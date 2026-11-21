import Foundation

// Sora module results opened as they are (module page, SoraResultView.swift): from the Search page when the module's
// "Link results to AniList / TMDB" is off (InstalledExtension.linkResults), or with "Open as is" when no AniList /
// TMDB title matches. For modules that are not anime, shows or movies (a module returning Twitch VODs): the result
// keeps its own image, title, description and episodes, and plays through the usual extension pipeline with that
// module and that episode href only. The media played is a pseudo media (Media.isSoraResult), never an AniList /
// TMDB title, so nothing is looked up or tracked for it.

/// One episode of a module result (`extractEpisodes` entry) listed by its module page.
struct SoraResultEpisode: Identifiable, Hashable {
  /// Number played (the local resume position is kept by media id + this number): the module's own numbers when
  /// every one is a whole number used once, else the position in the list (1, 2, 3...), so two episodes never share
  /// a resume position.
  var number: Int
  var title: String?
  var href: String
  /// Season of the episode when the result has seasons (the module's `season`, or its numbers starting again), nil
  /// otherwise (SoraResultSource.seasons).
  var season: Int? = nil
  /// Number shown ("Episode N"): its number in its season when the result has seasons, else `number`.
  var seasonEpisode: Int

  var id: String { "\(number)|\(href)" }
  var ref: EpisodeRef { EpisodeRef(number: number, season: nil, localEpisode: nil) }
  /// Entry of the player's episode list.
  var info: EpisodeInfo { EpisodeInfo(number: number, title: title) }
  /// Short name with the season ("S2E1", "Special 1"), nil without seasons (moduleresult.js episodeName).
  var seasonName: String? {
    guard let season else { return nil }
    return season == 0 ? "Special \(seasonEpisode)" : "S\(season)E\(seasonEpisode)"
  }
}

/// Episodes of one season of a module result, for the season picker of its module page (moduleresult.js
/// moduleSeasons). Season nil: the result has no seasons.
struct SoraResultSeason: Identifiable, Hashable {
  var season: Int?
  var episodes: [SoraResultEpisode]

  var id: Int { season ?? -1 }
  var label: String {
    guard let season else { return "Episodes" }
    return season == 0 ? "Specials" : "Season \(season)"
  }
}

/// What `extractDetails` says of a result, shown on its module page.
struct SoraResultDetails: Hashable {
  var description: String?
  var airdate: String?
}

enum SoraResultSource {
  // MARK: Pseudo media

  /// Media played for a module result: id "sora-<extensionKey>-<href>" (PC match.js resultMedia) and its title only.
  /// No image: the module's image address is shown on the module page with the extension image rules
  /// (ExtensionCoverImage: size cap, no local address), while the player's Now Playing artwork, its episode list,
  /// Discord and Watch Together load media images as the app's own.
  static func media(_ result: SoraSearchResult) -> Media {
    let title = result.title
    return Media(
      id: Media.soraResultKey(extensionKey: result.extensionKey, href: result.href),
      source: .sora,
      title: MediaTitle(romaji: title, english: title, native: title, userPreferred: title),
      images: MediaImages(),
      format: .unknown,
      status: .unknown
    )
  }

  // MARK: Module calls

  /// The enabled module of a result, once its load in progress is done (its offline copy after a few seconds when
  /// the load hangs), like the module search.
  @MainActor
  static func module(_ key: String) async throws -> LoadedExtension {
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads([key])
    try Task.checkCancellation()
    guard let ext = manager.enabledExtensions().first(where: { $0.key == key && $0.kind == .sora }) else {
      throw ExtensionFailure("\(SoraSearchSource.moduleName(key)) is disabled or could not be loaded")
    }
    return ext
  }

  /// `extractEpisodes` of the result href, as listed by the module page.
  @MainActor
  static func episodes(_ result: SoraSearchResult) async throws -> [SoraResultEpisode] {
    let ext = try await module(result.extensionKey)
    let items = try await ExtensionCalls.extractEpisodes(ext, href: result.href)
    try Task.checkCancellation()
    return episodes(items)
  }

  /// Episodes with a link (one without cannot play), once per link like PC, numbered as `SoraResultEpisode.number`
  /// says, with their season when the result has seasons.
  static func episodes(_ items: [ExtensionEpisode]) -> [SoraResultEpisode] {
    var seen = Set<String>()
    let usable = items.filter { !$0.href.isEmpty && seen.insert($0.href).inserted }
    let numbers = usable.map { $0.number }
    let allWhole = numbers.allSatisfy { whole($0) != nil }
    let ownNumbers = allWhole && Set(numbers).count == numbers.count
    let seasonList = seasons(usable)
    /// season -> episodes of it so far (number in the season when the module gives none)
    var counts: [Int: Int] = [:]
    return usable.enumerated().map { index, item in
      let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let number = ownNumbers ? Int(item.number) : index + 1
      let season = seasonList?[index]
      var seasonEpisode = number
      if let season {
        let place = (counts[season] ?? 0) + 1
        counts[season] = place
        seasonEpisode = whole(item.number) ?? place
      }
      return SoraResultEpisode(
        number: number,
        title: (title?.isEmpty ?? true) ? nil : title,
        href: item.href,
        season: season,
        seasonEpisode: seasonEpisode
      )
    }
  }

  /// A whole number from 0, else nil.
  private static func whole(_ value: Double?) -> Int? {
    guard let value, value.isFinite, value >= 0, value == value.rounded(), value < 1_000_000 else { return nil }
    return Int(value)
  }

  /// Season of each episode, nil when the result has one season only (moduleresult.js seasonsOf). Same rules as the
  /// season-aware pick of linked results (PlaybackResolver): a `season` given by the module wins, otherwise a new
  /// season starts where the numbers start again. Stricter, since every episode is shown under its season: a season
  /// is only inferred where the number goes back to 0 or 1, and never for a list numbered downwards (newest first),
  /// which would start a season at every episode.
  static func seasons(_ items: [ExtensionEpisode]) -> [Int]? {
    let given = items.map { whole($0.season) }
    var current = (given.first ?? nil) ?? 1
    var last = Double.nan
    var up = 0
    var down = 0
    var result: [Int] = []
    for (index, item) in items.enumerated() {
      let number = item.number
      if let season = given[index] {
        current = season
      } else if number < last && number <= 1 {
        current += 1
      }
      if number > last {
        up += 1
      } else if number < last {
        down += 1
      }
      if number.isFinite { last = number }
      result.append(current)
    }
    if Set(result).count < 2 { return nil }
    if given.allSatisfy({ $0 == nil }) && down >= up { return nil }
    return result
  }

  /// Episodes by season, for the season picker: seasons in order, specials (season 0) last; one group with season nil
  /// when the result has no seasons (moduleresult.js moduleSeasons).
  static func seasons(of episodes: [SoraResultEpisode]) -> [SoraResultSeason] {
    var groups: [SoraResultSeason] = []
    for episode in episodes {
      if let index = groups.firstIndex(where: { $0.season == episode.season }) {
        groups[index].episodes.append(episode)
      } else {
        groups.append(SoraResultSeason(season: episode.season, episodes: [episode]))
      }
    }
    func order(_ season: Int?) -> Int { season == 0 ? Int.max : (season ?? -1) }
    return groups.sorted { order($0.season) < order($1.season) }
  }

  /// Season the module page opens on: the last one with an episode already started here, else the first
  /// (moduleresult.js startSeason).
  static func startSeason(_ groups: [SoraResultSeason], started: (Int) -> Bool) -> Int? {
    var found = groups.first?.season
    for group in groups where group.episodes.contains(where: { started($0.number) }) {
      found = group.season
    }
    return found
  }

  /// `extractDetails` of the result href: its description and air date. nil when the module has none or fails (the
  /// page shows the episodes anyway).
  @MainActor
  static func details(_ result: SoraSearchResult) async -> SoraResultDetails? {
    do {
      let ext = try await module(result.extensionKey)
      let raw = try await ExtensionCalls.extractDetails(ext, href: result.href)
      let found = details(fromDetails: raw)
      return found.description == nil && found.airdate == nil ? nil : found
    } catch {
      #if DEBUG
      print("[Sora result] extractDetails failed: \(error.localizedDescription)")
      #endif
      return nil
    }
  }

  /// Description and air date of an `extractDetails` answer (an object, or an array whose first entry is the
  /// object, like SoraSearchSource.aliases).
  static func details(fromDetails raw: Any?) -> SoraResultDetails {
    let object: [String: Any]?
    if let list = raw as? [Any] {
      object = list.first as? [String: Any]
    } else {
      object = raw as? [String: Any]
    }
    func text(_ key: String) -> String? {
      guard let value = ExtensionJSON.string(object?[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return nil }
      return value
    }
    return SoraResultDetails(description: text("description"), airdate: text("airdate"))
  }
}

/// Module results played this session (module page → player): the module result and its episodes by pseudo media
/// id, so the player lists the module's own episodes and moves between them by their href, without any AniList /
/// TMDB episode list or episode-number matching. Kept for the session only.
@MainActor
final class SoraResultSessions {
  static let shared = SoraResultSessions()

  struct Entry {
    var source: PlaybackSource
    var episodes: [SoraResultEpisode]
  }

  private var entries: [String: Entry] = [:]

  private init() {}

  func remember(_ entry: Entry, for mediaID: String) {
    entries[mediaID] = entry
  }

  func entry(for mediaID: String) -> Entry? {
    entries[mediaID]
  }

  /// The listed episode played as `ref` (its number), nil when the result does not list it.
  func episode(_ ref: EpisodeRef, for mediaID: String) -> (episode: SoraResultEpisode, source: PlaybackSource)? {
    guard let entry = entries[mediaID], let episode = entry.episodes.first(where: { $0.number == ref.number }) else { return nil }
    return (episode, entry.source)
  }
}
