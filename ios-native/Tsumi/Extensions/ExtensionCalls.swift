import Foundation

/// Result of loading a manifest URL (loadExtension in extension.js).
struct ExtensionLoadResult {
  var manifest: ExtensionManifest
  var backend: LoadedExtension.Backend
  /// Raw Stremio manifest JSON, kept for offline reloads.
  var stremioManifestData: Data?

  var kind: ExtensionKind {
    switch backend {
    case .sora: return .sora
    case .stremio: return .stremio
    }
  }

  var key: String { manifest.storageKey }
}

/// Loads Sora modules (manifest + script) and Stremio addons (manifest only) from a manifest URL.
enum ExtensionLoader {
  /// loadExtension(manifestUrl)
  static func load(manifestURL: String) async throws -> ExtensionLoadResult {
    let normalized = StremioAddon.normalizeManifestURL(manifestURL)
    guard let url = URL.lenient(normalized), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw ExtensionFailure("Failed to load manifest from \(normalized): Invalid URL")
    }
    let resolved = url.absoluteString

    let json: Any
    do {
      let data = try await fetch(url)
      guard let parsed = ExtensionJSON.parse(data) else {
        throw ExtensionFailure("The manifest is not valid JSON")
      }
      json = parsed
    } catch {
      throw ExtensionFailure("Failed to load manifest from \(resolved): \(error.localizedDescription)")
    }

    // Stremio addons have no script: they are queried over HTTP instead.
    if let object = json as? [String: Any], StremioAddon.isStremioManifest(object), let manifest = StremioManifest(json: object) {
      let addon = StremioAddon(base: StremioAddon.baseURL(forManifest: resolved), manifest: manifest)
      let raw = try? JSONSerialization.data(withJSONObject: object, options: [])
      return ExtensionLoadResult(manifest: ExtensionManifest(stremio: manifest), backend: .stremio(addon), stremioManifestData: raw)
    }

    guard let object = json as? [String: Any], let manifest = ExtensionManifest(soraJSON: object), let scriptPath = manifest.scriptUrl else {
      throw ExtensionFailure("Invalid manifest: expected a Sora module (sourceName + scriptUrl) or a Stremio addon")
    }
    guard let scriptURL = URL(string: scriptPath, relativeTo: url)?.absoluteURL ?? URL.lenient(scriptPath) else {
      throw ExtensionFailure("Failed to load script from \(scriptPath): Invalid URL")
    }
    let script: String
    do {
      let data = try await fetch(scriptURL)
      script = String(decoding: data, as: UTF8.self)
    } catch {
      throw ExtensionFailure("Failed to load script from \(scriptURL.absoluteString): \(error.localizedDescription)")
    }
    return ExtensionLoadResult(manifest: manifest, backend: .sora(script: script), stremioManifestData: nil)
  }

  /// getExtension: GET, error on non-2xx ("HTTP 404 fetching <url>").
  private static func fetch(_ url: URL) async throws -> Data {
    let (data, response) = try await HTTP.data(url, allowErrorStatus: true)
    guard (200..<300).contains(response.statusCode) else {
      throw ExtensionFailure("HTTP \(response.statusCode) fetching \(url.absoluteString)")
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
      return try await SoraRuntime.call(script: script, functionName: functionName, arguments: arguments)
    }
  }

  /// searchResults(title) — Stremio addons also get the media (they look it up by TMDB id).
  static func searchResults(_ ext: LoadedExtension, title: String, media: Media?) async throws -> [ExtensionSearchItem] {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.searchResults(title: title, media: media)
    case .sora(let script):
      let raw = try await SoraRuntime.call(script: script, functionName: "searchResults", arguments: [title])
      return try parseSearchItems(raw)
    }
  }

  /// extractEpisodes(href)
  static func extractEpisodes(_ ext: LoadedExtension, href: String) async throws -> [ExtensionEpisode] {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.extractEpisodes(href: href)
    case .sora(let script):
      let raw = try await SoraRuntime.call(script: script, functionName: "extractEpisodes", arguments: [href])
      return try parseEpisodes(raw)
    }
  }

  /// extractStreamUrl(href): the raw answer, to be read by ExtensionStreamParser.
  static func extractStream(_ ext: LoadedExtension, href: String) async throws -> Any? {
    switch ext.backend {
    case .stremio(let addon):
      return try await addon.extractStreamUrl(href: href)
    case .sora(let script):
      return try await SoraRuntime.call(script: script, functionName: "extractStreamUrl", arguments: [href])
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
struct StoredExtensionPayload: Codable {
  var script: String?
  var stremioManifest: Data?
  var stremioBase: String?
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

  static func save(_ result: ExtensionLoadResult, key: String) {
    var payload = StoredExtensionPayload()
    switch result.backend {
    case .sora(let script):
      payload.script = script
    case .stremio(let addon):
      payload.stremioManifest = result.stremioManifestData
      payload.stremioBase = addon.base
    }
    guard let data = try? JSONEncoder().encode(payload) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL(key), options: .atomic)
  }

  static func load(key: String, config: InstalledExtension) -> LoadedExtension? {
    guard let data = try? Data(contentsOf: fileURL(key)),
          let payload = try? JSONDecoder().decode(StoredExtensionPayload.self, from: data) else { return nil }
    if let script = payload.script {
      return LoadedExtension(key: key, manifest: config.manifest, backend: .sora(script: script))
    }
    if let raw = payload.stremioManifest, let base = payload.stremioBase,
       let object = ExtensionJSON.parse(raw) as? [String: Any], let manifest = StremioManifest(json: object) {
      return LoadedExtension(key: key, manifest: config.manifest, backend: .stremio(StremioAddon(base: base, manifest: manifest)))
    }
    return nil
  }

  static func remove(key: String) {
    try? FileManager.default.removeItem(at: fileURL(key))
  }
}
