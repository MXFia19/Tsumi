import Foundation
import Observation

// Port of common/modules/sections.js (every home section, the generic search / discover loader
// createFallbackLoad used by the Search page) and of the data part of common/routes/home/HomePage.svelte
// (section order from settings.homeSections, hero banner getTitles with bannerProvider mix / anime / western,
// refresh when the user lists or the episode feeds change).

enum HomeSectionKind: String, Hashable {
  /// Media cards.
  case media
  /// Episode cards (Recent Subs / Dubs / Hentai, Western - Recent TV Episodes).
  case episodes
}

/// One page of a section.
struct HomeSectionPage {
  var media: [Media] = []
  var episodes: [EpisodeFeedItem] = []
  var hasNextPage: Bool = false

  static let empty = HomeSectionPage()
}

/// Section / search variables (the `variables` / `search` objects of sections.js and SearchBar.svelte).
struct SectionQuery: Hashable {
  /// nil = anime + western (Search page "both"), true = TMDB only, false = AniList only.
  var western: Bool? = false
  /// Search page: mixes AniList and TMDB results when `western` is nil.
  var isSearch: Bool = false
  var text: String?
  var sort: String?
  var formats: [String] = []
  var formatsNot: [String] = []
  var genres: [String] = []
  var genresNot: [String] = []
  var tags: [String] = []
  var tagsNot: [String] = []
  var season: String?
  var year: Int?
  var status: [String] = []
  var statusNot: [String] = []
  var onList: Bool?
  var hideMyAnime: Bool = false
  var showMyAnime: Bool = false
  var hideStatus: [ListStatus] = []
  var showStatus: [ListStatus] = []
  /// hideSubs: dubbed anime only.
  var dubOnly: Bool = false
  /// TMDB genre names of western sections.
  var tmdbGenres: [String] = []
  /// Continue Watching filter (finished, or progress behind the aired episodes).
  var continueWatching: Bool = false

  /// AniList variables of the query.
  func anilistVariables(page: Int, perPage: Int) -> AniListVariables {
    var variables = AniListVariables()
    variables.page = page
    variables.perPage = perPage
    if let sort, !sort.isEmpty, sort != "N/A", !UserListSorts.isUserSort(sort) { variables.sort = sort }
    variables.search = (text?.isEmpty ?? true) ? nil : text
    variables.onList = onList
    if !status.isEmpty { variables.status = status }
    if !statusNot.isEmpty { variables.statusNot = statusNot }
    variables.season = season
    variables.year = year
    if !genres.isEmpty { variables.genre = genres }
    if !genresNot.isEmpty { variables.genreNot = genresNot }
    if !tags.isEmpty { variables.tag = tags }
    if !tagsNot.isEmpty { variables.tagNot = tagsNot }
    if !formats.isEmpty { variables.format = formats }
    if !formatsNot.isEmpty { variables.formatNot = formatsNot }
    return variables
  }

  /// Local list filter of the query (user list sections).
  var listFilter: ListFilter {
    var filter = ListFilter()
    filter.search = text
    filter.genres = genres
    filter.tags = tags
    filter.season = season
    filter.year = year
    filter.formats = formats
    filter.formatsNot = formatsNot
    filter.status = status
    filter.statusNot = statusNot
    filter.continueWatching = continueWatching
    filter.dubOnly = dubOnly
    filter.sort = sort
    return filter
  }
}

/// Search page request built from the Core MediaQuery plus the list / dub switches of SearchBar.svelte.
struct SearchRequest: Hashable {
  var query: MediaQuery
  var hideMyAnime: Bool = false
  var showMyAnime: Bool = false
  var listStatuses: [ListStatus] = [.current, .repeating, .completed, .dropped]
  var dubOnly: Bool = false

  init(query: MediaQuery, hideMyAnime: Bool = false, showMyAnime: Bool = false, listStatuses: [ListStatus] = [.current, .repeating, .completed, .dropped], dubOnly: Bool = false) {
    self.query = query
    self.hideMyAnime = hideMyAnime
    self.showMyAnime = showMyAnime
    self.listStatuses = listStatuses
    self.dubOnly = dubOnly
  }

  var sectionQuery: SectionQuery {
    var result = SectionQuery()
    switch query.scope {
    case .anime: result.western = false
    case .western: result.western = true
    case .both: result.western = nil
    }
    result.isSearch = true
    result.text = query.text
    result.sort = query.sort.rawValue
    result.formats = query.formats.map { $0.rawValue }
    result.genres = query.genres
    result.genresNot = query.excludedGenres
    result.tags = query.tags
    result.tagsNot = query.excludedTags
    result.season = query.season?.rawValue
    result.year = query.year
    result.status = query.status.map { $0.rawValue }
    result.statusNot = query.excludedStatus.map { $0.rawValue }
    result.onList = query.onList
    result.hideMyAnime = hideMyAnime
    result.showMyAnime = showMyAnime
    result.hideStatus = listStatuses
    result.showStatus = listStatuses
    result.dubOnly = dubOnly
    result.tmdbGenres = query.genres
    return result
  }
}

/// A home section: title, kind and a page loader (the UI does not need to know the source).
struct HomeSection: Identifiable {
  var id: String { title }
  let title: String
  let kind: HomeSectionKind
  /// Episode feed (RSS) section.
  let isRSS: Bool
  /// Built from the user's list (hidden when logged out).
  let isUserList: Bool
  /// Hidden (not logged in, or MyAnimeList for Sequels / Stories You Missed).
  let isHidden: Bool
  /// Formats shown in the settings for this section.
  let formats: [String]
  /// Default variables of the section.
  let variables: SectionQuery
  let loader: (_ page: Int, _ perPage: Int, _ variables: SectionQuery) async throws -> HomeSectionPage

  func load(page: Int = 1, perPage: Int = 50) async throws -> HomeSectionPage {
    try await loader(page, perPage, variables)
  }

  /// "View all" with extra filters from the Search page.
  func load(page: Int, perPage: Int, variables: SectionQuery) async throws -> HomeSectionPage {
    try await loader(page, perPage, variables)
  }
}

@Observable
@MainActor
final class HomeSectionsService {
  static let shared = HomeSectionsService()

  /// settings.js base layout (every section the Svelte app offers by default, in order).
  static let defaultLayout: [HomeSectionSetting] = [
    HomeSectionSetting(title: "Continue Watching", sort: "UPDATED_TIME_DESC", formats: []),
    HomeSectionSetting(title: "Anime - Trending now", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Western - Trending Now", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Anime - Recent Subs", sort: "N/A", formats: ["TV", "MOVIE", "OVA", "ONA"]),
    HomeSectionSetting(title: "Western - Recent TV Episodes", sort: "N/A", formats: ["TV"]),
    HomeSectionSetting(title: "Anime - Romance", sort: "TRENDING_DESC", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Western - Crime Dramas", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Anime - Recent Dubs", sort: "N/A", formats: ["TV", "MOVIE", "OVA", "ONA"]),
    HomeSectionSetting(title: "Anime - Isekai Comedy", sort: "TRENDING_DESC", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Western - Sci-Fi & Fantasy", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Anime - Popular This Season", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Anime - All Time Popular", sort: "N/A", formats: ["TV", "MOVIE"]),
    HomeSectionSetting(title: "Sequels You Missed", sort: "POPULARITY_DESC", formats: []),
    HomeSectionSetting(title: "Planning List", sort: "POPULARITY_DESC", formats: [])
  ]

  private static let hideStatus: [ListStatus] = [.current, .repeating, .completed, .dropped]
  private static let releasedOnly: [String] = ["NOT_YET_RELEASED", "CANCELLED"]

  /// Visible sections in the order of settings.homeSections.
  private(set) var sections: [HomeSection] = []
  /// Incremented when every section must reload (lists / settings changed).
  private(set) var revision = 0
  /// Feeds whose content changed at the last update (ReleaseFeed raw values).
  private(set) var changedFeeds: [String] = []
  /// Number of content changes of each episode feed (ReleaseFeed raw value): only the rows of these feeds
  /// reload when the AniSchedule feeds change (feedChanged listener of HomePage.svelte).
  private(set) var feedRevisions: [String: Int] = [:]

  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var settingsDebounce: Task<Void, Never>?

  private init() {
    rebuild()
    observers.append(NotificationCenter.default.addObserver(forName: AnimeScheduleService.feedsChanged, object: nil, queue: .main) { [weak self] note in
      let feeds = note.userInfo?["feeds"] as? [String] ?? []
      Task { @MainActor in
        self?.feedsDidChange(feeds)
      }
    })
    observeSettings()
  }

  private func feedsDidChange(_ feeds: [String]) {
    changedFeeds = feeds
    for feed in feeds {
      feedRevisions[feed, default: 0] += 1
    }
  }

  /// Feed revision of a home section ("Anime - Recent Subs" -> Sub feed), 0 for the other sections.
  func feedRevision(forSection title: String) -> Int {
    guard let feed = ReleaseFeed.allCases.first(where: { $0.sectionTitle == title }) else { return 0 }
    return feedRevisions[feed.rawValue] ?? 0
  }

  /// Called by MediaListService when the lists change (refreshSections of HomePage.svelte).
  func listsChanged() {
    revision += 1
  }

  private func observeSettings() {
    withObservationTracking {
      let values = AppSettings.shared.values
      _ = values.homeSections
      _ = values.customSections
      _ = values.westernSections
      _ = values.adult
      _ = values.hideMyAnime
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleSettingsRebuild()
      }
    }
  }

  private func scheduleSettingsRebuild() {
    observeSettings()
    settingsDebounce?.cancel()
    settingsDebounce = Task {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      if Task.isCancelled { return }
      self.rebuild()
    }
  }

  /// mapSections: visible sections ordered like settings.homeSections.
  func rebuild() {
    let catalog = makeCatalog()
    var byTitle: [String: HomeSection] = [:]
    for section in catalog { byTitle[section.title] = section }
    let layout = AppSettings.shared.values.homeSections
    sections = layout.compactMap { byTitle[$0.title] }.filter { !$0.isHidden }
    revision += 1
  }

  /// Every section that can be added to the home screen (settings "Home Sections" picker).
  var availableTitles: [String] {
    makeCatalog().map { $0.title }
  }

  func section(titled title: String) -> HomeSection? {
    makeCatalog().first { $0.title == title }
  }

  // MARK: - Catalog (createSections)

  private func setting(_ title: String) -> HomeSectionSetting? {
    AppSettings.shared.values.homeSections.first { $0.title == title }
  }

  /// createSection: sort from the settings (unless static), formats from the settings.
  private func baseQuery(_ title: String, defaultSort: String, staticSort: Bool) -> SectionQuery {
    var query = SectionQuery()
    query.western = false
    let configured = setting(title)
    if !staticSort, let sort = configured?.sort, sort != "N/A", !sort.isEmpty {
      query.sort = sort
    } else {
      query.sort = defaultSort
    }
    if let formats = configured?.formats, !formats.isEmpty { query.formats = formats }
    return query
  }

  private func makeCatalog() -> [HomeSection] {
    let settings = AppSettings.shared.values
    let authorized = AccountStore.shared.isAuthorized
    let mal = AccountStore.shared.isMAL
    var catalog: [HomeSection] = []

    // Latest aired episodes.
    var feeds: [ReleaseFeed] = [.dub, .sub]
    if settings.adult == "hentai" { feeds.append(.hentai) }
    for feed in feeds {
      catalog.append(HomeSection(title: feed.sectionTitle, kind: .episodes, isRSS: true, isUserList: false, isHidden: false, formats: feed == .hentai ? ["OVA"] : ["TV", "MOVIE", "OVA", "ONA"], variables: SectionQuery(), loader: { page, perPage, _ in
        let result = try await AnimeScheduleService.shared.recentEpisodes(feed, page: page, perPage: perPage)
        return HomeSectionPage(media: [], episodes: result.items, hasNextPage: result.hasNextPage)
      }))
    }
    var westernFeed = SectionQuery()
    westernFeed.western = true
    catalog.append(HomeSection(title: "Western - Recent TV Episodes", kind: .episodes, isRSS: true, isUserList: false, isHidden: false, formats: ["TV"], variables: westernFeed, loader: { page, perPage, _ in
      let items = await TMDBService.shared.recentEpisodes(page: page, perPage: perPage)
      return HomeSectionPage(media: [], episodes: items, hasNextPage: !items.isEmpty)
    }))

    // Missed sequels / stories (AniList only: MAL lists have no relations).
    catalog.append(HomeSection(title: "Sequels You Missed", kind: .media, isRSS: false, isUserList: true, isHidden: !authorized || mal, formats: [], variables: baseQuery("Sequels You Missed", defaultSort: "POPULARITY_DESC", staticSort: false), loader: { page, perPage, variables in
      let media = try await HomeSectionsService.missed(page: page, perPage: perPage, variables: variables, sequels: true)
      return HomeSectionPage(media: media.items, hasNextPage: media.hasNextPage)
    }))
    catalog.append(HomeSection(title: "Stories You Missed", kind: .media, isRSS: false, isUserList: true, isHidden: !authorized || mal, formats: [], variables: baseQuery("Stories You Missed", defaultSort: "POPULARITY_DESC", staticSort: false), loader: { page, perPage, variables in
      let media = try await HomeSectionsService.missed(page: page, perPage: perPage, variables: variables, sequels: false)
      return HomeSectionPage(media: media.items, hasNextPage: media.hasNextPage)
    }))

    // User lists.
    var continueQuery = baseQuery("Continue Watching", defaultSort: "UPDATED_TIME_DESC", staticSort: false)
    continueQuery.continueWatching = true
    continueQuery.statusNot = Self.releasedOnly
    catalog.append(HomeSection(title: "Continue Watching", kind: .media, isRSS: false, isUserList: true, isHidden: !authorized, formats: [], variables: continueQuery, loader: { page, perPage, variables in
      let media = try await HomeSectionsService.continueWatching(page: page, perPage: perPage, variables: variables)
      return HomeSectionPage(media: media.items, hasNextPage: media.hasNextPage)
    }))
    let lists: [(String, [ListStatus], String)] = [
      ("Watching List", [.current], "UPDATED_TIME_DESC"),
      ("Rewatching List", [.repeating], "UPDATED_TIME_DESC"),
      ("Completed List", [.completed], "UPDATED_TIME_DESC"),
      ("Planning List", [.planning], "POPULARITY_DESC"),
      ("Paused List", [.paused], "UPDATED_TIME_DESC"),
      ("Dropped List", [.dropped], "UPDATED_TIME_DESC")
    ]
    for (title, statuses, sort) in lists {
      var query = baseQuery(title, defaultSort: sort, staticSort: false)
      query.statusNot = Self.releasedOnly
      catalog.append(HomeSection(title: title, kind: .media, isRSS: false, isUserList: true, isHidden: !authorized, formats: [], variables: query, loader: { page, perPage, variables in
        let media = try await HomeSectionsService.userList(statuses, page: page, perPage: perPage, variables: variables)
        return HomeSectionPage(media: media.items, hasNextPage: media.hasNextPage)
      }))
    }

    // Common sections.
    let season = AnimeSeasonClock.currentSeason
    let year = AnimeSeasonClock.currentYear
    var popular = baseQuery("Anime - Popular This Season", defaultSort: "POPULARITY_DESC", staticSort: true)
    popular.season = season.rawValue
    popular.year = year
    applyHide(&popular, settings: settings)
    popular.statusNot = Self.releasedOnly
    catalog.append(searchSection("Anime - Popular This Season", query: popular))

    let next = AnimeSeasonClock.nextSeason
    var upcoming = baseQuery("Anime - Upcoming Next Season", defaultSort: "POPULARITY_DESC", staticSort: false)
    upcoming.season = next.season.rawValue
    upcoming.year = next.year
    applyHide(&upcoming, settings: settings)
    upcoming.status = ["NOT_YET_RELEASED"]
    upcoming.statusNot = ["CANCELLED"]
    catalog.append(searchSection("Anime - Upcoming Next Season", query: upcoming))

    var trending = baseQuery("Anime - Trending now", defaultSort: "TRENDING_DESC", staticSort: true)
    applyHide(&trending, settings: settings)
    trending.statusNot = Self.releasedOnly
    catalog.append(searchSection("Anime - Trending now", query: trending))

    var allTime = baseQuery("Anime - All Time Popular", defaultSort: "POPULARITY_DESC", staticSort: true)
    applyHide(&allTime, settings: settings)
    allTime.statusNot = Self.releasedOnly
    catalog.append(searchSection("Anime - All Time Popular", query: allTime))

    for custom in settings.customSections {
      var query = baseQuery(custom.title, defaultSort: "TRENDING_DESC", staticSort: false)
      query.genres = custom.genres
      query.tags = custom.tags
      query.genresNot = custom.excludedGenres
      query.tagsNot = custom.excludedTags
      applyHide(&query, settings: settings)
      query.statusNot = Self.releasedOnly
      catalog.append(searchSection(custom.title, query: query))
    }

    // Western (TMDB) sections.
    for western in settings.westernSections {
      let formats: [String]
      switch western.mediaType {
      case "Movies": formats = ["MOVIE"]
      case "TV Shows": formats = ["TV"]
      default: formats = ["TV", "MOVIE"]
      }
      var query = SectionQuery()
      query.western = true
      query.formats = formats
      query.tmdbGenres = western.genres
      query.genres = western.genres
      catalog.append(HomeSection(title: western.title, kind: .media, isRSS: false, isUserList: false, isHidden: false, formats: formats, variables: query, loader: { page, _, variables in
        var search = TMDBSearchQuery()
        search.page = page
        search.sort = (variables.sort == nil || variables.sort == "N/A") ? "POPULARITY_DESC" : variables.sort
        search.formats = variables.formats.isEmpty ? formats : variables.formats
        search.genres = variables.tmdbGenres.isEmpty ? western.genres : variables.tmdbGenres
        search.excludedGenres = variables.genresNot
        search.year = variables.year
        search.excludeAnime = true
        let result = await TMDBService.shared.search(search)
        return HomeSectionPage(media: result.items, hasNextPage: result.hasNextPage)
      }))
    }
    return catalog
  }

  private func applyHide(_ query: inout SectionQuery, settings: SettingsValues) {
    query.hideMyAnime = settings.hideMyAnime
    query.hideStatus = Self.hideStatus
  }

  private func searchSection(_ title: String, query: SectionQuery) -> HomeSection {
    HomeSection(title: title, kind: .media, isRSS: false, isUserList: false, isHidden: false, formats: query.formats, variables: query, loader: { page, perPage, variables in
      let result = try await HomeSectionsService.searchMedia(variables, page: page, perPage: perPage)
      return HomeSectionPage(media: result.items, hasNextPage: result.hasNextPage)
    })
  }

  // MARK: - Loaders

  /// Sequels You Missed / Stories You Missed.
  private static func missed(page: Int, perPage: Int, variables: SectionQuery, sequels: Bool) async throws -> MediaPage {
    guard let lists = ServiceListOverlay.lists, lists.service == .anilist else { return MediaPage.empty }
    let completed = lists.entries([.completed])
    let excluded = lists.entries([.current, .repeating, .completed, .dropped, .paused]).compactMap { $0.anilistId }
    var ids: [Int] = []
    for item in completed {
      guard let media = item.media else { continue }
      let edges = MediaStore.shared.extras(for: media).relationEdges
      for edge in edges {
        let keep = sequels ? edge.relationType == "SEQUEL" : !["SEQUEL", "CHARACTER", "OTHER"].contains(edge.relationType)
        if keep { ids.append(edge.id) }
      }
    }
    if ids.isEmpty { return MediaPage.empty }
    var anilist = variables.anilistVariables(page: page, perPage: perPage)
    anilist.id = Array(NSOrderedSet(array: ids).compactMap { $0 as? Int })
    anilist.idNot = excluded
    anilist.status = ["FINISHED", "RELEASING"]
    anilist.statusNot = nil
    return try await AniListService.shared.searchIDs(anilist)
  }

  /// Watching / Rewatching / Completed / Planning / Paused / Dropped lists.
  private static func userList(_ statuses: [ListStatus], page: Int, perPage: Int, variables: SectionQuery) async throws -> MediaPage {
    let items = await MediaListService.shared.items(statuses, sort: variables.sort ?? "UPDATED_TIME_DESC")
    if items.isEmpty { return MediaPage.empty }
    let result = try await MediaListService.shared.paginatedMedia(page: page, perPage: perPage, filter: variables.listFilter, items: items)
    let injected = await TMDBService.shared.injectImages(result.items)
    return MediaPage(items: injected, hasNextPage: result.hasNextPage)
  }

  /// Continue Watching: watching + rewatching, minus caught-up dubs (preferDubs) and caught-up MAL airing shows.
  private static func continueWatching(page: Int, perPage: Int, variables: SectionQuery) async throws -> MediaPage {
    var items = await MediaListService.shared.items([.current, .repeating], sort: variables.sort ?? "UPDATED_TIME_DESC")
    if items.isEmpty { return MediaPage.empty }
    let now = Date()
    let isMAL = AccountStore.shared.isMAL
    if AppSettings.shared.values.preferDubs {
      let airing = await AnimeScheduleService.shared.dubAiringList()
      var excluded = Set<String>()
      for item in items {
        let found = airing.first { entry in
          isMAL ? (entry.anime?.idMal != nil && entry.anime?.idMal == item.malId) : (entry.anime?.id != nil && entry.anime?.id == item.anilistId)
        }
        guard let matching = found, let anime = matching.anime else { continue }
        let nodes = anime.nodes.sorted { $0.episode < $1.episode }
        guard let first = nodes.first else { continue }
        let progress = item.progress - ((anime.zeroEpisode ?? false) ? 1 : 0)
        let episodeNumber = first.episode - (first.airingAt > now ? 1 : 0)
        let total = item.media?.episodes ?? 0
        let releasing = item.media?.status == .releasing || item.malAiringStatus == "currently_airing"
        let caughtUp = progress == episodeNumber + ((total > 0 && episodeNumber == total) ? 1 : 0)
        let notFinished = !(item.malNumEpisodes.map { progress >= $0 } ?? false)
        if caughtUp && (releasing || notFinished) { excluded.insert(item.id) }
      }
      items = items.filter { !excluded.contains($0.id) }
    }
    if isMAL {
      let airing = await AnimeScheduleService.shared.subAiringList()
      items = items.filter { item in
        guard let malId = item.malId, let matching = airing.first(where: { $0.idMal == malId }) else { return true }
        let nodes = matching.nodes
        guard let closest = nodes.min(by: { abs($0.airingAt.timeIntervalSince(now)) < abs($1.airingAt.timeIntervalSince(now)) }) else { return true }
        let highest = nodes.filter { $0.airingAt == closest.airingAt }.map { $0.episode }.max() ?? closest.episode
        let episodeNumber = closest.airingAt > now ? highest - 1 : highest
        let target = episodeNumber > 0 ? episodeNumber : (item.malNumEpisodes ?? 0)
        return !(item.progress >= target)
      }
    }
    let result = try await MediaListService.shared.paginatedMedia(page: page, perPage: perPage, filter: variables.listFilter, items: items)
    let injected = await TMDBService.shared.injectImages(result.items)
    return MediaPage(items: injected, hasNextPage: result.hasNextPage)
  }

  /// createFallbackLoad: AniList search / TMDB search / mixed search, with hide / show my anime and dubs only.
  static func searchMedia(_ query: SectionQuery, page: Int = 1, perPage: Int = 50) async throws -> MediaPage {
    if query.isSearch, let text = query.text, SearchRelevance.isRelevanceSort(text: text, sort: query.sort) {
      // Search page (no section) text query, no explicit sort: ranked by relevance with local fuzzy matches.
      let relevanceQuery: SectionQuery = {
        var copy = query
        copy.sort = "SEARCH_MATCH"
        return copy
      }()
      var hasher = Hasher()
      hasher.combine(query)
      hasher.combine(perPage)
      hasher.combine(AccountStore.shared.current?.id)
      let result = try await SearchRelevancePager.shared.page(key: hasher.finalize(), page: page, perPage: perPage, query: text) { sourcePage in
        try await sourceMedia(relevanceQuery, page: sourcePage, perPage: perPage)
      }
      let injected = await TMDBService.shared.injectImages(result.items)
      return MediaPage(items: injected, hasNextPage: result.hasNextPage)
    }
    let result = try await sourceMedia(query, page: page, perPage: perPage).page
    let injected = await TMDBService.shared.injectImages(result.items)
    return MediaPage(items: injected, hasNextPage: result.hasNextPage)
  }

  /// One page of the search sources (AniList, TMDB or both) and what it searched (relevance local matches).
  private static func sourceMedia(_ query: SectionQuery, page: Int, perPage: Int) async throws -> (page: MediaPage, sources: SearchRelevanceSources) {
    var sources = SearchRelevanceSources()
    var dubbed: [Int] = []
    if query.dubOnly {
      dubbed = await MALDubsService.shared.lists().dubbed
    }
    var anilist = query.anilistVariables(page: page, perPage: perPage)
    if query.dubOnly { anilist.idMal = dubbed }

    var result: MediaPage
    if (query.hideMyAnime || query.showMyAnime), let lists = ServiceListOverlay.lists {
      let statuses = Set(query.hideMyAnime ? query.hideStatus : query.showStatus)
      let matching = lists.items.filter { statuses.contains($0.status) }
      if lists.service == .anilist {
        let ids = Array(Set(matching.compactMap { query.dubOnly ? $0.malId : $0.anilistId }))
        if query.hideMyAnime, !ids.isEmpty {
          if query.dubOnly { anilist.idMalNot = ids } else { anilist.idNot = ids }
        } else if query.showMyAnime, !ids.isEmpty {
          if query.dubOnly { anilist.idMal = ids } else { anilist.id = ids }
        }
      } else {
        let ids = Array(Set(matching.compactMap { $0.malId }))
        if query.hideMyAnime, !ids.isEmpty {
          anilist.idMalNot = ids
        } else if query.showMyAnime, !ids.isEmpty {
          anilist.idMal = ids
        }
      }
      sources.anime = anilist
      result = try await AniListService.shared.search(anilist)
    } else if query.western == false {
      sources.anime = anilist
      result = try await AniListService.shared.search(anilist)
    } else if query.western == true {
      sources.western = true
      result = await westernSearch(query, page: page)
    } else if query.isSearch {
      sources.anime = anilist
      sources.western = true
      result = try await mixedSearch(query, anilist: anilist, page: page)
    } else {
      sources.anime = anilist
      result = try await AniListService.shared.search(anilist)
    }
    return (result, sources)
  }

  private static func westernSearch(_ query: SectionQuery, page: Int) async -> MediaPage {
    if let text = query.text, !text.isEmpty {
      return await TMDBService.shared.textSearch(text, page: page)
    }
    var search = TMDBSearchQuery()
    search.page = page
    search.sort = query.sort
    search.formats = query.formats
    search.genres = query.tmdbGenres.isEmpty ? query.genres : query.tmdbGenres
    search.excludedGenres = query.genresNot
    search.year = query.year
    search.excludeAnime = true
    return await TMDBService.shared.search(search)
  }

  /// Search page with "both": AniList (20) + TMDB interleaved, then sorted by relevance / sort.
  private static func mixedSearch(_ query: SectionQuery, anilist: AniListVariables, page: Int) async throws -> MediaPage {
    var anilistQuery = anilist
    anilistQuery.perPage = 20
    anilistQuery.sort = anilist.sort == "SEARCH_MATCH" ? "SEARCH_MATCH" : "TRENDING_DESC"
    async let animePage = AniListService.shared.search(anilistQuery)
    async let westernPage = westernSearch(query, page: page)
    let anime = (try? await animePage) ?? MediaPage.empty
    let western = await westernPage
    var combined: [Media] = []
    for index in 0..<max(anime.items.count, western.items.count) {
      if index < anime.items.count { combined.append(anime.items[index]) }
      if index < western.items.count { combined.append(western.items[index]) }
    }
    let text = (query.text ?? "").lowercased()
    let sort = query.sort ?? ""
    func title(_ media: Media) -> String {
      (media.title.userPreferred ?? media.title.english ?? media.title.romaji ?? "").lowercased()
    }
    func relevance(_ value: String) -> Int {
      if value == text { return 3 }
      if value.hasPrefix(text) { return 2 }
      if value.contains(text) { return 1 }
      return 0
    }
    func popularity(_ media: Media) -> Int {
      media.source == .tmdb ? (media.popularity ?? 0) * 1000 : (media.popularity ?? 0)
    }
    combined.sort { lhs, rhs in
      let left = title(lhs)
      let right = title(rhs)
      if !text.isEmpty {
        let leftRelevance = relevance(left)
        let rightRelevance = relevance(right)
        if leftRelevance != rightRelevance { return leftRelevance > rightRelevance }
      }
      if sort.contains("TITLE") {
        let ascending = left.localizedCompare(right) == .orderedAscending
        return sort.contains("DESC") ? !ascending : ascending
      }
      if sort.contains("SCORE") { return (lhs.averageScore ?? 0) > (rhs.averageScore ?? 0) }
      if sort.contains("DATE") || sort.contains("TIME") || sort.contains("YEAR") { return (lhs.seasonYear ?? 0) > (rhs.seasonYear ?? 0) }
      return popularity(lhs) > popularity(rhs)
    }
    return MediaPage(items: combined, hasNextPage: anime.hasNextPage || western.hasNextPage)
  }

  // MARK: - Search page / banner

  /// Search page load (SearchPage.svelte with the fallback loader).
  func search(_ request: SearchRequest, page: Int = 1, perPage: Int = 50) async throws -> MediaPage {
    try await Self.searchMedia(request.sectionQuery, page: page, perPage: perPage)
  }

  /// HomePage getTitles: hero banner media for bannerProvider mix / anime / western.
  func banner() async -> [Media] {
    let settings = AppSettings.shared.values
    let provider = settings.bannerProvider
    let hentaiBanner = settings.adult == "hentai" && settings.hentaiBanner
    var anime: [Media] = []
    var western: [Media] = []
    if provider != "western" {
      var variables = AniListVariables()
      variables.sort = "TRENDING_DESC"
      variables.perPage = 50
      variables.onList = AccountStore.shared.isAniList ? false : nil
      if hentaiBanner {
        variables.genre = ["Hentai"]
      } else {
        variables.season = AnimeSeasonClock.currentSeason.rawValue
      }
      variables.year = AnimeSeasonClock.currentYear
      variables.statusNot = ["NOT_YET_RELEASED"]
      anime = (try? await AniListService.shared.search(variables).items) ?? []
    }
    if provider != "anime" {
      var search = TMDBSearchQuery()
      search.sort = "TRENDING_DESC"
      search.formats = ["TV", "MOVIE"]
      search.excludeAnime = true
      search.page = 1
      let first = await TMDBService.shared.search(search)
      search.page = 2
      let second = await TMDBService.shared.search(search)
      western = first.items + second.items
    }
    if !anime.isEmpty { anime = await TMDBService.shared.injectImages(anime) }
    if !western.isEmpty { western = await TMDBService.shared.injectImages(western) }
    if provider == "anime" { return anime }
    if provider == "western" { return western }
    var mixed: [Media] = []
    for index in 0..<max(anime.count, western.count) {
      if index < anime.count { mixed.append(anime[index]) }
      if index < western.count { mixed.append(western[index]) }
    }
    return mixed
  }

  // MARK: - Schedule page

  func schedule(_ filter: ScheduleFilter, page: Int = 1) async throws -> (items: [AiringEpisode], hasNextPage: Bool) {
    try await AnimeScheduleService.shared.scheduleEntries(filter, page: page)
  }
}
