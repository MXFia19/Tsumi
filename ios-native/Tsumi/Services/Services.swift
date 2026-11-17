import Foundation
import UIKit

// Container of the data / services layer and app-level wiring (startup, deep links of
// capacitor/src/main/protocol.js and the clipboard links of settings.js).

/// tsumi:// (or legacy shiru://) links.
enum TsumiDeepLink: Hashable {
  /// tsumi://anime/<anilistId>
  case anime(Int)
  /// tsumi://malanime/<malId>
  case malAnime(Int)
  /// tsumi://movie/<tmdbId>: details of a TMDB movie (movie release alerts).
  case movie(Int)
  /// tsumi://search/<anilistId>: play the anime.
  case play(Int)
  /// tsumi://w2g/<link>
  case watchTogether(String)
  /// tsumi://schedule/
  case schedule
  /// tsumi://alauth / tsumi://malauth login callbacks (already handled).
  case loginCallback(success: Bool)
}

@MainActor
final class Services {
  static let shared = Services()

  var store: MediaStore { MediaStore.shared }
  var anilist: AniListService { AniListService.shared }
  var mal: MyAnimeListService { MyAnimeListService.shared }
  var tmdb: TMDBService { TMDBService.shared }
  var mappings: AnimeMappingsService { AnimeMappingsService.shared }
  var dubs: MALDubsService { MALDubsService.shared }
  var schedule: AnimeScheduleService { AnimeScheduleService.shared }
  var details: MediaDetailsService { MediaDetailsService.shared }
  var accounts: AccountStore { AccountStore.shared }
  var auth: ProfilesService { ProfilesService.shared }
  var lists: MediaListService { MediaListService.shared }
  var progress: AnimeProgressService { AnimeProgressService.shared }
  var sections: HomeSectionsService { HomeSectionsService.shared }
  var notifications: AppNotificationsService { AppNotificationsService.shared }
  var messages: ServiceMessages { ServiceMessages.shared }
  var network: ServiceNetworkMonitor { ServiceNetworkMonitor.shared }

  private var started = false
  private var dubsTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var saveTask: UIBackgroundTaskIdentifier = .invalid

  private init() {}

  /// Starts the background work (list refresh every 15 min, schedule manifest polling every 5 min,
  /// AniList notification polling every 5 min, hourly dub list refresh, animap preload).
  func start() {
    guard !started else { return }
    started = true
    lists.start()
    schedule.start()
    notifications.start()
    // Movie release alerts: first check a few seconds after launch, then every 6 hours.
    MovieAlertsService.shared.start()
    sections.rebuild()
    observeLifecycle()
    Task.detached(priority: .utility) {
      _ = await AnimeMappingsService.shared.animapIndex()
    }
    // Cache files expired long ago are deleted once per launch.
    Task.detached(priority: .background) {
      DiskCache.shared.pruneExpiredFiles()
    }
    dubsTask = Task.detached(priority: .utility) {
      while !Task.isCancelled {
        _ = await MALDubsService.shared.lists(force: true)
        try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
      }
    }
  }

  /// Memory warnings empty the in-memory caches; going to the background writes the media store (its saves are
  /// grouped every minute otherwise).
  private func observeLifecycle() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
      MediaStore.shared.purgeMemory()
      AnimeMappingsService.shared.purgeMemory()
      Task.detached(priority: .utility) {
        await DiskCache.shared.purgeMemory()
      }
    })
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        Services.shared.saveStores()
      }
    })
  }

  private func saveStores() {
    endSaveTask()
    saveTask = UIApplication.shared.beginBackgroundTask(withName: "Tsumi media store") {
      MainActor.assumeIsolated {
        Services.shared.endSaveTask()
      }
    }
    DispatchQueue.global(qos: .utility).async {
      MediaStore.shared.saveNow()
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          Services.shared.endSaveTask()
        }
      }
    }
  }

  private func endSaveTask() {
    guard saveTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(saveTask)
    saveTask = .invalid
  }

  /// Handles an incoming URL (onOpenURL / notification tap / pasted link). Login callbacks are
  /// consumed here; other links are returned for navigation.
  func handle(url: URL) async -> TsumiDeepLink? {
    let text = url.absoluteString
    if let link = Self.parseWebLink(text) { return link }
    guard let scheme = url.scheme?.lowercased(), scheme == "tsumi" || scheme == "shiru" else { return nil }
    let remainder = String(text.dropFirst(scheme.count + 3))
    var key = ""
    var value = ""
    if let separator = remainder.firstIndex(where: { $0 == "/" || $0 == "#" || $0 == "?" }) {
      key = String(remainder[..<separator])
      value = String(remainder[remainder.index(after: separator)...])
      if remainder[separator] == "?" { value = "?" + value }
    } else {
      key = remainder
    }
    switch key.lowercased() {
    case "alauth", "malauth":
      let success = await auth.handleCallback(url)
      return .loginCallback(success: success)
    case "anime":
      return Int(Self.trimmed(value)).map { TsumiDeepLink.anime($0) }
    case "malanime":
      return Int(Self.trimmed(value)).map { TsumiDeepLink.malAnime($0) }
    case "movie":
      return Int(Self.trimmed(value)).map { TsumiDeepLink.movie($0) }
    case "search":
      return Int(Self.trimmed(value)).map { TsumiDeepLink.play($0) }
    case "w2g":
      return .watchTogether(value)
    case "schedule":
      return .schedule
    case "trakt":
      // tsumi://trakt/callback (Trakt sign-in): handled by TraktService (ShellDeepLinks), never a navigation.
      return nil
    default:
      return nil
    }
  }

  /// anilist.co/anime/<id> and myanimelist.net/anime/<id> links (settings.js paste handler).
  static func parseWebLink(_ text: String) -> TsumiDeepLink? {
    let patterns: [(String, Bool)] = [("anilist\\.co/anime/(\\d+)", false), ("myanimelist\\.net/anime/(\\d+)", true)]
    for (pattern, isMAL) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      if let match = regex.firstMatch(in: text, range: range), let idRange = Range(match.range(at: 1), in: text), let id = Int(text[idRange]) {
        return isMAL ? .malAnime(id) : .anime(id)
      }
    }
    return nil
  }

  private static func trimmed(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") { result.removeLast() }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Media of an anime link (App.svelte handleAnime: searchIDSingle by id or MAL id).
  func media(for link: TsumiDeepLink) async -> Media? {
    switch link {
    case .anime(let id), .play(let id):
      return try? await anilist.media(id: id)
    case .malAnime(let id):
      return try? await anilist.media(malId: id)
    case .movie(let id):
      // Stored media, else the snapshot of its release alert, else TMDB (PC movieMedia).
      return await MovieAlertsService.shared.movieMedia(tmdbId: id)
    default:
      return nil
    }
  }

  /// Settings "Clear Cache" (cache.resetCaches): API caches and the media store.
  func clearCaches() async {
    await DiskCache.shared.clear()
    store.clear()
    await lists.refresh()
    sections.rebuild()
  }
}
