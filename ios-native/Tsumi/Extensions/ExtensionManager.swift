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
    for task in loadTasks.values { task.cancel() }
    loadTasks.removeAll()
    loadingKeys.removeAll()
    loaded.removeAll()
    reload()
  }

  /// Waits for the loads started at launch (so a play request right after launch sees them).
  func awaitPendingLoads() async {
    let tasks = Array(loadTasks.values)
    for task in tasks { await task.value }
  }

  private func startLoading(_ config: InstalledExtension) {
    let key = config.key
    let url = config.url
    loadingKeys.insert(key)
    loadTasks[key] = Task { [weak self] in
      do {
        let result = try await ExtensionLoader.load(manifestURL: url)
        self?.finishLoading(key: key, result: result)
      } catch {
        self?.failLoading(key: key, error: error)
      }
    }
  }

  private func finishLoading(key: String, result: ExtensionLoadResult) {
    loadTasks[key] = nil
    loadingKeys.remove(key)
    guard installedExtension(key) != nil else { return }
    loaded[key] = LoadedExtension(key: key, manifest: result.manifest, backend: result.backend)
    loadErrors[key] = nil
    ExtensionPayloadStore.save(result, key: key)
  }

  private func failLoading(key: String, error: Error) {
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
    loadTasks[key]?.cancel()
    loadTasks[key] = nil
    loadingKeys.remove(key)
    loaded[key] = nil
    loadErrors[key] = nil
    installed.removeAll { $0.key == key }
    persist()
    ExtensionPayloadStore.remove(key: key)
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
