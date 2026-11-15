import Foundation
import Observation
import UIKit

// Port of electron/src/main/trakt.js (account: device code flow, tokens, refresh, requests) and
// common/modules/sync/trakt.js (scrobbling targets, /sync/playback). The tokens are kept in the Keychain.
// The app credentials come from the build: Info.plist TraktClientID / TraktClientSecret = $(TRAKT_CLIENT_ID) /
// $(TRAKT_CLIENT_SECRET), set by the CI from the repository secrets. Empty: "Trakt is not available in this build".

/// What Trakt calls an episode or a movie: { movie: { ids } } or { show: { ids }, episode: { season, number } }.
struct TraktTarget: Hashable {
  var movieIds: [String: String] = [:]
  var showIds: [String: String] = [:]
  var season: Int?
  var number: Int?

  var isMovie: Bool { !movieIds.isEmpty }

  private static func jsonIds(_ ids: [String: String]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in ids {
      // Numeric ids (trakt, tmdb, tvdb) are sent as numbers, imdb / slug as text.
      if key != "imdb", key != "slug", let number = Int(value) {
        result[key] = number
      } else {
        result[key] = value
      }
    }
    return result
  }

  /// Body of a scrobble request (without the progress).
  var body: [String: Any] {
    if isMovie { return ["movie": ["ids": Self.jsonIds(movieIds)]] }
    return ["show": ["ids": Self.jsonIds(showIds)], "episode": ["season": season ?? 0, "number": number ?? 0]]
  }

  private static func sameIds(_ ids: [String: Any]?, _ wanted: [String: String]) -> Bool {
    guard let ids else { return false }
    for (key, value) in wanted {
      if let other = ids[key], "\(other)" == value { return true }
    }
    return false
  }

  /// A /sync/playback item about this movie / episode.
  func matches(_ item: [String: Any]) -> Bool {
    if isMovie {
      return item.string("type") == "movie" && Self.sameIds(item.dict("movie")?.dict("ids"), movieIds)
    }
    guard item.string("type") == "episode", Self.sameIds(item.dict("show")?.dict("ids"), showIds) else { return false }
    let episode = item.dict("episode")
    return episode?.int("season") == season && episode?.int("number") == number
  }
}

@Observable
@MainActor
final class TraktService {
  static let shared = TraktService()

  enum State: Equatable {
    case unavailable
    case disconnected
    case linking(code: String, url: URL, expiresAt: Date)
    case connected
  }

  private struct Token: Codable {
    var access: String
    var refresh: String
    var expiresAt: Date
    var user: String
  }

  private(set) var state: State = .unavailable
  private(set) var userName = ""
  private(set) var lastError: String?

  private let clientId: String
  private let clientSecret: String
  @ObservationIgnored private var token: Token?
  @ObservationIgnored private var linkTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Bool, Never>?
  @ObservationIgnored private var lastWrite = Date.distantPast
  @ObservationIgnored private var playbackCache: (date: Date, items: [[String: Any]])?

  private static let api = "https://api.trakt.tv"
  private static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
  private static let keychainAccount = "trakt.v1"
  /// Trakt allows one POST / PUT / DELETE per second per user.
  private static let writeSpacing: TimeInterval = 1.1

  var isAvailable: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
  var isConnected: Bool { state == .connected }

  private init() {
    clientId = Self.credential("TraktClientID")
    clientSecret = Self.credential("TraktClientSecret")
    guard !clientId.isEmpty, !clientSecret.isEmpty else { return }
    if let data = TsumiKeychain.data(for: Self.keychainAccount), let saved = try? JSONDecoder().decode(Token.self, from: data) {
      token = saved
      userName = saved.user
      state = .connected
    } else {
      state = .disconnected
    }
  }

  /// Info.plist value; an unexpanded "$(…)" or blank value means "not set".
  private static func credential(_ key: String) -> String {
    let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.hasPrefix("$(") ? "" : value
  }

  private var userAgent: String {
    "Tsumi/\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1") (iOS)"
  }

  private func headers(auth: Bool) -> [String: String] {
    var headers = [
      "Content-Type": "application/json",
      "User-Agent": userAgent,
      "trakt-api-version": "2",
      "trakt-api-key": clientId
    ]
    if auth, let token { headers["Authorization"] = "Bearer " + token.access }
    return headers
  }

  private func post(_ path: String, _ body: [String: Any], auth: Bool = false) async throws -> (Data, HTTPURLResponse) {
    guard let url = URL(string: Self.api + path) else { throw ServiceError.invalidResponse }
    let payload = try JSONSerialization.data(withJSONObject: body)
    return try await HTTP.data(url, method: "POST", headers: headers(auth: auth), body: payload, timeout: 30, allowErrorStatus: true)
  }

  // MARK: - Account

  /// Device code flow: shows the code, opens trakt.tv/activate and polls until the user approved it.
  func link() {
    guard isAvailable, linkTask == nil else { return }
    lastError = nil
    linkTask = Task { @MainActor [weak self] in
      await self?.runLink()
      self?.linkTask = nil
    }
  }

  private func runLink() async {
    do {
      let (data, response) = try await post("/oauth/device/code", ["client_id": clientId])
      guard (200..<300).contains(response.statusCode), let device = ServiceJSON.object(data),
            let deviceCode = device.string("device_code"), let userCode = device.string("user_code"),
            let url = URL(string: device.string("verification_url") ?? "https://trakt.tv/activate") else {
        throw ServiceError.api("Trakt returned \(response.statusCode).")
      }
      if Task.isCancelled { return }
      let expiresAt = Date().addingTimeInterval(device.double("expires_in") ?? 600)
      state = .linking(code: userCode, url: url, expiresAt: expiresAt)
      Self.openInBrowser(url)
      var interval = device.double("interval") ?? 5
      while Date() < expiresAt {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        if Task.isCancelled { return }
        let polled = try? await post("/oauth/device/token", ["code": deviceCode, "client_id": clientId, "client_secret": clientSecret])
        if Task.isCancelled { return }
        guard let poll = polled else { continue }
        let body = poll.0
        let reply = poll.1
        switch reply.statusCode {
        case 200:
          guard let json = ServiceJSON.object(body), saveToken(json, user: "") else {
            throw ServiceError.api("Trakt sent an unreadable answer, try again.")
          }
          await loadUser()
          state = .connected
          return
        case 400:
          continue // not approved yet
        case 429:
          interval += 1
          continue
        case 404:
          throw ServiceError.api("This code is not valid, try again.")
        case 409:
          throw ServiceError.api("This code was already used, try again.")
        case 410:
          throw ServiceError.api("The code expired, try again.")
        case 418:
          throw ServiceError.api("Access was denied on Trakt.")
        default:
          throw ServiceError.api("Trakt returned \(reply.statusCode), try again.")
        }
      }
      throw ServiceError.api("The code expired, try again.")
    } catch {
      if Task.isCancelled || error is CancellationError { return }
      lastError = error.localizedDescription
      state = token != nil ? .connected : .disconnected
    }
  }

  func cancelLink() {
    linkTask?.cancel()
    linkTask = nil
    lastError = nil
    if case .linking = state { state = token != nil ? .connected : .disconnected }
  }

  func unlink() {
    cancelLink()
    let old = token
    token = nil
    userName = ""
    playbackCache = nil
    TsumiKeychain.remove(Self.keychainAccount)
    if isAvailable { state = .disconnected }
    if let old {
      let body: [String: Any] = ["token": old.access, "client_id": clientId, "client_secret": clientSecret]
      Task { _ = try? await self.post("/oauth/revoke", body) }
    }
  }

  /// Opens a page in the browser (outside of the async context, so the completion handler variant is used).
  static func openInBrowser(_ url: URL) {
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  /// Name shown in Settings ("Connected as …").
  private func loadUser() async {
    guard let url = URL(string: Self.api + "/users/settings"),
          let result = try? await HTTP.data(url, headers: headers(auth: true), allowErrorStatus: true),
          (200..<300).contains(result.1.statusCode),
          let json = ServiceJSON.object(result.0), let user = json.dict("user") else { return }
    let name = user.string("username") ?? user.string("name") ?? ""
    userName = name
    token?.user = name
    persist()
  }

  @discardableResult
  private func saveToken(_ json: [String: Any], user: String) -> Bool {
    guard let access = json.string("access_token"), let refresh = json.string("refresh_token") else { return false }
    let created = json.double("created_at").map { Date(timeIntervalSince1970: $0) } ?? Date()
    token = Token(access: access, refresh: refresh, expiresAt: created.addingTimeInterval(json.double("expires_in") ?? 86_400), user: user)
    persist()
    return true
  }

  private func persist() {
    guard let token, let data = try? JSONEncoder().encode(token) else { return }
    TsumiKeychain.set(data, for: Self.keychainAccount)
  }

  /// Refreshes the access token; a refused refresh token disconnects the account.
  private func refresh() async -> Bool {
    if let refreshTask { return await refreshTask.value }
    guard let current = token else { return false }
    let task = Task { @MainActor [weak self] () -> Bool in
      guard let self else { return false }
      let body: [String: Any] = [
        "refresh_token": current.refresh,
        "client_id": self.clientId,
        "client_secret": self.clientSecret,
        "redirect_uri": Self.redirectURI,
        "grant_type": "refresh_token"
      ]
      guard let result = try? await self.post("/oauth/token", body) else { return false }
      let status = result.1.statusCode
      if (200..<300).contains(status), let json = ServiceJSON.object(result.0) {
        return self.saveToken(json, user: current.user)
      }
      if status == 400 || status == 401 {
        self.token = nil
        self.userName = ""
        TsumiKeychain.remove(Self.keychainAccount)
        self.lastError = "The Trakt session expired, connect again."
        self.state = .disconnected
      }
      return false
    }
    refreshTask = task
    let result = await task.value
    refreshTask = nil
    return result
  }

  // MARK: - Requests

  /// Authenticated request. Returns the status (0: not possible / network error) and the decoded JSON.
  func request(_ method: String, _ path: String, body: [String: Any]? = nil, retried: Bool = false) async -> (status: Int, json: Any?) {
    guard isAvailable, token != nil, let url = URL(string: Self.api + path) else { return (0, nil) }
    if let token, Date() > token.expiresAt.addingTimeInterval(-60) { _ = await refresh() }
    guard token != nil else { return (401, nil) }
    if method != "GET" {
      let wait = lastWrite.addingTimeInterval(Self.writeSpacing).timeIntervalSinceNow
      lastWrite = max(Date(), lastWrite.addingTimeInterval(Self.writeSpacing))
      if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
    let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    guard let result = try? await HTTP.data(url, method: method, headers: headers(auth: true), body: payload, timeout: 30, allowErrorStatus: true) else {
      return (0, nil)
    }
    let data = result.0
    let response = result.1
    if response.statusCode == 401, !retried, await refresh() {
      return await request(method, path, body: body, retried: true)
    }
    if response.statusCode == 429, !retried {
      let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
      try? await Task.sleep(nanoseconds: UInt64((retryAfter + 0.1) * 1_000_000_000))
      return await request(method, path, body: body, retried: true)
    }
    let json: Any? = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data))
    return (response.statusCode, json)
  }

  /// Items paused on any device (movies and episodes), newest first; cached for a minute.
  func playback(fresh: Bool = false) async -> [[String: Any]] {
    guard isConnected else { return [] }
    if !fresh, let cache = playbackCache, Date().timeIntervalSince(cache.date) < 60 { return cache.items }
    let result = await request("GET", "/sync/playback")
    guard result.status == 200, let items = result.json as? [[String: Any]] else { return playbackCache?.items ?? [] }
    let sorted = items.sorted { (Self.date($0) ?? .distantPast) > (Self.date($1) ?? .distantPast) }
    playbackCache = (Date(), sorted)
    return sorted
  }

  /// paused_at of a /sync/playback item.
  static func date(_ item: [String: Any]) -> Date? {
    guard let text = item.string("paused_at") else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  /// /scrobble/start | pause | stop. Stop at 80% or more marks it watched on Trakt, below it saves the progress.
  @discardableResult
  func scrobble(_ action: String, target: TraktTarget, progress: Double) async -> Int {
    var body = target.body
    body["progress"] = min(100, max(0, progress.isFinite ? progress : 0))
    let result = await request("POST", "/scrobble/\(action)", body: body)
    if action != "start" { playbackCache = nil }
    return result.status
  }

  // MARK: - Targets

  /// Season / episode of a TMDB show for an episode of the app (the session gives them, else the episode list).
  private func tmdbEpisode(_ media: Media, _ ref: EpisodeRef) async -> (season: Int, number: Int)? {
    if let season = ref.season, let local = ref.localEpisode { return (season, local) }
    let list = await MediaDetailsService.shared.quickEpisodes(for: media)
    guard let info = list.first(where: { $0.number == ref.number }), let season = info.season, let local = info.localEpisode else { return nil }
    return (season, local)
  }

  /// Target of an episode / movie; nil when it can't be told (anime without mappings, anime scrobbling off).
  func target(for media: Media, episode ref: EpisodeRef) async -> TraktTarget? {
    if media.source == .tmdb, let tmdbId = media.tmdbId {
      if media.isMovie { return TraktTarget(movieIds: ["tmdb": String(tmdbId)]) }
      guard let found = await tmdbEpisode(media, ref) else { return nil }
      return TraktTarget(showIds: ["tmdb": String(tmdbId)], season: found.season, number: found.number)
    }
    guard AppSettings.shared.values.traktScrobbleAnime, let anilistId = media.anilistId,
          let mappings = await AnimeMappingsService.shared.aniZip(anilistId: anilistId), let ids = mappings.mappings else { return nil }
    if media.isMovie {
      if let imdb = ids.imdbId, !imdb.isEmpty { return TraktTarget(movieIds: ["imdb": imdb]) }
      if let tmdb = ids.tmdbId { return TraktTarget(movieIds: ["tmdb": String(tmdb)]) }
      return nil
    }
    guard let show = ids.tvdbId, let data = mappings.episodes[String(ref.number)],
          let season = data.seasonNumber, let number = data.episodeNumber else { return nil }
    return TraktTarget(showIds: ["tvdb": String(show)], season: season, number: number)
  }
}
