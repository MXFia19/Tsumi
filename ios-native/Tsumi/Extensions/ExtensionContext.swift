import Foundation

/// TMDB/TVDB position of an AniList entry (tmdbClient.anilistToTmdb[id] in the Svelte app:
/// { id, type, tvdb_season, tvdb_epoffset }).
struct ExtensionAnimeMapping: Hashable {
  var tmdbId: Int
  var isMovie: Bool
  /// TVDB season the AniList entry corresponds to (nil or 0 = unknown).
  var season: Int?
  /// Episodes of that season that belong to earlier AniList entries.
  var episodeOffset: Int
}

/// One season of a TMDB show (`getDetails(id, 'tv').seasons[]`).
struct ExtensionSeasonInfo: Hashable {
  var seasonNumber: Int
  var episodeCount: Int
}

/// Result of TMDB `/find/{imdb}?external_source=imdb_id`.
struct ExtensionIMDbMatch: Hashable {
  var tvIds: [Int] = []
  var movieIds: [Int] = []
}

/// Data the extension system needs from the AniList/TMDB services, injected by the app so this
/// folder does not depend on them. Every closure has a harmless default (Stremio addons then fall
/// back to their own catalog search, like when the Svelte app has no TMDB mapping).
///
/// Wire it once at launch, e.g.:
/// ```
/// ExtensionContext.shared.animeToTMDB = { id in await Mappings.shared.tmdb(forAnilist: id) }
/// ```
struct ExtensionContext {
  /// AniList id -> TMDB id, movie flag, TVDB season and episode offset.
  var animeToTMDB: (Int) async -> ExtensionAnimeMapping? = { _ in nil }
  /// TMDB id -> IMDb id (`getDetails(id, type).externalIds.imdb_id`).
  var tmdbIMDbId: (Int, TMDBType) async -> String? = { _, _ in nil }
  /// IMDb id -> TMDB ids (`/find/{imdb}`).
  var tmdbFindByIMDb: (String) async -> ExtensionIMDbMatch? = { _ in nil }
  /// TMDB show id -> seasons with their episode counts (season 0 = specials).
  var tmdbSeasons: (Int) async -> [ExtensionSeasonInfo] = { _ in [] }
  /// TMDB id -> AniList id when the title is a known anime (tmdbClient.tmdbToAnilist).
  var tmdbToAnilistId: (Int, TMDBType) -> Int? = { _, _ in nil }
  /// Title used to search extensions (anilistClient.title): English or romaji per settings,
  /// userPreferred as fallback. The app may override it (e.g. userPreferred when logged in to AniList).
  var displayTitle: (Media) -> String = { media in ExtensionContext.defaultTitle(media) }

  static var shared = ExtensionContext()

  static func defaultTitle(_ media: Media) -> String {
    let title = media.title
    let preferred = ExtensionJSON.nonEmpty(title.userPreferred)
    let chosen: String?
    if AppSettings.shared.values.titleLang == .romaji {
      chosen = ExtensionJSON.nonEmpty(title.romaji) ?? preferred
    } else {
      chosen = ExtensionJSON.nonEmpty(title.english) ?? preferred
    }
    return chosen ?? title.display(AppSettings.shared.values.titleLang)
  }
}
