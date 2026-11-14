import Foundation
import Observation

// Port of common/modules/helper.js (abstraction over AniList vs MyAnimeList: isAuthorized, userLists,
// status / sort mapping, entry updates with profile syncing, automatic progress update after watching,
// getPaginatedMediaList, getFuzzyDate) plus the list parts of anilist.js / myanimelist.js
// (userLists refreshed every 15 minutes, sortListEntries, MAL custom sorts) and of Scoring.svelte
// (save / delete with toasts) and anime.js (setStatus, playMedia start episode).

/// One entry of the user's list (AniList MediaListCollection entry or MyAnimeList animelist node).
struct UserListItem: Codable, Hashable, Identifiable {
  var id: String
  /// AniList: the full media (with its list entry). MyAnimeList: nil (resolved by MAL id when needed).
  var media: Media?
  var anilistId: Int?
  var malId: Int?
  var listEntryId: Int?
  var status: ListStatus
  var progress: Int
  /// 0-10 scale.
  var score: Double
  var repeatCount: Int
  var updatedAt: Date?
  var startedAt: FuzzyDate?
  var completedAt: FuzzyDate?
  var isRewatching: Bool
  var title: String?
  var alternativeTitles: [String]
  var malMediaType: String?
  var malNumEpisodes: Int?
  /// Seconds.
  var malAverageEpisodeDuration: Int?
  var malStartSeason: String?
  var malStartYear: Int?
  var malAiringStatus: String?
  var cover: URL?

  init(id: String, media: Media? = nil, anilistId: Int? = nil, malId: Int? = nil, listEntryId: Int? = nil, status: ListStatus, progress: Int, score: Double, repeatCount: Int, updatedAt: Date? = nil, startedAt: FuzzyDate? = nil, completedAt: FuzzyDate? = nil, isRewatching: Bool = false, title: String? = nil, alternativeTitles: [String] = [], malMediaType: String? = nil, malNumEpisodes: Int? = nil, malAverageEpisodeDuration: Int? = nil, malStartSeason: String? = nil, malStartYear: Int? = nil, malAiringStatus: String? = nil, cover: URL? = nil) {
    self.id = id
    self.media = media
    self.anilistId = anilistId
    self.malId = malId
    self.listEntryId = listEntryId
    self.status = status
    self.progress = progress
    self.score = score
    self.repeatCount = repeatCount
    self.updatedAt = updatedAt
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.isRewatching = isRewatching
    self.title = title
    self.alternativeTitles = alternativeTitles
    self.malMediaType = malMediaType
    self.malNumEpisodes = malNumEpisodes
    self.malAverageEpisodeDuration = malAverageEpisodeDuration
    self.malStartSeason = malStartSeason
    self.malStartYear = malStartYear
    self.malAiringStatus = malAiringStatus
    self.cover = cover
  }

  var listEntry: ListEntry {
    ListEntry(status: status, progress: progress, score: score, repeatCount: repeatCount, updatedAt: updatedAt)
  }

  static func fromAniList(_ media: Media, extras: MediaExtras) -> UserListItem? {
    guard let entry = media.listEntry else { return nil }
    return UserListItem(id: media.id, media: media, anilistId: media.anilistId, malId: media.malId, listEntryId: extras.listEntryId, status: entry.status, progress: entry.progress, score: entry.score ?? 0, repeatCount: entry.repeatCount ?? 0, updatedAt: entry.updatedAt, startedAt: extras.startedAt, completedAt: extras.completedAt, isRewatching: entry.status == .repeating, title: media.title.display(), alternativeTitles: media.title.all, cover: media.images.cover)
  }

  static func fromMAL(_ item: [String: Any]) -> UserListItem? {
    guard let node = item.dict("node"), let malId = node.int("id") else { return nil }
    let rawStatus = node.dict("my_list_status") ?? item.dict("list_status")
    let rewatching = rawStatus?.bool("is_rewatching") ?? false
    guard let listStatus = rawStatus, let status = MALStatusMap.fromMAL(listStatus.string("status"), rewatching: rewatching) else { return nil }
    let alternative = node.dict("alternative_titles")
    var titles: [String] = ServiceJSON.strings(alternative, "synonyms")
    if let english = alternative?.string("en"), !english.isEmpty { titles.append(english) }
    if let japanese = alternative?.string("ja"), !japanese.isEmpty { titles.append(japanese) }
    let season = node.dict("start_season")
    let picture = node.dict("main_picture")
    return UserListItem(id: "mal-\(malId)", malId: malId, status: status, progress: listStatus.int("num_episodes_watched") ?? 0, score: listStatus.double("score") ?? 0, repeatCount: listStatus.int("num_times_rewatched") ?? 0, updatedAt: ServiceDates.parse(listStatus.string("updated_at")), startedAt: FuzzyDate.parse(isoDay: listStatus.string("start_date")), completedAt: FuzzyDate.parse(isoDay: listStatus.string("finish_date")), isRewatching: rewatching, title: node.string("title"), alternativeTitles: titles, malMediaType: node.string("media_type"), malNumEpisodes: node.int("num_episodes"), malAverageEpisodeDuration: node.int("average_episode_duration"), malStartSeason: season?.string("season"), malStartYear: season?.int("year"), malAiringStatus: node.string("status"), cover: URL.lenient(picture?.string("large") ?? picture?.string("medium")))
  }
}

/// The current user's lists.
struct UserLists: Codable, Hashable {
  var service: Viewer.Service
  var userId: Int
  var items: [UserListItem]
  var fetchedAt: Date

  func entries(_ statuses: Set<ListStatus>) -> [UserListItem] {
    items.filter { statuses.contains($0.status) }
  }
}

/// AniList list sorts that only exist on the user's own list (helper.js isUserSort).
enum UserListSorts {
  static let all: Set<String> = ["UPDATED_TIME_DESC", "STARTED_ON_DESC", "FINISHED_ON_DESC", "PROGRESS_DESC", "USER_SCORE_DESC"]

  static func isUserSort(_ sort: String?) -> Bool {
    guard let sort else { return false }
    return all.contains(sort)
  }
}

/// Local filters of getPaginatedMediaList (user list sections, Search page on a list section).
struct ListFilter: Hashable {
  var search: String?
  var genres: [String] = []
  var tags: [String] = []
  var season: String?
  var year: Int?
  var formats: [String] = []
  var formatsNot: [String] = []
  var status: [String] = []
  var statusNot: [String] = []
  var continueWatching: Bool = false
  /// hideSubs: only dubbed media (MAL-Dubs).
  var dubOnly: Bool = false
  var sort: String?
}

@Observable
@MainActor
final class MediaListService {
  static let shared = MediaListService()

  static var userSorts: Set<String> { UserListSorts.all }

  private(set) var lists: UserLists?
  private(set) var isLoading = false
  private(set) var revision = 0
  private(set) var lastError: String?

  @ObservationIgnored private var timerTask: Task<Void, Never>?
  @ObservationIgnored private var started = false

  private init() {}

  var isAuthorized: Bool { AccountStore.shared.isAuthorized }
  var isAniList: Bool { AccountStore.shared.isAniList }
  var isMAL: Bool { AccountStore.shared.isMAL }

  static func isUserSort(_ sort: String?) -> Bool {
    UserListSorts.isUserSort(sort)
  }

  // MARK: - Loading

  /// Loads the cached lists, refreshes them, then refreshes every 15 minutes.
  func start() {
    guard !started else { return }
    started = true
    Task {
      await loadCached()
      await refresh()
    }
    timerTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
        if Task.isCancelled { break }
        await refresh()
      }
    }
  }

  /// Called after a login / profile switch / logout.
  func accountChanged() {
    lists = nil
    ServiceListOverlay.set(nil)
    revision += 1
    Task {
      await loadCached()
      await refresh()
    }
  }

  private var cacheKey: String? {
    guard let current = AccountStore.shared.current else { return nil }
    return "lists.v1." + current.id
  }

  private func loadCached() async {
    guard let key = cacheKey else { return }
    if let cached = await DiskCache.shared.get(key, as: UserLists.self, allowExpired: true), lists == nil {
      apply(cached)
    }
  }

  /// getUserLists of the active client.
  func refresh() async {
    guard let account = AccountStore.shared.current else {
      if lists != nil { apply(nil) }
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let items: [UserListItem]
      if account.isAniList {
        items = try await AniListService.shared.userLists(userId: account.viewer.id)
      } else {
        items = try await MyAnimeListService.shared.userLists(sort: "list_updated_at")
      }
      guard AccountStore.shared.current?.id == account.id else { return }
      let fresh = UserLists(service: account.viewer.service, userId: account.viewer.id, items: Self.sort(items, by: "UPDATED_TIME_DESC"), fetchedAt: Date())
      apply(fresh)
      lastError = nil
      if let key = cacheKey {
        await DiskCache.shared.set(key, fresh, ttl: 14 * 60)
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func apply(_ value: UserLists?) {
    lists = value
    ServiceListOverlay.set(value)
    if value?.service == .myanimelist {
      MediaStore.shared.reapplyOverlay()
    }
    revision += 1
    HomeSectionsService.shared.listsChanged()
  }

  private func persist() {
    guard let key = cacheKey, let lists else { return }
    Task {
      await DiskCache.shared.set(key, lists, ttl: 14 * 60)
    }
  }

  // MARK: - Reads

  func item(for media: Media) -> UserListItem? {
    guard let lists else { return nil }
    if let id = media.anilistId, let item = lists.items.first(where: { $0.anilistId == id }) { return item }
    if lists.service == .myanimelist, let malId = media.malId { return lists.items.first { $0.malId == malId } }
    return nil
  }

  /// List entry of a media (store first, as mediaCache in the Svelte app).
  func entry(for media: Media) -> ListEntry? {
    if let stored = MediaStore.shared.media(media.id) { return stored.listEntry }
    return item(for: media)?.listEntry ?? media.listEntry
  }

  /// Helper.userLists: the items of some statuses, sorted by an AniList list sort.
  func items(_ statuses: [ListStatus], sort: String = "UPDATED_TIME_DESC") -> [UserListItem] {
    let selected = (lists?.items ?? []).filter { statuses.contains($0.status) }
    return Self.sort(selected, by: sort)
  }

  /// sortListEntries / MAL custom sorts: descending, empty values last (PROGRESS_DESC ascending distance).
  static func sort(_ items: [UserListItem], by sort: String) -> [UserListItem] {
    func value(_ item: UserListItem) -> Double {
      switch sort {
      case "STARTED_ON_DESC": return Double(item.startedAt?.sortValue ?? 0)
      case "FINISHED_ON_DESC": return Double(item.completedAt?.sortValue ?? 0)
      case "USER_SCORE_DESC": return item.score
      case "PROGRESS_DESC":
        if let media = item.media { return AnimeHelpers.progressSortValue(media) }
        if item.progress == 0 { return Double.infinity }
        let total = item.malNumEpisodes ?? 0
        if total == 0 { return -Double(item.progress) }
        let distance = total - item.progress
        return distance <= 0 ? -Double.infinity : Double(distance) + Double(item.progress) / 100_000
      default: return item.updatedAt?.timeIntervalSince1970 ?? 0
      }
    }
    if sort == "PROGRESS_DESC" {
      return items.sorted { value($0) < value($1) }
    }
    return items.sorted { lhs, rhs in
      let left = value(lhs)
      let right = value(rhs)
      if left == 0 && right != 0 { return false }
      if right == 0 && left != 0 { return true }
      return left > right
    }
  }

  // MARK: - Dates (getFuzzyDate)

  /// Started today when watching, completed today when completed; fixes start > completion.
  static func fuzzyDates(startedAt: FuzzyDate?, completedAt: FuzzyDate?, status: ListStatus) -> (startedAt: FuzzyDate?, completedAt: FuzzyDate?) {
    let today = FuzzyDate.from(Date())
    var started = (startedAt?.isComplete ?? false) ? startedAt : ((status == .current || status == .repeating) ? today : nil)
    var completed = (completedAt?.isComplete ?? false) ? completedAt : (status == .completed ? today : nil)
    if let start = started?.isoDay, let end = completed?.isoDay, start > end {
      completed = today
      started = FuzzyDate.from(Date().addingTimeInterval(-86400))
    }
    return (started, completed)
  }

  // MARK: - Mutations

  /// Scoring.svelte saveEntry: saves status / progress / score (0-10), with toasts and profile syncing.
  @discardableResult
  func save(_ media: Media, status: ListStatus, progress: Int, score: Double, repeatCount: Int? = nil) async -> Bool {
    guard let account = AccountStore.shared.current else {
      ServiceMessages.shared.post(.error, "Failed to Update List", "You need to be logged in.")
      return false
    }
    let current = MediaStore.shared.media(media.id) ?? media
    let existing = entry(for: current)
    let repeatValue = repeatCount ?? existing?.repeatCount ?? 0
    let maxEpisode = AnimeHelpers.maxEpisode(current)
    let description = "Title: \(AniListService.shared.title(current))\nStatus: \(status.label)\nEpisode: \(progress) / \(maxEpisode > 0 ? String(maxEpisode) : "?")\(score != 0 ? "\nYour Score: \(Self.scoreText(score))" : "")"
    if existing?.status == status && existing?.progress == progress && (existing?.score ?? 0) == score && (existing?.repeatCount ?? 0) == repeatValue {
      ServiceMessages.shared.post(.warning, "No Changes to List", description)
      return false
    }
    let input = makeInput(current, status: status, progress: progress, score: score, repeatCount: repeatValue, account: account)
    let success = await performSave(current, input: input, account: account)
    if success {
      ServiceMessages.shared.post(.success, "List Updated", description)
    } else {
      ServiceMessages.shared.post(.error, "Failed to Update List", description)
    }
    await syncProfiles(current, status: status, progress: progress, score: score, repeatCount: repeatValue, delete: false, description: description, startedAt: input.startedAt, completedAt: input.completedAt)
    return success
  }

  /// Scoring.svelte deleteEntry.
  @discardableResult
  func delete(_ media: Media) async -> Bool {
    guard let account = AccountStore.shared.current else { return false }
    let current = MediaStore.shared.media(media.id) ?? media
    guard entry(for: current) != nil else { return false }
    let description = "\(AniListService.shared.title(current)) has been deleted from your list."
    var success = false
    do {
      if account.isAniList {
        let listEntryId = MediaStore.shared.extras(current.id)?.listEntryId ?? item(for: current)?.listEntryId
        if let listEntryId {
          success = try await AniListService.shared.deleteEntry(listEntryId: listEntryId)
        }
      } else if let malId = current.malId {
        success = try await MyAnimeListService.shared.deleteEntry(malId: malId)
      }
    } catch {
      success = false
    }
    if success {
      MediaStore.shared.setListEntry(current.id, entry: nil)
      removeLocal(current)
      ServiceMessages.shared.post(.warning, "List Updated", description)
      if account.viewer.service == .myanimelist { scheduleMALRefresh() }
    } else {
      ServiceMessages.shared.post(.error, "Failed to Update List", description)
    }
    await syncProfiles(current, status: .current, progress: 0, score: 0, repeatCount: 0, delete: true, description: description)
    return success
  }

  /// anime.js setStatus: changes the status keeping the score / repeat count (no toast).
  @discardableResult
  func setStatus(_ status: ListStatus, media: Media, progress: Int? = nil) async -> Bool {
    guard let account = AccountStore.shared.current else { return false }
    let current = MediaStore.shared.media(media.id) ?? media
    let existing = entry(for: current)
    let input = makeInput(current, status: status, progress: progress ?? existing?.progress ?? 0, score: existing?.score ?? 0, repeatCount: existing?.repeatCount ?? 0, account: account)
    return await performSave(current, input: input, account: account)
  }

  /// Helper.updateEntry: automatic progress update after an episode was watched (playerAutocomplete).
  func updateAfterWatching(_ media: Media, episode: Int?, failed: Bool = false) async {
    guard AccountStore.shared.isAuthorized, media.source == .anilist, let anilistId = media.anilistId else { return }
    if failed {
      ServiceMessages.shared.post(.error, "Failed to Update Progress", "The currently playing media failed to be identified, episode progress will not be updated.")
      return
    }
    let cached = await AniListService.shared.requestMedia(id: anilistId) ?? media
    if cached.status == .cancelled { return }
    let zeroEpisode = await AnimeHelpers.hasZeroEpisode(cached) != nil
    let singleEpisode = ((cached.episodes == nil && (episode == nil || episode == 1)) || (cached.format == .movie && cached.episodes == 1)) ? 1 : 0
    let watched = episode.flatMap { $0 != 0 ? $0 : nil } ?? singleEpisode
    let videoEpisode = watched + (zeroEpisode ? 1 : 0)
    let maxEpisode = AnimeHelpers.maxEpisode(cached)
    let mediaEpisode = maxEpisode > 0 ? maxEpisode : singleEpisode
    guard videoEpisode > 0, mediaEpisode > 0, videoEpisode <= mediaEpisode else { return }
    let existing = entry(for: cached)
    let baseStatus: ListStatus = existing?.status == .repeating ? .repeating : .current
    if let progress = existing?.progress {
      if progress > videoEpisode { return }
      if progress == videoEpisode && videoEpisode != mediaEpisode && singleEpisode == 0 { return }
    }
    var status = baseStatus
    var repeatCount = existing?.repeatCount ?? 0
    if videoEpisode == mediaEpisode && cached.status != .notYetReleased {
      status = .completed
      if existing?.status == .repeating { repeatCount += 1 }
    }
    let score = existing?.score ?? 0
    let changed = existing?.status != status || existing?.progress != videoEpisode || (existing?.repeatCount ?? 0) != repeatCount
    guard changed, let account = AccountStore.shared.current else { return }
    let input = makeInput(cached, status: status, progress: videoEpisode, score: score, repeatCount: repeatCount, account: account)
    let description = "Title: \(AniListService.shared.title(cached))\nStatus: \(status.label)\nEpisode: \(videoEpisode) / \(maxEpisode > 0 ? String(maxEpisode) : "?")\(score != 0 ? "\nYour Score: \(Self.scoreText(score))" : "")"
    let success = await performSave(cached, input: input, account: account)
    if success {
      ServiceMessages.shared.post(.success, "List Updated", description)
    } else {
      ServiceMessages.shared.post(.error, "Failed to Update List", description)
    }
    await syncProfiles(cached, status: status, progress: videoEpisode, score: score, repeatCount: repeatCount, delete: false, description: description, startedAt: input.startedAt, completedAt: input.completedAt)
  }

  /// playMedia: episode to start from (continues after the progress, zero episode aware).
  /// A completed entry is switched to Rewatching with progress 0.
  func startEpisode(for media: Media) async -> Int {
    guard media.source == .anilist else { return 1 }
    let current = MediaStore.shared.media(media.id) ?? media
    let zeroEpisode = await AnimeHelpers.hasZeroEpisode(current) != nil
    var episode = zeroEpisode ? 0 : 1
    if let existing = entry(for: current), existing.progress > 0 {
      if existing.status == .completed {
        await setStatus(.repeating, media: current, progress: 0)
      } else {
        let next = existing.progress + (zeroEpisode ? 0 : 1)
        let playable = AnimeHelpers.maxEpisode(current, playable: true)
        episode = min(playable > 0 ? playable : next, next)
      }
    }
    return episode
  }

  private static func scoreText(_ score: Double) -> String {
    score.rounded() == score ? String(Int(score)) : String(score)
  }

  private func makeInput(_ media: Media, status: ListStatus, progress: Int, score: Double, repeatCount: Int, account: AccountProfile) -> ListEntryInput {
    let extras = MediaStore.shared.extras(for: media)
    let dates = Self.fuzzyDates(startedAt: extras.startedAt ?? item(for: media)?.startedAt, completedAt: extras.completedAt ?? item(for: media)?.completedAt, status: status)
    let raw = account.isAniList ? Int((score * 10).rounded()) : Int(score.rounded())
    return ListEntryInput(anilistId: media.anilistId, malId: media.malId, status: status, progress: progress, scoreRaw: raw, repeatCount: repeatCount, startedAt: dates.startedAt, completedAt: dates.completedAt)
  }

  /// Helper.entry for the current account; updates the store and the local lists.
  private func performSave(_ media: Media, input: ListEntryInput, account: AccountProfile) async -> Bool {
    do {
      if account.isAniList {
        let saved = try await AniListService.shared.saveEntry(input)
        MediaStore.shared.setListEntry(media.id, entry: saved.listEntry) { extras in
          extras.listEntryId = saved.id ?? extras.listEntryId
          extras.startedAt = saved.startedAt
          extras.completedAt = saved.completedAt
        }
        updateLocal(media, entry: saved.listEntry, listEntryId: saved.id, startedAt: saved.startedAt, completedAt: saved.completedAt)
      } else {
        guard let malId = media.malId else { return false }
        let ok = try await MyAnimeListService.shared.saveEntry(malId: malId, input: input)
        guard ok else { return false }
        let entry = ListEntry(status: input.status, progress: input.progress, score: Double(input.scoreRaw), repeatCount: input.repeatCount, updatedAt: Date())
        MediaStore.shared.setListEntry(media.id, entry: entry) { extras in
          extras.startedAt = input.startedAt
          extras.completedAt = input.completedAt
        }
        updateLocal(media, entry: entry, listEntryId: nil, startedAt: input.startedAt, completedAt: input.completedAt)
        scheduleMALRefresh()
      }
      AppNotificationsService.shared.markRead(mediaId: media.anilistId, episode: input.progress, episodes: media.episodes)
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  /// Syncs a change to the other profiles whose "Sync List Entries" switch is on. The entry's dates are the
  /// ones sent for the current account (Scoring.svelte / helper.js `...variables`), so a synced profile keeps
  /// the real start / completion dates instead of getting today.
  private func syncProfiles(_ media: Media, status: ListStatus, progress: Int, score: Double, repeatCount: Int, delete: Bool, description: String, startedAt: FuzzyDate? = nil, completedAt: FuzzyDate? = nil) async {
    let store = AccountStore.shared
    let targets = store.others.filter { store.syncIds.contains($0.viewer.id) && !$0.reauth }
    for profile in targets {
      var success = false
      do {
        if profile.isAniList {
          if delete {
            let theirLists = try await AniListService.shared.userLists(userId: profile.viewer.id, token: profile.token)
            if let listEntryId = theirLists.first(where: { $0.anilistId == media.anilistId })?.listEntryId {
              success = try await AniListService.shared.deleteEntry(listEntryId: listEntryId, token: profile.token)
            } else {
              continue
            }
          } else {
            let dates = Self.fuzzyDates(startedAt: startedAt, completedAt: completedAt, status: status)
            let input = ListEntryInput(anilistId: media.anilistId, malId: media.malId, status: status, progress: progress, scoreRaw: Int((score * 10).rounded()), repeatCount: repeatCount, startedAt: dates.startedAt, completedAt: dates.completedAt)
            _ = try await AniListService.shared.saveEntry(input, token: profile.token)
            success = true
          }
        } else if let malId = media.malId {
          if delete {
            success = try await MyAnimeListService.shared.deleteEntry(malId: malId, profile: profile)
          } else {
            let dates = Self.fuzzyDates(startedAt: startedAt, completedAt: completedAt, status: status)
            let input = ListEntryInput(anilistId: media.anilistId, malId: malId, status: status, progress: progress, scoreRaw: Int(score.rounded()), repeatCount: repeatCount, startedAt: dates.startedAt, completedAt: dates.completedAt)
            success = try await MyAnimeListService.shared.saveEntry(malId: malId, input: input, profile: profile)
          }
        }
      } catch {
        success = false
      }
      if !success {
        let service = profile.isAniList ? "AniList" : "MyAnimeList"
        ServiceMessages.shared.post(.error, "Failed to Update List for \(profile.viewer.name) (\(service))", description)
      }
    }
  }

  private func updateLocal(_ media: Media, entry: ListEntry, listEntryId: Int?, startedAt: FuzzyDate?, completedAt: FuzzyDate?) {
    guard var current = lists else { return }
    let previous = item(for: media)
    current.items.removeAll { candidate in
      (media.anilistId != nil && candidate.anilistId == media.anilistId) || (current.service == .myanimelist && media.malId != nil && candidate.malId == media.malId)
    }
    var updatedMedia = MediaStore.shared.media(media.id) ?? media
    updatedMedia.listEntry = entry
    let newItem = UserListItem(id: current.service == .anilist ? media.id : "mal-\(media.malId ?? 0)", media: current.service == .anilist ? updatedMedia : nil, anilistId: media.anilistId, malId: media.malId, listEntryId: listEntryId ?? previous?.listEntryId, status: entry.status, progress: entry.progress, score: entry.score ?? 0, repeatCount: entry.repeatCount ?? 0, updatedAt: entry.updatedAt ?? Date(), startedAt: startedAt, completedAt: completedAt, isRewatching: entry.status == .repeating, title: previous?.title ?? media.title.display(), alternativeTitles: previous?.alternativeTitles ?? media.title.all, malMediaType: previous?.malMediaType, malNumEpisodes: previous?.malNumEpisodes ?? media.episodes, malAverageEpisodeDuration: previous?.malAverageEpisodeDuration, malStartSeason: previous?.malStartSeason, malStartYear: previous?.malStartYear, malAiringStatus: previous?.malAiringStatus, cover: previous?.cover ?? media.images.cover)
    current.items.insert(newItem, at: 0)
    apply(current)
    persist()
  }

  private func removeLocal(_ media: Media) {
    guard var current = lists else { return }
    current.items.removeAll { candidate in
      (media.anilistId != nil && candidate.anilistId == media.anilistId) || (current.service == .myanimelist && media.malId != nil && candidate.malId == media.malId)
    }
    apply(current)
    persist()
  }

  /// myanimelist.js refetches the whole list after every change.
  private func scheduleMALRefresh() {
    Task {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      await refresh()
    }
  }

  // MARK: - Pagination (getPaginatedMediaList)

  /// Filters list items locally, then pages them (user sorts) or resolves them through an AniList id search.
  func paginatedMedia(page: Int, perPage: Int, filter: ListFilter, items: [UserListItem]) async throws -> MediaPage {
    var dubbed: Set<Int> = []
    if filter.dubOnly {
      dubbed = Set(await MALDubsService.shared.lists().dubbed)
    }
    let userSort = Self.isUserSort(filter.sort)
    if lists?.service != .myanimelist {
      let medias = items.compactMap { $0.media }.map { MediaStore.shared.media($0.id) ?? $0 }.filter { Self.matches($0, filter: filter, dubbed: dubbed) }
      if medias.isEmpty { return MediaPage.empty }
      if userSort {
        let start = max(0, (page - 1) * perPage)
        let end = min(medias.count, start + perPage)
        return MediaPage(items: start < end ? Array(medias[start..<end]) : [], hasNextPage: medias.count > start + perPage)
      }
      var variables = Self.searchVariables(filter, includeFormat: true)
      variables.page = page
      variables.perPage = perPage
      variables.id = medias.compactMap { $0.anilistId }
      return try await AniListService.shared.searchIDs(variables)
    }
    let ids = items.filter { Self.matchesMAL($0, filter: filter, dubbed: dubbed) }.compactMap { $0.malId }
    if ids.isEmpty { return MediaPage.empty }
    if userSort {
      let start = max(0, (page - 1) * perPage)
      let end = min(ids.count, start + perPage)
      let paginated = start < end ? Array(ids[start..<end]) : []
      if paginated.isEmpty { return MediaPage.empty }
      var variables = Self.searchVariables(filter, includeFormat: false)
      variables.sort = nil
      variables.page = 1
      variables.perPage = perPage
      variables.idMal = paginated
      let result = try await AniListService.shared.searchIDs(variables)
      let order = Dictionary(uniqueKeysWithValues: paginated.enumerated().map { ($0.element, $0.offset) })
      let sorted = result.items.sorted { (order[$0.malId ?? -1] ?? Int.max) < (order[$1.malId ?? -1] ?? Int.max) }
      return MediaPage(items: sorted, hasNextPage: ids.count > end)
    }
    var variables = Self.searchVariables(filter, includeFormat: true)
    variables.page = page
    variables.perPage = perPage
    variables.idMal = ids
    return try await AniListService.shared.searchIDs(variables)
  }

  private static func searchVariables(_ filter: ListFilter, includeFormat: Bool) -> AniListVariables {
    var variables = AniListVariables()
    variables.sort = isUserSort(filter.sort) ? nil : filter.sort
    variables.search = filter.search
    variables.season = filter.season
    variables.year = filter.year
    if !filter.genres.isEmpty { variables.genre = filter.genres }
    if !filter.tags.isEmpty { variables.tag = filter.tags }
    if includeFormat && !filter.formats.isEmpty { variables.format = filter.formats }
    if !filter.status.isEmpty { variables.status = filter.status }
    return variables
  }

  private static func matches(_ media: Media, filter: ListFilter, dubbed: Set<Int>) -> Bool {
    if filter.dubOnly && !dubbed.contains(media.malId ?? -1) { return false }
    if !ServiceText.matchKeys(media.title.all, phrase: filter.search) { return false }
    let genres = Set(media.genres.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    if !filter.genres.allSatisfy({ genres.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) { return false }
    let tags = Set(media.tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    if !filter.tags.allSatisfy({ tags.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) { return false }
    if let season = filter.season, media.season?.rawValue != season { return false }
    if let year = filter.year, media.seasonYear != year { return false }
    if !filter.formats.isEmpty && !filter.formats.contains(media.format.rawValue) { return false }
    if filter.formatsNot.contains(media.format.rawValue) { return false }
    if !filter.status.isEmpty && !filter.status.contains(media.status.rawValue) { return false }
    if filter.statusNot.contains(media.status.rawValue) { return false }
    if filter.continueWatching {
      if media.status == .finished { return true }
      guard let next = media.nextAiring?.episode, let progress = media.listEntry?.progress else { return false }
      return progress < next - 1
    }
    return true
  }

  /// MyAnimeList node filters (TV_SHORT = TV episodes under 20 minutes).
  private static func matchesMAL(_ item: UserListItem, filter: ListFilter, dubbed: Set<Int>) -> Bool {
    if filter.dubOnly && !dubbed.contains(item.malId ?? -1) { return false }
    if !ServiceText.matchKeys([item.title ?? ""] + item.alternativeTitles, phrase: filter.search) { return false }
    if let season = filter.season, season.lowercased() != item.malStartSeason?.lowercased() { return false }
    if let year = filter.year, year != item.malStartYear { return false }
    let type = (item.malMediaType ?? "").uppercased()
    let duration = item.malAverageEpisodeDuration ?? 0
    func formatMatches(_ formats: [String]) -> Bool {
      let included = formats.contains(type) || (formats.contains("TV_SHORT") && type == "TV" && duration < 1200)
      let longEnough = !formats.contains("TV") || formats.contains("TV_SHORT") || duration >= 1200
      return included && longEnough
    }
    if !filter.formats.isEmpty && !formatMatches(filter.formats) { return false }
    if !filter.formatsNot.isEmpty && formatMatches(filter.formatsNot) { return false }
    let airing = MALStatusMap.airing(item.malAiringStatus)?.rawValue
    if !filter.status.isEmpty && !filter.status.contains(airing ?? "") { return false }
    if let airing, filter.statusNot.contains(airing) { return false }
    return true
  }
}
