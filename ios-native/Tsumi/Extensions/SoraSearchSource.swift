import Foundation

// Sora modules as a Source of the Search page (common/modules/sora/searchsource.js + match.js): the title is searched
// in the module itself and its results are shown as cards (SearchView.swift, BrowseSoraCards.swift). Opening one finds
// the matching AniList / TMDB title (details, list tracking) and remembers the module result, so Play uses it directly
// instead of searching every extension (PlaybackRequestCoordinator.play). Remembered for the session only. A module
// whose "Link results to AniList / TMDB" is off (InstalledExtension.linkResults) opens its results as they are
// instead, on their module page (SoraResultSource.swift, SoraResultView.swift).

/// One `searchResults` entry of a Sora module, shown as a card of the Search page (resultMedia of match.js).
struct SoraSearchResult: Identifiable, Hashable {
  var extensionKey: String
  var extensionName: String
  var href: String
  var title: String
  var imageURL: URL?

  var id: String { extensionKey + "|" + href }
}

/// Enabled Sora module offered by the Source menu of the Search page.
struct SoraModuleOption: Identifiable, Hashable {
  var key: String
  var name: String

  var id: String { key }
}

enum SoraSearchSource {
  /// Most results shown for one search (searchsource.js `slice(0, 100)`); there is no next page.
  static let maxResults = 100
  /// Lowest title score accepted as the same title, so a fuzzy match with a few typos still passes
  /// (match.js MATCH_MIN_SCORE = SCORE.FUZZY).
  static let matchMinScore = SearchRelevance.fuzzy
  /// Results of the AniList search compared with a title (searchsource.js `perPage: 10`).
  static let candidatesPerTitle = 10

  // MARK: Modules

  /// Enabled Sora modules, in the order of the settings (Stremio addons are not offered).
  @MainActor
  static func modules() -> [SoraModuleOption] {
    ExtensionManager.shared.enabledExtensions()
      .filter { $0.kind == .sora }
      .map { SoraModuleOption(key: $0.key, name: $0.displayName) }
  }

  /// Name of a module for the Source menu and the hints (its key when it is not installed any more).
  @MainActor
  static func moduleName(_ key: String) -> String {
    ExtensionManager.shared.installedExtension(key)?.displayName ?? key
  }

  // MARK: Search

  /// searchResults(title) of one module, as cards. Empty without a title (nothing is searched then).
  @MainActor
  static func search(moduleKey: String, title: String) async throws -> [SoraSearchResult] {
    let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let manager = ExtensionManager.shared
    // A search right after launch or a refresh waits for the module being loaded (its offline copy after a few
    // seconds when the load hangs).
    await manager.awaitPendingLoads([moduleKey])
    try Task.checkCancellation()
    guard let ext = manager.enabledExtensions().first(where: { $0.key == moduleKey && $0.kind == .sora }) else {
      throw ExtensionFailure("\(moduleName(moduleKey)) is disabled or could not be loaded")
    }
    let items = try await ExtensionCalls.searchResults(ext, title: query, media: nil)
    try Task.checkCancellation()
    return results(items, extensionKey: ext.key, extensionName: ext.displayName)
  }

  /// Cards of a module answer: entries with a title and a link, one per link, at most `maxResults`.
  static func results(_ items: [ExtensionSearchItem], extensionKey: String, extensionName: String) -> [SoraSearchResult] {
    var seen = Set<String>()
    var list: [SoraSearchResult] = []
    for item in items {
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, !item.href.isEmpty, !seen.contains(item.href) else { continue }
      seen.insert(item.href)
      list.append(SoraSearchResult(extensionKey: extensionKey, extensionName: extensionName, href: item.href, title: title, imageURL: imageURL(item.image)))
      if list.count >= maxResults { break }
    }
    return list
  }

  /// Web images only (match.js resultMedia: `^https?://`).
  static func imageURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
    return URL.lenient(trimmed)
  }

  // MARK: Matching (match.js)

  /// Catalogues to search for a module, from its manifest `type` ("anime", "movies", "shows"...): AniList for anime,
  /// TMDB for movies and shows, both when unknown (most modules don't say) or when the type names both
  /// ("anime/movies"). match.js matchTargets.
  static func matchTargets(_ type: String?) -> (anime: Bool, western: Bool) {
    let value = (type ?? "").lowercased()
    let anime = ["anime", "manga", "donghua"].contains(where: { value.contains($0) })
    let western = ["movie", "show", "serie", "tv", "film", "drama", "cartoon"].contains(where: { value.contains($0) })
    if anime && !western { return (anime: true, western: false) }
    if western && !anime { return (anime: false, western: true) }
    return (anime: true, western: true)
  }

  /// Version tags modules add at the end of titles: "Attack on Titan (Dub)", "Naruto Shippuden VF",
  /// "One Piece [VOSTFR]", "Dune (2021)". AniList and TMDB titles have none, so they are removed before searching and
  /// scoring. match.js VERSION_TAG (ICU needs the `[` of the first class escaped).
  private static let versionTag = try? NSRegularExpression(
    pattern: #"(?:\s*[(\[]\s*(?:(?:english|french|eng|fr)\s+)?(?:dub(?:bed)?|sub(?:bed)?|vf|vostfr|vost|vo|multi|uncensored|censored|(?:19|20)\d\d)\s*[)\]]|\s+(?:dub|sub|vf|vostfr|vost|multi)|\s*\[[^\]]*\])\s*$"#,
    options: [.caseInsensitive]
  )

  /// Title of a module result without its version tags (several in a row: "X (English Dub) [HD]" -> "X"); the title
  /// itself when that would leave nothing ("Sub" stays "Sub", "The Office (US)" is unchanged). match.js
  /// cleanResultTitle.
  static func cleanResultTitle(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let regex = versionTag else { return text }
    for _ in 0..<5 {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let next = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
      if next == text || next.isEmpty { break }
      text = next
    }
    return text
  }

  /// Cleaned titles, without empty ones and duplicates (first one kept).
  static func cleanResultTitles(_ titles: [String]) -> [String] {
    var result: [String] = []
    for title in titles.map(cleanResultTitle) where !title.isEmpty && !result.contains(title) {
      result.append(title)
    }
    return result
  }

  /// Best media for a result title among the candidates: the highest title score (aliases included, scored by
  /// SearchRelevance like the search page), then the most popular. nil when nothing reaches `matchMinScore` (better no
  /// match than another show). match.js pickBestMatch.
  static func pickBestMatch(_ titles: [String], _ candidates: [Media]) -> Media? {
    let queries = titles
      .map { RelevanceText($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.compact.isEmpty }
    guard !queries.isEmpty else { return nil }
    var best: (media: Media, score: Int)?
    for media in candidates where !media.id.isEmpty {
      var score = 0
      for query in queries {
        score = Swift.max(score, SearchRelevance.scoreMedia(query, media))
      }
      if score < matchMinScore { continue }
      if let current = best {
        let better = score > current.score
          || (score == current.score && SearchRelevance.popularity(media) > SearchRelevance.popularity(current.media))
        if better { best = (media: media, score: score) }
      } else {
        best = (media: media, score: score)
      }
    }
    return best?.media
  }

  /// Aliases of an `extractDetails` answer (an object, or an array whose first entry is the object): "A, B" text or
  /// an array, at most 10. searchsource.js resultAliases.
  static func aliases(fromDetails raw: Any?) -> [String] {
    let details: [String: Any]?
    if let list = raw as? [Any] {
      details = list.first as? [String: Any]
    } else {
      details = raw as? [String: Any]
    }
    guard let value = details?["aliases"] else { return [] }
    var list: [String] = []
    if let array = value as? [Any] {
      list = array.compactMap { ExtensionJSON.string($0) }
    } else if let text = value as? String {
      list = text.components(separatedBy: CharacterSet(charactersIn: ",;\n|"))
    }
    let cleaned = list
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0.utf16.count < 200 }
    return Array(cleaned.prefix(10))
  }

  /// Aliases given by the module details, to match titles listed under another name. Empty when the module has no
  /// details or they fail.
  static func aliases(_ ext: LoadedExtension, href: String) async -> [String] {
    do {
      let raw = try await ExtensionCalls.extractDetails(ext, href: href)
      return aliases(fromDetails: raw)
    } catch {
      #if DEBUG
      print("[Sora search] extractDetails failed: \(error.localizedDescription)")
      #endif
      return []
    }
  }

  /// AniList / TMDB media found for up to 3 titles, in the order of the requests (title by title, AniList then TMDB),
  /// which is the tie-break order of `pickBestMatch`. A failed request gives nothing.
  static func candidates(_ titles: [String], anime: Bool, western: Bool) async -> [Media] {
    let searched = Array(titles.prefix(3))
    let lists: [(index: Int, media: [Media])] = await withTaskGroup(of: (index: Int, media: [Media]).self) { group in
      for (offset, title) in searched.enumerated() {
        if anime {
          group.addTask {
            var variables = AniListVariables()
            variables.search = title
            variables.page = 1
            variables.perPage = SoraSearchSource.candidatesPerTitle
            // Best title matches first, so the right title is among the few results kept.
            variables.sort = "SEARCH_MATCH"
            let page = try? await AniListService.shared.search(variables)
            return (index: offset * 2, media: page?.items ?? [])
          }
        }
        if western {
          group.addTask {
            // Every TMDB title, K-dramas, Asian and anime films included (the Search page's TMDB results leave them
            // out); a title mapped to AniList is replaced by its AniList entry.
            let page = await TMDBService.shared.textSearch(title, includeAnime: true)
            let media = await SoraSearchSource.withAniList(page.items)
            return (index: offset * 2 + 1, media: media)
          }
        }
      }
      var found: [(index: Int, media: [Media])] = []
      for await list in group {
        found.append(list)
      }
      return found
    }
    return lists.sorted { $0.index < $1.index }.flatMap { $0.media }
  }

  /// TMDB titles mapped to AniList open their AniList entry (searchsource.js withAniList): the unmapped ones, then the
  /// AniList media of the mapped ones (left out when AniList fails).
  static func withAniList(_ media: [Media]) async -> [Media] {
    let mapped = media.compactMap { $0.anilistId }
    let others = media.filter { $0.anilistId == nil }
    guard !mapped.isEmpty else { return others }
    var variables = AniListVariables()
    variables.id = mapped
    variables.page = 1
    variables.perPage = 50
    let page = try? await AniListService.shared.searchIDs(variables)
    return others + (page?.items ?? [])
  }

  /// AniList / TMDB media matching a module result (its title, then the aliases of the module details), nil when none
  /// is close enough. searchsource.js findMatch.
  @MainActor
  static func findMatch(_ result: SoraSearchResult) async throws -> Media? {
    let ext = ExtensionManager.shared.loadedExtension(result.extensionKey)
    let targets = matchTargets(ext?.manifest.type)
    // "Attack on Titan (Dub)" is searched and scored as "Attack on Titan" (the original title is still scored).
    let titles = cleanResultTitles([result.title])
    let found = await candidates(titles, anime: targets.anime, western: targets.western)
    try Task.checkCancellation()
    if let match = pickBestMatch(titles + [result.title], found) { return match }
    guard let ext else { return nil }
    let moduleAliases = await Self.aliases(ext, href: result.href)
    let names = cleanResultTitles(moduleAliases)
    try Task.checkCancellation()
    guard !names.isEmpty else { return nil }
    let more = await candidates(names, anime: targets.anime, western: targets.western)
    try Task.checkCancellation()
    return pickBestMatch(titles + [result.title] + names, more)
  }
}

/// Module result each title was opened from (searchsource.js preferredSources): Play resolves that module and result
/// first (PlaybackRequestCoordinator.play). Kept for the session only.
@MainActor
final class SoraPreferredSources {
  static let shared = SoraPreferredSources()

  private var sources: [String: PlaybackSource] = [:]

  private init() {}

  /// Module result remembered for a media id (`Media.id`). Forgotten once its module was removed or disabled, so a
  /// later Play of the title goes straight to the usual flow instead of failing on it first.
  func source(for mediaID: String) -> PlaybackSource? {
    guard let source = sources[mediaID] else { return nil }
    guard ExtensionManager.shared.isEnabled(source.extensionKey) else {
      sources[mediaID] = nil
      return nil
    }
    return source
  }

  func remember(_ source: PlaybackSource, for mediaID: String) {
    sources[mediaID] = source
  }
}
