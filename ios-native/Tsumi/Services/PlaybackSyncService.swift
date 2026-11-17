import Foundation
import Observation
import UIKit

// Port of common/modules/sync (remote.js, store.js, session.js): cross-device resume through the note of the list
// entry (AniList `notes`, MyAnimeList `comments`, line format in PlaybackPositionNote.swift) and Trakt for shows and
// movies (TraktService.swift).
// - The player writes the position on pause, when it closes, when the app goes to the background and every 2 minutes
//   while playing; the line is removed once the episode reaches the auto-complete threshold.
// - "Resume at 12:34 (from PC)" is offered in the player (PlayerResumeOfferView) and the details
//   (BrowseRemoteResumeButton) when another device played the episode more recently.
// - Every write is a read-modify-write of the current note: the user's own text is never lost, and nothing is
//   written when the note could not be read.

/// Position written by another device (remotePositions of store.js). `time` / `duration` in seconds.
struct RemotePosition: Hashable {
  var episode: Int
  var time: Double?
  var duration: Double?
  /// Trakt only stores a percentage.
  var percent: Double?
  var device: String
  var at: Date
  /// anilist | mal | trakt
  var source: String

  /// Watched percentage (0-100), 0 when unknown.
  var watchedPercent: Int {
    // Clamped before the Int conversion, which crashes on huge values (a note edited by hand).
    if let duration, duration > 0, let time, time >= 0, time.isFinite { return Int(min(100, (time / duration * 100).rounded(.up))) }
    if let percent, percent > 0, percent.isFinite { return Int(min(100, percent.rounded(.up))) }
    return 0
  }
}

/// "Resume at 12:34 (from PC)" offered over a player.
struct ResumeOffer: Equatable, Identifiable {
  let id = UUID()
  var controllerId: ObjectIdentifier
  var mediaKey: String
  var episode: Int
  var time: Double
  var device: String
  var isMovie: Bool
}

/// "Resume Episode 5 at 12:34 (from iPhone)" offered in the details.
struct DetailsResumeOffer: Equatable {
  var episode: EpisodeRef
  var time: Double?
  var percent: Double?
  var duration: Double?
  var device: String
  var at: Date
}

@Observable
@MainActor
final class PlaybackSyncService {
  static let shared = PlaybackSyncService()

  /// Name written in the note line ("Resume at 12:34 (from iPhone)" on the other device).
  static var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
  }

  enum NoteService: String {
    case anilist
    case mal
  }

  /// List entry with its note. `unknown`: the service did not return the note, so it must not be written.
  struct NoteEntry {
    var exists: Bool
    var unknown = false
    var notes = ""
    var progress: Int?
  }

  struct PendingResume {
    var mediaKey: String
    var episode: Int
    var time: Double?
    var percent: Double?
    var date: Date
  }

  /// Positions of other devices by media key (episode progress bars, details).
  private(set) var remotePositions: [String: RemotePosition] = [:]
  /// Offer shown over the player.
  private(set) var offer: ResumeOffer?

  /// Resume asked from the details, applied when that episode is opened in the player.
  @ObservationIgnored var pendingResume: PendingResume?
  @ObservationIgnored private var lastRead: [String: (entry: NoteEntry, date: Date)] = [:]
  @ObservationIgnored private var chains: [String: Task<Bool, Never>] = [:]
  @ObservationIgnored private weak var session: PlaybackSyncSession?
  @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// A note read less than this long ago is reused by the next write.
  private static let readReuse: TimeInterval = 20

  private static let entryQuery = """
  query($id: Int) {
    Media(id: $id, type: ANIME) {
      id
      mediaListEntry { id, status, progress, notes, updatedAt }
    }
  }
  """

  private static let saveNotesMutation = """
  mutation($id: Int, $notes: String) {
    SaveMediaListEntry(mediaId: $id, notes: $notes) { id, notes }
  }
  """

  private init() {
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.enteredBackground()
      }
    }
  }

  // MARK: - Player

  /// Session following one player (ShellPlayback.wire).
  func attach(_ controller: PlayerController) -> PlaybackSyncSession {
    let created = PlaybackSyncSession(controller: controller, service: self)
    session = created
    return created
  }

  func showOffer(_ value: ResumeOffer) {
    offer = value
  }

  func dismissOffer(_ id: UUID? = nil) {
    if id == nil || offer?.id == id { offer = nil }
  }

  /// The app goes to the background: the position is written right away (with some background time).
  private func enteredBackground() {
    guard let session, session.hasPendingWork else { return }
    endBackgroundTask()
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Tsumi playback sync") { [weak self] in
      MainActor.assumeIsolated {
        self?.endBackgroundTask()
      }
    }
    Task { @MainActor [weak self] in
      await session.flush()
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: - Remote positions

  func setRemote(_ mediaKey: String, _ position: RemotePosition?) {
    if remotePositions[mediaKey] == position { return }
    remotePositions[mediaKey] = position
  }

  /// Another AniList / MyAnimeList account is in use (ProfilesService): the positions read from the previous
  /// account's notes, its cached note reads and the resume offers built from them are dropped. Trakt positions stay
  /// (Trakt is connected separately).
  func accountChanged() {
    remotePositions = remotePositions.filter { $0.value.source == "trakt" }
    lastRead.removeAll()
    pendingResume = nil
    offer = nil
  }

  /// Notes of the user lists (AniListService.userLists asks for them): the positions of every entry are known
  /// after each list refresh, without one request per title. Key: media key, value: the note.
  func ingestListNotes(_ notes: [String: String]) {
    guard AppSettings.shared.values.syncPlaybackPosition else { return }
    for (key, text) in notes {
      if let position = PlaybackPositionNote.read(text) {
        setRemote(key, RemotePosition(episode: position.episode, time: position.time, duration: position.duration, percent: nil, device: position.device, at: position.at, source: NoteService.anilist.rawValue))
      } else if remotePositions[key]?.source == NoteService.anilist.rawValue {
        setRemote(key, nil)
      }
    }
  }

  // MARK: - Notes

  /// Where the note of this media lives: AniList, MyAnimeList, or nil (setting off, not logged in, TMDB title).
  func noteService(_ media: Media) -> NoteService? {
    guard AppSettings.shared.values.syncPlaybackPosition, media.source == .anilist else { return nil }
    let accounts = AccountStore.shared
    if accounts.isAniList, media.anilistId != nil { return .anilist }
    if accounts.isMAL, accounts.current?.reauth == false, media.malId != nil { return .mal }
    return nil
  }

  private static func cacheKey(_ media: Media, _ service: NoteService) -> String {
    "\(service.rawValue):\(service == .mal ? (media.malId ?? 0) : (media.anilistId ?? 0))"
  }

  /// One read-modify-write at a time per entry.
  private func serial(_ key: String, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
    let previous = chains[key]
    let task = Task { @MainActor () -> Bool in
      _ = await previous?.value
      return await work()
    }
    chains[key] = task
    let result = await task.value
    if chains[key] == task { chains[key] = nil }
    return result
  }

  private func readEntry(_ media: Media, _ service: NoteService) async -> NoteEntry? {
    let account = AccountStore.shared.current?.id
    var entry: NoteEntry
    switch service {
    case .anilist:
      guard let id = media.anilistId,
            let json = try? await AniListService.shared.request(Self.entryQuery, variables: ["id": id]),
            let data = json["data"] as? [String: Any],
            let mediaData = data.dict("Media") else { return nil }
      if let listEntry = mediaData.dict("mediaListEntry") {
        let raw = listEntry["notes"]
        entry = NoteEntry(exists: true, unknown: raw == nil, notes: raw as? String ?? "", progress: listEntry.int("progress"))
      } else {
        entry = NoteEntry(exists: false)
      }
    case .mal:
      let fields = URLQueryItem(name: "fields", value: "my_list_status{status,num_episodes_watched,is_rewatching,comments}")
      guard let malId = media.malId,
            let result = try? await MyAnimeListService.shared.request(path: "anime/\(malId)", query: [fields]),
            let data = result as? [String: Any], data["id"] != nil else { return nil }
      if let status = data.dict("my_list_status") {
        let comments = status["comments"] as? String
        entry = NoteEntry(exists: true, unknown: comments == nil, notes: comments ?? "", progress: status.int("num_episodes_watched"))
      } else {
        entry = NoteEntry(exists: false)
      }
    }
    // The profile changed during the request: the note is the previous account's.
    guard AccountStore.shared.current?.id == account else { return nil }
    lastRead[Self.cacheKey(media, service)] = (entry, Date())
    return entry
  }

  private func writeNotes(_ media: Media, _ service: NoteService, _ notes: String) async -> Bool {
    switch service {
    case .anilist:
      guard let id = media.anilistId,
            let json = try? await AniListService.shared.request(Self.saveNotesMutation, variables: ["id": id, "notes": notes]),
            let data = json["data"] as? [String: Any] else { return false }
      return data.dict("SaveMediaListEntry")?.int("id") != nil
    case .mal:
      guard let malId = media.malId,
            let result = try? await MyAnimeListService.shared.request(path: "anime/\(malId)/my_list_status", method: "PUT", form: ["comments": notes]) else { return false }
      return (result as? [String: Any])?["status"] != nil
    }
  }

  /// Reads the position written in the note of `media` (fresh request) and records it.
  func fetchNotePosition(_ media: Media) async -> (entry: NoteEntry, position: NotePosition?)? {
    guard let service = noteService(media), let entry = await readEntry(media, service) else { return nil }
    let position = entry.exists && !entry.unknown ? PlaybackPositionNote.read(entry.notes) : nil
    setRemote(media.id, position.map { RemotePosition(episode: $0.episode, time: $0.time, duration: $0.duration, percent: nil, device: $0.device, at: $0.at, source: service.rawValue) })
    return (entry, position)
  }

  /// Writes `position` in the note (replacing the previous Tsumi line), or removes the line when nil (keeping a
  /// line about an episode after `upToEpisode`: another device moved on). Only for an entry already on the list.
  @discardableResult
  func saveNotePosition(_ media: Media, _ position: NotePosition?, upToEpisode: Int? = nil) async -> Bool {
    guard let service = noteService(media) else { return false }
    let key = Self.cacheKey(media, service)
    let account = AccountStore.shared.current?.id
    return await serial(key) { [weak self] in
      guard let self else { return false }
      // A position of the previous profile is never written to the note of the current one.
      guard AccountStore.shared.current?.id == account else { return false }
      let cached = self.lastRead[key]
      let fresh: NoteEntry?
      if let cached, Date().timeIntervalSince(cached.date) < Self.readReuse {
        fresh = cached.entry
      } else {
        fresh = await self.readEntry(media, service)
      }
      guard let entry = fresh, entry.exists, !entry.unknown else { return false }
      let current = entry.notes
      if position == nil {
        if !PlaybackPositionNote.hasLine(current) { return true }
        if let written = PlaybackPositionNote.read(current), let upToEpisode, written.episode > upToEpisode { return true }
      }
      let next = PlaybackPositionNote.with(current, position)
      if next == current { return true }
      guard AccountStore.shared.current?.id == account else { return false }
      let ok = await self.writeNotes(media, service, next)
      if ok {
        var updated = entry
        updated.notes = next
        self.lastRead[key] = (updated, Date())
        self.setRemote(media.id, position.map { RemotePosition(episode: $0.episode, time: $0.time, duration: $0.duration, percent: nil, device: $0.device, at: $0.at, source: service.rawValue) })
      } else {
        self.lastRead[key] = nil
      }
      return ok
    }
  }

  // MARK: - Details

  /// "Resume Episode 5 at 12:34 (from iPhone)": the note (anime) or Trakt (shows and movies), when newer than
  /// what this device played.
  func detailsOffer(for media: Media) async -> DetailsResumeOffer? {
    var candidate: DetailsResumeOffer?
    if media.source == .tmdb {
      candidate = await traktDetailsOffer(media)
    } else if noteService(media) != nil {
      guard let fetched = await fetchNotePosition(media), let position = fetched.position else { return nil }
      // An earlier episode than the list progress was already watched (the line stays only when a removal failed).
      if position.episode < (fetched.entry.progress ?? 0) { return nil }
      candidate = DetailsResumeOffer(episode: EpisodeRef(number: position.episode, season: nil, localEpisode: nil), time: position.time, percent: nil, duration: position.duration, device: position.device, at: position.at)
    }
    guard let found = candidate else { return nil }
    let local = AnimeProgressService.shared.record(mediaKey: media.id, episode: found.episode.number)
    return Self.isNewer(found, local) ? found : nil
  }

  private static func isNewer(_ remote: DetailsResumeOffer, _ local: EpisodeProgressRecord?) -> Bool {
    guard let local else { return (remote.time ?? 0) > 0 || (remote.percent ?? 0) > 0 }
    if remote.at <= local.updatedAt.addingTimeInterval(PlaybackPositionNote.offerMinAgeDifference) { return false }
    if let time = remote.time, time > 0 { return abs(time - local.currentTime) > PlaybackPositionNote.offerMinDifference }
    let localPercent = local.safeDuration > 0 ? local.currentTime / local.safeDuration * 100 : 0
    return abs((remote.percent ?? 0) - localPercent) > 2
  }

  private static func idString(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return "\(value)"
  }

  private func traktDetailsOffer(_ media: Media) async -> DetailsResumeOffer? {
    let trakt = TraktService.shared
    guard trakt.isConnected, let tmdbId = media.tmdbId else { return nil }
    let items = await trakt.playback()
    let wanted = String(tmdbId)
    let match: [String: Any]?
    if media.isMovie {
      match = items.first { $0.string("type") == "movie" && Self.idString($0.dict("movie")?.dict("ids")?["tmdb"]) == wanted }
    } else {
      match = items.first { $0.string("type") == "episode" && Self.idString($0.dict("show")?.dict("ids")?["tmdb"]) == wanted }
    }
    guard let item = match, let percent = item.double("progress"), percent > 0, let at = TraktService.date(item) else { return nil }
    var episode = EpisodeRef(number: 1, season: nil, localEpisode: nil)
    var minutes: Int?
    if media.isMovie {
      minutes = await TMDBService.shared.details(id: tmdbId, type: .movie)?.runtime
    } else {
      guard let season = item.dict("episode")?.int("season"), let number = item.dict("episode")?.int("number") else { return nil }
      let list = await MediaDetailsService.shared.quickEpisodes(for: media)
      guard let info = list.first(where: { $0.season == season && $0.localEpisode == number }) else { return nil }
      episode = info.ref
      minutes = info.durationMinutes
    }
    let duration = minutes.map { Double($0 * 60) }.flatMap { $0 > 0 ? $0 : nil }
    let time = duration.map { percent / 100 * $0 }
    setRemote(media.id, RemotePosition(episode: episode.number, time: time, duration: duration, percent: percent, device: "Trakt", at: at, source: "trakt"))
    return DetailsResumeOffer(episode: episode, time: time, percent: percent, duration: duration, device: "Trakt", at: at)
  }

  /// The details "Resume" button: the player resumes the local position, so it becomes this one (the Trakt
  /// percentage is applied exactly once the real duration is known), then the episode is played.
  func resumeFromDetails(_ media: Media, _ offer: DetailsResumeOffer) {
    let safeDuration = offer.duration ?? Double((media.duration ?? 24) * 60)
    let time = offer.time ?? ((offer.percent ?? 0) / 100 * safeDuration)
    if time > 0 {
      AnimeProgressService.shared.set(mediaKey: media.id, episode: offer.episode.number, currentTime: time, safeDuration: safeDuration)
    }
    let isTrakt = offer.device == "Trakt"
    pendingResume = PendingResume(mediaKey: media.id, episode: offer.episode.number, time: isTrakt ? nil : offer.time, percent: isTrakt ? offer.percent : nil, date: Date())
    BrowseActions.play(media, episode: offer.episode)
  }
}

/// Follows one player: note writes, Trakt scrobbles, resume offer (session.js PlaybackSync).
@MainActor
final class PlaybackSyncSession {
  enum TraktState {
    case idle
    case start
    case pause
    case stop
  }

  final class Item {
    let media: Media
    let episode: EpisodeRef
    let key: String
    let localTime: Double?
    let localUpdatedAt: Date?
    var time: Double = 0
    var duration: Double = 0
    var playing = false
    var finished = false
    var written: NotePosition?
    var writtenAt = Date()
    var lastReport: (time: Double, date: Date, playing: Bool)?
    var pauseTask: Task<Void, Never>?
    var target: Task<TraktTarget?, Never>?
    var traktState: TraktState = .idle
    var traktTask: Task<Void, Never>?
    var resume: PlaybackSyncService.PendingResume?

    init(media: Media, episode: EpisodeRef, key: String, local: EpisodeProgressRecord?) {
      self.media = media
      self.episode = episode
      self.key = key
      self.localTime = local?.currentTime
      self.localUpdatedAt = local?.updatedAt
    }
  }

  private weak var controller: PlayerController?
  private unowned let service: PlaybackSyncService
  private var item: Item?

  init(controller: PlayerController, service: PlaybackSyncService) {
    self.controller = controller
    self.service = service
  }

  var hasPendingWork: Bool { item != nil }

  private static func key(_ media: Media, _ episode: EpisodeRef) -> String {
    "\(media.id):\(episode.number)"
  }

  private var threshold: Double {
    Double(AppSettings.shared.values.playerAutocompleteThreshold > 0 ? AppSettings.shared.values.playerAutocompleteThreshold : 85)
  }

  // MARK: Player hooks

  /// onEpisodeStarted: a new episode (the previous one is left first).
  func started(_ session: PlaybackSession) {
    let key = Self.key(session.media, session.episode)
    if item?.key == key { return }
    leave()
    let media = session.media
    let episode = session.episode
    let local = AnimeProgressService.shared.record(mediaKey: media.id, episode: episode.number)
    let next = Item(media: media, episode: episode, key: key, local: local)
    if let pending = service.pendingResume, pending.mediaKey == media.id, pending.episode == episode.number, Date().timeIntervalSince(pending.date) < 300 {
      next.resume = pending
      service.pendingResume = nil
    }
    let trakt = TraktService.shared
    let scrobbles = trakt.isConnected && AppSettings.shared.values.traktScrobble
    if scrobbles || (trakt.isConnected && media.source == .tmdb) {
      next.target = Task { @MainActor in await TraktService.shared.target(for: media, episode: episode) }
    }
    if !scrobbles { next.traktState = .stop } // resume offers only
    item = next
    service.dismissOffer()
    Task { @MainActor [weak self] in
      await self?.checkRemote(next)
    }
  }

  /// onProgress: every 10 s while playing, on play / pause / seek, on close.
  func progress(_ snapshot: PlayerProgressSnapshot, playing: Bool) {
    guard let item, item.key == Self.key(snapshot.media, snapshot.episode) else { return }
    let previous = item.lastReport
    let now = Date()
    item.time = snapshot.currentTime
    if let duration = controller?.duration, duration.isFinite, duration > 0 { item.duration = duration }
    item.lastReport = (snapshot.currentTime, now, playing)
    if !item.finished, item.duration > 0, item.time / item.duration * 100 >= threshold {
      finish(item)
    }
    if playing {
      item.pauseTask?.cancel()
      item.pauseTask = nil
      if !item.playing {
        item.playing = true
        queueTrakt(item, .start, delay: 1.5)
      } else if let previous, previous.playing, item.traktState == .start {
        // A seek while playing: Trakt is told where playback is now.
        let rate = Double(controller?.playbackRate ?? 1)
        let expected = now.timeIntervalSince(previous.date) * rate
        if abs((snapshot.currentTime - previous.time) - expected) > 5 { queueTrakt(item, .start, delay: 1.5, force: true) }
      }
      if now.timeIntervalSince(item.writtenAt) >= PlaybackPositionNote.periodicWrite {
        Task { @MainActor [weak self] in await self?.writeNote(item) }
      }
    } else {
      item.playing = false
      item.pauseTask?.cancel()
      item.pauseTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(PlaybackPositionNote.pauseWriteDelay * 1_000_000_000))
        if Task.isCancelled { return }
        await self?.writeNote(item)
      }
      queueTrakt(item, .pause, delay: 2)
    }
  }

  /// onPlaybackEnded.
  func ended() {
    guard let item else { return }
    item.time = item.duration > 0 ? item.duration : item.time
    finish(item)
    item.traktTask?.cancel()
    if item.traktState == .start || item.traktState == .pause {
      Task { @MainActor [weak self] in await self?.sendTrakt(item, .stop, progress: 100) }
    }
  }

  /// onClose.
  func closed() {
    leave()
    service.dismissOffer()
  }

  /// The app goes to the background.
  func flush() async {
    guard let item else { return }
    if let controller, controller.currentTime.isFinite, controller.currentTime > 0 { item.time = controller.currentTime }
    await writeNote(item)
  }

  // MARK: Internals

  /// The player closes or moves to another episode: last note write and Trakt stop.
  private func leave() {
    guard let item else { return }
    self.item = nil
    item.pauseTask?.cancel()
    item.traktTask?.cancel()
    let stops = item.traktState == .start || item.traktState == .pause
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.writeNote(item)
      if stops { await self.sendTrakt(item, .stop, progress: nil) }
    }
  }

  /// The auto-complete threshold is reached: the episode counts as watched, the note line goes away.
  private func finish(_ item: Item) {
    guard !item.finished else { return }
    item.finished = true
    item.pauseTask?.cancel()
    guard service.noteService(item.media) != nil else { return }
    let service = self.service
    Task { @MainActor in
      await service.saveNotePosition(item.media, nil, upToEpisode: item.episode.number)
    }
  }

  private func writeNote(_ item: Item) async {
    item.pauseTask?.cancel()
    guard !item.finished, item.time >= PlaybackPositionNote.minWriteTime, service.noteService(item.media) != nil else { return }
    let position = NotePosition(episode: item.episode.number, time: item.time, duration: item.duration > 0 ? item.duration : nil, device: PlaybackSyncService.deviceName, at: Date())
    guard PlaybackPositionNote.needsWrite(last: item.written, next: position) else { return }
    item.written = position
    item.writtenAt = Date()
    await service.saveNotePosition(item.media, position)
  }

  private func queueTrakt(_ item: Item, _ action: TraktState, delay: TimeInterval, force: Bool = false) {
    guard item.target != nil, item.traktState != .stop else { return }
    item.traktTask?.cancel()
    if item.traktState == action && !force { return }
    item.traktTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      if Task.isCancelled { return }
      await self?.sendTrakt(item, action, progress: nil)
    }
  }

  private func sendTrakt(_ item: Item, _ action: TraktState, progress: Double?) async {
    guard let targetTask = item.target else { return }
    let previous = item.traktState
    item.traktState = action
    guard previous != .stop, let target = await targetTask.value else { return }
    let percent = progress ?? (item.duration > 0 ? item.time / item.duration * 100 : 0)
    let name: String
    switch action {
    case .start: name = "start"
    case .pause: name = "pause"
    case .stop, .idle: name = "stop"
    }
    await TraktService.shared.scrobble(name, target: target, progress: percent)
  }

  /// "Resume at 12:34 (from PC)" when the note (anime) or Trakt (shows and movies) has a newer position for this
  /// episode than this device.
  private func checkRemote(_ item: Item) async {
    var waited = 0
    while waited < 40 {
      if self.item !== item { return }
      if let duration = controller?.duration, duration.isFinite, duration > 0 { break }
      try? await Task.sleep(nanoseconds: 500_000_000)
      waited += 1
    }
    guard self.item === item, let controller, controller.duration.isFinite, controller.duration > 0 else { return }
    item.duration = controller.duration
    if let resume = item.resume {
      // Resume asked from the details: the local position was set to it; correct it once the duration is known.
      let target = resume.time ?? ((resume.percent ?? 0) / 100 * item.duration)
      try? await Task.sleep(nanoseconds: 500_000_000)
      if self.item === item, target > 0, abs(controller.currentTime - target) > 3 {
        controller.seek(to: max(target - 2, 0))
      }
      return
    }
    var remote: NotePosition?
    if service.noteService(item.media) != nil {
      remote = await service.fetchNotePosition(item.media)?.position
    } else if TraktService.shared.isConnected, let targetTask = item.target, let target = await targetTask.value {
      let items = await TraktService.shared.playback(fresh: true)
      if let found = items.first(where: { target.matches($0) }), let percent = found.double("progress"), let at = TraktService.date(found) {
        remote = NotePosition(episode: item.episode.number, time: percent / 100 * item.duration, duration: item.duration, device: "Trakt", at: at)
      }
    }
    guard self.item === item, let remote, let player = self.controller else { return }
    guard PlaybackPositionNote.shouldOffer(remote: remote, localTime: item.localTime, localUpdatedAt: item.localUpdatedAt, episode: item.episode.number) else { return }
    guard abs(player.currentTime - remote.time) >= PlaybackPositionNote.offerMinDifference else { return }
    service.showOffer(ResumeOffer(
      controllerId: ObjectIdentifier(player),
      mediaKey: item.media.id,
      episode: item.episode.number,
      time: remote.time,
      device: remote.device,
      isMovie: item.media.isMovie
    ))
  }
}
