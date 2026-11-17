import Foundation

// Stremio addon support, port of common/modules/stremio.js.
//
// A Stremio addon is described by a manifest.json (id, name, resources, types, catalogs, idPrefixes)
// and answers plain HTTP GET requests: {base}/{resource}/{type}/{id}[/{extra}].json with
// resource = catalog | meta | stream. To fit the extension system, an addon is exposed through the
// same three functions as a Sora module (searchResults, extractEpisodes, extractStreamUrl); the
// "href" passed between them is an opaque reference: "stremio:" + JSON.

struct StremioCatalogExtra: Hashable {
  var name: String
  var isRequired: Bool
}

struct StremioCatalog: Hashable {
  var type: String
  var id: String
  var name: String?
  var extra: [StremioCatalogExtra]
  var extraSupported: [String]
  var extraRequired: [String]

  init?(json: [String: Any]) {
    guard let type = ExtensionJSON.string(json["type"]), let id = ExtensionJSON.string(json["id"]) else { return nil }
    self.type = type
    self.id = id
    name = ExtensionJSON.nonEmpty(ExtensionJSON.string(json["name"]))
    extra = (json["extra"] as? [Any] ?? []).compactMap { entry -> StremioCatalogExtra? in
      guard let object = entry as? [String: Any], let name = ExtensionJSON.string(object["name"]) else { return nil }
      return StremioCatalogExtra(name: name, isRequired: (object["isRequired"] as? Bool) ?? false)
    }
    extraSupported = ExtensionJSON.strings(json["extraSupported"]) ?? []
    extraRequired = ExtensionJSON.strings(json["extraRequired"]) ?? []
  }

  /// catalogSupports(catalog, name)
  func supports(_ extraName: String) -> Bool {
    extra.contains { $0.name == extraName } || extraSupported.contains(extraName)
  }

  /// catalogRequiresExtra(catalog)
  var requiresExtra: Bool {
    extra.contains { $0.isRequired } || !extraRequired.isEmpty
  }
}

struct StremioResource: Hashable {
  var name: String
  var types: [String]?
  var idPrefixes: [String]?
  /// false for the short form ("stream"), true for { name, types, idPrefixes }.
  var isObject: Bool
}

struct StremioManifest: Hashable {
  var id: String
  var name: String?
  var version: String?
  var description: String?
  var logo: String?
  var icon: String?
  var resources: [StremioResource]
  var types: [String]
  var idPrefixes: [String]?
  var catalogs: [StremioCatalog]

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, let resourceList = json["resources"] as? [Any] else { return nil }
    self.id = id
    name = ExtensionJSON.string(json["name"])
    version = ExtensionJSON.string(json["version"])
    description = ExtensionJSON.string(json["description"])
    logo = ExtensionJSON.string(json["logo"])
    icon = ExtensionJSON.string(json["icon"])
    resources = resourceList.compactMap { entry -> StremioResource? in
      if let name = entry as? String { return StremioResource(name: name, types: nil, idPrefixes: nil, isObject: false) }
      if let object = entry as? [String: Any], let name = ExtensionJSON.string(object["name"]) {
        return StremioResource(name: name, types: ExtensionJSON.strings(object["types"]), idPrefixes: ExtensionJSON.strings(object["idPrefixes"]), isObject: true)
      }
      return nil
    }
    types = ExtensionJSON.strings(json["types"]) ?? []
    idPrefixes = ExtensionJSON.strings(json["idPrefixes"])
    catalogs = (json["catalogs"] as? [Any] ?? []).compactMap { entry in
      (entry as? [String: Any]).flatMap { StremioCatalog(json: $0) }
    }
  }

  /// resourceInfo(manifest, name)
  private func resourceInfo(_ name: String) -> (types: [String], idPrefixes: [String]?)? {
    for resource in resources where resource.name == name {
      if resource.isObject {
        return (resource.types ?? types, resource.idPrefixes ?? idPrefixes)
      }
      return (types, idPrefixes)
    }
    return nil
  }

  /// supportsResource(manifest, name, type, id)
  func supportsResource(_ name: String, type: String?, id: String?) -> Bool {
    guard let info = resourceInfo(name) else { return false }
    if let type, !type.isEmpty, !info.types.isEmpty, !info.types.contains(type) { return false }
    if let id, !id.isEmpty, let prefixes = info.idPrefixes, !prefixes.isEmpty, !prefixes.contains(where: { id.hasPrefix($0) }) {
      return false
    }
    return true
  }
}

/// Extra catalog argument (search, skip, genre...), kept in insertion order like Object.entries.
struct StremioExtraParam: Hashable {
  var name: String
  var value: String
}

/// JSON payload of an addon answer, boxed so it can cross tasks.
struct StremioPayload: @unchecked Sendable {
  let json: [String: Any]
}

/// Reference passed as `href` between searchResults / extractEpisodes / extractStreamUrl.
struct StremioRef {
  var type: String
  var id: String
  var season: Int?
  var offset: Int

  /// encodeRef: "stremio:" + JSON.stringify(ref)
  func encoded(includeSeason: Bool) -> String {
    var object: [String: Any] = ["type": type, "id": id]
    if includeSeason {
      object["season"] = season.map { $0 as Any } ?? NSNull()
      object["offset"] = offset
    }
    return "stremio:" + (ExtensionJSON.stringify(object) ?? "{}")
  }

  /// decodeRef
  static func decode(_ href: String) throws -> StremioRef {
    let raw = href.hasPrefix("stremio:") ? String(href.dropFirst("stremio:".count)) : href
    guard let object = ExtensionJSON.parse(raw) as? [String: Any],
          let type = ExtensionJSON.string(object["type"]),
          let id = ExtensionJSON.string(object["id"]) else {
      throw ExtensionFailure("Invalid Stremio reference")
    }
    let seasonNumber = ExtensionJSON.number(object["season"])
    let offsetNumber = ExtensionJSON.number(object["offset"])
    return StremioRef(
      type: type,
      id: id,
      season: seasonNumber.isFinite && seasonNumber > 0 && seasonNumber < 100_000 ? Int(seasonNumber) : nil,
      offset: offsetNumber.isFinite && abs(offsetNumber) < 1_000_000 ? Int(offsetNumber) : 0
    )
  }
}

/// What Tsumi knows about a title (resolveMediaIds).
struct StremioMediaIds {
  var tmdbId: Int
  var tmdbType: TMDBType
  var season: Int?
  var offset: Int
  var imdbHint: String?

  var stremioType: String { tmdbType == .movie ? "movie" : "series" }
}

/// One page of a catalog (loadCatalogPage) and the `skip` of the page after it.
struct StremioCatalogPage {
  var page: MediaPage
  var nextSkip: Int
}

/// A loaded addon: base URL + raw manifest (loadStremioAddon).
struct StremioAddon: Hashable {
  static let requestTimeout: TimeInterval = 45

  var base: String
  var manifest: StremioManifest

  // MARK: Manifest helpers

  /// isStremioManifest
  static func isStremioManifest(_ json: [String: Any]) -> Bool {
    ExtensionJSON.truthyString(json["scriptUrl"]) == nil && json["id"] is String && json["resources"] is [Any]
  }

  /// normalizeManifestUrl: stremio:// install links point to the same manifest over https.
  static func normalizeManifestURL(_ url: String) -> String {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("stremio://") {
      return "https://" + String(trimmed.dropFirst("stremio://".count))
    }
    return trimmed
  }

  /// addonBaseUrl
  static func baseURL(forManifest url: String) -> String {
    var value = normalizeManifestURL(url)
    if let range = value.range(of: "/manifest\\.json(\\?.*)?$", options: [.regularExpression, .caseInsensitive]) {
      value.removeSubrange(range)
    }
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  // MARK: Requests

  private static func encodeId(_ id: String) -> String {
    id.components(separatedBy: ":").map { ExtensionJSON.encodeURIComponent($0) }.joined(separator: ":")
  }

  private static func extraPath(_ extra: [StremioExtraParam]) -> String {
    let parts = extra
      .filter { !$0.value.isEmpty }
      .map { "\(ExtensionJSON.encodeURIComponent($0.name))=\(ExtensionJSON.encodeURIComponent($0.value))" }
    return parts.isEmpty ? "" : "/" + parts.joined(separator: "&")
  }

  func resourceURL(_ resource: String, type: String, id: String, extra: [StremioExtraParam]) -> URL? {
    URL.lenient("\(base)/\(resource)/\(ExtensionJSON.encodeURIComponent(type))/\(Self.encodeId(id))\(Self.extraPath(extra)).json")
  }

  /// stremioRequest: GET a resource. ttl = 0 disables caching (stream links can expire).
  func request(_ resource: String, type: String, id: String, extra: [StremioExtraParam] = [], ttl: TimeInterval = 5 * 60) async throws -> [String: Any] {
    guard let url = resourceURL(resource, type: type, id: id, extra: extra) else {
      throw ExtensionFailure("Invalid addon URL for \(resource)")
    }
    let payload = try await StremioRequestCache.shared.load(url, resource: resource, ttl: ttl)
    return payload.json
  }

  static func fetch(_ url: URL, resource: String) async throws -> StremioPayload {
    do {
      // 20 MB at most (ExtensionHTTP), so a broken or hostile addon can't exhaust the memory.
      let (data, response) = try await ExtensionHTTP.data(url, timeout: requestTimeout)
      guard (200..<300).contains(response.statusCode) else {
        throw ExtensionFailure("Addon returned HTTP \(response.statusCode) for \(resource)")
      }
      let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      return StremioPayload(json: object as? [String: Any] ?? [:])
    } catch let error as URLError where error.code == .timedOut {
      throw ExtensionFailure("Addon did not answer in time (\(resource))")
    }
  }

  // MARK: Ids

  /// tmdbFromImdb
  static func tmdbFromIMDb(_ imdbId: String, type: TMDBType) async -> Int? {
    guard let result = await ExtensionContext.shared.tmdbFindByIMDb(imdbId) else { return nil }
    let preferred = type == .movie ? result.movieIds : result.tvIds
    return preferred.first ?? result.tvIds.first ?? result.movieIds.first
  }

  /// resolveMediaIds: TMDB id and, for AniList anime, the TMDB/TVDB season + episode offset.
  static func resolveMediaIds(_ media: Media?) async -> StremioMediaIds? {
    guard let media else { return nil }
    var tmdbType: TMDBType = (media.format == .movie || media.tmdbType == .movie) ? .movie : .tv
    var tmdbId = media.tmdbId
    if tmdbId == nil, media.id.hasPrefix("tmdb-"), let last = media.id.split(separator: "-").last {
      tmdbId = Int(last)
    }
    var season: Int?
    var offset = 0
    if media.source == .anilist, let anilistId = media.anilistId,
       let map = await ExtensionContext.shared.animeToTMDB(anilistId) {
      tmdbId = tmdbId ?? map.tmdbId
      if map.isMovie { tmdbType = .movie }
      if let mapped = map.season, mapped > 0 { season = mapped }
      offset = map.episodeOffset
    }
    guard let tmdbId else { return nil }
    let hint = (media.source == .tmdb && media.tmdbType == tmdbType) ? ExtensionJSON.nonEmpty(media.imdbId) : nil
    return StremioMediaIds(tmdbId: tmdbId, tmdbType: tmdbType, season: season, offset: offset, imdbHint: hint)
  }

  /// pickAddonId: an id the addon accepts for this resource, tmdb:123 first, then the IMDb id.
  func pickAddonId(resource: String, ids: StremioMediaIds) async -> String? {
    let type = ids.stremioType
    let tmdbStremioId = "tmdb:\(ids.tmdbId)"
    if manifest.supportsResource(resource, type: type, id: tmdbStremioId) { return tmdbStremioId }
    if manifest.supportsResource(resource, type: type, id: "tt") {
      var imdbId = ids.imdbHint
      if imdbId == nil { imdbId = await ExtensionContext.shared.tmdbIMDbId(ids.tmdbId, ids.tmdbType) }
      if let imdbId, !imdbId.isEmpty, manifest.supportsResource(resource, type: type, id: imdbId) { return imdbId }
    }
    return nil
  }

  // MARK: Catalogs

  /// listCatalogs: catalogs to browse (no mandatory filter), or catalogs that can search.
  func listCatalogs(search: Bool = false) -> [StremioCatalog] {
    manifest.catalogs.filter { catalog in
      if search { return catalog.supports("search") }
      return !catalog.requiresExtra
    }
  }

  /// searchCatalogs: every searchable catalog (of the given types), deduplicated by type:id.
  func searchCatalogs(_ query: String, types: [String]?) async -> [StremioPayload] {
    let catalogs = listCatalogs(search: true).filter { types == nil || (types ?? []).contains($0.type) }
    guard !catalogs.isEmpty else { return [] }
    let addon = self
    var responses = [StremioPayload?](repeating: nil, count: catalogs.count)
    await withTaskGroup(of: (Int, StremioPayload?).self) { group in
      for (index, catalog) in catalogs.enumerated() {
        group.addTask {
          let json = try? await addon.request("catalog", type: catalog.type, id: catalog.id, extra: [StremioExtraParam(name: "search", value: query)])
          return (index, json.map { StremioPayload(json: $0) })
        }
      }
      for await (index, payload) in group { responses[index] = payload }
    }
    var results: [StremioPayload] = []
    var seen = Set<String>()
    for (index, response) in responses.enumerated() {
      guard let response else { continue }
      for case let meta as [String: Any] in (response.json["metas"] as? [Any] ?? []) {
        let type = ExtensionJSON.string(meta["type"]) ?? catalogs[index].type
        let key = "\(type):\(ExtensionJSON.string(meta["id"]) ?? "")"
        if seen.contains(key) { continue }
        seen.insert(key)
        var copy = meta
        copy["type"] = type
        results.append(StremioPayload(json: copy))
      }
    }
    return results
  }

  /// metaToMedia: a Stremio catalog item as a TMDB media (nil when no TMDB id can be found). Items of anime addons
  /// (kitsu:, mal:, anilist: ids) are their AniList entry (nil when it can't be found).
  static func metaToMedia(_ meta: [String: Any], fallbackType: String) async -> Media? {
    let stremioType = ExtensionJSON.truthyString(meta["type"]) ?? fallbackType
    let tmdbType: TMDBType = stremioType == "movie" ? .movie : .tv
    let id = ExtensionJSON.string(meta["id"]) ?? ""
    if let animeId = StremioAnimeIds.parse(id) {
      guard let anilistId = await StremioAnimeIds.shared.anilistId(animeId) else { return nil }
      return await AniListService.shared.requestMedia(id: anilistId)
    }
    var tmdbId: Int?
    if id.hasPrefix("tmdb:") {
      let parts = id.components(separatedBy: ":")
      if parts.count > 1, let value = Int(parts[1]), value != 0 { tmdbId = value }
    } else if id.range(of: "^tt\\d+", options: .regularExpression) != nil {
      let imdb = id.components(separatedBy: ":").first ?? id
      tmdbId = await tmdbFromIMDb(imdb, type: tmdbType)
    }
    guard let tmdbId else { return nil }

    let yearSource = ExtensionJSON.truthyString(meta["releaseInfo"]) ?? ExtensionJSON.truthyString(meta["year"]) ?? ""
    let year = parseLeadingInt(String(yearSource.prefix(4)))
    let name = ExtensionJSON.truthyString(meta["name"]) ?? "Unknown Title"
    let poster = ExtensionJSON.truthyString(meta["poster"])
    var largePoster = poster
    if let poster, poster.contains("image.tmdb.org") {
      largePoster = poster.replacingOccurrences(of: "/w\\d+/", with: "/w500/", options: .regularExpression)
    }

    var status: MediaStatus = .releasing
    if let year {
      var components = DateComponents()
      components.year = year
      components.month = 1
      components.day = 1
      if let date = Calendar(identifier: .gregorian).date(from: components) {
        status = date.timeIntervalSinceNow <= 86_400 ? .releasing : .notYetReleased
      }
    }

    var media = Media(
      id: Media.tmdbKey(tmdbId, tmdbType),
      source: .tmdb,
      anilistId: ExtensionContext.shared.tmdbToAnilistId(tmdbId, tmdbType),
      malId: nil,
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      imdbId: id.hasPrefix("tt") ? id.components(separatedBy: ":").first : nil,
      title: MediaTitle(romaji: name, english: name, native: name, userPreferred: name),
      images: MediaImages(cover: URL.lenient(poster), coverLarge: URL.lenient(largePoster), banner: URL.lenient(ExtensionJSON.truthyString(meta["background"])), logo: URL.lenient(ExtensionJSON.truthyString(meta["logo"])), color: nil),
      format: tmdbType == .movie ? .movie : .tv,
      status: status,
      description: ExtensionJSON.string(meta["description"])
    )
    media.episodes = tmdbType == .movie ? 1 : nil
    media.seasonYear = year
    if let genres = ExtensionJSON.strings(meta["genres"]), !genres.isEmpty { media.genres = genres }
    if let ratingText = ExtensionJSON.string(meta["imdbRating"]), let rating = Double(ratingText.trimmingCharacters(in: .whitespaces)),
       rating.isFinite, rating >= 0, rating <= 100 {
      media.averageScore = Int((rating * 10).rounded())
    }
    return media
  }

  /// parseInt(text) for the leading digits (nil for NaN and 0, like `|| null`).
  private static func parseLeadingInt(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
    guard let value = Int(digits), value != 0 else { return nil }
    return value
  }

  /// metasToPage
  static func metasToPage(_ metas: [StremioPayload], fallbackType: String, hasNextPage: Bool) async -> MediaPage {
    var items = [Media?](repeating: nil, count: metas.count)
    await withTaskGroup(of: (Int, Media?).self) { group in
      for (index, meta) in metas.enumerated() {
        group.addTask { (index, await StremioAddon.metaToMedia(meta.json, fallbackType: fallbackType)) }
      }
      for await (index, media) in group { items[index] = media }
    }
    return MediaPage(items: items.compactMap { $0 }, hasNextPage: hasNextPage)
  }

  /// loadCatalogPage: one page of a catalog, from `skip`; Stremio pages with "skip" (several batches per page, at
  /// least `perPage` items when the catalog has them). Every item read is kept (no truncation), and `nextSkip` is
  /// the real position after them (the sum of the batch sizes): addons that read skip as a page boundary would
  /// otherwise skip or repeat items.
  func loadCatalogPage(_ catalog: StremioCatalog, skip: Int = 0, perPage: Int = 50, extra: [StremioExtraParam] = []) async throws -> StremioCatalogPage {
    let canSkip = catalog.supports("skip")
    if skip > 0 && !canSkip { return StremioCatalogPage(page: .empty, nextSkip: skip) }
    var metas: [StremioPayload] = []
    var cursor = skip
    var lastBatch = 0
    var attempt = 0
    while attempt < 6 && metas.count < perPage {
      attempt += 1
      var params = extra
      if cursor > 0 { params.append(StremioExtraParam(name: "skip", value: String(cursor))) }
      let response = try await request("catalog", type: catalog.type, id: catalog.id, extra: params)
      let batch = (response["metas"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
      lastBatch = batch.count
      if batch.isEmpty { break }
      metas.append(contentsOf: batch.map { StremioPayload(json: $0) })
      cursor += batch.count
      if !canSkip { break }
    }
    let page = await Self.metasToPage(metas, fallbackType: catalog.type, hasNextPage: canSkip && lastBatch > 0)
    return StremioCatalogPage(page: page, nextSkip: cursor)
  }

  // MARK: Sora-compatible functions

  /// searchResults(ext, title, media)
  func searchResults(title: String, media: Media?) async throws -> [ExtensionSearchItem] {
    let ids = await Self.resolveMediaIds(media)

    // Tsumi already knows the exact title: ask the addon by id, no guessing.
    if let ids, let id = await pickAddonId(resource: "stream", ids: ids) {
      let fallbackTitle = ExtensionJSON.nonEmpty(title) ?? ExtensionJSON.nonEmpty(media?.title.userPreferred) ?? id
      let image = media?.images.coverLarge ?? media?.images.cover
      let ref = StremioRef(type: ids.stremioType, id: id, season: ids.season, offset: ids.offset)
      return [ExtensionSearchItem(title: fallbackTitle, image: image?.absoluteString ?? "", href: ref.encoded(includeSeason: true))]
    }

    // Otherwise fall back to the addon's own search.
    if title.isEmpty { return [] }
    let types: [String]?
    if let ids {
      types = [ids.stremioType]
    } else if let media {
      types = [media.format == .movie ? "movie" : "series"]
    } else {
      types = nil
    }
    let metas = await searchCatalogs(title, types: types)
    return metas.map { meta in
      let type = ExtensionJSON.string(meta.json["type"]) ?? ""
      let id = ExtensionJSON.string(meta.json["id"]) ?? ""
      return ExtensionSearchItem(
        title: ExtensionJSON.string(meta.json["name"]) ?? "",
        image: ExtensionJSON.truthyString(meta.json["poster"]) ?? "",
        href: StremioRef(type: type, id: id, season: nil, offset: 0).encoded(includeSeason: false)
      )
    }
  }

  /// videosFromTmdb: episode list built from TMDB seasons when the addon has no meta.
  private static func videosFromTMDB(_ id: String) async -> [[String: Any]] {
    var tmdbId: Int?
    if id.hasPrefix("tmdb:") {
      let parts = id.components(separatedBy: ":")
      if parts.count > 1 { tmdbId = Int(parts[1]) }
    } else if id.hasPrefix("tt") {
      tmdbId = await tmdbFromIMDb(id, type: .tv)
    }
    guard let tmdbId else { return [] }
    var videos: [[String: Any]] = []
    let seasons = await ExtensionContext.shared.tmdbSeasons(tmdbId)
    for season in seasons where season.episodeCount > 0 {
      for episode in 1...season.episodeCount {
        videos.append(["id": "\(id):\(season.seasonNumber):\(episode)", "season": season.seasonNumber, "episode": episode])
      }
    }
    return videos
  }

  /// extractEpisodes(ext, href)
  func extractEpisodes(href: String) async throws -> [ExtensionEpisode] {
    let ref = try StremioRef.decode(href)
    if ref.type == "movie" {
      let movieRef = StremioRef(type: "movie", id: ref.id, season: nil, offset: 0)
      return [ExtensionEpisode(number: 1, season: nil, title: "Movie", href: movieRef.encoded(includeSeason: false))]
    }

    var videos: [[String: Any]] = []
    if manifest.supportsResource("meta", type: ref.type, id: ref.id) {
      if let response = try? await request("meta", type: ref.type, id: ref.id, ttl: 30 * 60) {
        let meta = response["meta"] as? [String: Any]
        videos = (meta?["videos"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
      }
    }
    if videos.isEmpty { videos = await Self.videosFromTMDB(ref.id) }

    var episodes: [ExtensionEpisode] = []
    for video in videos {
      let rawSeason = video["season"]
      let hasSeason = !ExtensionJSON.isNullish(rawSeason)
      if hasSeason && !(ExtensionJSON.number(rawSeason) > 0) { continue }
      let rawNumber = ExtensionJSON.isNullish(video["episode"]) ? video["number"] : video["episode"]
      let number = ExtensionJSON.number(rawNumber)
      guard number.isFinite else { continue }
      let videoRef = StremioRef(type: ref.type, id: ExtensionJSON.string(video["id"]) ?? "", season: nil, offset: 0)
      episodes.append(ExtensionEpisode(
        number: number,
        season: hasSeason ? ExtensionJSON.number(rawSeason) : nil,
        title: ExtensionJSON.truthyString(video["title"]) ?? ExtensionJSON.truthyString(video["name"]) ?? "",
        href: videoRef.encoded(includeSeason: false)
      ))
    }
    episodes = episodes.enumerated().sorted { lhs, rhs in
      let leftSeason = lhs.element.season ?? 0
      let rightSeason = rhs.element.season ?? 0
      if leftSeason != rightSeason { return leftSeason < rightSeason }
      if lhs.element.number != rhs.element.number { return lhs.element.number < rhs.element.number }
      return lhs.offset < rhs.offset
    }.map { $0.element }

    // AniList entries are one season each: keep that season and number episodes the way
    // AniList does (after the mapping's episode offset).
    if let season = ref.season, season > 0 {
      let offset = Double(ref.offset)
      let inSeason = episodes.filter { $0.season == Double(season) && $0.number > offset }
      if !inSeason.isEmpty {
        episodes = inSeason.map { episode in
          var copy = episode
          copy.season = nil
          copy.number = episode.number - offset
          return copy
        }
      }
    }
    return episodes
  }

  /// streamTitle(stream, index)
  static func streamTitle(_ stream: [String: Any], index: Int) -> String {
    func lines(_ value: Any?) -> [String] {
      (ExtensionJSON.string(value) ?? "")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    let name = lines(stream["name"])
    let details = lines(ExtensionJSON.truthyString(stream["title"]) ?? ExtensionJSON.string(stream["description"]))
      .filter { line in !name.contains { $0.contains(line) } }
    let joined = (name + details).joined(separator: " · ")
    return joined.isEmpty ? "Server \(index + 1)" : joined
  }

  /// pickSubtitle: French first, else the first subtitle.
  static func pickSubtitle(_ subtitles: Any?) -> String? {
    guard let list = subtitles as? [Any], !list.isEmpty else { return nil }
    let objects = list.compactMap { $0 as? [String: Any] }
    let french = objects.first { subtitle in
      let lang = ExtensionJSON.string(subtitle["lang"]) ?? ""
      return lang.range(of: "^(fr|fre|fra|french)", options: [.regularExpression, .caseInsensitive]) != nil
    }
    let chosen = french ?? (list.first as? [String: Any])
    return ExtensionJSON.truthyString(chosen?["url"])
  }

  /// extractStreamUrl(ext, href): `{ streams: [{ title, streamUrl, headers }], subtitles }` for parseStreamResponse.
  func extractStreamUrl(href: String) async throws -> [String: Any] {
    let ref = try StremioRef.decode(href)
    let response = try await request("stream", type: ref.type, id: ref.id, ttl: 0)
    let all = (response["streams"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    let playable = all.filter { stream in
      guard let url = stream["url"] as? String else { return false }
      return url.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }
    guard let first = playable.first else {
      throw ExtensionFailure(all.isEmpty
        ? "No streams found for this title"
        : "This addon only returned peer-to-peer or external links, which Tsumi cannot play")
    }
    let streams: [[String: Any]] = playable.enumerated().map { item -> [String: Any] in
      let stream = item.element
      let hints = stream["behaviorHints"] as? [String: Any]
      let proxy = hints?["proxyHeaders"] as? [String: Any]
      return [
        "title": StremioAddon.streamTitle(stream, index: item.offset),
        "streamUrl": stream["url"] as? String ?? "",
        "headers": ExtensionJSON.headers(proxy?["request"])
      ]
    }
    var result: [String: Any] = ["streams": streams]
    result["subtitles"] = Self.pickSubtitle(first["subtitles"]) ?? NSNull()
    return result
  }

  /// callStremioFunction: generic entry used by ExtensionCalls.call (JSON-like results).
  func call(_ functionName: String, arguments: [Any]) async throws -> Any? {
    switch functionName {
    case "searchResults":
      let title = arguments.first as? String ?? ""
      let media = arguments.count > 1 ? arguments[1] as? Media : nil
      let items = try await searchResults(title: title, media: media)
      return items.map { ["title": $0.title, "image": $0.image, "href": $0.href] }
    case "extractEpisodes":
      let episodes = try await extractEpisodes(href: arguments.first as? String ?? "")
      return episodes.map { episode -> [String: Any] in
        var object: [String: Any] = ["number": episode.number, "title": episode.title ?? "", "href": episode.href]
        object["season"] = episode.season.map { $0 as Any } ?? NSNull()
        return object
      }
    case "extractStreamUrl":
      return try await extractStreamUrl(href: arguments.first as? String ?? "")
    default:
      throw ExtensionFailure("Stremio addons do not support \(functionName)")
    }
  }

  static func == (lhs: StremioAddon, rhs: StremioAddon) -> Bool {
    lhs.base == rhs.base && lhs.manifest.id == rhs.manifest.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(base)
    hasher.combine(manifest.id)
  }
}

/// Request cache of stremio.js (`requestCache`): same URL within the TTL shares one request,
/// failed requests are dropped from the cache. Bounded: expired answers are dropped, and above `capacity` the least
/// recently used ones go first (the desktop cache grew for the whole session).
///
/// Cancellation: an uncached request (ttl 0, streams) runs in the caller's task, so cancelling the caller stops it at
/// once. A shared request runs in its own task; it is cancelled (and dropped from the cache) when every caller
/// waiting for it was cancelled, which also ends their wait. A cancelled caller sharing it with others keeps waiting
/// for the answer (bounded by the request timeouts).
actor StremioRequestCache {
  static let shared = StremioRequestCache()
  /// Answers kept at most (catalog pages, metas, searches).
  static let capacity = 200

  private struct Entry {
    var id: UUID
    var expires: Date
    var lastUsed: Date
    var task: Task<StremioPayload, Error>
    /// Callers waiting for the answer.
    var waiters: Set<UUID> = []
    /// The answer arrived (a cached answer is never cancelled).
    var done = false
  }

  private var entries: [String: Entry] = [:]

  func load(_ url: URL, resource: String, ttl: TimeInterval) async throws -> StremioPayload {
    guard ttl > 0 else {
      return try await StremioAddon.fetch(url, resource: resource)
    }
    let key = url.absoluteString
    let now = Date()
    if var entry = entries[key], entry.expires > now {
      entry.lastUsed = now
      entries[key] = entry
    } else {
      let task = Task.detached { try await StremioAddon.fetch(url, resource: resource) }
      entries[key] = Entry(id: UUID(), expires: now.addingTimeInterval(ttl), lastUsed: now, task: task)
      prune(now: now)
    }
    guard let entry = entries[key] else {
      // Dropped at once by the pruning (not expected): a request of its own.
      return try await StremioAddon.fetch(url, resource: resource)
    }
    let id = entry.id
    let task = entry.task
    let waiter = UUID()
    entries[key]?.waiters.insert(waiter)
    do {
      let payload = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        Task { await self.leave(key, id: id, waiter: waiter, cancelled: true) }
      }
      if entries[key]?.id == id { entries[key]?.done = true }
      leave(key, id: id, waiter: waiter, cancelled: false)
      return payload
    } catch {
      if entries[key]?.id == id { entries[key] = nil }
      throw error
    }
  }

  /// A caller stops waiting. When it was cancelled and nobody else waits for an answer still in progress, the request
  /// is cancelled and dropped (a later caller starts a new one).
  private func leave(_ key: String, id: UUID, waiter: UUID, cancelled: Bool) {
    guard var entry = entries[key], entry.id == id else { return }
    entry.waiters.remove(waiter)
    if cancelled && entry.waiters.isEmpty && !entry.done {
      entry.task.cancel()
      entries[key] = nil
      return
    }
    entries[key] = entry
  }

  /// Drops the expired answers, then the least recently used ones above `capacity`.
  private func prune(now: Date) {
    entries = entries.filter { $0.value.expires > now }
    guard entries.count > Self.capacity else { return }
    let overflow = entries.count - Self.capacity
    let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(overflow).map { $0.key }
    for key in oldest {
      entries[key] = nil
    }
  }

  func clear() { entries.removeAll() }
}

/// Ids of anime addons (Kitsu, MyAnimeList and AniList catalogs: "kitsu:123", "mal:456", "anilist:789", episode ids
/// add ":<n>") as AniList ids, so their items open the AniList entry: AniList ids as they are, MyAnimeList ids through
/// the animap index of AnimeMappingsService, Kitsu ids (and MyAnimeList ids animap does not know) through
/// api.ani.zip, cached on disk.
actor StremioAnimeIds {
  enum AnimeId: Hashable {
    case anilist(Int)
    case mal(Int)
    case kitsu(Int)
  }

  private enum Lookup {
    case found(Int)
    case notFound
    case failed
  }

  static let shared = StremioAnimeIds()

  /// MyAnimeList id -> AniList id, built once from animap.
  private var malIndex: [Int: Int] = [:]
  private var malIndexBuilt: Date?
  /// Build of `malIndex` in progress, shared by the lookups made meanwhile (every item of a catalog page at once).
  private var malIndexTask: Task<[Int: Int], Never>?
  private var resolved: [AnimeId: Int] = [:]
  /// Ids ani.zip does not know (not asked again this session).
  private var missing: Set<AnimeId> = []
  private var inflight: [AnimeId: Task<Lookup, Never>] = [:]

  static func parse(_ id: String) -> AnimeId? {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let value = Int(parts[1]), value > 0 else { return nil }
    switch parts[0].lowercased() {
    case "anilist": return .anilist(value)
    case "mal": return .mal(value)
    case "kitsu": return .kitsu(value)
    default: return nil
    }
  }

  func anilistId(_ id: AnimeId) async -> Int? {
    switch id {
    case .anilist(let value):
      return value
    case .mal(let value):
      if let mapped = await malToAnilist(value) { return mapped }
    case .kitsu:
      break
    }
    if let known = resolved[id] { return known }
    if missing.contains(id) { return nil }
    let task: Task<Lookup, Never>
    if let running = inflight[id] {
      task = running
    } else {
      task = Task { await StremioAnimeIds.lookup(id) }
      inflight[id] = task
    }
    let result = await task.value
    inflight[id] = nil
    switch result {
    case .found(let value):
      resolved[id] = value
      return value
    case .notFound:
      missing.insert(id)
      return nil
    case .failed:
      return nil
    }
  }

  private func malToAnilist(_ malId: Int) async -> Int? {
    // Built again when animap was not available (offline), at most every 5 minutes.
    let stale = malIndexBuilt.map { malIndex.isEmpty && Date().timeIntervalSince($0) > 300 } ?? true
    if stale {
      // One build, awaited by every lookup made meanwhile: they no longer see an empty index marked fresh (and all
      // go to api.ani.zip) while the first one builds it.
      let task: Task<[Int: Int], Never>
      if let running = malIndexTask {
        task = running
      } else {
        task = Task { await StremioAnimeIds.buildMalIndex() }
        malIndexTask = task
      }
      let map = await task.value
      if malIndexTask == task {
        malIndexTask = nil
        malIndex = map
        malIndexBuilt = Date()
      }
    }
    return malIndex[malId]
  }

  private static func buildMalIndex() async -> [Int: Int] {
    let index = await AnimeMappingsService.shared.animapIndex()
    var map: [Int: Int] = [:]
    for entry in index.byAnilist.values {
      if let mal = entry.malId, map[mal] == nil { map[mal] = entry.anilistId }
    }
    return map
  }

  private static func lookup(_ id: AnimeId) async -> Lookup {
    let query: String
    switch id {
    case .anilist(let value):
      return .found(value)
    case .mal(let value):
      query = "mal_id=\(value)"
    case .kitsu(let value):
      query = "kitsu_id=\(value)"
    }
    let cacheKey = "stremio.anime." + query
    if let cached = await DiskCache.shared.get(cacheKey, as: Int.self) { return .found(cached) }
    guard let url = URL(string: "https://api.ani.zip/mappings?" + query) else { return .failed }
    do {
      let (data, response) = try await HTTP.data(url, timeout: 20, allowErrorStatus: true)
      if response.statusCode == 404 { return .notFound }
      guard (200..<300).contains(response.statusCode) else { return .failed }
      let mappings = try JSONDecoder().decode(AniZipMappings.self, from: data)
      guard let anilistId = mappings.mappings?.anilistId, anilistId > 0 else { return .notFound }
      await DiskCache.shared.set(cacheKey, anilistId, ttl: 30 * 86400)
      return .found(anilistId)
    } catch {
      return .failed
    }
  }
}
