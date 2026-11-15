import Foundation

// Data shared by the app and its widget extension (compiled into both targets, see project.yml).
// The app writes a `TsumiWidgetSnapshot` (JSON) and small cover thumbnails into the App Group container
// (TsumiSharedContainer); the widgets and the Live Activity read them. When the install has no usable App Group
// (re-signed without the entitlement), the widgets build the same snapshot from AniList's public list instead
// (widget configuration: AniList username).

/// What the widgets show, as of `generatedAt`.
struct TsumiWidgetSnapshot: Codable, Hashable {
  static let fileName = "widget-snapshot.json"
  static let coversFolder = "Covers"
  static let currentVersion = 1

  var version: Int = TsumiWidgetSnapshot.currentVersion
  var generatedAt: Date
  /// Name of the signed-in account (or of the AniList user of the widget configuration); nil = signed out.
  var account: String?
  /// "anilist" | "myanimelist".
  var service: String?
  /// Watching / rewatching titles, the ones with an episode to watch first.
  var continueWatching: [TsumiWidgetShow]
  /// Next episodes of the followed titles (watching, rewatching, planning), soonest first, a few per title.
  var airing: [TsumiWidgetAiring]

  init(generatedAt: Date, account: String?, service: String?, continueWatching: [TsumiWidgetShow], airing: [TsumiWidgetAiring]) {
    self.generatedAt = generatedAt
    self.account = account
    self.service = service
    self.continueWatching = continueWatching
    self.airing = airing
  }

  /// Tolerant decoding: a missing key keeps its default, so older / newer snapshots still decode.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
    generatedAt = (try? container.decodeIfPresent(Date.self, forKey: .generatedAt)) ?? Date.distantPast
    account = try? container.decodeIfPresent(String.self, forKey: .account)
    service = try? container.decodeIfPresent(String.self, forKey: .service)
    continueWatching = (try? container.decodeIfPresent([TsumiWidgetLossy<TsumiWidgetShow>].self, forKey: .continueWatching))?.compactMap { $0.value } ?? []
    airing = (try? container.decodeIfPresent([TsumiWidgetLossy<TsumiWidgetAiring>].self, forKey: .airing))?.compactMap { $0.value } ?? []
  }

  /// The airings still worth showing at `date`: not aired yet, or aired less than `outWindow` ago ("Out now").
  func airings(at date: Date, outWindow: TimeInterval = TsumiWidgetSnapshot.outWindow) -> [TsumiWidgetAiring] {
    airing
      .filter { $0.airingAt.addingTimeInterval(outWindow) > date }
      .sorted { $0.airingAt < $1.airingAt }
  }

  /// How long an aired episode stays as "Out now".
  static let outWindow: TimeInterval = 60 * 60

  /// Same content, ignoring when it was generated (to skip needless widget reloads).
  func sameContent(as other: TsumiWidgetSnapshot) -> Bool {
    var left = self
    var right = other
    left.generatedAt = .distantPast
    right.generatedAt = .distantPast
    return left == right
  }
}

/// A title of the Continue Watching widget.
struct TsumiWidgetShow: Codable, Hashable, Identifiable {
  /// "al-<anilistId>" or "mal-<malId>".
  var id: String
  var title: String
  var progress: Int
  /// Episode count when known.
  var total: Int?
  /// Episode to watch next (progress + 1).
  var nextEpisode: Int
  /// The next episode has not aired yet (`nextEpisodeAiringAt` is when it airs, when known).
  var upcoming: Bool
  var nextEpisodeAiringAt: Date?
  /// Thumbnail file name in the covers folder.
  var cover: String?
  var coverURL: URL?
  /// Cover colour "#rrggbb".
  var color: String?
  /// tsumi:// deep link opening the title in the app.
  var link: URL

  /// The next episode can be watched at `date`.
  func isAvailable(at date: Date) -> Bool {
    guard upcoming else { return true }
    guard let airingAt = nextEpisodeAiringAt else { return false }
    return airingAt <= date
  }

  /// "Ep 6 of 12" / "Ep 6".
  var episodeText: String {
    if let total, total > 0 { return "Ep \(nextEpisode) of \(total)" }
    return "Ep \(nextEpisode)"
  }

  /// 0...1 progress through the series (0 when the episode count is unknown).
  var fraction: Double {
    guard let total, total > 0 else { return 0 }
    return min(1, max(0, Double(progress) / Double(total)))
  }
}

/// An upcoming episode of a followed title.
struct TsumiWidgetAiring: Codable, Hashable, Identifiable {
  var id: String { "\(mediaId)-\(episode)" }
  /// "al-<anilistId>" or "mal-<malId>".
  var mediaId: String
  var title: String
  var episode: Int
  var totalEpisodes: Int?
  var airingAt: Date
  var cover: String?
  var coverURL: URL?
  var color: String?
  var link: URL

  /// "Episode 5" / "Episode 5 of 12".
  var episodeText: String {
    if let totalEpisodes, totalEpisodes > 0 { return "Episode \(episode) of \(totalEpisodes)" }
    return "Episode \(episode)"
  }
}

/// Array element that decodes to nil instead of failing the whole array.
struct TsumiWidgetLossy<Wrapped: Decodable>: Decodable {
  let value: Wrapped?

  init(from decoder: Decoder) throws {
    value = try? Wrapped(from: decoder)
  }
}

enum TsumiWidgetCoding {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}

/// tsumi:// links opened by the widgets (handled by Services.handle(url:) in the app).
enum TsumiWidgetLinks {
  /// Just opens the app (a route the app does not know: no navigation).
  static let openApp: URL = URL(string: "tsumi://open") ?? URL(fileURLWithPath: "/")

  /// Details of an AniList title.
  static func anime(_ anilistId: Int) -> URL {
    URL(string: "tsumi://anime/\(anilistId)") ?? openApp
  }

  /// Details of a MyAnimeList title (resolved to AniList by the app).
  static func malAnime(_ malId: Int) -> URL {
    URL(string: "tsumi://malanime/\(malId)") ?? openApp
  }

  /// Schedule tab.
  static let schedule: URL = URL(string: "tsumi://schedule/") ?? openApp

  /// Link of a media key ("al-<id>" / "mal-<id>"); nil for other sources.
  static func link(mediaKey: String) -> URL? {
    if mediaKey.hasPrefix("al-"), let id = Int(mediaKey.dropFirst(3)) { return anime(id) }
    if mediaKey.hasPrefix("mal-"), let id = Int(mediaKey.dropFirst(4)) { return malAnime(id) }
    return nil
  }
}

extension TsumiWidgetSnapshot {
  /// Reads the snapshot of a shared container folder.
  static func read(from directory: URL) -> TsumiWidgetSnapshot? {
    let url = directory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? TsumiWidgetCoding.decoder().decode(TsumiWidgetSnapshot.self, from: data)
  }

  /// Writes the snapshot atomically into a shared container folder.
  func write(to directory: URL) throws {
    let data = try TsumiWidgetCoding.encoder().encode(self)
    try data.write(to: directory.appendingPathComponent(Self.fileName), options: [.atomic])
  }
}

/// Ordering shared by both data sources.
enum TsumiWidgetOrdering {
  /// Titles with an episode to watch first (list order kept), then the ones waiting for an episode, soonest first.
  static func continueWatching(_ shows: [TsumiWidgetShow], now: Date) -> [TsumiWidgetShow] {
    let available = shows.filter { $0.isAvailable(at: now) }
    let waiting = shows.filter { !$0.isAvailable(at: now) }.sorted { lhs, rhs in
      switch (lhs.nextEpisodeAiringAt, rhs.nextEpisodeAiringAt) {
      case let (left?, right?): return left < right
      case (_?, nil): return true
      default: return false
      }
    }
    return available + waiting
  }
}
