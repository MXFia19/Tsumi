import SwiftUI
import UIKit
import BackgroundTasks

// Connects the blocks written separately (Services, Extensions, Player, Watch Together, Discord) once at launch.
// Svelte equivalents: the module-level IPC / window event listeners of App.svelte, ExtensionModal.svelte
// ('w2g-play'), WatchTogetherPage.svelte (lobby events), NotificationsModal.svelte (activation links),
// stremio.js / tmdb.js (anilistToTmdb, tmdbToAnilist, getDetails) and anilist.js `title`.

@MainActor
enum AppWiring {
  private static var configured = false

  /// Installs every closure / hook. Idempotent.
  static func configure() {
    guard !configured else { return }
    configured = true
    ExtensionContext.shared = ShellExtensionBridge.makeContext()
    PlaybackRequestCoordinator.shared.onReady = { playback in
      ShellPlayback.start(playback)
    }
    configureWatchTogether()
    configureDiscord()
    // Notification taps (activation tsumi://anime/<id>) go through the deep link router.
    AppNotificationsService.shared.onOpenURL = { url in
      ShellDeepLinks.handle(url)
    }
    ShellSettingsDefaults.applySvelteLayoutOnce()
  }

  /// The player the lobby sees and drives: none while it plays a Sora module result as it is (never shared with the
  /// lobby), so the lobby sees this device as not playing and its play / pause / seek leave that video alone.
  private static var lobbyController: PlayerController? {
    guard let controller = PlayerPresentation.shared.controller, !controller.session.media.isSoraResult else { return nil }
    return controller
  }

  private static func configureWatchTogether() {
    let client = WatchTogetherClient.shared
    // Helper.getUser(): the signed-in AniList / MyAnimeList viewer, anonymous otherwise.
    client.currentUser = {
      ProfilesService.shared.viewer
    }
    client.onRemoteMedia = { media, episode in
      ShellPlayback.playRemote(media, episode: episode)
    }
    // v1 fallback, only used when onApplyPlayer is not set.
    client.onRemotePlayer = { paused, time in
      lobbyController?.applyRemoteState(paused: paused, time: time)
    }
    // v2 lobby states (someone's action, host snap-back, auto-sync, resync, countdown): applied without being
    // reported back. Exact times (v2) seek past 0.25 s; v1 whole-second times past 1.5 s.
    client.onApplyPlayer = { command in
      let threshold = command.isPrecise ? PlayerController.syncSeekThreshold : PlayerController.remoteSeekThreshold
      lobbyController?.applyRemoteState(paused: command.paused, time: command.time, seekThreshold: threshold)
    }
    // The host accepted a request: do it as a local action, which is then broadcast.
    client.onPerformRequest = { kind, time in
      guard let controller = lobbyController else { return }
      switch kind {
      case .pause:
        controller.pause()
      case .play:
        controller.play()
      case .seek:
        if let time { controller.seek(to: time) }
      }
    }
    // `status` source: what the player is doing now (nil = not in the player, `idle`).
    client.localPlayback = {
      guard let controller = lobbyController else { return nil }
      let snapshot = controller.syncSnapshot
      let state: W2GPlaybackState
      switch snapshot.state {
      case .playing: state = .playing
      case .paused: state = .paused
      case .buffering: state = .buffering
      case .loading: state = .loading
      case .idle: state = .idle
      }
      return W2GLocalPlayback(
        state: state,
        time: snapshot.time,
        rate: snapshot.rate,
        media: snapshot.media,
        episode: snapshot.episode,
        source: snapshot.source
      )
    }
    client.onRemoteIndex = { index in
      ShellPlayback.applyRemoteIndex(index)
    }
    client.onNotice = { title, message in
      // In the full screen player the app toasts are hidden: show it in the player instead.
      if PlayerPresentation.shared.isPresented, let controller = PlayerPresentation.shared.controller {
        controller.showNotice(title, message)
        return
      }
      ShellPlayback.showWatchTogetherNotice(title, message)
    }
    client.onShowLobby = {
      ShellNavigation.showTab(.watchTogether)
    }
    // v2.4 voice chat: video ducking while someone speaks, and where the audio session goes back after voice.
    client.onDuck = { level in
      PlayerPresentation.shared.controller?.setDuck(level)
    }
    client.isPlayerOpen = {
      PlayerPresentation.shared.controller != nil
    }
  }

  /// Discord rich presence (PlayerPage.svelte setDiscordRPC inputs): what the player is doing, sampled once a
  /// second by DiscordPresence (play / pause / seek / episode changes are seen there), and the lobby code.
  private static func configureDiscord() {
    let discord = DiscordPresence.shared
    discord.nowPlaying = {
      let presentation = PlayerPresentation.shared
      guard let controller = presentation.controller else { return nil }
      let snapshot = controller.syncSnapshot
      let paused: Bool
      switch snapshot.state {
      case .idle:
        return nil
      case .playing, .buffering:
        paused = false
      case .paused, .loading:
        paused = true
      }
      let media = MediaStore.shared.media(snapshot.media.id) ?? snapshot.media
      let duration = controller.duration
      return DiscordNowPlaying(
        media: media,
        episode: snapshot.episode.number,
        title: AniListService.shared.title(media),
        isPaused: paused,
        isPresented: presentation.isPresented,
        time: snapshot.time,
        duration: duration.isFinite ? duration : 0,
        rate: snapshot.rate
      )
    }
    discord.watchTogetherCode = {
      WatchTogetherClient.shared.code
    }
  }
}

/// ExtensionContext closures, built outside the main actor: the extension runtime calls them from
/// background tasks, so they only use the thread-safe services (AnimeMappingsService, TMDBService,
/// AniListService, AccountStore, AppSettings).
enum ShellExtensionBridge {
  static func makeContext() -> ExtensionContext {
    var context = ExtensionContext()
    // tmdbClient.anilistToTmdb[id]: { id, type, tvdb_season, tvdb_epoffset }.
    context.animeToTMDB = { anilistId in
      guard let entry = await AnimeMappingsService.shared.tmdbInfo(anilistId: anilistId), let tmdbId = entry.tmdbId else { return nil }
      return ExtensionAnimeMapping(tmdbId: tmdbId, isMovie: entry.isMovie, season: entry.tvdbSeason, episodeOffset: entry.tvdbEpoffset ?? 0)
    }
    // getDetails(id, type).externalIds.imdb_id.
    context.tmdbIMDbId = { tmdbId, type in
      guard let details = await TMDBService.shared.details(id: tmdbId, type: type) else { return nil }
      if let imdb = details.imdbId, !imdb.isEmpty { return imdb }
      if let imdb = details.externalIds["imdb_id"], !imdb.isEmpty { return imdb }
      return nil
    }
    // /find/{imdb}?external_source=imdb_id.
    context.tmdbFindByIMDb = { imdbId in
      let found = await TMDBService.shared.findAll(externalId: imdbId, source: "imdb_id")
      if found.tvIds.isEmpty && found.movieIds.isEmpty { return nil }
      return ExtensionIMDbMatch(tvIds: found.tvIds, movieIds: found.movieIds)
    }
    // getDetails(id, 'tv').seasons.
    context.tmdbSeasons = { tmdbId in
      guard let details = await TMDBService.shared.details(id: tmdbId, type: .tv) else { return [] }
      return details.seasons.map { ExtensionSeasonInfo(seasonNumber: $0.seasonNumber, episodeCount: $0.episodeCount) }
    }
    // tmdbClient.tmdbToAnilist[`${type}-${id}`] (index preloaded by Services.start()).
    context.tmdbToAnilistId = { tmdbId, type in
      AnimeMappingsService.shared.loadedAnilistId(tmdbId: tmdbId, type: type)
    }
    // anilistClient.title: userPreferred when logged into AniList, else the title language setting.
    context.displayTitle = { media in
      AniListService.shared.title(media)
    }
    return context
  }
}

/// Launch sequence, run from the app delegate (so notification taps that launch the app find their
/// delegate and router) and again from the root view (no-op).
@MainActor
enum ShellLaunch {
  private static var started = false

  static func start() {
    guard !started else { return }
    started = true
    AppWiring.configure()
    Services.shared.start()
    // Home screen widgets and lock screen countdowns (Widgets/TsumiWidgetBridge.swift).
    TsumiWidgetBridge.start()
    _ = ExtensionManager.shared
    ShellConnectionMonitor.shared.start()
    // Offline downloads: reconnects to the background download sessions.
    DownloadCenter.shared.start()
  }

  static func startFromView() async {
    start()
    // Foreground launches only (not background refresh): reconnects a linked Discord account.
    DiscordPresence.shared.start()
    // Expired / expiring AniList and MyAnimeList sessions (Services/SessionExpiry.swift).
    SessionExpiryCenter.shared.scheduleStartupCheck()
  }
}

/// App lifecycle (scenePhase).
@MainActor
enum ShellLifecycle {
  static func scenePhaseChanged(_ phase: ScenePhase) {
    switch phase {
    case .active:
      // Reconnects the Watch Together trackers dropped while suspended.
      WatchTogetherClient.shared.appBecameActive()
      // Same for the Discord connection (rich presence).
      DiscordPresence.shared.appBecameActive()
      TsumiWidgetBridge.appBecameActive()
      // Movie release alerts: the 6 hour loop does not run while suspended.
      MovieAlertsService.shared.checkIfStale()
    case .background:
      TsumiWidgetBridge.appEnteredBackground()
      // Delivers the queued notifications before the app is suspended (15 s debounce otherwise).
      AppNotificationsService.shared.flush()
      // Notification checks while the app is closed (the desktop tray keeps polling).
      ShellBackgroundRefresh.schedule()
    case .inactive:
      break
    @unknown default:
      break
    }
  }
}

/// App delegate: orientation lock of the player, background refresh registration and early wiring.
@MainActor
final class ShellAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // BGTaskScheduler handlers must be registered before launching finishes.
    ShellBackgroundRefresh.register()
    ShellLaunch.start()
    return true
  }

  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    PlayerOrientation.supportedMask
  }

  /// Offline downloads finished while the app was suspended / closed.
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    DownloadCenter.shared.handleBackgroundEvents(identifier, completion: completionHandler)
  }
}

/// BGAppRefreshTask running the AniList notification check and the schedule announcements while the app is
/// closed (`AppNotificationsService.backgroundRefresh()`), then delivering the system notifications.
/// Info.plist: `BGTaskSchedulerPermittedIdentifiers` and the `fetch` background mode.
enum ShellBackgroundRefresh {
  static let identifier = "org.tsumi.app.refresh"
  private static let registered = ServiceLocked<Bool>(false)

  static func register() {
    let first = registered.update { done -> Bool in
      if done { return false }
      done = true
      return true
    }
    guard first else { return }
    _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      run(task)
    }
  }

  /// Asks iOS for the next run (at the earliest in 15 minutes, like the 5 min polling but battery friendly).
  static func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private static func run(_ task: BGTask) {
    schedule()
    let finished = ServiceLocked<Bool>(false)
    let complete: (Bool) -> Void = { success in
      let first = finished.update { done -> Bool in
        if done { return false }
        done = true
        return true
      }
      if first { task.setTaskCompleted(success: success) }
    }
    let work = Task { @MainActor in
      ShellLaunch.start()
      await AppNotificationsService.shared.backgroundRefresh()
      // Let the notifications dispatched by the checks reach the queue, then deliver them now.
      try? await Task.sleep(nanoseconds: 500_000_000)
      await AppNotificationsService.shared.flushAndWait()
      // Widget snapshot + timelines, and the end of aired lock screen countdowns.
      await TsumiWidgetBridge.backgroundRefresh()
      complete(!Task.isCancelled)
    }
    task.expirationHandler = {
      work.cancel()
      complete(false)
    }
  }
}
