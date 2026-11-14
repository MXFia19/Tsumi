import Foundation

// Port of common/modules/anime/animedubs.js: list of dubbed MyAnimeList ids (MAL-Dubs project),
// refreshed every hour, used by "preferDubs", the dub-only search filter and the episode lists.

struct MALDubLists: Codable, Hashable {
  var dubbed: [Int] = []
  var incomplete: [Int] = []
}

final class MALDubsService: @unchecked Sendable {
  static let shared = MALDubsService()

  private static let feedURL = ServiceText.base64("aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL01BTC1EdWJzL01BTC1EdWJzL21haW4vZGF0YS9kdWJJbmZvLmpzb24=")
  private static let cacheKey = "maldubs.v1"

  private struct State {
    var lists: MALDubLists?
    var dubbed: Set<Int> = []
    var incomplete: Set<Int> = []
    var loadedAt: Date?
  }

  private let state = ServiceLocked<State>(State())
  private let inflight = ServiceInflight()

  private init() {}

  /// Current lists (fetched if missing or older than an hour).
  func lists(force: Bool = false) async -> MALDubLists {
    let current = state.get()
    if !force, let lists = current.lists, let loadedAt = current.loadedAt, Date().timeIntervalSince(loadedAt) < 3600 {
      return lists
    }
    let lists: MALDubLists = (try? await inflight.run("maldubs") { await MALDubsService.fetch() }) ?? current.lists ?? MALDubLists()
    state.set(State(lists: lists, dubbed: Set(lists.dubbed), incomplete: Set(lists.incomplete), loadedAt: Date()))
    return lists
  }

  private static func fetch() async -> MALDubLists {
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: MALDubLists.self, allowExpired: !online) { return cached }
    do {
      guard let url = URL(string: feedURL + "?timestamp=\(Int(Date().timeIntervalSince1970 * 1000))") else { throw ServiceError.invalidResponse }
      let json = try await HTTP.jsonObject(from: url) as? [String: Any]
      let lists = MALDubLists(dubbed: ServiceJSON.ints(json, "dubbed"), incomplete: ServiceJSON.ints(json, "incomplete"))
      if lists.dubbed.isEmpty { throw ServiceError.invalidResponse }
      await DiskCache.shared.set(cacheKey, lists, ttl: TimeInterval(Int.random(in: 100...200) * 60))
      return lists
    } catch {
      if let stale = await DiskCache.shared.get(cacheKey, as: MALDubLists.self, allowExpired: true) { return stale }
      ServiceMessages.send(.error, "Dub Caching Failed", "Failed to load dub information!")
      return MALDubLists()
    }
  }

  /// Synchronous check against the loaded lists (false until loaded).
  func isDubbed(malId: Int?) -> Bool {
    guard let malId else { return false }
    let current = state.get()
    return current.dubbed.contains(malId) || current.incomplete.contains(malId)
  }

  func isFullyDubbed(malId: Int?) -> Bool {
    guard let malId else { return false }
    return state.get().dubbed.contains(malId)
  }

  func isIncomplete(malId: Int?) -> Bool {
    guard let malId else { return false }
    return state.get().incomplete.contains(malId)
  }

  /// isDubMedia: by MAL id (dubbed or incomplete), or by audio language / file name keywords.
  func isDubMedia(malId: Int?, language: String? = nil, fileName: String? = nil) async -> Bool {
    let lists = await self.lists()
    if lists.dubbed.isEmpty && lists.incomplete.isEmpty { return false }
    if malId != nil { return isDubbed(malId: malId) }
    if language != nil || fileName != nil {
      return ServiceText.matchPhrase(language, ["English"], threshold: 3)
        || ServiceText.matchPhrase(fileName, ["Multi Audio", "Dual Audio", "English Audio", "English Dub"], threshold: 3)
        || ServiceText.matchPhrase(fileName, ["Dual", "Dub"], threshold: 1)
    }
    return false
  }
}
