import Foundation

// Port of the mapping / metadata parts of common/modules/tmdb.js (fetchAnimeMap: animap anime <-> TMDB/TVDB),
// common/modules/anime/anime.js (getAniMappings: api.ani.zip, getKitsuMappings, getEpisodeMetadataForMedia)
// and common/modules/episodes.js (Jikan episodes / fillers, Kitsu episodes, Jikan media for trailers).

/// animap entry for one AniList media.
struct AnimapEntry: Codable, Hashable {
  var anilistId: Int
  var malId: Int?
  var tmdbId: Int?
  var tmdbType: TMDBType?
  /// animap media_type (TV, MOVIE, OVA...).
  var mediaType: String?
  var tvdbId: Int?
  var tvdbSeason: Int?
  var tvdbEpoffset: Int?
  var tmdbSeason: Int?
  var imdbId: String?
  var animePlanetId: String?

  var isMovie: Bool { tmdbType == .movie || mediaType?.uppercased() == "MOVIE" }
}

struct AnimapIndex: Codable {
  var byAnilist: [String: AnimapEntry] = [:]
  /// "tv-123" / "movie-456" -> AniList id.
  var tmdbToAnilist: [String: Int] = [:]
}

/// ani.zip episode (also used for converted Kitsu episodes, kitsuToAniEpisodes).
struct AniZipEpisode: Codable, Hashable {
  var title: [String: String] = [:]
  var episode: String?
  var episodeNumber: Int?
  var absoluteEpisodeNumber: Int?
  var seasonNumber: Int?
  var airDate: String?
  var airDateUtc: String?
  var airdate: String?
  var runtime: Int?
  var length: Int?
  var overview: String?
  var summary: String?
  var image: String?
  var rating: String?
  var airedBeforeEpisodeNumber: Int?
  var tvdbId: Int?
  var kitsuId: String?

  init() {}

  private enum CodingKeys: String, CodingKey {
    case title, episode, episodeNumber, absoluteEpisodeNumber, seasonNumber, airDate, airDateUtc, airdate, runtime
    case length, overview, summary, image, rating, airedBeforeEpisodeNumber, tvdbId, kitsuId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let titles = try? container.decodeIfPresent([String: String?].self, forKey: .title) {
      title = titles.compactMapValues { $0 }
    }
    episode = container.svcLossyString(.episode)
    episodeNumber = container.svcLossyInt(.episodeNumber)
    absoluteEpisodeNumber = container.svcLossyInt(.absoluteEpisodeNumber)
    seasonNumber = container.svcLossyInt(.seasonNumber)
    airDate = container.svcLossyString(.airDate)
    airDateUtc = container.svcLossyString(.airDateUtc)
    airdate = container.svcLossyString(.airdate)
    runtime = container.svcLossyInt(.runtime)
    length = container.svcLossyInt(.length)
    overview = container.svcLossyString(.overview)
    summary = container.svcLossyString(.summary)
    image = container.svcLossyString(.image)
    rating = container.svcLossyString(.rating)
    airedBeforeEpisodeNumber = container.svcLossyInt(.airedBeforeEpisodeNumber)
    tvdbId = container.svcLossyInt(.tvdbId)
    kitsuId = container.svcLossyString(.kitsuId)
  }
}

struct AniZipImage: Codable, Hashable {
  var coverType: String?
  var url: String?
}

/// ani.zip `mappings` object (external ids).
struct AniZipIds: Codable, Hashable {
  var anilistId: Int?
  var malId: Int?
  var kitsuId: Int?
  var anidbId: Int?
  var tvdbId: Int?
  var tmdbId: Int?
  var imdbId: String?
  var animePlanetId: String?
  var type: String?

  init() {}

  private enum CodingKeys: String, CodingKey {
    case anilistId = "anilist_id"
    case malId = "mal_id"
    case kitsuId = "kitsu_id"
    case anidbId = "anidb_id"
    case tvdbId = "thetvdb_id"
    case tmdbId = "themoviedb_id"
    case imdbId = "imdb_id"
    case animePlanetId = "animeplanet_id"
    case type
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    anilistId = container.svcLossyInt(.anilistId)
    malId = container.svcLossyInt(.malId)
    kitsuId = container.svcLossyInt(.kitsuId)
    anidbId = container.svcLossyInt(.anidbId)
    tvdbId = container.svcLossyInt(.tvdbId)
    tmdbId = container.svcLossyInt(.tmdbId)
    imdbId = container.svcLossyString(.imdbId)
    animePlanetId = container.svcLossyString(.animePlanetId)
    type = container.svcLossyString(.type)
  }
}

/// api.ani.zip/mappings response.
struct AniZipMappings: Codable, Hashable {
  var titles: [String: String] = [:]
  var episodes: [String: AniZipEpisode] = [:]
  var episodeCount: Int?
  var specialCount: Int?
  var images: [AniZipImage] = []
  var mappings: AniZipIds?

  init() {}

  private enum CodingKeys: String, CodingKey {
    case titles, episodes, episodeCount, specialCount, images, mappings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let values = try? container.decodeIfPresent([String: String?].self, forKey: .titles) {
      titles = values.compactMapValues { $0 }
    }
    episodes = (try? container.decodeIfPresent([String: AniZipEpisode].self, forKey: .episodes)) ?? [:]
    episodeCount = container.svcLossyInt(.episodeCount)
    specialCount = container.svcLossyInt(.specialCount)
    images = (try? container.decodeIfPresent([AniZipImage].self, forKey: .images)) ?? []
    mappings = try? container.decodeIfPresent(AniZipIds.self, forKey: .mappings)
  }
}

/// Kitsu episode attributes (episodes.js getKitsuEpisodes).
struct KitsuEpisode: Codable, Hashable {
  var id: String?
  var number: Int
  var seasonNumber: Int?
  var canonicalTitle: String?
  var titles: [String: String]
  var airdate: String?
  var length: Int?
  var synopsis: String?
  var description: String?
  var thumbnail: String?
}

/// Jikan episode (getEpisodeData / getSingleEpisode).
struct JikanEpisode: Codable, Hashable {
  var malId: Int
  var title: String?
  var aired: String?
  var filler: Bool
  var recap: Bool
}

struct JikanEpisodePage: Codable {
  var episodes: [JikanEpisode]
  var lastVisiblePage: Int?
  var hasNextPage: Bool
}

final class AnimeMappingsService: @unchecked Sendable {
  static let shared = AnimeMappingsService()

  private let animap = ServiceLocked<AnimapIndex?>(nil)
  private let animapTask = ServiceLocked<Task<AnimapIndex, Never>?>(nil)
  private let aniZipLimiter = ServiceRateLimiter(capacity: 200, interval: 30, minSpacing: 0.08)
  private let episodesLimiter = ServiceRateLimiter(capacity: 60, interval: 60, minSpacing: 0.333)
  private let inflight = ServiceInflight()
  private let metadata = ServiceLocked<[Int: [String: AniZipEpisode]]>([:])
  /// Jikan episode pages kept in memory for the session ("malId.page"), so an episode list reads each page once.
  private let jikanMemory = ServiceLocked<[String: JikanEpisodePage]>([:])
  /// Jikan pages that failed recently ("malId.page" -> time): not requested again for 10 minutes.
  private let jikanFailures = ServiceLocked<[String: Date]>([:])

  private init() {}

  // MARK: - animap (fetchAnimeMap)

  /// Loads (once) the animap AniList <-> TMDB/TVDB index, cached for a day.
  func animapIndex() async -> AnimapIndex {
    if let loaded = animap.get() { return loaded }
    let task: Task<AnimapIndex, Never> = animapTask.update { slot in
      if let existing = slot { return existing }
      let created = Task<AnimapIndex, Never> { await AnimeMappingsService.fetchAnimap() }
      slot = created
      return created
    }
    let index = await task.value
    if index.byAnilist.isEmpty {
      animapTask.set(nil)
    } else {
      animap.set(index)
    }
    return index
  }

  private static func fetchAnimap() async -> AnimapIndex {
    let cacheKey = "animap.index.v1"
    if let cached = await DiskCache.shared.get(cacheKey, as: AnimapIndex.self) { return cached }
    do {
      guard let url = URL(string: "https://animap.s0n1c.ca/mappings/all") else { throw ServiceError.invalidResponse }
      let (data, _) = try await HTTP.data(url, timeout: 120)
      let json = try JSONSerialization.jsonObject(with: data)
      var entries: [[String: Any]] = []
      if let array = json as? [[String: Any]] {
        entries = array
      } else if let dict = json as? [String: Any] {
        entries = dict.values.compactMap { $0 as? [String: Any] }
      }
      var index = AnimapIndex()
      for item in entries {
        guard let anilistId = item.int("anilist_id") else { continue }
        let movieId = item.int("tmdb_movie_id")
        let showId = item.int("tmdb_show_id")
        let tmdbId = movieId ?? showId
        let tmdbType: TMDBType? = tmdbId == nil ? nil : (movieId != nil ? .movie : .tv)
        if let tmdbId, let tmdbType {
          index.tmdbToAnilist["\(tmdbType.rawValue)-\(tmdbId)"] = anilistId
        }
        let entry = AnimapEntry(anilistId: anilistId, malId: item.int("mal_id"), tmdbId: tmdbId, tmdbType: tmdbType, mediaType: item.string("media_type") ?? (movieId != nil ? "MOVIE" : "TV"), tvdbId: item.int("tvdb_id"), tvdbSeason: item.int("tvdb_season"), tvdbEpoffset: item.int("tvdb_epoffset"), tmdbSeason: item.int("tmdb_season"), imdbId: item.string("imdb_id"), animePlanetId: item.string("animeplanet_id"))
        index.byAnilist[String(anilistId)] = entry
      }
      if !index.byAnilist.isEmpty {
        await DiskCache.shared.set(cacheKey, index, ttl: 24 * 3600)
      }
      return index
    } catch {
      if let stale = await DiskCache.shared.get(cacheKey, as: AnimapIndex.self, allowExpired: true) { return stale }
      return AnimapIndex()
    }
  }

  /// anilistToTmdb[anilistId] (TMDB id, type, TVDB season / episode offset).
  func tmdbInfo(anilistId: Int) async -> AnimapEntry? {
    await animapIndex().byAnilist[String(anilistId)]
  }

  /// tmdbToAnilist["tv-123"].
  func anilistId(tmdbId: Int, type: TMDBType) async -> Int? {
    await animapIndex().tmdbToAnilist["\(type.rawValue)-\(tmdbId)"]
  }

  /// Non-blocking variants (nil until the index is loaded).
  func loadedTmdbInfo(anilistId: Int) -> AnimapEntry? {
    animap.get()?.byAnilist[String(anilistId)]
  }

  func loadedAnilistId(tmdbId: Int, type: TMDBType) -> Int? {
    animap.get()?.tmdbToAnilist["\(type.rawValue)-\(tmdbId)"]
  }

  /// Fills a cached TMDB id found through /find (injectMediaImages tvdb fallback).
  func rememberTmdbId(anilistId: Int, tmdbId: Int, type: TMDBType) {
    animap.update { index in
      guard var current = index, var entry = current.byAnilist[String(anilistId)] else { return }
      entry.tmdbId = tmdbId
      entry.tmdbType = type
      current.byAnilist[String(anilistId)] = entry
      index = current
    }
  }

  // MARK: - ani.zip (getAniMappings)

  /// Cache duration: 14-21 days for series finished more than a month ago (or started a year ago), else 60-90 minutes.
  private func mappingTTL(anilistId: Int) -> TimeInterval {
    let shortTTL = TimeInterval(Int.random(in: 60...90) * 60)
    let longTTL = TimeInterval(Int.random(in: 14...21) * 24 * 3600)
    guard let media = MediaStore.shared.anilist(anilistId), media.status == .finished else { return shortTTL }
    let extras = MediaStore.shared.extras(for: media)
    let calendar = Calendar.current
    let now = Date()
    let year = calendar.component(.year, from: now)
    let month = calendar.component(.month, from: now)
    if let end = extras.endDate, let endYear = end.year {
      guard let endMonth = end.month else { return shortTTL }
      return (year - endYear) * 12 + (month - endMonth) >= 1 ? longTTL : shortTTL
    }
    if let startYear = extras.startDate?.year ?? media.seasonYear, year - startYear >= 1 { return longTTL }
    return shortTTL
  }

  func aniZip(anilistId: Int) async -> AniZipMappings? {
    let cacheKey = "anizip.\(anilistId)"
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: AniZipMappings.self, allowExpired: !online) { return cached }
    if !online { return nil }
    do {
      let mappings: AniZipMappings = try await inflight.run(cacheKey) {
        guard let url = URL(string: "https://api.ani.zip/mappings?anilist_id=\(anilistId)") else { throw ServiceError.invalidResponse }
        var attempt = 0
        while true {
          attempt += 1
          await self.aniZipLimiter.acquire()
          let (data, response) = try await HTTP.data(url, timeout: 30, allowErrorStatus: true)
          if (response.statusCode == 429 || response.statusCode == 500) && attempt < 4 {
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
            await self.aniZipLimiter.pause(for: response.statusCode == 500 ? 1 : retry + 1)
            continue
          }
          guard (200..<300).contains(response.statusCode) else { throw HTTPError.status(response.statusCode, url) }
          return try JSONDecoder().decode(AniZipMappings.self, from: data)
        }
      }
      await DiskCache.shared.set(cacheKey, mappings, ttl: mappingTTL(anilistId: anilistId))
      return mappings
    } catch {
      return await DiskCache.shared.get(cacheKey, as: AniZipMappings.self, allowExpired: true)
    }
  }

  // MARK: - Kitsu (getKitsuMappings / getKitsuEpisodes)

  func kitsuId(anilistId: Int) async -> String? {
    let cacheKey = "kitsu.mapping.\(anilistId)"
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: String.self, allowExpired: !online) { return cached.isEmpty ? nil : cached }
    if !online { return nil }
    do {
      guard let url = URL(string: "https://kitsu.app/api/edge/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D=\(anilistId)&include=item") else { return nil }
      let json = try await HTTP.jsonObject(from: url) as? [String: Any]
      let included = json?.array("included").first?.string("id")
      let related = json?.array("data").first?.dict("relationships")?.dict("item")?.dict("data")?.string("id")
      let id = included ?? related ?? ""
      await DiskCache.shared.set(cacheKey, id, ttl: mappingTTL(anilistId: anilistId))
      return id.isEmpty ? nil : id
    } catch {
      let stale = await DiskCache.shared.get(cacheKey, as: String.self, allowExpired: true)
      return (stale?.isEmpty ?? true) ? nil : stale
    }
  }

  /// First page of Kitsu episodes of an AniList media (same request as episodes.js).
  func kitsuEpisodes(anilistId: Int) async -> [KitsuEpisode] {
    guard let kitsuIdentifier = await self.kitsuId(anilistId: anilistId) else { return [] }
    let cacheKey = "kitsu.episodes.\(kitsuIdentifier)"
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: [KitsuEpisode].self, allowExpired: !online) { return cached }
    if !online { return [] }
    do {
      guard let url = URL(string: "https://kitsu.app/api/edge/anime/\(kitsuIdentifier)/episodes") else { return [] }
      await episodesLimiter.acquire()
      let json = try await HTTP.jsonObject(from: url) as? [String: Any]
      let episodes: [KitsuEpisode] = (json?.array("data") ?? []).compactMap { item in
        guard let attributes = item.dict("attributes"), let number = attributes.int("number") else { return nil }
        var titles: [String: String] = [:]
        for (key, value) in attributes.dict("titles") ?? [:] {
          if let text = value as? String { titles[key] = text }
        }
        let thumbnail = attributes.dict("thumbnail")
        return KitsuEpisode(id: item.string("id"), number: number, seasonNumber: attributes.int("seasonNumber"), canonicalTitle: attributes.string("canonicalTitle"), titles: titles, airdate: attributes.string("airdate"), length: attributes.int("length"), synopsis: attributes.string("synopsis"), description: attributes.string("description"), thumbnail: thumbnail?.string("original") ?? thumbnail?.string("large"))
      }
      await DiskCache.shared.set(cacheKey, episodes, ttl: TimeInterval(Int.random(in: 1...3) * 24 * 3600))
      return episodes
    } catch {
      return await DiskCache.shared.get(cacheKey, as: [KitsuEpisode].self, allowExpired: true) ?? []
    }
  }

  // MARK: - Episode metadata (getEpisodeMetadataForMedia)

  /// ani.zip episodes, or Kitsu episodes converted to the same shape (keyed by episode number).
  func episodeMetadata(for media: Media) async -> [String: AniZipEpisode] {
    guard let anilistId = media.anilistId else { return [:] }
    if let cached = metadata.get()[anilistId] { return cached }
    var result: [String: AniZipEpisode] = [:]
    if let mappings = await aniZip(anilistId: anilistId), !mappings.episodes.isEmpty {
      result = mappings.episodes
    } else {
      for episode in await kitsuEpisodes(anilistId: anilistId) {
        var converted = AniZipEpisode()
        converted.episode = String(episode.number)
        converted.seasonNumber = episode.seasonNumber ?? 1
        converted.episodeNumber = episode.number
        converted.absoluteEpisodeNumber = episode.number
        var titles: [String: String] = [:]
        if let english = episode.canonicalTitle ?? episode.titles["en"] { titles["en"] = english }
        if let japanese = episode.titles["ja"] { titles["ja"] = japanese }
        if let romaji = episode.titles["x-jat"] ?? episode.titles["ja_jp"] { titles["x-jat"] = romaji }
        converted.title = titles
        converted.airDate = episode.airdate
        converted.airdate = episode.airdate
        converted.length = episode.length
        converted.runtime = episode.length
        converted.overview = episode.synopsis ?? episode.description
        converted.summary = episode.description ?? episode.synopsis
        converted.image = episode.thumbnail
        converted.kitsuId = episode.id
        result[String(episode.number)] = converted
      }
    }
    let stored = result
    metadata.update { $0[anilistId] = stored }
    return result
  }

  // MARK: - Jikan (episodes.js)

  private func jikanPage(malId: Int, page: Int) async -> JikanEpisodePage? {
    let cacheKey = "jikan.episodes.\(malId).\(page)"
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: JikanEpisodePage.self, allowExpired: !online) { return cached }
    if !online { return nil }
    do {
      let result: JikanEpisodePage = try await inflight.run(cacheKey) {
        guard let url = URL(string: "https://api.jikan.moe/v4/anime/\(malId)/episodes?page=\(page)") else { throw ServiceError.invalidResponse }
        var attempt = 0
        while true {
          attempt += 1
          await self.episodesLimiter.acquire()
          let (data, response) = try await HTTP.data(url, timeout: 30, allowErrorStatus: true)
          if (response.statusCode == 429 || response.statusCode == 500) && attempt < 4 {
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            await self.episodesLimiter.pause(for: response.statusCode == 500 ? 1 : retry + 1)
            continue
          }
          guard (200..<300).contains(response.statusCode), let json = ServiceJSON.object(data) else {
            throw HTTPError.status(response.statusCode, url)
          }
          let episodes = json.array("data").compactMap { item -> JikanEpisode? in
            guard let id = item.int("mal_id") else { return nil }
            return JikanEpisode(malId: id, title: item.string("title") ?? item.string("title_romanji") ?? item.string("title_japanese"), aired: item.string("aired"), filler: item.bool("filler") ?? false, recap: item.bool("recap") ?? false)
          }
          let pagination = json.dict("pagination")
          return JikanEpisodePage(episodes: episodes, lastVisiblePage: pagination?.int("last_visible_page"), hasNextPage: pagination?.bool("has_next_page") ?? false)
        }
      }
      await DiskCache.shared.set(cacheKey, result, ttl: TimeInterval(Int.random(in: 1...3) * 24 * 3600))
      return result
    } catch {
      return await DiskCache.shared.get(cacheKey, as: JikanEpisodePage.self, allowExpired: true)
    }
  }

  /// One Jikan page through the session memory: a page is decoded / requested once, and a failed page is
  /// not requested again for 10 minutes.
  private func sessionJikanPage(malId: Int, page: Int) async -> JikanEpisodePage? {
    let key = "\(malId).\(page)"
    if let cached = jikanMemory.get()[key] { return cached }
    if let failed = jikanFailures.get()[key], Date().timeIntervalSince(failed) < 600 { return nil }
    guard let result = await jikanPage(malId: malId, page: page) else {
      jikanFailures.update { $0[key] = Date() }
      return nil
    }
    jikanMemory.update { $0[key] = result }
    return result
  }

  /// Episodes of one Jikan page (100 episodes per page), nil when the page could not be loaded.
  func jikanEpisodePage(malId: Int, page: Int) async -> [JikanEpisode]? {
    await sessionJikanPage(malId: malId, page: max(page, 1))?.episodes
  }

  /// Jikan page holding an episode (getSingleEpisode: episode 0 is looked up on page 1).
  static func jikanPageNumber(episode: Int) -> Int {
    let number = episode == 0 ? 1 : max(episode, 1)
    return max((number + 99) / 100, 1)
  }

  /// getEpisodeData: episodes of the first page, or of the last page when there are several (as the Svelte app).
  func jikanEpisodes(malId: Int?) async -> [JikanEpisode] {
    guard let malId else { return [] }
    guard let first = await sessionJikanPage(malId: malId, page: 1) else { return [] }
    if first.hasNextPage, let last = first.lastVisiblePage, last > 1 {
      return await sessionJikanPage(malId: malId, page: last)?.episodes ?? []
    }
    return first.episodes
  }

  /// getSingleEpisode: one episode (title, aired date, filler / recap flags).
  func jikanEpisode(malId: Int?, episode: Int) async -> JikanEpisode? {
    guard let malId else { return nil }
    return await sessionJikanPage(malId: malId, page: Self.jikanPageNumber(episode: episode))?.episodes.first { $0.malId == episode }
  }

  /// getMedia: Jikan anime root, used for the YouTube trailer fallback (TrailerModal / PreviewCard).
  func jikanTrailer(malId: Int?) async -> String? {
    guard let malId else { return nil }
    let cacheKey = "jikan.anime.trailer.\(malId)"
    if let cached = await DiskCache.shared.get(cacheKey, as: String.self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) {
      return cached.isEmpty ? nil : cached
    }
    guard let url = URL(string: "https://api.jikan.moe/v4/anime/\(malId)") else { return nil }
    await episodesLimiter.acquire()
    guard let json = (try? await HTTP.jsonObject(from: url)) as? [String: Any] else { return nil }
    let trailer = json.dict("data")?.dict("trailer")?.string("youtube_id") ?? ""
    await DiskCache.shared.set(cacheKey, trailer, ttl: TimeInterval(Int.random(in: 1...3) * 24 * 3600))
    return trailer.isEmpty ? nil : trailer
  }

  /// episodes.js handleArray: "1 ~ 3" / "01-03" batch ranges.
  static func episodeRange(_ text: String?) -> (first: Int, last: Int)? {
    guard let text, let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*[-~]\\s*(\\d+)") else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let firstRange = Range(match.range(at: 1), in: text),
          let lastRange = Range(match.range(at: 2), in: text),
          let first = Int(text[firstRange]), let last = Int(text[lastRange]), first < last else { return nil }
    return (first, last)
  }
}
