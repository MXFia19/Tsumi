import SwiftUI
import UIKit

// Connects the blocks written separately (Services, Extensions, Player, Watch Together) once at launch.
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
    // Notification taps (activation tsumi://anime/<id>) go through the deep link router.
    AppNotificationsService.shared.onOpenURL = { url in
      ShellDeepLinks.handle(url)
    }
    ShellSettingsDefaults.applySvelteLayoutOnce()
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
    client.onRemotePlayer = { paused, time in
      PlayerPresentation.shared.controller?.applyRemoteState(paused: paused, time: time)
    }
    client.onRemoteIndex = { index in
      ShellPlayback.applyRemoteIndex(index)
    }
    client.onNotice = { title, message in
      ShellPlayback.showWatchTogetherNotice(title, message)
    }
    client.onShowLobby = {
      ShellNavigation.showTab(.watchTogether)
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
      guard let found = await TMDBService.shared.find(externalId: imdbId, source: "imdb_id") else { return nil }
      if found.type == .tv {
        return ExtensionIMDbMatch(tvIds: [found.id], movieIds: [])
      }
      return ExtensionIMDbMatch(tvIds: [], movieIds: [found.id])
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
    _ = ExtensionManager.shared
    ShellConnectionMonitor.shared.start()
  }

  static func startFromView() async {
    start()
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
    case .background:
      // Delivers the queued notifications before the app is suspended (15 s debounce otherwise).
      AppNotificationsService.shared.flush()
    case .inactive:
      break
    @unknown default:
      break
    }
  }
}

/// App delegate: orientation lock of the player and early wiring.
@MainActor
final class ShellAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    ShellLaunch.start()
    return true
  }

  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    PlayerOrientation.supportedMask
  }
}
