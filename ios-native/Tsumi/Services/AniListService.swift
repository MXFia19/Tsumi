import Foundation

// Port of common/modules/anilist.js: GraphQL client with rate limiting (90 requests / minute,
// Retry-After handling), search / discover, ID searches, user lists, mutations, notifications,
// airing schedules, following, favourites and the batched `requestMediaID`.

/// Variables of the AniList `Page.media` queries (search / searchIDS / searchAllIDS).
/// `sort == nil` means 'OMIT' (no sort argument).
struct AniListVariables: Codable, Hashable {
  var page: Int = 1
  var perPage: Int = 50
  var sort: String? = "TRENDING_DESC"
  var search: String?
  var onList: Bool?
  var status: [String]?
  var statusNot: [String]?
  var season: String?
  var year: Int?
  var genre: [String]?
  var genreNot: [String]?
  var tag: [String]?
  var tagNot: [String]?
  var format: [String]?
  var formatNot: [String]?
  var id: [Int]?
  var idNot: [Int]?
  var idMal: [Int]?
  var idMalNot: [Int]?
  var isAdult: Bool?

  enum QueryKind {
    case search
    case ids
  }

  /// JSON variables for the GraphQL request; empty arrays / strings are omitted.
  func graphQL(_ kind: QueryKind) -> [String: Any] {
    var result: [String: Any] = ["page": page, "perPage": perPage]
    if let sort, !sort.isEmpty { result["sort"] = [sort] }
    if let search, !search.isEmpty { result["search"] = search }
    if let onList { result["onList"] = onList }
    if let status, !status.isEmpty { result["status"] = status }
    if let season, !season.isEmpty { result["season"] = season }
    if let year { result["year"] = year }
    if let genre, !genre.isEmpty { result["genre"] = genre }
    if let genreNot, !genreNot.isEmpty { result["genre_not"] = genreNot }
    if let tag, !tag.isEmpty { result["tag"] = tag }
    if let tagNot, !tagNot.isEmpty { result["tag_not"] = tagNot }
    if let format, !format.isEmpty { result["format"] = format }
    if let id, !id.isEmpty { result["id"] = id }
    if let idNot, !idNot.isEmpty { result["id_not"] = idNot }
    if let idMal, !idMal.isEmpty { result["idMal"] = idMal }
    if let isAdult { result["isAdult"] = isAdult }
    if kind == .search {
      if let statusNot, !statusNot.isEmpty { result["status_not"] = statusNot }
      if let formatNot, !formatNot.isEmpty { result["format_not"] = formatNot }
      if let idMalNot, !idMalNot.isEmpty { result["idMal_not"] = idMalNot }
    }
    return result
  }

  var cacheKey: String { ServiceJSON.cacheKey(self) }

  /// search / searchIDS adult filtering: adult 'none' forces isAdult false, Hentai is excluded unless 'hentai'.
  func withAdultFilters() -> AniListVariables {
    var copy = self
    let adult = AppSettings.shared.values.adult
    if adult == "none" { copy.isAdult = false }
    if adult != "hentai" {
      var excluded = copy.genreNot ?? []
      if !excluded.contains("Hentai") { excluded.append("Hentai") }
      copy.genreNot = excluded
    }
    return copy
  }
}

/// Mutation input of SaveMediaListEntry (and MAL my_list_status).
struct ListEntryInput: Hashable {
  var anilistId: Int?
  var malId: Int?
  var status: ListStatus
  var progress: Int
  /// AniList: 0-100 (scoreRaw). MyAnimeList: 0-10.
  var scoreRaw: Int
  var repeatCount: Int
  var startedAt: FuzzyDate?
  var completedAt: FuzzyDate?
}

/// Result of SaveMediaListEntry.
struct SavedListEntry: Hashable {
  var id: Int?
  var status: ListStatus
  var progress: Int
  var score: Double?
  var repeatCount: Int
  var updatedAt: Date?
  var startedAt: FuzzyDate?
  var completedAt: FuzzyDate?

  var listEntry: ListEntry {
    ListEntry(status: status, progress: progress, score: score, repeatCount: repeatCount, updatedAt: updatedAt)
  }
}

/// AniList notification (AiringNotification / RelatedMediaAdditionNotification).
struct AniListNotificationItem: Hashable {
  var id: Int
  var type: String
  var episode: Int?
  var createdAt: Date
  var mediaType: String?
  var media: Media
}

/// Users the viewer follows that have the media on their list (Following.svelte).
struct AniListFollowingEntry: Hashable, Identifiable {
  var id: Int { userId }
  var userId: Int
  var name: String
  var avatar: URL?
  var siteURL: URL?
  var status: ListStatus?
  var progress: Int
  var score: Double
}

/// Title to resolve through the compound search (alSearchCompound).
struct AniListCompoundTitle: Hashable, Codable {
  var key: String
  var title: String
  var year: Int?
  var isAdult: Bool
}

/// Cached `Page.media` result.
struct AniListCachedPage: Codable {
  var media: [Media]
  var extras: [String: MediaExtras]
  var hasNextPage: Bool
}

final class AniListService: @unchecked Sendable {
  static let shared = AniListService()

  static let endpoint: URL = URL(string: "https://graphql.anilist.co") ?? URL(fileURLWithPath: "/")

  private let limiter = ServiceRateLimiter(capacity: 90, interval: 60, minSpacing: 0.1)
  private let inflight = ServiceInflight()
  private let batcher = AniListMediaBatcher()
  private let favourites = ServiceLocked<[Int: Bool]>([:])

  private init() {}

  // MARK: - Queries

  /// queryObjects of anilist.js.
  static let baseMediaFields = """
  id, idMal, title { romaji, english, native, userPreferred }, description(asHtml: false), \
  endDate { year, month, day }, startDate { year, month, day }, season, seasonYear, format, status, episodes, \
  duration, averageScore, genres, tags { name, rank, isGeneralSpoiler, isMediaSpoiler }, isFavourite, coverImage { extraLarge, medium, color }, \
  source, countryOfOrigin, isAdult, bannerImage, synonyms, popularity, stats { scoreDistribution { score, amount } }, \
  nextAiringEpisode { timeUntilAiring, episode }, trailer { id, site }, streamingEpisodes { title, thumbnail }, \
  mediaListEntry { id, progress, repeat, status, notes, customLists(asArray: true), score(format: POINT_10), updatedAt, \
  startedAt { year, month, day }, completedAt { year, month, day } }, \
  airingSchedule(page: 1, perPage: 1000) { nodes { episode, airingAt } }, \
  relations { edges { relationType(version: 2), node { id, type, format, genres, isAdult, seasonYear } } }
  """

  /// queryComplexObjects of anilist.js.
  static let complexMediaFields = """
  studios(sort: NAME, isMain: true) { nodes { name } }, \
  recommendations { edges { node { rating, mediaRecommendation { id, genres, isAdult } } } }
  """

  /// settings.queryComplexity: "Complex" (default) adds the studios and recommendations to every media query,
  /// "Simple" leaves them out (recommendations are then fetched on demand by `recommendationIds(id:)`).
  static var usesComplexQueries: Bool {
    AppSettings.shared.values.queryComplexity != "Simple"
  }

  static var mediaFields: String {
    usesComplexQueries ? baseMediaFields + ", " + complexMediaFields : baseMediaFields
  }

  /// Cache key suffix, so results without the complex fields are not reused once Complex is back on.
  private static var complexityKeySuffix: String {
    usesComplexQueries ? "" : ".simple"
  }

  static var searchQuery: String { """
  query($page: Int, $perPage: Int, $sort: [MediaSort], $search: String, $onList: Boolean, $status: [MediaStatus], \
  $status_not: [MediaStatus], $season: MediaSeason, $year: Int, $genre: [String], $genre_not: [String], $tag: [String], \
  $tag_not: [String], $format: [MediaFormat], $format_not: [MediaFormat], $id_not: [Int], $idMal_not: [Int], $id: [Int], \
  $idMal: [Int], $isAdult: Boolean) {
    Page(page: $page, perPage: $perPage) {
      pageInfo { hasNextPage }
      media(id_not_in: $id_not, idMal_not_in: $idMal_not, id_in: $id, idMal_in: $idMal, type: ANIME, search: $search, \
  sort: $sort, onList: $onList, status_in: $status, status_not_in: $status_not, season: $season, seasonYear: $year, \
  genre_in: $genre, genre_not_in: $genre_not, tag_in: $tag, tag_not_in: $tag_not, format_in: $format, format_not: MUSIC, \
  format_not_in: $format_not, isAdult: $isAdult) {
        \(mediaFields)
      }
    }
  }
  """ }

  static var idsQuery: String { """
  query($id: [Int], $idMal: [Int], $id_not: [Int], $page: Int, $perPage: Int, $status: [MediaStatus], $onList: Boolean, \
  $sort: [MediaSort], $search: String, $season: MediaSeason, $year: Int, $genre: [String], $genre_not: [String], \
  $tag: [String], $tag_not: [String], $format: [MediaFormat], $isAdult: Boolean) {
    Page(page: $page, perPage: $perPage) {
      pageInfo { hasNextPage }
      media(id_in: $id, idMal_in: $idMal, id_not_in: $id_not, type: ANIME, status_in: $status, onList: $onList, \
  search: $search, sort: $sort, season: $season, seasonYear: $year, genre_in: $genre, genre_not_in: $genre_not, \
  tag_in: $tag, tag_not_in: $tag_not, format_in: $format, isAdult: $isAdult) {
        \(mediaFields)
      }
    }
  }
  """ }

  static var singleQuery: String { """
  query($id: Int, $idMal: Int) {
    Media(id: $id, idMal: $idMal, type: ANIME) {
      \(mediaFields)
    }
  }
  """ }

  static let viewerQuery = """
  query {
    Viewer {
      avatar { medium, large }
      name
      id
      mediaListOptions { animeList { customLists } }
    }
  }
  """

  static let notificationsQuery = """
  query($page: Int, $perPage: Int) {
    Page(page: $page, perPage: $perPage) {
      notifications(resetNotificationCount: false, type_in: [AIRING, RELATED_MEDIA_ADDITION]) {
        ... on AiringNotification {
          id, type, episode, createdAt,
          media { id, idMal, type, format, status, title { userPreferred, romaji, english, native }, \
  coverImage { medium, extraLarge }, bannerImage, trailer { id, site }, mediaListEntry { status, progress } }
        }
        ... on RelatedMediaAdditionNotification {
          id, type, createdAt,
          media { id, idMal, type, format, status, title { userPreferred, romaji, english, native }, \
  coverImage { medium, extraLarge }, bannerImage, trailer { id, site } }
        }
      }
    }
  }
  """

  static var userListsQuery: String { """
  query($id: Int, $sort: [MediaListSort]) {
    MediaListCollection(userId: $id, type: ANIME, sort: $sort, forceSingleCompletedList: true) {
      lists {
        status
        entries {
          media {
            \(mediaFields)
          }
        }
      }
    }
  }
  """ }

  static let saveEntryMutation = """
  mutation($id: Int, $status: MediaListStatus, $episode: Int, $repeat: Int, $score: Int, $startedAt: FuzzyDateInput, \
  $completedAt: FuzzyDateInput) {
    SaveMediaListEntry(mediaId: $id, status: $status, progress: $episode, repeat: $repeat, scoreRaw: $score, \
  startedAt: $startedAt, completedAt: $completedAt) {
      id, status, progress, score(format: POINT_10), repeat, updatedAt,
      startedAt { year, month, day }
      completedAt { year, month, day }
    }
  }
  """

  static let deleteEntryMutation = """
  mutation($id: Int) {
    DeleteMediaListEntry(id: $id) { deleted }
  }
  """

  static let airingScheduleQuery = """
  query($id: Int) {
    Page(page: 1, perPage: 1000) {
      airingSchedules(mediaId: $id) { airingAt, episode }
    }
  }
  """

  static let episodeDateQuery = """
  query($id: Int, $ep: Int) {
    AiringSchedule(mediaId: $id, episode: $ep) { airingAt }
  }
  """

  static let followingQuery = """
  query($id: Int) {
    Page {
      mediaList(mediaId: $id, isFollowing: true, sort: UPDATED_TIME_DESC) {
        score(format: POINT_10), status, progress,
        user { id, name, siteUrl, avatar { large, medium } }
      }
    }
  }
  """

  static let recommendationsQuery = """
  query($id: Int) {
    Media(id: $id, type: ANIME) {
      id, idMal,
      recommendations { edges { node { rating, mediaRecommendation { id, genres, isAdult } } } }
    }
  }
  """

  static let favouriteMutation = """
  mutation($id: Int) {
    ToggleFavourite(animeId: $id) { anime { nodes { id } } }
  }
  """

  // MARK: - Transport

  /// Sends a GraphQL request (alRequest + handleRequest). Returns the decoded JSON root.
  func request(_ query: String, variables: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
    guard ServiceNetworkMonitor.shared.isOnline else { throw ServiceError.offline }
    let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    var headers = ["Content-Type": "application/json", "Accept": "application/json"]
    if let auth = token ?? AccountStore.shared.anilistToken {
      headers["Authorization"] = "Bearer " + auth
    }
    var attempt = 0
    while true {
      attempt += 1
      await limiter.acquire()
      let (data, response) = try await HTTP.data(Self.endpoint, method: "POST", headers: headers, body: body, timeout: 60, allowErrorStatus: true)
      let outage = AniListOutageMonitor.shared
      if response.statusCode == 429 || response.statusCode == 500 {
        if attempt >= 4 {
          // printError is muted while AniList is down (networking.js isAnilistDown).
          if !outage.isDown {
            ServiceMessages.send(.error, "Search Failed", "Failed making request to Anilist!\nTry again in a minute.")
          }
          throw ServiceError.rateLimited
        }
        let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
        await limiter.pause(for: response.statusCode == 500 ? 1 : retryAfter + 1)
        continue
      }
      let json = ServiceJSON.object(data)
      if let message = Self.outageMessage(status: response.statusCode, data: data, json: json) {
        // "temporarily disabled": one "AniList Outage" toast + status bar, later errors stay silent.
        outage.report(message, status: response.statusCode)
        if let json { return json }
        throw HTTPError.status(response.statusCode, Self.endpoint)
      }
      if (200..<300).contains(response.statusCode) {
        outage.markReachable()
      }
      guard let json else {
        if (200..<300).contains(response.statusCode) && !outage.isDown {
          ServiceMessages.send(.error, "Search Failed", "Failed making request to Anilist!\nTry again in a minute.")
        }
        throw HTTPError.status(response.statusCode, Self.endpoint)
      }
      if !(200..<300).contains(response.statusCode) && response.statusCode != 404 && !outage.isDown {
        let message = ServiceJSON.errorMessage(json) ?? "HTTP \(response.statusCode)"
        ServiceMessages.send(.error, "Search Failed", "Failed making request to Anilist!\nTry again in a minute.\n" + message)
      }
      return json
    }
  }

  /// networking.js isAnilistError: a 403 whose message says the API is "temporarily disabled".
  /// Returns that message, nil for any other response.
  static func outageMessage(status: Int, data: Data, json: [String: Any]?) -> String? {
    var messages: [(status: Int, text: String)] = []
    if let errors = json?["errors"] as? [[String: Any]] {
      for error in errors {
        messages.append((status: error.int("status") ?? status, text: error.string("message") ?? ""))
      }
    }
    if messages.isEmpty, status == 403, let text = String(data: data.prefix(4000), encoding: .utf8) {
      messages.append((status: status, text: text))
    }
    for message in messages where message.status == 403 || status == 403 {
      if message.text.range(of: "temporarily disabled", options: .caseInsensitive) != nil {
        return message.text.count > 300 ? String(message.text.prefix(300)) : message.text
      }
    }
    return nil
  }

  private func dataObject(_ json: [String: Any]) throws -> [String: Any] {
    if let data = json["data"] as? [String: Any] { return data }
    throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "AniList returned no data")
  }

  private static func randomTTL(_ minutes: ClosedRange<Int>) -> TimeInterval {
    TimeInterval(Int.random(in: minutes) * 60)
  }

  // MARK: - Viewer

  func viewer(token: String) async throws -> (viewer: Viewer, customLists: [String]) {
    let json = try await request(Self.viewerQuery, token: token)
    let data = try dataObject(json)
    guard let viewer = data.dict("Viewer"), let id = viewer.int("id") else {
      throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "Failed to sign in with AniList.")
    }
    let avatar = viewer.dict("avatar")
    let lists = ServiceJSON.strings(viewer.dict("mediaListOptions")?.dict("animeList"), "customLists")
    let result = Viewer(id: id, name: viewer.string("name") ?? "AniList User", avatar: URL.lenient(avatar?.string("large") ?? avatar?.string("medium")), service: .anilist)
    return (result, lists)
  }

  // MARK: - Notifications

  /// AiringNotification / RelatedMediaAdditionNotification list (cached 4 minutes).
  func notifications(page: Int = 1, perPage: Int = 50, ignoreExpiry: Bool = false) async throws -> [AniListNotificationItem] {
    let key = "al.notifications.\(AccountStore.shared.current?.viewer.id ?? 0).\(page).\(perPage)"
    if let cached = await DiskCache.shared.get(key, as: [AniListCachedNotification].self, allowExpired: ignoreExpiry || !ServiceNetworkMonitor.shared.isOnline) {
      return cached.map { $0.item }
    }
    let json = try await request(Self.notificationsQuery, variables: ["page": page, "perPage": perPage])
    let data = try dataObject(json)
    let raw = data.dict("Page")?.array("notifications") ?? []
    var items: [AniListCachedNotification] = []
    for entry in raw {
      guard let id = entry.int("id"), let mediaDict = entry.dict("media"), let parsed = AniListParser.media(mediaDict) else { continue }
      let createdAt = Date(timeIntervalSince1970: entry.double("createdAt") ?? 0)
      items.append(AniListCachedNotification(id: id, type: entry.string("type") ?? "", episode: entry.int("episode"), createdAt: createdAt, mediaType: mediaDict.string("type"), media: parsed.media))
    }
    await DiskCache.shared.set(key, items, ttl: 4 * 60)
    return items.map { $0.item }
  }

  // MARK: - User lists

  /// MediaListCollection of a user (getUserLists), retried 3 times as large lists can time out.
  func userLists(userId: Int, token: String? = nil, sort: String = "UPDATED_TIME_DESC") async throws -> [UserListItem] {
    var lastError: Error = ServiceError.invalidResponse
    for attempt in 1...3 {
      do {
        let json = try await request(Self.userListsQuery, variables: ["id": userId, "sort": [sort]], token: token)
        let data = try dataObject(json)
        guard let collection = data.dict("MediaListCollection") else {
          throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "Failed to load the AniList lists")
        }
        var items: [UserListItem] = []
        var seen = Set<Int>()
        var parsedMedia: [Media] = []
        var parsedExtras: [String: MediaExtras] = [:]
        var notes: [String: String] = [:]
        for list in collection.array("lists") {
          guard ListStatus(rawValue: list.string("status") ?? "") != nil else { continue }
          for entry in list.array("entries") {
            guard let mediaDict = entry.dict("media"), let parsed = AniListParser.media(mediaDict), let anilistId = parsed.media.anilistId else { continue }
            if seen.contains(anilistId) { continue }
            seen.insert(anilistId)
            if let item = UserListItem.fromAniList(parsed.media, extras: parsed.extras) {
              items.append(item)
            }
            parsedMedia.append(parsed.media)
            parsedExtras[parsed.media.id] = parsed.extras
            if let listEntry = mediaDict.dict("mediaListEntry"), listEntry["notes"] != nil {
              notes[parsed.media.id] = listEntry.string("notes") ?? ""
            }
          }
        }
        if token == nil {
          MediaStore.shared.ingest(parsedMedia, extras: parsedExtras)
          // Cross-device resume: positions written in the notes by the other devices.
          let listNotes = notes
          Task { @MainActor in PlaybackSyncService.shared.ingestListNotes(listNotes) }
        }
        return items
      } catch {
        lastError = error
        if let serviceError = error as? ServiceError, case .offline = serviceError { throw error }
        if attempt < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
      }
    }
    throw lastError
  }

  // MARK: - Mutations

  func saveEntry(_ input: ListEntryInput, token: String? = nil) async throws -> SavedListEntry {
    guard let mediaId = input.anilistId else { throw ServiceError.api("This title has no AniList id.") }
    var variables: [String: Any] = [
      "id": mediaId,
      "status": input.status.rawValue,
      "episode": input.progress,
      "repeat": input.repeatCount,
      "score": input.scoreRaw
    ]
    if let startedAt = input.startedAt, !startedAt.isEmpty { variables["startedAt"] = startedAt.graphQL }
    if let completedAt = input.completedAt, !completedAt.isEmpty { variables["completedAt"] = completedAt.graphQL }
    let json = try await request(Self.saveEntryMutation, variables: variables, token: token)
    let data = try dataObject(json)
    guard let saved = data.dict("SaveMediaListEntry"), let status = ListStatus(rawValue: saved.string("status") ?? "") else {
      throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "Failed to update the list")
    }
    let updatedAt = saved.double("updatedAt").map { Date(timeIntervalSince1970: $0) }
    return SavedListEntry(id: saved.int("id"), status: status, progress: saved.int("progress") ?? input.progress, score: saved.double("score"), repeatCount: saved.int("repeat") ?? input.repeatCount, updatedAt: updatedAt ?? Date(), startedAt: FuzzyDate.parse(saved.dict("startedAt")), completedAt: FuzzyDate.parse(saved.dict("completedAt")))
  }

  func deleteEntry(listEntryId: Int, token: String? = nil) async throws -> Bool {
    let json = try await request(Self.deleteEntryMutation, variables: ["id": listEntryId], token: token)
    let data = try dataObject(json)
    return data.dict("DeleteMediaListEntry")?.bool("deleted") ?? false
  }

  /// ToggleFavourite: flips the cached value immediately and sends the mutation in the background.
  @discardableResult
  func toggleFavourite(id: Int) -> Bool {
    let key = Media.anilistKey(id)
    let current = favourites.get()[id] ?? MediaStore.shared.extras(key)?.isFavourite ?? false
    let next = !current
    favourites.update { $0[id] = next }
    MediaStore.shared.updateExtras(key) { $0.isFavourite = next }
    Task {
      _ = try? await self.request(Self.favouriteMutation, variables: ["id": id])
    }
    return next
  }

  func isFavourite(id: Int) -> Bool {
    favourites.get()[id] ?? MediaStore.shared.extras(Media.anilistKey(id))?.isFavourite ?? false
  }

  // MARK: - Searches

  private func parsePage(_ json: [String: Any]) -> AniListCachedPage? {
    guard let data = json["data"] as? [String: Any], let page = data.dict("Page") else { return nil }
    var media: [Media] = []
    var extras: [String: MediaExtras] = [:]
    for item in page.array("media") {
      guard let parsed = AniListParser.media(item) else { continue }
      media.append(parsed.media)
      extras[parsed.media.id] = parsed.extras
    }
    return AniListCachedPage(media: media, extras: extras, hasNextPage: page.dict("pageInfo")?.bool("hasNextPage") ?? false)
  }

  private func finalize(_ page: AniListCachedPage, fresh: Bool) -> MediaPage {
    let items = MediaStore.shared.ingest(page.media, extras: page.extras, overwrite: fresh)
    return MediaPage(items: items, hasNextPage: page.hasNextPage)
  }

  /// Generic cached page query.
  private func cachedPage(cacheKey: String, query: String, variables: [String: Any], ttl: TimeInterval, skipCache: Bool, fallback: AniListVariables) async throws -> MediaPage {
    let online = ServiceNetworkMonitor.shared.isOnline
    if !skipCache, let cached = await DiskCache.shared.get(cacheKey, as: AniListCachedPage.self, allowExpired: !online) {
      return finalize(cached, fresh: false)
    }
    do {
      let page: AniListCachedPage = try await inflight.run(cacheKey) {
        let json = try await self.request(query, variables: variables)
        guard let page = self.parsePage(json) else {
          throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "AniList returned no data")
        }
        return page
      }
      await DiskCache.shared.set(cacheKey, page, ttl: ttl)
      return finalize(page, fresh: true)
    } catch {
      if let stale = await DiskCache.shared.get(cacheKey, as: AniListCachedPage.self, allowExpired: true) {
        return finalize(stale, fresh: false)
      }
      let fallbackPage = fallbackSearch(fallback)
      if fallbackPage.items.isEmpty { throw error }
      return fallbackPage
    }
  }

  /// anilistClient.search: discover / text search (cached 75-100 minutes).
  func search(_ input: AniListVariables) async throws -> MediaPage {
    let variables = input.withAdultFilters()
    return try await cachedPage(cacheKey: "al.search." + variables.cacheKey + Self.complexityKeySuffix, query: Self.searchQuery, variables: variables.graphQL(.search), ttl: Self.randomTTL(75...100), skipCache: false, fallback: variables)
  }

  /// anilistClient.searchIDS: one page of media by ids (cached 24-30 minutes). Sort defaults to OMIT.
  func searchIDs(_ input: AniListVariables, skipCache: Bool = false) async throws -> MediaPage {
    if let ids = input.id, ids.isEmpty, input.idMal == nil { return MediaPage.empty }
    let variables = input.withAdultFilters()
    return try await cachedPage(cacheKey: "al.ids." + variables.cacheKey + Self.complexityKeySuffix, query: Self.idsQuery, variables: variables.graphQL(.ids), ttl: Self.randomTTL(24...30), skipCache: skipCache, fallback: variables)
  }

  /// anilistClient.searchAllIDS: every page of an id search.
  func searchAllIDs(_ input: AniListVariables, skipCache: Bool = false) async throws -> [Media] {
    var variables = input
    variables.sort = input.sort
    if let ids = variables.id {
      let unique = Array(NSOrderedSet(array: ids).compactMap { $0 as? Int })
      if unique.isEmpty { return [] }
      variables.id = unique
    } else if let ids = variables.idMal {
      let unique = Array(NSOrderedSet(array: ids).compactMap { $0 as? Int })
      if unique.isEmpty { return [] }
      variables.idMal = unique
    }
    var all: [Media] = []
    var page = 1
    var lastError: Error?
    while page < 200 {
      variables.page = page
      variables.perPage = 50
      do {
        let result = try await searchIDs(variables, skipCache: skipCache)
        all.append(contentsOf: result.items)
        if !result.hasNextPage { break }
      } catch {
        lastError = error
        break
      }
      page += 1
    }
    if all.isEmpty, let lastError { throw lastError }
    return all
  }

  /// anilistClient.searchIDSingle by AniList id (cached 80-100 minutes).
  func media(id: Int) async throws -> Media? {
    try await single(variables: ["id": id], cacheKey: "al.single.id.\(id)" + Self.complexityKeySuffix, fallback: MediaStore.shared.anilist(id))
  }

  /// anilistClient.searchIDSingle by MyAnimeList id (tsumi://malanime/<id>).
  func media(malId: Int) async throws -> Media? {
    try await single(variables: ["idMal": malId], cacheKey: "al.single.mal.\(malId)" + Self.complexityKeySuffix, fallback: MediaStore.shared.anilist(malId: malId))
  }

  private func single(variables: [String: Any], cacheKey: String, fallback: Media?) async throws -> Media? {
    let online = ServiceNetworkMonitor.shared.isOnline
    if let cached = await DiskCache.shared.get(cacheKey, as: AniListCachedPage.self, allowExpired: !online) {
      return finalize(cached, fresh: false).items.first
    }
    do {
      let page: AniListCachedPage = try await inflight.run(cacheKey) {
        let json = try await self.request(Self.singleQuery, variables: variables)
        let data = try self.dataObject(json)
        guard let mediaDict = data.dict("Media"), let parsed = AniListParser.media(mediaDict) else {
          return AniListCachedPage(media: [], extras: [:], hasNextPage: false)
        }
        return AniListCachedPage(media: [parsed.media], extras: [parsed.media.id: parsed.extras], hasNextPage: false)
      }
      if !page.media.isEmpty {
        await DiskCache.shared.set(cacheKey, page, ttl: Self.randomTTL(80...100))
      }
      return finalize(page, fresh: true).items.first
    } catch {
      if let stale = await DiskCache.shared.get(cacheKey, as: AniListCachedPage.self, allowExpired: true) {
        return finalize(stale, fresh: false).items.first
      }
      if let fallback { return fallback }
      throw error
    }
  }

  /// requestMediaID: returns the stored media or batches the id into one searchAllIDS call (1.5s debounce).
  func requestMedia(id: Int) async -> Media? {
    if let stored = MediaStore.shared.anilist(id) { return stored }
    guard ServiceNetworkMonitor.shared.isOnline else { return nil }
    return await batcher.request(id) { ids in
      var variables = AniListVariables()
      variables.sort = nil
      variables.id = ids
      let media = (try? await AniListService.shared.searchAllIDs(variables, skipCache: true)) ?? []
      var map: [Int: Media] = [:]
      for item in media {
        if let anilistId = item.anilistId { map[anilistId] = item }
      }
      return map
    }
  }

  // MARK: - Compound title search (alSearchCompound)

  func searchCompound(_ titles: [AniListCompoundTitle]) async throws -> [String: Media] {
    if titles.isEmpty { return [:] }
    let cacheKey = "al.compound." + ServiceJSON.cacheKey(titles)
    if let cached = await DiskCache.shared.get(cacheKey, as: [String: Media].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) {
      return cached
    }
    var variables: [String: Any] = [:]
    var declarations: [String] = []
    var fragments: [String] = []
    for (index, title) in titles.enumerated() {
      let reuse = title.isAdult && index != 0
      if !reuse {
        variables["v\(index)"] = title.title
        declarations.append("$v\(index): String")
      }
      let variableIndex = reuse ? index - 1 : index
      let year = title.year.map { ", seasonYear: \($0)" } ?? ""
      fragments.append("v\(index): Page(perPage: 10) { media(type: ANIME, search: $v\(variableIndex), status_not: CANCELLED, isAdult: \(title.isAdult)\(year)) { ...med } }")
    }
    let query = "query(\(declarations.joined(separator: ", "))) {\n\(fragments.joined(separator: "\n"))\n}\nfragment med on Media { id, title { romaji, english, native, userPreferred }, synonyms }"
    do {
      let json = try await request(query, variables: variables)
      let data = try dataObject(json)
      var best: [String: Int] = [:]
      for (name, value) in data {
        guard let page = value as? [String: Any], let index = Int(name.dropFirst()), index < titles.count else { continue }
        let titleObject = titles[index]
        if best[titleObject.key] != nil { continue }
        var bestId: Int?
        var bestDistance = Int.max
        for candidate in page.array("media") {
          guard let id = candidate.int("id") else { continue }
          let distance = AniListParser.distance(candidate, to: titleObject.title)
          if distance <= bestDistance {
            if distance < bestDistance || bestId == nil { bestId = id }
            bestDistance = distance
          }
        }
        if let bestId { best[titleObject.key] = bestId }
      }
      var idsVariables = AniListVariables()
      idsVariables.sort = nil
      idsVariables.perPage = 50
      idsVariables.id = Array(Set(best.values))
      var found: [Media] = []
      if !best.isEmpty {
        found = try await searchIDs(idsVariables).items
      }
      var result: [String: Media] = [:]
      for (key, id) in best {
        if let media = found.first(where: { $0.anilistId == id }) { result[key] = media }
      }
      await DiskCache.shared.set(cacheKey, result, ttl: Self.randomTTL(60...90))
      return result
    } catch {
      if let stale = await DiskCache.shared.get(cacheKey, as: [String: Media].self, allowExpired: true) { return stale }
      throw error
    }
  }

  // MARK: - Airing schedule

  /// anilistClient.episodes: full airing schedule of a media (cached 75-100 minutes).
  func airingSchedule(id: Int) async throws -> [AiringNode] {
    let key = "al.episodes.\(id)"
    if let cached = await DiskCache.shared.get(key, as: [AiringNode].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) { return cached }
    let json = try await request(Self.airingScheduleQuery, variables: ["id": id])
    let data = try dataObject(json)
    let nodes = (data.dict("Page")?.array("airingSchedules") ?? []).compactMap { node -> AiringNode? in
      guard let episode = node.int("episode"), let airingAt = node.double("airingAt") else { return nil }
      return AiringNode(episode: episode, airingAt: Date(timeIntervalSince1970: airingAt))
    }
    await DiskCache.shared.set(key, nodes, ttl: Self.randomTTL(75...100))
    return nodes
  }

  /// anilistClient.episodeDate: air date of one episode.
  func episodeDate(id: Int, episode: Int) async throws -> Date? {
    let key = "al.episodeDate.\(id).\(episode)"
    if let cached = await DiskCache.shared.get(key, as: Date.self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) { return cached }
    let json = try await request(Self.episodeDateQuery, variables: ["id": id, "ep": episode])
    let data = try dataObject(json)
    guard let airingAt = data.dict("AiringSchedule")?.double("airingAt") else { return nil }
    let date = Date(timeIntervalSince1970: airingAt)
    await DiskCache.shared.set(key, date, ttl: Self.randomTTL(90...100))
    return date
  }

  // MARK: - Following / recommendations

  /// anilistClient.following (cached 200-300 minutes). Excludes the viewer, deduplicated by name.
  func following(mediaId: Int) async throws -> [AniListFollowingEntry] {
    guard AccountStore.shared.isAniList else { return [] }
    let key = "al.following.\(AccountStore.shared.current?.viewer.id ?? 0).\(mediaId)"
    var entries: [AniListFollowingEntry]
    if let cached = await DiskCache.shared.get(key, as: [AniListCachedFollowing].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) {
      entries = cached.map { $0.entry }
    } else {
      let json = try await request(Self.followingQuery, variables: ["id": mediaId])
      let data = try dataObject(json)
      let list = data.dict("Page")?.array("mediaList") ?? []
      let cached: [AniListCachedFollowing] = list.compactMap { item in
        guard let user = item.dict("user"), let id = user.int("id") else { return nil }
        return AniListCachedFollowing(userId: id, name: user.string("name") ?? "", avatar: URL.lenient(user.dict("avatar")?.string("large") ?? user.dict("avatar")?.string("medium")), siteURL: URL.lenient(user.string("siteUrl")), status: item.string("status"), progress: item.int("progress") ?? 0, score: item.double("score") ?? 0)
      }
      await DiskCache.shared.set(key, cached, ttl: Self.randomTTL(200...300))
      entries = cached.map { $0.entry }
    }
    let viewerId = AccountStore.shared.current?.viewer.id
    var seen = Set<String>()
    return entries.filter { entry in
      if entry.userId == viewerId { return false }
      if seen.contains(entry.name) { return false }
      seen.insert(entry.name)
      return true
    }
  }

  /// Recommendation ids of a media (with Complex queries they usually come from the store; with Simple
  /// queries they are requested here, like anilist.js `recommendations`).
  func recommendationIds(id: Int) async throws -> [Int] {
    if let extras = MediaStore.shared.extras(Media.anilistKey(id)), !extras.recommendationIds.isEmpty {
      return extras.recommendationIds
    }
    let key = "al.recommendations.\(id)"
    if let cached = await DiskCache.shared.get(key, as: [Int].self, allowExpired: !ServiceNetworkMonitor.shared.isOnline) { return cached }
    let json = try await request(Self.recommendationsQuery, variables: ["id": id])
    let data = try dataObject(json)
    let edges = data.dict("Media")?.dict("recommendations")?.array("edges") ?? []
    let ids = edges.compactMap { $0.dict("node")?.dict("mediaRecommendation")?.int("id") }
    await DiskCache.shared.set(key, ids, ttl: Self.randomTTL(1500...2000))
    return ids
  }

  // MARK: - Offline fallback (fallbackSearch)

  func fallbackSearch(_ variables: AniListVariables) -> MediaPage {
    let store = MediaStore.shared
    var media = store.allMedia().filter { $0.source == .anilist }
    media = media.filter { item in
      if let ids = variables.id, let id = item.anilistId, !ids.contains(id) { return false }
      if let ids = variables.idMal, !ids.contains(item.malId ?? -1) { return false }
      if let ids = variables.idNot, let id = item.anilistId, ids.contains(id) { return false }
      if let ids = variables.idMalNot, let mal = item.malId, ids.contains(mal) { return false }
      if variables.onList == true && item.listEntry == nil { return false }
      if variables.onList == false && item.listEntry != nil { return false }
      if variables.isAdult == false && item.isAdult { return false }
      if let status = variables.status, !status.isEmpty, !status.contains(item.status.rawValue) { return false }
      if let statusNot = variables.statusNot, statusNot.contains(item.status.rawValue) { return false }
      if let season = variables.season, item.season?.rawValue != season { return false }
      if let year = variables.year, item.seasonYear != year { return false }
      if let format = variables.format, !format.isEmpty, !format.contains(item.format.rawValue) { return false }
      if let formatNot = variables.formatNot, formatNot.contains(item.format.rawValue) { return false }
      if item.format == .music { return false }
      if let genre = variables.genre, !genre.isEmpty, !genre.contains(where: { item.genres.contains($0) }) { return false }
      if let genreNot = variables.genreNot, genreNot.contains(where: { item.genres.contains($0) }) { return false }
      if let tag = variables.tag, !tag.isEmpty, !tag.contains(where: { item.tags.contains($0) }) { return false }
      if let tagNot = variables.tagNot, tagNot.contains(where: { item.tags.contains($0) }) { return false }
      if let search = variables.search?.lowercased(), !search.isEmpty {
        let titles = (item.title.all + item.synonyms).map { $0.lowercased() }
        if !titles.contains(where: { $0.contains(search) }) { return false }
      }
      return true
    }
    if let sort = variables.sort {
      media.sort { lhs, rhs in AniListParser.fallbackOrder(lhs, rhs, sort: sort, store: store) }
    }
    let start = max(0, (variables.page - 1) * variables.perPage)
    let end = min(media.count, start + variables.perPage)
    let slice = start < end ? Array(media[start..<end]) : []
    return MediaPage(items: slice, hasNextPage: end < media.count)
  }

  // MARK: - Display helpers

  /// anilistClient.title: userPreferred when logged into AniList, else the titleLang setting.
  func title(_ media: Media) -> String {
    if AccountStore.shared.isAniList, let preferred = media.title.userPreferred, !preferred.isEmpty { return preferred }
    return media.title.display(AppSettings.shared.values.titleLang)
  }

  /// anilistClient.reviews: number of reviewers or "?".
  func reviews(_ media: Media) -> String {
    guard media.averageScore != nil, let count = MediaStore.shared.extras(media.id)?.reviewCount, count > 0 else { return "?" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: count)) ?? String(count)
  }
}

// MARK: - Outage detection (networking.js isAnilistDown)

/// AniList "temporarily disabled" outages: the first detection shows one "AniList Outage" toast and the
/// outage status bar (`ServiceNetworkMonitor.isAniListDown`), AniList error toasts stay muted while it lasts,
/// and the API is pinged every 15-25 s until it answers again (then "Connection Restored").
final class AniListOutageMonitor: @unchecked Sendable {
  static let shared = AniListOutageMonitor()

  private let pinging = ServiceLocked<Bool>(false)

  private init() {}

  var isDown: Bool { ServiceNetworkMonitor.shared.isAniListDown }

  /// A response said the API is disabled.
  func report(_ message: String, status: Int) {
    guard ServiceNetworkMonitor.shared.setAniListDown(true) else { return }
    ServiceMessages.send(.error, "AniList Outage", "\(status) - \(message)")
    startPinging()
  }

  /// A request succeeded: the outage (if any) is over.
  func markReachable() {
    ServiceNetworkMonitor.shared.setAniListDown(false)
  }

  private func startPinging() {
    let start = pinging.update { running -> Bool in
      if running { return false }
      running = true
      return true
    }
    guard start else { return }
    Task.detached(priority: .utility) { [self] in
      while ServiceNetworkMonitor.shared.isAniListDown {
        let seconds = UInt64(Int.random(in: 15...25))
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        if await Self.ping() {
          ServiceNetworkMonitor.shared.setAniListDown(false)
        }
      }
      self.pinging.set(false)
      // A new outage reported while this loop was ending.
      if ServiceNetworkMonitor.shared.isAniListDown { self.startPinging() }
    }
  }

  /// pingWith of networking.js: a one item query that must not answer "temporarily disabled".
  private static func ping() async -> Bool {
    guard ServiceNetworkMonitor.shared.isOnline else { return false }
    let query = ["query": "query { Page(page: 1, perPage: 1) { media { id } } }"]
    guard let body = try? JSONSerialization.data(withJSONObject: query) else { return false }
    let headers = ["Content-Type": "application/json", "Accept": "application/json"]
    guard let result = try? await HTTP.data(AniListService.endpoint, method: "POST", headers: headers, body: body, timeout: 10, allowErrorStatus: true) else {
      return false
    }
    let data = result.0
    let response = result.1
    guard (200..<300).contains(response.statusCode) else { return false }
    return AniListService.outageMessage(status: response.statusCode, data: data, json: ServiceJSON.object(data)) == nil
  }
}

// MARK: - Cache helper types

struct AniListCachedNotification: Codable {
  var id: Int
  var type: String
  var episode: Int?
  var createdAt: Date
  var mediaType: String?
  var media: Media

  var item: AniListNotificationItem {
    AniListNotificationItem(id: id, type: type, episode: episode, createdAt: createdAt, mediaType: mediaType, media: media)
  }
}

struct AniListCachedFollowing: Codable {
  var userId: Int
  var name: String
  var avatar: URL?
  var siteURL: URL?
  var status: String?
  var progress: Int
  var score: Double

  var entry: AniListFollowingEntry {
    AniListFollowingEntry(userId: userId, name: name, avatar: avatar, siteURL: siteURL, status: ListStatus(rawValue: status ?? ""), progress: progress, score: score)
  }
}

// MARK: - Batched media requests (processQueuedMediaIDs)

actor AniListMediaBatcher {
  private var queued: Set<Int> = []
  private var waiters: [Int: [CheckedContinuation<Media?, Never>]] = [:]
  private var flushTask: Task<Void, Never>?

  func request(_ id: Int, fetch: @escaping ([Int]) async -> [Int: Media]) async -> Media? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Media?, Never>) in
      waiters[id, default: []].append(continuation)
      queued.insert(id)
      flushTask?.cancel()
      flushTask = Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if Task.isCancelled { return }
        await self.flush(fetch)
      }
    }
  }

  private func flush(_ fetch: @escaping ([Int]) async -> [Int: Media]) async {
    let ids = Array(queued)
    queued.removeAll()
    if ids.isEmpty { return }
    let pending = ids.map { ($0, waiters.removeValue(forKey: $0) ?? []) }
    let result = await fetch(ids)
    for (id, continuations) in pending {
      let media = result[id]
      for continuation in continuations { continuation.resume(returning: media) }
    }
  }
}

// MARK: - Parsing

enum AniListParser {
  /// AniList media JSON -> Core Media + extras.
  static func media(_ dict: [String: Any]) -> (media: Media, extras: MediaExtras)? {
    guard let id = dict.int("id") else { return nil }
    var title = MediaTitle()
    if let titles = dict.dict("title") {
      title.romaji = titles.string("romaji")
      title.english = titles.string("english")
      title.native = titles.string("native")
      title.userPreferred = titles.string("userPreferred")
    }
    var images = MediaImages()
    if let cover = dict.dict("coverImage") {
      images.cover = URL.lenient(cover.string("medium") ?? cover.string("large") ?? cover.string("extraLarge"))
      images.coverLarge = URL.lenient(cover.string("extraLarge") ?? cover.string("large") ?? cover.string("medium"))
      images.color = cover.string("color")
    }
    images.banner = URL.lenient(dict.string("bannerImage"))
    let format = MediaFormat(rawValue: dict.string("format") ?? "") ?? .unknown
    let status = MediaStatus(rawValue: dict.string("status") ?? "") ?? .unknown
    var media = Media(id: Media.anilistKey(id), source: .anilist, title: title, images: images, format: format, status: status)
    media.anilistId = id
    media.malId = dict.int("idMal")
    media.description = dict.string("description")
    media.synonyms = ServiceJSON.strings(dict, "synonyms")
    media.genres = ServiceJSON.strings(dict, "genres")
    let tags = dict.array("tags")
    media.tags = tags.compactMap { $0.string("name") }
    media.studios = (dict.dict("studios")?.array("nodes") ?? []).compactMap { $0.string("name") }
    media.episodes = dict.int("episodes")
    media.duration = dict.int("duration")
    media.season = MediaSeason(rawValue: dict.string("season") ?? "")
    media.seasonYear = dict.int("seasonYear")
    let startDate = FuzzyDate.parse(dict.dict("startDate"))
    media.startDate = startDate?.date
    media.averageScore = dict.int("averageScore")
    media.popularity = dict.int("popularity")
    media.isAdult = dict.bool("isAdult") ?? false
    media.countryOfOrigin = dict.string("countryOfOrigin")
    if let next = dict.dict("nextAiringEpisode"), let episode = next.int("episode") {
      media.nextAiring = NextAiring(episode: episode, airingAt: Date().addingTimeInterval(next.double("timeUntilAiring") ?? 0))
    }
    var extras = MediaExtras()
    if let trailer = dict.dict("trailer"), let trailerId = trailer.string("id") {
      extras.trailerSite = trailer.string("site")
      if (trailer.string("site") ?? "youtube").lowercased() == "youtube" { media.trailerYouTubeId = trailerId }
    }
    extras.startDate = startDate
    extras.endDate = FuzzyDate.parse(dict.dict("endDate"))
    extras.isFavourite = dict.bool("isFavourite") ?? false
    extras.source = dict.string("source")
    for tag in tags {
      if let name = tag.string("name"), let rank = tag.int("rank") { extras.tagRanks[name] = rank }
    }
    // Spoiler protection (Core/SpoilerProtection.swift).
    extras.generalSpoilerTags = tags.filter { $0.bool("isGeneralSpoiler") == true }.compactMap { $0.string("name") }
    extras.mediaSpoilerTags = tags.filter { $0.bool("isMediaSpoiler") == true }.compactMap { $0.string("name") }
    let distribution = dict.dict("stats")?.array("scoreDistribution") ?? []
    if !distribution.isEmpty {
      extras.reviewCount = distribution.reduce(0) { $0 + ($1.int("amount") ?? 0) }
    }
    extras.streamingEpisodes = dict.array("streamingEpisodes").map {
      StreamingEpisodeInfo(title: $0.string("title"), thumbnail: URL.lenient($0.string("thumbnail")))
    }
    extras.airingSchedule = (dict.dict("airingSchedule")?.array("nodes") ?? []).compactMap { node -> AiringNode? in
      guard let episode = node.int("episode"), let airingAt = node.double("airingAt") else { return nil }
      return AiringNode(episode: episode, airingAt: Date(timeIntervalSince1970: airingAt))
    }
    extras.relationEdges = (dict.dict("relations")?.array("edges") ?? []).compactMap { edge -> RelationEdgeInfo? in
      guard let node = edge.dict("node"), let nodeId = node.int("id") else { return nil }
      return RelationEdgeInfo(id: nodeId, relationType: edge.string("relationType") ?? "OTHER", type: node.string("type"), format: node.string("format"), isAdult: node.bool("isAdult"), seasonYear: node.int("seasonYear"))
    }
    extras.recommendationIds = (dict.dict("recommendations")?.array("edges") ?? []).compactMap {
      $0.dict("node")?.dict("mediaRecommendation")?.int("id")
    }
    if let entry = dict.dict("mediaListEntry"), let entryStatus = ListStatus(rawValue: entry.string("status") ?? "") {
      let updatedAt = entry.double("updatedAt").map { Date(timeIntervalSince1970: $0) }
      media.listEntry = ListEntry(status: entryStatus, progress: entry.int("progress") ?? 0, score: entry.double("score"), repeatCount: entry.int("repeat"), updatedAt: updatedAt)
      extras.listEntryId = entry.int("id")
      extras.startedAt = FuzzyDate.parse(entry.dict("startedAt"))
      extras.completedAt = FuzzyDate.parse(entry.dict("completedAt"))
      extras.customLists = entry.array("customLists").compactMap { list -> CustomListFlag? in
        guard let name = list.string("name") else { return nil }
        return CustomListFlag(name: name, enabled: list.bool("enabled") ?? false)
      }
    }
    return (media, extras)
  }

  /// getDistanceFromTitle: smallest Levenshtein distance between `name` and the titles (synonyms +2).
  static func distance(_ media: [String: Any], to name: String) -> Int {
    let lowered = name.lowercased()
    var distances: [Int] = []
    if let titles = media.dict("title") {
      for key in ["romaji", "english", "native", "userPreferred"] {
        if let value = titles.string(key), !value.isEmpty {
          distances.append(ServiceText.levenshtein(value.lowercased(), lowered))
        }
      }
    }
    for synonym in ServiceJSON.strings(media, "synonyms") where !synonym.isEmpty {
      distances.append(ServiceText.levenshtein(synonym.lowercased(), lowered) + 2)
    }
    return distances.min() ?? Int.max
  }

  /// Sort comparator of fallbackSearch.
  static func fallbackOrder(_ lhs: Media, _ rhs: Media, sort: String, store: MediaStore) -> Bool {
    switch sort {
    case "TRENDING_DESC", "POPULARITY_DESC":
      return (lhs.popularity ?? 0) > (rhs.popularity ?? 0)
    case "TITLE_ROMAJI":
      let left = lhs.title.romaji ?? lhs.title.userPreferred ?? ""
      let right = rhs.title.romaji ?? rhs.title.userPreferred ?? ""
      return left.localizedCompare(right) == .orderedAscending
    case "SCORE_DESC":
      return (lhs.averageScore ?? 0) > (rhs.averageScore ?? 0)
    case "START_DATE_DESC":
      return (lhs.startDate ?? .distantPast) > (rhs.startDate ?? .distantPast)
    case "UPDATED_TIME_DESC":
      return (lhs.listEntry?.updatedAt ?? .distantPast) > (rhs.listEntry?.updatedAt ?? .distantPast)
    case "USER_SCORE_DESC":
      return (lhs.listEntry?.score ?? 0) > (rhs.listEntry?.score ?? 0)
    case "FINISHED_ON_DESC":
      return (store.extras(lhs.id)?.completedAt?.sortValue ?? 0) > (store.extras(rhs.id)?.completedAt?.sortValue ?? 0)
    case "STARTED_ON_DESC":
      return (store.extras(lhs.id)?.startedAt?.sortValue ?? 0) > (store.extras(rhs.id)?.startedAt?.sortValue ?? 0)
    case "PROGRESS_DESC":
      return AnimeHelpers.progressSortValue(lhs) < AnimeHelpers.progressSortValue(rhs)
    default:
      return false
    }
  }
}
