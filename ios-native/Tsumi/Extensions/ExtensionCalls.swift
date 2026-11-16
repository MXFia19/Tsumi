import Foundation

/// Result of loading a manifest URL (loadExtension in extension.js).
struct ExtensionLoadResult {
  var manifest: ExtensionManifest
  var backend: LoadedExtension.Backend
  /// Raw Stremio manifest JSON, kept for offline reloads.
  var stremioManifestData: Data?
  /// Installed from this device or the local network: the module may fetch local addresses too.
  var allowsLocalNetwork = false
  /// Manifest and script came over https (a script fetched over plain http could have been changed on the way).
  var isSecure = true

  var kind: ExtensionKind {
    switch backend {
    case .sora: return .sora
    case .stremio: return .stremio
    }
  }

  /// Default settings key (`name-version`, like the desktop app); ExtensionManager may add a suffix.
  var key: String { manifest.storageKey }
}

/// Loads Sora modules (manifest + script) and Stremio addons (manifest only) from a manifest URL. Error messages
/// only name the host: manifest URLs can carry private tokens.
enum ExtensionLoader {
  /// loadExtension(manifestUrl)
  static func load(manifestURL: String) async throws -> ExtensionLoadResult {
    let normalized = StremioAddon.normalizeManifestURL(manifestURL)
    guard let url = URL.lenient(normalized), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw ExtensionFailure("Failed to load manifest from \(ExtensionURLMask.host(normalized)): Invalid URL")
    }
    let resolved = url.absoluteString
    let host = ExtensionURLMask.host(url)
    let manifestIsLocal = ExtensionNetworkPolicy.isLocal(url)

    let json: Any
    do {
      let data = try await fetch(url)
      guard let parsed = ExtensionJSON.parse(data) else {
        throw ExtensionFailure("The manifest is not valid JSON")
      }
      json = parsed
    } catch {
      if error is CancellationError { throw error }
      throw ExtensionFailure("Failed to load manifest from \(host): \(error.localizedDescription)")
    }

    // Stremio addons have no script: they are queried over HTTP instead.
    if let object = json as? [String: Any], StremioAddon.isStremioManifest(object), let manifest = StremioManifest(json: object) {
      let addon = StremioAddon(base: StremioAddon.baseURL(forManifest: resolved), manifest: manifest)
      let raw = try? JSONSerialization.data(withJSONObject: object, options: [])
      return ExtensionLoadResult(
        manifest: ExtensionManifest(stremio: manifest),
        backend: .stremio(addon),
        stremioManifestData: raw,
        allowsLocalNetwork: manifestIsLocal,
        isSecure: scheme == "https"
      )
    }

    guard let object = json as? [String: Any], let manifest = ExtensionManifest(soraJSON: object), let scriptPath = manifest.scriptUrl else {
      throw ExtensionFailure("Invalid manifest: expected a Sora module (sourceName + scriptUrl) or a Stremio addon")
    }
    guard let scriptURL = URL(string: scriptPath, relativeTo: url)?.absoluteURL ?? URL.lenient(scriptPath) else {
      throw ExtensionFailure("Failed to load script: Invalid URL")
    }
    // Web addresses only: a file: or data: URL would read files of the app or bypass the network rules.
    guard let scriptScheme = scriptURL.scheme?.lowercased(), scriptScheme == "http" || scriptScheme == "https" else {
      throw ExtensionFailure("Failed to load script: its address must start with https:// (or http://)")
    }
    let script: String
    do {
      let data = try await fetch(scriptURL)
      script = String(decoding: data, as: UTF8.self)
    } catch {
      if error is CancellationError { throw error }
      throw ExtensionFailure("Failed to load script from \(ExtensionURLMask.host(scriptURL)): \(error.localizedDescription)")
    }
    return ExtensionLoadResult(
      manifest: manifest,
      backend: .sora(script: script),
      stremioManifestData: nil,
      allowsLocalNetwork: manifestIsLocal || ExtensionNetworkPolicy.isLocal(scriptURL),
      isSecure: scheme == "https" && scriptScheme == "https"
    )
  }

  /// getExtension: GET (20 MB at most), error on non-2xx ("HTTP 404").
  private static func fetch(_ url: URL) async throws -> Data {
    let (data, response) = try await ExtensionHTTP.data(url)
    guard (200..<300).contains(response.statusCode) else {
      throw ExtensionFailure("HTTP \(response.statusCode)")
    }
    return data
  }
}

/// callExtensionFunction for both kinds of extensions, with the typed parsing the Svelte
/// components do on the results (`typeof raw === 'string' ? JSON.parse(raw) : raw`).
enum ExtensionCalls {
  /// Generic call; Stremio addons only support searchResults / extractEpisodes / extractStreamUrl.
  static func call(_ ext: LoadedExtension, _ functionName: String, _ arguments: [Any]) async throws -> Any? {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.call(functionName, arguments: arguments)
    case .sora(let script):
      return try await SoraRuntime.call(script: script, functionName: functionName, arguments: arguments, allowsLocalNetwork: ext.allowsLocalNetwork)
    }
  }

  /// searchResults(title) — Stremio addons also get the media (they look it up by TMDB id).
  static func searchResults(_ ext: LoadedExtension, title: String, media: Media?) async throws -> [ExtensionSearchItem] {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.searchResults(title: title, media: media)
    case .sora(let script):
      let raw = try await SoraRuntime.call(script: script, functionName: "searchResults", arguments: [title], allowsLocalNetwork: ext.allowsLocalNetwork)
      return try parseSearchItems(raw)
    }
  }

  /// extractEpisodes(href)
  static func extractEpisodes(_ ext: LoadedExtension, href: String) async throws -> [ExtensionEpisode] {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.extractEpisodes(href: href)
    case .sora(let script):
      let raw = try await SoraRuntime.call(script: script, functionName: "extractEpisodes", arguments: [href], allowsLocalNetwork: ext.allowsLocalNetwork)
      return try parseEpisodes(raw)
    }
  }

  /// extractStreamUrl(href): the raw answer, to be read by ExtensionStreamParser.
  static func extractStream(_ ext: LoadedExtension, href: String) async throws -> Any? {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.extractStreamUrl(href: href)
    case .sora(let script):
      return try await SoraRuntime.call(script: script, functionName: "extractStreamUrl", arguments: [href], allowsLocalNetwork: ext.allowsLocalNetwork)
    }
  }

  /// extractDetails(href) — part of the Sora module format; not used by the Svelte UI.
  static func extractDetails(_ ext: LoadedExtension, href: String) async throws -> Any? {
    try await call(ext, "extractDetails", [href])
  }

  static func parseSearchItems(_ raw: Any?) throws -> [ExtensionSearchItem] {
    if raw is String { throw ExtensionFailure("The extension returned invalid search results") }
    guard let list = raw as? [Any] else { return [] }
    return list.compactMap { entry in
      guard let object = entry as? [String: Any] else { return nil }
      return ExtensionSearchItem(
        title: ExtensionJSON.string(object["title"]) ?? "",
        image: ExtensionJSON.string(object["image"]) ?? "",
        href: ExtensionJSON.string(object["href"]) ?? ""
      )
    }
  }

  static func parseEpisodes(_ raw: Any?) throws -> [ExtensionEpisode] {
    if raw is String { throw ExtensionFailure("The extension returned an invalid episode list") }
    guard let list = raw as? [Any] else { return [] }
    return list.compactMap { entry in
      guard let object = entry as? [String: Any] else { return nil }
      return ExtensionEpisode(
        number: ExtensionJSON.number(object["number"]),
        season: ExtensionJSON.isNullish(object["season"]) ? nil : ExtensionJSON.number(object["season"]),
        title: ExtensionJSON.string(object["title"]),
        href: ExtensionJSON.string(object["href"]) ?? ""
      )
    }
  }
}

/// Last successfully downloaded script / Stremio manifest of each extension, so installed
/// extensions keep working when the app starts offline (the Svelte app relied on the browser cache).
/// The Stremio base URL is not stored here (it carries the addon's private configuration): it is rebuilt from the
/// manifest URL, which lives in the Keychain (ExtensionSecretStore).
struct StoredExtensionPayload: Codable {
  var script: String?
  var stremioManifest: Data?
  /// Written by older versions only; removed by `scrubSecrets`.
  var stremioBase: String?
  var allowsLocalNetwork: Bool?
  var isSecure: Bool?
}

enum ExtensionPayloadStore {
  private static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("TsumiExtensions", isDirectory: true)
  }

  private static func fileURL(_ key: String) -> URL {
    let safe = Data(key.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    return directory.appendingPathComponent(String(safe.prefix(180)) + ".json")
  }

  private static func read(_ key: String) -> StoredExtensionPayload? {
    guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
    return try? JSONDecoder().decode(StoredExtensionPayload.self, from: data)
  }

  private static func write(_ payload: StoredExtensionPayload, key: String) {
    guard let data = try? JSONEncoder().encode(payload) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL(key), options: .atomic)
  }

  static func save(_ result: ExtensionLoadResult, key: String) {
    var payload = StoredExtensionPayload()
    switch result.backend {
    case .sora(let script):
      payload.script = script
    case .stremio:
      payload.stremioManifest = result.stremioManifestData
    }
    payload.allowsLocalNetwork = result.allowsLocalNetwork
    payload.isSecure = result.isSecure
    write(payload, key: key)
  }

  /// Script last accepted for a Sora module (nil for addons and unknown keys).
  static func storedScript(key: String) -> String? {
    read(key)?.script
  }

  static func load(key: String, config: InstalledExtension) -> LoadedExtension? {
    guard let payload = read(key) else { return nil }
    let manifestURL = URL.lenient(StremioAddon.normalizeManifestURL(config.url))
    let local = payload.allowsLocalNetwork ?? manifestURL.map { ExtensionNetworkPolicy.isLocal($0) } ?? false
    let secure = payload.isSecure ?? (manifestURL?.scheme?.lowercased() == "https")
    if let script = payload.script {
      return LoadedExtension(key: key, manifest: config.manifest, backend: .sora(script: script), allowsLocalNetwork: local, isSecure: secure)
    }
    let base = config.url.isEmpty ? payload.stremioBase : StremioAddon.baseURL(forManifest: config.url)
    if let raw = payload.stremioManifest, let base, !base.isEmpty,
       let object = ExtensionJSON.parse(raw) as? [String: Any], let manifest = StremioManifest(json: object) {
      return LoadedExtension(key: key, manifest: config.manifest, backend: .stremio(StremioAddon(base: base, manifest: manifest)), allowsLocalNetwork: local, isSecure: secure)
    }
    return nil
  }

  /// Drops the Stremio base URLs older versions stored next to the manifests (their manifest URL is known).
  static func scrubSecrets(_ configs: [InstalledExtension]) {
    for config in configs where !config.url.isEmpty {
      guard var payload = read(config.key), payload.stremioBase != nil else { continue }
      payload.stremioBase = nil
      write(payload, key: config.key)
    }
  }

  static func remove(key: String) {
    try? FileManager.default.removeItem(at: fileURL(key))
  }
}
