import Foundation
import Observation
import AuthenticationServices
import UIKit

// Port of common/components/Profiles.svelte + settings.js handleToken / handleMalToken / swapProfiles.
// Logins run in an in-app web view (like the Electron 'open-auth' window): AniList implicit grant (client
// 35971, whose registered redirect is the AniList pin page https://anilist.co/api/v2/oauth/pin#access_token=...)
// and MyAnimeList OAuth2 PKCE with a plain challenge (redirect with ?code=...&state=...). The web view
// (UI/Shell/ProfilesView.swift) watches every URL it loads and hands the first one carrying the result to
// `finishWebLogin(_:request:)`. A pasted token / pin URL is the fallback (`login(pasted:)`).

/// A login page shown in the in-app web view sheet.
struct TsumiWebLoginRequest: Identifiable {
  let id: UUID
  let url: URL
  /// "AniList" / "MyAnimeList".
  let title: String
  /// MyAnimeList `state` the redirect must carry.
  let malState: String?
}

/// ASWebAuthenticationSession wrapper (kept for `authenticateOverride` style integrations; the default
/// flow is the web view sheet because the AniList client does not redirect to tsumi://).
@MainActor
final class TsumiWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
        if let callbackURL {
          continuation.resume(returning: callbackURL)
        } else {
          continuation.resume(throwing: error ?? ServiceError.cancelled)
        }
      }
      session.presentationContextProvider = self
      // Keep the browser cookies so the next login is remembered (Profiles.svelte opens the system browser).
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() {
        self.session = nil
        continuation.resume(throwing: ServiceError.api("Could not open the login page."))
      }
    }
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

@Observable
@MainActor
final class ProfilesService {
  static let shared = ProfilesService()

  /// Custom URL scheme registered as redirect URI on AniList and MyAnimeList (Info.plist: tsumi, shiru).
  static let callbackScheme = "tsumi"
  static let aniListClientID = ServiceText.base64("MzU5NzE=")
  static let maxOtherProfiles = 5

  private(set) var current: AccountProfile?
  private(set) var others: [AccountProfile] = []
  private(set) var syncIds: [Int] = []
  private(set) var isLoggingIn = false
  private(set) var lastError: String?
  /// Login page the profiles UI shows in its web view sheet (nil when no login runs).
  private(set) var webLogin: TsumiWebLoginRequest?

  /// Optional replacement of the web view login, e.g. SwiftUI's
  /// `webAuthenticationSession.authenticate(using:callbackURLScheme:preferredBrowserSession:)`.
  @ObservationIgnored var authenticateOverride: ((URL, String) async throws -> URL)?

  @ObservationIgnored private var authenticator: TsumiWebAuthenticator?
  @ObservationIgnored private var pendingMALStates: [String: String] = [:]
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var webLoginContinuation: CheckedContinuation<URL?, Never>?

  private init() {
    reload()
    observer = NotificationCenter.default.addObserver(forName: AccountStore.didChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.reload()
      }
    }
  }

  var isAuthorized: Bool { current != nil }
  var isAniList: Bool { current?.viewer.service == .anilist }
  var isMAL: Bool { current?.viewer.service == .myanimelist }
  var viewer: Viewer? { current?.viewer }
  /// The "Add Profile" button is shown while there are fewer than 5 other profiles.
  var canAddProfile: Bool { others.count < Self.maxOtherProfiles }

  func isSynced(_ profile: AccountProfile) -> Bool {
    syncIds.contains(profile.viewer.id)
  }

  private func reload() {
    let snapshot = AccountStore.shared.snapshot
    current = snapshot.current
    others = snapshot.others
    syncIds = snapshot.sync
  }

  // MARK: - Login

  /// confirmAnilist: implicit grant, the token comes back in the URL fragment.
  @discardableResult
  func loginAniList() async -> Bool {
    guard let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(Self.aniListClientID)&response_type=token") else { return false }
    return await runLogin(url, title: "AniList", malState: nil)
  }

  /// confirmMAL: PKCE with code_challenge_method=plain (challenge == verifier), 10 char state.
  @discardableResult
  func loginMAL() async -> Bool {
    let state = ServiceText.randomString(10)
    let challenge = ServiceText.randomString(50)
    pendingMALStates[state] = challenge
    var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: MyAnimeListService.clientID),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "plain")
    ]
    guard let url = components?.url else { return false }
    return await runLogin(url, title: "MyAnimeList", malState: state)
  }

  /// "Log In Again" of a profile whose session expired: the login of its service (the new token replaces
  /// the profile's, swapProfiles keeps the profile).
  @discardableResult
  func reauthenticate(_ profile: AccountProfile? = nil) async -> Bool {
    let target = profile ?? current
    if target?.viewer.service == .anilist { return await loginAniList() }
    return await loginMAL()
  }

  private func runLogin(_ url: URL, title: String, malState: String?) async -> Bool {
    lastError = nil
    if let override = authenticateOverride {
      isLoggingIn = true
      defer { isLoggingIn = false }
      do {
        let callback = try await override(url, Self.callbackScheme)
        return await handleCallback(callback)
      } catch {
        if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
          ServiceMessages.shared.post(.error, "Login Canceled", "The authorization window to log into your account was closed. If this was a mistake, please try logging in again.")
        } else {
          lastError = error.localizedDescription
          ServiceMessages.shared.post(.error, "Login Failed", error.localizedDescription)
        }
        return false
      }
    }
    // Closing the sheet (Cancel / swipe down) ends the login without a toast.
    guard let callback = await runWebLogin(url, title: title, malState: malState) else { return false }
    isLoggingIn = true
    defer { isLoggingIn = false }
    return await handleCallback(callback)
  }

  // MARK: - Web view login

  /// Shows the login page in the web view sheet and waits for its result (nil when it was closed).
  private func runWebLogin(_ url: URL, title: String, malState: String?) async -> URL? {
    finishWebLogin(nil)
    return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
      webLoginContinuation = continuation
      webLogin = TsumiWebLoginRequest(id: UUID(), url: url, title: title, malState: malState)
    }
  }

  /// Ends the running web login: `callback` is the URL carrying the token / code, nil for a cancel.
  /// With `request`, only that login is ended (a closing sheet must not end a newer one).
  func finishWebLogin(_ callback: URL?, request: UUID? = nil) {
    if let request, request != webLogin?.id { return }
    webLogin = nil
    let continuation = webLoginContinuation
    webLoginContinuation = nil
    continuation?.resume(returning: callback)
  }

  /// The login result carried by a URL the login web view loads (or tries to load), if any:
  /// - AniList `access_token=` (fragment of the pin page, or a tsumi://alauth callback);
  /// - MyAnimeList `code` + the `state` of this login in the query (any redirect URL);
  /// - a tsumi:// / shiru:// callback (parsed by `handleCallback`).
  nonisolated static func loginCallbackURL(_ url: URL, malState: String?) -> URL? {
    let text = url.absoluteString
    if let range = text.range(of: "access_token=") {
      let rest = text[range.upperBound...]
      if let first = rest.first, first != "&", first != "#" { return url }
    }
    if let malState, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      let items = components.queryItems ?? []
      let code = items.first(where: { $0.name == "code" })?.value ?? ""
      let state = items.first(where: { $0.name == "state" })?.value
      if !code.isEmpty, state == malState { return url }
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "tsumi" || scheme == "shiru" { return url }
    return nil
  }

  // MARK: - Pasted token (settings.js paste handler)

  /// AniList token of a pasted pin page URL / `access_token=...` string, or a bare token.
  nonisolated static func pastedAniListToken(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = trimmed.range(of: "access_token=") {
      var token = String(trimmed[range.upperBound...])
      if let end = token.firstIndex(where: { $0 == "&" || $0.isWhitespace }) { token = String(token[..<end]) }
      while token.hasSuffix("/") { token.removeLast() }
      return token.isEmpty ? nil : token
    }
    // AniList access tokens are long JWTs (no spaces, no URL parts).
    if trimmed.count >= 40, !trimmed.contains(where: { $0.isWhitespace }), !trimmed.contains("://"),
       !trimmed.contains("code="), !trimmed.contains("/") {
      return trimmed
    }
    return nil
  }

  /// Logs in with pasted text: an AniList token / pin URL, or a MyAnimeList `code=...&state=...` redirect.
  @discardableResult
  func login(pasted text: String) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    lastError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }
    if let token = Self.pastedAniListToken(trimmed) {
      return await handleAniListToken(token)
    }
    if trimmed.contains("code="), trimmed.contains("state=") {
      let url = URL(string: trimmed) ?? URL(string: "tsumi://malauth?" + trimmed)
      if let url { return await handleCallback(url) }
    }
    ServiceMessages.shared.post(.error, "Failed to sign in", "The pasted text is not an AniList token or a login link.")
    return false
  }

  /// tsumi://alauth / tsumi://malauth (and shiru://) opened from outside the app (onOpenURL through Services.handle).
  /// The AniList sign-in comes back through the login web view (pin page), so an AniList token link is only taken as
  /// the result of an AniList sign-in started here and still waiting: any web page could otherwise open a link with
  /// its own token, sign the app into that account and get the user's progress written there (login CSRF). A
  /// MyAnimeList link is checked against the state of a login started here (`handleMALCode`). Returns true when the
  /// link was handed to the running sign-in (which reports its own result) or signed in.
  @discardableResult
  func handleExternalCallback(_ url: URL) async -> Bool {
    let isAniListLink = url.absoluteString.contains("access_token=")
    if let pending = webLogin, isAniListLink == (pending.malState == nil) {
      finishWebLogin(url, request: pending.id)
      return true
    }
    if isAniListLink {
      ServiceMessages.shared.post(.error, "Sign-in Link Ignored", "This AniList sign-in link does not come from a sign-in started in the app. Sign in from the profiles instead.")
      return false
    }
    return await handleCallback(url)
  }

  /// Handles the tsumi://alauth / tsumi://malauth (and shiru://) result of a login started here (and the pasted
  /// MyAnimeList redirect).
  @discardableResult
  func handleCallback(_ url: URL) async -> Bool {
    let text = url.absoluteString
    if let range = text.range(of: "access_token=") {
      var token = String(text[range.upperBound...])
      if let end = token.range(of: "&") { token = String(token[..<end.lowerBound]) }
      if token.hasSuffix("/") { token.removeLast() }
      guard !token.isEmpty else { return false }
      return await handleAniListToken(token)
    }
    if let codeRange = text.range(of: "code="), text.contains("state=") {
      var code = String(text[codeRange.upperBound...])
      if let end = code.range(of: "&") { code = String(code[..<end.lowerBound]) }
      var state = ""
      if let stateRange = text.range(of: "state=") {
        state = String(text[stateRange.upperBound...])
        if let end = state.range(of: "&") { state = String(state[..<end.lowerBound]) }
      }
      if code.hasSuffix("/") { code.removeLast() }
      if state.hasSuffix("/") { state.removeLast() }
      state = state.removingPercentEncoding ?? state
      code = code.trimmingCharacters(in: .whitespacesAndNewlines)
      state = state.trimmingCharacters(in: .whitespacesAndNewlines)
      return await handleMALCode(code, state: state)
    }
    return false
  }

  /// settings.js handleToken.
  private func handleAniListToken(_ token: String) async -> Bool {
    do {
      let result = try await AniListService.shared.viewer(token: token)
      let profile = AccountProfile(viewer: result.viewer, token: token, customLists: result.customLists, expiresAt: SessionToken.expiry(of: token))
      swapProfiles(profile, newProfile: true)
      return true
    } catch {
      lastError = error.localizedDescription
      ServiceMessages.shared.post(.error, "Failed to sign in with AniList. Please try again.", error.localizedDescription)
      return false
    }
  }

  /// settings.js handleMalToken.
  private func handleMALCode(_ code: String, state: String) async -> Bool {
    guard !code.isEmpty, !state.isEmpty, let verifier = pendingMALStates.removeValue(forKey: state) else {
      ServiceMessages.shared.post(.error, "Failed to sign in with MyAnimeList. Please try again.")
      return false
    }
    do {
      let tokens = try await MyAnimeListService.shared.exchangeCode(code, verifier: verifier)
      let viewer = try await MyAnimeListService.shared.viewer(token: tokens.accessToken)
      let profile = AccountProfile(viewer: viewer, token: tokens.accessToken, refreshToken: tokens.refreshToken, refreshAt: Date().addingTimeInterval(14 * 24 * 3600), reauth: false)
      swapProfiles(profile, newProfile: true)
      return true
    } catch {
      lastError = error.localizedDescription
      ServiceMessages.shared.post(.error, "Failed to sign in with MyAnimeList. Please try again.", error.localizedDescription)
      return false
    }
  }

  // MARK: - Profiles

  /// Sign Out of the current profile (swapProfiles(null)): the first other profile becomes current.
  func logout() {
    let signedOut = current
    swapProfiles(nil, newProfile: false)
    // Its offline progress can no longer be sent.
    if let signedOut { DownloadProgressQueue.shared.dropAccount(signedOut.id) }
  }

  /// Switch to another profile; the current one moves to the other profiles.
  func switchTo(_ profile: AccountProfile) {
    swapProfiles(profile, newProfile: false)
  }

  /// Logout button of an "other" profile (dropProfile).
  func drop(_ profile: AccountProfile) {
    AccountStore.shared.mutate { value in
      value.others.removeAll { $0.id == profile.id }
      value.sync.removeAll { $0 == profile.viewer.id }
    }
    reload()
    DownloadProgressQueue.shared.dropAccount(profile.id)
  }

  /// "Sync List Entries" switch of an other profile.
  func toggleSync(_ profile: AccountProfile) {
    AccountStore.shared.mutate { value in
      if value.sync.contains(profile.viewer.id) {
        value.sync.removeAll { $0 == profile.viewer.id }
      } else {
        value.sync.append(profile.viewer.id)
      }
    }
    reload()
  }

  /// swapProfiles(profile, newProfile).
  private func swapProfiles(_ profile: AccountProfile?, newProfile: Bool) {
    let previous = AccountStore.shared.current
    AccountStore.shared.mutate { value in
      guard let profile else {
        if !value.others.isEmpty {
          value.current = value.others.removeFirst()
        } else {
          value.current = nil
        }
        return
      }
      if newProfile && value.current?.id == profile.id {
        value.current = profile
      } else if newProfile && value.others.contains(where: { $0.id == profile.id }) {
        value.others = value.others.map { $0.id == profile.id ? profile : $0 }
      } else {
        if let current = value.current, current.id != profile.id { value.others.insert(current, at: 0) }
        value.current = profile
        value.others.removeAll { $0.id == profile.id }
      }
    }
    reload()
    if previous?.id != current?.id || previous?.token != current?.token {
      accountChanged(previous: previous)
    }
  }

  /// location.reload() equivalent: user specific data is reset and reloaded.
  private func accountChanged(previous: AccountProfile?) {
    if previous?.id != current?.id {
      // Per-account memory of the previous profile: list entries and hearts of the store, hearts toggled in this
      // session, positions read from its notes (the AniList caches are kept per viewer, AniListService.viewerKey).
      MediaStore.shared.clearListEntries()
      AniListService.shared.accountChanged()
      PlaybackSyncService.shared.accountChanged()
      BrowseFavouriteStore.shared.changed()
    }
    MediaListService.shared.accountChanged()
    HomeSectionsService.shared.rebuild()
    AppNotificationsService.shared.accountChanged()
  }
}
