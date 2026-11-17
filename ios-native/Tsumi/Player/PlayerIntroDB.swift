import Foundation

// TheIntroDB (https://theintrodb.org): community skip times (intro, recap, credits, preview) for shows, movies and
// anime, keyed by TVDB. Port of common/modules/introdb (core.js + index.js).
//
// API (public, no key, https://theintrodb.org/openapi.yaml): GET /v4/media?tmdb_id=<id>[&season=<s>&episode=<e>]
// or ?tvdb_id=<id>&season=<s>&episode=<e>[&tvdb_episode_id=<id>], optional duration_ms to pick the release version.
// -> { tvdb_id, type: "tv" | "movie", intro?: [{ start_ms, end_ms }], recap?, credits?, preview? }
// start_ms null = start of the video, end_ms null = end of the video. 404 = nothing submitted (or unknown media).
// TMDB numbering is converted by the server; TVDB numbering is its own.
enum PlayerIntroDB {
  static let api = "https://api.theintrodb.org/v4"
  /// Segment types of the answer and the chapter names the player recognises as skippable.
  static let segments: [(key: String, name: String)] = [
    ("intro", "Intro"), ("recap", "Recap"), ("credits", "Credits"), ("preview", "Preview")
  ]
  /// Shortest segment kept, in milliseconds (the API stores "no recap" as a 0 to 0 segment).
  private static let minSegmentMs: Double = 1000

  struct Query: Hashable, Sendable {
    var tmdb: Int?
    var tvdb: Int?
    var season: Int?
    var episode: Int?
    var tvdbEpisode: Int?
  }

  /// Answers kept for the session per request URL (nil data: nothing submitted for it).
  private actor Answers {
    private var answers: [URL: Data?] = [:]
    private var order: [URL] = []

    func answer(for url: URL) -> Data?? {
      answers.keys.contains(url) ? .some(answers[url] ?? nil) : nil
    }

    func store(_ data: Data?, for url: URL) {
      if !answers.keys.contains(url) { order.append(url) }
      answers[url] = .some(data)
      if order.count > 50 { answers[order.removeFirst()] = nil }
    }
  }

  private static let cache = Answers()

  // MARK: - Lookup

  /// Chapters of an episode (or movie), [] when TheIntroDB has nothing for it or cannot be reached.
  static func chapters(media: Media, episode: EpisodeRef, duration: Double) async -> [PlayerChapter] {
    guard duration > 0, duration.isFinite,
          let query = await query(media: media, episode: episode),
          let url = url(query, duration: duration) else { return [] }
    if let cached = await cache.answer(for: url) {
      guard let data = cached else { return [] }
      return chapters(from: data, duration: duration)
    }
    guard let result = try? await HTTP.data(url, timeout: 15, allowErrorStatus: true) else { return [] }
    let (data, response) = result
    // 404: nothing submitted for this episode yet (or unknown media); 429: rate limited, asked again next time.
    if response.statusCode == 404 {
      await cache.store(nil, for: url)
      return []
    }
    guard (200..<300).contains(response.statusCode) else { return [] }
    await cache.store(data, for: url)
    return chapters(from: data, duration: duration)
  }

  /// introDbQuery: TMDB id for TMDB movies, TMDB id with the season / episode for TMDB shows (from the episode,
  /// else from the absolute number and the TMDB seasons), ani.zip TVDB numbering for anime. nil when the episode
  /// cannot be placed (better no chapters than the skip times of another episode), episode 0 included
  /// (`tmdbSeasonEpisode` gives nil for 0).
  static func query(media: Media, episode: EpisodeRef) async -> Query? {
    // Episode 0 (a prologue) stays 0: no skip times rather than episode 1's (negative numbers count as 1, like PC).
    let number = episode.number < 0 ? 1 : episode.number
    if media.source == .tmdb {
      guard let tmdb = media.tmdbId, tmdb > 0 else { return nil }
      if media.isMovie { return Query(tmdb: tmdb) }
      if let season = episode.season, let local = episode.localEpisode, season > 0, local > 0 {
        return Query(tmdb: tmdb, season: season, episode: local)
      }
      guard let details = await TMDBService.shared.details(id: tmdb, type: .tv),
            let mapped = OnlineSubtitlesService.tmdbSeasonEpisode(details.seasons, absolute: number) else { return nil }
      return Query(tmdb: tmdb, season: mapped.season, episode: mapped.episode)
    }
    guard let anilistId = media.anilistId,
          let aniZip = await AnimeMappingsService.shared.aniZip(anilistId: anilistId) else { return nil }
    return animeQuery(aniZip, episode: number, isMovie: media.format == .movie)
  }

  // MARK: - Pure helpers (same as core.js)

  private static func positive(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return value
  }

  /// animeQuery: TVDB show, season and episode numbers of the episode in ani.zip (and its TVDB episode id);
  /// movies use the TMDB id.
  static func animeQuery(_ aniZip: AniZipMappings, episode: Int, isMovie: Bool) -> Query? {
    let ids = aniZip.mappings
    if isMovie || (ids?.type ?? "").uppercased() == "MOVIE" {
      guard let tmdb = positive(ids?.tmdbId) else { return nil }
      return Query(tmdb: tmdb)
    }
    // Episode 0 stays 0: ani.zip has no "0" entry for most shows, so no skip times rather than episode 1's.
    let entry = aniZip.episodes[String(episode < 0 ? 1 : episode)]
    guard let tvdb = positive(entry?.tvdbShowId) ?? positive(ids?.tvdbId),
          let season = entry?.seasonNumber, season >= 0,
          let number = positive(entry?.episodeNumber) else { return nil }
    return Query(tvdb: tvdb, season: season, episode: number, tvdbEpisode: positive(entry?.tvdbId))
  }

  /// introDbUrl: request of a movie ({ tmdb }) or an episode ({ tmdb | tvdb, season, episode, tvdbEpisode? }),
  /// with the video length to pick the closest release version.
  static func url(_ query: Query, duration: Double?) -> URL? {
    var items: [URLQueryItem] = []
    if let tvdb = positive(query.tvdb) {
      items.append(URLQueryItem(name: "tvdb_id", value: String(tvdb)))
    } else if let tmdb = positive(query.tmdb) {
      items.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
    } else {
      return nil
    }
    if query.season != nil || query.episode != nil {
      guard let season = query.season, season >= 0, let episode = positive(query.episode) else { return nil }
      items.append(URLQueryItem(name: "season", value: String(season)))
      items.append(URLQueryItem(name: "episode", value: String(episode)))
      if positive(query.tvdb) != nil, let tvdbEpisode = positive(query.tvdbEpisode) {
        items.append(URLQueryItem(name: "tvdb_episode_id", value: String(tvdbEpisode)))
      }
    }
    if let duration, duration.isFinite {
      let ms = Int((duration * 1000).rounded())
      if ms > 0 { items.append(URLQueryItem(name: "duration_ms", value: String(ms))) }
    }
    var components = URLComponents(string: "\(api)/media")
    components?.queryItems = items
    return components?.url
  }

  static func chapters(from data: Data, duration: Double) -> [PlayerChapter] {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
    return chapters(json: json, duration: duration)
  }

  /// A millisecond value of the answer: null / missing -> `fallback`, numbers and numeric strings as they are.
  private static func milliseconds(_ value: Any?, fallback: Double) -> Double? {
    switch value {
    case nil, is NSNull: return fallback
    case let number as NSNumber: return number.doubleValue
    case let text as String: return Double(text)
    default: return nil
    }
  }

  /// introDbChapters: chapters covering the whole video. Segments are clamped to the video, overlaps are cut (the
  /// earlier segment wins) and the gaps become "Episode" (or "Movie") chapters. Segment chapters are `trusted`:
  /// they are meant for skipping, so the player allows long ones (movie credits). [] without a usable segment.
  static func chapters(json: [String: Any], duration: Double) -> [PlayerChapter] {
    guard duration.isFinite else { return [] }
    let total = (duration * 1000).rounded()
    guard total > 0 else { return [] }
    var found: [(start: Double, end: Double, name: String, index: Int)] = []
    for (key, name) in segments {
      for case let segment as [String: Any] in (json[key] as? [Any]) ?? [] {
        guard let start = milliseconds(segment["start_ms"], fallback: 0),
              let end = milliseconds(segment["end_ms"], fallback: total),
              start.isFinite, end.isFinite else { continue }
        let from = max(0, min(start, total))
        let to = max(0, min(end, total))
        if to - from >= minSegmentMs { found.append((from, to, name, found.count)) }
      }
    }
    found.sort { a, b in
      if a.start != b.start { return a.start < b.start }
      if a.end != b.end { return a.end > b.end }
      return a.index < b.index
    }
    var kept: [(start: Double, end: Double, name: String)] = []
    for segment in found {
      var start = segment.start
      if let previous = kept.last, start < previous.end {
        if segment.end - previous.end < minSegmentMs { continue }
        start = previous.end
      }
      kept.append((start, segment.end, segment.name))
    }
    guard !kept.isEmpty else { return [] }
    let filler = (json["type"] as? String) == "movie" ? "Movie" : "Episode"
    var result: [(start: Double, end: Double, name: String, trusted: Bool)] = []
    var cursor: Double = 0
    for segment in kept {
      var start = segment.start
      if start - cursor >= minSegmentMs {
        result.append((cursor, start, filler, false))
      } else {
        start = cursor
      }
      result.append((start, segment.end, segment.name, true))
      cursor = segment.end
    }
    if total - cursor >= minSegmentMs {
      result.append((cursor, total, filler, false))
    } else {
      result[result.count - 1].end = total
    }
    return result.map { PlayerChapter(start: $0.start / 1000, end: $0.end / 1000, text: $0.name, trusted: $0.trusted) }
  }
}
