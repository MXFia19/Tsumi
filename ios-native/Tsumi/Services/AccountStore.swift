import Foundation
import Security

// Token storage of the AniList / MyAnimeList accounts (settings.js alToken / malToken / profiles / sync,
// stored in localStorage by the Svelte app; in the Keychain here). Thread-safe so that API clients can
// read the current token from any thread.

/// One logged-in account (current or "other profile").
struct AccountProfile: Codable, Hashable, Identifiable {
  var id: String { "\(viewer.service.rawValue)-\(viewer.id)" }
  var viewer: Viewer
  var token: String
  var refreshToken: String?
  /// MyAnimeList: when the token must be refreshed (refresh_in).
  var refreshAt: Date?
  /// The session expired (AniList token refused or past its expiry, MyAnimeList refresh failed):
  /// the user must log in again (Services/SessionExpiry.swift).
  var reauth: Bool
  /// AniList custom anime lists (Viewer.mediaListOptions).
  var customLists: [String]
  /// AniList: expiry of the token (its JWT `exp`, settings.js expires_in). Missing in older stored profiles.
  var expiresAt: Date?

  var isAniList: Bool { viewer.service == .anilist }

  init(viewer: Viewer, token: String, refreshToken: String? = nil, refreshAt: Date? = nil, reauth: Bool = false, customLists: [String] = [], expiresAt: Date? = nil) {
    self.viewer = viewer
    self.token = token
    self.refreshToken = refreshToken
    self.refreshAt = refreshAt
    self.reauth = reauth
    self.customLists = customLists
    self.expiresAt = expiresAt
  }
}

/// Minimal Keychain wrapper (generic passwords of the app).
enum TsumiKeychain {
  private static let service = "org.tsumi.app.accounts"

  static func data(for account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  @discardableResult
  static func set(_ data: Data, for account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return true }
    if status == errSecItemNotFound {
      var insert = query
      for (key, value) in attributes { insert[key] = value }
      return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    return false
  }

  static func remove(_ account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
  }
}

final class AccountStore: @unchecked Sendable {
  static let shared = AccountStore()
  /// Posted on the main queue whenever an account changes (login, refresh, switch, logout).
  static let didChange = Notification.Name("tsumi.services.accountsChanged")

  struct Snapshot: Codable, Hashable {
    var current: AccountProfile?
    var others: [AccountProfile] = []
    /// Viewer ids of the other profiles whose lists are kept in sync (settings.js `sync`).
    var sync: [Int] = []
  }

  private static let keychainAccount = "accounts.v1"
  private let state: ServiceLocked<Snapshot>

  private init() {
    var initial = Snapshot()
    if let data = TsumiKeychain.data(for: Self.keychainAccount), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
      initial = decoded
    }
    state = ServiceLocked(initial)
  }

  var snapshot: Snapshot { state.get() }
  var current: AccountProfile? { state.get().current }
  var others: [AccountProfile] { state.get().others }
  var syncIds: [Int] { state.get().sync }

  var isAuthorized: Bool { current != nil }
  var isAniList: Bool { current?.viewer.service == .anilist }
  var isMAL: Bool { current?.viewer.service == .myanimelist }

  /// AniList token of the current profile (Authorization header of anilist.js).
  var anilistToken: String? {
    guard let current, current.viewer.service == .anilist else { return nil }
    return current.token
  }

  func mutate(_ body: (inout Snapshot) -> Void) {
    let snapshot: Snapshot = state.update { value in
      body(&value)
      return value
    }
    persist(snapshot)
  }

  /// Updates a profile after a token refresh (current or other).
  func replaceProfile(oldToken: String, with profile: AccountProfile) {
    mutate { value in
      if value.current?.token == oldToken {
        value.current = profile
      } else {
        value.others = value.others.map { $0.token == oldToken ? profile : $0 }
      }
    }
  }

  /// Marks a profile (AniList or MyAnimeList) as needing a new login.
  func markReauth(token: String) {
    mutate { value in
      if value.current?.token == token {
        value.current?.reauth = true
      } else {
        value.others = value.others.map { profile in
          var copy = profile
          if copy.token == token { copy.reauth = true }
          return copy
        }
      }
    }
  }

  private func persist(_ snapshot: Snapshot) {
    if let data = try? JSONEncoder().encode(snapshot) {
      TsumiKeychain.set(data, for: Self.keychainAccount)
    }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: AccountStore.didChange, object: nil)
    }
  }
}
