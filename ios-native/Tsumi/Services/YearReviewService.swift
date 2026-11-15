import Foundation
import Observation
import UIKit

// Year in Review data, port of common/modules/yearreview/yearreview.js: AniList list activities of the year
// (paged, createdAt bounds), list entries and the progress before the year, with Retry-After / X-RateLimit
// backoff (AniList is sometimes degraded to 30 requests / minute); cached per user and year in DiskCache and
// refreshed incrementally for the current year; plus the local watch history of TMDB shows / movies.
// Statistics: YearReviewStats.swift. Screen: UI/YearReview/.

/// Who can see a review.
struct YearReviewAccount: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case anilist
    case mal
    case none
  }

  var kind: Kind
  var userId: Int
  var name: String
  var avatar: URL?
  var token: String

  static func current() -> YearReviewAccount {
    guard let profile = AccountStore.shared.current else {
      return YearReviewAccount(kind: .none, userId: 0, name: "", avatar: nil, token: "")
    }
    if profile.isAniList {
      return YearReviewAccount(kind: .anilist, userId: profile.viewer.id, name: profile.viewer.name, avatar: profile.viewer.avatar, token: profile.token)
    }
    return YearReviewAccount(kind: .mal, userId: profile.viewer.id, name: profile.viewer.name, avatar: profile.viewer.avatar, token: "")
  }
}

/// Loading state shown by the screen.
struct YearReviewProgress: Equatable, Sendable {
  var message: String
  var fraction: Double
  /// Seconds left before the next request (AniList rate limit), 0 when not waiting.
  var wait: Int = 0
}

typealias YearReviewProgressHandler = @Sendable (YearReviewProgress) async -> Void

/// Cached AniList data of one year.
struct YearReviewDataset: Codable {
  var version: Int
  var year: Int
  var userId: Int
  var fetchedAt: Int
  var activities: [YearReviewActivity]
  var media: [Int: YearReviewMedia]
  var entries: [YearReviewEntry]
  /// Progress before the year of the titles that needed it.
  var prior: [Int: Int]
  /// Titles already looked up (with or without a result).
  var priorChecked: [Int]
}

/// Cached list entries of the user (they also give the years of the picker).
struct YearReviewEntriesCache: Codable {
  var version: Int
  var fetchedAt: Int
  var entries: [YearReviewEntry]
  var media: [Int: YearReviewMedia]
}

/// One title of the local history section, resolved for display.
struct YearReviewLocalItem: Hashable, Identifiable {
  var key: String
  var title: String
  var cover: URL?
  var isMovie: Bool
  var episodes: Int
  var minutes: Int
  var id: String { key }
}

struct YearReviewResult {
  var year: Int
  var stats: YearReviewStats
  var media: [Int: YearReviewMedia]
  var fetchedAt: Date
  /// The refresh failed: the last cached data is shown.
  var stale: Bool
  var local: YearReviewLocalStats
  var localItems: [YearReviewLocalItem]

  func media(_ id: Int?) -> YearReviewMedia {
    guard let id, let value = media[id] else {
      return YearReviewMedia(id: id ?? 0, title: YearReviewCalc.unknownTitle)
    }
    return value
  }
}

// MARK: - Transport

/// Spaces the review's own requests (they do not go through AniListService's limiter).
actor YearReviewPacer {
  static let shared = YearReviewPacer()
  private var next = Date.distantPast

  func wait(spacing: TimeInterval) async {
    let now = Date()
    let target = max(now, next)
    next = target.addingTimeInterval(spacing)
    let delay = target.timeIntervalSince(now)
    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
  }
}

enum YearReviewAPI {
  static let version = 1

  static let mediaFields = "id title { userPreferred english romaji } coverImage { extraLarge large color } bannerImage format episodes duration genres"

  static let entriesQuery = """
  query ($userId: Int) {
    MediaListCollection(userId: $userId, type: ANIME, forceSingleCompletedList: true) {
      lists {
        entries {
          status score(format: POINT_10_DECIMAL) progress repeat updatedAt createdAt
          startedAt { year month day }
          completedAt { year month day }
          media { \(mediaFields) studios { edges { isMain node { name isAnimationStudio } } } }
        }
      }
    }
  }
  """

  static let activitiesQuery = """
  query ($userId: Int, $page: Int, $after: Int, $before: Int) {
    Page(page: $page, perPage: 50) {
      pageInfo { hasNextPage }
      activities(userId: $userId, type: ANIME_LIST, createdAt_greater: $after, createdAt_lesser: $before, sort: ID) {
        ... on ListActivity { id status progress createdAt media { \(mediaFields) } }
      }
    }
  }
  """

  static let priorQuery = """
  query ($userId: Int, $page: Int, $mediaIds: [Int], $before: Int) {
    Page(page: $page, perPage: 50) {
      pageInfo { hasNextPage }
      activities(userId: $userId, type: ANIME_LIST, mediaId_in: $mediaIds, createdAt_lesser: $before, sort: ID_DESC) {
        ... on ListActivity { id status progress createdAt media { id } }
      }
    }
  }
  """

  /// Waits `seconds`, reporting the countdown (rate limit) when `report` is given.
  static func countdown(_ seconds: Int, progress: YearReviewProgress, report: YearReviewProgressHandler?) async throws {
    var left = max(1, seconds)
    while left > 0 {
      try Task.checkCancellation()
      var value = progress
      value.wait = left
      await report?(value)
      try await Task.sleep(nanoseconds: 1_000_000_000)
      left -= 1
    }
    var done = progress
    done.wait = 0
    await report?(done)
  }

  /// One GraphQL request. 429 waits for Retry-After, 5xx and network errors back off, and a nearly exhausted
  /// X-RateLimit-Remaining pauses before the next request.
  static func request(_ query: String, variables: [String: Any], token: String, progress: YearReviewProgress, report: YearReviewProgressHandler?) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    var headers = ["Content-Type": "application/json", "Accept": "application/json"]
    if !token.isEmpty { headers["Authorization"] = "Bearer " + token }
    var failures = 0
    for _ in 0..<10 {
      try Task.checkCancellation()
      guard ServiceNetworkMonitor.shared.isOnline else { throw ServiceError.offline }
      await YearReviewPacer.shared.wait(spacing: 0.7)
      let reply: (Data, HTTPURLResponse)
      do {
        reply = try await HTTP.data(AniListService.endpoint, method: "POST", headers: headers, body: body, timeout: 60, allowErrorStatus: true)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        failures += 1
        if failures > 3 { throw ServiceError.api("Could not reach AniList. Check your connection and try again.") }
        try await countdown(min(5 * (1 << failures), 30), progress: progress, report: nil)
        continue
      }
      let (data, response) = reply
      if response.statusCode == 429 {
        let retryAfter = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
        try await countdown((retryAfter > 0 ? retryAfter : 60) + 1, progress: progress, report: report)
        continue
      }
      if response.statusCode >= 500 {
        failures += 1
        if failures > 3 { throw ServiceError.api("AniList is having trouble (HTTP \(response.statusCode)). Try again later.") }
        try await countdown(min(5 * (1 << failures), 30), progress: progress, report: nil)
        continue
      }
      let json = ServiceJSON.object(data)
      guard (200..<300).contains(response.statusCode), let json, json["data"] is [String: Any] else {
        if let message = AniListService.outageMessage(status: response.statusCode, data: data, json: json) {
          throw ServiceError.api(message)
        }
        throw ServiceError.api(ServiceJSON.errorMessage(json) ?? "AniList returned HTTP \(response.statusCode)")
      }
      if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) }), remaining <= 2 {
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { Double($0) }
        let wait = reset.map { $0 - Date().timeIntervalSince1970 } ?? 20
        try await countdown(Int(min(60, max(1, wait)).rounded(.up)), progress: progress, report: report)
      }
      return json
    }
    throw ServiceError.api("AniList keeps rate limiting requests. Try again in a few minutes.")
  }

  // MARK: Parsing

  static func media(_ dict: [String: Any]) -> YearReviewMedia? {
    guard let id = dict.int("id") else { return nil }
    let title = dict.dict("title")
    let cover = dict.dict("coverImage")
    let edges = (dict.dict("studios")?.array("edges") ?? []).filter { $0.dict("node")?.string("name") != nil }
    let main = edges.filter { $0.bool("isMain") == true }
    let chosen = main.isEmpty ? edges.filter { $0.dict("node")?.bool("isAnimationStudio") == true } : main
    var studios: [String] = []
    for edge in chosen {
      if let name = edge.dict("node")?.string("name"), !studios.contains(name) { studios.append(name) }
    }
    let name = title?.string("userPreferred") ?? title?.string("english") ?? title?.string("romaji") ?? YearReviewCalc.unknownTitle
    return YearReviewMedia(
      id: id,
      title: name,
      cover: cover?.string("extraLarge") ?? cover?.string("large"),
      color: cover?.string("color"),
      banner: dict.string("bannerImage"),
      format: dict.string("format"),
      episodes: dict.int("episodes"),
      duration: dict.int("duration"),
      genres: ServiceJSON.strings(dict, "genres"),
      studios: studios
    )
  }

  private static func fuzzy(_ dict: [String: Any]?) -> FuzzyDate? {
    guard let value = FuzzyDate.parse(dict), value.year != nil else { return nil }
    return value
  }

  static func fetchEntries(account: YearReviewAccount, report: YearReviewProgressHandler?) async throws -> YearReviewEntriesCache {
    let progress = YearReviewProgress(message: "Reading your AniList list…", fraction: 0)
    await report?(progress)
    let json = try await request(entriesQuery, variables: ["userId": account.userId], token: account.token, progress: progress, report: report)
    var entries: [YearReviewEntry] = []
    var media: [Int: YearReviewMedia] = [:]
    let lists = json.dict("data")?.dict("MediaListCollection")?.array("lists") ?? []
    for list in lists {
      for entry in list.array("entries") {
        guard let mediaDict = entry.dict("media"), let parsed = Self.media(mediaDict), media[parsed.id] == nil else { continue }
        media[parsed.id] = parsed
        entries.append(YearReviewEntry(
          mediaId: parsed.id,
          status: entry.string("status") ?? "",
          score: entry.double("score") ?? 0,
          progress: entry.int("progress") ?? 0,
          repeatCount: entry.int("repeat") ?? 0,
          startedAt: fuzzy(entry.dict("startedAt")),
          completedAt: fuzzy(entry.dict("completedAt")),
          updatedAt: entry.int("updatedAt") ?? 0,
          createdAt: entry.int("createdAt") ?? 0
        ))
      }
    }
    return YearReviewEntriesCache(version: version, fetchedAt: Int(Date().timeIntervalSince1970), entries: entries, media: media)
  }

  /// Every ListActivity created in [after + 1, before), page by page.
  static func fetchActivities(account: YearReviewAccount, after: Int, before: Int, start: Int, report: YearReviewProgressHandler?) async throws -> (activities: [YearReviewActivity], media: [Int: YearReviewMedia]) {
    var activities: [YearReviewActivity] = []
    var media: [Int: YearReviewMedia] = [:]
    let span = max(1, Double(min(before, Int(Date().timeIntervalSince1970)) - start))
    var progress = YearReviewProgress(message: "Reading your activity…", fraction: 0.05)
    for page in 1...400 {
      let json = try await request(activitiesQuery, variables: ["userId": account.userId, "page": page, "after": after, "before": before], token: account.token, progress: progress, report: report)
      let pageDict = json.dict("data")?.dict("Page")
      let raw = pageDict?.array("activities") ?? []
      var latest = 0
      for item in raw {
        guard let id = item.int("id"), let mediaDict = item.dict("media"), let parsed = Self.media(mediaDict) else { continue }
        media[parsed.id] = media[parsed.id]?.merged(with: parsed) ?? parsed
        let createdAt = item.int("createdAt") ?? 0
        activities.append(YearReviewActivity(id: id, status: item.string("status") ?? "", progress: item.string("progress"), createdAt: createdAt, mediaId: parsed.id))
        latest = max(latest, createdAt)
      }
      if latest > 0 {
        let month = YearReviewCalc.calendar.component(.month, from: Date(timeIntervalSince1970: TimeInterval(latest))) - 1
        let name = YearReviewCalc.monthNames[min(max(month, 0), 11)]
        progress = YearReviewProgress(message: "Reading your activity… \(name) (\(activities.count) updates)", fraction: min(0.95, max(0.05, Double(latest - start) / span)))
        await report?(progress)
      }
      if pageDict?.dict("pageInfo")?.bool("hasNextPage") != true || raw.isEmpty { break }
    }
    return (activities, media)
  }

  /// Progress before the year of the given titles (newest earlier activity of each).
  static func fetchPrior(account: YearReviewAccount, mediaIds: [Int], before: Int, media: [Int: YearReviewMedia], report: YearReviewProgressHandler?) async throws -> [Int: Int] {
    guard !mediaIds.isEmpty else { return [:] }
    let progress = YearReviewProgress(message: "Checking where you left off last year…", fraction: 0.97)
    await report?(progress)
    var found: [YearReviewPriorActivity] = []
    for page in 1...3 {
      let json = try await request(priorQuery, variables: ["userId": account.userId, "page": page, "mediaIds": mediaIds, "before": before], token: account.token, progress: progress, report: report)
      let pageDict = json.dict("data")?.dict("Page")
      for item in pageDict?.array("activities") ?? [] {
        guard let mediaId = item.dict("media")?.int("id") else { continue }
        found.append(YearReviewPriorActivity(mediaId: mediaId, status: item.string("status") ?? "", progress: item.string("progress")))
      }
      let prior = YearReviewCalc.priorFromActivities(found, media: media)
      if mediaIds.allSatisfy({ prior[$0] != nil }) || pageDict?.dict("pageInfo")?.bool("hasNextPage") != true { break }
    }
    return YearReviewCalc.priorFromActivities(found, media: media)
  }
}

// MARK: - Cache

/// List entries: cached 6 hours, one request shared by the year picker and the review.
actor YearReviewEntriesStore {
  static let shared = YearReviewEntriesStore()
  private static let ttl = 6 * 60 * 60
  private var pending: [Int: Task<YearReviewEntriesCache, Error>] = [:]

  private static func key(_ userId: Int) -> String { "yearReview.v\(YearReviewAPI.version).entries.\(userId)" }

  func load(account: YearReviewAccount, force: Bool, report: YearReviewProgressHandler?) async throws -> YearReviewEntriesCache {
    let key = Self.key(account.userId)
    let cached = await DiskCache.shared.get(key, as: YearReviewEntriesCache.self, allowExpired: true)
    let now = Int(Date().timeIntervalSince1970)
    if !force, let cached, cached.version == YearReviewAPI.version, now - cached.fetchedAt < Self.ttl { return cached }
    if !force, let running = pending[account.userId] { return try await running.value }
    // Not cancelled with the review: one request, shared by the callers and cached.
    let task = Task { () async throws -> YearReviewEntriesCache in
      do {
        let fresh = try await YearReviewAPI.fetchEntries(account: account, report: report)
        await DiskCache.shared.set(key, fresh, ttl: 400 * 24 * 60 * 60)
        return fresh
      } catch {
        if let cached, cached.version == YearReviewAPI.version { return cached }
        throw error
      }
    }
    if !force { pending[account.userId] = task }
    defer { if !force { pending[account.userId] = nil } }
    return try await task.value
  }
}

enum YearReviewLoader {
  private static let day = 24 * 60 * 60
  /// The current year is refreshed (incrementally) after this many seconds.
  private static let currentYearTTL = 3 * 60 * 60
  /// Incremental refreshes re-read this much activity before the last fetch (AniList merges recent activities).
  private static let overlap = 2 * day

  private static func key(_ userId: Int, _ year: Int) -> String { "yearReview.v\(YearReviewAPI.version).review.\(userId).\(year)" }

  private static func isFresh(_ dataset: YearReviewDataset, year: Int) -> Bool {
    let now = Int(Date().timeIntervalSince1970)
    let end = YearReviewCalc.yearBounds(year).end
    if dataset.fetchedAt >= end + overlap { return true }
    let currentYear = YearReviewCalc.calendar.component(.year, from: Date())
    return year >= currentYear && now - dataset.fetchedAt < currentYearTTL
  }

  /// Loads the AniList data of a year (cache first). Returns the dataset and whether it is a stale fallback.
  static func load(year: Int, force: Bool, account: YearReviewAccount, report: YearReviewProgressHandler?) async throws -> (dataset: YearReviewDataset, stale: Bool) {
    let cacheKey = key(account.userId, year)
    var dataset = await DiskCache.shared.get(cacheKey, as: YearReviewDataset.self, allowExpired: true)
    if dataset?.version != YearReviewAPI.version { dataset = nil }
    if !force, let dataset, isFresh(dataset, year: year) { return (dataset, false) }
    do {
      let fresh = try await fetch(year: year, previous: force ? nil : dataset, force: force, account: account, report: report)
      await DiskCache.shared.set(cacheKey, fresh, ttl: 400 * 24 * 60 * 60)
      return (fresh, false)
    } catch {
      // Offline / AniList down: the last cached data of the year is better than nothing.
      if let dataset, !(error is CancellationError), !Task.isCancelled { return (dataset, true) }
      throw error
    }
  }

  private static func relevantEntries(_ entries: [YearReviewEntry], mediaIds: Set<Int>, year: Int) -> [YearReviewEntry] {
    entries.filter { mediaIds.contains($0.mediaId) || $0.startedAt?.year == year || $0.completedAt?.year == year }
  }

  private static func fetch(year: Int, previous: YearReviewDataset?, force: Bool, account: YearReviewAccount, report: YearReviewProgressHandler?) async throws -> YearReviewDataset {
    let bounds = YearReviewCalc.yearBounds(year)
    let entries = try await YearReviewEntriesStore.shared.load(account: account, force: force, report: report)
    try Task.checkCancellation()
    let incremental = previous.map { $0.fetchedAt > bounds.start } ?? false
    let after = incremental ? max(bounds.start - 1, (previous?.fetchedAt ?? 0) - overlap) : bounds.start - 1
    await report?(YearReviewProgress(message: "Reading your activity…", fraction: 0.05))
    let fetched = try await YearReviewAPI.fetchActivities(account: account, after: after, before: bounds.end, start: bounds.start, report: report)

    var byId: [Int: YearReviewActivity] = [:]
    if incremental, let previous {
      for activity in previous.activities { byId[activity.id] = activity }
    }
    for activity in fetched.activities { byId[activity.id] = activity }
    let activities = byId.values.sorted { $0.id < $1.id }
    var mediaIds = Set(activities.map(\.mediaId))
    let yearEntries = relevantEntries(entries.entries, mediaIds: mediaIds, year: year)
    for entry in yearEntries { mediaIds.insert(entry.mediaId) }
    var media: [Int: YearReviewMedia] = [:]
    for id in mediaIds {
      let candidates = [incremental ? previous?.media[id] : nil, fetched.media[id], entries.media[id]].compactMap { $0 }
      guard var merged = candidates.first else { continue }
      for next in candidates.dropFirst() { merged = merged.merged(with: next) }
      media[id] = merged
    }

    var prior = incremental ? (previous?.prior ?? [:]) : [:]
    var checked = Set(incremental ? (previous?.priorChecked ?? []) : [])
    let missing = Array(YearReviewCalc.mediaNeedingPrior(year: year, activities: activities, media: media, entries: yearEntries).filter { !checked.contains($0) }.prefix(100))
    if !missing.isEmpty {
      let found = try await YearReviewAPI.fetchPrior(account: account, mediaIds: missing, before: bounds.start, media: media, report: report)
      for (id, value) in found { prior[id] = value }
      for id in missing { checked.insert(id) }
    }
    return YearReviewDataset(version: YearReviewAPI.version, year: year, userId: account.userId, fetchedAt: Int(Date().timeIntervalSince1970), activities: activities, media: media, entries: yearEntries, prior: prior, priorChecked: Array(checked))
  }

  /// Years of the picker (needs the list entries: one request when they are not cached).
  static func years(account: YearReviewAccount, extra: [Int]) async -> [Int] {
    guard account.kind == .anilist else { return YearReviewCalc.availableYears(entries: [], extra: extra) }
    let entries = (try? await YearReviewEntriesStore.shared.load(account: account, force: false, report: nil))?.entries ?? []
    return YearReviewCalc.availableYears(entries: entries, extra: extra)
  }
}

// MARK: - Local watch history (shows and movies from TMDB)

@MainActor
enum YearReviewLocal {
  static func records() -> [YearReviewLocalRecord] {
    AnimeProgressService.shared.records.compactMap { record in
      guard let key = record.mediaKey, key.hasPrefix("tmdb-") else { return nil }
      return YearReviewLocalRecord(key: key, episode: record.episode, currentTime: record.currentTime, duration: record.safeDuration, updatedAt: record.updatedAt)
    }
  }

  static func years() -> [Int] {
    Array(Set(records().map { YearReviewCalc.calendar.component(.year, from: $0.updatedAt) }))
  }

  /// "tmdb-tv-123" → (123, .tv).
  private static func tmdbId(_ key: String) -> (id: Int, type: TMDBType)? {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let type = TMDBType(rawValue: String(parts[1])), let id = Int(parts[2]) else { return nil }
    return (id, type)
  }

  /// Local history stats of the year, with the titles / posters of the media store (TMDB when missing).
  static func review(year: Int) async -> (stats: YearReviewLocalStats, items: [YearReviewLocalItem]) {
    let stats = YearReviewCalc.computeLocal(records(), year: year)
    var items: [YearReviewLocalItem] = []
    for title in stats.top {
      var media = MediaStore.shared.media(title.key)
      let parsed = tmdbId(title.key)
      if media == nil, let parsed {
        media = await TMDBService.shared.media(id: parsed.id, type: parsed.type)
      }
      items.append(YearReviewLocalItem(
        key: title.key,
        title: media.map { AniListService.shared.title($0) } ?? YearReviewCalc.unknownTitle,
        cover: media?.images.coverLarge ?? media?.images.cover,
        isMovie: media?.isMovie ?? (parsed?.type == .movie),
        episodes: title.episodes,
        minutes: title.minutes
      ))
    }
    return (stats, items)
  }
}

// MARK: - Screen model

@MainActor
@Observable
final class YearReviewModel {
  enum Phase: Equatable {
    case needsAniList
    case malOnly
    case loading
    case loaded
    case failed(String)
  }

  private(set) var account: YearReviewAccount
  private(set) var phase: Phase = .loading
  private(set) var years: [Int]
  private(set) var year: Int
  private(set) var result: YearReviewResult?
  private(set) var progress = YearReviewProgress(message: "Loading…", fraction: 0)
  /// Rendered summary card (ShareLink), prepared once the review is loaded.
  private(set) var shareImage: UIImage?
  private(set) var preparingShare = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var shareTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var started = false

  init(year: Int?) {
    let current = YearReviewCalc.calendar.component(.year, from: Date())
    let initial = year ?? current
    self.year = initial
    years = [initial]
    account = YearReviewAccount.current()
    switch account.kind {
    case .anilist: phase = .loading
    case .mal: phase = .malOnly
    case .none: phase = .needsAniList
    }
  }

  /// First appearance: loads the default year and the years of the picker.
  func start() async {
    guard !started else { return }
    started = true
    guard account.kind == .anilist else { return }
    load(year)
    let offered = await YearReviewLoader.years(account: account, extra: YearReviewLocal.years())
    years = Array(Set(offered + [year])).sorted(by: >)
  }

  func select(_ value: Int) {
    guard value != year || phase != .loaded else { return }
    load(value)
  }

  func refresh() {
    load(year, force: true)
  }

  func cancel() {
    task?.cancel()
    shareTask?.cancel()
    generation += 1
  }

  private func apply(_ value: YearReviewProgress, generation current: Int) {
    guard generation == current else { return }
    progress = value
  }

  private func load(_ target: Int, force: Bool = false) {
    task?.cancel()
    shareTask?.cancel()
    generation += 1
    let current = generation
    year = target
    result = nil
    shareImage = nil
    preparingShare = false
    phase = .loading
    progress = YearReviewProgress(message: "Loading…", fraction: 0)
    let account = self.account
    let report: YearReviewProgressHandler = { [weak self] value in
      await self?.apply(value, generation: current)
    }
    task = Task { [weak self] in
      do {
        let loaded = try await YearReviewLoader.load(year: target, force: force, account: account, report: report)
        let local = await YearReviewLocal.review(year: target)
        guard let self, self.generation == current, !Task.isCancelled else { return }
        let dataset = loaded.dataset
        let stats = YearReviewCalc.compute(year: target, activities: dataset.activities, media: dataset.media, entries: dataset.entries, prior: dataset.prior)
        self.result = YearReviewResult(
          year: target,
          stats: stats,
          media: dataset.media,
          fetchedAt: Date(timeIntervalSince1970: TimeInterval(dataset.fetchedAt)),
          stale: loaded.stale,
          local: local.stats,
          localItems: local.items
        )
        self.phase = .loaded
        self.prepareShareImage()
      } catch {
        guard let self, self.generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// Downloads the covers and renders the summary card for the share sheet.
  private func prepareShareImage() {
    guard let result, result.stats.hasData else { return }
    let current = generation
    let account = self.account
    preparingShare = true
    shareTask = Task { [weak self] in
      let images = await YearReviewShareImages.load(result: result, avatar: account.avatar)
      guard let self, self.generation == current, !Task.isCancelled else { return }
      self.shareImage = YearReviewShareRenderer.render(result: result, account: account, images: images)
      self.preparingShare = false
    }
  }
}
