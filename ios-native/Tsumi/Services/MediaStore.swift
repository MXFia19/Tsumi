import Foundation

// Global media store, the equivalent of `mediaCache` in common/modules/cache.js: every media fetched
// from AniList / TMDB is merged here (keyed by Media.id) so that list entries, banners and logos stay
// consistent between screens, and so that searches can fall back to it when offline.

/// One airing schedule node (AniList airingSchedule / AniSchedule feeds).
struct AiringNode: Codable, Hashable {
  var episode: Int
  var airingAt: Date

  init(episode: Int, airingAt: Date) {
    self.episode = episode
    self.airingAt = airingAt
  }

  private enum CodingKeys: String, CodingKey {
    case episode
    case airingAt
  }

  /// Accepts epoch seconds (AniList, sub schedule) or ISO strings (dub schedule).
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    episode = container.svcLossyInt(.episode) ?? 0
    if let seconds = try? container.decode(Double.self, forKey: .airingAt) {
      airingAt = ServiceDates.epoch(seconds)
    } else if let string = try? container.decode(String.self, forKey: .airingAt), let date = ServiceDates.parse(string) {
      airingAt = date
    } else {
      airingAt = Date.distantPast
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(episode, forKey: .episode)
    try container.encode(airingAt.timeIntervalSince1970, forKey: .airingAt)
  }
}

/// AniList streamingEpisodes entry ("Episode 3 - Title").
struct StreamingEpisodeInfo: Codable, Hashable {
  var title: String?
  var thumbnail: URL?
}

/// AniList relations edge (only the fields requested by the media query).
struct RelationEdgeInfo: Codable, Hashable {
  var id: Int
  var relationType: String
  var type: String?
  var format: String?
  var isAdult: Bool?
  var seasonYear: Int?
}

/// AniList custom list flag of a list entry.
struct CustomListFlag: Codable, Hashable {
  var name: String
  var enabled: Bool
}

/// TMDB season summary (details.seasons).
struct TMDBSeasonInfo: Codable, Hashable {
  var seasonNumber: Int
  var episodeCount: Int
  var name: String?
  var airDate: String?
  var poster: URL?
}

/// Fields of the Svelte media objects that Core `Media` does not model.
struct MediaExtras: Codable, Hashable {
  var airingSchedule: [AiringNode] = []
  var streamingEpisodes: [StreamingEpisodeInfo] = []
  var relationEdges: [RelationEdgeInfo] = []
  var recommendationIds: [Int] = []
  var startDate: FuzzyDate?
  var endDate: FuzzyDate?
  var listEntryId: Int?
  var startedAt: FuzzyDate?
  var completedAt: FuzzyDate?
  var customLists: [CustomListFlag] = []
  var isFavourite: Bool = false
  var reviewCount: Int?
  var source: String?
  var trailerSite: String?
  var tagRanks: [String: Int] = [:]
  /// AniList tags marked as spoilers (isGeneralSpoiler / isMediaSpoiler), for spoiler protection. Optional so the
  /// stored extras of older versions still decode.
  var generalSpoilerTags: [String]? = nil
  var mediaSpoilerTags: [String]? = nil
  // TMDB only
  var originalLanguage: String?
  var originCountries: [String] = []
  var contentRating: String?
  var networks: [String] = []
  var streamingProviders: [String] = []
  var tmdbSeasons: [TMDBSeasonInfo] = []
  var collectionId: Int?
  var tvdbId: Int?
  var tmdbEnriched: Bool = false

  enum CodingKeys: String, CodingKey {
    case airingSchedule, streamingEpisodes, relationEdges, recommendationIds, startDate, endDate, listEntryId
    case startedAt, completedAt, customLists, isFavourite, reviewCount, source, trailerSite, tagRanks
    case generalSpoilerTags, mediaSpoilerTags, originalLanguage, originCountries, contentRating, networks
    case streamingProviders, tmdbSeasons, collectionId, tvdbId, tmdbEnriched
  }
}

extension MediaExtras {
  /// Tolerant decoding of the stored extras: every field is optional and falls back to its default, so a field
  /// added later (or one that changed type) never wipes the media store.
  init(from decoder: Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    airingSchedule = container.svcArray(AiringNode.self, .airingSchedule)
    streamingEpisodes = container.svcArray(StreamingEpisodeInfo.self, .streamingEpisodes)
    relationEdges = container.svcArray(RelationEdgeInfo.self, .relationEdges)
    recommendationIds = container.svcArray(Int.self, .recommendationIds)
    startDate = container.svcValue(FuzzyDate.self, .startDate)
    endDate = container.svcValue(FuzzyDate.self, .endDate)
    listEntryId = container.svcLossyInt(.listEntryId)
    startedAt = container.svcValue(FuzzyDate.self, .startedAt)
    completedAt = container.svcValue(FuzzyDate.self, .completedAt)
    customLists = container.svcArray(CustomListFlag.self, .customLists)
    isFavourite = container.svcLossyBool(.isFavourite) ?? false
    reviewCount = container.svcLossyInt(.reviewCount)
    source = container.svcValue(String.self, .source)
    trailerSite = container.svcValue(String.self, .trailerSite)
    tagRanks = container.svcValue([String: Int].self, .tagRanks) ?? [:]
    generalSpoilerTags = container.svcValue([String].self, .generalSpoilerTags)
    mediaSpoilerTags = container.svcValue([String].self, .mediaSpoilerTags)
    originalLanguage = container.svcValue(String.self, .originalLanguage)
    originCountries = container.svcArray(String.self, .originCountries)
    contentRating = container.svcValue(String.self, .contentRating)
    networks = container.svcArray(String.self, .networks)
    streamingProviders = container.svcArray(String.self, .streamingProviders)
    tmdbSeasons = container.svcArray(TMDBSeasonInfo.self, .tmdbSeasons)
    collectionId = container.svcLossyInt(.collectionId)
    tvdbId = container.svcLossyInt(.tvdbId)
    tmdbEnriched = container.svcLossyBool(.tmdbEnriched) ?? false
  }
}

final class MediaStore: @unchecked Sendable {
  static let shared = MediaStore()

  private struct State {
    var media: [String: Media] = [:]
    var extras: [String: MediaExtras] = [:]
    var touched: [String: Date] = [:]
    var saveScheduled = false
    /// Changed since the last save.
    var dirty = false
  }

  private struct Persisted: Codable {
    var media: [String: Media]
    var extras: [String: MediaExtras]
    var touched: [String: Date]

    init(media: [String: Media], extras: [String: MediaExtras], touched: [String: Date]) {
      self.media = media
      self.extras = extras
      self.touched = touched
    }

    /// One unreadable media (older or newer format) is dropped instead of the whole store.
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      media = ((try? container.decode([String: SettingsLossyItem<Media>].self, forKey: .media)) ?? [:]).compactMapValues { $0.value }
      extras = ((try? container.decode([String: SettingsLossyItem<MediaExtras>].self, forKey: .extras)) ?? [:]).compactMapValues { $0.value }
      touched = (try? container.decode([String: Date].self, forKey: .touched)) ?? [:]
    }
  }

  private static let maxPersisted = 4000
  /// Media kept in memory: past this, the least recently updated ones that are not on the list are dropped
  /// (down to `maxPersisted`) at the next save.
  private static let maxInMemory = 6000
  /// Kept (besides the list entries) when the system warns about memory.
  private static let keptOnMemoryWarning = 1500
  /// Saves are grouped: the whole store is encoded at most once per this delay, and when the app goes to the
  /// background (`saveNow`).
  private static let saveDelay: TimeInterval = 60
  private let state = ServiceLocked<State>(State())
  private let fileURL: URL

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("tsumi-media-store.json")
    if let data = try? Data(contentsOf: fileURL), let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
      state.update { current in
        current.media = persisted.media
        current.extras = persisted.extras
        current.touched = persisted.touched
      }
    }
  }

  // MARK: Reads

  func media(_ key: String) -> Media? {
    state.get().media[key]
  }

  func anilist(_ id: Int) -> Media? {
    media(Media.anilistKey(id))
  }

  func anilist(malId: Int) -> Media? {
    state.get().media.values.first { $0.source == .anilist && $0.malId == malId }
  }

  func extras(_ key: String) -> MediaExtras? {
    state.get().extras[key]
  }

  func extras(for media: Media) -> MediaExtras {
    state.get().extras[media.id] ?? MediaExtras()
  }

  func allMedia() -> [Media] {
    Array(state.get().media.values)
  }

  /// Latest stored version of each media (cache.js remaps cached ids to mediaCache entries).
  func resolve(_ items: [Media]) -> [Media] {
    let current = state.get().media
    return items.map { current[$0.id] ?? $0 }
  }

  // MARK: Writes

  /// Merges fresh media into the store (cache.updateMedia): new values win, but banners, logos,
  /// detail-only fields and airing schedules are kept when the new copy lacks them.
  @discardableResult
  func ingest(_ items: [Media], extras: [String: MediaExtras] = [:], overwrite: Bool = true) -> [Media] {
    var result: [Media] = []
    result.reserveCapacity(items.count)
    let changed: Bool = state.update { current in
      let now = Date()
      var changed = false
      for var incoming in items {
        ServiceListOverlay.apply(to: &incoming, extras: nil)
        if let existing = current.media[incoming.id] {
          if !overwrite {
            result.append(existing)
            continue
          }
          if incoming.images.logo == nil { incoming.images.logo = existing.images.logo }
          if incoming.images.banner == nil { incoming.images.banner = existing.images.banner }
          if incoming.relations.isEmpty { incoming.relations = existing.relations }
          if incoming.recommendations.isEmpty { incoming.recommendations = existing.recommendations }
          if incoming.characters.isEmpty { incoming.characters = existing.characters }
          if incoming.staff.isEmpty { incoming.staff = existing.staff }
          if incoming.studios.isEmpty { incoming.studios = existing.studios }
          if incoming.trailerYouTubeId == nil { incoming.trailerYouTubeId = existing.trailerYouTubeId }
          if incoming.tmdbId == nil {
            incoming.tmdbId = existing.tmdbId
            incoming.tmdbType = existing.tmdbType
          }
          if incoming.imdbId == nil { incoming.imdbId = existing.imdbId }
          if incoming.numberOfSeasons == nil { incoming.numberOfSeasons = existing.numberOfSeasons }
        }
        if var newExtras = extras[incoming.id] {
          if let previous = current.extras[incoming.id] {
            if newExtras.airingSchedule.isEmpty { newExtras.airingSchedule = previous.airingSchedule }
            if newExtras.tmdbSeasons.isEmpty { newExtras.tmdbSeasons = previous.tmdbSeasons }
            if newExtras.originalLanguage == nil { newExtras.originalLanguage = previous.originalLanguage }
            if newExtras.collectionId == nil { newExtras.collectionId = previous.collectionId }
            if newExtras.tvdbId == nil { newExtras.tvdbId = previous.tvdbId }
            if !newExtras.tmdbEnriched { newExtras.tmdbEnriched = previous.tmdbEnriched }
            if newExtras.relationEdges.isEmpty { newExtras.relationEdges = previous.relationEdges }
            if newExtras.recommendationIds.isEmpty { newExtras.recommendationIds = previous.recommendationIds }
          }
          ServiceListOverlay.applyDates(to: &newExtras, media: incoming)
          current.extras[incoming.id] = newExtras
        }
        current.media[incoming.id] = incoming
        current.touched[incoming.id] = now
        result.append(incoming)
        changed = true
      }
      return changed
    }
    if changed { scheduleSave() }
    return result
  }

  /// Replaces the list entry of a media (after SaveMediaListEntry / DeleteMediaListEntry).
  func setListEntry(_ key: String, entry: ListEntry?, update: ((inout MediaExtras) -> Void)? = nil) {
    state.update { current in
      if var media = current.media[key] {
        media.listEntry = entry
        current.media[key] = media
      }
      var extras = current.extras[key] ?? MediaExtras()
      update?(&extras)
      if entry == nil {
        extras.listEntryId = nil
        extras.startedAt = nil
        extras.completedAt = nil
      }
      current.extras[key] = extras
      current.touched[key] = Date()
    }
    scheduleSave()
  }

  func updateMedia(_ key: String, _ body: (inout Media) -> Void) {
    state.update { current in
      if var media = current.media[key] {
        body(&media)
        current.media[key] = media
      }
    }
    scheduleSave()
  }

  func updateExtras(_ key: String, _ body: (inout MediaExtras) -> Void) {
    state.update { current in
      var extras = current.extras[key] ?? MediaExtras()
      body(&extras)
      current.extras[key] = extras
    }
    scheduleSave()
  }

  /// Re-applies the MyAnimeList entries to every stored AniList media (after the MAL list changed).
  func reapplyOverlay() {
    state.update { current in
      for key in Array(current.media.keys) {
        guard var media = current.media[key], media.source == .anilist else { continue }
        ServiceListOverlay.apply(to: &media, extras: nil)
        current.media[key] = media
        if var extras = current.extras[key] {
          ServiceListOverlay.applyDates(to: &extras, media: media)
          current.extras[key] = extras
        }
      }
    }
    scheduleSave()
  }

  /// Removes every list entry and favourite flag (account switch / logout: they belonged to the previous user).
  func clearListEntries() {
    state.update { current in
      for key in Array(current.media.keys) {
        current.media[key]?.listEntry = nil
      }
      for key in Array(current.extras.keys) {
        current.extras[key]?.listEntryId = nil
        current.extras[key]?.startedAt = nil
        current.extras[key]?.completedAt = nil
        current.extras[key]?.customLists = []
        current.extras[key]?.isFavourite = false
      }
    }
    scheduleSave()
  }

  func clear() {
    state.set(State())
    try? FileManager.default.removeItem(at: fileURL)
  }

  /// Memory warning: keeps the list entries and the most recently updated media only (the file is untouched until
  /// the next save).
  func purgeMemory() {
    state.update { current in
      Self.prune(&current, keeping: Self.keptOnMemoryWarning)
    }
  }

  /// Drops the least recently updated media that are not on the list, down to `keeping` of them.
  private static func prune(_ current: inout State, keeping: Int) {
    let removable = current.media.filter { $0.value.listEntry == nil }.map { $0.key }
    guard removable.count > keeping else { return }
    let ordered = removable.sorted { (current.touched[$0] ?? .distantPast) > (current.touched[$1] ?? .distantPast) }
    for key in ordered.dropFirst(keeping) {
      current.media[key] = nil
      current.extras[key] = nil
      current.touched[key] = nil
    }
  }

  // MARK: Persistence

  private func scheduleSave() {
    let shouldSchedule: Bool = state.update { current in
      current.dirty = true
      if current.saveScheduled { return false }
      current.saveScheduled = true
      return true
    }
    guard shouldSchedule else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
      self?.save()
    }
  }

  /// Writes the pending changes now (the app goes to the background). Blocking: call it off the main thread.
  func saveNow() {
    save()
  }

  private func save() {
    let snapshot: Persisted? = state.update { current in
      current.saveScheduled = false
      guard current.dirty else { return nil }
      current.dirty = false
      if current.media.count > Self.maxInMemory {
        Self.prune(&current, keeping: Self.maxPersisted)
      }
      var keys = Array(current.media.keys)
      if keys.count > Self.maxPersisted {
        keys.sort { (current.touched[$0] ?? .distantPast) > (current.touched[$1] ?? .distantPast) }
        keys = Array(keys.prefix(Self.maxPersisted))
      }
      var media: [String: Media] = [:]
      var extras: [String: MediaExtras] = [:]
      var touched: [String: Date] = [:]
      for key in keys {
        if var item = current.media[key] {
          item.relations = []
          item.recommendations = []
          media[key] = item
        }
        if let extra = current.extras[key] { extras[key] = extra }
        if let date = current.touched[key] { touched[key] = date }
      }
      return Persisted(media: media, extras: extras, touched: touched)
    }
    guard let snapshot else { return }
    if let data = try? JSONEncoder().encode(snapshot) {
      try? data.write(to: fileURL, options: .atomic)
    }
  }
}

/// Thread-safe snapshot of the current user's lists, read by background services
/// (helper.js `Helper.getClient().userLists.value`). Also fills AniList media with MyAnimeList
/// entries when the active account is a MAL one (cache.js fillEntries).
final class ServiceListOverlay: @unchecked Sendable {
  private struct State {
    var lists: UserLists?
    var byAnilist: [Int: UserListItem] = [:]
    var byMal: [Int: UserListItem] = [:]
  }

  private static let state = ServiceLocked<State>(State())

  static var lists: UserLists? { state.get().lists }

  static func set(_ lists: UserLists?) {
    var next = State()
    next.lists = lists
    for item in lists?.items ?? [] {
      if let id = item.anilistId { next.byAnilist[id] = item }
      if let mal = item.malId { next.byMal[mal] = item }
    }
    state.set(next)
  }

  static func item(anilistId: Int?, malId: Int?) -> UserListItem? {
    let current = state.get()
    if let anilistId, let item = current.byAnilist[anilistId] { return item }
    if let malId, let item = current.byMal[malId] { return item }
    return nil
  }

  /// When logged into MyAnimeList, AniList media get their list entry from the MAL list.
  static func apply(to media: inout Media, extras: MediaExtras?) {
    guard media.source == .anilist else { return }
    let current = state.get()
    guard let lists = current.lists, lists.service == .myanimelist else { return }
    if let malId = media.malId, let item = current.byMal[malId] {
      media.listEntry = item.listEntry
    } else {
      media.listEntry = nil
    }
  }

  static func applyDates(to extras: inout MediaExtras, media: Media) {
    let current = state.get()
    guard let lists = current.lists, lists.service == .myanimelist, media.source == .anilist else { return }
    if let malId = media.malId, let item = current.byMal[malId] {
      extras.startedAt = item.startedAt
      extras.completedAt = item.completedAt
    }
  }
}
