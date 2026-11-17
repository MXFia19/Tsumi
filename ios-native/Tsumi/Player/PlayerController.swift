import AVFoundation
import AVKit
import Combine
import CoreImage
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Native video player. Port of the playback logic of common/routes/player/PlayerPage.svelte
/// (stream loading, servers, progress, autocomplete, chapters/skip, next episode, subtitles, Watch Together)
/// on top of AVPlayer. Create it on the main actor, set the hooks, then present `PlayerView(controller:)`
/// (or use `PlayerPresentation.shared.present(_:)`). Playback starts when the view appears. `minimize()` leaves
/// the full screen UI without stopping playback (in-app miniplayer, `PlayerMiniPlayer`).
@MainActor
@Observable
final class PlayerController {
  // MARK: - Hooks wired by the app

  /// Loads another episode (next/previous, episode list, Watch Together index). Errors are shown as a notice;
  /// throw `PlayerEpisodeHandedOff` when the app took over (e.g. it opened the extension picker).
  @ObservationIgnored var loadEpisode: ((EpisodeRef) async throws -> PlaybackSession)?
  /// Saved position when the session has no `startTime` (getAnimeProgress).
  @ObservationIgnored var resumePosition: ((Media, EpisodeRef) -> Double?)?
  /// Periodic position report: every 10 s while playing, on play/pause/seek, on close (setAnimeProgress).
  @ObservationIgnored var onProgress: ((PlayerProgressSnapshot) -> Void)?
  /// Called once per episode when `playerAutocompleteThreshold`% is watched and `playerAutocomplete` is on
  /// (Helper.updateEntry: update the list progress).
  @ObservationIgnored var onAutocomplete: ((Media, EpisodeRef) -> Void)?
  /// Called when the episode plays to its end.
  @ObservationIgnored var onPlaybackEnded: ((Media, EpisodeRef) -> Void)?
  /// Called every time an episode starts loading (initial one included); Watch Together can share it.
  @ObservationIgnored var onEpisodeStarted: ((PlaybackSession) -> Void)?
  /// The player was closed (X button, the miniplayer's close button, or a new player replacing it). Closing the
  /// PiP window while the player UI is dismissed brings the video back in the miniplayer instead.
  @ObservationIgnored var onClose: (() -> Void)?
  /// `minimize()` (in-app miniplayer) or Picture in Picture started from the PiP button: the app dismisses the
  /// player UI and keeps the controller (PlayerPresentation shows the miniplayer when PiP is not running).
  @ObservationIgnored var onMinimize: (() -> Void)?
  /// "Restore" tapped in the PiP window while minimized: the app must present the player UI again.
  @ObservationIgnored var onRestoreFromPictureInPicture: (() -> Void)?
  /// "Now Playing [O]": shows the media details. The app reports the sheet with `setExternalOverlay(presented:)`
  /// (playback continues, like the Svelte app; the player restores its keyboard focus when it closes).
  @ObservationIgnored var onOpenDetails: ((Media) -> Void)?
  /// "Download Episode" of the More menu (offline downloads); the item shows only when the app sets it.
  @ObservationIgnored var onDownloadEpisode: (() -> Void)?
  /// Watch Together: local play/pause/seek (w2gEmitter 'player', time floored to the second).
  @ObservationIgnored var onLocalStateChange: (((paused: Bool, time: Double)) -> Void)?
  /// Watch Together: the user changed episode. Index in `episodeList`, or the episode number without a list.
  @ObservationIgnored var onIndexChange: ((Int) -> Void)?
  /// Watch Together session active: disables autoplay of the next episode (like `!state.value`).
  @ObservationIgnored var isWatchTogetherActive: (() -> Bool)?
  /// Name of the extension / addon playing (Watch Together `status.source`); the app sets and updates it.
  @ObservationIgnored var sourceName: String?
  /// Watch Together v2: a play / pause / seek the user made (not a file loading, not a lobby state being applied).
  @ObservationIgnored var onSyncAction: ((PlayerSyncAction) -> Void)?
  /// Watch Together v2: the file is ready (resume position and autoplay handled); the lobby may move it to the host.
  @ObservationIgnored var onSyncReady: (() -> Void)?
  /// Filler/recap lookup used for the skip prompt; defaults to Jikan. Set to nil to disable.
  @ObservationIgnored var episodeFlagsLookup: ((Media, EpisodeRef) async -> PlayerEpisodeFlags?)? = { media, episode in
    await PlayerEpisodeFlagsLookup.jikan(media: media, episode: episode)
  }
  /// Close the player when PlayerView disappears without being minimized to Picture in Picture.
  @ObservationIgnored var closesWhenViewDisappears = true

  // MARK: - Observable state

  private(set) var session: PlaybackSession
  private(set) var episodeList: [EpisodeInfo]
  private(set) var phase: PlayerPhase = .loading
  private(set) var isPlaying = false
  private(set) var isBuffering = true
  private(set) var hasEnded = false
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  private(set) var bufferedTime: Double = 0
  private(set) var playbackRate: Float = 1
  private(set) var isMuted = false
  private(set) var isScrubbing = false
  private(set) var scrubTime: Double = 0
  private(set) var scrubPreview: UIImage?
  private(set) var audioTracks: [PlayerTrackOption] = []
  private(set) var selectedAudioTrack: Int?
  private(set) var embeddedSubtitleTracks: [PlayerTrackOption] = []
  private(set) var externalSubtitleTracks: [PlayerExternalSubtitleTrack] = []
  private(set) var subtitleChoice: PlayerSubtitleChoice = .off
  /// Seconds added to the video time for external subtitles (JASSUB timeOffset / "Subtitle Offset").
  private(set) var subtitleDelay: Double = 0
  private(set) var activeSubtitleCues: [PlayerSubtitleCue] = []
  private(set) var chapters: [PlayerChapter] = []
  /// Name of the skippable chapter being played ("Opening", "Ending"...), drives the "Skip ..." button.
  private(set) var currentSkippable: String?
  /// The autocomplete threshold was reached for this episode.
  private(set) var completed = false
  private(set) var isPictureInPictureActive = false
  private(set) var isPictureInPicturePossible = false
  /// "Toggle Video Cover" (fitWidth): aspect fill instead of aspect fit.
  private(set) var videoFill = false
  private(set) var notice: PlayerNotice?
  /// "Filler" / "Recap" while the skip prompt is shown.
  private(set) var fillerPrompt: String?
  /// Natural size of the video (presentationSize), used to map ASS script coordinates to the video rect.
  private(set) var videoSize: CGSize = .zero
  /// The app shows a sheet over the player (media details).
  private(set) var isExternalOverlayPresented = false
  /// Episode being loaded through `loadEpisode`.
  private(set) var loadingEpisode: EpisodeRef?
  private(set) var stats: [PlayerStatLine]?
  /// "Up next" card: the end credits / preview of the episode play, autoplay is on and there is a next episode.
  private(set) var upNext: PlayerUpNext?
  /// A saved position was restored when the episode loaded: the card offering to start over instead.
  private(set) var resumeChoice: PlayerResumeChoice?
  /// Hold to speed up (PlayerHoldSpeed.swift): the rate playing while the video or Space is held, nil otherwise.
  var holdSpeedRate: Float?
  @ObservationIgnored var holdSpeedState = PlayerHoldSpeedState()

  // MARK: - AVFoundation and internals

  let player = AVPlayer()
  let layerView = PlayerLayerUIView()
  private let nowPlaying = PlayerNowPlaying()
  private let pip = PlayerPiPCoordinator()

  private enum PendingSeek {
    /// Saved progress: resume 5 s earlier (loadAnimeProgress).
    case restore(Double)
    /// Server switch / reload: same position.
    case exact(Double)
  }

  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var playerCancellables = Set<AnyCancellable>()
  @ObservationIgnored private var itemCancellables = Set<AnyCancellable>()
  @ObservationIgnored private var appCancellables = Set<AnyCancellable>()
  @ObservationIgnored private var currentAsset: AVURLAsset?
  @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
  @ObservationIgnored private var imageGenerator: AVAssetImageGenerator?
  @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
  @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
  @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
  @ObservationIgnored private var legibleOptions: [AVMediaSelectionOption] = []
  @ObservationIgnored private var didStart = false
  @ObservationIgnored private var isClosed = false
  @ObservationIgnored private var isMinimized = false
  @ObservationIgnored private var wantsMinimizeOnPiPStart = false
  @ObservationIgnored private var pipStarting = false
  @ObservationIgnored private var restoringFromPiP = false
  /// PiP stopped by `stopPictureInPictureForRestore()`: the app presents the player UI itself.
  @ObservationIgnored private var restoreHandledByApp = false
  @ObservationIgnored private var itemGeneration = 0
  @ObservationIgnored private var episodeGeneration = 0
  @ObservationIgnored private var everReady = false
  @ObservationIgnored private var isFreshEpisodeLoad = true
  @ObservationIgnored private var triedServers = Set<Int>()
  @ObservationIgnored private var pendingSeek: PendingSeek?
  @ObservationIgnored private var resumePlaybackAfterLoad = false
  @ObservationIgnored private var flagsTask: Task<PlayerEpisodeFlags?, Never>?
  @ObservationIgnored private var bufferingTask: Task<Void, Never>?
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var statsTask: Task<Void, Never>?
  /// "Automatic Online Subtitles" of the current episode (PlayerOnlineSubtitles.swift).
  @ObservationIgnored var onlineSubtitlesTask: Task<Void, Never>?
  @ObservationIgnored private var lastProgressSave = Date.distantPast
  @ObservationIgnored private var lastSyncedState: (paused: Bool, time: Double)?
  @ObservationIgnored private var suppressSyncUntil = Date.distantPast
  @ObservationIgnored private var pendingRemoteState: (paused: Bool, time: Double)?
  @ObservationIgnored private var autoplayHandledByRemote = false
  @ObservationIgnored private var userChoseSubtitle = false
  @ObservationIgnored private var autoSkippedChapterStart: Double?
  @ObservationIgnored private var nextExternalTrackID = 0
  @ObservationIgnored private var seekInFlight = false
  @ObservationIgnored private var chaseTarget: Double = 0
  @ObservationIgnored private var chasePrecise = true
  @ObservationIgnored private var seekCompletions: [() -> Void] = []
  @ObservationIgnored private var pausedByBackground = false
  /// Position when the seekbar drag started (Watch Together seek distance).
  @ObservationIgnored private var scrubOrigin: Double?
  @ObservationIgnored private var detachedForBackground = false
  @ObservationIgnored private var playingBeforeResign = false
  @ObservationIgnored private var interruptedWhilePlaying = false
  /// HLS seekbar thumbnails: small frames copied from the video output while playing, by time bucket.
  @ObservationIgnored private var thumbnailCache: [Int: CGImage] = [:]
  @ObservationIgnored private var lastThumbnailCapture = Date.distantPast
  /// Last frame copied from the video output (screenshot fallback when the output has no new buffer).
  @ObservationIgnored private var lastVideoFrame: (buffer: CVPixelBuffer, time: Double)?
  /// Scrub previews the image generator failed to make in a row (3: the asset is a stream, cached frames instead).
  @ObservationIgnored private var previewFailures = 0
  /// Episode generation whose autoplay was decided (filler prompt or play), see `startAutoPlay`.
  @ObservationIgnored private var autoPlayDecidedGeneration = -1
  /// Episode generation whose "Up next" card was answered (played or cancelled): not shown again.
  @ObservationIgnored private var upNextDoneGeneration = -1

  /// Playback speeds offered in the speed menu ([ and ] change it by 0.1 like the Svelte keybinds).
  static let speedOptions: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
  /// Watch Together: only seek to a remote time farther than this (times are floored to the second).
  static let remoteSeekThreshold: Double = 1.5
  /// Watch Together v2: same for exact times (v2 `player` events, host snap-back, auto-sync, countdown).
  static let syncSeekThreshold: Double = 0.25
  /// Watch Together v2: a local seek shorter than this is a player fix-up, not a user action.
  static let syncSeekMinimum: Double = 0.5
  /// HLS thumbnails: one frame per bucket of this many seconds, at most `thumbnailLimit` frames (~20 MB).
  private static let thumbnailInterval: Double = 6
  private static let thumbnailLimit = 240
  private static let thumbnailSize = CGSize(width: 192, height: 108)
  private static let ciContext = CIContext()
  /// Longest wait for the filler/recap lookup before autoplay (a slow Jikan must not hold the episode).
  private static let flagsLookupTimeout: UInt64 = 3_000_000_000
  /// "Up next" countdown, in seconds of playback (it waits while paused).
  static let upNextCountdown: Double = 10
  /// Saved positions under this are not resumed (PC playerstate.js MIN_RESUME_S): the episode starts over.
  static let minResumeTime: Double = 10

  init(session: PlaybackSession, episodeList: [EpisodeInfo] = []) {
    self.session = session
    self.episodeList = episodeList
    // Playback speed kept between episodes (PlayerPage.svelte keeps `playbackRate`).
    self.playbackRate = PlayerPreferences.playbackRate
    configurePlayer()
  }

  private func configurePlayer() {
    player.automaticallyWaitsToMinimizeStalling = true
    player.appliesMediaSelectionCriteriaAutomatically = false
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    let storedVolume = AppSettings.shared.values.volume
    player.volume = Float(min(max(storedVolume.isFinite ? storedVolume : 1, 0), 1))
    layerView.playerLayer.player = player
    layerView.playerLayer.videoGravity = .resizeAspect
  }

  // MARK: - Derived values

  var activeServerIndex: Int { session.selectedServer }

  /// "safeduration": the duration when known, else the current time.
  var safeDuration: Double {
    duration.isFinite && duration > 0 ? duration : max(currentTime, 0)
  }

  /// Time shown by the UI (scrub position while dragging).
  var displayTime: Double { isScrubbing ? scrubTime : currentTime }

  var failure: PlayerFailure? {
    if case .failed(let value) = phase { return value }
    return nil
  }

  var isReady: Bool { phase == .ready }
  var isLoadingEpisode: Bool { loadingEpisode != nil }
  /// The video goes on while the app is in the background: playing (audio, "Pause On Lost Focus" off), in
  /// Picture in Picture or on AirPlay (Discord keeps its presence then).
  var continuesInBackground: Bool {
    !isClosed && (isPlaying || isPictureInPictureActive || player.isExternalPlaybackActive)
  }
  var canTryNextServer: Bool { session.servers.count > 1 }
  var canOpenDetails: Bool { onOpenDetails != nil }
  /// The app can show the in-app miniplayer (`minimize()`).
  var canMinimize: Bool { onMinimize != nil }
  var canLoadEpisodes: Bool { loadEpisode != nil }
  var isPictureInPictureSupported: Bool { PlayerPiPCoordinator.isSupported }

  var displayTitle: String {
    session.media.title.display(AppSettings.shared.values.titleLang)
  }

  /// Episode title, with MediaHandler's "The Movie" fallback.
  var episodeTitle: String? {
    let media = session.media
    if let title = PlayerText.cleanedTitle(session.episodeTitle) {
      let lower = title.lowercased()
      if media.episodes == 1 && (lower == "web" || lower.contains(" web") || lower.contains("web ") || lower.contains("movie")) {
        return "The Movie"
      }
      return title
    }
    if media.isMovie && (media.episodes ?? 0) <= 1 { return "The Movie" }
    return nil
  }

  /// Second line of the title block: "Episode 3 of 12 - Title" (PlayerPage.svelte top bar).
  var episodeLine: String? {
    let media = session.media
    let episode = session.episode
    let title = episodeTitle
    let mentionsNumber = title.map { PlayerText.containsStandalone(number: episode.number, in: $0) } ?? false
    var line = ""
    if media.episodes != 1 && !media.isMovie && !mentionsNumber {
      if let season = episode.season, let local = episode.localEpisode {
        line = "Season \(season) · Episode \(local)"
      } else {
        line = "Episode \(episode.number)"
        // A zero episode is counted by AniList: "of N" leaves it out (PlayerPage.svelte maxEpisodes).
        let maxEpisodes = PlayerEpisodeMath.maxEpisode(media) - (hasZeroEpisode ? 1 : 0)
        if maxEpisodes > 1 {
          line += " of \(maxEpisodes)"
        } else if maxEpisodes == 0 && episodeList.count > 1 {
          line += " of \(episodeList.count)"
        }
      }
    }
    if let title {
      if !line.isEmpty { line += " - " }
      line += title
    }
    return line.isEmpty ? nil : line
  }

  /// Seekbar accent: completed, or already counted in the list progress (episode 0 counts as one).
  var isEpisodeWatched: Bool {
    if completed { return true }
    guard let progress = session.media.listEntry?.progress else { return false }
    return progress - (hasZeroEpisode ? 1 : 0) >= session.episode.number
  }

  /// MediaHandler `zeroEpisode` (checkForZero): the media has an episode 0, from the session or the episode list.
  var hasZeroEpisode: Bool {
    session.zeroEpisode ?? episodeList.contains { $0.number == 0 }
  }

  var currentEpisodeIndex: Int? {
    let episode = session.episode
    return episodeList.firstIndex { info in
      if let season = episode.season, let local = episode.localEpisode,
         let infoSeason = info.season, let infoLocal = info.localEpisode {
        return season == infoSeason && local == infoLocal
      }
      return info.number == episode.number
    }
  }

  func isCurrent(_ info: EpisodeInfo) -> Bool {
    guard let index = currentEpisodeIndex, episodeList.indices.contains(index) else {
      return info.number == session.episode.number
    }
    return episodeList[index].id == info.id
  }

  /// checkAvail (hasNext) using the media episode counts when no episode list is available.
  private var mediaHasNext: Bool {
    let media = session.media
    // A Sora module result played as it is only has the episodes its module listed (the episode list).
    if media.isSoraResult { return false }
    if media.isMovie && (media.episodes ?? 1) <= 1 { return false }
    let aired = (media.nextAiring?.episode ?? 0) - 1
    let available = aired > 0 ? aired : PlayerEpisodeMath.maxEpisode(media)
    if available - (hasZeroEpisode ? 1 : 0) > session.episode.number { return true }
    return media.nextAiring == nil && media.episodes == nil
  }

  var nextEpisodeRef: EpisodeRef? {
    if let index = currentEpisodeIndex {
      return episodeList.indices.contains(index + 1) ? episodeList[index + 1].ref : nil
    }
    guard mediaHasNext else { return nil }
    let episode = session.episode
    return EpisodeRef(number: episode.number + 1, season: episode.season, localEpisode: episode.localEpisode.map { $0 + 1 })
  }

  var previousEpisodeRef: EpisodeRef? {
    if let index = currentEpisodeIndex {
      return index > 0 && episodeList.indices.contains(index - 1) ? episodeList[index - 1].ref : nil
    }
    let episode = session.episode
    // Episode 1 goes back to episode 0 when the media has one (checkAvail hasLast).
    guard episode.number > 1 || (hasZeroEpisode && episode.number == 1) else { return nil }
    var local: Int?
    if let value = episode.localEpisode, value > 1 { local = value - 1 }
    return EpisodeRef(number: episode.number - 1, season: local == nil ? nil : episode.season, localEpisode: local)
  }

  var hasNext: Bool { nextEpisodeRef != nil }
  var hasLast: Bool { previousEpisodeRef != nil }

  func serverName(_ index: Int) -> String {
    guard session.servers.indices.contains(index) else { return "Server \(index + 1)" }
    let title = session.servers[index].title.trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? "Server \(index + 1)" : title
  }

  var scrubberSegments: [PlayerScrubberSegment] {
    let total = safeDuration
    guard total > 0, chapters.count > 1 else { return [] }
    return chapters.compactMap { chapter in
      guard chapter.start < total else { return nil }
      let start = max(0, chapter.start / total)
      let end = min(1, chapter.end / total)
      guard end > start else { return nil }
      return PlayerScrubberSegment(start: start, end: end, skippable: PlayerChapterLogic.skippableName(chapter) != nil)
    }
  }

  func chapterTitle(at time: Double) -> String? {
    guard chapters.count > 1, let index = chapters.firstIndex(where: { time >= $0.start && time < $0.end }) else { return nil }
    let names = PlayerChapterLogic.displayNames(chapters)
    return names.indices.contains(index) ? names[index] : nil
  }

  func subtitleName(for choice: PlayerSubtitleChoice) -> String? {
    switch choice {
    case .off:
      return nil
    case .embedded(let index):
      return embeddedSubtitleTracks.indices.contains(index) ? embeddedSubtitleTracks[index].name : nil
    case .external(let id):
      return externalSubtitleTracks.first { $0.id == id }?.name
    }
  }

  // MARK: - Lifecycle

  /// Starts playback once (called by PlayerView.onAppear).
  func startIfNeeded() {
    guard !didStart, !isClosed else { return }
    didStart = true
    PlayerAudioSession.activate()
    installPlayerObservers()
    installAppObservers()
    installRemoteCommands()
    configurePictureInPicture()
    begin(session)
  }

  func viewDidAppear() {
    isMinimized = false
    startIfNeeded()
  }

  func viewDidDisappear() {
    guard closesWhenViewDisappears, didStart, !isClosed, !isMinimized, !isPictureInPictureActive,
          !pipStarting, !wantsMinimizeOnPiPStart else { return }
    close()
  }

  /// Attaches the video layer to a container (PlayerVideoSurface).
  func mountVideoView(in container: UIView) {
    if layerView.superview !== container {
      layerView.removeFromSuperview()
      layerView.frame = container.bounds
      layerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(layerView)
    }
    if !detachedForBackground && !isClosed {
      layerView.playerLayer.player = player
    }
  }

  /// closePlayer: stops playback, leaves Picture in Picture and reports the last position.
  func close() {
    guard !isClosed else { return }
    if everReady { saveProgress(force: true) }
    isClosed = true
    if isPictureInPictureActive { pip.stop() }
    tearDown()
    onClose?()
  }

  private func tearDown() {
    cancelHoldSpeed()
    player.pause()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
    playerCancellables.removeAll()
    itemCancellables.removeAll()
    appCancellables.removeAll()
    bufferingTask?.cancel()
    noticeTask?.cancel()
    previewTask?.cancel()
    statsTask?.cancel()
    flagsTask?.cancel()
    onlineSubtitlesTask?.cancel()
    statsTask = nil
    player.replaceCurrentItem(with: nil)
    layerView.playerLayer.player = nil
    thumbnailCache = [:]
    lastVideoFrame = nil
    nowPlaying.clear()
    pip.detach()
    UIApplication.shared.isIdleTimerDisabled = false
    PlayerAudioSession.deactivate()
  }

  /// Call with true when the app shows something over the player (media details), false after. Playback goes
  /// on like in the Svelte app (navigation.js never sets `playPage`, so details do not pause the player); the
  /// player view restores its keyboard focus when the overlay closes.
  func setExternalOverlay(presented: Bool) {
    if isExternalOverlayPresented != presented {
      isExternalOverlayPresented = presented
    }
  }

  /// Episode list loaded after the player opened: MediaHandler fills the episode title once the episode data
  /// arrives, so the missing title is taken from the list and Now Playing is refreshed.
  func setEpisodeList(_ list: [EpisodeInfo]) {
    episodeList = list
    if PlayerText.cleanedTitle(session.episodeTitle) == nil, let index = currentEpisodeIndex,
       list.indices.contains(index), let title = PlayerText.cleanedTitle(list[index].title) {
      session.episodeTitle = title
    }
    refreshRemoteCommandAvailability()
    updateNowPlayingMetadata()
  }

  func openDetails() {
    onOpenDetails?(session.media)
  }

  // MARK: - Loading

  private func begin(_ newSession: PlaybackSession) {
    episodeGeneration += 1
    session = newSession
    completed = false
    chapters = []
    currentSkippable = nil
    autoSkippedChapterStart = nil
    fillerPrompt = nil
    externalSubtitleTracks = []
    embeddedSubtitleTracks = []
    audioTracks = []
    selectedAudioTrack = nil
    subtitleChoice = .off
    activeSubtitleCues = []
    userChoseSubtitle = false
    // Subtitle offset remembered for this show (the same release usually needs the same offset).
    subtitleDelay = PlayerPreferences.subtitleOffset(for: newSession.media.id)
    upNext = nil
    resumeChoice = nil
    // A play state from before this episode must not resume it after an interruption.
    playingBeforeResign = false
    autoplayHandledByRemote = pendingRemoteState != nil
    currentTime = 0
    duration = 0
    bufferedTime = 0
    hasEnded = false
    triedServers = []
    isFreshEpisodeLoad = true
    resumePlaybackAfterLoad = false
    pendingSeek = nil
    // Less than 10 s watched: start from the beginning (no "Resumed at 0:02" card), like PC.
    if let resume = newSession.startTime ?? resumePosition?(newSession.media, newSession.episode),
       resume.isFinite, resume >= PlayerController.minResumeTime {
      pendingSeek = .restore(resume)
    }
    startFlagsLookup(for: newSession)
    thumbnailCache = [:]
    lastVideoFrame = nil

    if newSession.servers.isEmpty {
      itemGeneration += 1
      tearDownItem()
      player.replaceCurrentItem(with: nil)
      phase = .failed(.noServers)
      setBuffering(false)
    } else {
      let index = newSession.servers.indices.contains(newSession.selectedServer) ? newSession.selectedServer : 0
      loadServer(index)
    }
    if let subtitleURL = newSession.subtitleURL {
      let headers = newSession.subtitleHeaders ?? newSession.currentServer?.headers ?? [:]
      loadExternalSubtitle(from: subtitleURL, headers: headers, name: "Subtitles")
    }
    scheduleAutomaticOnlineSubtitles()
    updateNowPlayingMetadata()
    onEpisodeStarted?(newSession)
  }

  private func startFlagsLookup(for newSession: PlaybackSession) {
    flagsTask?.cancel()
    flagsTask = nil
    if newSession.isFiller != nil || newSession.isRecap != nil {
      let flags = PlayerEpisodeFlags(isFiller: newSession.isFiller ?? false, isRecap: newSession.isRecap ?? false)
      flagsTask = Task<PlayerEpisodeFlags?, Never> { flags }
      return
    }
    let listedAsFiller = episodeList.contains { $0.number == newSession.episode.number && $0.isFiller }
    if listedAsFiller {
      flagsTask = Task<PlayerEpisodeFlags?, Never> { PlayerEpisodeFlags(isFiller: true, isRecap: false) }
      return
    }
    guard let lookup = episodeFlagsLookup else { return }
    let media = newSession.media
    let episode = newSession.episode
    flagsTask = Task<PlayerEpisodeFlags?, Never> { await lookup(media, episode) }
  }

  private func loadServer(_ index: Int) {
    guard session.servers.indices.contains(index) else { return }
    itemGeneration += 1
    let generation = itemGeneration
    session.selectedServer = index
    triedServers.insert(index)
    tearDownItem()
    phase = .loading
    everReady = false
    hasEnded = false
    setBuffering(true, immediate: true)

    let server = session.servers[index]
    let asset = AVURLAsset(url: server.url, options: PlayerController.assetOptions(for: server.headers))
    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    item.add(output)
    currentAsset = asset
    videoOutput = output
    // Streams have no AVAssetImageGenerator support: their previews come from frames cached while playing.
    // Decided from the URL first, then from the asset once loaded (checkPreviewSource) for a stream whose URL
    // doesn't say so (proxy URL, downloaded .movpkg).
    imageGenerator = PlayerController.isStream(server.url) ? nil : PlayerController.makeImageGenerator(asset)
    observe(item, generation: generation)
    player.replaceCurrentItem(with: item)
    player.defaultRate = playbackRate
    updateNowPlayingPlayback()
  }

  private func tearDownItem() {
    itemCancellables.removeAll()
    previewTask?.cancel()
    previewTask = nil
    scrubPreview = nil
    audioGroup = nil
    audioOptions = []
    legibleGroup = nil
    legibleOptions = []
    currentAsset = nil
    videoOutput = nil
    imageGenerator = nil
    previewFailures = 0
    seekInFlight = false
    seekCompletions = []
    isScrubbing = false
  }

  /// Stream headers (Referer, Origin, User-Agent...) on every request of the asset: replaces the Electron
  /// proxy of common/modules/streaming.js.
  private static func assetOptions(for headers: [String: String]) -> [String: Any] {
    var options: [String: Any] = [:]
    guard !headers.isEmpty else { return options }
    options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
      options[AVURLAssetHTTPUserAgentKey] = agent
    }
    return options
  }

  /// HLS by its URL: a playlist, or a downloaded HLS package (.movpkg).
  private static func isStream(_ url: URL) -> Bool {
    let text = url.absoluteString.lowercased()
    return text.contains(".m3u8") || text.contains("mpegurl") || url.pathExtension.lowercased() == "movpkg"
  }

  /// An HLS asset lists no track of its own (they belong to the player item): the image generator can't make
  /// frames of it, the cached frames are used.
  private func checkPreviewSource(generation: Int) async {
    guard imageGenerator != nil, let asset = currentAsset else { return }
    let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
    guard generation == itemGeneration, !isClosed, tracks.isEmpty else { return }
    imageGenerator = nil
  }

  private static func makeImageGenerator(_ asset: AVAsset) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 180)
    let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    return generator
  }

  private func observe(_ item: AVPlayerItem, generation: Int) {
    item.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        self?.handleItemStatus(status, generation: generation)
      }
      .store(in: &itemCancellables)
    item.publisher(for: \.duration)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.updateDuration(value, generation: generation)
      }
      .store(in: &itemCancellables)
    item.publisher(for: \.loadedTimeRanges)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] ranges in
        self?.updateBuffered(ranges, generation: generation)
      }
      .store(in: &itemCancellables)
    item.publisher(for: \.presentationSize)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] size in
        self?.updateVideoSize(size, generation: generation)
      }
      .store(in: &itemCancellables)
    NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.handleEnded(generation: generation)
      }
      .store(in: &itemCancellables)
    NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
      .map { $0.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        self?.handleFailure(error, generation: generation)
      }
      .store(in: &itemCancellables)
  }

  private func installPlayerObservers() {
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      MainActor.assumeIsolated {
        self?.handleTick(time)
      }
    }
    player.publisher(for: \.timeControlStatus)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        self?.handleTimeControlStatus(status)
      }
      .store(in: &playerCancellables)
  }

  private func installAppObservers() {
    let center = NotificationCenter.default
    center.publisher(for: UIApplication.willResignActiveNotification)
      .sink { [weak self] _ in
        self?.handleWillResignActive()
      }
      .store(in: &appCancellables)
    center.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in
        self?.handleDidEnterBackground()
      }
      .store(in: &appCancellables)
    center.publisher(for: UIApplication.willEnterForegroundNotification)
      .sink { [weak self] _ in
        self?.handleWillEnterForeground()
      }
      .store(in: &appCancellables)
    center.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        // Only meaningful between resigning and the background / interruption that follows: a stale value
        // would resume a video paused since then after the next interruption.
        self?.playingBeforeResign = false
      }
      .store(in: &appCancellables)
    center.publisher(for: AVAudioSession.interruptionNotification)
      .map { note -> (type: UInt?, options: UInt?) in
        (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
         note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
      }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] values in
        self?.handleInterruption(type: values.type, options: values.options)
      }
      .store(in: &appCancellables)
  }

  private func configurePictureInPicture() {
    pip.onPossibleChanged = { [weak self] possible in
      self?.isPictureInPicturePossible = possible
    }
    pip.onWillStart = { [weak self] in
      self?.pipStarting = true
    }
    pip.onDidStart = { [weak self] in
      self?.pictureInPictureDidStart()
    }
    pip.onDidStop = { [weak self] in
      self?.pictureInPictureDidStop()
    }
    pip.onFailed = { [weak self] message in
      self?.pictureInPictureFailed(message)
    }
    pip.onRestore = { [weak self] in
      self?.pictureInPictureRestore()
    }
    pip.attach(to: layerView.playerLayer, autoStart: PlayerPreferences.autoPictureInPicture)
  }

  // MARK: - Item events

  private func handleItemStatus(_ status: AVPlayerItem.Status, generation: Int) {
    guard generation == itemGeneration, !isClosed else { return }
    switch status {
    case .readyToPlay:
      handleReady(generation: generation)
    case .failed:
      handleFailure(player.currentItem?.error as NSError?, generation: generation)
    default:
      break
    }
  }

  private func handleReady(generation: Int) {
    guard !everReady else { return }
    everReady = true
    phase = .ready
    if let item = player.currentItem {
      updateDuration(item.duration, generation: generation)
    }
    setBuffering(false)
    Task { [weak self] in
      await self?.loadMediaSelection(generation: generation)
      await self?.checkPreviewSource(generation: generation)
    }
    let fresh = isFreshEpisodeLoad
    isFreshEpisodeLoad = false
    applyPendingSeek()
    if fresh {
      loadChapters()
      startAutoPlay()
    } else if resumePlaybackAfterLoad {
      resumePlaybackAfterLoad = false
      // Reloading the stream is not a user action for Watch Together.
      suppressSyncUntil = max(suppressSyncUntil, Date().addingTimeInterval(1))
      player.play()
    }
    if let remote = pendingRemoteState {
      pendingRemoteState = nil
      applyRemoteState(paused: remote.paused, time: remote.time)
    } else {
      onSyncReady?()
    }
    updateNowPlayingPlayback()
  }

  private func applyPendingSeek() {
    guard let pending = pendingSeek else { return }
    pendingSeek = nil
    let total = safeDuration
    var target: Double
    var restored = false
    switch pending {
    case .restore(let time):
      // Load 5 seconds before. An episode watched past the completion threshold (or its last 3%) starts over
      // instead of resuming near its end (autoplay would then jump to the next episode at once).
      target = max(time - 5, 0)
      if total > 0 && time >= total * PlayerController.resumeLimit { target = 0 }
      restored = true
    case .exact(let time):
      target = time
    }
    guard target > 0 else { return }
    performSeek(to: target) { [weak self] in
      // Loading a file (resume position) is not a user action for Watch Together.
      self?.emitLocalState(announce: false)
    }
    // "Resumed at 12:34 · Start Over" (not in Watch Together: the lobby decides the position there).
    if restored && !(isWatchTogetherActive?() ?? false) {
      resumeChoice = PlayerResumeChoice(time: target)
    }
  }

  /// Share of the episode past which a saved position is not resumed: the completion threshold
  /// (playerAutocompleteThreshold), kept between 50% and 97%.
  static var resumeLimit: Double {
    let threshold = Double(AppSettings.shared.values.playerAutocompleteThreshold) / 100
    return min(max(threshold.isFinite ? threshold : 0.97, 0.5), 0.97)
  }

  /// "Start Over" of the resume card.
  func startOver() {
    resumeChoice = nil
    seek(to: 0)
  }

  /// "Resume" (keep the restored position) or the card timing out.
  func dismissResumeChoice(_ id: UUID? = nil) {
    if id == nil || resumeChoice?.id == id { resumeChoice = nil }
  }

  /// autoPlay + promptFiller: plays unless the episode is a filler/recap (then asks first). The filler/recap
  /// lookup is waited for at most `flagsLookupTimeout`: past it the episode plays (a late answer is ignored).
  private func startAutoPlay() {
    let generation = episodeGeneration
    let task = flagsTask
    Task { [weak self] in
      let flags = await task?.value
      self?.decideAutoPlay(flags, generation: generation)
    }
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: PlayerController.flagsLookupTimeout)
      self?.decideAutoPlay(nil, generation: generation)
    }
  }

  /// First of the lookup answer and its timeout, once per episode.
  private func decideAutoPlay(_ flags: PlayerEpisodeFlags?, generation: Int) {
    guard generation == episodeGeneration, autoPlayDecidedGeneration != generation, !isClosed else { return }
    autoPlayDecidedGeneration = generation
    // A Watch Together state was applied: the lobby decides (no filler prompt pausing the others).
    if autoplayHandledByRemote { return }
    if let label = flags?.promptLabel {
      fillerPrompt = label
      player.pause()
      return
    }
    // Autoplay is not a user action for Watch Together.
    suppressSyncUntil = max(suppressSyncUntil, Date().addingTimeInterval(1))
    player.play()
  }

  private func handleFailure(_ error: NSError?, generation: Int) {
    guard generation == itemGeneration, !isClosed else { return }
    if failure != nil { return }
    let reason = PlayerFailure.from(error)
    if everReady { saveProgress(force: true) }
    setBuffering(false)
    if !everReady, let next = nextUntriedServer() {
      showNotice("\(serverName(activeServerIndex)) failed", "Trying \(serverName(next))…", isError: true)
      loadServer(next)
      return
    }
    if everReady, currentTime > 0, pendingSeek == nil {
      pendingSeek = .exact(currentTime)
    }
    phase = .failed(reason)
  }

  private func nextUntriedServer() -> Int? {
    let count = session.servers.count
    guard count > 1 else { return nil }
    for offset in 1..<count {
      let index = (activeServerIndex + offset) % count
      if !triedServers.contains(index) { return index }
    }
    return nil
  }

  private func handleEnded(generation: Int) {
    guard generation == itemGeneration, !isClosed else { return }
    hasEnded = true
    if duration.isFinite && duration > 0 { currentTime = duration }
    checkCompletion()
    saveProgress(force: true)
    currentSkippable = nil
    upNext = nil
    updateNowPlayingPlayback()
    onPlaybackEnded?(session.media, session.episode)
    let watchingTogether = isWatchTogetherActive?() ?? false
    if autoplaysNextEpisode && !watchingTogether && hasNext {
      Task { [weak self] in
        await self?.playNext()
      }
    }
  }

  private func updateDuration(_ value: CMTime, generation: Int) {
    guard generation == itemGeneration else { return }
    let seconds = value.seconds
    let newValue = seconds.isFinite && seconds > 0 ? seconds : 0
    guard newValue != duration else { return }
    duration = newValue
    updateNowPlayingPlayback()
  }

  private func updateVideoSize(_ size: CGSize, generation: Int) {
    guard generation == itemGeneration, size.width > 0, size.height > 0, size != videoSize else { return }
    videoSize = size
  }

  private func updateBuffered(_ ranges: [NSValue], generation: Int) {
    guard generation == itemGeneration else { return }
    let position = currentTime
    var containing: Double = 0
    var furthest: Double = 0
    for value in ranges {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = range.end.seconds
      guard start.isFinite, end.isFinite else { continue }
      furthest = max(furthest, end)
      if position >= start - 0.5 && position <= end { containing = max(containing, end) }
    }
    bufferedTime = containing > 0 ? containing : furthest
  }

  private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
    guard !isClosed else { return }
    let playing = status != .paused
    // Paused or ended while held: back to the normal rate (the release then does nothing more).
    if !playing { stopHoldSpeed(pause: false) }
    if playing != isPlaying {
      isPlaying = playing
      if playing {
        hasEnded = false
        fillerPrompt = nil
      }
      UIApplication.shared.isIdleTimerDisabled = playing
      emitLocalState()
      updateNowPlayingPlayback()
    }
    switch status {
    case .waitingToPlayAtSpecifiedRate:
      if phase == .ready { setBuffering(true) }
    case .playing:
      setBuffering(false)
    case .paused:
      if phase == .ready { setBuffering(false) }
    @unknown default:
      break
    }
  }

  private func setBuffering(_ value: Bool, immediate: Bool = false) {
    bufferingTask?.cancel()
    bufferingTask = nil
    guard value else {
      if isBuffering { isBuffering = false }
      return
    }
    if immediate || isBuffering {
      isBuffering = true
      return
    }
    // showBuffering: only show the spinner after 150 ms.
    bufferingTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      self?.isBuffering = true
    }
  }

  private func handleTick(_ time: CMTime) {
    guard !isClosed else { return }
    let seconds = time.seconds
    guard seconds.isFinite else { return }
    if !isScrubbing && !seekInFlight {
      currentTime = max(seconds, 0)
    }
    refreshSubtitleCues()
    guard isPlaying, phase == .ready else { return }
    checkSkippableChapters()
    updateUpNext()
    checkCompletion()
    if Date().timeIntervalSince(lastProgressSave) >= 10 {
      saveProgress()
    }
    captureThumbnailIfNeeded()
  }

  /// timeupdate runs checkSkippableChapters / checkCompletion even while paused: same after a seek.
  private func runTimeChecks() {
    guard phase == .ready, !isClosed else { return }
    checkSkippableChapters()
    updateUpNext()
    checkCompletion()
  }

  // MARK: - App state

  private func handleWillResignActive() {
    // A seekbar drag the system interrupts (Control Center, a call) never ends by itself: it ends where it is.
    finishScrubbing()
    // A hold started on a paused video pauses it again: it was not playing for the background rules.
    let pausedByHold = cancelHoldSpeed()
    playingBeforeResign = isPlaying && !pausedByHold
    // Picks up a change of the "Auto Picture in Picture" setting made while this player was open.
    pip.attach(to: layerView.playerLayer, autoStart: PlayerPreferences.autoPictureInPicture)
  }

  /// handleVisibility: pause when leaving the app if playerPause is on (unless PiP/AirPlay); otherwise keep
  /// the audio playing by detaching the video layer (AVPlayer pauses video-attached players in background).
  private func handleDidEnterBackground() {
    guard didStart, !isClosed else { return }
    if everReady { saveProgress(force: true) }
    if isPictureInPictureActive || pipStarting || player.isExternalPlaybackActive { return }
    let wasPlaying = isPlaying || playingBeforeResign
    if AppSettings.shared.values.playerPause {
      pausedByBackground = wasPlaying
      if isPlaying { player.pause() }
    } else {
      layerView.playerLayer.player = nil
      detachedForBackground = true
      if wasPlaying { player.play() }
    }
  }

  private func handleWillEnterForeground() {
    guard didStart, !isClosed else { return }
    if detachedForBackground {
      detachedForBackground = false
      layerView.playerLayer.player = player
    }
    if pausedByBackground {
      pausedByBackground = false
      player.play()
    }
  }

  private func handleInterruption(type: UInt?, options: UInt?) {
    guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
    switch interruption {
    case .began:
      interruptedWhilePlaying = isPlaying || playingBeforeResign
    case .ended:
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume)
      if shouldResume && interruptedWhilePlaying && !isClosed { player.play() }
      interruptedWhilePlaying = false
    @unknown default:
      break
    }
  }

  // MARK: - Playback controls

  func play() {
    guard !isClosed else { return }
    fillerPrompt = nil
    if hasEnded {
      hasEnded = false
      performSeek(to: 0) { [weak self] in
        self?.player.play()
      }
      return
    }
    player.play()
  }

  func pause() {
    player.pause()
  }

  func togglePlayPause() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  func seek(to time: Double) {
    guard everReady, !isClosed else { return }
    let origin = currentTime
    performSeek(to: time) { [weak self] in
      self?.emitLocalState(seekFrom: origin)
      self?.updateNowPlayingPlayback()
      self?.runTimeChecks()
    }
  }

  func seek(by delta: Double) {
    seek(to: currentTime + delta)
  }

  /// forward / rewind: `playerSeek` seconds.
  func forward() {
    seek(by: AppSettings.shared.values.playerSeek)
  }

  func rewind() {
    seek(by: -AppSettings.shared.values.playerSeek)
  }

  func beginScrubbing() {
    guard everReady else { return }
    if !isScrubbing { scrubOrigin = currentTime }
    isScrubbing = true
    scrubTime = currentTime
  }

  func scrub(to time: Double) {
    guard isScrubbing, time.isFinite else { return }
    scrubTime = min(max(time, 0), safeDuration)
    refreshSubtitleCues()
    performSeek(to: scrubTime, precise: false)
    requestPreview(at: scrubTime)
  }

  func endScrubbing(at time: Double) {
    guard isScrubbing else { return }
    let target = time.isFinite ? min(max(time, 0), safeDuration) : scrubTime
    scrubTime = target
    currentTime = target
    previewTask?.cancel()
    previewTask = nil
    scrubPreview = nil
    let origin = scrubOrigin ?? target
    scrubOrigin = nil
    performSeek(to: target, precise: true) { [weak self] in
      guard let self else { return }
      self.isScrubbing = false
      self.emitLocalState(seekFrom: origin)
      self.updateNowPlayingPlayback()
      self.refreshSubtitleCues()
      self.runTimeChecks()
    }
  }

  /// Ends a seekbar drag that was cancelled instead of ended (the gesture was interrupted, the app resigned
  /// active, the seekbar disappeared) at the last scrubbed position, so `isScrubbing` never stays stuck.
  func finishScrubbing() {
    guard isScrubbing else { return }
    endScrubbing(at: scrubTime)
  }

  private func performSeek(to seconds: Double, precise: Bool = true, completion: (() -> Void)? = nil) {
    guard seconds.isFinite else { return }
    let upper = duration > 0 ? duration : max(seconds, 0)
    let target = min(max(seconds, 0), upper)
    chaseTarget = target
    chasePrecise = precise
    if let completion { seekCompletions.append(completion) }
    if !isScrubbing { currentTime = target }
    if target < upper - 0.5 { hasEnded = false }
    if !seekInFlight { runChaseSeek() }
  }

  /// Seeks one at a time and jumps to the latest requested position (smooth scrubbing).
  private func runChaseSeek() {
    seekInFlight = true
    let target = chaseTarget
    let precise = chasePrecise
    let tolerance = precise ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
    let time = CMTime(seconds: target, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.chaseSeekFinished(target: target, precise: precise)
      }
    }
  }

  private func chaseSeekFinished(target: Double, precise: Bool) {
    guard seekInFlight else { return }
    if target != chaseTarget || precise != chasePrecise {
      runChaseSeek()
      return
    }
    seekInFlight = false
    let completions = seekCompletions
    seekCompletions = []
    for completion in completions { completion() }
  }

  private func requestPreview(at time: Double) {
    guard let generator = imageGenerator else {
      // HLS: frames cached while playing (generateThumbnails equivalent for streams).
      scrubPreview = cachedThumbnail(near: time).map { UIImage(cgImage: $0) }
      return
    }
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled else { return }
      let cmTime = CMTime(seconds: time, preferredTimescale: 600)
      do {
        let image = try await generator.image(at: cmTime).image
        guard !Task.isCancelled, let self else { return }
        self.previewFailures = 0
        guard self.isScrubbing else { return }
        self.scrubPreview = UIImage(cgImage: image)
      } catch {
        guard !Task.isCancelled, let self, self.imageGenerator === generator else { return }
        if self.isScrubbing {
          self.scrubPreview = self.cachedThumbnail(near: time).map { UIImage(cgImage: $0) }
        }
        // The asset can't make frames (a stream the URL didn't reveal): the frames cached while playing are
        // used from now on.
        self.previewFailures += 1
        if self.previewFailures >= 3 { self.imageGenerator = nil }
      }
    }
  }

  func setRate(_ rate: Float) {
    guard rate.isFinite else { return }
    let clamped = min(max(rate, 0.1), 4)
    playbackRate = clamped
    PlayerPreferences.playbackRate = clamped
    player.defaultRate = clamped
    if isPlaying { player.rate = clamped }
    updateNowPlayingPlayback()
  }

  /// BracketLeft / BracketRight: playback rate -/+ 0.1.
  func adjustRate(by delta: Float) {
    setRate(((playbackRate + delta) * 10).rounded() / 10)
  }

  static func rateLabel(_ rate: Float) -> String {
    rate == 1 ? "Normal" : String(format: "%gx", Double(rate))
  }

  func toggleMute() {
    player.isMuted.toggle()
    isMuted = player.isMuted
    showNotice(isMuted ? "Muted" : "Unmuted")
  }

  /// ArrowUp / ArrowDown: app volume, persisted in the settings like the Svelte cache entry.
  func adjustVolume(by delta: Double) {
    let value = min(max(Double(player.volume) / duckLevel + delta, 0), 1)
    player.volume = Float(value * duckLevel)
    AppSettings.shared.values.volume = value
    showNotice("Volume \(Int((value * 100).rounded()))%")
  }

  /// Watch Together voice ducking: the video plays at this fraction of the user's volume while someone speaks.
  @ObservationIgnored private var duckLevel: Double = 1

  func setDuck(_ level: Double) {
    let value = min(max(level.isFinite ? level : 1, 0.05), 1)
    guard value != duckLevel else { return }
    let base = Double(player.volume) / duckLevel
    duckLevel = value
    player.volume = Float(min(max(base, 0), 1) * value)
  }

  func setVideoFill(_ fill: Bool) {
    videoFill = fill
    layerView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
  }

  func toggleVideoFill() {
    setVideoFill(!videoFill)
  }

  // MARK: - Servers

  /// switchServer: loads another server and keeps the position.
  func switchServer(to index: Int) {
    guard session.servers.indices.contains(index), index != activeServerIndex || failure != nil else { return }
    if everReady, currentTime > 0, pendingSeek == nil {
      pendingSeek = .exact(currentTime)
    }
    resumePlaybackAfterLoad = !isFreshEpisodeLoad
    loadServer(index)
  }

  func tryNextServer() {
    let count = session.servers.count
    guard count > 1 else { return }
    switchServer(to: (activeServerIndex + 1) % count)
  }

  /// Reloads the current server (the Svelte toast "Dismiss this toast to reload the video").
  func retry() {
    if pendingSeek == nil, currentTime > 0 {
      pendingSeek = .exact(currentTime)
    }
    resumePlaybackAfterLoad = !isFreshEpisodeLoad
    loadServer(activeServerIndex)
  }

  // MARK: - Audio and subtitle tracks

  private func loadMediaSelection(generation: Int) async {
    guard let asset = currentAsset else { return }
    let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
    let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
    guard generation == itemGeneration, !isClosed else { return }
    audioGroup = audible
    audioOptions = PlayerController.playableAudioOptions(audible, asset: asset)
    // Raw names (empty when the stream has none): the menu label and the per-show memory work like PC
    // (audioTrackLabel / pickAudioTrack), "Track N" is only a label.
    audioTracks = audioOptions.enumerated().map { index, option in
      PlayerTrackOption(id: index, name: option.displayName.trimmingCharacters(in: .whitespacesAndNewlines), languageTag: PlayerController.languageTag(option))
    }
    legibleGroup = legible
    legibleOptions = (legible?.options ?? []).filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
    embeddedSubtitleTracks = legibleOptions.enumerated().map { index, option in
      PlayerTrackOption(id: index, name: PlayerController.trackName(option, index: index), languageTag: PlayerController.languageTag(option))
    }
    selectPreferredAudio()
    refreshSelectedAudio()
    if userChoseSubtitle {
      applySubtitleChoice(subtitleChoice)
    } else {
      applySubtitlePreference()
    }
  }

  /// Audio options that can play. A downloaded HLS package (.movpkg) only holds the audio renditions that were
  /// downloaded: the others are left out, so neither the menu nor the remembered track can pick one that is not there.
  private static func playableAudioOptions(_ group: AVMediaSelectionGroup?, asset: AVURLAsset) -> [AVMediaSelectionOption] {
    guard let group else { return [] }
    let options = group.options
    guard asset.url.isFileURL, asset.url.pathExtension.lowercased() == "movpkg", let cache = asset.assetCache else { return options }
    let cached = cache.mediaSelectionOptions(in: group)
    guard !cached.isEmpty else { return options }
    let kept = options.filter { cached.contains($0) }
    return kept.isEmpty ? cached : kept
  }

  private static func trackName(_ option: AVMediaSelectionOption, index: Int) -> String {
    let name = option.displayName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Track \(index + 1)" : name
  }

  private static func languageTag(_ option: AVMediaSelectionOption) -> String? {
    option.extendedLanguageTag ?? option.locale?.identifier
  }

  /// checkAudio, when there are several audio tracks: the track remembered for this show (audio menu), then the
  /// preferred audio language, then Japanese; otherwise the stream's default track stays.
  private func selectPreferredAudio() {
    guard let group = audioGroup, audioOptions.count > 1, let item = player.currentItem else { return }
    let remembered = PlayerPreferences.lastAudio(for: session.media.id)
    let wanted = AppSettings.shared.values.audioLanguage
    if let index = PlayerLanguage.preferredAudioTrack(audioTracks, remembered: remembered, preferred: wanted), audioOptions.indices.contains(index) {
      item.select(audioOptions[index], in: group)
    }
  }

  private func refreshSelectedAudio() {
    guard let group = audioGroup, let item = player.currentItem,
          let selected = item.currentMediaSelection.selectedMediaOption(in: group) else {
      selectedAudioTrack = nil
      return
    }
    selectedAudioTrack = audioOptions.firstIndex(of: selected)
  }

  /// User choice from the audio menu, remembered per show (name and language) like the subtitle choice.
  func selectAudio(_ id: Int) {
    guard let group = audioGroup, audioOptions.indices.contains(id), let item = player.currentItem else { return }
    item.select(audioOptions[id], in: group)
    selectedAudioTrack = id
    if let track = audioTracks.first(where: { $0.id == id }) {
      PlayerPreferences.setLastAudio(PlayerAudioMemory(name: track.name, language: track.languageTag), for: session.media.id)
    }
  }

  /// User choice from the subtitle menu (remembered per media like 'lastSubtitle').
  func selectSubtitle(_ choice: PlayerSubtitleChoice) {
    applySubtitleChoice(choice)
    userChoseSubtitle = true
    PlayerPreferences.setLastSubtitle(subtitleName(for: subtitleChoice) ?? "OFF", for: session.media.id)
  }

  private func applySubtitleChoice(_ choice: PlayerSubtitleChoice) {
    var resolved = choice
    if case .external(let id) = choice, !externalSubtitleTracks.contains(where: { $0.id == id }) {
      resolved = .off
    }
    if let group = legibleGroup, let item = player.currentItem {
      if case .embedded(let index) = choice, legibleOptions.indices.contains(index) {
        item.select(legibleOptions[index], in: group)
      } else {
        if case .embedded = choice { resolved = .off }
        item.select(nil, in: group)
      }
    } else if case .embedded = choice {
      resolved = .off
    }
    subtitleChoice = resolved
    refreshSubtitleCues()
  }

  /// Automatic subtitle choice: remembered track for this media (checkSubtitle), then the Svelte
  /// handleTracks order (single track, preferred language, name match, English, first track).
  private func applySubtitlePreference() {
    guard !userChoseSubtitle else { return }
    var candidates: [(choice: PlayerSubtitleChoice, name: String, tag: String?)] = []
    for track in embeddedSubtitleTracks {
      candidates.append((choice: .embedded(track.id), name: track.name, tag: track.languageTag))
    }
    for track in externalSubtitleTracks {
      candidates.append((choice: .external(track.id), name: track.name, tag: nil))
    }
    guard !candidates.isEmpty else {
      applySubtitleChoice(.off)
      return
    }
    if let remembered = PlayerPreferences.lastSubtitle(for: session.media.id) {
      if remembered == "OFF" {
        applySubtitleChoice(.off)
        return
      }
      let key = remembered.lowercased()
      if let match = candidates.first(where: { $0.name.lowercased() == key })
          ?? candidates.first(where: { $0.name.lowercased().contains(key) || key.contains($0.name.lowercased()) }) {
        applySubtitleChoice(match.choice)
        return
      }
    }
    let wanted = AppSettings.shared.values.subtitleLanguage
    if wanted.isEmpty {
      // "None": only the subtitle file provided by the source is turned on (addSingleSubtitleFile).
      if let external = candidates.first(where: { if case .external = $0.choice { return true } else { return false } }) {
        applySubtitleChoice(external.choice)
      } else {
        applySubtitleChoice(.off)
      }
      return
    }
    if candidates.count == 1 {
      applySubtitleChoice(candidates[0].choice)
      return
    }
    let wantedLower = wanted.lowercased()
    let byLanguage = candidates.first { candidate in
      candidate.tag == nil ? wantedLower == "eng" : PlayerLanguage.matches(tag: candidate.tag, wanted: wanted)
    }
    let byName = candidates.first { $0.name.lowercased().contains(wantedLower) }
    let english = candidates.first { PlayerLanguage.isEnglishOrUnknown($0.tag) }
    applySubtitleChoice((byLanguage ?? byName ?? english ?? candidates[0]).choice)
  }

  /// Subtitle cycling (KeyC): next track, then OFF.
  func cycleSubtitles() {
    var all: [PlayerSubtitleChoice] = embeddedSubtitleTracks.map { PlayerSubtitleChoice.embedded($0.id) }
    all += externalSubtitleTracks.map { PlayerSubtitleChoice.external($0.id) }
    guard !all.isEmpty else { return }
    let next: PlayerSubtitleChoice
    if let index = all.firstIndex(of: subtitleChoice) {
      next = index + 1 < all.count ? all[index + 1] : .off
    } else {
      next = all[0]
    }
    selectSubtitle(next)
    showNotice("Subtitles", subtitleName(for: next) ?? "OFF")
  }

  /// "Subtitle Offset": applies to the episodes that follow too, and is remembered for this show.
  func setSubtitleDelay(_ value: Double) {
    guard value.isFinite else { return }
    let range = PlayerPreferences.subtitleOffsetRange
    subtitleDelay = (min(max(value, -range), range) * 10).rounded() / 10
    PlayerPreferences.setSubtitleOffset(subtitleDelay, for: session.media.id)
    refreshSubtitleCues()
  }

  /// loadExternalSubtitleUrl: downloads a subtitle file with the stream headers.
  func loadExternalSubtitle(from url: URL, headers: [String: String] = [:], name: String = "Subtitles") {
    let generation = episodeGeneration
    let fileExtension = url.pathExtension
    Task { [weak self] in
      do {
        let (data, _) = try await HTTP.data(url, headers: headers, timeout: 30)
        let cues = await Task.detached(priority: .userInitiated) {
          PlayerSubtitleParser.parse(data: data, fileExtension: fileExtension)
        }.value
        guard let self, generation == self.episodeGeneration else { return }
        guard !cues.isEmpty else {
          self.showNotice("Subtitles", "Failed to load \(name) as it is not a subtitle file.", isError: true)
          return
        }
        self.addExternalTrack(name: name, cues: cues, select: false)
      } catch {
        guard let self, generation == self.episodeGeneration else { return }
        self.showNotice("Subtitles", "Failed to fetch subtitles: \(error.localizedDescription)", isError: true)
      }
    }
  }

  /// "Add Subtitles": a file picked in Files (.srt, .vtt, .ass, .ssa, .sub, .txt).
  func importSubtitleFile(at url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    let data = try? Data(contentsOf: url)
    if access { url.stopAccessingSecurityScopedResource() }
    let name = url.deletingPathExtension().lastPathComponent
    guard let data else {
      showNotice("Subtitles", "Failed to read \(name).", isError: true)
      return
    }
    parseAndAddSubtitles(data: data, fileExtension: url.pathExtension, name: name.isEmpty ? "Subtitles" : name)
  }

  /// Clipboard subtitles (the Svelte app accepts pasted ASS text and subtitle files).
  func pasteSubtitles() {
    guard let text = UIPasteboard.general.string, !text.isEmpty, let data = text.data(using: .utf8) else {
      showNotice("Subtitles", "The clipboard doesn't contain subtitles.", isError: true)
      return
    }
    parseAndAddSubtitles(data: data, fileExtension: "", name: "Clipboard")
  }

  private func parseAndAddSubtitles(data: Data, fileExtension: String, name: String) {
    let generation = episodeGeneration
    Task { [weak self] in
      let cues = await Task.detached(priority: .userInitiated) {
        PlayerSubtitleParser.parse(data: data, fileExtension: fileExtension)
      }.value
      guard let self, generation == self.episodeGeneration else { return }
      guard !cues.isEmpty else {
        self.showNotice("Subtitles", "Failed to load the file \(name) as it is not a subtitle file.", isError: true)
        return
      }
      self.addExternalTrack(name: name, cues: cues, select: true)
    }
  }

  /// Also used by the online subtitles (PlayerOnlineSubtitles.swift).
  func addExternalTrack(name: String, cues: [PlayerSubtitleCue], select: Bool) {
    nextExternalTrackID += 1
    var uniqueName = name
    var suffix = 2
    while externalSubtitleTracks.contains(where: { $0.name == uniqueName }) || embeddedSubtitleTracks.contains(where: { $0.name == uniqueName }) {
      uniqueName = "\(name) \(suffix)"
      suffix += 1
    }
    let track = PlayerExternalSubtitleTrack(id: nextExternalTrackID, name: uniqueName, cues: cues)
    externalSubtitleTracks.append(track)
    if select {
      selectSubtitle(.external(track.id))
    } else {
      applySubtitlePreference()
    }
  }

  private func refreshSubtitleCues() {
    guard case .external(let id) = subtitleChoice, let track = externalSubtitleTracks.first(where: { $0.id == id }) else {
      if !activeSubtitleCues.isEmpty { activeSubtitleCues = [] }
      return
    }
    let cues = track.activeCues(at: displayTime + subtitleDelay)
    if cues.map(\.id) != activeSubtitleCues.map(\.id) {
      activeSubtitleCues = cues
    }
  }

  // MARK: - Chapters and skipping

  /// findChapters: the file's own chapters when it has some, otherwise AniSkip for anime, then TheIntroDB (shows,
  /// movies, and the anime episodes AniSkip does not know).
  private func loadChapters() {
    guard let asset = currentAsset else { return }
    let generation = episodeGeneration
    Task { [weak self] in
      let embedded = await PlayerChapterLoader.embeddedChapters(of: asset)
      guard let self, generation == self.episodeGeneration else { return }
      if !embedded.isEmpty {
        self.chapters = PlayerChapterLogic.sanitise(embedded, duration: self.safeDuration)
        return
      }
      await self.findOnlineChapters()
    }
  }

  private func findOnlineChapters() async {
    let media = session.media
    let episode = session.episode
    let total = safeDuration
    // AniSkip and TheIntroDB know AniList / TMDB titles only (a Sora module result played as it is keeps the file's
    // own chapters).
    guard total > 0, !media.isSoraResult else { return }
    let generation = episodeGeneration
    var found: [PlayerChapter] = []
    // No AniSkip for episode 0 (a prologue), like PC getChaptersAniSkip (`!file.media?.episode`): AniSkip numbers
    // from 1.
    if media.isAnime, let malId = media.malId, episode.number > 0 {
      found = await PlayerAniSkip.chapters(malId: malId, episode: episode.number, duration: total)
    }
    if found.isEmpty, generation == episodeGeneration, !isClosed {
      found = await PlayerIntroDB.chapters(media: media, episode: episode, duration: total)
    }
    guard generation == episodeGeneration, !isClosed, !found.isEmpty, chapters.isEmpty else { return }
    chapters = PlayerChapterLogic.sanitise(found, duration: safeDuration)
  }

  /// checkSkippableChapters + auto skip (`playerSkip`, "Auto-Skip Intro/Outro").
  private func checkSkippableChapters() {
    guard !isScrubbing, !seekInFlight,
          let chapter = PlayerChapterLogic.chapter(at: currentTime, in: chapters) else { return }
    let name = PlayerChapterLogic.skippableName(chapter)
    if name != currentSkippable { currentSkippable = name }
    if name != nil, AppSettings.shared.values.playerSkip, autoSkippedChapterStart != chapter.start {
      autoSkippedChapterStart = chapter.start
      skip()
    }
  }

  /// skip(): end of the current skippable chapter (or next episode when it is the last one),
  /// +85 s inside a long non-skippable chapter, 90 s near the start, the end near the end.
  func skip() {
    guard everReady else { return }
    let time = currentTime
    let total = safeDuration
    var target: Double
    if let chapter = PlayerChapterLogic.chapter(at: time, in: chapters) {
      if PlayerChapterLogic.skippableName(chapter) == nil && chapter.length > 100 {
        target = time + 85
      } else {
        // Last chapter: the next episode (tryPlayNext). In Watch Together never on this device alone (each
        // member would load it): the seek to the end goes to the lobby and ends the episode, whose end path
        // (onPlaybackEnded) lets the host play the next queued item.
        if (total - chapter.end).rounded(.towardZero) == 0 && hasNext && autoplaysNextEpisode
            && !(isWatchTogetherActive?() ?? false) {
          currentSkippable = nil
          // Same as "Play Now": no Up next card for this episode any more (it would show in the same tick, then
          // over the next episode's loading).
          upNextDoneGeneration = episodeGeneration
          upNext = nil
          Task { [weak self] in
            await self?.playNext()
          }
          return
        }
        target = chapter.end
        currentSkippable = nil
      }
    } else if time < 10 {
      target = 90
    } else if total - time < 90 {
      target = total
    } else {
      target = time + 85
    }
    seek(to: target)
  }

  // MARK: - Up next

  /// The next episode starts by itself (end of the episode, Up next card, skip of the last chapter): the Autoplay
  /// setting, never for a Sora module result played as it is (its episodes are separate videos, a VOD list...).
  private var autoplaysNextEpisode: Bool {
    AppSettings.shared.values.playerAutoplay && !session.media.isSoraResult
  }

  /// "Up next" card: in the last credits / preview chapters of the episode (embedded, AniSkip or TheIntroDB),
  /// with autoplay on and a next episode. The next episode starts when the countdown (playback time) runs out.
  /// Not in Watch Together: autoplay is off there and the lobby's own "Up next" (the host's queue) runs at the
  /// end of the episode, which the seek to the end of `skip()` reaches.
  private func updateUpNext() {
    guard let next = upNextEpisode() else {
      if upNext != nil { upNext = nil }
      return
    }
    guard let current = upNext, current.episode == next else {
      upNext = PlayerUpNext(episode: next, title: upNextTitle(), startsAt: currentTime + PlayerController.upNextCountdown)
      return
    }
    if isPlaying, currentTime >= current.startsAt {
      playUpNext()
    }
  }

  private func upNextEpisode() -> EpisodeRef? {
    // Only with the full screen player in view (miniplayer, Picture in Picture, details sheet over it: autoplay
    // at the end as before).
    guard phase == .ready, !hasEnded, !isScrubbing, loadingEpisode == nil, fillerPrompt == nil,
          !isMinimized, !isPictureInPictureActive, !isExternalOverlayPresented,
          upNextDoneGeneration != episodeGeneration, autoplaysNextEpisode,
          !(isWatchTogetherActive?() ?? false), !autoSkipOwnsChapter,
          PlayerChapterLogic.isInOutroTail(currentTime, chapters: chapters, duration: safeDuration) else { return nil }
    return nextEpisodeRef
  }

  /// Auto-Skip jumps over the skippable chapter playing (or to the next episode from the last one), so no card
  /// there, like PC (`!(playerSkip && currentSkippable)`): it would flash, then stay over the next episode's
  /// loading. Read from the chapter at the current time (the auto-skip seek has already moved it, and `skip()`
  /// cleared `currentSkippable` in the same tick). A chapter already auto-skipped once and sought back into is
  /// not skipped again on iOS, so the card shows there.
  private var autoSkipOwnsChapter: Bool {
    guard AppSettings.shared.values.playerSkip,
          let chapter = PlayerChapterLogic.chapter(at: currentTime, in: chapters),
          PlayerChapterLogic.skippableName(chapter) != nil else { return false }
    return autoSkippedChapterStart != chapter.start
  }

  /// Title of the next episode from the episode list, unless spoiler protection hides it.
  private func upNextTitle() -> String? {
    guard let index = currentEpisodeIndex, episodeList.indices.contains(index + 1) else { return nil }
    let info = episodeList[index + 1]
    // Spoiler protection counts like the list progress: +1 when the show has an episode 0.
    if EpisodeSpoilers(entry: BrowseMediaInfo.entry(session.media), episode: info.number + (hasZeroEpisode ? 1 : 0)).title {
      return nil
    }
    return PlayerText.cleanedTitle(info.title)
  }

  /// "Play Now" of the Up next card, or its countdown running out.
  func playUpNext() {
    upNextDoneGeneration = episodeGeneration
    upNext = nil
    Task { [weak self] in
      await self?.playNext()
    }
  }

  /// "Cancel" of the Up next card: not shown again for this episode.
  func dismissUpNext() {
    upNextDoneGeneration = episodeGeneration
    upNext = nil
  }

  // MARK: - Progress and completion

  /// checkCompletion / checkCompletionByTime.
  private func checkCompletion() {
    let settings = AppSettings.shared.values
    guard !completed, settings.playerAutocomplete else { return }
    let threshold = Double(settings.playerAutocompleteThreshold) / 100
    let total = safeDuration
    guard total > 0, currentTime > 0, currentTime >= total * threshold else { return }
    let media = session.media
    let episodeAired = (media.nextAiring?.episode ?? 0) >= session.episode.number
    guard media.episodes != nil || episodeAired || media.isMovie else { return }
    completed = true
    onAutocomplete?(media, session.episode)
  }

  /// saveAnimeProgress: skipped while buffering/seeking unless forced.
  private func saveProgress(force: Bool = false) {
    if !force {
      guard phase == .ready, !isBuffering, !seekInFlight, currentTime > 0.5 else { return }
    }
    let total = safeDuration
    guard total > 0, currentTime.isFinite else { return }
    lastProgressSave = Date()
    onProgress?(PlayerProgressSnapshot(media: session.media, episode: session.episode, currentTime: currentTime, duration: total))
  }

  // MARK: - Episodes

  /// playNext (KeyN, next button, autoplay).
  func playNext() async {
    guard let ref = nextEpisodeRef else { return }
    await switchEpisode(to: ref, notifyIndex: true)
  }

  /// playLast (KeyB, previous button).
  func playPrevious() async {
    guard let ref = previousEpisodeRef else { return }
    await switchEpisode(to: ref, notifyIndex: true)
  }

  /// Episode picked in the episode list.
  func playEpisode(_ ref: EpisodeRef) async {
    await switchEpisode(to: ref, notifyIndex: true)
  }

  /// Filler prompt answer: Yes skips to the next episode, No plays this one.
  func answerFillerPrompt(skip: Bool) {
    fillerPrompt = nil
    if skip {
      Task { [weak self] in
        await self?.playNext()
      }
    } else {
      play()
    }
  }

  private func switchEpisode(to ref: EpisodeRef, notifyIndex: Bool) async {
    guard !isClosed, loadingEpisode == nil else { return }
    guard let loadEpisode else {
      showNotice("Episode \(ref.number)", "Episode loading is not available here.", isError: true)
      return
    }
    if everReady { saveProgress(force: true) }
    let wasPlaying = isPlaying
    player.pause()
    // Another episode loads (next button, episode list...): the Up next card would otherwise stay over the loading
    // spinner ("Paused") until begin().
    upNext = nil
    loadingEpisode = ref
    do {
      let next = try await loadEpisode(ref)
      loadingEpisode = nil
      guard !isClosed else { return }
      begin(next)
      if notifyIndex {
        onIndexChange?(currentEpisodeIndex ?? next.episode.number)
      }
    } catch {
      loadingEpisode = nil
      guard !isClosed else { return }
      // The app opened its own flow (extension picker): no error, stay paused until it delivers.
      if error is PlayerEpisodeHandedOff { return }
      if !(error is CancellationError) {
        showNotice("Failed to load Episode \(ref.number)", error.localizedDescription, isError: true)
      }
      if wasPlaying { player.play() }
    }
  }

  // MARK: - Watch Together

  /// Reports a local play / pause / seek. `seekFrom`: position before a seek the user made (seek distance);
  /// `announce: false` only records the state (file loading). States applied from the lobby are not reported
  /// (`suppressSyncUntil`).
  private func emitLocalState(seekFrom: Double? = nil, announce: Bool = true) {
    saveProgress()
    guard everReady else { return }
    let state = (paused: !isPlaying, time: floor(currentTime))
    let previous = lastSyncedState
    if let last = previous, last.paused == state.paused, last.time == state.time { return }
    lastSyncedState = state
    guard announce, Date() >= suppressSyncUntil else { return }
    onLocalStateChange?(state)
    guard let onSyncAction else { return }
    let kind: PlayerSyncAction.Kind
    var delta: Double?
    if let seekFrom, abs(currentTime - seekFrom) > PlayerController.syncSeekMinimum {
      kind = .seek
      delta = currentTime - seekFrom
    } else if previous == nil || previous?.paused != state.paused {
      kind = state.paused ? .pause : .play
    } else {
      return
    }
    // Paused by the system (app sent to the background with "Pause On Lost Focus", audio interruption).
    let automatic = state.paused && (pausedByBackground || interruptedWhilePlaying)
    onSyncAction(PlayerSyncAction(
      kind: kind,
      time: currentTime,
      paused: state.paused,
      delta: delta,
      rate: Double(playbackRate),
      automatic: automatic
    ))
  }

  /// Watch Together v2 `status` of this player (state, position, rate, what is playing).
  var syncSnapshot: PlayerSyncSnapshot {
    let state: PlayerSyncSnapshot.State
    if isClosed {
      state = .idle
    } else if loadingEpisode != nil || phase == .loading {
      state = .loading
    } else if isPlaying {
      state = isBuffering ? .buffering : .playing
    } else {
      state = .paused
    }
    let time = currentTime.isFinite ? max(currentTime, 0) : 0
    return PlayerSyncSnapshot(
      state: state,
      time: time,
      rate: Double(playbackRate),
      media: session.media,
      episode: session.episode,
      source: syncSource
    )
  }

  /// "Extension · Server" (PROTOCOL.md v2.1 `status.source`), "" when nothing is known.
  var syncSource: String {
    let server: String? = session.servers.isEmpty ? nil : serverName(activeServerIndex)
    return W2GSync.formatSource([sourceName, server])
  }

  /// w2gEmitter 'playerupdate': follow another participant (seek only on a meaningful difference).
  func applyRemoteState(paused: Bool, time: Double) {
    applyRemoteState(paused: paused, time: time, seekThreshold: PlayerController.remoteSeekThreshold)
  }

  /// Applies a lobby state (Watch Together v2: someone's action, host snap-back, auto-sync, resync, countdown).
  /// Seeks only when the position differs by more than `seekThreshold`; never reported back as a local action.
  func applyRemoteState(paused: Bool, time: Double, seekThreshold: Double) {
    guard !isClosed, time.isFinite else { return }
    lastSyncedState = (paused: paused, time: floor(time))
    suppressSyncUntil = Date().addingTimeInterval(1)
    autoplayHandledByRemote = true
    // The lobby sets the position: no local "Start Over" offer.
    resumeChoice = nil
    guard phase == .ready else {
      pendingRemoteState = (paused: paused, time: time)
      return
    }
    fillerPrompt = nil
    if abs(currentTime - time) > max(seekThreshold, 0) {
      performSeek(to: time)
    }
    if paused {
      if isPlaying { player.pause() }
    } else if !isPlaying {
      if hasEnded {
        play()
      } else {
        player.play()
      }
    }
  }

  /// w2gEmitter 'setindex': another participant changed episode.
  func applyRemoteIndex(_ index: Int) {
    let ref: EpisodeRef
    if !episodeList.isEmpty {
      guard episodeList.indices.contains(index) else { return }
      ref = episodeList[index].ref
    } else {
      ref = EpisodeRef(number: index, season: nil, localEpisode: nil)
    }
    guard ref.number != session.episode.number || ref.season != session.episode.season else { return }
    Task { [weak self] in
      await self?.switchEpisode(to: ref, notifyIndex: false)
    }
  }

  // MARK: - Picture in Picture and miniplayer

  /// togglePopout (KeyP, PiP button). With `onMinimize` set, the player UI is dismissed once PiP runs so
  /// the rest of the app can be used. When PiP is unavailable or fails, the player falls back to the in-app
  /// miniplayer (PlayerPage.svelte: "PiP failed, falling back to miniplayer").
  func togglePictureInPicture() {
    if isPictureInPictureActive {
      pip.stop()
      return
    }
    startPictureInPicture(andMinimize: onMinimize != nil)
  }

  /// Leaves the full screen player without stopping playback: the app shows the in-app miniplayer
  /// (Miniplayer.svelte, shown when the player page is left). Needs `onMinimize` (PlayerPresentation sets it).
  func minimize() {
    guard didStart, !isClosed, onMinimize != nil else { return }
    wantsMinimizeOnPiPStart = false
    isMinimized = true
    onMinimize?()
  }

  /// "Now Playing" while minimized to Picture in Picture: stops PiP for a restore. The app presents the player
  /// UI itself (once its sheets are closed), so the AVKit restore callback does not present it a second time.
  func stopPictureInPictureForRestore() {
    // Already stopping through the PiP window's restore button: nothing to stop.
    guard isPictureInPictureActive, !restoringFromPiP else { return }
    restoringFromPiP = true
    restoreHandledByApp = true
    pip.stop()
  }

  private func startPictureInPicture(andMinimize: Bool) {
    guard PlayerPiPCoordinator.isSupported else {
      if andMinimize {
        minimize()
      } else {
        showNotice("Picture in Picture", "Picture in Picture is not supported on this device.", isError: true)
      }
      return
    }
    guard isPictureInPicturePossible else {
      if andMinimize {
        minimize()
      } else {
        showNotice("Picture in Picture", "Picture in Picture isn't available for this video right now.", isError: true)
      }
      return
    }
    wantsMinimizeOnPiPStart = andMinimize && onMinimize != nil
    pip.start()
  }

  private func pictureInPictureDidStart() {
    pipStarting = false
    isPictureInPictureActive = true
    if wantsMinimizeOnPiPStart {
      wantsMinimizeOnPiPStart = false
      isMinimized = true
      onMinimize?()
    }
  }

  /// PiP window closed. While the player UI is dismissed, the video comes back in the in-app miniplayer
  /// (PlayerPresentation shows it again once PiP is over) instead of closing the player.
  private func pictureInPictureDidStop() {
    pipStarting = false
    isPictureInPictureActive = false
    restoringFromPiP = false
    restoreHandledByApp = false
  }

  private func pictureInPictureFailed(_ message: String) {
    pipStarting = false
    let fallBack = wantsMinimizeOnPiPStart
    wantsMinimizeOnPiPStart = false
    if fallBack && !isMinimized {
      minimize()
      return
    }
    showNotice("Picture in Picture", message, isError: true)
  }

  private func pictureInPictureRestore() {
    restoringFromPiP = true
    if restoreHandledByApp { return }
    if isMinimized {
      isMinimized = false
      onRestoreFromPictureInPicture?()
    }
  }

  // MARK: - Now Playing

  private func installRemoteCommands() {
    let commands = PlayerNowPlaying.Commands(
      play: { [weak self] in self?.play() },
      pause: { [weak self] in self?.pause() },
      toggle: { [weak self] in self?.togglePlayPause() },
      next: { [weak self] in
        Task { await self?.playNext() }
      },
      previous: { [weak self] in
        Task { await self?.playPrevious() }
      },
      skipForward: { [weak self] in self?.forward() },
      skipBackward: { [weak self] in self?.rewind() },
      seek: { [weak self] time in self?.seek(to: time) }
    )
    nowPlaying.enable(commands, skipInterval: AppSettings.shared.values.playerSeek)
    refreshRemoteCommandAvailability()
  }

  private func refreshRemoteCommandAvailability() {
    nowPlaying.setTrackCommands(next: hasNext, previous: hasLast)
  }

  private func updateNowPlayingMetadata() {
    guard didStart, !isClosed else { return }
    let images = session.media.images
    nowPlaying.setMetadata(title: displayTitle, subtitle: episodeLine, artworkURL: images.coverLarge ?? images.cover ?? images.banner)
    refreshRemoteCommandAvailability()
    updateNowPlayingPlayback()
  }

  private func updateNowPlayingPlayback() {
    guard didStart, !isClosed else { return }
    nowPlaying.setPlayback(elapsed: currentTime, duration: safeDuration, rate: isPlaying ? Double(playbackRate) : 0)
  }

  // MARK: - Tools

  /// KeyX "Save Screenshot to Clipboard": the video frame with the active external subtitles drawn on it
  /// (embedded tracks are rendered by AVPlayer and cannot be captured).
  func takeScreenshot() {
    guard let output = videoOutput, let item = player.currentItem else { return }
    let time = item.currentTime()
    let fresh = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    var fallback: CVPixelBuffer?
    if fresh == nil, let last = lastVideoFrame, time.seconds.isFinite, abs(last.time - time.seconds) < 1 {
      fallback = last.buffer
    }
    guard let buffer = fresh ?? fallback else {
      showNotice("Screenshot", "No video frame is available yet.", isError: true)
      return
    }
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = PlayerController.ciContext.createCGImage(image, from: image.extent) else {
      showNotice("Screenshot", "The video frame could not be captured.", isError: true)
      return
    }
    let cues = activeSubtitleCues
    if cues.isEmpty {
      UIPasteboard.general.image = UIImage(cgImage: cgImage)
    } else {
      UIPasteboard.general.image = PlayerSubtitleBurner.render(cgImage, cues: cues, time: displayTime + subtitleDelay)
    }
    showNotice("Screenshot", "Saved screenshot to clipboard.")
  }

  /// HLS has no AVAssetImageGenerator support: while playing, a small frame is copied from the video output
  /// every few seconds of video so the seekbar can preview the parts already played.
  private func captureThumbnailIfNeeded() {
    guard imageGenerator == nil, !isScrubbing, !seekInFlight, let output = videoOutput,
          let item = player.currentItem else { return }
    let itemTime = item.currentTime()
    let seconds = itemTime.seconds
    guard seconds.isFinite, seconds >= 0 else { return }
    let bucket = Int(seconds / PlayerController.thumbnailInterval)
    guard thumbnailCache[bucket] == nil, Date().timeIntervalSince(lastThumbnailCapture) >= 1,
          output.hasNewPixelBuffer(forItemTime: itemTime),
          let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
    lastThumbnailCapture = Date()
    lastVideoFrame = (buffer: buffer, time: seconds)
    guard let thumbnail = PlayerController.thumbnail(from: buffer) else { return }
    if thumbnailCache.count >= PlayerController.thumbnailLimit,
       let farthest = thumbnailCache.keys.max(by: { abs($0 - bucket) < abs($1 - bucket) }) {
      thumbnailCache[farthest] = nil
    }
    thumbnailCache[bucket] = thumbnail
  }

  /// Cached HLS frame closest to `time` (same bucket, else up to two buckets away).
  private func cachedThumbnail(near time: Double) -> CGImage? {
    guard !thumbnailCache.isEmpty, time.isFinite, time >= 0 else { return nil }
    let bucket = Int(time / PlayerController.thumbnailInterval)
    for distance in 0...2 {
      if let image = thumbnailCache[bucket - distance] { return image }
      if let image = thumbnailCache[bucket + distance] { return image }
    }
    return nil
  }

  private static func thumbnail(from buffer: CVPixelBuffer) -> CGImage? {
    let image = CIImage(cvPixelBuffer: buffer)
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }
    let scale = min(thumbnailSize.width / extent.width, thumbnailSize.height / extent.height, 1)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ciContext.createCGImage(scaled, from: scaled.extent)
  }

  /// Subtitle files (or text) dropped on the player (common/modules/clipboard.js drop handler → subtitles.js).
  /// Returns false when nothing in the drop can be read as data.
  func importDroppedSubtitles(_ providers: [NSItemProvider]) -> Bool {
    let dataType = UTType.data.identifier
    var accepted = false
    for provider in providers where provider.hasItemConformingToTypeIdentifier(dataType) {
      let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
        UTType(identifier)?.conforms(to: .data) ?? false
      } ?? dataType
      let suggested = provider.suggestedName ?? ""
      let suggestedExtension = (suggested as NSString).pathExtension
      let fileExtension = suggestedExtension.isEmpty
        ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "")
        : suggestedExtension
      let baseName = (suggested as NSString).deletingPathExtension
      let name = baseName.isEmpty ? "Subtitles" : baseName
      accepted = true
      _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, _ in
        let controller = self
        Task { @MainActor in
          guard let controller else { return }
          guard let data else {
            controller.showNotice("Subtitles", "Failed to read \(name).", isError: true)
            return
          }
          controller.parseAndAddSubtitles(data: data, fileExtension: fileExtension, name: name)
        }
      }
    }
    return accepted
  }

  /// KeyI "Toggle Stats".
  func toggleStats() {
    if statsTask != nil {
      statsTask?.cancel()
      statsTask = nil
      stats = nil
      return
    }
    stats = makeStats()
    statsTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, let self else { return }
        self.stats = self.makeStats()
      }
    }
  }

  private func makeStats() -> [PlayerStatLine] {
    let item = player.currentItem
    let event = item?.accessLog()?.events.last
    let videoTrack = item?.tracks.first { $0.assetTrack?.mediaType == .video }
    let fps = videoTrack.map { String(format: "%.3f", Double($0.currentVideoFrameRate)) } ?? "n/a"
    let dropped = event.map { String($0.numberOfDroppedVideoFrames) } ?? "n/a"
    let bitrate = event.map { $0.indicatedBitrate > 0 ? String(format: "%.0f kbps", $0.indicatedBitrate / 1000) : "n/a" } ?? "n/a"
    let size = item?.presentationSize ?? .zero
    let scale = layerView.traitCollection.displayScale
    let bounds = layerView.bounds.size
    let viewport = "\(Int((bounds.width * scale).rounded()))x\(Int((bounds.height * scale).rounded()))"
    let resolution = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    let bufferHealth = max(0, bufferedTime - currentTime)
    let server = session.currentServer
    let name = server.map { "\($0.title) (\($0.url.lastPathComponent))" } ?? ""
    return [
      PlayerStatLine(label: "FPS", value: fps),
      PlayerStatLine(label: "Dropped frames", value: dropped),
      PlayerStatLine(label: "Viewport", value: viewport),
      PlayerStatLine(label: "Resolution", value: resolution),
      PlayerStatLine(label: "Bitrate", value: bitrate),
      PlayerStatLine(label: "Buffer health", value: String(format: "%.0f s", bufferHealth)),
      PlayerStatLine(label: "Playback speed", value: String(format: "x%.1f", Double(player.rate == 0 ? playbackRate : player.rate))),
      PlayerStatLine(label: "Name", value: name)
    ]
  }

  /// "External Player" (VLC / Infuse). Stream headers can't be forwarded.
  func openInExternalPlayer(_ app: PlayerExternalApp) {
    guard let server = session.currentServer, let url = app.url(for: server.url) else { return }
    pause()
    Task { [weak self] in
      let opened = await UIApplication.shared.open(url, options: [:])
      if !opened {
        self?.showNotice("External Player", "\(app.name) is not installed.", isError: true)
      }
    }
  }

  func showNotice(_ title: String, _ message: String? = nil, isError: Bool = false) {
    let newNotice = PlayerNotice(title: title, message: message, isError: isError)
    notice = newNotice
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled, let self, self.notice?.id == newNotice.id else { return }
      self.notice = nil
    }
  }

  func dismissNotice() {
    noticeTask?.cancel()
    noticeTask = nil
    notice = nil
  }
}
