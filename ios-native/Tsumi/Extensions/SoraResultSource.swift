import Foundation

// Sora module results opened as they are (module page, SoraResultView.swift): from the Search page when the module's
// "Link results to AniList / TMDB" is off (InstalledExtension.linkResults), or with "Open as is" when no AniList /
// TMDB title matches. For modules that are not anime, shows or movies (a module returning Twitch VODs): the result
// keeps its own image, title, description and episodes, and plays through the usual extension pipeline with that
// module and that episode href only. The media played is a pseudo media (Media.isSoraResult), never an AniList /
// TMDB title, so nothing is looked up or tracked for it.

/// One episode of a module result (`extractEpisodes` entry) listed by its module page.
struct SoraResultEpisode: Identifiable, Hashable {
  /// Number shown ("Episode N") and played (the local resume position is kept by media id + this number): the
  /// module's own numbers when every one is a whole number used once, else the position in the list (1, 2, 3...),
  /// so two episodes never share a resume position.
  var number: Int
  var title: String?
  var href: String

  var id: String { "\(number)|\(href)" }
  var ref: EpisodeRef { EpisodeRef(number: number, season: nil, localEpisode: nil) }
  /// Entry of the player's episode list.
  var info: EpisodeInfo { EpisodeInfo(number: number, title: title) }
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

  /// Episodes with a link (one without cannot play), numbered as `SoraResultEpisode.number` says.
  static func episodes(_ items: [ExtensionEpisode]) -> [SoraResultEpisode] {
    let usable = items.filter { !$0.href.isEmpty }
    let numbers = usable.map { $0.number }
    let whole = numbers.allSatisfy { $0.isFinite && $0 >= 0 && $0 == $0.rounded() && $0 < 1_000_000 }
    let ownNumbers = whole && Set(numbers).count == numbers.count
    return usable.enumerated().map { index, item in
      let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      return SoraResultEpisode(
        number: ownNumbers ? Int(item.number) : index + 1,
        title: (title?.isEmpty ?? true) ? nil : title,
        href: item.href
      )
    }
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
