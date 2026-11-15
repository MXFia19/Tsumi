import Foundation
import Observation
import WidgetKit

// App side of the widgets (TsumiWidgets extension): builds a TsumiWidgetSnapshot from the user's lists and the
// airing schedules, writes it with small cover thumbnails into the shared App Group container
// (Shared/TsumiSharedContainer.swift), then reloads the widget timelines. Runs at launch, whenever the lists
// change (refresh every 15 min, progress updates, account switch), when the app comes back to the foreground
// and in the background refresh task. Also drives the Live Activity countdowns (LiveCountdownManager).
// Hooks: AppWiring.swift (ShellLaunch, ShellLifecycle, ShellBackgroundRefresh).

/// Widget / Live Activity preferences (iOS only, so kept out of the settings blob shared with the desktop app).
@MainActor
@Observable
final class TsumiWidgetPreferences {
  static let shared = TsumiWidgetPreferences()
  private static let storageKey = "tsumi.widgets.v1"
  /// Choices of "Airing Within" (iOS ends a Live Activity after 8 hours).
  static let leadHourChoices = [1, 2, 3, 4, 6, 8]

  struct Values: Codable, Equatable {
    /// Start a lock screen countdown by itself for followed titles airing soon (while the app is open).
    var liveActivityAutoStart = false
    /// "Airing Within", hours.
    var liveActivityLeadHours = 3

    init() {}

    /// Tolerant: a missing or unreadable key keeps its default.
    init(from decoder: Decoder) throws {
      self.init()
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let value = try? container.decodeIfPresent(Bool.self, forKey: .liveActivityAutoStart) {
        liveActivityAutoStart = value
      }
      if let value = try? container.decodeIfPresent(Int.self, forKey: .liveActivityLeadHours), (1...12).contains(value) {
        liveActivityLeadHours = value
      }
    }
  }

  var values: Values {
    didSet {
      save()
      if values.liveActivityAutoStart && !oldValue.liveActivityAutoStart || values.liveActivityLeadHours != oldValue.liveActivityLeadHours {
        TsumiWidgetBridge.shared.scheduleWrite(after: 0.3)
      }
    }
  }

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode(Values.self, from: data) {
      values = stored
    } else {
      values = Values()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(values) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}

@MainActor
@Observable
final class TsumiWidgetBridge {
  static let shared = TsumiWidgetBridge()

  /// Shared container the snapshot is written to (nil when this install has no usable App Group).
  private(set) var location: TsumiSharedContainer.Location?
  /// `location` has been looked up.
  private(set) var isResolved = false
  private(set) var lastWrite: Date?
  private(set) var lastError: String?
  /// Last snapshot built (also used by the Live Activity auto start).
  private(set) var lastSnapshot: TsumiWidgetSnapshot?

  @ObservationIgnored private var started = false
  @ObservationIgnored private var pendingWrite: Task<Void, Never>?
  @ObservationIgnored private var resolveTask: Task<TsumiSharedContainer.Location?, Never>?
  @ObservationIgnored private var lastReload = Date.distantPast
  @ObservationIgnored private var isWriting = false
  @ObservationIgnored private var writeAgain = false

  private init() {}

  // MARK: - Hooks (AppWiring.swift)

  /// Launch (foreground or background): watches the lists and writes a first snapshot.
  static func start() {
    shared.start()
  }

  static func appBecameActive() {
    LiveCountdownManager.shared.reload()
    shared.scheduleWrite(after: 1)
  }

  static func appEnteredBackground() {
    shared.scheduleWrite(after: 0)
  }

  /// BGAppRefreshTask: fresh lists when they are old, then snapshot, widget reload and Live Activity cleanup.
  static func backgroundRefresh() async {
    await shared.refreshInBackground()
  }

  // MARK: - Writing

  private func start() {
    guard !started else { return }
    started = true
    observeLists()
    LiveCountdownManager.shared.reload()
    scheduleWrite(after: 1.5)
  }

  /// MediaListService.revision changes on every list refresh, local edit and account change.
  private func observeLists() {
    withObservationTracking {
      _ = MediaListService.shared.revision
    } onChange: {
      Task { @MainActor in
        TsumiWidgetBridge.shared.scheduleWrite(after: 2)
        TsumiWidgetBridge.shared.observeLists()
      }
    }
  }

  func scheduleWrite(after delay: TimeInterval, force: Bool = false) {
    pendingWrite?.cancel()
    pendingWrite = Task { @MainActor in
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      guard !Task.isCancelled else { return }
      await TsumiWidgetBridge.shared.writeNow(force: force)
    }
  }

  /// Looks up the shared container once (reads the code signature and provisioning profile off the main thread).
  func resolveLocation() async -> TsumiSharedContainer.Location? {
    if isResolved { return location }
    let task: Task<TsumiSharedContainer.Location?, Never>
    if let resolveTask {
      task = resolveTask
    } else {
      task = Task.detached(priority: .utility) {
        TsumiSharedContainer.writableLocation()
      }
      resolveTask = task
    }
    let resolved = await task.value
    location = resolved
    isResolved = true
    return resolved
  }

  /// Builds and writes the snapshot now (`force` reloads the widgets even when nothing changed).
  func writeNow(force: Bool = false) async {
    if isWriting {
      writeAgain = true
      return
    }
    isWriting = true
    await performWrite(force: force)
    while writeAgain {
      writeAgain = false
      await performWrite(force: false)
    }
    isWriting = false
  }

  private func performWrite(force: Bool) async {
    // nil while the lists of a signed-in account are not loaded yet: keep the previous snapshot meanwhile.
    guard var snapshot = await TsumiWidgetSnapshotBuilder.build() else { return }
    if let location = await resolveLocation() {
      snapshot = await TsumiWidgetCovers.sync(snapshot, keep: LiveCountdownManager.shared.coverFiles, in: location)
      let directory = location.directory
      let written = snapshot
      let result = await Task.detached(priority: .utility) { () -> (changed: Bool, error: String?) in
        let previous = TsumiWidgetSnapshot.read(from: directory)
        let changed = previous.map { !$0.sameContent(as: written) } ?? true
        do {
          try written.write(to: directory)
          return (changed, nil)
        } catch {
          return (changed, error.localizedDescription)
        }
      }.value
      lastError = result.error
      if result.error == nil {
        lastWrite = Date()
        // Reloads count against the widgets' daily budget in the background: only when something changed (or
        // once an hour, so the timelines pick up the next airing episodes).
        if force || result.changed || Date().timeIntervalSince(lastReload) > 3600 {
          WidgetCenter.shared.reloadAllTimelines()
          lastReload = Date()
        }
      }
    }
    lastSnapshot = snapshot
    await LiveCountdownManager.shared.sync(with: snapshot)
  }

  private func refreshInBackground() async {
    start()
    // Services.start() (run by ShellLaunch) loads the cached lists and refreshes them: wait for that a little.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !Task.isCancelled {
      let service = MediaListService.shared
      if AccountStore.shared.current == nil || (service.lists != nil && !service.isLoading) { break }
      try? await Task.sleep(nanoseconds: 500_000_000)
    }
    let service = MediaListService.shared
    if AccountStore.shared.current != nil, !service.isLoading, !Task.isCancelled,
       let fetchedAt = service.lists?.fetchedAt, Date().timeIntervalSince(fetchedAt) > 30 * 60 {
      await service.refresh()
    }
    pendingWrite?.cancel()
    await writeNow()
  }
}

/// Snapshot of the current account's lists.
@MainActor
enum TsumiWidgetSnapshotBuilder {
  /// Titles followed by the Next Episode widget and the countdowns.
  static let followedStatuses: [ListStatus] = [.current, .repeating, .planning]

  /// nil when signed in but the lists are not loaded yet.
  static func build(now: Date = Date()) async -> TsumiWidgetSnapshot? {
    guard let account = AccountStore.shared.current else {
      return TsumiWidgetSnapshot(generatedAt: now, account: nil, service: nil, continueWatching: [], airing: [])
    }
    guard let lists = MediaListService.shared.lists else { return nil }
    let isMAL = lists.service == .myanimelist
    // MyAnimeList entries have no AniList media of their own: the schedule feed gives their airing times.
    var schedule: [Int: ScheduleMedia] = [:]
    var byMalId: [Int: Media] = [:]
    if isMAL {
      for media in await AnimeScheduleService.shared.subAiringList() {
        if let malId = media.idMal, schedule[malId] == nil { schedule[malId] = media }
      }
      for media in MediaStore.shared.allMedia() where media.source == .anilist {
        if let malId = media.malId, byMalId[malId] == nil { byMalId[malId] = media }
      }
    }
    let context = Context(now: now, schedule: schedule, byMalId: byMalId)
    let service = MediaListService.shared

    var shows: [TsumiWidgetShow] = []
    for item in service.items([.current, .repeating], sort: "UPDATED_TIME_DESC").prefix(60) {
      if let show = context.show(item) { shows.append(show) }
    }
    let continueWatching = Array(TsumiWidgetOrdering.continueWatching(shows, now: now).prefix(10))

    var airing: [TsumiWidgetAiring] = []
    for item in service.items(followedStatuses) {
      airing.append(contentsOf: context.airings(item))
    }
    airing.sort { $0.airingAt < $1.airingAt }

    return TsumiWidgetSnapshot(generatedAt: now, account: account.viewer.name, service: account.viewer.service.rawValue, continueWatching: continueWatching, airing: Array(airing.prefix(40)))
  }

  private struct Context {
    let now: Date
    let schedule: [Int: ScheduleMedia]
    let byMalId: [Int: Media]

    func media(_ item: UserListItem) -> Media? {
      if let media = item.media { return MediaStore.shared.media(media.id) ?? media }
      if let malId = item.malId { return byMalId[malId] }
      return nil
    }

    func key(_ item: UserListItem, _ media: Media?) -> String {
      media?.id ?? item.id
    }

    func link(_ item: UserListItem, _ media: Media?) -> URL? {
      if let id = media?.anilistId ?? item.anilistId { return TsumiWidgetLinks.anime(id) }
      if let malId = item.malId { return TsumiWidgetLinks.malAnime(malId) }
      return nil
    }

    @MainActor
    func title(_ item: UserListItem, _ media: Media?) -> String {
      if let media { return AniListService.shared.title(media) }
      if let title = item.title, !title.isEmpty { return title }
      let scheduled = item.malId.flatMap { schedule[$0]?.title }
      return scheduled?.userPreferred ?? scheduled?.english ?? scheduled?.romaji ?? "Unknown Title"
    }

    func coverURL(_ item: UserListItem, _ media: Media?) -> URL? {
      if let url = media?.images.coverLarge ?? media?.images.cover ?? item.cover { return url }
      let cover = item.malId.flatMap { schedule[$0]?.coverImage }
      return (cover?.extraLarge ?? cover?.medium).flatMap { URL(string: $0) }
    }

    func total(_ item: UserListItem, _ media: Media?) -> Int? {
      for value in [media?.episodes, item.malNumEpisodes, item.malId.flatMap { schedule[$0]?.episodes }] {
        if let value, value > 0 { return value }
      }
      return nil
    }

    /// Airing schedule of the title, sorted.
    func nodes(_ item: UserListItem, _ media: Media?) -> [AiringNode] {
      var nodes = media.map { MediaStore.shared.extras(for: $0).airingSchedule } ?? []
      if nodes.isEmpty, let malId = item.malId, let scheduled = schedule[malId] {
        nodes = scheduled.nodes
      }
      return nodes.sorted { $0.airingAt < $1.airingAt }
    }

    @MainActor
    func show(_ item: UserListItem) -> TsumiWidgetShow? {
      let media = self.media(item)
      guard let link = self.link(item, media) else { return nil }
      let total = self.total(item, media)
      if let total, item.progress >= total { return nil }
      let next = item.progress + 1
      let state = nextEpisodeState(next, nodes: self.nodes(item, media), media: media, item: item)
      let key = self.key(item, media)
      let color = media?.images.color ?? item.malId.flatMap { schedule[$0]?.coverImage?.color }
      return TsumiWidgetShow(id: key, title: self.title(item, media), progress: item.progress, total: total, nextEpisode: next, upcoming: state.upcoming, nextEpisodeAiringAt: state.airingAt, cover: TsumiThumbnail.fileName(for: key), coverURL: self.coverURL(item, media), color: color, link: link)
    }

    /// Whether episode `next` has aired, and when it airs when it has not.
    private func nextEpisodeState(_ next: Int, nodes: [AiringNode], media: Media?, item: UserListItem) -> (upcoming: Bool, airingAt: Date?) {
      if let node = nodes.first(where: { $0.episode == next }) {
        return node.airingAt > now ? (true, node.airingAt) : (false, nil)
      }
      if let nextAiring = media?.nextAiring {
        if nextAiring.episode == next {
          return nextAiring.airingAt > now ? (true, nextAiring.airingAt) : (false, nil)
        }
        if nextAiring.episode < next && nextAiring.airingAt > now { return (true, nil) }
      }
      if media?.status == .notYetReleased || item.malAiringStatus == "not_yet_aired" { return (true, nil) }
      let airing = media?.status == .releasing || item.malAiringStatus == "currently_airing"
      if airing, let last = nodes.last, next > last.episode { return (true, nil) }
      return (false, nil)
    }

    /// The next episodes of a followed title (up to 3, within two weeks, plus the one that just aired).
    @MainActor
    func airings(_ item: UserListItem) -> [TsumiWidgetAiring] {
      let media = self.media(item)
      guard let link = self.link(item, media) else { return [] }
      let from = now.addingTimeInterval(-TsumiWidgetSnapshot.outWindow)
      let horizon = now.addingTimeInterval(14 * 86400)
      var upcoming = self.nodes(item, media).filter { $0.airingAt > from && $0.airingAt < horizon }
      if upcoming.isEmpty, let next = media?.nextAiring, next.airingAt > from, next.airingAt < horizon {
        upcoming = [AiringNode(episode: next.episode, airingAt: next.airingAt)]
      }
      guard !upcoming.isEmpty else { return [] }
      let key = self.key(item, media)
      let title = self.title(item, media)
      let total = self.total(item, media)
      let cover = TsumiThumbnail.fileName(for: key)
      let coverURL = self.coverURL(item, media)
      let color = media?.images.color ?? item.malId.flatMap { schedule[$0]?.coverImage?.color }
      var result: [TsumiWidgetAiring] = []
      var times = Set<Date>()
      for node in upcoming where times.insert(node.airingAt).inserted {
        // Batch releases: one entry per airing time (its first episode).
        result.append(TsumiWidgetAiring(mediaId: key, title: title, episode: node.episode, totalEpisodes: total, airingAt: node.airingAt, cover: cover, coverURL: coverURL, color: color, link: link))
        if result.count == 3 { break }
      }
      return result
    }
  }
}

/// Cover thumbnails of the shared container.
enum TsumiWidgetCovers {
  /// Downloads the thumbnails the widgets can show, deletes the others (except `keep`, used by Live Activities)
  /// and returns the snapshot with `cover` set only where a thumbnail exists.
  static func sync(_ snapshot: TsumiWidgetSnapshot, keep: Set<String>, in location: TsumiSharedContainer.Location) async -> TsumiWidgetSnapshot {
    var wanted: [(String, URL)] = []
    var names = Set<String>()
    for show in snapshot.continueWatching.prefix(8) {
      if let cover = show.cover, let url = show.coverURL, names.insert(cover).inserted { wanted.append((cover, url)) }
    }
    for item in snapshot.airing.prefix(16) {
      if let cover = item.cover, let url = item.coverURL, names.insert(cover).inserted { wanted.append((cover, url)) }
    }
    let directory = location.coversDirectory
    let keepNames = names.union(keep)
    let downloads = wanted
    let existing = await Task.detached(priority: .utility) { () async -> Set<String> in
      let manager = FileManager.default
      try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
      var index = 0
      while index < downloads.count {
        let batch = Array(downloads[index..<min(index + 4, downloads.count)])
        await withTaskGroup(of: Void.self) { group in
          for (name, url) in batch {
            group.addTask {
              _ = await TsumiThumbnail.download(url, to: directory.appendingPathComponent(name))
            }
          }
        }
        index += 4
      }
      let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
      var present = Set<String>()
      for file in files {
        if keepNames.contains(file) {
          present.insert(file)
        } else {
          try? manager.removeItem(at: directory.appendingPathComponent(file))
        }
      }
      return present
    }.value
    var result = snapshot
    for index in result.continueWatching.indices {
      if let cover = result.continueWatching[index].cover, !existing.contains(cover) { result.continueWatching[index].cover = nil }
    }
    for index in result.airing.indices {
      if let cover = result.airing[index].cover, !existing.contains(cover) { result.airing[index].cover = nil }
    }
    return result
  }

  /// Makes sure one thumbnail exists (Live Activity started from the details of any title).
  static func ensure(_ name: String, url: URL, in location: TsumiSharedContainer.Location) async -> Bool {
    let destination = location.coversDirectory.appendingPathComponent(name)
    return await Task.detached(priority: .userInitiated) { () async -> Bool in
      await TsumiThumbnail.download(url, to: destination, timeout: 6)
    }.value
  }
}
