import Foundation

// Shared data model of the native app. Mirrors the media objects of the Svelte app
// (common/modules/anilist.js, tmdb.js normalizeMedia) in a single typed structure.

enum MediaSource: String, Codable, Hashable {
  case anilist
  case tmdb
  /// A Sora module result opened as it is (module page, SoraResultView.swift): not an AniList / TMDB title.
  case sora
}

enum TMDBType: String, Codable, Hashable {
  case tv
  case movie
}

enum MediaFormat: String, Codable, Hashable, CaseIterable {
  case tv = "TV"
  case tvShort = "TV_SHORT"
  case movie = "MOVIE"
  case special = "SPECIAL"
  case ova = "OVA"
  case ona = "ONA"
  case music = "MUSIC"
  case unknown = "UNKNOWN"

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = MediaFormat(rawValue: raw) ?? .unknown
  }

  var label: String {
    switch self {
    case .tv: return "TV Series"
    case .tvShort: return "TV Short"
    case .movie: return "Movie"
    case .special: return "Special"
    case .ova: return "OVA"
    case .ona: return "ONA"
    case .music: return "Music"
    case .unknown: return "Unknown"
    }
  }
}

enum MediaStatus: String, Codable, Hashable, CaseIterable {
  case finished = "FINISHED"
  case releasing = "RELEASING"
  case notYetReleased = "NOT_YET_RELEASED"
  case cancelled = "CANCELLED"
  case hiatus = "HIATUS"
  case unknown = "UNKNOWN"

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = MediaStatus(rawValue: raw) ?? .unknown
  }

  var label: String {
    switch self {
    case .finished: return "Finished"
    case .releasing: return "Releasing"
    case .notYetReleased: return "Not Yet Released"
    case .cancelled: return "Cancelled"
    case .hiatus: return "Hiatus"
    case .unknown: return "Unknown"
    }
  }
}

enum MediaSeason: String, Codable, Hashable, CaseIterable {
  case winter = "WINTER"
  case spring = "SPRING"
  case summer = "SUMMER"
  case fall = "FALL"
}

/// Watch list status, same values as AniList (MyAnimeList statuses are mapped onto them).
enum ListStatus: String, Codable, Hashable, CaseIterable {
  case current = "CURRENT"
  case planning = "PLANNING"
  case completed = "COMPLETED"
  case dropped = "DROPPED"
  case paused = "PAUSED"
  case repeating = "REPEATING"

  var label: String {
    switch self {
    case .current: return "Watching"
    case .planning: return "Planning"
    case .completed: return "Completed"
    case .dropped: return "Dropped"
    case .paused: return "Paused"
    case .repeating: return "Rewatching"
    }
  }
}

struct MediaTitle: Codable, Hashable {
  var romaji: String?
  var english: String?
  var native: String?
  var userPreferred: String?

  /// Title in the language chosen in the settings (titleLang), with fallbacks.
  func display(_ language: TitleLanguage = .english) -> String {
    let ordered: [String?]
    switch language {
    case .english: ordered = [english, userPreferred, romaji, native]
    case .romaji: ordered = [romaji, userPreferred, english, native]
    case .native: ordered = [native, romaji, userPreferred, english]
    }
    return ordered.compactMap { $0 }.first { !$0.isEmpty } ?? "Unknown Title"
  }

  /// Every non-empty title, used for search/matching.
  var all: [String] {
    [userPreferred, english, romaji, native].compactMap { $0 }.filter { !$0.isEmpty }
  }
}

struct MediaImages: Codable, Hashable {
  var cover: URL?
  var coverLarge: URL?
  var banner: URL?
  var logo: URL?
  /// Hex color (#rrggbb) of the cover, when the source gives one.
  var color: String?
}

struct ListEntry: Codable, Hashable {
  var status: ListStatus
  var progress: Int
  var score: Double?
  var repeatCount: Int?
  var updatedAt: Date?
}

struct NextAiring: Codable, Hashable {
  var episode: Int
  var airingAt: Date
}

struct MediaRelation: Codable, Hashable, Identifiable {
  var id: String { media.id + relationType }
  var relationType: String
  var media: Media
}

struct MediaCharacter: Codable, Hashable, Identifiable {
  var id: String { name + (actorName ?? "") }
  var name: String
  var role: String?
  var image: URL?
  var actorName: String?
  var actorImage: URL?
}

struct MediaStaff: Codable, Hashable, Identifiable {
  var id: String { name + role }
  var name: String
  var role: String
  var image: URL?
}

/// One title (anime from AniList, or movie/show from TMDB).
/// `id` is a stable key: "al-<anilistId>" or "tmdb-<tv|movie>-<tmdbId>".
struct Media: Identifiable, Codable, Hashable {
  var id: String
  var source: MediaSource
  var anilistId: Int?
  var malId: Int?
  var tmdbId: Int?
  var tmdbType: TMDBType?
  var imdbId: String?

  var title: MediaTitle
  var images: MediaImages
  var format: MediaFormat
  var status: MediaStatus
  var description: String?
  var synonyms: [String] = []
  var genres: [String] = []
  var tags: [String] = []
  var studios: [String] = []
  var episodes: Int?
  var duration: Int?
  var season: MediaSeason?
  var seasonYear: Int?
  var startDate: Date?
  var averageScore: Int?
  var popularity: Int?
  var isAdult: Bool = false
  var countryOfOrigin: String?
  var nextAiring: NextAiring?
  var listEntry: ListEntry?
  var trailerYouTubeId: String?

  // Filled by detail requests only.
  var relations: [MediaRelation] = []
  var recommendations: [Media] = []
  var characters: [MediaCharacter] = []
  var staff: [MediaStaff] = []
  var numberOfSeasons: Int?

  var isMovie: Bool { format == .movie || tmdbType == .movie }
  var isAnime: Bool { source == .anilist }
  /// Pseudo media of a Sora module result played from its module page (id "sora-<extensionKey>-<href>", like PC
  /// match.js resultMedia): no AniList / TMDB title behind it, so no lookups, list or progress updates, Watch
  /// Together, Trakt, remote resume or next-episode autoplay for it. The id prefix also catches one decoded without
  /// its source (a peer's payload).
  var isSoraResult: Bool { source == .sora || id.hasPrefix(Media.soraResultPrefix) }

  static func anilistKey(_ id: Int) -> String { "al-\(id)" }
  static func tmdbKey(_ id: Int, _ type: TMDBType) -> String { "tmdb-\(type.rawValue)-\(id)" }
  static let soraResultPrefix = "sora-"
  static func soraResultKey(extensionKey: String, href: String) -> String { "\(soraResultPrefix)\(extensionKey)-\(href)" }

  enum CodingKeys: String, CodingKey {
    case id, source, anilistId, malId, tmdbId, tmdbType, imdbId
    case title, images, format, status, description, synonyms, genres, tags, studios, episodes, duration, season
    case seasonYear, startDate, averageScore, popularity, isAdult, countryOfOrigin, nextAiring, listEntry
    case trailerYouTubeId, relations, recommendations, characters, staff, numberOfSeasons
  }
}

extension Media {
  /// Tolerant decoding of stored media (media store, caches, offline queue): only `id` is required, a missing or
  /// unreadable field takes its default, so a field added or changed later never wipes the stored data.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      source: container.svcValue(MediaSource.self, .source)
        ?? (id.hasPrefix("tmdb-") ? .tmdb : id.hasPrefix(Media.soraResultPrefix) ? .sora : .anilist),
      title: container.svcValue(MediaTitle.self, .title) ?? MediaTitle(),
      images: container.svcValue(MediaImages.self, .images) ?? MediaImages(),
      format: container.svcValue(MediaFormat.self, .format) ?? .unknown,
      status: container.svcValue(MediaStatus.self, .status) ?? .unknown
    )
    anilistId = container.svcLossyInt(.anilistId)
    malId = container.svcLossyInt(.malId)
    tmdbId = container.svcLossyInt(.tmdbId)
    tmdbType = container.svcValue(TMDBType.self, .tmdbType)
    imdbId = container.svcValue(String.self, .imdbId)
    description = container.svcValue(String.self, .description)
    synonyms = container.svcArray(String.self, .synonyms)
    genres = container.svcArray(String.self, .genres)
    tags = container.svcArray(String.self, .tags)
    studios = container.svcArray(String.self, .studios)
    episodes = container.svcLossyInt(.episodes)
    duration = container.svcLossyInt(.duration)
    season = container.svcValue(MediaSeason.self, .season)
    seasonYear = container.svcLossyInt(.seasonYear)
    startDate = container.svcValue(Date.self, .startDate)
    averageScore = container.svcLossyInt(.averageScore)
    popularity = container.svcLossyInt(.popularity)
    isAdult = container.svcLossyBool(.isAdult) ?? false
    countryOfOrigin = container.svcValue(String.self, .countryOfOrigin)
    nextAiring = container.svcValue(NextAiring.self, .nextAiring)
    listEntry = container.svcValue(ListEntry.self, .listEntry)
    trailerYouTubeId = container.svcValue(String.self, .trailerYouTubeId)
    relations = container.svcArray(MediaRelation.self, .relations)
    recommendations = container.svcArray(Media.self, .recommendations)
    characters = container.svcArray(MediaCharacter.self, .characters)
    staff = container.svcArray(MediaStaff.self, .staff)
    numberOfSeasons = container.svcLossyInt(.numberOfSeasons)
  }
}

struct MediaPage {
  var items: [Media]
  var hasNextPage: Bool

  static let empty = MediaPage(items: [], hasNextPage: false)
}

/// Episode requested for playback. `number` is the absolute episode number (AniList style);
/// `season`/`localEpisode` are set for TMDB shows (season 2 episode 3 = S2E3).
struct EpisodeRef: Codable, Hashable {
  var number: Int
  var season: Int?
  var localEpisode: Int?
}

/// Episode metadata shown in episode lists.
struct EpisodeInfo: Identifiable, Codable, Hashable {
  var id: String { "\(season ?? 0)-\(number)" }
  var number: Int
  var season: Int?
  var localEpisode: Int?
  var title: String?
  var summary: String?
  var thumbnail: URL?
  var airDate: Date?
  var durationMinutes: Int?
  var isFiller: Bool = false
  /// Jikan "recap" flag (EpisodeList.svelte "Recap" badge).
  var isRecap: Bool = false

  var ref: EpisodeRef { EpisodeRef(number: number, season: season, localEpisode: localEpisode) }
}

/// "Recent episodes" feed entry (Recent Subs / Recent Dubs / Western Recent TV Episodes sections).
struct EpisodeFeedItem: Identifiable, Hashable {
  var id: String { "\(media.id)-\(episode)-\(dub)" }
  var media: Media
  var episode: Int
  var date: Date
  var dub: Bool = false
  var episodeTitle: String?
  var thumbnail: URL?
  /// Episode summary (episodeData.summary / overview), shown by the episode preview card.
  var summary: String? = nil
  /// Last episode of a batch release ("Episodes 1 ~ 3"), nil for a single episode.
  var lastEpisode: Int? = nil
}

/// Airing schedule entry (Schedule page).
struct AiringEpisode: Identifiable, Hashable {
  var id: String { "\(media.id)-\(episode)" }
  var media: Media
  var episode: Int
  var airingAt: Date
  /// Last episode airing at the same time ("Episode 5 ~ 7"), nil for a single episode.
  var lastEpisode: Int? = nil
  /// Dub production suspended (delayedIndefinitely): shown as "Suspended" instead of a countdown.
  var delayedIndefinitely: Bool = false
  /// Movie release of the schedule ("In theaters", "On digital", MovieReleases), shown instead of the episode.
  var releaseLabel: String? = nil

  /// "Episode 5" / "Episode 5 ~ 7" (episode() of anime.js), or the movie release.
  var episodeText: String {
    if let releaseLabel { return releaseLabel }
    if let lastEpisode, lastEpisode > episode { return "Episode \(episode) ~ \(lastEpisode)" }
    return "Episode \(episode)"
  }
}

/// A playable link returned by an extension.
struct StreamServer: Identifiable, Codable, Hashable {
  var id: String { url.absoluteString + title }
  var title: String
  var url: URL
  var headers: [String: String] = [:]
}

struct StreamResult: Hashable {
  var servers: [StreamServer]
  var subtitleURL: URL?
}

struct Viewer: Codable, Hashable {
  enum Service: String, Codable { case anilist, myanimelist }
  var id: Int
  var name: String
  var avatar: URL?
  var service: Service

  enum CodingKeys: String, CodingKey {
    case id, name, avatar, service
  }
}

extension Viewer {
  /// Tolerant decoding (stored accounts): a missing name or unreadable avatar does not drop the account.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(Int.self, forKey: .id),
      name: container.svcValue(String.self, .name) ?? "",
      avatar: container.svcValue(URL.self, .avatar),
      service: try container.decode(Service.self, forKey: .service)
    )
  }
}

struct AppNotification: Identifiable, Codable, Hashable {
  var id: String
  var title: String
  var message: String
  var date: Date
  var mediaKey: String?
  var episode: Int?
  var image: URL?
  var read: Bool = false
}

enum TitleLanguage: String, Codable, Hashable, CaseIterable {
  case english
  case romaji
  case native
}

enum SearchScope: String, Codable, Hashable, CaseIterable {
  case anime
  case western
  case both
}

enum SearchSort: String, Codable, Hashable, CaseIterable {
  case trending = "TRENDING_DESC"
  case popularity = "POPULARITY_DESC"
  case score = "SCORE_DESC"
  case title = "TITLE_ROMAJI"
  case newest = "START_DATE_DESC"
  case updated = "UPDATED_AT_DESC"

  var label: String {
    switch self {
    case .trending: return "Trending"
    case .popularity: return "Popularity"
    case .score: return "Score"
    case .title: return "Title"
    case .newest: return "Release Date"
    case .updated: return "Recently Updated"
    }
  }
}

/// Search / section filters (SearchBar.svelte variables).
struct MediaQuery: Codable, Hashable {
  var text: String?
  var scope: SearchScope = .both
  var formats: [MediaFormat] = []
  var genres: [String] = []
  var excludedGenres: [String] = []
  var tags: [String] = []
  var excludedTags: [String] = []
  var season: MediaSeason?
  var year: Int?
  var status: [MediaStatus] = []
  var excludedStatus: [MediaStatus] = []
  var sort: SearchSort = .trending
  var onList: Bool?
  var includeAdult: Bool = false
}
