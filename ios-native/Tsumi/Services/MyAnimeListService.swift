import Foundation

// Port of common/modules/myanimelist.js and the MAL parts of common/modules/settings.js
// (OAuth2 PKCE code exchange + token refresh). Rate limited to 20 requests / 4 s, 1 request / s.

/// Status mapping between AniList and MyAnimeList (cache.js mapStatus, helper.js airingMap).
enum MALStatusMap {
  static func toMAL(_ status: ListStatus) -> String {
    switch status {
    case .current, .repeating: return "watching"
    case .planning: return "plan_to_watch"
    case .completed: return "completed"
    case .dropped: return "dropped"
    case .paused: return "on_hold"
    }
  }

  static func fromMAL(_ status: String?, rewatching: Bool) -> ListStatus? {
    if rewatching { return .repeating }
    guard let status else { return nil }
    switch status {
    case "watching": return .current
    case "rewatching": return .repeating
    case "plan_to_watch": return .planning
    case "completed": return .completed
    case "dropped": return .dropped
    case "on_hold": return .paused
    default: return nil
    }
  }

  /// helper.js airingMap.
  static func airing(_ status: String?) -> MediaStatus? {
    guard let status else { return nil }
    switch status {
    case "finished_airing": return .finished
    case "currently_airing": return .releasing
    case "not_yet_aired": return .notYetReleased
    default: return nil
    }
  }

  /// helper.js sortMap (AniList user sort -> MAL sort name).
  static func sortMap(_ sort: String) -> String {
    switch sort {
    case "STARTED_ON_DESC": return "list_start_date_nan"
    case "FINISHED_ON_DESC": return "list_finish_date_nan"
    case "PROGRESS_DESC": return "list_progress_nan"
    case "USER_SCORE_DESC": return "list_score"
    default: return "list_updated_at"
    }
  }
}

final class MyAnimeListService: @unchecked Sendable {
  static let shared = MyAnimeListService()

  /// App type MUST be "other" on MAL, no seed (same client as the desktop app).
  static let clientID = ServiceText.base64("ZDZjNTlhNjI4M2U1NWU3NGZlMDQyMDY4OTk0ZTRmYjY=")
  static let apiBase = "https://api.myanimelist.net/v2/"
  static let tokenURL: URL = URL(string: "https://myanimelist.net/v1/oauth2/token") ?? URL(fileURLWithPath: "/")
  static let defaultAvatar = URL(string: "https://cdn.myanimelist.net/images/kaomoji_mal_white.png")

  static let queryFields: String = [
    "synopsis", "alternative_titles", "mean", "rank", "popularity", "num_list_users", "num_scoring_users",
    "related_anime", "media_type", "num_episodes", "status", "my_list_status", "start_date", "end_date",
    "start_season", "broadcast", "studios", "authors{first_name,last_name}", "source", "genres",
    "average_episode_duration", "rating"
  ].joined(separator: ",")

  private let limiter = ServiceRateLimiter(capacity: 20, interval: 4, minSpacing: 1)
  /// Tokens whose refresh MyAnimeList rejected (invalid_grant): the profile must log in again.
  private let failedRefresh = ServiceLocked<Set<String>>([])
  /// Tokens whose refresh failed for a transient reason (network, 5xx, 429): next attempt not before this date.
  private let refreshRetryAt = ServiceLocked<[String: Date]>([:])
  private let refreshes = ServiceInflight()

  /// Wait before retrying a refresh that failed for a transient reason.
  private static let refreshRetryDelay: TimeInterval = 5 * 60

  private init() {}

  // MARK: - Transport

  /// malRequest + handleRequest. Returns the JSON (or an empty dictionary for empty bodies),
  /// nil when the profile needs to re-authenticate or the request failed.
  func request(path: String, method: String = "GET", query: [URLQueryItem] = [], form: [String: String] = [:], profile: AccountProfile? = nil, explicitToken: String? = nil, retried: Bool = false) async throws -> Any? {
    guard ServiceNetworkMonitor.shared.isOnline else { throw ServiceError.offline }
    var target = profile ?? AccountStore.shared.current
    let token: String
    if let explicitToken {
      token = explicitToken
    } else {
      guard var account = target, account.viewer.service == .myanimelist else { throw ServiceError.notAuthorized }
      if failedRefresh.get().contains(account.token) { return nil }
      if account.reauth {
        // Older versions marked a profile `reauth` after any failed refresh (even offline): its refresh token is
        // tried again (at most every 5 minutes, never after a rejection), so a profile that was never really
        // rejected comes back without a new login.
        guard let healed = await healExpired(account) else { return nil }
        account = healed
      } else if let refreshAt = account.refreshAt, Date() >= refreshAt, canRetryRefresh(account.token) {
        if let refreshed = await refreshToken(account) {
          account = refreshed
        } else if failedRefresh.get().contains(account.token) {
          return nil
        }
        // A transient failure keeps the current token: it is valid 31 days and refreshed after 14.
      }
      target = account
      token = account.token
    }
    guard var components = URLComponents(string: Self.apiBase + path) else { throw ServiceError.invalidResponse }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw ServiceError.invalidResponse }
    let headers = ["Authorization": "Bearer " + token, "Content-Type": "application/x-www-form-urlencoded"]
    let body: Data? = form.isEmpty ? nil : ServiceJSON.formBody(form)
    var attempt = 0
    while true {
      attempt += 1
      await limiter.acquire()
      let (data, response) = try await HTTP.data(url, method: method, headers: headers, body: body, timeout: 60, allowErrorStatus: true)
      if response.statusCode == 429 || response.statusCode == 500 {
        if attempt >= 4 {
          ServiceMessages.send(.error, "Search Failed", "Failed making request to MyAnimeList!\nTry again in a minute.")
          throw ServiceError.rateLimited
        }
        let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
        await limiter.pause(for: response.statusCode == 500 ? 1 : retryAfter + 1)
        continue
      }
      let json: Any? = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data))
      if (200..<300).contains(response.statusCode) {
        return json ?? [String: Any]()
      }
      if response.statusCode == 404 { return json }
      let errorCode = (json as? [String: Any])?.string("error")
      if (errorCode == "invalid_token" || response.statusCode == 401), explicitToken == nil, !retried, let account = target {
        if canRetryRefresh(account.token), let refreshed = await refreshToken(account) {
          return try await request(path: path, method: method, query: query, form: form, profile: refreshed, retried: true)
        }
        return nil
      }
      ServiceMessages.send(.error, "Search Failed", "Failed making request to MyAnimeList!\nTry again in a minute.\n\(errorCode ?? String(response.statusCode))")
      return nil
    }
  }

  // MARK: - OAuth

  /// handleMalToken: exchanges the PKCE authorization code (plain challenge = verifier).
  func exchangeCode(_ code: String, verifier: String) async throws -> (accessToken: String, refreshToken: String?) {
    let form = [
      "client_id": Self.clientID,
      "grant_type": "authorization_code",
      "code": code,
      "code_verifier": verifier
    ]
    let (data, response) = try await HTTP.data(Self.tokenURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: ServiceJSON.formBody(form), allowErrorStatus: true)
    guard (200..<300).contains(response.statusCode), let json = ServiceJSON.object(data), let access = json.string("access_token") else {
      throw ServiceError.api("Failed to sign in with MyAnimeList. Please try again. (\(response.statusCode))")
    }
    return (access, json.string("refresh_token"))
  }

  /// refreshMalToken: refreshes the token (it expires every 31 days; refreshed every two weeks).
  func refreshToken(_ profile: AccountProfile) async -> AccountProfile? {
    let key = profile.token
    let result: AccountProfile? = try? await refreshes.run(key) {
      await self.performRefresh(profile)
    }
    return result ?? nil
  }

  /// Whether a refresh may be sent now (not waiting after a transient failure).
  private func canRetryRefresh(_ token: String) -> Bool {
    guard let retryAt = refreshRetryAt.get()[token] else { return true }
    return Date() >= retryAt
  }

  /// A profile marked `reauth` that still has a refresh token: a refresh that works clears the mark.
  private func healExpired(_ profile: AccountProfile) async -> AccountProfile? {
    guard let refresh = profile.refreshToken, !refresh.isEmpty, canRetryRefresh(profile.token) else { return nil }
    return await refreshToken(profile)
  }

  /// Whether a token endpoint answer says the refresh token is dead (a new login is the only way): 400 / 401 with
  /// `invalid_grant`, or the "The refresh token is invalid" `invalid_request` of the OAuth server MyAnimeList uses.
  static func isRefreshRejected(status: Int, json: [String: Any]?) -> Bool {
    guard status == 400 || status == 401 else { return false }
    let error = json?.string("error") ?? ""
    if error == "invalid_grant" { return true }
    let message = ((json?.string("message") ?? "") + " " + (json?.string("hint") ?? "")).lowercased()
    return error == "invalid_request" && message.contains("refresh token")
  }

  private func performRefresh(_ profile: AccountProfile) async -> AccountProfile? {
    guard let refresh = profile.refreshToken, !refresh.isEmpty else {
      // No refresh token: only a new login can renew the session.
      expire(profile)
      return nil
    }
    let form = ["client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await HTTP.data(Self.tokenURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: ServiceJSON.formBody(form), allowErrorStatus: true)
    } catch {
      // Offline, timeout...: the old token is kept and the refresh tried again later.
      deferRefresh(profile.token)
      return nil
    }
    let json = ServiceJSON.object(data)
    if (200..<300).contains(response.statusCode), let access = json?.string("access_token") {
      let refreshedViewer = (try? await self.viewer(token: access)) ?? profile.viewer
      let refreshed = AccountProfile(viewer: refreshedViewer, token: access, refreshToken: json?.string("refresh_token") ?? refresh, refreshAt: Date().addingTimeInterval(14 * 24 * 3600), reauth: false, customLists: profile.customLists)
      refreshRetryAt.update { $0[profile.token] = nil }
      AccountStore.shared.replaceProfile(oldToken: profile.token, with: refreshed)
      return refreshed
    }
    if Self.isRefreshRejected(status: response.statusCode, json: json) {
      expire(profile)
    } else {
      // 5xx, 429 or an unexpected answer: MyAnimeList may be down, the session is not dead.
      deferRefresh(profile.token)
    }
    return nil
  }

  private func deferRefresh(_ token: String) {
    refreshRetryAt.update { $0[token] = Date().addingTimeInterval(Self.refreshRetryDelay) }
  }

  /// The refresh was rejected: the profile needs a new login (prompted once, SessionExpiry.swift).
  private func expire(_ profile: AccountProfile) {
    if !profile.reauth {
      // "Your MyAnimeList session has expired": Log in again / Log out (SessionExpiry.swift).
      Task { @MainActor in SessionExpiryCenter.shared.prompt(profile, kind: .expired) }
    }
    failedRefresh.update { $0.insert(profile.token) }
    AccountStore.shared.markReauth(token: profile.token)
  }

  // MARK: - API

  /// users/@me (viewer). MAL does not return the default picture, so it is filled in.
  func viewer(token: String) async throws -> Viewer {
    let response = try await request(path: "users/@me", explicitToken: token) as? [String: Any]
    guard let json = response, let id = json.int("id") else {
      throw ServiceError.api("Failed to sign in with MyAnimeList. Please try again.")
    }
    return Viewer(id: id, name: json.string("name") ?? "MyAnimeList User", avatar: URL.lenient(json.string("picture")) ?? Self.defaultAvatar, service: .myanimelist)
  }

  /// users/@me/animelist, every page (limit 1000). `sort` is a MAL sort (list_updated_at, list_score...).
  func userLists(sort: String = "list_updated_at", profile: AccountProfile? = nil) async throws -> [UserListItem] {
    let serverSort = sort.hasSuffix("_nan") ? "list_updated_at" : sort
    var offset = 0
    var items: [UserListItem] = []
    while true {
      let query = [
        URLQueryItem(name: "fields", value: Self.queryFields),
        URLQueryItem(name: "nsfw", value: "true"),
        URLQueryItem(name: "limit", value: "1000"),
        URLQueryItem(name: "offset", value: String(offset)),
        URLQueryItem(name: "sort", value: serverSort)
      ]
      guard let json = try await request(path: "users/@me/animelist", query: query, profile: profile) as? [String: Any],
            let data = json["data"] as? [[String: Any]] else {
        throw ServiceError.api("Failed to load the MyAnimeList list")
      }
      items.append(contentsOf: data.compactMap { UserListItem.fromMAL($0) })
      if data.count < 1000 { break }
      offset += 1000
    }
    return items
  }

  /// Whether a my_list_status answer is a success: `request` also returns the JSON of a 404, and MyAnimeList
  /// error bodies are `{ "error": ... }` objects, which must not count as an update (no "List Updated" toast).
  static func isSuccess(_ result: Any?) -> Bool {
    guard let result else { return false }
    if let object = result as? [String: Any] { return object["error"] == nil }
    return result is [Any]
  }

  /// PUT anime/{id}/my_list_status. Only the fields given are changed by MyAnimeList: a nil score or rewatch count
  /// keeps the stored one.
  func saveEntry(malId: Int, input: ListEntryInput, profile: AccountProfile? = nil) async throws -> Bool {
    var startDate = input.startedAt?.isoDay
    var finishDate = input.completedAt?.isoDay
    if let start = startDate, let finish = finishDate, start > finish {
      let now = Date()
      finishDate = ServiceDates.dayString(now)
      startDate = ServiceDates.dayString(now.addingTimeInterval(-86400))
    }
    var form: [String: String] = [
      "status": MALStatusMap.toMAL(input.status),
      "is_rewatching": input.status == .repeating ? "true" : "false",
      "num_watched_episodes": String(input.progress)
    ]
    if let repeatCount = input.repeatCount { form["num_times_rewatched"] = String(repeatCount) }
    if let score = input.scoreRaw { form["score"] = String(score) }
    if let startDate { form["start_date"] = startDate }
    if let finishDate { form["finish_date"] = finishDate }
    let result = try await request(path: "anime/\(malId)/my_list_status", method: "PUT", form: form, profile: profile)
    return Self.isSuccess(result)
  }

  /// DELETE anime/{id}/my_list_status. A 404 means the entry is already gone, which is what was asked.
  func deleteEntry(malId: Int, profile: AccountProfile? = nil) async throws -> Bool {
    let result = try await request(path: "anime/\(malId)/my_list_status", method: "DELETE", profile: profile)
    return Self.isSuccess(result) || (result as? [String: Any])?.string("error") == "not_found"
  }

  /// my_list_status of one anime for a profile (other profiles kept in sync): nil when it is not on the list.
  /// Throws when it could not be read.
  func listStatus(malId: Int, profile: AccountProfile? = nil) async throws -> UserListItem? {
    let query = [URLQueryItem(name: "fields", value: "my_list_status{status,score,num_episodes_watched,is_rewatching,num_times_rewatched,start_date,finish_date,updated_at},num_episodes,media_type,status")]
    guard let json = try await request(path: "anime/\(malId)", query: query, profile: profile) as? [String: Any],
          json["error"] == nil, json.int("id") != nil else {
      throw ServiceError.api("Failed to read the MyAnimeList entry")
    }
    return UserListItem.fromMAL(["node": json])
  }
}
