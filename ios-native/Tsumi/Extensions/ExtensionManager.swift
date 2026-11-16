import CryptoKit
import Foundation
import Observation
import Security

/// Changed code of an installed module waiting for the user's approval (a module served over plain http changed:
/// anyone on the network path could have changed it). The approved code keeps running meanwhile.
struct ExtensionPendingUpdate {
  var result: ExtensionLoadResult
  var fromVersion: String?
  var toVersion: String?

  /// "1.2 → 1.3", or "new code" when the version did not change.
  var summary: String {
    if let toVersion, toVersion != fromVersion {
      return "\(fromVersion ?? "?") → \(toVersion)"
    }
    return "new code"
  }
}

/// Installed extensions and their loaded runtimes. Port of `ExtensionManager` / `manager`
/// (common/modules/extension.js): the installed list is persisted (UserDefaults, JSON, with the manifest URLs in the
/// Keychain since they can carry private tokens), every installed extension is (re)loaded at launch
/// (syncFromSettings), and the default / starred extension keys live in
/// `AppSettings.shared.values.defaultExtension / starredExtension`.
///
/// A load brings the installed entry up to date (new version: its manifest is updated in place, the key stays, so
/// the default / starred extension, downloads and resume points keep pointing at it). Changed code is applied at once
/// when it came over https (Settings shows "Updated"), and waits for "Update" in Settings when it came over http.
/// Failed loads run from the offline copy and are retried when the device gets back online.
@MainActor
@Observable
final class ExtensionManager {
  static let shared = ExtensionManager()
  private static let storageKey = "tsumi.extensions.v1"

  /// settings.extensions, in insertion order.
  private(set) var installed: [InstalledExtension] = []
  /// Loaded runtimes by key (`extensions` Map).
  private(set) var loaded: [String: LoadedExtension] = [:]
  /// Keys being loaded (`loading` Map).
  private(set) var loadingKeys: Set<String> = []
  /// Last load error per key (the extension may still run from its offline copy).
  private(set) var loadErrors: [String: String] = [:]
  /// Keys running from their offline copy because their last load failed.
  private(set) var offlineKeys: Set<String> = []
  /// Changed code waiting for the user's approval, by key.
  private(set) var pendingUpdates: [String: ExtensionPendingUpdate] = [:]
  /// What the last load of a key changed ("Updated to 1.3"), shown in the settings until the next launch.
  private(set) var updateNotes: [String: String] = [:]

  @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
  /// Token of the load currently in charge of each key. A load that was cancelled or replaced (refresh,
  /// removal, import) finishes with a stale token and leaves the newer load's state alone.
  @ObservationIgnored private var loadTokens: [String: UUID] = [:]
  @ObservationIgnored private var wasOnline = true

  private init() {
    let stored = Self.readStored()
    installed = stored.list
    if stored.needsMigration {
      // Manifest URLs saved in UserDefaults by older versions: moved to the Keychain.
      persist()
    }
    ExtensionPayloadStore.scrubSecrets(installed)
    reload()
    observeNetwork()
  }

  // MARK: Settings keys

  var defaultKey: String? { AppSettings.shared.values.defaultExtension }
  var starredKey: String? { AppSettings.shared.values.starredExtension }

  func installedExtension(_ key: String) -> InstalledExtension? {
    installed.first { $0.key == key }
  }

  func loadedExtension(_ key: String) -> LoadedExtension? { loaded[key] }

  func isEnabled(_ key: String) -> Bool { installedExtension(key)?.enabled ?? false }

  // MARK: Loading

  /// syncFromSettings: load every installed extension that is not loaded or loading yet.
  func reload() {
    for config in installed where loaded[config.key] == nil && loadTasks[config.key] == nil {
      startLoading(config)
    }
  }

  /// Reloads every extension from its URL (e.g. pull-to-refresh in the settings).
  func refreshAll() {
    cancelAllLoads()
    loaded.removeAll()
    offlineKeys.removeAll()
    reload()
  }

  /// Loads again the extensions whose last load failed (back online).
  func retryFailed() {
    for config in installed where loadErrors[config.key] != nil && loadTasks[config.key] == nil {
      startLoading(config)
    }
  }

  /// Loads one extension again ("Retry" in the settings).
  func retry(_ key: String) {
    guard let config = installedExtension(key) else { return }
    cancelLoad(key)
    startLoading(config)
  }

  /// Waits for the loads in progress (so a play request right after launch or a refresh sees them).
  /// Loads started while waiting (a refresh during the wait) are awaited too.
  func awaitPendingLoads() async {
    var awaited = Set<UUID>()
    while true {
      let pending = loadTokens.filter { !awaited.contains($0.value) }
      if pending.isEmpty { return }
      for (key, token) in pending {
        awaited.insert(token)
        if let task = loadTasks[key] { await task.value }
      }
    }
  }

  /// Retries the failed loads when the network comes back (an offline launch keeps the offline copies until then).
  private func observeNetwork() {
    let online = withObservationTracking {
      ServiceNetworkMonitor.shared.isOnline
    } onChange: {
      Task { @MainActor in
        ExtensionManager.shared.observeNetwork()
      }
    }
    if online && !wasOnline {
      retryFailed()
    }
    wasOnline = online
  }

  private func startLoading(_ config: InstalledExtension) {
    let key = config.key
    var url = config.url
    if url.isEmpty, let stored = ExtensionSecretStore.loadURLs()?[key], !stored.isEmpty,
       let index = installed.firstIndex(where: { $0.key == key }) {
      // The Keychain could not be read at launch (device locked since it started): read it again now.
      installed[index].url = stored
      url = stored
    }
    let token = UUID()
    loadTokens[key] = token
    loadingKeys.insert(key)
    loadTasks[key] = Task { [weak self] in
      do {
        let result = try await ExtensionLoader.load(manifestURL: url)
        self?.finishLoading(key: key, token: token, result: result)
      } catch {
        self?.failLoading(key: key, token: token, error: error)
      }
    }
  }

  /// Stops the load of one key; its task can no longer touch the state (its token is dropped).
  private func cancelLoad(_ key: String) {
    loadTasks[key]?.cancel()
    loadTasks[key] = nil
    loadTokens[key] = nil
    loadingKeys.remove(key)
  }

  private func cancelAllLoads() {
    for task in loadTasks.values { task.cancel() }
    loadTasks.removeAll()
    loadTokens.removeAll()
    loadingKeys.removeAll()
  }

  private func finishLoading(key: String, token: UUID, result: ExtensionLoadResult) {
    // A newer load (refresh) or a removal took over: this result is stale.
    guard loadTokens[key] == token else { return }
    loadTokens[key] = nil
    loadTasks[key] = nil
    loadingKeys.remove(key)
    guard let config = installedExtension(key) else { return }
    loadErrors[key] = nil
    offlineKeys.remove(key)
    if case .sora(let script) = result.backend, !result.isSecure,
       let accepted = ExtensionPayloadStore.storedScript(key: key), accepted != script {
      // Plain http and the code changed: the approved code keeps running until "Update" in the settings.
      pendingUpdates[key] = ExtensionPendingUpdate(result: result, fromVersion: config.manifest.version, toVersion: result.manifest.version)
      if loaded[key] == nil {
        loaded[key] = ExtensionPayloadStore.load(key: key, config: config)
      }
      return
    }
    apply(result, key: key, announce: true)
  }

  private func failLoading(key: String, token: UUID, error: Error) {
    // A cancelled load fails with a wrapped URLError rather than CancellationError: the token tells
    // it apart, so it cannot clear the state of the load that replaced it.
    guard loadTokens[key] == token else { return }
    loadTokens[key] = nil
    loadTasks[key] = nil
    loadingKeys.remove(key)
    guard let config = installedExtension(key) else { return }
    if error is CancellationError { return }
    loadErrors[key] = error.localizedDescription
    #if DEBUG
    print("[Extensions] Failed to sync extension \(key): \(error.localizedDescription)")
    #endif
    if loaded[key] == nil, let offline = ExtensionPayloadStore.load(key: key, config: config) {
      loaded[key] = offline
      offlineKeys.insert(key)
    }
  }

  /// Runs `result` for `key`: brings the installed entry's manifest up to date (same key), stores the offline copy
  /// and, when `announce`, notes what changed for the settings.
  private func apply(_ result: ExtensionLoadResult, key: String, announce: Bool) {
    var previousScript: String?
    if case .sora = result.backend {
      previousScript = ExtensionPayloadStore.storedScript(key: key)
    }
    loaded[key] = LoadedExtension(key: key, manifest: result.manifest, backend: result.backend, allowsLocalNetwork: result.allowsLocalNetwork, isSecure: result.isSecure)
    pendingUpdates[key] = nil
    if let index = installed.firstIndex(where: { $0.key == key }) {
      let previous = installed[index].manifest
      if previous != result.manifest {
        installed[index].manifest = result.manifest
        persist()
      }
      if announce {
        if let version = result.manifest.version, previous.version != version {
          updateNotes[key] = "Updated to \(version)"
        } else if case .sora(let script) = result.backend, let previousScript, previousScript != script {
          updateNotes[key] = "Code updated"
        }
      }
    }
    ExtensionPayloadStore.save(result, key: key)
  }

  // MARK: Manager API

  /// addExtension(manifestUrl): loads the manifest (Sora module or Stremio addon), stores it enabled. A manifest that
  /// is already installed (same address, or for a Sora module the same name) updates that entry instead of adding a
  /// duplicate.
  @discardableResult
  func addExtension(_ manifestURL: String) async throws -> String {
    let result = try await ExtensionLoader.load(manifestURL: manifestURL)
    let key = installKey(for: result, url: manifestURL)
    // A launch / refresh load of the same key must not overwrite this fresher copy.
    cancelLoad(key)
    loaded[key] = LoadedExtension(key: key, manifest: result.manifest, backend: result.backend, allowsLocalNetwork: result.allowsLocalNetwork, isSecure: result.isSecure)
    loadErrors[key] = nil
    offlineKeys.remove(key)
    pendingUpdates[key] = nil
    updateNotes[key] = nil
    let config = InstalledExtension(key: key, url: manifestURL, enabled: true, kind: result.kind, manifest: result.manifest)
    if let index = installed.firstIndex(where: { $0.key == key }) {
      installed[index] = config
    } else {
      installed.append(config)
    }
    persist()
    ExtensionPayloadStore.save(result, key: key)
    return key
  }

  /// Accepts the pending update of `key` ("Update" in the settings).
  func applyUpdate(_ key: String) {
    guard let pending = pendingUpdates[key], installedExtension(key) != nil else { return }
    apply(pending.result, key: key, announce: true)
  }

  /// Key of a manifest being added: the installed entry it updates (same address, or for a Sora module the same
  /// name), else `name-version` like the desktop app. When another entry already has that key (two configurations
  /// of one Stremio addon share their name and version), a short hash of the addon address is appended, so the new
  /// one does not replace the other. Existing keys never change.
  private func installKey(for result: ExtensionLoadResult, url: String) -> String {
    let address = Self.comparableURL(url)
    if let same = installed.first(where: { Self.comparableURL($0.url) == address }) {
      return same.key
    }
    if result.kind == .sora,
       let same = installed.first(where: { $0.kind == .sora && $0.manifest.sourceName == result.manifest.sourceName }) {
      return same.key
    }
    let base = result.key
    guard installed.contains(where: { $0.key == base }) else { return base }
    let hashed = base + "#" + Self.shortHash(StremioAddon.baseURL(forManifest: url))
    var candidate = hashed
    var counter = 2
    while installed.contains(where: { $0.key == candidate }) {
      candidate = "\(hashed)-\(counter)"
      counter += 1
    }
    return candidate
  }

  private static func comparableURL(_ url: String) -> String {
    let normalized = StremioAddon.normalizeManifestURL(url)
    return URL.lenient(normalized)?.absoluteString ?? normalized
  }

  /// First 4 bytes of SHA-256, hex (an address is never shown, even hashed in full).
  private static func shortHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  /// removeExtension(key)
  func removeExtension(_ key: String) {
    cancelLoad(key)
    forgetState(key)
    installed.removeAll { $0.key == key }
    persist()
    ExtensionPayloadStore.remove(key: key)
  }

  private func forgetState(_ key: String) {
    loaded[key] = nil
    loadErrors[key] = nil
    offlineKeys.remove(key)
    pendingUpdates[key] = nil
    updateNotes[key] = nil
  }

  /// Replaces the whole installed list (settings Import), persists it and loads what is missing, like
  /// `settings.set(imported)` → syncFromSettings. Duplicate keys keep the first position and the last
  /// value. Runtimes of keys that stay with the same URL are kept; removed keys are unloaded and their
  /// offline copy deleted. The default / starred keys are left to the caller (they are settings values).
  func replaceInstalled(_ configs: [InstalledExtension]) {
    var list: [InstalledExtension] = []
    var positions: [String: Int] = [:]
    for config in configs {
      if let position = positions[config.key] {
        list[position] = config
      } else {
        positions[config.key] = list.count
        list.append(config)
      }
    }

    let previous = installed
    for old in previous {
      if let position = positions[old.key] {
        // Same key from another URL: load it again from the new one.
        if list[position].url != old.url {
          cancelLoad(old.key)
          forgetState(old.key)
        }
      } else {
        cancelLoad(old.key)
        forgetState(old.key)
        ExtensionPayloadStore.remove(key: old.key)
      }
    }
    // Runtimes added outside the list (none expected) are dropped too.
    for key in Array(loaded.keys) where positions[key] == nil {
      loaded[key] = nil
    }

    installed = list
    persist()
    reload()
  }

  /// Removes every extension (settings Reset): unloads them, deletes their offline copies, clears the
  /// default and starred extension, persists the empty list.
  func removeAll() {
    let keys = Set(installed.map(\.key)).union(loaded.keys)
    cancelAllLoads()
    loaded.removeAll()
    loadErrors.removeAll()
    offlineKeys.removeAll()
    pendingUpdates.removeAll()
    updateNotes.removeAll()
    installed.removeAll()
    persist()
    for key in keys { ExtensionPayloadStore.remove(key: key) }
    unsetDefault()
    unsetStar()
  }

  /// toggleExtension(key, enabled)
  func toggleExtension(_ key: String, enabled: Bool) {
    guard let index = installed.firstIndex(where: { $0.key == key }) else { return }
    installed[index].enabled = enabled
    persist()
  }

  func setDefault(_ key: String) { AppSettings.shared.values.defaultExtension = key }
  func unsetDefault() { AppSettings.shared.values.defaultExtension = nil }
  func setStar(_ key: String) { AppSettings.shared.values.starredExtension = key }
  func unsetStar() { AppSettings.shared.values.starredExtension = nil }

  /// getEnabled(): loaded extensions whose config is enabled (installed order).
  func enabledExtensions() -> [LoadedExtension] {
    installed.filter(\.enabled).compactMap { loaded[$0.key] }
  }

  /// Enabled extensions, starred one first (ExtensionResults.svelte sort).
  func enabledExtensionsStarredFirst() -> [LoadedExtension] {
    let starred = starredKey
    let enabled = enabledExtensions()
    return enabled.filter { $0.key == starred } + enabled.filter { $0.key != starred }
  }

  /// callDefault(functionName, ...args)
  func callDefault(_ functionName: String, _ arguments: [Any]) async throws -> Any? {
    guard let key = defaultKey else { throw ExtensionFailure("No default extension set") }
    guard let ext = loaded[key] else { throw ExtensionFailure("Extension \(key) not loaded") }
    return try await ExtensionCalls.call(ext, functionName, arguments)
  }

  /// callAll(functionName, ...args): sequential, failures skipped.
  func callAll(_ functionName: String, _ arguments: [Any]) async -> [(extensionKey: String, result: Any?)] {
    var results: [(extensionKey: String, result: Any?)] = []
    for ext in enabledExtensions() {
      do {
        let result = try await ExtensionCalls.call(ext, functionName, arguments)
        results.append((ext.key, result))
      } catch {
        #if DEBUG
        print("[Extensions] Error calling \(functionName) on \(ext.key): \(error.localizedDescription)")
        #endif
      }
    }
    return results
  }

  // MARK: Persistence

  /// The list goes to UserDefaults without its manifest URLs, which go to the Keychain. When the Keychain cannot be
  /// written, the URLs stay in the list rather than being lost.
  private func persist() {
    var urls: [String: String] = [:]
    var missing = false
    for config in installed {
      if config.url.isEmpty {
        missing = true
      } else {
        urls[config.key] = config.url
      }
    }
    var secured = false
    if missing {
      // URLs not read at launch (Keychain locked then): keep the stored ones, and never overwrite them blindly.
      if let stored = ExtensionSecretStore.loadURLs() {
        for config in installed where config.url.isEmpty {
          if let url = stored[config.key] { urls[config.key] = url }
        }
        secured = ExtensionSecretStore.saveURLs(urls)
      }
    } else {
      secured = ExtensionSecretStore.saveURLs(urls)
    }
    let stored: [InstalledExtension]
    if secured {
      stored = installed.map { config in
        var copy = config
        copy.url = ""
        return copy
      }
    } else {
      stored = installed
    }
    if let data = try? JSONEncoder().encode(stored) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }

  /// The stored list with the URLs of the Keychain; `needsMigration` when URLs were found in UserDefaults.
  private static func readStored() -> (list: [InstalledExtension], needsMigration: Bool) {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          var list = try? JSONDecoder().decode([InstalledExtension].self, from: data) else { return ([], false) }
    let urls = ExtensionSecretStore.loadURLs() ?? [:]
    var needsMigration = false
    for index in list.indices {
      if list[index].url.isEmpty {
        list[index].url = urls[list[index].key] ?? ""
      } else {
        needsMigration = true
      }
    }
    return (list, needsMigration)
  }
}

/// Manifest URLs of the installed extensions (a configured Stremio addon keeps its private token in the URL), as one
/// Keychain item: `{ key: url }`.
enum ExtensionSecretStore {
  private static let service = "org.tsumi.app.extensions"
  private static let account = "manifest-urls"

  /// nil when the Keychain cannot be read now (locked since the device started, or unreadable); empty when nothing
  /// is stored.
  static func loadURLs() -> [String: String]? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess, let data = result as? Data,
          let urls = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
    return urls
  }

  static func saveURLs(_ urls: [String: String]) -> Bool {
    guard let data = try? JSONEncoder().encode(urls) else { return false }
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
      insert.merge(attributes) { _, new in new }
      return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    return false
  }
}
