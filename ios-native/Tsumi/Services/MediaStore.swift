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
}

final class MediaStore: @unchecked Sendable {
  static let shared = MediaStore()

  private struct State {
    var media: [String: Media] = [:]
    var extras: [String: MediaExtras] = [:]
    var touched: [String: Date] = [:]
    var saveScheduled = false
  }

  private struct Persisted: Codable {
    var media: [String: Media]
    var extras: [String: MediaExtras]
    var touched: [String: Date]
  }

  private static let maxPersisted = 4000
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
    state.update { current in
      let now = Date()
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
      }
    }
    scheduleSave()
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

  /// Removes every list entry (account switch / logout: the entries belonged to the previous user).
  func clearListEntries() {
    state.update { current in
      for key in Array(current.media.keys) {
        current.media[key]?.listEntry = nil
        if current.extras[key] != nil {
          current.extras[key]?.listEntryId = nil
          current.extras[key]?.startedAt = nil
          current.extras[key]?.completedAt = nil
          current.extras[key]?.customLists = []
        }
      }
    }
    scheduleSave()
  }

  func clear() {
    state.set(State())
    try? FileManager.default.removeItem(at: fileURL)
  }

  // MARK: Persistence

  private func scheduleSave() {
    let shouldSchedule: Bool = state.update { current in
      if current.saveScheduled { return false }
      current.saveScheduled = true
      return true
    }
    guard shouldSchedule else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
      self?.save()
    }
  }

  private func save() {
    let snapshot: Persisted = state.update { current in
      current.saveScheduled = false
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
