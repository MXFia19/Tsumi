import Foundation

// Types of the extension system (port of common/modules/extension.js + stremio.js data shapes).
// Everything here is a plain value type so it can travel between the main actor and the
// background tasks that run extensions.

/// Kind of extension: a Sora JavaScript module or a Stremio addon (extension.js `type`).
enum ExtensionKind: String, Codable, Hashable {
  case sora
  case stremio
}

/// Manifest shown in the settings. Sora manifests are kept as-is (sourceName, iconUrl, version,
/// scriptUrl, language, streamType, quality, type...); Stremio manifests are normalized like
/// `normalizeStremioManifest` in stremio.js.
struct ExtensionManifest: Codable, Hashable {
  var sourceName: String
  var iconUrl: String?
  var version: String?
  var description: String?
  var scriptUrl: String?
  var language: String?
  var streamType: String?
  var quality: String?
  var type: String?
  var baseUrl: String?
  var searchBaseUrl: String?
  var author: String?
  var asyncJS: Bool?
  var softsub: Bool?
  var stremioId: String?

  /// Sora module manifest; nil when sourceName or scriptUrl is missing
  /// ("Invalid manifest: expected a Sora module (sourceName + scriptUrl) or a Stremio addon").
  init?(soraJSON json: [String: Any]) {
    guard let name = ExtensionJSON.truthyString(json["sourceName"]),
          let script = ExtensionJSON.truthyString(json["scriptUrl"]) ?? ExtensionJSON.truthyString(json["scriptURL"]) else {
      return nil
    }
    sourceName = name
    scriptUrl = script
    iconUrl = ExtensionJSON.truthyString(json["iconUrl"])
    version = ExtensionJSON.string(json["version"])
    description = ExtensionJSON.string(json["description"])
    language = ExtensionJSON.string(json["language"])
    streamType = ExtensionJSON.string(json["streamType"])
    quality = ExtensionJSON.string(json["quality"])
    type = ExtensionJSON.string(json["type"])
    baseUrl = ExtensionJSON.string(json["baseUrl"])
    searchBaseUrl = ExtensionJSON.string(json["searchBaseUrl"])
    if let authorObject = ExtensionJSON.dict(json["author"]) {
      author = ExtensionJSON.string(authorObject["name"])
    } else {
      author = ExtensionJSON.string(json["author"])
    }
    asyncJS = json["asyncJS"] as? Bool
    softsub = json["softsub"] as? Bool
    stremioId = nil
  }

  /// normalizeStremioManifest (stremio.js).
  init(stremio manifest: StremioManifest) {
    sourceName = ExtensionJSON.nonEmpty(manifest.name) ?? manifest.id
    iconUrl = ExtensionJSON.nonEmpty(manifest.logo) ?? ExtensionJSON.nonEmpty(manifest.icon)
    version = ExtensionJSON.nonEmpty(manifest.version) ?? "0.0.0"
    description = manifest.description ?? ""
    scriptUrl = nil
    language = nil
    streamType = "Stremio"
    quality = nil
    type = nil
    baseUrl = nil
    searchBaseUrl = nil
    author = nil
    asyncJS = nil
    softsub = nil
    stremioId = manifest.id
  }

  /// Settings key: `${manifest.sourceName}-${manifest.version}` (JS prints "undefined" when the version is missing).
  var storageKey: String { "\(sourceName)-\(version ?? "undefined")" }

  var iconURL: URL? { URL.lenient(iconUrl) }
}

/// One installed extension as persisted (settings.extensions[key] = { url, enabled, manifest, linkResults }).
struct InstalledExtension: Codable, Identifiable, Hashable {
  var key: String
  var url: String
  var enabled: Bool
  var kind: ExtensionKind
  var manifest: ExtensionManifest
  /// Sora modules: a result tapped on the Search page opens its AniList / TMDB match (true, the default), or the
  /// module page as it is (false: modules that are not anime, shows or movies). Stored only when false, like PC
  /// (`linkResults` absent = true), so the settings of either app round-trip.
  var linkResults: Bool = true

  var id: String { key }
  var displayName: String { manifest.sourceName.isEmpty ? key : manifest.sourceName }

  enum CodingKeys: String, CodingKey {
    case key, url, enabled, kind, manifest, linkResults
  }
}

extension InstalledExtension {
  /// Same required keys as before; `linkResults` is optional (lists stored by older versions have none).
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    url = try container.decode(String.self, forKey: .url)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    kind = try container.decode(ExtensionKind.self, forKey: .kind)
    manifest = try container.decode(ExtensionManifest.self, forKey: .manifest)
    linkResults = (try? container.decodeIfPresent(Bool.self, forKey: .linkResults)) ?? true
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(url, forKey: .url)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(kind, forKey: .kind)
    try container.encode(manifest, forKey: .manifest)
    if !linkResults { try container.encode(false, forKey: .linkResults) }
  }
}

/// A loaded extension ready to be called (entries of ExtensionManager.extensions in extension.js):
/// the manifest plus either the module script or the Stremio addon description.
struct LoadedExtension: Identifiable {
  enum Backend {
    case sora(script: String)
    case stremio(StremioAddon)
  }

  var key: String
  var manifest: ExtensionManifest
  var backend: Backend
  /// Installed from this device or the local network: a Sora module may then fetch local addresses too
  /// (ExtensionNetworkPolicy).
  var allowsLocalNetwork = false
  /// Manifest and script came over https.
  var isSecure = true

  var id: String { key }
  var displayName: String { manifest.sourceName.isEmpty ? key : manifest.sourceName }
  var iconURL: URL? { manifest.iconURL }

  var kind: ExtensionKind {
    switch backend {
    case .sora: return .sora
    case .stremio: return .stremio
    }
  }

  var stremioAddon: StremioAddon? {
    if case .stremio(let addon) = backend { return addon }
    return nil
  }
}

/// Raw `searchResults` entry ({ title, image, href }).
struct ExtensionSearchItem: Hashable {
  var title: String
  var image: String
  var href: String
}

/// Search result scored against the media title (ExtensionResults.svelte `scored`).
struct ExtensionSearchResult: Identifiable, Hashable {
  var id: String
  var title: String
  var imageURL: URL?
  var href: String
  var extensionKey: String
  var score: Int
}

/// Results of one extension (ExtensionResults.svelte `groupedResults` entry).
struct ExtensionResultGroup: Identifiable, Hashable {
  var extensionKey: String
  var extensionName: String
  var extensionIcon: URL?
  var isStarred: Bool
  var results: [ExtensionSearchResult]

  var id: String { extensionKey }
}

/// `extractEpisodes` entry. Numbers keep JavaScript `Number()` semantics: NaN when missing or invalid.
struct ExtensionEpisode {
  var number: Double
  var season: Double?
  var title: String?
  var href: String
  /// Name of the episode's season given by the module (`seasonTitle`, or `seasonName`): "Saison 1", "Films"...
  /// Shown by the module page of a result opened as it is (SoraResultSource).
  var seasonTitle: String? = nil
}

/// Error carrying the same message the Svelte app shows.
struct ExtensionFailure: LocalizedError, Equatable {
  let message: String

  init(_ message: String) { self.message = message }

  var errorDescription: String? { message }
}

/// Helpers reading untyped JSON with JavaScript semantics (truthiness, Number(), encodeURIComponent).
enum ExtensionJSON {
  static func isNullish(_ value: Any?) -> Bool {
    guard let value else { return true }
    return value is NSNull
  }

  static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// String value; numbers are converted (String(value) in JS), booleans and objects are not.
  static func string(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !isBoolean(number) { return number.stringValue }
    return nil
  }

  /// Non-empty string (a truthy string in JS).
  static func truthyString(_ value: Any?) -> String? {
    guard let text = string(value), !text.isEmpty else { return nil }
    return text
  }

  static func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }

  /// JavaScript `Number(value)`: NaN for undefined/objects, 0 for null, parsed strings.
  static func number(_ value: Any?) -> Double {
    guard let value else { return .nan }
    if value is NSNull { return 0 }
    if let number = value as? NSNumber {
      if isBoolean(number) { return number.boolValue ? 1 : 0 }
      return number.doubleValue
    }
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return 0 }
      return Double(trimmed) ?? .nan
    }
    return .nan
  }

  static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

  static func array(_ value: Any?) -> [Any]? { value as? [Any] }

  static func strings(_ value: Any?) -> [String]? {
    guard let list = value as? [Any] else { return nil }
    return list.compactMap { string($0) }
  }

  /// JSON.parse with top-level fragments allowed; nil when the text is not JSON.
  static func parse(_ text: String) -> Any? {
    parse(Data(text.utf8))
  }

  static func parse(_ data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  /// JSON.stringify for dictionaries/arrays (nil when not serializable).
  static func stringify(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// JSON string literal (JSON.stringify of a string).
  static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{2028}": out += "\\u2028"
      case "\u{2029}": out += "\\u2029"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
    return out
  }

  private static let uriComponentAllowed: CharacterSet = {
    var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    set.insert(charactersIn: "-_.!~*'()")
    return set
  }()

  /// JavaScript encodeURIComponent.
  static func encodeURIComponent(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? text
  }

  /// Header dictionary with string values (non-string values are stringified, null skipped).
  static func headers(_ value: Any?) -> [String: String] {
    guard let object = value as? [String: Any] else { return [:] }
    var out: [String: String] = [:]
    for (key, raw) in object {
      if let text = string(raw) {
        out[key] = text
      } else if let number = raw as? NSNumber {
        out[key] = number.boolValue ? "true" : "false"
      }
    }
    return out
  }
}
