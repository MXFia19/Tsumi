import Foundation
import Observation

/// Persisted user settings, same keys and defaults as the Svelte app (common/modules/util.js `defaults`),
/// minus desktop-only ones (Discord RPC, close action, external player path, DoH, miniplayer, angle).
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

  // Interface
  var titleLang: TitleLanguage = .english
  var bannerProvider = "mix"         // mix | anime | western
  var hideMyAnime = false
  var cardPreview = true
  var adult = "none"                 // none | hentai
  var hentaiBanner = false
  var toasts = "All"                 // All | Errors | None
  /// Home sections: [title, sort, formats] like settings.homeSections in the Svelte app.
  var homeSections: [HomeSectionSetting] = HomeSectionSetting.defaults
  var customSections: [CustomAnimeSection] = CustomAnimeSection.defaults
  var westernSections: [WesternSection] = WesternSection.defaults

  // Notifications
  var systemNotify = true
  var aniNotify = "all"              // all | limited | none
  var releasesNotify: [ListStatus] = []
  var subAnnounce = "none"
  var dubAnnounce = "none"

  // Extensions (managed by the extension manager)
  var defaultExtension: String?
  var starredExtension: String?
}

struct HomeSectionSetting: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var sort: String
  var formats: [String]

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

/// "Anime Sections" setting: [title, genres, tags, excluded genres, excluded tags].
struct CustomAnimeSection: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var genres: [String] = []
  var tags: [String] = []
  var excludedGenres: [String] = []
  var excludedTags: [String] = []

  static let defaults: [CustomAnimeSection] = [
    .init(title: "Anime - Romance", genres: ["Romance"]),
    .init(title: "Anime - Isekai Comedy", genres: ["Comedy"], tags: ["Isekai"])
  ]
}

/// "Western Sections" setting: [title, TMDB genres, media type (Both | TV Shows | Movies)].
struct WesternSection: Codable, Hashable, Identifiable {
  var id: String { title }
  var title: String
  var genres: [String] = []
  var mediaType: String = "Both"

  static let defaults: [WesternSection] = [
    .init(title: "Western - Trending Now"),
    .init(title: "Western - Crime Dramas", genres: ["Crime", "Drama"], mediaType: "TV Shows"),
    .init(title: "Western - Sci-Fi & Fantasy", genres: ["Sci-Fi & Fantasy"])
  ]
}

@Observable
final class AppSettings {
  static let shared = AppSettings()
  private static let storageKey = "tsumi.settings.v1"

  var values: SettingsValues {
    didSet { save() }
  }

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
       let stored = try? JSONDecoder().decode(SettingsValues.self, from: data) {
      values = stored
    } else {
      values = SettingsValues()
    }
  }

  func reset() { values = SettingsValues() }

  private func save() {
    if let data = try? JSONEncoder().encode(values) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
