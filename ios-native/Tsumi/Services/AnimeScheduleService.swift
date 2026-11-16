import Foundation

// Port of common/modules/anime/animeschedule.js (AniSchedule feeds: sub / dub schedules and
// sub / dub / hentai episode feeds, update manifest polling every 5 minutes with jitter, release,
// announcement and delayed-dub notifications, the "Recent Subs / Dubs / Hentai" home feeds) and of the
// data part of common/routes/SchedulePage.svelte (fetchAllScheduleEntries), plus isSubbedProgress (anime.js).

enum ReleaseFeed: String, CaseIterable, Codable, Hashable {
  case sub = "Sub"
  case dub = "Dub"
  case hentai = "Hentai"

  var route: String {
    switch self {
    case .sub: return "sub"
    case .dub: return "dub"
    case .hentai: return "hentai"
    }
  }

  /// Key in the last-updated manifest.
  var manifestKey: String {
    switch self {
    case .sub: return "subbed"
    case .dub: return "dubbed"
    case .hentai: return "hentai"
    }
  }

  /// Home section title of the feed.
  var sectionTitle: String {
    switch self {
    case .sub: return "Anime - Recent Subs"
    case .dub: return "Anime - Recent Dubs"
    case .hentai: return "Hentai Releases"
    }
  }
}

struct ScheduleTitle: Codable, Hashable {
  var romaji: String?
  var english: String?
  var native: String?
  var userPreferred: String?
}

struct ScheduleCover: Codable, Hashable {
  var extraLarge: String?
  var medium: String?
  var color: String?
}

struct ScheduleNodes: Codable, Hashable {
  var nodes: [AiringNode]?
}

/// Media of the sub schedule (and of dub schedule entries).
struct ScheduleMedia: Codable, Hashable {
  var id: Int?
  var idMal: Int?
  var title: ScheduleTitle?
  var format: String?
  var genres: [String]?
  var duration: Int?
  var seasonYear: Int?
  var coverImage: ScheduleCover?
  var isAdult: Bool?
  var bannerImage: String?
  var airingSchedule: ScheduleNodes?
  var episodes: Int?
  var unaired: Bool?
  var zeroEpisode: Bool?

  var nodes: [AiringNode] { airingSchedule?.nodes ?? [] }

  private enum CodingKeys: String, CodingKey {
    case id, idMal, title, format, genres, duration, seasonYear, coverImage, isAdult, bannerImage, airingSchedule, episodes, unaired, zeroEpisode
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = container.svcLossyInt(.id)
    idMal = container.svcLossyInt(.idMal)
    title = try? container.decodeIfPresent(ScheduleTitle.self, forKey: .title)
    format = container.svcLossyString(.format)
    genres = try? container.decodeIfPresent([String].self, forKey: .genres)
    duration = container.svcLossyInt(.duration)
    seasonYear = container.svcLossyInt(.seasonYear)
    coverImage = try? container.decodeIfPresent(ScheduleCover.self, forKey: .coverImage)
    isAdult = container.svcLossyBool(.isAdult)
    bannerImage = container.svcLossyString(.bannerImage)
    airingSchedule = try? container.decodeIfPresent(ScheduleNodes.self, forKey: .airingSchedule)
    episodes = container.svcLossyInt(.episodes)
    unaired = container.svcLossyBool(.unaired)
    zeroEpisode = container.svcLossyBool(.zeroEpisode)
  }
}

struct DubScheduleMediaWrapper: Codable, Hashable {
  var media: ScheduleMedia?
}

/// Dub schedule entry (AnimeSchedule.net timetables).
struct DubScheduleEntry: Codable, Hashable {
  var title: String?
  var delayedFrom: String?
  var delayedUntil: String?
  var delayedText: String?
  var delayedIndefinitely: Bool?
  var episodeDate: String?
  var episodeNumber: Int?
  var subtractedEpisodeNumber: Int?
  var episodes: Int?
  var unaired: Bool?
  var status: String?
  var addedAt: String?
  var media: DubScheduleMediaWrapper?

  var anime: ScheduleMedia? { media?.media }

  private enum CodingKeys: String, CodingKey {
    case title, delayedFrom, delayedUntil, delayedText, delayedIndefinitely, episodeDate, episodeNumber
    case subtractedEpisodeNumber, episodes, unaired, status, addedAt, media
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = container.svcLossyString(.title)
    delayedFrom = container.svcLossyString(.delayedFrom)
    delayedUntil = container.svcLossyString(.delayedUntil)
    delayedText = container.svcLossyString(.delayedText)
    delayedIndefinitely = container.svcLossyBool(.delayedIndefinitely)
    episodeDate = container.svcLossyString(.episodeDate)
    episodeNumber = container.svcLossyInt(.episodeNumber)
    subtractedEpisodeNumber = container.svcLossyInt(.subtractedEpisodeNumber)
    episodes = container.svcLossyInt(.episodes)
    unaired = container.svcLossyBool(.unaired)
    status = container.svcLossyString(.status)
    addedAt = container.svcLossyString(.addedAt)
    media = try? container.decodeIfPresent(DubScheduleMediaWrapper.self, forKey: .media)
  }
}

struct AiredEpisode: Codable, Hashable {
  var aired: Int?
  var airedAt: String?
  var addedAt: String?
  /// Last episode of a batch release ("1 ~ 3" in the feed, handleArray of episodes.js), nil otherwise.
  var airedLast: Int?

  private enum CodingKeys: String, CodingKey {
    case aired, airedAt, addedAt, airedLast
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    aired = container.svcLossyInt(.aired)
    airedAt = container.svcLossyString(.airedAt)
    addedAt = container.svcLossyString(.addedAt)
    airedLast = container.svcLossyInt(.airedLast)
    if aired == nil, let text = container.svcLossyString(.aired), let range = AnimeMappingsService.episodeRange(text) {
      aired = range.first
      airedLast = range.last
    }
  }
}

/// Episode feed entry (sub / dub / hentai -episode-feed).
struct AiredFeedEntry: Codable, Hashable {
  var id: Int?
  var idMal: Int?
  var format: String?
  var duration: Int?
  var episode: AiredEpisode?

  private enum CodingKeys: String, CodingKey {
    case id, idMal, format, duration, episode
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = container.svcLossyInt(.id)
    idMal = container.svcLossyInt(.idMal)
    format = container.svcLossyString(.format)
    duration = container.svcLossyInt(.duration)
    episode = try? container.decodeIfPresent(AiredEpisode.self, forKey: .episode)
  }

  var airedDate: Date? { ServiceDates.parse(episode?.airedAt) }
  var addedDate: Date? { ServiceDates.parse(episode?.addedAt) }
}

struct ScheduleManifestFeed: Codable, Hashable {
  var episodes: String?
  var schedule: String?
}

/// raw/last-updated.json.
struct ScheduleManifest: Codable, Hashable {
  var subbed: ScheduleManifestFeed?
  var dubbed: ScheduleManifestFeed?
  var hentai: ScheduleManifestFeed?

  func value(_ feed: ReleaseFeed, schedule: Bool) -> String? {
    let entry: ScheduleManifestFeed?
    switch feed {
    case .sub: entry = subbed
    case .dub: entry = dubbed
    case .hentai: entry = hentai
    }
    return schedule ? entry?.schedule : entry?.episodes
  }

  mutating func set(_ feed: ReleaseFeed, schedule: Bool, value: String?) {
    var entry: ScheduleManifestFeed
    switch feed {
    case .sub: entry = subbed ?? ScheduleManifestFeed()
    case .dub: entry = dubbed ?? ScheduleManifestFeed()
    case .hentai: entry = hentai ?? ScheduleManifestFeed()
    }
    if schedule { entry.schedule = value ?? entry.schedule } else { entry.episodes = value ?? entry.episodes }
    switch feed {
    case .sub: subbed = entry
    case .dub: dubbed = entry
    case .hentai: hentai = entry
    }
  }
}

struct ScheduleManifestCheck {
  var changed: Bool
  var force: Bool
  var previous: ScheduleManifest?
  var current: ScheduleManifest?
}

/// Filters of the Schedule page (SearchBar variables of SchedulePage.svelte).
struct ScheduleFilter: Hashable {
  /// hideSubs: dub schedule instead of the sub schedule.
  var dubs: Bool = false
  /// nil = anime + western, true = western only, false = anime only.
  var western: Bool? = false
  var formats: [String] = ["TV"]
  var genres: [String] = []
  var excludedGenres: [String] = []
  var tags: [String] = []
  var excludedTags: [String] = []
  var hideMyAnime: Bool = false
  var showMyAnime: Bool = false
  var listStatuses: [ListStatus] = []
  /// "Release" filter: episodes, movies in theaters, movies on digital (MovieReleases).
  var release: ScheduleRelease = .any
}

/// Persists the stored manifest (lastUpdated store + _lastUpdatedLock).
actor ScheduleManifestStore {
  private static let key = "anischedule.manifest"
  private var manifest: ScheduleManifest?
  private var loaded = false

  func get() async -> ScheduleManifest? {
    if !loaded {
      manifest = await DiskCache.shared.get(Self.key, as: ScheduleManifest.self, allowExpired: true)
      loaded = true
    }
    return manifest
  }

  func update(_ feed: ReleaseFeed, schedule: Bool, value: String?) async {
    var current = await get() ?? ScheduleManifest()
    current.set(feed, schedule: schedule, value: value)
    manifest = current
    await DiskCache.shared.set(Self.key, current, ttl: 3650 * 24 * 3600)
  }
}

final class AnimeScheduleService: @unchecked Sendable {
  static let shared = AnimeScheduleService()
  /// Posted (main queue) when episode feeds changed; userInfo["feeds"] = [ReleaseFeed raw values].
  static let feedsChanged = Notification.Name("tsumi.services.feedsChanged")

  private static let base = ServiceText.base64("aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL1JvY2tpbkNoYW9zL0FuaVNjaGVkdWxlL21hc3Rlci9yYXc=")

  private struct PageCacheEntry {
    var signature: Int
    var items: [EpisodeFeedItem]
    var hasNextPage: Bool
  }

  private struct State {
    var subAiring: [ScheduleMedia]?
    var dubAiring: [DubScheduleEntry]?
    var aired: [ReleaseFeed: [AiredFeedEntry]] = [:]
    var manifestDate: Date?
    var manifestResult: ScheduleManifestCheck?
    var pageCache: [String: PageCacheEntry] = [:]
    var pollTask: Task<Void, Never>?
    /// Aired dub episodes per AniList id (built lazily from aired[.dub], reset when it changes).
    var dubCounts: [Int: Int]?
  }

  private let state = ServiceLocked<State>(State())
  private let manifestStore = ScheduleManifestStore()
  private let inflight = ServiceInflight()
  private let jitter = Double.random(in: 27...60)
  /// Feeds whose release notifications are being computed (the home rows and the background check can overlap).
  private let notifying = ServiceLocked<Set<ReleaseFeed>>([])

  private init() {}

  // MARK: - Feeds

  private func feedName(_ feed: ReleaseFeed, schedule: Bool) -> String {
    feed.route + (schedule ? "-schedule" : "-episode-feed")
  }

  private func getFeed<T: Decodable>(_ name: String, as type: T.Type) async throws -> T {
    guard ServiceNetworkMonitor.shared.isOnline else { throw ServiceError.offline }
    guard let url = URL(string: "\(Self.base)/\(name).json?timestamp=\(Int(Date().timeIntervalSince1970 * 1000))") else { throw ServiceError.invalidResponse }
    let (data, response) = try await HTTP.data(url, timeout: 60, allowErrorStatus: true)
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode != 404 {
        ServiceMessages.send(.error, "Search Failed", "Failed to fetch the anime schedule(s)!")
      }
      throw HTTPError.status(response.statusCode, url)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// manifestChanged: compares raw/last-updated.json with the stored manifest (memoized one minute).
  func manifestChanged(force: Bool = false) async -> ScheduleManifestCheck {
    let current = state.get()
    if !force, let date = current.manifestDate, let result = current.manifestResult, Date().timeIntervalSince(date) < 60 {
      return result
    }
    let previous = await manifestStore.get()
    let result: ScheduleManifestCheck
    do {
      let latest = try await getFeed("last-updated", as: ScheduleManifest.self)
      if latest != previous {
        result = ScheduleManifestCheck(changed: true, force: false, previous: previous, current: latest)
      } else {
        result = ScheduleManifestCheck(changed: false, force: false, previous: previous, current: latest)
      }
    } catch {
      result = previous != nil
        ? ScheduleManifestCheck(changed: false, force: false, previous: previous, current: nil)
        : ScheduleManifestCheck(changed: true, force: true, previous: nil, current: nil)
    }
    state.update { value in
      value.manifestDate = Date()
      value.manifestResult = result
    }
    return result
  }

  /// feedChanged: downloads a feed (falls back to the cached copy) and records its manifest value. The manifest
  /// value is only recorded after a successful download: a failed one is downloaded again at the next check instead
  /// of keeping the stale cached feed until the feed changes upstream again.
  private func feedChanged<T: Codable>(_ feed: ReleaseFeed, schedule: Bool, manifest: ScheduleManifestCheck?, as type: T.Type) async throws -> T {
    let name = feedName(feed, schedule: schedule)
    let cacheKey = "anischedule." + name
    let content: T
    do {
      content = try await inflight.run(cacheKey) {
        try await self.getFeed(name, as: T.self)
      }
      await DiskCache.shared.set(cacheKey, content, ttl: 315)
      if let current = manifest?.current {
        await manifestStore.update(feed, schedule: schedule, value: current.value(feed, schedule: schedule))
      }
    } catch {
      guard let cached = await DiskCache.shared.get(cacheKey, as: T.self, allowExpired: true) else { throw error }
      content = cached
    }
    return content
  }

  /// feedFromManifest: cached feed unless the manifest says it changed.
  private func feedFromManifest<T: Codable>(_ feed: ReleaseFeed, schedule: Bool, as type: T.Type) async throws -> T {
    let manifest = await manifestChanged()
    let cacheKey = "anischedule." + feedName(feed, schedule: schedule)
    let cached = await DiskCache.shared.get(cacheKey, as: T.self, allowExpired: true)
    let changed = manifest.changed && manifest.previous?.value(feed, schedule: schedule) != manifest.current?.value(feed, schedule: schedule)
    if let cached, !manifest.force, !changed {
      return cached
    }
    return try await feedChanged(feed, schedule: schedule, manifest: manifest, as: type)
  }

  /// Sub schedule (AniChart): AniList media with their airing schedule.
  func subAiringList(refresh: Bool = false) async -> [ScheduleMedia] {
    if !refresh, let list = state.get().subAiring { return list }
    let list = (try? await feedFromManifest(.sub, schedule: true, as: [ScheduleMedia].self)) ?? state.get().subAiring ?? []
    state.update { $0.subAiring = list }
    return list
  }

  /// Dub schedule (AnimeSchedule.net timetables).
  func dubAiringList(refresh: Bool = false) async -> [DubScheduleEntry] {
    if !refresh, let list = state.get().dubAiring { return list }
    let list = (try? await feedFromManifest(.dub, schedule: true, as: [DubScheduleEntry].self)) ?? state.get().dubAiring ?? []
    state.update { $0.dubAiring = list }
    return list
  }

  /// Episode feed (aired episodes) of a release type.
  func airedList(_ feed: ReleaseFeed, refresh: Bool = false) async -> [AiredFeedEntry] {
    if !refresh, let list = state.get().aired[feed] { return list }
    let list = (try? await feedFromManifest(feed, schedule: false, as: [AiredFeedEntry].self)) ?? state.get().aired[feed] ?? []
    state.update { value in
      value.aired[feed] = list
      if feed == .dub { value.dubCounts = nil }
    }
    return list
  }

  // MARK: - Loaded lists (synchronous reads for the UI, nil until loaded)

  /// Dub schedule if already loaded (no request).
  func loadedDubAiringList() -> [DubScheduleEntry]? {
    state.get().dubAiring
  }

  /// Episode feed if already loaded (no request).
  func loadedAiredList(_ feed: ReleaseFeed) -> [AiredFeedEntry]? {
    state.get().aired[feed]
  }

  /// Number of aired dub episodes of a media (dubAiredLists of AudioLabel.svelte); nil until the dub feed is loaded.
  func loadedDubAiredCount(anilistId: Int) -> Int? {
    let counts: [Int: Int]? = state.update { value in
      if let cached = value.dubCounts { return cached }
      guard let list = value.aired[.dub] else { return nil }
      var built: [Int: Int] = [:]
      for entry in list {
        if let id = entry.id { built[id, default: 0] += 1 }
      }
      value.dubCounts = built
      return built
    }
    guard let counts else { return nil }
    return counts[anilistId] ?? 0
  }

  /// Dub schedule entry of a media if the dub schedule is already loaded (no request).
  func loadedDubEntry(anilistId: Int) -> DubScheduleEntry? {
    state.get().dubAiring?.first { $0.anime?.id == anilistId }
  }

  // MARK: - Polling (checkManifestAndFeeds)

  /// Starts the 5 minute manifest polling (next 5-minute mark + 27-60 s jitter).
  func start() {
    let shouldStart: Bool = state.update { value in
      if value.pollTask != nil { return false }
      return true
    }
    guard shouldStart else { return }
    let task = Task {
      _ = await self.subAiringList()
      _ = await self.dubAiringList()
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      await self.findNewNotifications()
      await self.findNewDelayedEpisodes()
      await self.checkNewReleases()
      while !Task.isCancelled {
        let now = Date()
        let seconds = now.timeIntervalSince1970
        let next = (seconds / 300).rounded(.down) * 300 + 300
        let wait = next - seconds + self.jitter
        try? await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
        if Task.isCancelled { break }
        await self.checkForUpdates()
      }
    }
    state.update { $0.pollTask = task }
  }

  func stop() {
    let task: Task<Void, Never>? = state.update { value in
      let current = value.pollTask
      value.pollTask = nil
      return current
    }
    task?.cancel()
  }

  /// checkManifestAndFeeds.
  func checkForUpdates() async {
    let manifest = await manifestChanged(force: true)
    guard manifest.changed else { return }
    var scheduleChanged = false
    for feed in [ReleaseFeed.sub, ReleaseFeed.dub] {
      let differs = manifest.previous?.value(feed, schedule: true) != manifest.current?.value(feed, schedule: true)
      guard manifest.force || differs else { continue }
      scheduleChanged = true
      if feed == .sub {
        if let list = try? await feedChanged(.sub, schedule: true, manifest: manifest, as: [ScheduleMedia].self) {
          state.update { $0.subAiring = list }
        }
      } else if let list = try? await feedChanged(.dub, schedule: true, manifest: manifest, as: [DubScheduleEntry].self) {
        state.update { $0.dubAiring = list }
      }
    }
    if scheduleChanged {
      await findNewNotifications()
      await findNewDelayedEpisodes()
    }
    var updated: [String] = []
    for feed in ReleaseFeed.allCases {
      let differs = manifest.previous?.value(feed, schedule: false) != manifest.current?.value(feed, schedule: false)
      guard manifest.force || differs else { continue }
      if let list = try? await feedChanged(feed, schedule: false, manifest: manifest, as: [AiredFeedEntry].self) {
        state.update { value in
          value.aired[feed] = list
          value.pageCache = value.pageCache.filter { !$0.key.hasPrefix(feed.rawValue + "-") }
          if feed == .dub { value.dubCounts = nil }
        }
        updated.append(feed.rawValue)
      }
    }
    if !updated.isEmpty {
      let feeds = updated
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: AnimeScheduleService.feedsChanged, object: nil, userInfo: ["feeds": feeds])
      }
      // The "Episode N is out" notifications must not depend on the home rows being on screen.
      await checkNewReleases()
    }
  }

  /// Release notifications without the UI (background refresh, manifest polling): the episodes each feed got since
  /// its last check are resolved on AniList and notified like the home rows do (`recentEpisodes`).
  func checkNewReleases() async {
    var feeds: [ReleaseFeed] = [.sub, .dub]
    if AppSettings.shared.values.adult == "hentai" { feeds.append(.hentai) }
    for feed in feeds {
      let entries = await airedList(feed)
      guard !entries.isEmpty else { continue }
      let lastNotified = ReleaseNotifyStore.shared.last(feed)
      var fresh: [Int] = []
      if lastNotified > 0 {
        let threshold = Date(timeIntervalSince1970: lastNotified)
        let recent = entries.filter { ($0.airedDate ?? .distantPast) >= threshold || ($0.addedDate ?? .distantPast) >= threshold }
          .sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        fresh = Array(NSOrderedSet(array: recent.compactMap { $0.id }).compactMap { $0 as? Int }.prefix(300))
        // Nothing new: the last check time stays (it only moves when something was notified).
        if fresh.isEmpty { continue }
      }
      var byId: [Int: Media] = [:]
      if !fresh.isEmpty {
        var variables = AniListVariables()
        variables.sort = nil
        variables.id = fresh
        // AniList unreachable: nothing is notified and the last check time stays, so it is tried again.
        guard let medias = try? await AniListService.shared.searchAllIDs(variables) else { continue }
        for media in medias {
          if let id = media.anilistId { byId[id] = media }
        }
      }
      await notifyReleases(feed, entries: entries, slice: [], byId: byId, missedIds: Set(fresh), lastNotified: lastNotified)
    }
  }

  // MARK: - isSubbedProgress

  /// True when the user's progress is ahead of the dub (used by preferDubs to pick sub or dub).
  func isSubbedProgress(_ media: Media?) async -> Bool {
    guard let media else { return true }
    let dubAiring = await dubAiringList()
    let dubAired = await airedList(.dub)
    return Self.isSubbedProgress(media, dubAiring: dubAiring, dubAired: dubAired)
  }

  static func isSubbedProgress(_ media: Media, dubAiring: [DubScheduleEntry], dubAired: [AiredFeedEntry]) -> Bool {
    if media.status == .notYetReleased { return false }
    let progress = media.listEntry?.progress ?? 0
    if progress == 0 { return false }
    let matches: (Int?, Int?) -> Bool = { id, idMal in
      (id != nil && id == media.anilistId) || (idMal != nil && idMal == media.malId)
    }
    let dubbedEntry = dubAiring.first { matches($0.anime?.id, $0.anime?.idMal) }
    let nodes = dubbedEntry?.anime?.nodes ?? []
    if nodes.isEmpty {
      let aired = dubAired.filter { matches($0.id, $0.idMal) }
      if aired.isEmpty { return true }
      let numbers = aired.map { $0.episode?.aired ?? 0 }
      let hasZero = numbers.contains(0)
      let maxAired = numbers.max() ?? 0
      return progress > (hasZero ? maxAired + 1 : maxAired)
    }
    let last = nodes[nodes.count > 1 ? nodes.count - 1 : 0]
    let zero = (dubbedEntry?.anime?.zeroEpisode ?? false) ? 1 : 0
    return (progress - zero) > (last.episode - (last.airingAt <= Date() ? 0 : 1))
  }

  // MARK: - Recent Subs / Dubs / Hentai (getMediaForRSS)

  /// One page of an episode feed, with release notifications for the new episodes.
  func recentEpisodes(_ feed: ReleaseFeed, page: Int = 1, perPage: Int = 50) async throws -> (items: [EpisodeFeedItem], hasNextPage: Bool) {
    let settings = AppSettings.shared.values
    if feed == .hentai && settings.adult != "hentai" { return ([], false) }
    var entries = await airedList(feed)
    if settings.preferDubs {
      _ = await MALDubsService.shared.lists()
      let dubAiring = await dubAiringList()
      let dubAired = await airedList(.dub)
      entries = entries.filter { entry in
        guard let id = entry.id, let media = MediaStore.shared.anilist(id) else { return true }
        let watching = media.listEntry?.status == .current || media.listEntry?.status == .repeating
        if media.status == .finished && !watching { return true }
        if !MALDubsService.shared.isDubbed(malId: entry.idMal) { return true }
        let subbed = Self.isSubbedProgress(media, dubAiring: dubAiring, dubAired: dubAired)
        return feed == .dub ? !subbed : subbed
      }
    }
    let start = max(0, (page - 1) * perPage)
    let end = min(entries.count, page * perPage)
    let slice = start < end ? Array(entries[start..<end]) : []
    let ids = slice.compactMap { $0.id }
    let hasNextPage = ids.count == perPage
    if ids.isEmpty { return ([], false) }

    var hasher = Hasher()
    hasher.combine(entries)
    let signature = hasher.finalize()
    let cacheKey = "\(feed.rawValue)-\(page)-\(perPage)"
    if let cached = state.get().pageCache[cacheKey], cached.signature == signature {
      return (cached.items, cached.hasNextPage)
    }

    let lastNotified = ReleaseNotifyStore.shared.last(feed)
    var missedIds: [Int] = []
    if lastNotified > 0 {
      let threshold = Date(timeIntervalSince1970: lastNotified)
      missedIds = entries.filter { entry in
        guard let id = entry.id, !ids.contains(id) else { return false }
        return (entry.airedDate ?? .distantPast) >= threshold || (entry.addedDate ?? .distantPast) >= threshold
      }
      .sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
      .prefix(300)
      .compactMap { $0.id }
    }
    var variables = AniListVariables()
    variables.sort = nil
    variables.id = Array(NSOrderedSet(array: ids + missedIds).compactMap { $0 as? Int })
    let medias = try await AniListService.shared.searchAllIDs(variables)
    var byId: [Int: Media] = [:]
    for media in medias {
      if let id = media.anilistId { byId[id] = media }
    }
    let feedItems: [EpisodeFeedItem] = slice.compactMap { entry in
      guard let id = entry.id, let media = byId[id] else { return nil }
      let last = entry.episode?.airedLast
      let first = entry.episode?.aired ?? 1
      return EpisodeFeedItem(media: media, episode: first, date: entry.airedDate ?? Date(), dub: feed == .dub, episodeTitle: nil, thumbnail: nil, summary: nil, lastEpisode: (last ?? 0) > first ? last : nil)
    }
    let results = await withEpisodeMetadata(feedItems)

    await notifyReleases(feed, entries: entries, slice: slice, byId: byId, missedIds: Set(missedIds), lastNotified: lastNotified)

    state.update { value in
      value.pageCache[cacheKey] = PageCacheEntry(signature: signature, items: results, hasNextPage: hasNextPage)
    }
    return (results, hasNextPage)
  }

  /// structureResolveResults: adds the episode title / thumbnail (getEpisodeMetadataForMedia).
  private func withEpisodeMetadata(_ items: [EpisodeFeedItem]) async -> [EpisodeFeedItem] {
    await withTaskGroup(of: (Int, EpisodeFeedItem).self) { group in
      for (offset, item) in items.enumerated() {
        group.addTask {
          var copy = item
          let metadata = await AnimeMappingsService.shared.episodeMetadata(for: item.media)
          if let episode = metadata[String(item.episode)] {
            copy.episodeTitle = episode.title["en"] ?? episode.title["x-jat"] ?? episode.title["ja"] ?? episode.title["jp"]
            copy.thumbnail = URL.lenient(episode.image)
            copy.summary = episode.summary ?? episode.overview
          }
          return (offset, copy)
        }
      }
      var collected: [(Int, EpisodeFeedItem)] = []
      for await pair in group { collected.append(pair) }
      return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
  }

  private func notifyReleases(_ feed: ReleaseFeed, entries: [AiredFeedEntry], slice: [AiredFeedEntry], byId: [Int: Media], missedIds: Set<Int>, lastNotified passedLastNotified: Double) async {
    let settings = AppSettings.shared.values
    if feed == .hentai && settings.adult != "hentai" { return }
    // One pass per feed at a time (home rows and background check); a pass that started from an older check time
    // than the stored one would notify the same episodes again.
    let acquired = notifying.update { running -> Bool in running.insert(feed).inserted }
    guard acquired else { return }
    defer { notifying.update { _ = $0.remove(feed) } }
    let lastNotified = max(passedLastNotified, ReleaseNotifyStore.shared.last(feed))
    let threshold = Date(timeIntervalSince1970: lastNotified)
    var combined: [AiredFeedEntry] = slice
    for entry in entries {
      guard let id = entry.id, missedIds.contains(id) else { continue }
      if slice.contains(where: { $0.id == id && $0.episode?.aired == entry.episode?.aired }) { continue }
      combined.append(entry)
    }
    let newReleases = combined.filter { entry in
      guard let id = entry.id, byId[id] != nil else { return false }
      return (entry.airedDate ?? .distantPast) >= threshold || (entry.addedDate ?? .distantPast) >= threshold
    }
    let notifyStatuses = settings.releasesNotify
    let notOnList = ServiceSettingsExtras.releasesNotifyNotOnList
    if !newReleases.isEmpty && (!notifyStatuses.isEmpty || notOnList) && lastNotified > 0 {
      let dubAiring = await dubAiringList()
      let dubAired = await airedList(.dub)
      for entry in newReleases {
        guard let id = entry.id, let media = byId[id] else { continue }
        let listStatus = media.listEntry?.status
        let notify = (listStatus == nil && notOnList) || (listStatus.map { notifyStatuses.contains($0) } ?? false)
        let watching = listStatus == .current || listStatus == .repeating
        let dubOk = feed == .dub || !settings.preferDubs || (media.status == .finished && !watching) || !MALDubsService.shared.isDubbed(malId: media.malId) || Self.isSubbedProgress(media, dubAiring: dubAiring, dubAired: dubAired)
        guard notify && dubOk && media.format != .music else { continue }
        let aired = entry.episode?.aired ?? 1
        let isMovie = media.format == .movie
        let finale = media.episodes == aired
        let region = feed == .dub ? "the United States" : "Japan"
        let start = isMovie ? "The Movie" : "\(finale ? "The wait is over! " : "")Episode \(aired)"
        let ending: String
        if !isMovie && finale {
          ending = "this season should be available to binge soon!"
        } else if !isMovie {
          ending = "it should be available soon."
        } else {
          ending = "if this is a theatrical release it will likely be a few months before it is available for streaming."
        }
        let notification = MediaNotification.make(media: media, message: "\(start) (\(feed.rawValue)) is out in \(region), \(ending)", episode: aired, timestamp: entry.addedDate ?? Date(), dub: feed == .dub, action: .play)
        AppNotificationsService.dispatch(notification)
      }
    }
    if !newReleases.isEmpty || lastNotified <= 1 {
      ReleaseNotifyStore.shared.setLast(feed, Date().timeIntervalSince1970)
    }
  }

  // MARK: - Announcements (findNewNotifications)

  func findNewNotifications() async {
    let settings = AppSettings.shared.values
    for feed in [ReleaseFeed.dub, ReleaseFeed.sub, ReleaseFeed.hentai] {
      if feed == .hentai && settings.adult != "hentai" { return }
      let setting: String
      switch feed {
      case .dub: setting = settings.dubAnnounce
      case .sub: setting = settings.subAnnounce
      case .hentai: setting = ServiceSettingsExtras.hentaiAnnounce
      }
      let announced = Set(ReleaseNotifyStore.shared.announced(feed))
      var candidates: [ScheduleMedia] = []
      if feed == .dub {
        candidates = await dubAiringList().filter { $0.unaired == true }.compactMap { $0.anime }
      } else {
        candidates = await subAiringList().filter { $0.unaired == true }
      }
      let fresh = candidates.filter { media in
        guard let id = media.id, !announced.contains(id) else { return false }
        let hentai = media.genres?.contains("Hentai") ?? false
        return feed == .hentai ? hentai : !hentai
      }
      if fresh.isEmpty { continue }
      if setting == "none" { continue }
      var variables = AniListVariables()
      variables.sort = nil
      variables.id = fresh.compactMap { $0.id }
      _ = try? await AniListService.shared.searchAllIDs(variables)
      for scheduled in fresh {
        guard let id = scheduled.id else { continue }
        let media = await AniListService.shared.requestMedia(id: id)
        let notify = ReleaseNotifyStore.shared.last(feed) > 0 && (setting == "all" || isFollowing(media))
        if notify, let media, media.format != .music {
          let airingDate = scheduled.nodes.first?.airingAt ?? Date()
          let message = (feed == .dub ? "A dub has just been" : "Was recently") + " announced for " + ServiceDates.longString(airingDate) + "!"
          let notification = MediaNotification.make(media: media, message: message, episode: nil, timestamp: Date().addingTimeInterval(-5), dub: feed == .dub, action: .view)
          AppNotificationsService.dispatch(notification)
        }
        ReleaseNotifyStore.shared.addAnnounced(feed, id: id)
      }
    }
  }

  /// isFollowing: a relation of the media is on the user's list (watching, rewatching, completed, paused, planning).
  private func isFollowing(_ media: Media?) -> Bool {
    guard let media, let lists = ServiceListOverlay.lists else { return false }
    let statuses: Set<ListStatus> = [.current, .repeating, .completed, .paused, .planning]
    let relationIds = MediaStore.shared.extras(for: media).relationEdges.map { $0.id }
    if relationIds.isEmpty { return false }
    let items = lists.items.filter { statuses.contains($0.status) }
    if lists.service == .anilist {
      let ids = Set(items.compactMap { $0.anilistId })
      return relationIds.contains { ids.contains($0) }
    }
    let malIds = Set(items.compactMap { $0.malId })
    return relationIds.contains { relation in
      guard let malId = MediaStore.shared.anilist(relation)?.malId else { return false }
      return malIds.contains(malId)
    }
  }

  // MARK: - Delayed dubs (findNewDelayedEpisodes)

  func findNewDelayedEpisodes() async {
    let now = Date()
    let notified = Set(ReleaseNotifyStore.shared.delayedDubs())
    var delayed: [(entry: DubScheduleEntry, episode: Int, key: String)] = []
    for entry in await dubAiringList() {
      guard let from = ServiceDates.parse(entry.delayedFrom), let until = ServiceDates.parse(entry.delayedUntil), from <= now, until > now,
            let id = entry.anime?.id, let last = entry.episodeNumber else { continue }
      let first = entry.subtractedEpisodeNumber ?? last
      guard first <= last else { continue }
      for episode in first...last {
        let key = "\(id):\(episode):\(entry.delayedUntil ?? "")"
        if !notified.contains(key) { delayed.append((entry, episode, key)) }
      }
    }
    if delayed.isEmpty { return }
    var variables = AniListVariables()
    variables.sort = nil
    variables.id = Array(Set(delayed.compactMap { $0.entry.anime?.id }))
    _ = try? await AniListService.shared.searchAllIDs(variables)
    let settings = AppSettings.shared.values
    for item in delayed {
      guard let id = item.entry.anime?.id else { continue }
      let media = await AniListService.shared.requestMedia(id: id)
      let status = media?.listEntry?.status
      let notify = ReleaseNotifyStore.shared.last(.dub) > 0 && ((status == nil && ServiceSettingsExtras.releasesNotifyNotOnList) || (status.map { settings.releasesNotify.contains($0) } ?? false))
      if notify, let media, media.format != .music {
        let until: String
        if item.entry.delayedIndefinitely == true && !(item.entry.status?.uppercased().contains("FINISHED") ?? false) {
          until = "further notice, production has been suspended"
        } else if item.entry.delayedIndefinitely == true {
          until = "further notice, this is determined to be a partial dub so this episode will likely not be dubbed"
        } else {
          until = ServiceDates.parse(item.entry.delayedUntil).map { ServiceDates.longString($0) } ?? "further notice"
        }
        var notification = MediaNotification.make(media: media, message: "Episode \(item.episode) has been delayed until \(until)!", episode: item.episode, timestamp: Date().addingTimeInterval(-5), dub: true, action: .view)
        notification.delayed = true
        AppNotificationsService.dispatch(notification)
      }
      ReleaseNotifyStore.shared.addDelayedDub(item.key)
    }
  }

  // MARK: - Schedule page (fetchAllScheduleEntries)

  /// Airing schedule of the week (anime on page 1) mixed with western shows (TMDB on the air) and upcoming movies
  /// (theatrical and digital releases), sorted by air time. The "Release" filter picks episodes and / or movies;
  /// asking for movies lists them even with the Anime source, which has no movie releases of its own.
  func scheduleEntries(_ filter: ScheduleFilter, page: Int = 1) async throws -> (items: [AiringEpisode], hasNextPage: Bool) {
    async let movieLookup = movieEntries(filter, page: page)
    var anime: [AiringEpisode] = []
    var western: [AiringEpisode] = []
    var westernHasNext = false
    if filter.release.episodes && filter.western != true && page == 1 {
      anime = (try? await animeSchedule(filter)) ?? []
    }
    if filter.release.episodes && filter.western != false {
      let result = await TMDBService.shared.schedule(page: page)
      westernHasNext = result.hasNextPage
      western = result.entries.map { AiringEpisode(media: $0.media, episode: $0.airing.episode, airingAt: $0.airing.airingAt) }
    }
    let (movies, moviesHasNext) = await movieLookup
    let now = Date()
    var seen = Set<String>()
    let combined = (anime + western + movies).filter { item in
      if seen.contains(item.media.id) || item.airingAt <= now { return false }
      seen.insert(item.media.id)
      return true
    }.sorted { $0.airingAt < $1.airingAt }
    return (combined, westernHasNext || moviesHasNext)
  }

  /// Upcoming movies of the schedule (getMovieSchedule), none for the dub schedule or the episodes only filter.
  private func movieEntries(_ filter: ScheduleFilter, page: Int) async -> ([AiringEpisode], Bool) {
    let release = filter.release
    guard release.theatrical || release.digital, filter.western != false || !release.episodes, !filter.dubs else { return ([], false) }
    let result = await TMDBService.shared.movieSchedule(page: page, theatrical: release.theatrical, digital: release.digital)
    let items = result.entries.map { entry in
      AiringEpisode(media: entry.media, episode: 1, airingAt: entry.release.date, releaseLabel: entry.release.label)
    }
    return (items, result.hasNextPage)
  }

  private func animeSchedule(_ filter: ScheduleFilter) async throws -> [AiringEpisode] {
    var nodesById: [Int: [AiringNode]] = [:]
    var dubEntries: [Int: DubScheduleEntry] = [:]
    var ids: [(id: Int, idMal: Int?)] = []
    if filter.dubs {
      for entry in await dubAiringList() {
        guard let media = entry.anime, let id = media.id else { continue }
        if dubEntries[id] == nil { dubEntries[id] = entry }
        ids.append((id, media.idMal))
      }
    } else {
      for media in await subAiringList() {
        guard let id = media.id else { continue }
        nodesById[id] = media.nodes
        ids.append((id, media.idMal))
      }
    }
    if (filter.hideMyAnime || filter.showMyAnime), let lists = ServiceListOverlay.lists {
      let statuses = Set(filter.listStatuses)
      let matching = lists.items.filter { statuses.contains($0.status) }
      if lists.service == .anilist {
        let userIds = Set(matching.compactMap { $0.anilistId })
        ids = ids.filter { filter.hideMyAnime ? !userIds.contains($0.id) : userIds.contains($0.id) }
      } else {
        let userIds = Set(matching.compactMap { $0.malId })
        ids = ids.filter { pair in
          let onList = pair.idMal.map { userIds.contains($0) } ?? false
          return filter.hideMyAnime ? !onList : onList
        }
      }
    }
    if ids.isEmpty { return [] }
    var variables = AniListVariables()
    variables.sort = nil
    variables.id = ids.map { $0.id }
    if !filter.formats.isEmpty { variables.format = filter.formats }
    if !filter.genres.isEmpty { variables.genre = filter.genres }
    if !filter.excludedGenres.isEmpty { variables.genreNot = filter.excludedGenres }
    if !filter.tags.isEmpty { variables.tag = filter.tags }
    if !filter.excludedTags.isEmpty { variables.tagNot = filter.excludedTags }
    let medias = try await AniListService.shared.searchAllIDs(variables)
    let now = Date()
    var result: [AiringEpisode] = []
    var seen = Set<Int>()
    for media in medias {
      guard let id = media.anilistId, !seen.contains(id) else { continue }
      seen.insert(id)
      var nodes: [AiringNode]
      var suspended = false
      if filter.dubs {
        guard let entry = dubEntries[id] else { continue }
        if entry.delayedIndefinitely == true && (entry.status?.uppercased().contains("FINISHED") ?? false) { continue }
        suspended = entry.delayedIndefinitely == true
        let numberOfEpisodes = entry.subtractedEpisodeNumber.map { (entry.episodeNumber ?? 0) - $0 } ?? 1
        nodes = entry.anime?.nodes ?? []
        var predict = false
        let blocked = numberOfEpisodes > 4 && entry.unaired != true
        if !nodes.isEmpty {
          predict = nodes.allSatisfy { $0.airingAt <= now }
          if predict && !blocked {
            let latestEpisode = nodes.map { $0.episode }.max() ?? 0
            let latestDate = nodes.map { $0.airingAt }.max() ?? now
            let offset: TimeInterval = entry.delayedIndefinitely == true ? 6 * 365 * 24 * 3600 : 7 * 24 * 3600
            nodes.insert(AiringNode(episode: latestEpisode + 1, airingAt: latestDate.addingTimeInterval(offset)), at: 0)
          }
        }
        if let first = nodes.first, let total = media.episodes, first.episode > total { continue }
        if predict && blocked { continue }
        if nodes.isEmpty { continue }
      } else {
        nodes = nodesById[id] ?? MediaStore.shared.extras(for: media).airingSchedule
      }
      guard let next = AnimeHelpers.nextAiring(nodes, now: now) else { continue }
      // episode() of anime.js: "Episode a ~ b" when several episodes air at the same time ("Episode a is" when suspended).
      let sameTime = nodes.filter { $0.airingAt == next.airingAt }.map { $0.episode }
      let last = sameTime.max() ?? next.episode
      let range: Int? = (!suspended && nodes.count > 1 && last > next.episode) ? last : nil
      result.append(AiringEpisode(media: media, episode: next.episode, airingAt: next.airingAt, lastEpisode: range, delayedIndefinitely: suspended))
    }
    return result
  }

  /// Dub airing info of one media (EpisodeList dubbedEpisode / airingAt with hideSubs).
  func dubEntry(for media: Media) async -> DubScheduleEntry? {
    guard let id = media.anilistId else { return nil }
    return await dubAiringList().first { $0.anime?.id == id }
  }

  // MARK: - Episode list dub rows (dubbedEpisode of EpisodeList.svelte)

  /// Dub / Sub airing rows of the details episode list, keyed by episode number. Empty unless the Card Audio
  /// setting is on (dubbedEpisode returns nothing without it).
  func dubEpisodeAirings(for media: Media, episodes: [Int]) async -> [Int: DubEpisodeAiring] {
    guard ServiceSettingsExtras.cardAudio, media.source == .anilist, media.anilistId != nil else { return [:] }
    let entry = await dubEntry(for: media)
    let id = media.anilistId
    let aired = await airedList(.dub).filter { $0.id != nil && $0.id == id }
    let lists = await MALDubsService.shared.lists()
    let incomplete = media.malId.map { lists.incomplete.contains($0) } ?? false
    let dubMedia = media.malId.map { lists.dubbed.contains($0) || lists.incomplete.contains($0) } ?? false
    let now = Date()
    var result: [Int: DubEpisodeAiring] = [:]
    for episode in episodes {
      if let value = Self.dubbedEpisode(episode, media: media, entry: entry, aired: aired, incomplete: incomplete, dubMedia: dubMedia, now: now) {
        result[episode] = value
      }
    }
    return result
  }

  /// dubbedEpisode(i, media) for one episode. `aired` = the dub episode feed entries of this media.
  static func dubbedEpisode(_ episode: Int, media: Media, entry: DubScheduleEntry?, aired: [AiredFeedEntry], incomplete: Bool, dubMedia: Bool, now: Date = Date()) -> DubEpisodeAiring? {
    let episodeEntry = aired.first { $0.episode?.aired == episode }
    if let entry, episodeEntry == nil {
      let nodes = entry.anime?.nodes ?? []
      let airingEntry = nodes.first { $0.episode == episode }
      let byIndex: AiringNode? = (episode >= 1 && episode - 1 < nodes.count) ? nodes[episode - 1] : nil
      let airingSchedule = airingEntry ?? byIndex ?? nodes.first
      let delayedFrom = ServiceDates.parse(entry.delayedFrom)
      let delayedUntil = ServiceDates.parse(entry.delayedUntil)
      let indefinitely = entry.delayedIndefinitely == true
      let firstNode = nodes.first
      func isDelayed(_ date: Date?) -> Bool {
        guard let date else { return false }
        if indefinitely { return true }
        guard let until = delayedUntil, until >= date, until > now else { return false }
        if let from = delayedFrom, from > date { return true }
        if until == date { return true }
        if let from = delayedFrom, from <= date, let firstNode, entry.episodeNumber == firstNode.episode, until == firstNode.airingAt { return true }
        return false
      }
      let delayed = isDelayed(ServiceDates.parse(entry.episodeDate)) || (airingEntry != nil && isDelayed(airingSchedule?.airingAt))
      let subtracted = entry.subtractedEpisodeNumber ?? 0
      let numberOfEpisodes = subtracted != 0 ? subtracted : 1
      let delayText = (entry.delayedText?.isEmpty ?? true) ? "Delayed" : (entry.delayedText ?? "Delayed")
      if let episodeDate = entry.episodeDate, !episodeDate.isEmpty, let number = entry.episodeNumber, number <= episode {
        guard let base = airingSchedule?.airingAt ?? ServiceDates.parse(episodeDate) else { return nil }
        let weeks = number >= episode ? 0 : episode - number
        let airDate = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: base) ?? base
        let text: String
        if indefinitely {
          text = "Suspended"
        } else if episode > number && numberOfEpisodes > 4 && entry.unaired != true {
          text = "In Production"
        } else {
          text = ServiceText.since(airDate) + (delayed ? " (\(delayText))" : "")
        }
        return DubEpisodeAiring(airdate: airDate, text: text, delayed: delayed)
      } else if let schedule = airingSchedule, schedule.episode <= episode {
        return DubEpisodeAiring(airdate: schedule.airingAt, text: ServiceText.since(schedule.airingAt) + (delayed ? " (\(delayText))" : ""), delayed: delayed && !indefinitely)
      }
      return DubEpisodeAiring(airdate: now, text: "Finished", delayed: false)
    }
    if let episodeEntry {
      let date = ServiceDates.parse(episodeEntry.episode?.airedAt)
      return DubEpisodeAiring(airdate: date, text: date.map { ServiceText.since($0) } ?? "", delayed: false)
    }
    if incomplete && aired.contains(where: { $0.episode?.aired == 1 }) {
      return DubEpisodeAiring(airdate: nil, text: "Not Planned", delayed: true, notPlanned: true)
    }
    if entry == nil && (media.seasonYear ?? 0) >= ServiceDates.gregorian.component(.year, from: now) && dubMedia {
      return DubEpisodeAiring(airdate: nil, text: "In Production", delayed: false)
    }
    return nil
  }
}

/// Dub airing state of one episode of the details episode list (dubbedEpisode of EpisodeList.svelte).
struct DubEpisodeAiring: Hashable {
  var airdate: Date?
  var text: String
  var delayed: Bool
  var notPlanned: Bool = false
}
