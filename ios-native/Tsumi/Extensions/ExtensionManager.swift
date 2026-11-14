import Foundation
import Observation

/// Installed extensions and their loaded runtimes. Port of `ExtensionManager` / `manager`
/// (common/modules/extension.js): the installed list is persisted (UserDefaults, JSON), every
/// installed extension is (re)loaded at launch (syncFromSettings), and the default / starred
/// extension keys live in `AppSettings.shared.values.defaultExtension / starredExtension`.
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

  @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
  /// Token of the load currently in charge of each key. A load that was cancelled or replaced (refresh,
  /// removal, import) finishes with a stale token and leaves the newer load's state alone.
  @ObservationIgnored private var loadTokens: [String: UUID] = [:]

  private init() {
    installed = Self.readStored()
    reload()
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
    reload()
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

  private func startLoading(_ config: InstalledExtension) {
    let key = config.key
    let url = config.url
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
    guard installedExtension(key) != nil else { return }
    loaded[key] = LoadedExtension(key: key, manifest: result.manifest, backend: result.backend)
    loadErrors[key] = nil
    ExtensionPayloadStore.save(result, key: key)
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
    }
  }

  // MARK: Manager API

  /// addExtension(manifestUrl): loads the manifest (Sora module or Stremio addon), stores it enabled.
  @discardableResult
  func addExtension(_ manifestURL: String) async throws -> String {
    let result = try await ExtensionLoader.load(manifestURL: manifestURL)
    let key = result.key
    // A launch / refresh load of the same key must not overwrite this fresher copy.
    cancelLoad(key)
    loaded[key] = LoadedExtension(key: key, manifest: result.manifest, backend: result.backend)
    loadErrors[key] = nil
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

  /// removeExtension(key)
  func removeExtension(_ key: String) {
    cancelLoad(key)
    loaded[key] = nil
    loadErrors[key] = nil
    installed.removeAll { $0.key == key }
    persist()
    ExtensionPayloadStore.remove(key: key)
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
          loaded[old.key] = nil
          loadErrors[old.key] = nil
        }
      } else {
        cancelLoad(old.key)
        loaded[old.key] = nil
        loadErrors[old.key] = nil
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

  private func persist() {
    if let data = try? JSONEncoder().encode(installed) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }

  private static func readStored() -> [InstalledExtension] {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) else { return [] }
    return list
  }
}
