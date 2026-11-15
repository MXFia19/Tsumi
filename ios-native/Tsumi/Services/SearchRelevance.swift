import Foundation

// Port of common/modules/search/relevance.js (title scoring) and relevancesearch.js (relevance paging with
// local fuzzy matches). The scoring rules MUST stay identical to relevance.js (tests:
// node common/modules/search/relevance.test.mjs):
//   100 exact            title == query, or compact title == compact query
//    90 prefix           title starts with the query (or compact with compact)
//    80 phrase           the query is a run of whole words of the title
//    70 words            every query word is a title word (any order); words of 2+ letters may be a word prefix
//    60 substring        the compact query is inside the compact title
//    50 / 45 / 40 fuzzy  every query word is within its edit budget of a title word (or of its start)
//    30 compact fuzzy    the compact query is within its edit budget of the compact title (or of its start)
//     0                  no match
// Normalisation: NFKD, lower case, NFKD, marks removed, final sigma -> sigma, apostrophes removed, "&" -> "and",
// every other non letter / digit run -> one space. Edit budget: 0 under 4 letters, 1 from 4, 2 from 8 (optimal
// string alignment). Synonyms score 5 less. Ranking: score, popularity (TMDB x 1000), original order.
// Strings are compared as Unicode scalar values, like the JavaScript code points.

/// A normalised title: scalar values of the words separated by single spaces.
struct RelevanceText: Hashable {
  let norm: [UInt32]
  let padded: [UInt32]
  let tokens: [[UInt32]]
  let compact: [UInt32]

  init(_ text: String) {
    let norm = SearchRelevance.normalize(text)
    var tokens: [[UInt32]] = []
    var current: [UInt32] = []
    for value in norm {
      if value == SearchRelevance.space {
        if !current.isEmpty { tokens.append(current) }
        current = []
      } else {
        current.append(value)
      }
    }
    if !current.isEmpty { tokens.append(current) }
    self.norm = norm
    self.padded = [SearchRelevance.space] + norm + [SearchRelevance.space]
    self.tokens = tokens
    self.compact = tokens.flatMap { $0 }
  }
}

enum SearchRelevance {
  static let exact = 100
  static let prefix = 90
  static let phrase = 80
  static let words = 70
  static let substring = 60
  static let fuzzy = 50
  static let fuzzyMin = 40
  static let compactFuzzy = 30
  static let synonymPenalty = 5
  /// Local fuzzy matches are only looked up from this many letters (compact query).
  static let localMinQueryLength = 3

  static let space: UInt32 = 0x20
  private static let apostrophes: Set<UInt32> = [0x27, 0x60, 0x2018, 0x2019, 0x02BC]

  // MARK: Normalisation

  static func normalize(_ text: String) -> [UInt32] {
    if text.isEmpty { return [] }
    let folded = text.decomposedStringWithCompatibilityMapping.lowercased().decomposedStringWithCompatibilityMapping
    var output: [UInt32] = []
    output.reserveCapacity(folded.unicodeScalars.count)
    var pendingSpace = false
    func emit(_ value: UInt32) {
      if pendingSpace && !output.isEmpty { output.append(space) }
      pendingSpace = false
      output.append(value)
    }
    for scalar in folded.unicodeScalars {
      let category = scalar.properties.generalCategory
      switch category {
      case .nonspacingMark, .spacingMark, .enclosingMark:
        continue
      default:
        break
      }
      var value = scalar.value
      if value == 0x03C2 { value = 0x03C3 } // final sigma
      if apostrophes.contains(value) { continue }
      if value == 0x26 { // "&" -> " and "
        pendingSpace = true
        emit(0x61)
        emit(0x6E)
        emit(0x64)
        pendingSpace = true
        continue
      }
      switch category {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
           .decimalNumber, .letterNumber, .otherNumber:
        emit(value)
      default:
        pendingSpace = true
      }
    }
    return output
  }

  /// Normalised text as a String (debugging, tests).
  static func normalizedString(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for value in normalize(text) {
      if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
    }
    return String(scalars)
  }

  /// Edit budget of a word (or compact query) of `length` scalars.
  static func maxEdits(_ length: Int) -> Int {
    length >= 8 ? 2 : (length >= 4 ? 1 : 0)
  }

  // MARK: Distances

  /// Optimal string alignment distance (`b` limited to its first `bLength` values), capped at `max + 1`.
  static func editDistance(_ a: [UInt32], _ b: [UInt32], max: Int, bLength: Int? = nil) -> Int {
    let la = a.count
    let lb = Swift.min(bLength ?? b.count, b.count)
    if abs(la - lb) > max { return max + 1 }
    if la == 0 || lb == 0 { return Swift.min(Swift.max(la, lb), max + 1) }
    var previous2 = [Int](repeating: 0, count: lb + 1)
    var previous = Array(0...lb)
    var current = [Int](repeating: 0, count: lb + 1)
    for i in 1...la {
      current[0] = i
      var rowMin = i
      for j in 1...lb {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        var value = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
          value = Swift.min(value, previous2[j - 2] + 1)
        }
        current[j] = value
        if value < rowMin { rowMin = value }
      }
      // Later rows never go below the smallest value of this one: stop once it is over the budget.
      if rowMin > max { return max + 1 }
      let recycled = previous2
      previous2 = previous
      previous = current
      current = recycled
    }
    return Swift.min(previous[lb], max + 1)
  }

  /// Distance of a query word to a title word: 0 for equal or a prefix (2+ letters), else its edits
  /// (or the word start's); nil when over the budget.
  private static func wordDistance(_ token: [UInt32], _ word: [UInt32]) -> Int? {
    if word == token { return 0 }
    if token.count >= 2 && word.starts(with: token) { return 0 }
    let max = maxEdits(token.count)
    if max == 0 || word.count < token.count - max { return nil }
    var distance = editDistance(token, word, max: max)
    if distance > 0 && word.count > token.count {
      distance = Swift.min(distance, editDistance(token, word, max: max, bLength: token.count))
    }
    return distance <= max ? distance : nil
  }

  private static func contains(_ haystack: [UInt32], _ needle: [UInt32]) -> Bool {
    if needle.isEmpty { return true }
    if needle.count > haystack.count { return false }
    let last = haystack.count - needle.count
    var index = 0
    while index <= last {
      if haystack[index] == needle[0] {
        var offset = 1
        while offset < needle.count && haystack[index + offset] == needle[offset] { offset += 1 }
        if offset == needle.count { return true }
      }
      index += 1
    }
    return false
  }

  // MARK: Scoring

  /// Score of one title for a query.
  static func scoreTitle(_ query: RelevanceText, _ title: RelevanceText) -> Int {
    if query.compact.isEmpty || title.compact.isEmpty { return 0 }
    if title.norm == query.norm || title.compact == query.compact { return exact }
    if title.norm.starts(with: query.norm) || title.compact.starts(with: query.compact) { return prefix }
    if contains(title.padded, query.padded) { return phrase }
    let allWords = query.tokens.allSatisfy { token in
      title.tokens.contains { word in word == token || (token.count >= 2 && word.starts(with: token)) }
    }
    if allWords { return words }
    if contains(title.compact, query.compact) { return substring }
    var edits = 0
    var isFuzzy = true
    for token in query.tokens {
      var best: Int?
      for word in title.tokens {
        guard let distance = wordDistance(token, word) else { continue }
        best = Swift.min(best ?? distance, distance)
        if best == 0 { break }
      }
      guard let found = best else {
        isFuzzy = false
        break
      }
      edits += found
    }
    if isFuzzy { return Swift.max(fuzzyMin, fuzzy - 5 * Swift.max(0, edits - 1)) }
    let max = maxEdits(query.compact.count)
    if max > 0 {
      var distance = editDistance(query.compact, title.compact, max: max)
      if distance > max && title.compact.count > query.compact.count {
        distance = editDistance(query.compact, title.compact, max: max, bLength: query.compact.count)
      }
      if distance <= max { return compactFuzzy }
    }
    return 0
  }

  struct PreparedTitles {
    let main: [RelevanceText]
    let synonyms: [RelevanceText]
  }

  private static let preparedCache = ServiceLocked<[String: PreparedTitles]>([:])

  /// Prepared main titles (romaji, English, native, userPreferred) and synonyms, unique by normalised text.
  static func prepared(_ media: Media) -> PreparedTitles {
    let titles = [media.title.romaji, media.title.english, media.title.native, media.title.userPreferred].compactMap { $0 }.filter { !$0.isEmpty }
    let synonyms = media.synonyms.filter { !$0.isEmpty }
    let signature = titles.joined(separator: "\n") + "\n\n" + synonyms.joined(separator: "\n")
    if let cached = preparedCache.get()[signature] { return cached }
    func unique(_ list: [String]) -> [RelevanceText] {
      var seen = Set<[UInt32]>()
      var result: [RelevanceText] = []
      for text in list {
        let item = RelevanceText(text)
        if item.compact.isEmpty || seen.contains(item.norm) { continue }
        seen.insert(item.norm)
        result.append(item)
      }
      return result
    }
    let result = PreparedTitles(main: unique(titles), synonyms: unique(synonyms))
    preparedCache.update { cache in
      if cache.count > 20_000 { cache.removeAll() }
      cache[signature] = result
    }
    return result
  }

  /// Best score of a media's titles (synonyms minus 5).
  static func scoreMedia(_ query: RelevanceText, _ media: Media) -> Int {
    if query.compact.isEmpty { return 0 }
    let titles = prepared(media)
    var best = 0
    for title in titles.main {
      best = Swift.max(best, scoreTitle(query, title))
      if best == exact { return best }
    }
    for title in titles.synonyms {
      let score = scoreTitle(query, title)
      if score > 0 { best = Swift.max(best, score - synonymPenalty) }
    }
    return best
  }

  /// Popularity tie-break: TMDB popularity scaled like the mixed AniList / TMDB search.
  static func popularity(_ media: Media) -> Int {
    let value = media.popularity ?? 0
    return media.source == .tmdb ? value * 1000 : value
  }

  private static func ordered(_ scored: [(index: Int, media: Media, score: Int, popularity: Int)]) -> [(index: Int, media: Media, score: Int, popularity: Int)] {
    scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
      return lhs.index < rhs.index
    }
  }

  /// Media sorted by relevance to the query: score, then popularity, then the original order.
  static func rank(_ query: String, _ list: [Media]) -> [Media] {
    let prepared = RelevanceText(query)
    let scored = list.enumerated().map { (index: $0.offset, media: $0.element, score: scoreMedia(prepared, $0.element), popularity: popularity($0.element)) }
    return ordered(scored).map { $0.media }
  }

  /// Media of `list` matching the query (score of at least `minScore`), best first, at most `limit`.
  /// Empty when the compact query has fewer than `localMinQueryLength` letters.
  static func fuzzyMatches(_ query: String, _ list: [Media], limit: Int = 20, minScore: Int = 1) -> [(media: Media, score: Int)] {
    let prepared = RelevanceText(query)
    if prepared.compact.count < localMinQueryLength { return [] }
    var scored: [(index: Int, media: Media, score: Int, popularity: Int)] = []
    for (index, media) in list.enumerated() {
      let score = scoreMedia(prepared, media)
      if score >= minScore { scored.append((index: index, media: media, score: score, popularity: popularity(media))) }
    }
    return ordered(scored).prefix(limit).map { (media: $0.media, score: $0.score) }
  }

  /// A search sorts by relevance when it has a text query and no sort (or SEARCH_MATCH).
  static func isRelevanceSort(text: String?, sort: String?) -> Bool {
    guard let text, !RelevanceText(text).compact.isEmpty else { return false }
    let value = sort ?? ""
    return value.isEmpty || value == "SEARCH_MATCH"
  }
}

// MARK: - Relevance paging (relevancesearch.js)

/// What a source page searched: the AniList variables (before the adult filters) and whether TMDB was used.
struct SearchRelevanceSources {
  var anime: AniListVariables?
  var western = false
}

/// Text searches with no explicit sort: sources fetched with AniList's SEARCH_MATCH order (and TMDB's text
/// search), the first pages merged with the local fuzzy matches (media store, which holds the user's lists)
/// and ranked together; later pages ranked within themselves and appended without duplicates.
actor SearchRelevancePager {
  static let shared = SearchRelevancePager()

  /// Local fuzzy matches merged into the first page.
  static let localLimit = 20
  /// Source pages fetched at most for one requested page.
  static let maxFetches = 10

  private final class Snapshot {
    var items: [Media] = []
    var ids = Set<String>()
    var nextPage = 1
    var hasNextPage = true
    var merged = false
    var sources = SearchRelevanceSources()
    var failure: Error?
  }

  private var snapshots: [Int: Snapshot] = [:]
  private var order: [Int] = []

  /// One page of a relevance search. `fetch` loads one page of the sources (AniList sorted by SEARCH_MATCH).
  func page(key: Int, page: Int, perPage: Int, query: String, fetch: (Int) async throws -> (page: MediaPage, sources: SearchRelevanceSources)) async throws -> MediaPage {
    let snapshot: Snapshot
    if page == 1 || snapshots[key] == nil {
      snapshot = Snapshot()
      order.removeAll { $0 == key }
      if order.count >= 10 {
        let oldest = order.removeFirst()
        snapshots[oldest] = nil
      }
      order.append(key)
      snapshots[key] = snapshot
    } else if let existing = snapshots[key] {
      snapshot = existing
    } else {
      return MediaPage.empty
    }
    let start = (page - 1) * perPage
    let end = start + perPage
    var batch: [Media] = []
    func add(_ media: Media) {
      if snapshot.ids.contains(media.id) { return }
      snapshot.ids.insert(media.id)
      batch.append(media)
    }
    var fetches = 0
    while snapshot.hasNextPage && snapshot.items.count + batch.count < end && fetches < Self.maxFetches {
      fetches += 1
      let sourcePage = snapshot.nextPage
      snapshot.nextPage += 1
      do {
        let result = try await fetch(sourcePage)
        if let anime = result.sources.anime { snapshot.sources.anime = anime }
        if result.sources.western { snapshot.sources.western = true }
        result.page.items.forEach(add)
        snapshot.hasNextPage = result.page.hasNextPage
      } catch {
        snapshot.hasNextPage = false
        if snapshot.items.isEmpty && batch.isEmpty { snapshot.failure = error }
        break
      }
    }
    if !snapshot.merged {
      snapshot.merged = true
      let local = await Self.localMatches(query, sources: snapshot.sources)
      local.forEach(add)
    }
    snapshot.items.append(contentsOf: SearchRelevance.rank(query, batch))
    if snapshot.items.isEmpty, let failure = snapshot.failure { throw failure }
    let slice = start < snapshot.items.count ? Array(snapshot.items[start..<Swift.min(end, snapshot.items.count)]) : []
    return MediaPage(items: slice, hasNextPage: snapshot.hasNextPage || snapshot.items.count > end)
  }

  /// Media of the local store matching the query, filtered like the searched sources.
  static func localMatches(_ query: String, sources: SearchRelevanceSources) async -> [Media] {
    if RelevanceText(query).compact.count < SearchRelevance.localMinQueryLength { return [] }
    var pool: [Media] = []
    if var anime = sources.anime {
      // fallbackSearch applies the AniList filters (format, status, genres, adult, ids...).
      anime = anime.withAdultFilters()
      anime.search = nil
      anime.sort = nil
      anime.page = 1
      anime.perPage = 1_000_000
      pool.append(contentsOf: AniListService.shared.fallbackSearch(anime).items)
    }
    if sources.western {
      let adult = AppSettings.shared.values.adult != "none"
      pool.append(contentsOf: MediaStore.shared.allMedia().filter { $0.source == .tmdb && (adult || !$0.isAdult) })
    }
    return SearchRelevance.fuzzyMatches(query, pool, limit: localLimit).map { $0.media }
  }
}
