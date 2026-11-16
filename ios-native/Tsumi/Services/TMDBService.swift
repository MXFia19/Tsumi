import Foundation

// Port of common/modules/tmdb.js: TMDB client (40 requests / s), normalizeMedia -> Core Media,
// discover / trending / text search with genre mapping, details (images, logos, external ids, seasons,
// recommendations, similar, collection, trailer), season episodes, the "on the air" schedule with the
// TVmaze next-episode fallback, the "Western - Recent TV Episodes" feed (getMediaForRSS) and the
// TMDB backdrop / logo injection into AniList media (injectMediaImages).

struct TMDBEpisodeRef: Codable, Hashable {
  var airDate: String?
  var episodeNumber: Int?
  var seasonNumber: Int?
  var name: String?
  var still: URL?
  /// Episode overview (summary of the episode preview card).
  var overview: String? = nil
}

struct TMDBPerson: Codable, Hashable {
  var name: String
  var role: String
  var image: URL?
}

struct TMDBCastMember: Codable, Hashable {
  var character: String
  var actorName: String?
  var image: URL?
}

/// getDetails result.
struct TMDBDetails: Codable, Hashable {
  var id: Int
  var mediaType: TMDBType
  var title: String?
  var description: String?
  var genres: [String] = []
  var tags: [String] = []
  /// US certification (release_dates / content_ratings), "NR" when unknown.
  var rating: String = "NR"
  var isAdult: Bool = false
  var imdbId: String?
  var tvdbId: Int?
  var externalIds: [String: String] = [:]
  var streamingProviders: [String] = []
  var staff: [TMDBPerson] = []
  var characters: [TMDBCastMember] = []
  var status: MediaStatus = .unknown
  var averageScore: Int?
  var episodes: Int?
  var duration: Int?
  var seasonYear: Int?
  var releaseDate: String?
  var runtime: Int?
  var seasons: [TMDBSeasonInfo] = []
  var numberOfSeasons: Int = 0
  var poster: URL?
  var backdrop: URL?
  var logo: URL?
  var trailerYouTubeId: String?
  var networks: [String] = []
  var studios: [String] = []
  var recommendations: [Media] = []
  var similar: [Media] = []
  var lastEpisodeToAir: TMDBEpisodeRef?
  var nextEpisodeToAir: TMDBEpisodeRef?
  var collectionId: Int?
  var originalLanguage: String?
  var originCountries: [String] = []
}

/// getSeasonEpisodes entry.
struct TMDBSeasonEpisode: Codable, Hashable {
  var episode: Int
  var title: String?
  var summary: String?
  var image: URL?
  var airDate: Date?
  var length: Int?
  var rating: Int?
  var seasonNumber: Int
}

/// getSchedule entry: a western show with its next (or last) episode.
struct TMDBScheduleEntry: Hashable {
  var media: Media
  var airing: AiringNode
  var nextEpisode: TMDBEpisodeRef?
  var lastEpisode: TMDBEpisodeRef?
}

/// Variables of tmdbClient.search.
struct TMDBSearchQuery: Hashable {
  var page: Int = 1
  var sort: String?
  /// AniList formats: MOVIE and / or TV (empty = both).
  var formats: [String] = []
  /// Genre names (AniList or TMDB names, mapped per media type).
  var genres: [String] = []
  var excludedGenres: [String] = []
  var year: Int?
  /// Excludes ja / zh / ko productions (western sections).
  var excludeAnime: Bool = false
}

/// Untyped JSON passed between tasks.
struct TMDBJSONBox: @unchecked Sendable {
  let json: [String: Any]
}

struct TMDBArtwork: Codable, Hashable {
  var backdrop: URL?
  var logo: URL?
}

final class TMDBService: @unchecked Sendable {
  static let shared = TMDBService()

  static let apiKey = ServiceText.base64("OTgwMWI2YjA1NDhhZDU3NTgxZDExMWVhNjkwYzg1Yzg=")
  static let imageBase = "https://image.tmdb.org/t/p/"

  static let genres: [Int: String] = [
    28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
    10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
    878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western", 10759: "Action & Adventure",
    10762: "Kids", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk",
    10768: "War & Politics"
  ]

  private static let movieGenreIds: Set<Int> = [28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27, 10402, 9648, 10749, 878, 10770, 53, 10752, 37]
  private static let tvGenreIds: Set<Int> = [10759, 16, 35, 80, 99, 18, 10751, 10762, 9648, 10763, 10764, 10765, 10766, 10767, 10768, 37]

  private let limiter = ServiceRateLimiter(capacity: 40, interval: 1, minSpacing: 0.025)
  /// TVmaze allows 20 calls every 10 seconds per IP.
  private let tvMazeLimiter = ServiceRateLimiter(capacity: 20, interval: 10, minSpacing: 0.1)
  private let inflight = ServiceInflight()

  private init() {}

  static func image(_ path: String?, size: String) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    return URL(string: imageBase + size + path)
  }

  // MARK: - Transport

  func get(_ endpoint: String, params: [String: String] = [:]) async throws -> [String: Any] {
    guard ServiceNetworkMonitor.shared.isOnline else { throw ServiceError.offline }
    guard var components = URLComponents(string: "https://api.themoviedb.org/3" + endpoint.lowercased()) else { throw ServiceError.invalidResponse }
    var items = [URLQueryItem(name: "api_key", value: Self.apiKey)]
    for key in params.keys.sorted() {
      items.append(URLQueryItem(name: key, value: params[key]))
    }
    components.queryItems = items
    guard let url = components.url else { throw ServiceError.invalidResponse }
    var attempt = 0
    while true {
      attempt += 1
      await limiter.acquire()
      let (data, response) = try await HTTP.data(url, timeout: 30, allowErrorStatus: true)
      if response.statusCode == 429 && attempt < 4 {
        let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
        await limiter.pause(for: retry)
        continue
      }
      guard (200..<300).contains(response.statusCode), let json = ServiceJSON.object(data) else {
        throw HTTPError.status(response.statusCode, url)
      }
      return json
    }
  }

  // MARK: - Normalization (normalizeMedia)

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value, !value.isEmpty { return value }
    }
    return nil
  }

  static func normalizedStatus(_ status: String?, date: String?) -> MediaStatus {
    if let status, !status.isEmpty {
      if ["Ended", "Canceled", "Finished"].contains(where: { status.contains($0) }) { return .finished }
      if ["Returning Series", "Released", "In Production", "Post Production", "Pilot", "Airing"].contains(where: { status.contains($0) }) { return .releasing }
      return .notYetReleased
    }
    if let date, !date.isEmpty {
      guard let parsed = ServiceDates.parse(date) else { return .releasing }
      return parsed <= Date().addingTimeInterval(86400) ? .releasing : .notYetReleased
    }
    return .releasing
  }

  static func logo(from images: [String: Any]?) -> URL? {
    let logos = images?.array("logos") ?? []
    let chosen = logos.first(where: { $0.string("iso_639_1") == "en" }) ?? logos.first(where: { $0["iso_639_1"] is NSNull }) ?? logos.first
    return image(chosen?.string("file_path"), size: "w500")
  }

  /// normalizeMedia: TMDB result -> Core Media (+ extras). `index` resolves mapped anime.
  func normalize(_ item: [String: Any], index: AnimapIndex?) -> (media: Media, extras: MediaExtras)? {
    guard let id = item.int("id") else { return nil }
    let isTv = item.string("media_type") == "tv" || !(item.string("first_air_date") ?? "").isEmpty
    let type: TMDBType = isTv ? .tv : .movie
    let name = item.string("name")
    let originalName = item.string("original_name")
    let movieTitle = item.string("title")
    let originalTitle = item.string("original_title")
    var title = MediaTitle()
    title.romaji = Self.firstNonEmpty(name, originalName, movieTitle, originalTitle) ?? "Unknown Title"
    title.english = Self.firstNonEmpty(name, movieTitle, originalName, originalTitle) ?? "Unknown Title"
    title.native = Self.firstNonEmpty(originalName, originalTitle, name, movieTitle) ?? "Unknown Title"
    title.userPreferred = title.english
    var images = MediaImages()
    images.cover = Self.image(item.string("poster_path"), size: "w342")
    images.coverLarge = Self.image(item.string("poster_path"), size: "w500")
    images.banner = Self.image(item.string("backdrop_path"), size: "w1280")
    images.logo = Self.logo(from: item.dict("images"))
    var media = Media(id: Media.tmdbKey(id, type), source: .tmdb, title: title, images: images, format: isTv ? .tv : .movie, status: Self.normalizedStatus(item.string("status"), date: Self.firstNonEmpty(item.string("release_date"), item.string("first_air_date"))))
    media.tmdbId = id
    media.tmdbType = type
    media.anilistId = index?.tmdbToAnilist["\(type.rawValue)-\(id)"]
    media.description = item.string("overview")
    media.episodes = isTv ? nil : 1
    if let vote = item.double("vote_average"), vote > 0 { media.averageScore = Int((vote * 10).rounded()) }
    if let popularity = item.double("popularity") { media.popularity = Int(popularity.rounded()) }
    media.isAdult = item.bool("adult") ?? false
    media.genres = ServiceJSON.ints(item, "genre_ids").map { Self.genres[$0] ?? "Unknown" }
    if media.genres.isEmpty {
      media.genres = item.array("genres").compactMap { $0.string("name") }
    }
    let date = Self.firstNonEmpty(item.string("first_air_date"), item.string("release_date"))
    if let date {
      media.seasonYear = Int(date.prefix(4))
      media.startDate = ServiceDates.parse(String(date.prefix(10)))
    }
    var extras = MediaExtras()
    extras.originalLanguage = item.string("original_language")
    extras.originCountries = ServiceJSON.strings(item, "origin_country")
    return (media, extras)
  }

  private func isAsian(_ language: String?) -> Bool {
    guard let language else { return false }
    return ["ja", "zh", "ko"].contains(language)
  }

  // MARK: - Discover / trending (search)

  private func genreIds(_ names: [String], type: TMDBType) -> [Int] {
    var ids: [Int] = []
    for name in names {
      if type == .tv {
        switch name {
        case "Action", "Adventure": ids.append(10759); continue
        case "Sci-Fi", "Fantasy": ids.append(10765); continue
        case "Horror", "Thriller": ids.append(9648); continue
        case "War": ids.append(10768); continue
        case "Romance": ids.append(10766); continue
        default: break
        }
      } else {
        switch name {
        case "Action & Adventure": ids.append(contentsOf: [28, 12]); continue
        case "Sci-Fi & Fantasy": ids.append(contentsOf: [878, 14]); continue
        case "War & Politics": ids.append(10752); continue
        default: break
        }
      }
      if let id = Self.genres.first(where: { $0.value == name })?.key { ids.append(id) }
    }
    let allowed = type == .movie ? Self.movieGenreIds : Self.tvGenreIds
    return ids.filter { allowed.contains($0) }
  }

  private func discover(type: TMDBType, query: TMDBSearchQuery, enabled: Bool) async -> TMDBJSONBox {
    if !enabled { return TMDBJSONBox(json: [:]) }
    let included = genreIds(query.genres, type: type)
    let excluded = genreIds(query.excludedGenres, type: type)
    let sort = query.sort ?? ""
    let isTrending = sort.isEmpty || sort == "TRENDING_DESC"
    var endpoint = "/discover/\(type.rawValue)"
    var params: [String: String] = ["page": String(query.page)]
    if isTrending && included.isEmpty && query.year == nil && !query.excludeAnime && excluded.isEmpty {
      endpoint = "/trending/\(type.rawValue)/week"
    } else {
      if isTrending || sort == "POPULARITY_DESC" {
        params["sort_by"] = "popularity.desc"
      } else if sort.contains("POPULARITY") {
        params["sort_by"] = sort.contains("DESC") ? "popularity.desc" : "popularity.asc"
      } else if sort.contains("SCORE") {
        params["sort_by"] = sort.contains("DESC") ? "vote_average.desc" : "vote_average.asc"
      } else if sort.contains("DATE") {
        let field = type == .movie ? "primary_release_date" : "first_air_date"
        params["sort_by"] = field + (sort.contains("DESC") ? ".desc" : ".asc")
      } else if sort.contains("TITLE") {
        let field = type == .movie ? "original_title" : "original_name"
        params["sort_by"] = field + (sort.contains("DESC") ? ".desc" : ".asc")
      }
      if !included.isEmpty { params["with_genres"] = included.map(String.init).joined(separator: ",") }
      if !excluded.isEmpty { params["without_genres"] = excluded.map(String.init).joined(separator: ",") }
      if let year = query.year { params[type == .movie ? "primary_release_year" : "first_air_date_year"] = String(year) }
      if query.excludeAnime { params["without_original_language"] = "ja,zh,ko" }
    }
    return TMDBJSONBox(json: (try? await get(endpoint, params: params)) ?? ["results": [Any](), "total_pages": 0])
  }

  /// tmdbClient.search: discover / weekly trending of movies and / or shows, interleaved.
  func search(_ query: TMDBSearchQuery) async -> MediaPage {
    let index = await AnimeMappingsService.shared.animapIndex()
    let fetchMovies = query.formats.isEmpty || query.formats.contains("MOVIE")
    let fetchTv = query.formats.isEmpty || query.formats.contains("TV")
    async let movieResponse = discover(type: .movie, query: query, enabled: fetchMovies)
    async let tvResponse = discover(type: .tv, query: query, enabled: fetchTv)
    let movies = await movieResponse.json
    let shows = await tvResponse.json
    let movieItems = movies.array("results")
    let tvItems = shows.array("results")
    let hasNextPage = (movies.int("page") ?? 0) < (movies.int("total_pages") ?? 0) || (shows.int("page") ?? 0) < (shows.int("total_pages") ?? 0)
    var results: [(Media, MediaExtras)] = []
    for i in 0..<max(movieItems.count, tvItems.count) {
      if i < movieItems.count, let normalized = normalize(movieItems[i], index: index) { results.append(normalized) }
      if i < tvItems.count, let normalized = normalize(tvItems[i], index: index) { results.append(normalized) }
    }
    if fetchMovies && fetchTv {
      results.sort { ($0.0.popularity ?? 0) > ($1.0.popularity ?? 0) }
    }
    var media: [Media] = []
    var extras: [String: MediaExtras] = [:]
    for (item, extra) in results {
      if let anilistId = item.anilistId, let anime = try? await AniListService.shared.media(id: anilistId) {
        media.append(merge(anime: anime, tmdb: item))
      } else {
        media.append(item)
        extras[item.id] = extra
      }
    }
    let stored = MediaStore.shared.ingest(media, extras: extras)
    return MediaPage(items: stored, hasNextPage: hasNextPage)
  }

  /// AniList media found through a TMDB result: AniList data with the TMDB ids and artwork.
  private func merge(anime: Media, tmdb: Media) -> Media {
    var merged = anime
    merged.tmdbId = tmdb.tmdbId
    merged.tmdbType = tmdb.tmdbType
    if let banner = tmdb.images.banner { merged.images.banner = banner }
    if let logo = tmdb.images.logo { merged.images.logo = logo }
    return merged
  }

  /// tmdbClient.textSearch: /search/multi without anime (ja/zh/ko or animap-mapped titles).
  func textSearch(_ text: String, page: Int = 1) async -> MediaPage {
    guard !text.isEmpty else { return MediaPage.empty }
    let index = await AnimeMappingsService.shared.animapIndex()
    guard let data = try? await get("/search/multi", params: ["query": text, "page": String(page), "include_adult": "false"]) else { return MediaPage.empty }
    var media: [Media] = []
    var extras: [String: MediaExtras] = [:]
    for item in data.array("results") {
      let mediaType = item.string("media_type")
      guard mediaType == "tv" || mediaType == "movie", let normalized = normalize(item, index: index) else { continue }
      if normalized.media.anilistId != nil || isAsian(normalized.extras.originalLanguage) { continue }
      media.append(normalized.media)
      extras[normalized.media.id] = normalized.extras
    }
    let stored = MediaStore.shared.ingest(media, extras: extras)
    return MediaPage(items: stored, hasNextPage: (data.int("page") ?? 0) < (data.int("total_pages") ?? 0))
  }

  // MARK: - Details (getDetails)

  func details(id: Int, type: TMDBType) async -> TMDBDetails? {
    let cacheKey = "tmdb.details.v2.\(type.rawValue).\(id)"
    if let cached = await DiskCache.shared.get(cacheKey, as: TMDBDetails.self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) { return cached }
    do {
      let details: TMDBDetails = try await inflight.run(cacheKey) {
        try await self.fetchDetails(id: id, type: type)
      }
      await DiskCache.shared.set(cacheKey, details, ttl: Self.detailsTTL(details))
      return details
    } catch {
      return await DiskCache.shared.get(cacheKey, as: TMDBDetails.self, allowExpired: true)
    }
  }

  /// Ended shows and released movies change little (3 days); a show still airing gets new episodes, seasons and
  /// next-episode dates, so its details are refreshed every 12 hours.
  static func detailsTTL(_ details: TMDBDetails) -> TimeInterval {
    details.status == .finished || (details.mediaType == .movie && details.status == .releasing) ? 3 * 24 * 3600 : 12 * 3600
  }

  /// A season with an episode to come, without air date or aired in the last two weeks is still changing (titles,
  /// stills, new episodes): 12 hours. Older seasons: 3 days.
  static func seasonTTL(_ episodes: [TMDBSeasonEpisode], now: Date = Date()) -> TimeInterval {
    let recent = now.addingTimeInterval(-14 * 24 * 3600)
    let changing = episodes.isEmpty || episodes.contains { ($0.airDate ?? .distantFuture) > recent }
    return changing ? 12 * 3600 : 3 * 24 * 3600
  }

  private func fetchDetails(id: Int, type: TMDBType) async throws -> TMDBDetails {
    let ratingEndpoint = type == .movie ? "release_dates" : "content_ratings"
    let append = "videos,credits,recommendations,similar,external_ids,keywords,watch/providers,\(ratingEndpoint),images"
    let data = try await get("/\(type.rawValue)/\(id)", params: ["append_to_response": append])
    let index = await AnimeMappingsService.shared.animapIndex()
    var details = TMDBDetails(id: id, mediaType: type)
    details.title = data.string("name") ?? data.string("title")
    details.description = data.string("overview")
    details.genres = data.array("genres").compactMap { $0.string("name") }
    let keywords = data.dict("keywords")
    details.tags = ((keywords?.array("results") ?? []) + (keywords?.array("keywords") ?? [])).compactMap { $0.string("name") }
    if type == .movie {
      let us = data.dict("release_dates")?.array("results").first { $0.string("iso_3166_1") == "US" }
      let certification = us?.array("release_dates").first?.string("certification") ?? ""
      details.rating = certification.isEmpty ? "NR" : certification
    } else {
      let us = data.dict("content_ratings")?.array("results").first { $0.string("iso_3166_1") == "US" }
      let rating = us?.string("rating") ?? ""
      details.rating = rating.isEmpty ? "NR" : rating
    }
    details.isAdult = data.bool("adult") ?? false
    if let external = data.dict("external_ids") {
      for (key, value) in external {
        if let string = value as? String { details.externalIds[key] = string }
        if let number = value as? Int { details.externalIds[key] = String(number) }
      }
      details.imdbId = external.string("imdb_id")
      details.tvdbId = external.int("tvdb_id")
    }
    details.streamingProviders = (data.dict("watch/providers")?.dict("results")?.dict("US")?.array("flatrate") ?? []).compactMap { $0.string("provider_name") }
    let credits = data.dict("credits")
    let jobs: Set<String> = ["Director", "Writer", "Screenplay", "Creator", "Original Series Creator"]
    details.staff = (credits?.array("crew") ?? []).compactMap { person in
      guard let job = person.string("job"), jobs.contains(job), let name = person.string("name") else { return nil }
      return TMDBPerson(name: name, role: job, image: Self.image(person.string("profile_path"), size: "w185"))
    }
    details.characters = (credits?.array("cast") ?? []).prefix(15).compactMap { actor in
      guard let character = actor.string("character") else { return nil }
      return TMDBCastMember(character: character, actorName: actor.string("name"), image: Self.image(actor.string("profile_path"), size: "w185"))
    }
    let status = data.string("status") ?? ""
    if ["Ended", "Canceled"].contains(status) {
      details.status = .finished
    } else if ["Returning Series", "Released", "In Production", "Post Production", "Pilot"].contains(status) {
      details.status = .releasing
    } else {
      details.status = .notYetReleased
    }
    if let vote = data.double("vote_average"), vote > 0 { details.averageScore = Int((vote * 10).rounded()) }
    let runtimes = ServiceJSON.ints(data, "episode_run_time")
    details.episodes = type == .movie ? 1 : data.int("number_of_episodes")
    details.duration = type == .movie ? data.int("runtime") : runtimes.first
    let date = Self.firstNonEmpty(data.string("first_air_date"), data.string("release_date"))
    details.seasonYear = date.flatMap { Int($0.prefix(4)) }
    details.releaseDate = Self.firstNonEmpty(data.string("release_date"), data.string("first_air_date"))
    details.runtime = data.int("runtime") ?? runtimes.first
    if type == .tv {
      details.seasons = data.array("seasons").compactMap { season in
        guard let number = season.int("season_number"), number > 0 else { return nil }
        return TMDBSeasonInfo(seasonNumber: number, episodeCount: season.int("episode_count") ?? 0, name: season.string("name"), airDate: season.string("air_date"), poster: Self.image(season.string("poster_path"), size: "w342"))
      }
    }
    details.numberOfSeasons = data.int("number_of_seasons") ?? 0
    details.poster = Self.image(data.string("poster_path"), size: "w500")
    details.backdrop = Self.image(data.string("backdrop_path"), size: "w1280")
    details.logo = Self.logo(from: data.dict("images"))
    let videos = data.dict("videos")?.array("results") ?? []
    let trailer = videos.first(where: { $0.string("type") == "Trailer" && $0.string("site") == "YouTube" }) ?? videos.first(where: { $0.string("site") == "YouTube" })
    details.trailerYouTubeId = trailer?.string("key")
    details.networks = data.array("networks").compactMap { $0.string("name") }
    details.studios = data.array("production_companies").compactMap { $0.string("name") }
    details.recommendations = (data.dict("recommendations")?.array("results") ?? []).compactMap { normalize($0, index: index)?.media }
    details.similar = (data.dict("similar")?.array("results") ?? []).compactMap { normalize($0, index: index)?.media }
    details.lastEpisodeToAir = Self.episodeRef(data.dict("last_episode_to_air"))
    details.nextEpisodeToAir = Self.episodeRef(data.dict("next_episode_to_air"))
    details.collectionId = data.dict("belongs_to_collection")?.int("id")
    details.originalLanguage = data.string("original_language")
    details.originCountries = ServiceJSON.strings(data, "origin_country")
    return details
  }

  private static func episodeRef(_ dict: [String: Any]?) -> TMDBEpisodeRef? {
    guard let dict else { return nil }
    return TMDBEpisodeRef(airDate: dict.string("air_date"), episodeNumber: dict.int("episode_number"), seasonNumber: dict.int("season_number"), name: dict.string("name"), still: image(dict.string("still_path"), size: "w500"), overview: dict.string("overview"))
  }

  /// DetailsModal TMDB enrichment: applies getDetails to a normalized media.
  func apply(_ details: TMDBDetails, to media: Media) -> (media: Media, extras: MediaExtras) {
    var result = media
    if !details.genres.isEmpty { result.genres = details.genres }
    if !details.tags.isEmpty { result.tags = details.tags }
    if let description = details.description, !description.isEmpty { result.description = description }
    if let episodes = details.episodes { result.episodes = episodes }
    if let duration = details.duration { result.duration = duration }
    if details.status != .unknown { result.status = details.status }
    if let score = details.averageScore { result.averageScore = score }
    if let trailer = details.trailerYouTubeId { result.trailerYouTubeId = trailer }
    if let backdrop = details.backdrop { result.images.banner = backdrop }
    if result.images.logo == nil { result.images.logo = details.logo }
    if let year = details.seasonYear { result.seasonYear = year }
    result.isAdult = details.isAdult || result.isAdult
    result.studios = details.studios
    result.staff = details.staff.map { MediaStaff(name: $0.name, role: $0.role, image: $0.image) }
    result.characters = details.characters.map { MediaCharacter(name: $0.character, role: nil, image: $0.image, actorName: $0.actorName, actorImage: $0.image) }
    result.numberOfSeasons = details.numberOfSeasons > 0 ? details.numberOfSeasons : nil
    result.imdbId = details.imdbId ?? result.imdbId
    var extras = MediaStore.shared.extras(for: media)
    extras.contentRating = details.rating
    extras.networks = details.networks
    extras.streamingProviders = details.streamingProviders
    extras.tmdbSeasons = details.seasons
    extras.collectionId = details.collectionId
    extras.tvdbId = details.tvdbId
    extras.originalLanguage = details.originalLanguage ?? extras.originalLanguage
    extras.originCountries = details.originCountries
    extras.tmdbEnriched = true
    return (result, extras)
  }

  /// Media built from details only (deep links / Stremio items).
  func media(id: Int, type: TMDBType) async -> Media? {
    if let stored = MediaStore.shared.media(Media.tmdbKey(id, type)) { return stored }
    guard let details = await self.details(id: id, type: type) else { return nil }
    var title = MediaTitle()
    title.english = details.title
    title.romaji = details.title
    title.userPreferred = details.title
    var images = MediaImages()
    images.cover = details.poster
    images.coverLarge = details.poster
    images.banner = details.backdrop
    images.logo = details.logo
    var base = Media(id: Media.tmdbKey(id, type), source: .tmdb, title: title, images: images, format: type == .movie ? .movie : .tv, status: details.status)
    base.tmdbId = id
    base.tmdbType = type
    base.anilistId = await AnimeMappingsService.shared.anilistId(tmdbId: id, type: type)
    let enriched = apply(details, to: base)
    return MediaStore.shared.ingest([enriched.media], extras: [enriched.media.id: enriched.extras]).first
  }

  // MARK: - Seasons / collection / relations / recommendations / trailer

  func seasonEpisodes(id: Int, season: Int) async -> [TMDBSeasonEpisode] {
    let cacheKey = "tmdb.season.\(id).\(season)"
    if let cached = await DiskCache.shared.get(cacheKey, as: [TMDBSeasonEpisode].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) { return cached }
    guard let data = try? await get("/tv/\(id)/season/\(season)") else {
      return await DiskCache.shared.get(cacheKey, as: [TMDBSeasonEpisode].self, allowExpired: true) ?? []
    }
    let episodes: [TMDBSeasonEpisode] = data.array("episodes").compactMap { episode in
      guard let number = episode.int("episode_number") else { return nil }
      let rating = episode.double("vote_average").flatMap { $0 > 0 ? Int(($0 * 10).rounded()) : nil }
      return TMDBSeasonEpisode(episode: number, title: episode.string("name"), summary: episode.string("overview"), image: Self.image(episode.string("still_path"), size: "w500"), airDate: ServiceDates.parse(episode.string("air_date")), length: episode.int("runtime"), rating: rating, seasonNumber: season)
    }
    await DiskCache.shared.set(cacheKey, episodes, ttl: Self.seasonTTL(episodes))
    return episodes
  }

  func collection(id: Int) async -> [Media] {
    let cacheKey = "tmdb.collection.\(id)"
    if let cached = await DiskCache.shared.get(cacheKey, as: [Media].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) {
      return MediaStore.shared.ingest(cached, overwrite: false)
    }
    let index = await AnimeMappingsService.shared.animapIndex()
    guard let data = try? await get("/collection/\(id)") else { return [] }
    let parts = data.array("parts").compactMap { normalize($0, index: index)?.media }
    let stored = MediaStore.shared.ingest(parts)
    await DiskCache.shared.set(cacheKey, stored, ttl: 7 * 24 * 3600)
    return stored
  }

  /// getRelations: movies of the same collection as PREQUEL / SEQUEL.
  func relations(id: Int, type: TMDBType) async -> [MediaRelation] {
    guard type == .movie, let details = await self.details(id: id, type: .movie), let collectionId = details.collectionId else { return [] }
    let parts = await collection(id: collectionId).sorted { ($0.seasonYear ?? 0) < ($1.seasonYear ?? 0) }
    return parts.filter { $0.tmdbId != id }.map { part in
      MediaRelation(relationType: (part.seasonYear ?? 0) < (details.seasonYear ?? 0) ? "PREQUEL" : "SEQUEL", media: part)
    }
  }

  /// getRecommendations: recommendations + similar, deduplicated.
  func recommendations(id: Int, type: TMDBType) async -> [Media] {
    guard let details = await self.details(id: id, type: type) else { return [] }
    var seen = Set<String>()
    let unique = (details.recommendations + details.similar).filter { item in
      if seen.contains(item.id) { return false }
      seen.insert(item.id)
      return true
    }
    return MediaStore.shared.ingest(unique, overwrite: false)
  }

  /// getTrailer: YouTube id of the trailer.
  func trailer(for media: Media) async -> String? {
    if let trailer = media.trailerYouTubeId { return trailer }
    guard let id = media.tmdbId else { return nil }
    return await self.details(id: id, type: media.tmdbType ?? (media.format == .movie ? .movie : .tv))?.trailerYouTubeId
  }

  /// /find/{id}?external_source=imdb_id|tvdb_id: first match, a show before a movie.
  func find(externalId: String, source: String) async -> (id: Int, type: TMDBType)? {
    let matches = await findAll(externalId: externalId, source: source)
    if let show = matches.tvIds.first { return (show, .tv) }
    if let movie = matches.movieIds.first { return (movie, .movie) }
    return nil
  }

  /// /find/{id}?external_source=imdb_id|tvdb_id: every match (tv_results and movie_results ids, in order),
  /// for callers that prefer a type (stremio.js tmdbFromImdb).
  func findAll(externalId: String, source: String) async -> (tvIds: [Int], movieIds: [Int]) {
    guard let data = try? await get("/find/\(externalId)", params: ["external_source": source]) else { return ([], []) }
    let tvIds = data.array("tv_results").compactMap { $0.int("id") }
    let movieIds = data.array("movie_results").compactMap { $0.int("id") }
    return (tvIds, movieIds)
  }

  // MARK: - Schedule (getSchedule) and recent episodes (getMediaForRSS)

  func schedule(page: Int = 1) async -> (entries: [TMDBScheduleEntry], hasNextPage: Bool) {
    let index = await AnimeMappingsService.shared.animapIndex()
    var response = (try? await get("/tv/on_the_air", params: ["page": String(page)])) ?? [:]
    if response.array("results").isEmpty {
      response = (try? await get("/tv/popular", params: ["page": String(page)])) ?? [:]
    }
    let western: [(Media, MediaExtras)] = response.array("results").compactMap { item in
      guard let normalized = normalize(item, index: index) else { return nil }
      let asianCountry = normalized.extras.originCountries.contains { ["JP", "CN", "KR"].contains($0) }
      let mapped = index.tmdbToAnilist["tv-\(normalized.media.tmdbId ?? 0)"] != nil || index.tmdbToAnilist["movie-\(normalized.media.tmdbId ?? 0)"] != nil
      if isAsian(normalized.extras.originalLanguage) || asianCountry || mapped { return nil }
      return (normalized.media, normalized.extras)
    }
    let entries: [TMDBScheduleEntry] = await withTaskGroup(of: (Int, TMDBScheduleEntry?).self) { group in
      for (offset, pair) in western.enumerated() {
        let media = pair.0
        let extras = pair.1
        group.addTask {
          (offset, await self.scheduleEntry(media: media, extras: extras))
        }
      }
      var collected: [(Int, TMDBScheduleEntry)] = []
      for await (offset, entry) in group {
        if let entry { collected.append((offset, entry)) }
      }
      return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
    let sorted = entries.sorted { $0.airing.airingAt < $1.airing.airingAt }
    let stored = MediaStore.shared.ingest(sorted.map { $0.media })
    var result: [TMDBScheduleEntry] = []
    for (offset, entry) in sorted.enumerated() where offset < stored.count {
      var copy = entry
      copy.media = stored[offset]
      result.append(copy)
    }
    return (result, (response.int("page") ?? 0) < (response.int("total_pages") ?? 0))
  }

  private func scheduleEntry(media: Media, extras: MediaExtras) async -> TMDBScheduleEntry? {
    guard let id = media.tmdbId, let details = await self.details(id: id, type: .tv) else { return nil }
    var chosen = details.nextEpisodeToAir ?? details.lastEpisodeToAir
    let nextDate = ServiceDates.parse(details.nextEpisodeToAir?.airDate)
    if details.nextEpisodeToAir == nil || (nextDate ?? .distantPast) < Date(), let imdb = details.imdbId,
       let next = await tvMazeNextEpisode(imdbId: imdb) {
      chosen = next
    }
    guard let episode = chosen, let airDate = episode.airDate, let airingAt = ServiceDates.endOfDay(airDate) else { return nil }
    let enriched = apply(details, to: media)
    MediaStore.shared.updateExtras(media.id) { value in
      value = enriched.extras
      value.airingSchedule = [AiringNode(episode: episode.episodeNumber ?? 1, airingAt: airingAt)]
    }
    return TMDBScheduleEntry(media: enriched.media, airing: AiringNode(episode: episode.episodeNumber ?? 1, airingAt: airingAt), nextEpisode: details.nextEpisodeToAir, lastEpisode: details.lastEpisodeToAir)
  }

  /// Release dates of a movie (/movie/{id}/release_dates), kept 12 hours: digital dates are often added late.
  func releaseDates(movieId: Int) async -> [TMDBReleaseCountry] {
    let cacheKey = "tmdb.releaseDates.\(movieId)"
    if let cached = await DiskCache.shared.get(cacheKey, as: [TMDBReleaseCountry].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) {
      return cached
    }
    guard let data = try? await get("/movie/\(movieId)/release_dates") else {
      return await DiskCache.shared.get(cacheKey, as: [TMDBReleaseCountry].self, allowExpired: true) ?? []
    }
    let countries: [TMDBReleaseCountry] = data.array("results").compactMap { entry in
      guard let country = entry.string("iso_3166_1") else { return nil }
      let dates: [TMDBReleaseDate] = entry.array("release_dates").compactMap { item in
        guard let type = item.int("type"), let date = item.string("release_date") else { return nil }
        return TMDBReleaseDate(type: type, date: date)
      }
      return TMDBReleaseCountry(country: country, dates: dates)
    }
    await DiskCache.shared.set(cacheKey, countries, ttl: 12 * 3600)
    return countries
  }

  /// Upcoming movies of the schedule (getMovieSchedule of tmdb.js, MovieReleases): theatrical releases in the
  /// first two release regions and digital releases (first region and US) of the next MovieReleases.windowDays
  /// days, most popular first, each with its first release to come. Anime movies known to AniList are left out
  /// like in `schedule`.
  func movieSchedule(page: Int = 1, theatrical: Bool, digital: Bool) async -> (entries: [(media: Media, release: MovieRelease)], hasNextPage: Bool) {
    let regions = MovieReleases.regions
    let first = regions.first ?? "US"
    let now = Date()
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(identifier: "UTC")
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let base = [
      "release_date.gte": dayFormatter.string(from: now),
      "release_date.lte": dayFormatter.string(from: now.addingTimeInterval(Double(MovieReleases.windowDays) * 86_400)),
      "sort_by": "popularity.desc",
      "include_adult": "false",
      "page": String(page)
    ]
    var queries: [[String: String]] = []
    if theatrical {
      for region in Self.uniqueRegions([first, regions.count > 1 ? regions[1] : "US"]) {
        queries.append(["region": region, "with_release_type": "2|3"])
      }
    }
    if digital {
      for region in Self.uniqueRegions([first, "US"]) {
        queries.append(["region": region, "with_release_type": "4"])
      }
    }
    let pages: [[String: Any]] = await withTaskGroup(of: (Int, [String: Any]?).self) { group in
      for (offset, query) in queries.enumerated() {
        let params = base.merging(query) { _, new in new }
        group.addTask {
          (offset, try? await self.get("/discover/movie", params: params))
        }
      }
      var collected: [(Int, [String: Any])] = []
      for await (offset, response) in group {
        if let response { collected.append((offset, response)) }
      }
      return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
    let index = await AnimeMappingsService.shared.animapIndex()
    var seen = Set<Int>()
    var movies: [Media] = []
    for response in pages {
      for item in response.array("results") {
        guard let id = item.int("id"), !(item.bool("adult") ?? false), !seen.contains(id),
              index.tmdbToAnilist["movie-\(id)"] == nil,
              let normalized = normalize(item, index: index) else { continue }
        seen.insert(id)
        movies.append(normalized.media)
      }
    }
    let found: [(Int, Media, MovieRelease)] = await withTaskGroup(of: (Int, Media, MovieRelease)?.self) { group in
      for (offset, media) in movies.enumerated() {
        group.addTask {
          guard let id = media.tmdbId else { return nil }
          let dates = await self.releaseDates(movieId: id)
          let releases = MovieReleases.releases(dates, regions: regions, theatrical: theatrical, digital: digital, now: now)
          guard let first = releases.first else { return nil }
          return (offset, media, first)
        }
      }
      var collected: [(Int, Media, MovieRelease)] = []
      for await item in group {
        if let item { collected.append(item) }
      }
      return collected.sorted { $0.0 < $1.0 }
    }
    let stored = MediaStore.shared.ingest(found.map { $0.1 })
    var entries: [(media: Media, release: MovieRelease)] = []
    for (offset, item) in found.enumerated() where offset < stored.count {
      entries.append((stored[offset], item.2))
    }
    let hasNextPage = pages.contains { ($0.int("page") ?? 0) < ($0.int("total_pages") ?? 0) }
    return (entries, hasNextPage)
  }

  private static func uniqueRegions(_ list: [String]) -> [String] {
    var result: [String] = []
    for region in list where !result.contains(region) { result.append(region) }
    return result
  }

  /// TVmaze next episode lookup, cached: "none" (no next episode known) is cached too.
  private struct TVMazeNext: Codable {
    var episode: TMDBEpisodeRef?
  }

  /// TVmaze lookup of the next episode by IMDb id, cached 6 hours and rate limited (TVmaze answers 429 past 20
  /// calls in 10 seconds, which used to drop shows from the western schedule).
  private func tvMazeNextEpisode(imdbId: String) async -> TMDBEpisodeRef? {
    let cacheKey = "tvmaze.next.\(imdbId)"
    if let cached = await DiskCache.shared.get(cacheKey, as: TVMazeNext.self) {
      // A cached next episode that already aired is looked up again.
      let aired = ServiceDates.parse(cached.episode?.airDate).map { $0 < Date() } ?? false
      if !aired { return cached.episode }
    }
    guard let lookup = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdbId)") else { return nil }
    do {
      guard let show = try await tvMazeJSON(lookup) else {
        // 404: TVmaze does not know the show.
        await DiskCache.shared.set(cacheKey, TVMazeNext(episode: nil), ttl: 24 * 3600)
        return nil
      }
      var next: TMDBEpisodeRef?
      if let href = show.dict("_links")?.dict("nextepisode")?.string("href"), let nextURL = URL(string: href),
         let episode = try await tvMazeJSON(nextURL) {
        next = TMDBEpisodeRef(airDate: episode.string("airdate"), episodeNumber: episode.int("number"), seasonNumber: episode.int("season"), name: episode.string("name"), still: nil, overview: episode.string("summary"))
      }
      await DiskCache.shared.set(cacheKey, TVMazeNext(episode: next), ttl: 6 * 3600)
      return next
    } catch {
      return await DiskCache.shared.get(cacheKey, as: TVMazeNext.self, allowExpired: true)?.episode
    }
  }

  /// One TVmaze request: nil on 404, waits and retries on 429 (Retry-After), throws on other failures.
  private func tvMazeJSON(_ url: URL) async throws -> [String: Any]? {
    var attempt = 0
    while true {
      attempt += 1
      await tvMazeLimiter.acquire()
      let (data, response) = try await HTTP.data(url, timeout: 20, allowErrorStatus: true)
      if response.statusCode == 429 && attempt < 4 {
        let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
        await tvMazeLimiter.pause(for: retry + 1)
        continue
      }
      if response.statusCode == 404 { return nil }
      guard (200..<300).contains(response.statusCode), let json = ServiceJSON.object(data) else {
        throw HTTPError.status(response.statusCode, url)
      }
      return json
    }
  }

  /// "Western - Recent TV Episodes" feed (getMediaForRSS): next or last episode of the shows on the air.
  func recentEpisodes(page: Int = 1, perPage: Int = 50) async -> [EpisodeFeedItem] {
    let onTheAir = await self.schedule(page: page)
    let items: [EpisodeFeedItem] = onTheAir.entries.compactMap { entry in
      guard let episode = entry.nextEpisode ?? entry.lastEpisode, let number = episode.episodeNumber else { return nil }
      let date = ServiceDates.parse(episode.airDate) ?? entry.airing.airingAt
      return EpisodeFeedItem(media: entry.media, episode: number, date: date, dub: false, episodeTitle: episode.name, thumbnail: episode.still ?? entry.media.images.banner, summary: episode.overview)
    }
    return Array(items.prefix(perPage))
  }

  // MARK: - Artwork injection (injectMediaImages / injectTmdbImages)

  /// Replaces banners with TMDB backdrops and adds TMDB logos (AniList media through animap).
  func injectImages(_ media: [Media]) async -> [Media] {
    if media.isEmpty { return media }
    let index = await AnimeMappingsService.shared.animapIndex()
    let updated: [Media] = await withTaskGroup(of: (Int, Media).self) { group in
      for (offset, item) in media.enumerated() {
        let entry: AnimapEntry? = item.anilistId.flatMap { index.byAnilist[String($0)] }
        group.addTask {
          (offset, await self.injectImage(item, mapping: entry))
        }
      }
      var collected: [(Int, Media)] = []
      for await pair in group { collected.append(pair) }
      return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
    return MediaStore.shared.ingest(updated)
  }

  private func injectImage(_ media: Media, mapping: AnimapEntry?) async -> Media {
    var candidateId: Int?
    var type: TMDBType = .tv
    if media.source == .tmdb {
      candidateId = media.tmdbId
      type = media.tmdbType ?? (media.format == .movie ? .movie : .tv)
    } else if let mapping {
      candidateId = mapping.tmdbId
      type = mapping.isMovie ? .movie : .tv
      if candidateId == nil, let tvdb = mapping.tvdbId, let found = await find(externalId: String(tvdb), source: "tvdb_id") {
        candidateId = found.id
        type = found.type
        AnimeMappingsService.shared.rememberTmdbId(anilistId: mapping.anilistId, tmdbId: found.id, type: found.type)
      }
    } else if let id = media.tmdbId {
      candidateId = id
      type = media.tmdbType ?? .tv
    }
    guard let tmdbId = candidateId else { return media }
    let cacheKey = "tmdb.artwork.\(type.rawValue).\(tmdbId)"
    var artwork = await DiskCache.shared.get(cacheKey, as: TMDBArtwork.self, allowExpired: !ServiceNetworkMonitor.shared.isOnline)
    if artwork == nil, let data = try? await get("/\(type.rawValue)/\(tmdbId)", params: ["append_to_response": "images", "include_image_language": "en,null,ja"]) {
      let fetched = TMDBArtwork(backdrop: Self.image(data.string("backdrop_path"), size: "w1280"), logo: Self.logo(from: data.dict("images")))
      await DiskCache.shared.set(cacheKey, fetched, ttl: 30 * 24 * 3600)
      artwork = fetched
    }
    var result = media
    if media.source == .anilist {
      result.tmdbId = result.tmdbId ?? tmdbId
      result.tmdbType = result.tmdbType ?? type
    }
    if let backdrop = artwork?.backdrop { result.images.banner = backdrop }
    if let logo = artwork?.logo { result.images.logo = logo }
    return result
  }
}
