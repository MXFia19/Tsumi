import Foundation

// Data part of common/modals/details/DetailsModal.svelte (relations + recommendations resolved through
// searchAllIDS, TMDB enrichment, recommendations / collection relations of western titles, favourite,
// reviews, following) and of components/EpisodeList.svelte (load / loadTmdbEpisodes: the episode list built
// from ani.zip, the AniList airing schedule, Jikan, Kitsu, streaming episodes and zero episodes), plus the
// trailer fallback of TrailerModal.svelte / PreviewCard.svelte (Jikan / TMDB).

final class MediaDetailsService: @unchecked Sendable {
  static let shared = MediaDetailsService()

  private init() {}

  // MARK: - Details

  /// Full media for the details screen: fresh data, relations and recommendations as media.
  func details(for media: Media) async -> Media {
    if media.source == .tmdb {
      return await tmdbDetails(media)
    }
    guard let anilistId = media.anilistId else { return media }
    let fresh = (try? await AniListService.shared.media(id: anilistId)) ?? MediaStore.shared.media(media.id) ?? media
    let extras = MediaStore.shared.extras(for: fresh)
    let relationEdges = extras.relationEdges.filter { ($0.type ?? "ANIME") == "ANIME" }
    let recommendationIds = (try? await AniListService.shared.recommendationIds(id: anilistId)) ?? extras.recommendationIds
    let ids = Array(NSOrderedSet(array: relationEdges.map { $0.id } + recommendationIds).compactMap { $0 as? Int })
    var result = fresh
    if !ids.isEmpty {
      var variables = AniListVariables()
      variables.sort = nil
      variables.id = ids
      let related = (try? await AniListService.shared.searchAllIDs(variables)) ?? []
      var byId: [Int: Media] = [:]
      for item in related {
        if let id = item.anilistId { byId[id] = item }
      }
      result.relations = relationEdges.compactMap { edge in
        byId[edge.id].map { MediaRelation(relationType: edge.relationType, media: $0) }
      }
      result.recommendations = recommendationIds.compactMap { byId[$0] }
    }
    let injected = await TMDBService.shared.injectImages([result])
    if var withArtwork = injected.first {
      withArtwork.relations = result.relations
      withArtwork.recommendations = result.recommendations
      result = withArtwork
    }
    return MediaStore.shared.ingest([result]).first ?? result
  }

  private func tmdbDetails(_ media: Media) async -> Media {
    guard let id = media.tmdbId else { return media }
    let type = media.tmdbType ?? (media.format == .movie ? .movie : .tv)
    var result = MediaStore.shared.media(media.id) ?? media
    var extras = MediaStore.shared.extras(for: result)
    if let details = await TMDBService.shared.details(id: id, type: type) {
      let enriched = TMDBService.shared.apply(details, to: result)
      result = enriched.media
      extras = enriched.extras
    }
    result.recommendations = await TMDBService.shared.recommendations(id: id, type: type)
    result.relations = await TMDBService.shared.relations(id: id, type: type)
    return MediaStore.shared.ingest([result], extras: [result.id: extras]).first ?? result
  }

  /// Friends who have the media on their list (Following.svelte, AniList only).
  func following(for media: Media) async -> [AniListFollowingEntry] {
    guard let id = media.anilistId, media.source == .anilist else { return [] }
    return (try? await AniListService.shared.following(mediaId: id)) ?? []
  }

  /// YouTube trailer id: AniList trailer, Jikan fallback (anime) or TMDB videos (western).
  func trailer(for media: Media) async -> String? {
    if let trailer = media.trailerYouTubeId { return trailer }
    if media.source == .tmdb { return await TMDBService.shared.trailer(for: media) }
    return await AnimeMappingsService.shared.jikanTrailer(malId: media.malId)
  }

  @discardableResult
  func toggleFavourite(_ media: Media) -> Bool {
    guard let id = media.anilistId, media.source == .anilist else { return false }
    return AniListService.shared.toggleFavourite(id: id)
  }

  func isFavourite(_ media: Media) -> Bool {
    guard let id = media.anilistId, media.source == .anilist else { return false }
    return AniListService.shared.isFavourite(id: id)
  }

  /// "1,234" reviewers or "?".
  func reviews(_ media: Media) -> String {
    AniListService.shared.reviews(media)
  }

  // MARK: - Episodes (EpisodeList.svelte)

  func episodes(for media: Media) async -> [EpisodeInfo] {
    if media.source == .tmdb { return await tmdbEpisodes(media) }
    return await anilistEpisodes(media)
  }

  private struct RawEpisode {
    var episode: Int
    var title: String?
    var airingAt: Date?
  }

  private func numericKeyOrder(_ keys: [String]) -> [String] {
    let numeric = keys.compactMap { Int($0) }.sorted().map { String($0) }
    let others = keys.filter { Int($0) == nil }.sorted()
    return numeric + others
  }

  private func notBefore(_ date: Date?, _ last: Date?) -> Date? {
    guard let date else { return nil }
    guard let last else { return date }
    if date >= last { return date }
    let calendar = Calendar.current
    return calendar.startOfDay(for: date) >= calendar.startOfDay(for: last) ? date : nil
  }

  private func anilistEpisodes(_ media: Media) async -> [EpisodeInfo] {
    guard let anilistId = media.anilistId else { return [] }
    let mappings = await AnimeMappingsService.shared.aniZip(anilistId: anilistId) ?? AniZipMappings()
    let episodesMap = mappings.episodes
    let orderedKeys = numericKeyOrder(Array(episodesMap.keys))
    let specialCount = mappings.specialCount ?? 0
    let newEpisodeCount = mappings.episodeCount ?? 0
    let extras = MediaStore.shared.extras(for: media)
    let episodeCount = AnimeHelpers.maxEpisode(media, extras: extras)
    let now = Date()

    func episodeData(_ number: Int) -> AniZipEpisode? {
      let data = episodesMap[String(number)] ?? episodesMap["O\(number)"]
      let movieLike = media.format == .movie || media.format == .special || (data?.title["en"]?.range(of: "movie", options: .caseInsensitive) != nil)
      if number == 1 && specialCount == 0 && episodesMap["1"] != nil && episodesMap["O1"] != nil && movieLike && orderedKeys.count > (media.episodes ?? 0) && media.status == .finished, orderedKeys.count > 1 {
        return episodesMap[orderedKeys[1]]
      }
      return data
    }

    var raw: [RawEpisode] = (0..<max(newEpisodeCount, episodeCount)).map { RawEpisode(episode: $0 + 1, title: nil, airingAt: nil) }
    if raw.count < episodeCount || (raw.isEmpty && episodeCount == 0) {
      let jikan = await AnimeMappingsService.shared.jikanEpisodes(malId: media.malId)
      if let lastId = jikan.last?.malId, lastId > 0 {
        raw = (1...lastId).map { number in
          let match = lastId <= 100 ? jikan.first(where: { $0.malId == number }) : nil
          return RawEpisode(episode: number, title: match?.title, airingAt: ServiceDates.parse(match?.aired))
        }
      } else if media.status == .releasing || media.status == .finished {
        let count = max(media.listEntry?.progress ?? 0, 1)
        raw = (1...count).map { RawEpisode(episode: $0, title: nil, airingAt: nil) }
      }
    }

    let zeroEpisode = await AnimeHelpers.hasZeroEpisode(media, mappings: mappings)
    let kitsu = await AnimeMappingsService.shared.kitsuEpisodes(anilistId: anilistId)
    if let zeroEpisode {
      let firstAiring = extras.airingSchedule.first(where: { $0.episode == 1 })?.airingAt ?? zeroEpisode.airingAt
      raw.insert(RawEpisode(episode: 0, title: zeroEpisode.title, airingAt: firstAiring), at: 0)
    }
    let streaming: [(number: Int, title: String, thumbnail: URL?)] = extras.streamingEpisodes.compactMap { episode in
      guard let parsed = AnimeHelpers.streamingEpisodeTitle(episode.title) else { return nil }
      return (parsed.number, parsed.title, episode.thumbnail)
    }
    let hasBonusEpisode = streaming.contains { $0.number == (media.episodes ?? -1) + 1 }

    var lastValidAirDate: Date?
    var lastDuration: Int? = AnimeCatalog.duration(for: media.format)
    var zeroAsFirstEpisode = false
    var usedImages = Set<String>()
    var usedSummaries = Set<String>()
    var output: [Int: EpisodeInfo] = [:]
    let list = raw.isEmpty ? [RawEpisode(episode: 1, title: nil, airingAt: nil)] : raw
    let startDate = extras.startDate

    for item in list {
      let validationNeeded = !(specialCount == 0 || ((media.episodes ?? 0) > 0 && media.episodes == newEpisodeCount && !episodesMap.isEmpty && episodeData(item.episode) != nil))
      let data: AniZipEpisode? = validationNeeded ? AnimeHelpers.episodeByAirDate(nil, episodes: episodesMap, episode: item.episode) : episodeData(item.episode)
      let kitsuEpisode = kitsu.first(where: { $0.number == item.episode })
      let streamingTitle: String? = hasBonusEpisode ? nil : streaming.first(where: { $0.number == item.episode && !$0.title.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("episode") })?.title
      let streamingThumbnail = streaming.first(where: { $0.number == item.episode })?.thumbnail

      var title: String?
      if item.episode == 0 {
        title = item.title
      } else {
        title = data?.title["en"]
        if title == nil, media.malId != nil {
          title = await AnimeMappingsService.shared.jikanEpisode(malId: media.malId, episode: item.episode)?.title
        }
        if title == nil { title = streamingTitle }
      }
      lastDuration = data?.length ?? media.duration ?? lastDuration

      let scheduledEpisode = item.episode + (zeroEpisode != nil ? 1 : 0)
      let scheduled = extras.airingSchedule.first(where: { $0.episode == scheduledEpisode })?.airingAt
      var validated = notBefore(scheduled, lastValidAirDate)
      if validated == nil {
        let fallback = ServiceDates.parse(data?.airdate)
        validated = notBefore(item.airingAt ?? fallback, lastValidAirDate)
      }
      if let validated { lastValidAirDate = validated }

      var zeroSummary: String?
      if item.episode == 0 {
        let match = episodesMap.values.first { candidate in
          guard let english = candidate.title["en"], let title else { return false }
          return ServiceText.matchPhrase(english, [title], threshold: 0)
        }
        zeroSummary = match?.summary ?? match?.overview ?? "This is a zero episode which means a prequel, prologue or a teaser which may be important to the story."
        lastDuration = match?.length ?? lastDuration
      }
      let fallbackTitle = title ?? kitsuEpisode?.titles["en_us"] ?? kitsuEpisode?.titles["en_jp"] ?? data?.title["jp"]
      if zeroEpisode != nil && item.episode == 1 && AnimeHelpers.isEpisodeZeroTitle(fallbackTitle) {
        zeroAsFirstEpisode = true
        continue
      }
      let episodeNumber = item.episode - (zeroAsFirstEpisode ? 1 : 0)
      let released = media.status == .finished || (validated.map { $0.timeIntervalSince(now) <= 7 * 24 * 3600 } ?? false)
      var foundTitle: String? = released ? fallbackTitle : nil
      if let found = foundTitle, media.episodes == 1, found.range(of: " web|web |movie", options: [.regularExpression, .caseInsensitive]) != nil || found.lowercased() == "web" {
        foundTitle = "The Movie"
      }

      var image: URL?
      if released {
        if item.episode == 0 {
          image = zeroEpisode?.thumbnail
        } else if let candidate = URL.lenient(data?.image) ?? URL.lenient(kitsuEpisode?.thumbnail) ?? streamingThumbnail, !usedImages.contains(candidate.absoluteString) {
          image = candidate
          usedImages.insert(candidate.absoluteString)
        }
      }

      var summary: String?
      let summaryVisible = media.status == .finished || (validated.map { $0 <= now } ?? false) || ((item.episode == 0 || item.episode == 1) && validated == nil && media.status == .releasing)
      if summaryVisible {
        if item.episode == 0 {
          summary = zeroSummary ?? data?.summary ?? data?.overview
        } else if let candidate = data?.summary ?? data?.overview ?? kitsuEpisode?.synopsis ?? kitsuEpisode?.description, !usedSummaries.contains(candidate) {
          summary = candidate
          usedSummaries.insert(candidate)
        }
      } else if let validated {
        summary = "This episode will be released on \(ServiceText.monthDay(validated, year: false))."
      } else if media.status == .notYetReleased, let start = startDate, start.month != nil, let date = start.date {
        summary = "This episode will be released in \(ServiceText.monthDay(date, year: true))."
      } else if media.status == .notYetReleased, media.season != nil || media.seasonYear != nil {
        let season = media.season.map { $0.rawValue.capitalized } ?? ""
        summary = "This episode will be released in \(season) \(media.seasonYear.map { String($0) } ?? "")."
      } else {
        summary = "This episode is in production and does not have an estimated release date."
      }

      let length: Int? = (media.status == .finished || validated != nil) ? lastDuration : nil
      var filler = false
      if media.malId != nil {
        filler = await AnimeMappingsService.shared.jikanEpisode(malId: media.malId, episode: episodeNumber)?.filler ?? false
      }
      let index = episodeNumber - (zeroEpisode == nil ? 1 : 0)
      output[index] = EpisodeInfo(number: episodeNumber, season: nil, localEpisode: nil, title: foundTitle, summary: summary, thumbnail: image, airDate: validated, durationMinutes: length, isFiller: filler)
    }

    var result = output.keys.sorted().compactMap { output[$0] }
    if zeroEpisode != nil && result.count == list.count && !result.isEmpty {
      result.removeLast()
    }
    if let banner = media.images.banner, result.contains(where: { $0.thumbnail != nil }) {
      result = result.map { episode in
        var copy = episode
        if copy.thumbnail == nil { copy.thumbnail = banner }
        return copy
      }
    }
    return result
  }

  private func tmdbEpisodes(_ media: Media) async -> [EpisodeInfo] {
    let type = media.tmdbType ?? (media.format == .movie ? .movie : .tv)
    guard let id = media.tmdbId, let details = await TMDBService.shared.details(id: id, type: type) else {
      return [EpisodeInfo(number: 1, season: nil, localEpisode: nil, title: media.title.display(), summary: media.description, thumbnail: media.images.banner, airDate: nil, durationMinutes: media.duration, isFiller: false)]
    }
    if type == .movie {
      return [EpisodeInfo(number: 1, season: nil, localEpisode: nil, title: details.title ?? media.title.display(), summary: details.description ?? media.description, thumbnail: details.backdrop ?? media.images.banner, airDate: ServiceDates.parse(details.releaseDate), durationMinutes: details.runtime, isFiller: false)]
    }
    var episodes: [EpisodeInfo] = []
    for season in details.seasons {
      let seasonEpisodes = await TMDBService.shared.seasonEpisodes(id: id, season: season.seasonNumber)
      for episode in seasonEpisodes {
        let name = episode.title ?? "Episode \(episode.episode)"
        let title = details.numberOfSeasons > 1 ? "S\(episode.seasonNumber)E\(episode.episode) - \(name)" : name
        episodes.append(EpisodeInfo(number: episodes.count + 1, season: season.seasonNumber, localEpisode: episode.episode, title: title, summary: episode.summary, thumbnail: episode.image ?? details.backdrop ?? media.images.banner, airDate: episode.airDate, durationMinutes: episode.length, isFiller: false))
      }
    }
    if episodes.isEmpty {
      return [EpisodeInfo(number: 1, season: nil, localEpisode: nil, title: "Episode 1", summary: media.description, thumbnail: media.images.banner, airDate: nil, durationMinutes: nil, isFiller: false)]
    }
    return episodes
  }
}
