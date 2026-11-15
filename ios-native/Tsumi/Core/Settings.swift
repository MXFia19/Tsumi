import Foundation
import Observation

/// Persisted user settings, same keys and defaults as the Svelte app (common/modules/util.js `defaults`),
/// minus desktop-only ones (close action, external player path, DoH, miniplayer, angle).
/// Decoding is tolerant like settings.js `{ ...defaults, ...storedSettings }`: a missing or unreadable key
/// keeps its default, unknown keys are ignored and the Svelte array shapes of the sections are accepted
/// (see the `init(from:)` extensions below).
struct SettingsValues: Codable, Equatable {
  // Player
  var volume: Double = 1
  var playerAutoplay = true          // play the next episode when one ends
  var playerPause = true             // pause when the app goes to background
  var playerAutocomplete = true      // update list progress automatically
  var playerAutocompleteThreshold = 85 // % watched before progress is updated
  var playerSeek = 2.0               // seconds per seek step... (Svelte: 2)
  var playerSkip = false             // skip openings/endings automatically
  var subtitleLanguage = "eng"
  var audioLanguage = "jpn"
  var preferDubs = false
  var onlineSubtitlesAuto = false    // add online subtitles (subs.wing.st) when the source has none

  // Watch Together
  var w2gAutoSync = true             // follow the host when drifting more than 2 s (PROTOCOL.md "Auto-sync")
  var w2gDisplayName = ""            // name shown to the lobby when not logged in
  var w2gWatchOnMyOwn = false        // "Watch on my own" (PROTOCOL.md v2.2), remembered for the next lobby

  // Interface
  var titleLang: TitleLanguage = .english
  var bannerProvider = "mix"         // mix | anime | western
  var hideMyAnime = false
  var cardPreview = true
  var cardAudio = false              // audio icons / dub info on the cards and episode lists
  var toggleList: Bool = false       // Expandable Lists: relations / recommendations open as dropdowns
  var uiScale: Double = 1            // themes.js setScale, applied as a Dynamic Type size (1 = system)
  var accentColor = ""               // "#RRGGBB" tint (CSS Variables subset), empty = app default
  var adult = "none"                 // none | adult | hentai
  var hentaiBanner = false
  var toasts = "All"                 // All | Warnings / Successes | Errors | None
  /// Home sections: [title, sort, formats] like settings.homeSections in the Svelte app.
  var homeSections: [HomeSectionSetting] = HomeSectionSetting.defaults
  var customSections: [CustomAnimeSection] = CustomAnimeSection.defaults
  var westernSections: [WesternSection] = WesternSection.defaults

  // Notifications
  var systemNotify = true
  var aniNotify = "all"              // all | limited | none
  var releasesNotify: [ListStatus] = []
  /// The 'NOTONLIST' entry of the Svelte releasesNotify array (ListStatus has no such case).
  var releasesNotifyNotOnList = false
  var subAnnounce = "none"
  var dubAnnounce = "none"
  var hentaiAnnounce = "none"        // all | following | none

  // Discord (Settings > Discord, DiscordPresence)
  var enableRPC = "full"             // full | limited (no title / episode) | disabled
  var rpcSecondButton = "mal"        // mal | download: second presence button outside Watch Together

  // App
  var queryComplexity = "Complex"    // Complex | Simple (anilist.js queryComplexObjects)

  // Extensions (managed by the extension manager)
  var defaultExtension: String?
  var starredExtension: String?

  enum CodingKeys: String, CodingKey {
    case volume, playerAutoplay, playerPause, playerAutocomplete, playerAutocompleteThreshold, playerSeek, playerSkip
    case subtitleLanguage, audioLanguage, preferDubs
    case onlineSubtitlesAuto
    case w2gAutoSync, w2gDisplayName, w2gWatchOnMyOwn
    case titleLang, bannerProvider, hideMyAnime, cardPreview, cardAudio, toggleList, uiScale, accentColor
    case adult, hentaiBanner, toasts, homeSections, customSections, westernSections
    case systemNotify, aniNotify, releasesNotify, releasesNotifyNotOnList, subAnnounce, dubAnnounce, hentaiAnnounce
    case enableRPC, rpcSecondButton
    case queryComplexity, defaultExtension, starredExtension
  }

  /// releasesNotify value of the Svelte app for "Not on List".
  static let notOnListValue = "NOTONLIST"

  /// Every key the settings blob can hold (used to recognize a settings export).
  static var allKeys: [String] {
    let keys: [CodingKeys] = [
      .volume, .playerAutoplay, .playerPause, .playerAutocomplete, .playerAutocompleteThreshold, .playerSeek, .playerSkip,
      .subtitleLanguage, .audioLanguage, .preferDubs,
      .onlineSubtitlesAuto,
      .w2gAutoSync, .w2gDisplayName, .w2gWatchOnMyOwn,
      .titleLang, .bannerProvider, .hideMyAnime, .cardPreview, .cardAudio, .toggleList, .uiScale, .accentColor,
      .adult, .hentaiBanner, .toasts, .homeSections, .customSections, .westernSections,
      .systemNotify, .aniNotify, .releasesNotify, .releasesNotifyNotOnList, .subAnnounce, .dubAnnounce, .hentaiAnnounce,
      .enableRPC, .rpcSecondButton,
      .queryComplexity, .defaultExtension, .starredExtension
    ]
    return keys.map { $0.stringValue }
  }
}

extension SettingsValues {
  /// `{ ...defaults, ...stored }`: every key is optional and falls back to its default.
  init(from decoder: Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    volume = container.svcLossyDouble(.volume) ?? volume
    playerAutoplay = container.svcLossyBool(.playerAutoplay) ?? playerAutoplay
    playerPause = container.svcLossyBool(.playerPause) ?? playerPause
    playerAutocomplete = container.svcLossyBool(.playerAutocomplete) ?? playerAutocomplete
    playerAutocompleteThreshold = container.svcLossyInt(.playerAutocompleteThreshold) ?? playerAutocompleteThreshold
    playerSeek = container.svcLossyDouble(.playerSeek) ?? playerSeek
    playerSkip = container.svcLossyBool(.playerSkip) ?? playerSkip
    subtitleLanguage = container.settingsValue(String.self, .subtitleLanguage) ?? subtitleLanguage
    audioLanguage = container.settingsValue(String.self, .audioLanguage) ?? audioLanguage
    preferDubs = container.svcLossyBool(.preferDubs) ?? preferDubs
    onlineSubtitlesAuto = container.svcLossyBool(.onlineSubtitlesAuto) ?? onlineSubtitlesAuto
    w2gAutoSync = container.svcLossyBool(.w2gAutoSync) ?? w2gAutoSync
    w2gDisplayName = container.settingsValue(String.self, .w2gDisplayName) ?? w2gDisplayName
    w2gWatchOnMyOwn = container.svcLossyBool(.w2gWatchOnMyOwn) ?? w2gWatchOnMyOwn

    titleLang = container.settingsValue(TitleLanguage.self, .titleLang) ?? titleLang
    bannerProvider = container.settingsValue(String.self, .bannerProvider) ?? bannerProvider
    hideMyAnime = container.svcLossyBool(.hideMyAnime) ?? hideMyAnime
    cardPreview = container.svcLossyBool(.cardPreview) ?? cardPreview
    cardAudio = container.svcLossyBool(.cardAudio) ?? cardAudio
    toggleList = container.svcLossyBool(.toggleList) ?? toggleList
    uiScale = container.svcLossyDouble(.uiScale) ?? uiScale
    accentColor = container.settingsValue(String.self, .accentColor) ?? accentColor
    adult = container.settingsValue(String.self, .adult) ?? adult
    hentaiBanner = container.svcLossyBool(.hentaiBanner) ?? hentaiBanner
    toasts = container.settingsValue(String.self, .toasts) ?? toasts
    homeSections = container.settingsArray(HomeSectionSetting.self, .homeSections) ?? homeSections
    customSections = container.settingsArray(CustomAnimeSection.self, .customSections) ?? customSections
    westernSections = container.settingsArray(WesternSection.self, .westernSections) ?? westernSections

    systemNotify = container.svcLossyBool(.systemNotify) ?? systemNotify
    aniNotify = container.settingsValue(String.self, .aniNotify) ?? aniNotify
    var notOnList = container.svcLossyBool(.releasesNotifyNotOnList) ?? false
    if let raw = container.settingsValue([SettingsJSONValue].self, .releasesNotify) {
      let names = raw.compactMap { $0.stringValue }
      var statuses: [ListStatus] = []
      for name in names {
        if let status = ListStatus(rawValue: name), !statuses.contains(status) { statuses.append(status) }
      }
      releasesNotify = statuses
      if names.contains(Self.notOnListValue) { notOnList = true }
    }
    releasesNotifyNotOnList = notOnList
    subAnnounce = container.settingsValue(String.self, .subAnnounce) ?? subAnnounce
    dubAnnounce = container.settingsValue(String.self, .dubAnnounce) ?? dubAnnounce
    hentaiAnnounce = container.settingsValue(String.self, .hentaiAnnounce) ?? hentaiAnnounce

    if let mode = container.settingsValue(String.self, .enableRPC), ["full", "limited", "disabled"].contains(mode) {
      enableRPC = mode
    }
    if let button = container.settingsValue(String.self, .rpcSecondButton), ["mal", "download"].contains(button) {
      rpcSecondButton = button
    }

    queryComplexity = container.settingsValue(String.self, .queryComplexity) ?? queryComplexity

    defaultExtension = container.settingsValue(String.self, .defaultExtension)
    starredExtension = container.settingsValue(String.self, .starredExtension)
  }
}

struct HomeSectionSetting: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var sort: String
  var formats: [String]

  enum CodingKeys: String, CodingKey {
    case title, sort, formats
  }

  static let defaults: [HomeSectionSetting] = [
    .init(title: "Continue Watching", sort: "UPDATED_TIME_DESC", formats: []),
    .init(title: "Anime - Trending now", sort: "N/A", formats: ["TV", "MOVIE"]),
    .init(title: "Western - Trending Now", sort: "N/A", formats: ["TV", "MOVIE"]),
    .init(title: "Anime - Recent Subs", sort: "N/A", formats: ["TV", "MOVIE", "OVA", "ONA"]),
    .init(title: "Western - Recent TV Episodes", sort: "N/A", formats: ["TV"]),
    .init(title: "Anime - Romance", sort: "TRENDING_DESC", formats: ["TV", "MOVIE"]),
    .init(title: "Western - Crime Dramas", sort: "N/A", formats: ["TV", "MOVIE"]),
    .init(title: "Anime - Recent Dubs", sort: "N/A", formats: ["TV", "MOVIE", "OVA", "ONA"])
  ]
}

extension HomeSectionSetting {
  /// Object of the iOS app, or the Svelte `[title, sort, formats]` array.
  init(from decoder: Decoder) throws {
    if let array = try? decoder.singleValueContainer().decode([SettingsJSONValue].self) {
      let title = try SettingsJSONValue.title(array, decoder)
      self.init(
        title: title,
        sort: array.count > 1 ? (array[1].stringValue ?? "N/A") : "N/A",
        formats: array.count > 2 ? array[2].stringValues : []
      )
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decode(String.self, forKey: .title),
      sort: container.settingsValue(String.self, .sort) ?? "N/A",
      formats: container.settingsValue([String].self, .formats) ?? []
    )
  }
}

/// "Anime Sections" setting: [title, genres, tags, excluded genres, excluded tags].
struct CustomAnimeSection: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var genres: [String] = []
  var tags: [String] = []
  var excludedGenres: [String] = []
  var excludedTags: [String] = []

  enum CodingKeys: String, CodingKey {
    case title, genres, tags, excludedGenres, excludedTags
  }

  static let defaults: [CustomAnimeSection] = [
    .init(title: "Anime - Romance", genres: ["Romance"]),
    .init(title: "Anime - Isekai Comedy", genres: ["Comedy"], tags: ["Isekai"])
  ]
}

extension CustomAnimeSection {
  /// Object of the iOS app, or the Svelte `[title, genres, tags, excludedGenres, excludedTags]` array.
  init(from decoder: Decoder) throws {
    if let array = try? decoder.singleValueContainer().decode([SettingsJSONValue].self) {
      let title = try SettingsJSONValue.title(array, decoder)
      self.init(
        title: title,
        genres: array.count > 1 ? array[1].stringValues : [],
        tags: array.count > 2 ? array[2].stringValues : [],
        excludedGenres: array.count > 3 ? array[3].stringValues : [],
        excludedTags: array.count > 4 ? array[4].stringValues : []
      )
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decode(String.self, forKey: .title),
      genres: container.settingsValue([String].self, .genres) ?? [],
      tags: container.settingsValue([String].self, .tags) ?? [],
      excludedGenres: container.settingsValue([String].self, .excludedGenres) ?? [],
      excludedTags: container.settingsValue([String].self, .excludedTags) ?? []
    )
  }
}

/// "Western Sections" setting: [title, TMDB genres, media type (Both | TV Shows | Movies)].
struct WesternSection: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var genres: [String] = []
  var mediaType: String = "Both"

  enum CodingKeys: String, CodingKey {
    case title, genres, mediaType
  }

  static let defaults: [WesternSection] = [
    .init(title: "Western - Trending Now"),
    .init(title: "Western - Crime Dramas", genres: ["Crime", "Drama"], mediaType: "TV Shows"),
    .init(title: "Western - Sci-Fi & Fantasy", genres: ["Sci-Fi & Fantasy"])
  ]
}

extension WesternSection {
  /// Object of the iOS app, or the Svelte `[title, genres, mediaType]` array.
  init(from decoder: Decoder) throws {
    if let array = try? decoder.singleValueContainer().decode([SettingsJSONValue].self) {
      let title = try SettingsJSONValue.title(array, decoder)
      self.init(
        title: title,
        genres: array.count > 1 ? array[1].stringValues : [],
        mediaType: array.count > 2 ? (array[2].stringValue ?? "Both") : "Both"
      )
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decode(String.self, forKey: .title),
      genres: container.settingsValue([String].self, .genres) ?? [],
      mediaType: container.settingsValue(String.self, .mediaType) ?? "Both"
    )
  }
}

// MARK: - Tolerant decoding helpers

/// Any JSON value (the Svelte settings store section entries as heterogeneous arrays).
enum SettingsJSONValue: Decodable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([SettingsJSONValue])
  case object([String: SettingsJSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([SettingsJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: SettingsJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// The strings of an array value (other elements are skipped).
  var stringValues: [String] {
    if case .array(let values) = self { return values.compactMap { $0.stringValue } }
    return []
  }

  /// First element of a Svelte section array: its non-empty title.
  static func title(_ array: [SettingsJSONValue], _ decoder: Decoder) throws -> String {
    guard let title = array.first?.stringValue, !title.isEmpty else {
      throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Section without a title"))
    }
    return title
  }
}

/// Array element that decodes to nil instead of failing the whole array.
struct SettingsLossyItem<Wrapped: Decodable>: Decodable {
  let value: Wrapped?

  init(from decoder: Decoder) throws {
    value = try? Wrapped(from: decoder)
  }
}

private extension KeyedDecodingContainer {
  /// decodeIfPresent that also gives nil for a value of another type.
  func settingsValue<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
    guard let value = try? decodeIfPresent(type, forKey: key) else { return nil }
    return value
  }

  /// Array whose unreadable elements are dropped; nil when the key is missing or not an array.
  func settingsArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
    guard let items = try? decodeIfPresent([SettingsLossyItem<T>].self, forKey: key) else { return nil }
    return items.compactMap { $0.value }
  }
}

@Observable
final class AppSettings {
  static let shared = AppSettings()
  private static let storageKey = "tsumi.settings.v1"

  var values: SettingsValues {
    didSet { save() }
  }

  private init() {
    var initial = SettingsValues()
    var storedKeys = Set<String>()
    if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
      if let stored = try? JSONDecoder().decode(SettingsValues.self, from: data) {
        initial = stored
      }
      if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        storedKeys = Set(object.keys)
      }
    }
    let migrated = Self.migrateLegacyExtras(&initial, storedKeys: storedKeys)
    values = initial
    if migrated { save() }
  }

  func reset() { values = SettingsValues() }

  /// cardAudio, hentaiAnnounce and the 'NOTONLIST' flag used to live in separate UserDefaults keys
  /// (ServiceSettingsExtras); they are taken over once when the settings blob has no value for them.
  private static func migrateLegacyExtras(_ values: inout SettingsValues, storedKeys: Set<String>) -> Bool {
    let defaults = UserDefaults.standard
    var changed = false
    if !storedKeys.contains(SettingsValues.CodingKeys.cardAudio.stringValue),
       let legacy = defaults.object(forKey: "tsumi.services.cardAudio") as? Bool {
      values.cardAudio = legacy
      changed = true
    }
    if !storedKeys.contains(SettingsValues.CodingKeys.hentaiAnnounce.stringValue),
       let legacy = defaults.string(forKey: "tsumi.services.hentaiAnnounce") {
      values.hentaiAnnounce = legacy
      changed = true
    }
    if !storedKeys.contains(SettingsValues.CodingKeys.releasesNotifyNotOnList.stringValue),
       let legacy = defaults.object(forKey: "tsumi.services.releasesNotify.notOnList") as? Bool {
      values.releasesNotifyNotOnList = legacy
      changed = true
    }
    return changed
  }

  private func save() {
    if let data = try? JSONEncoder().encode(values) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
