import Foundation
import Observation

// Port of common/modules/auth/token.js + auth/expiry.js: AniList / MyAnimeList session expiry.
// AniList access tokens are JWTs that expire about a year after the login (payload `exp`) and can be revoked
// earlier (AniList then answers 401 or "Invalid token"). A dead token marks its profile `reauth`, is no longer
// sent (public AniList queries keep working without it) and shows one persistent prompt per session
// (UI/Shell/ShellSessionExpiry.swift): "Log in again" re-runs the login of that profile (swapProfiles keeps it),
// "Log out" removes it. MyAnimeList tokens are refreshed first: the prompt only comes when the refresh fails.
// A known AniList expiry also warns `warningDays` before.

enum SessionToken {
  /// Days before a known expiry when the "expires soon" prompt is shown.
  static let warningDays = 7
  static let expiredMessage = "Your AniList session has expired. Log in again to keep your list in sync."

  enum State: Equatable {
    case expired
    case expiring
    case valid
    case unknown
  }

  /// The token without a "Bearer " prefix.
  static func bare(_ token: String) -> String {
    var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    return value
  }

  /// `exp` of a JWT access token, nil when the token is not a JWT or has no expiry.
  static func expiry(of token: String) -> Date? {
    let parts = bare(token).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: base64),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let exp: Double?
    if let number = payload["exp"] as? NSNumber {
      exp = number.doubleValue
    } else if let text = payload["exp"] as? String {
      exp = Double(text)
    } else {
      exp = nil
    }
    guard let exp, exp.isFinite, exp > 0 else { return nil }
    return Date(timeIntervalSince1970: exp)
  }

  static func state(_ expiresAt: Date?, now: Date = Date()) -> State {
    guard let expiresAt else { return .unknown }
    if now >= expiresAt { return .expired }
    if expiresAt.timeIntervalSince(now) <= TimeInterval(warningDays * 24 * 3600) { return .expiring }
    return .valid
  }

  /// Whole days left before `expiresAt` (at least 1).
  static func daysLeft(_ expiresAt: Date, now: Date = Date()) -> Int {
    Swift.max(1, Int((expiresAt.timeIntervalSince(now) / (24 * 3600)).rounded(.up)))
  }

  /// Saved expiry of an AniList profile, else its token's own `exp`.
  static func profileExpiry(_ profile: AccountProfile) -> Date? {
    profile.expiresAt ?? expiry(of: profile.token)
  }

  /// Whether an AniList response says the token is not accepted (expired or revoked).
  static func isAniListAuthError(status: Int, json: [String: Any]?) -> Bool {
    if status == 401 { return true }
    let errors = json?["errors"] as? [[String: Any]] ?? []
    return errors.contains { error in
      error.int("status") == 401 || (error.string("message") ?? "").range(of: "invalid token", options: .caseInsensitive) != nil
    }
  }

  /// Whether a GraphQL document is a mutation.
  static func isMutation(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation")
  }

  /// The stored profile (current or other) using this token.
  static func profile(for token: String) -> (profile: AccountProfile, isCurrent: Bool)? {
    let wanted = bare(token)
    guard !wanted.isEmpty else { return nil }
    let snapshot = AccountStore.shared.snapshot
    if let current = snapshot.current, bare(current.token) == wanted { return (current, true) }
    if let other = snapshot.others.first(where: { bare($0.token) == wanted }) { return (other, false) }
    return nil
  }

  /// Whether an AniList token can still be sent: not marked expired and its JWT `exp` not passed.
  static func isAniListTokenUsable(_ token: String) -> Bool {
    if bare(token).isEmpty { return false }
    if profile(for: token)?.profile.reauth == true { return false }
    return state(expiry(of: token)) != .expired
  }

  /// A token was refused (or its refresh failed): marks its profile `reauth` and prompts once. Any thread.
  static func markExpired(token: String) {
    guard let found = profile(for: token) else { return }
    let stored = found.profile
    if !stored.reauth { AccountStore.shared.markReauth(token: stored.token) }
    Task { @MainActor in
      SessionExpiryCenter.shared.prompt(stored, kind: .expired)
    }
  }
}

/// Persistent session prompts (svelte-sonner toasts with Log in again / Log out on the desktop app).
@Observable
@MainActor
final class SessionExpiryCenter {
  static let shared = SessionExpiryCenter()

  enum Kind: String, Equatable {
    case expired
    case expiring
  }

  struct Prompt: Identifiable, Equatable {
    var id: String { profileId + "-" + kind.rawValue }
    let profileId: String
    let viewerId: Int
    let service: Viewer.Service
    let name: String
    let kind: Kind
    let daysLeft: Int?

    var serviceName: String { service == .anilist ? "AniList" : "MyAnimeList" }
    var title: String {
      kind == .expired ? "Your \(serviceName) session has expired" : "Your \(serviceName) session expires soon"
    }
    var message: String {
      if kind == .expired {
        return "\(name) is signed out of \(serviceName): list updates are paused until you log in again."
      }
      let days = daysLeft ?? 1
      return "The session of \(name) ends in \(days) day\(days == 1 ? "" : "s"). Log in again to keep your list in sync."
    }
  }

  private(set) var prompts: [Prompt] = []
  /// Prompts shown this session (dismissed ones included).
  @ObservationIgnored private var shown = Set<String>()
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    // A new login (or a log out) resolves the profile's prompts.
    observer = NotificationCenter.default.addObserver(forName: AccountStore.didChange, object: nil, queue: .main) { _ in
      Task { @MainActor in
        SessionExpiryCenter.shared.pruneResolved()
      }
    }
  }

  /// Shows the prompt of a profile, once per session and kind.
  func prompt(_ profile: AccountProfile, kind: Kind) {
    let prompt = Prompt(
      profileId: profile.id,
      viewerId: profile.viewer.id,
      service: profile.viewer.service,
      name: profile.viewer.name,
      kind: kind,
      daysLeft: kind == .expiring ? SessionToken.profileExpiry(profile).map { SessionToken.daysLeft($0) } : nil
    )
    guard !shown.contains(prompt.id) else { return }
    shown.insert(prompt.id)
    prompts.append(prompt)
  }

  func dismiss(_ prompt: Prompt) {
    prompts.removeAll { $0.id == prompt.id }
  }

  /// "Log in again": opens the profiles sheet (it hosts the login web view) and runs the profile's login.
  func logInAgain(_ prompt: Prompt) {
    dismiss(prompt)
    let profile = storedProfile(prompt)
    AppRouter.shared.showProfiles = true
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 600_000_000)
      if let profile {
        _ = await ProfilesService.shared.reauthenticate(profile)
      } else if prompt.service == .anilist {
        _ = await ProfilesService.shared.loginAniList()
      } else {
        _ = await ProfilesService.shared.loginMAL()
      }
    }
  }

  /// "Log out": signs the current profile out (the next one takes over) or removes another profile.
  func logOut(_ prompt: Prompt) {
    dismiss(prompt)
    let service = ProfilesService.shared
    if service.current?.id == prompt.profileId {
      service.logout()
    } else if let other = service.others.first(where: { $0.id == prompt.profileId }) {
      service.drop(other)
    }
  }

  /// Startup check: the current profile and the other profiles kept in sync. Expired AniList tokens (JWT
  /// `exp`) are marked, profiles already marked are prompted again (once per session), AniList tokens ending
  /// within `warningDays` get a warning. MyAnimeList is prompted when a refresh fails.
  func checkStoredSessions() {
    let snapshot = AccountStore.shared.snapshot
    let others = snapshot.others.filter { snapshot.sync.contains($0.viewer.id) }
    for profile in [snapshot.current].compactMap({ $0 }) + others {
      if profile.reauth {
        prompt(profile, kind: .expired)
        continue
      }
      guard profile.isAniList else { continue }
      switch SessionToken.state(SessionToken.profileExpiry(profile)) {
      case .expired: SessionToken.markExpired(token: profile.token)
      case .expiring: prompt(profile, kind: .expiring)
      case .valid, .unknown: break
      }
    }
  }

  /// Runs `checkStoredSessions` a few seconds after the launch.
  func scheduleStartupCheck() {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      checkStoredSessions()
    }
  }

  private func storedProfile(_ prompt: Prompt) -> AccountProfile? {
    let snapshot = AccountStore.shared.snapshot
    return ([snapshot.current].compactMap { $0 } + snapshot.others).first { $0.id == prompt.profileId }
  }

  /// Drops the prompts whose profile logged in again (no longer `reauth`) or was removed.
  private func pruneResolved() {
    prompts.removeAll { prompt in
      guard let profile = storedProfile(prompt) else { return true }
      return prompt.kind == .expired ? !profile.reauth : SessionToken.state(SessionToken.profileExpiry(profile)) == .valid
    }
  }
}
