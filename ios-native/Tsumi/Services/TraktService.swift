import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

// Port of electron/src/main/trakt.js (account: sign-in with the authorization code flow and PKCE, tokens, refresh,
// requests) and common/modules/sync/trakt.js (scrobbling targets, /sync/playback). The tokens are kept in the Keychain.
// The Client ID comes from the build: Info.plist TraktClientID = $(TRAKT_CLIENT_ID), set by the CI from the repository
// secret. Empty: "Trakt is not available in this build". There is no client secret (https://developer.trakt.tv/docs/pkce).

/// PKCE helpers of the Trakt sign-in (electron/src/main/traktAuth.js).
enum TraktPKCE {
  /// Every OAuth request (authorize, token, refresh, revoke) goes to this host, not to the API host.
  static let authHost = "https://auth.trakt.tv"
  /// Redirect URI registered in the Trakt app: a GitHub Pages page (docs/trakt/index.html) that opens
  /// tsumi://trakt/callback. Identical in the authorize request, the token exchange and the refresh.
  static let redirectURI = "https://mxfia19.github.io/Tsumi/trakt/"
  static let callbackScheme = "tsumi"

  static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Random base64url text (SystemRandomNumberGenerator is cryptographically secure); 32 bytes give the 43 characters
  /// of a code_verifier.
  static func random(bytes: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return base64url(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  /// code_challenge of a code_verifier: base64url (no padding) of its SHA-256.
  static func challenge(for verifier: String) -> String {
    base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func authorizeURL(clientId: String, state: String, challenge: String) -> URL? {
    var components = URLComponents(string: authHost + "/oauth/authorize")
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256")
    ]
    return components?.url
  }

  /// tsumi://trakt/... links.
  static func isCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == callbackScheme && url.host?.lowercased() == "trakt"
  }

  /// code / state / error of tsumi://trakt/callback?code=...&state=...; nil without a code or an error.
  static func callback(_ url: URL) -> (code: String, state: String, error: String)? {
    guard isCallback(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func value(_ name: String) -> String {
      var text = (items.first(where: { $0.name == name })?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      while text.hasSuffix("/") { text.removeLast() }
      return text
    }
    let code = value("code")
    let error = value("error")
    guard !code.isEmpty || !error.isEmpty else { return nil }
    return (code, value("state"), error)
  }

  /// OAuth error code reduced to a short word that is safe to show (never the description).
  static func errorCode(_ error: String) -> String {
    String(error.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }.prefix(40))
  }

  /// Message for an error=... of the authorize redirect.
  static func errorMessage(_ error: String) -> String {
    if error == "access_denied" { return "Access was denied on Trakt." }
    let code = errorCode(error)
    return "Trakt could not sign you in (\(code.isEmpty ? "unknown error" : code)), try again."
  }
}

/// ASWebAuthenticationSession of the Trakt sign-in. The authorize page ends on the https redirect page, which navigates
/// to tsumi://trakt/callback: the session catches that link (callbackURLScheme "tsumi") and closes. Can be cancelled
/// (Cancel in Settings, task cancellation) or completed by a callback that reached the app through onOpenURL.
@MainActor
final class TraktWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?
  private var continuation: CheckedContinuation<URL, Error>?

  func authenticate(url: URL) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        self.continuation = continuation
        // The session is released by finish(), which breaks the reference cycle through this handler.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: TraktPKCE.callbackScheme) { callbackURL, error in
          let result: Result<URL, Error> = callbackURL.map { .success($0) } ?? .failure(error ?? ServiceError.cancelled)
          Task { @MainActor [weak self] in
            self?.finish(result, closeSession: false)
          }
        }
        session.presentationContextProvider = self
        // Shares the Safari cookies, so a user already signed in to Trakt only has to allow the app.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
          self.finish(.failure(ServiceError.api("Could not open the Trakt sign-in page.")), closeSession: false)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(.failure(CancellationError()), closeSession: true)
      }
    }
  }

  /// A tsumi://trakt/callback link that reached the app outside of the session (onOpenURL). Returns false when no
  /// sign-in is waiting.
  func deliver(_ url: URL) -> Bool {
    guard continuation != nil else { return false }
    finish(.success(url), closeSession: true)
    return true
  }

  private func finish(_ result: Result<URL, Error>, closeSession: Bool) {
    let session = self.session
    self.session = nil
    if closeSession { session?.cancel() }
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
    }
    if let scene = scenes.first {
      if let window = scene.windows.first { return window }
      return UIWindow(windowScene: scene)
    }
    return ASPresentationAnchor()
  }
}

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
    /// Sign-in page open (ASWebAuthenticationSession), then token exchange.
    case linking
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
  @ObservationIgnored private var token: Token?
  @ObservationIgnored private var linkTask: Task<Void, Never>?
  @ObservationIgnored private var linkGeneration = 0
  @ObservationIgnored private var authenticator: TraktWebAuthenticator?
  @ObservationIgnored private var refreshTask: Task<Bool, Never>?
  @ObservationIgnored private var lastWrite = Date.distantPast
  @ObservationIgnored private var playbackCache: (date: Date, items: [[String: Any]])?

  private static let api = "https://api.trakt.tv"
  private static let keychainAccount = "trakt.v1"
  /// Trakt allows one POST / PUT / DELETE per second per user.
  private static let writeSpacing: TimeInterval = 1.1

  var isAvailable: Bool { !clientId.isEmpty }
  var isConnected: Bool { state == .connected }

  private init() {
    clientId = Self.credential("TraktClientID")
    guard !clientId.isEmpty else { return }
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

  /// OAuth request (token exchange, refresh, revoke): auth.trakt.tv, with the Client ID only.
  private func postAuth(_ path: String, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
    guard let url = URL(string: TraktPKCE.authHost + path) else { throw ServiceError.invalidResponse }
    let payload = try JSONSerialization.data(withJSONObject: body)
    return try await HTTP.data(url, method: "POST", headers: headers(auth: false), body: payload, timeout: 30, allowErrorStatus: true)
  }

  // MARK: - Account

  /// Sign-in with the authorization code flow and PKCE: Trakt's authorize page in an ASWebAuthenticationSession,
  /// then the code (from tsumi://trakt/callback) is exchanged with the code_verifier of this attempt.
  func link() {
    guard isAvailable, linkTask == nil else { return }
    lastError = nil
    linkGeneration += 1
    let generation = linkGeneration
    linkTask = Task { @MainActor [weak self] in
      await self?.runLink()
      if self?.linkGeneration == generation { self?.linkTask = nil }
    }
  }

  private func runLink() async {
    let verifier = TraktPKCE.random(bytes: 32)
    let expectedState = TraktPKCE.random(bytes: 24)
    guard let url = TraktPKCE.authorizeURL(clientId: clientId, state: expectedState, challenge: TraktPKCE.challenge(for: verifier)) else { return }
    state = .linking
    let authenticator = TraktWebAuthenticator()
    self.authenticator = authenticator
    defer { if self.authenticator === authenticator { self.authenticator = nil } }
    do {
      let callbackURL = try await authenticator.authenticate(url: url)
      if Task.isCancelled { return }
      // Only the answer to this attempt is accepted (an old or forged link carries another state).
      guard let result = TraktPKCE.callback(callbackURL), result.state == expectedState else {
        throw ServiceError.api("Trakt sent back an invalid answer, try again.")
      }
      if !result.error.isEmpty || result.code.isEmpty { throw ServiceError.api(TraktPKCE.errorMessage(result.error)) }
      let (data, response) = try await postAuth("/oauth/token", [
        "code": result.code,
        "client_id": clientId,
        "redirect_uri": TraktPKCE.redirectURI,
        "grant_type": "authorization_code",
        "code_verifier": verifier
      ])
      if Task.isCancelled { return }
      guard (200..<300).contains(response.statusCode) else {
        let code = TraktPKCE.errorCode(ServiceJSON.object(data)?.string("error") ?? "")
        throw ServiceError.api("Trakt refused the sign-in (\(code.isEmpty ? String(response.statusCode) : code)), try again.")
      }
      guard let json = ServiceJSON.object(data), saveToken(json, user: "") else {
        throw ServiceError.api("Trakt sent an unreadable answer, try again.")
      }
      await loadUser()
      if Task.isCancelled { return }
      state = .connected
    } catch {
      if Task.isCancelled || error is CancellationError { return }
      // Closing the sign-in sheet is not an error.
      if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
        state = token != nil ? .connected : .disconnected
        return
      }
      lastError = error.localizedDescription
      state = token != nil ? .connected : .disconnected
    }
  }

  /// tsumi://trakt/... that reached the app through onOpenURL (the sign-in session normally catches it): completes
  /// the running sign-in, which checks its state; ignored when none is running.
  func handleCallback(_ url: URL) {
    _ = authenticator?.deliver(url)
  }

  func cancelLink() {
    linkTask?.cancel()
    linkTask = nil
    linkGeneration += 1
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
      let body: [String: Any] = ["token": old.access, "client_id": clientId]
      Task { _ = try? await self.postAuth("/oauth/revoke", body) }
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

  /// Refreshes the access token (refresh tokens are single-use: the answer replaces both); a refused refresh token
  /// disconnects the account.
  private func refresh() async -> Bool {
    if let refreshTask { return await refreshTask.value }
    guard let current = token else { return false }
    let task = Task { @MainActor [weak self] () -> Bool in
      guard let self else { return false }
      let body: [String: Any] = [
        "refresh_token": current.refresh,
        "client_id": self.clientId,
        "redirect_uri": TraktPKCE.redirectURI,
        "grant_type": "refresh_token"
      ]
      guard let result = try? await self.postAuth("/oauth/token", body) else { return false }
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
    // A Sora module result played as it is is no Trakt title: never scrobbled.
    if media.isSoraResult { return nil }
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
