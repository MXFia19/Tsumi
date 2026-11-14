import Foundation
import Observation
import AuthenticationServices
import UIKit

// Port of common/components/Profiles.svelte + settings.js handleToken / handleMalToken / swapProfiles.
// Logins go through ASWebAuthenticationSession: AniList implicit grant (client 35971, redirect
// tsumi://alauth#access_token=...) and MyAnimeList OAuth2 PKCE with a plain challenge
// (redirect tsumi://malauth?code=...&state=...).

/// ASWebAuthenticationSession wrapper.
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
      session.prefersEphemeralWebBrowserSession = true
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

  /// Optional replacement of the ASWebAuthenticationSession flow, e.g. SwiftUI's
  /// `webAuthenticationSession.authenticate(using:callbackURLScheme:preferredBrowserSession:)`.
  @ObservationIgnored var authenticateOverride: ((URL, String) async throws -> URL)?

  @ObservationIgnored private var authenticator: TsumiWebAuthenticator?
  @ObservationIgnored private var pendingMALStates: [String: String] = [:]
  @ObservationIgnored private var observer: NSObjectProtocol?

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
    return await runLogin(url)
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
    return await runLogin(url)
  }

  /// "Authenticate" button of a MyAnimeList profile whose refresh failed.
  @discardableResult
  func reauthenticate() async -> Bool {
    await loginMAL()
  }

  private func runLogin(_ url: URL) async -> Bool {
    isLoggingIn = true
    lastError = nil
    defer { isLoggingIn = false }
    do {
      let callback: URL
      if let override = authenticateOverride {
        callback = try await override(url, Self.callbackScheme)
      } else {
        let session = authenticator ?? TsumiWebAuthenticator()
        authenticator = session
        callback = try await session.authenticate(url: url, callbackScheme: Self.callbackScheme)
      }
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

  /// Handles tsumi://alauth / tsumi://malauth (and shiru://) callbacks, also usable from `onOpenURL`.
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
      let profile = AccountProfile(viewer: result.viewer, token: token, customLists: result.customLists)
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
    swapProfiles(nil, newProfile: false)
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
      MediaStore.shared.clearListEntries()
    }
    MediaListService.shared.accountChanged()
    HomeSectionsService.shared.rebuild()
    AppNotificationsService.shared.accountChanged()
  }
}
