import Foundation
import SwiftUI

// Online subtitles (subs.wing.st), port of common/modules/onlinesubs/ (core.js, index.js) and
// common/routes/player/OnlineSubtitles.svelte: "Search Online Subtitles…" in the subtitle menu (list grouped by
// language, preferred language first, release names), and "Automatic Online Subtitles" (settings
// `onlineSubtitlesAuto`) when the source has no subtitle track.
//
// API (no public docs, observed): GET /subtitles?type=tv&tmdb=<id>&season=<s>&episode=<e> or ?type=movie&tmdb=<id>
// -> { total, subtitles: [{ id, language: "en", url, type: "srt", display: "<release>.srt", source, voteRef }] }.
// Only "movie" and "tv" exist; season and episode are required for tv. Files are UTF-8 SRT.

struct OnlineSubtitle: Identifiable, Hashable, Sendable {
  /// The file URL (unique once duplicates are removed).
  var id: String { url.absoluteString }
  let url: URL
  /// ISO 639-1 code, "und" when the provider gives none.
  let language: String
  /// Release / file name.
  let name: String
  let source: String
  let format: String

  var languageName: String { OnlineSubtitlesService.languageName(language) }

  /// Track name in the subtitle menu: "English - <release without extension>".
  var trackName: String {
    let release = OnlineSubtitlesService.releaseName(name)
    return release.isEmpty ? languageName : "\(languageName) - \(release)"
  }
}

struct OnlineSubtitleGroup: Identifiable, Hashable {
  var id: String { language }
  let language: String
  let name: String
  let items: [OnlineSubtitle]
}

enum OnlineSubtitlesError: LocalizedError {
  case noMatch
  case busy
  case unavailable(Int)
  case download(Int)
  case empty
  case notSubtitles
  case episodeChanged

  var errorDescription: String? {
    switch self {
    case .noMatch: return "This title has no TMDB match, so online subtitles cannot be searched."
    case .busy: return "The subtitle service is busy, try again in a minute."
    case .unavailable(let code): return "The subtitle service is unavailable (error \(code))."
    case .download(let code): return "The subtitle file could not be downloaded (error \(code))."
    case .empty: return "The subtitle file is empty."
    case .notSubtitles: return "This file does not contain subtitles."
    case .episodeChanged: return "The video changed while the subtitles were loading."
    }
  }
}

/// Search (cached per episode for an hour) and downloads (a few kept for the session).
actor OnlineSubtitlesService {
  static let shared = OnlineSubtitlesService()
  static let api = "https://subs.wing.st"

  struct Query: Hashable, Sendable {
    let type: String
    let tmdb: Int
    var season: Int?
    var episode: Int?

    var url: URL? {
      var components = URLComponents(string: "\(OnlineSubtitlesService.api)/subtitles")
      var items = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "tmdb", value: String(tmdb))]
      if type == "tv", let season, let episode {
        items.append(URLQueryItem(name: "season", value: String(season)))
        items.append(URLQueryItem(name: "episode", value: String(episode)))
      }
      components?.queryItems = items
      return components?.url
    }
  }

  struct SeasonEpisode: Hashable, Sendable {
    let season: Int
    let episode: Int
  }

  private var searches: [String: (date: Date, list: [OnlineSubtitle])] = [:]
  private var files: [URL: Data] = [:]
  private var fileOrder: [URL] = []

  /// Subtitles of an episode (or movie): tries each numbering until one has results.
  func search(media: Media, episode: EpisodeRef, force: Bool = false) async throws -> [OnlineSubtitle] {
    let key = "\(media.id):\(episode.number):\(episode.season ?? 0):\(episode.localEpisode ?? 0)"
    if !force, let cached = searches[key], Date().timeIntervalSince(cached.date) < 3600 { return cached.list }
    let queries = await Self.queries(media: media, episode: episode)
    guard !queries.isEmpty else { throw OnlineSubtitlesError.noMatch }
    var answered = false
    var lastError: Error?
    for query in queries {
      do {
        let list = try await Self.fetch(query)
        answered = true
        if !list.isEmpty {
          searches[key] = (Date(), list)
          return list
        }
      } catch {
        lastError = error
      }
    }
    if !answered, let lastError { throw lastError }
    searches[key] = (Date(), [])
    return []
  }

  func download(_ subtitle: OnlineSubtitle) async throws -> Data {
    if let data = files[subtitle.url] { return data }
    let (data, response) = try await HTTP.data(subtitle.url, timeout: 30, allowErrorStatus: true)
    guard (200..<300).contains(response.statusCode) else { throw OnlineSubtitlesError.download(response.statusCode) }
    guard !data.isEmpty else { throw OnlineSubtitlesError.empty }
    files[subtitle.url] = data
    fileOrder.append(subtitle.url)
    if fileOrder.count > 20 { files[fileOrder.removeFirst()] = nil }
    return data
  }

  // MARK: - Requests

  static func fetch(_ query: Query) async throws -> [OnlineSubtitle] {
    guard let url = query.url else { throw OnlineSubtitlesError.noMatch }
    let (data, response) = try await HTTP.data(url, timeout: 20, allowErrorStatus: true)
    if response.statusCode == 429 { throw OnlineSubtitlesError.busy }
    guard (200..<300).contains(response.statusCode) else { throw OnlineSubtitlesError.unavailable(response.statusCode) }
    return parse(data)
  }

  /// Requests to try: the TMDB id of TMDB titles (season / episode from the episode, else from the TMDB seasons),
  /// the TMDB id and TVDB numbering of ani.zip for anime (animap as a fallback), then absolute numbering.
  static func queries(media: Media, episode: EpisodeRef) async -> [Query] {
    let number = episode.number
    if media.source == .tmdb {
      guard let tmdb = media.tmdbId else { return [] }
      if media.isMovie { return [Query(type: "movie", tmdb: tmdb)] }
      var pairs: [SeasonEpisode] = []
      if let season = episode.season, let local = episode.localEpisode, season > 0, local > 0 {
        pairs.append(SeasonEpisode(season: season, episode: local))
      } else if let details = await TMDBService.shared.details(id: tmdb, type: .tv),
                let mapped = tmdbSeasonEpisode(details.seasons, absolute: number) {
        pairs.append(mapped)
      }
      if number > 0 { pairs.append(SeasonEpisode(season: 1, episode: number)) }
      return unique(pairs).map { Query(type: "tv", tmdb: tmdb, season: $0.season, episode: $0.episode) }
    }
    guard let anilistId = media.anilistId else { return [] }
    async let aniZipLookup = AnimeMappingsService.shared.aniZip(anilistId: anilistId)
    async let animapLookup = AnimeMappingsService.shared.tmdbInfo(anilistId: anilistId)
    let (aniZip, animap) = await (aniZipLookup, animapLookup)
    guard let tmdb = aniZip?.mappings?.tmdbId ?? media.tmdbId ?? animap?.tmdbId else { return [] }
    let type = (aniZip?.mappings?.type ?? animap?.mediaType ?? "").uppercased()
    if media.format == .movie || type == "MOVIE" || media.tmdbType == .movie {
      return [Query(type: "movie", tmdb: tmdb)]
    }
    let pairs = episodeCandidates(
      episode: number,
      aniEpisode: aniZip?.episodes[String(number)],
      tvdbSeason: animap?.tvdbSeason,
      tvdbOffset: animap?.tvdbEpoffset
    )
    return pairs.map { Query(type: "tv", tmdb: tmdb, season: $0.season, episode: $0.episode) }
  }

  // MARK: - Pure helpers (same as core.js)

  /// TVDB numbering of ani.zip, then absolute numbering (some shows are filed under one long season: One Piece
  /// episode 1000 is S1E1000, not S21E109), then the animap TVDB season + offset, then the episode itself.
  static func episodeCandidates(episode: Int, aniEpisode: AniZipEpisode?, tvdbSeason: Int?, tvdbOffset: Int?) -> [SeasonEpisode] {
    var pairs: [SeasonEpisode] = []
    func add(_ season: Int?, _ number: Int?) {
      guard let season, let number, season > 0, number > 0 else { return }
      pairs.append(SeasonEpisode(season: season, episode: number))
    }
    if let aniEpisode {
      add(aniEpisode.seasonNumber, aniEpisode.episodeNumber)
      add(1, aniEpisode.absoluteEpisodeNumber)
    }
    if let tvdbSeason, tvdbSeason > 0 { add(tvdbSeason, episode + (tvdbOffset ?? 0)) }
    add(1, episode)
    return unique(pairs)
  }

  /// Season and episode of an absolute episode number of a TMDB show (specials excluded).
  static func tmdbSeasonEpisode(_ seasons: [TMDBSeasonInfo], absolute: Int) -> SeasonEpisode? {
    guard absolute > 0 else { return nil }
    var remaining = absolute
    for season in seasons.filter({ $0.seasonNumber > 0 }).sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
      if remaining <= season.episodeCount { return SeasonEpisode(season: season.seasonNumber, episode: remaining) }
      remaining -= season.episodeCount
    }
    return nil
  }

  private static func unique(_ pairs: [SeasonEpisode]) -> [SeasonEpisode] {
    var seen = Set<SeasonEpisode>()
    return pairs.filter { seen.insert($0).inserted }
  }

  /// Valid https URLs only, language codes normalized, duplicate releases (same language and file name) removed.
  static func parse(_ data: Data) -> [OnlineSubtitle] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    var seen = Set<String>()
    var list: [OnlineSubtitle] = []
    for entry in (json["subtitles"] as? [[String: Any]]) ?? [] {
      guard let link = entry["url"] as? String, link.lowercased().hasPrefix("https://"), let url = URL(string: link) else { continue }
      let language = normalizeLanguage(entry["language"] as? String) ?? "und"
      let display = ((entry["display"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let name = display.isEmpty ? "Subtitles" : display
      let key = "\(language)|\(name.lowercased())"
      if seen.contains(key) || seen.contains(link) { continue }
      seen.insert(key)
      seen.insert(link)
      list.append(OnlineSubtitle(
        url: url,
        language: language,
        name: name,
        source: (entry["source"] as? String) ?? "",
        format: ((entry["type"] as? String) ?? "srt").lowercased()
      ))
    }
    return list
  }

  /// Preferred Subtitle Language setting (codes of PlayerTab.svelte) -> ISO 639-1.
  static let settingToISO: [String: String] = [
    "eng": "en", "jpn": "ja", "chi": "zh", "por": "pt", "spa": "es", "lat": "es", "ger": "de", "pol": "pl",
    "cze": "cs", "dan": "da", "gre": "el", "fin": "fi", "fre": "fr", "hun": "hu", "ita": "it", "kor": "ko",
    "dut": "nl", "nor": "no", "rum": "ro", "rus": "ru", "slo": "sk", "swe": "sv", "ara": "ar", "idn": "id"
  ]

  private static let aliases: [String: String] = ["nb": "no", "nn": "no", "iw": "he", "in": "id", "ji": "yi", "jw": "jv", "pb": "pt", "ze": "zh"]

  /// Lower-case primary language subtag ("pt-BR" -> "pt", "nb" -> "no"); nil when unknown.
  static func normalizeLanguage(_ code: String?) -> String? {
    let lower = (code ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let primary = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    guard (2...3).contains(primary.count), primary.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
    return aliases[primary] ?? primary
  }

  /// ISO code of the Preferred Subtitle Language; English when it is None or unknown.
  static func preferredLanguage(_ setting: String) -> String {
    let value = setting.lowercased()
    if value.isEmpty { return "en" }
    return settingToISO[value] ?? normalizeLanguage(value) ?? "en"
  }

  static func languageName(_ code: String) -> String {
    guard !code.isEmpty, code != "und" else { return "Unknown" }
    if let name = Locale(identifier: "en").localizedString(forLanguageCode: code), name.lowercased() != code.lowercased() {
      return name
    }
    return code.uppercased()
  }

  static func releaseName(_ name: String) -> String {
    var release = name
    for suffix in [".srt", ".vtt", ".ass", ".ssa", ".sub", ".txt"] where release.lowercased().hasSuffix(suffix) {
      release = String(release.dropLast(suffix.count))
      break
    }
    return release.trimmingCharacters(in: .whitespaces)
  }

  /// The preferred language first, then English, then the others by name.
  static func groups(_ list: [OnlineSubtitle], preferred: String) -> [OnlineSubtitleGroup] {
    var order: [String] = []
    var byLanguage: [String: [OnlineSubtitle]] = [:]
    for item in list {
      if byLanguage[item.language] == nil { order.append(item.language) }
      byLanguage[item.language, default: []].append(item)
    }
    func rank(_ language: String) -> Int { language == preferred ? 0 : (language == "en" ? 1 : 2) }
    return order
      .map { OnlineSubtitleGroup(language: $0, name: languageName($0), items: byLanguage[$0] ?? []) }
      .sorted { lhs, rhs in
        let left = rank(lhs.language)
        let right = rank(rhs.language)
        if left != right { return left < right }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  /// "Automatic Online Subtitles": first SRT in the preferred language.
  static func pickAutomatic(_ list: [OnlineSubtitle], preferred: String) -> OnlineSubtitle? {
    let matching = list.filter { $0.language == preferred }
    return matching.first { $0.format == "srt" } ?? matching.first
  }

  static func message(for error: Error) -> String {
    if let error = error as? OnlineSubtitlesError { return error.errorDescription ?? "Something went wrong while loading subtitles." }
    if let error = error as? URLError {
      if error.code == .timedOut { return "The subtitle service took too long to answer." }
      return "Could not reach the subtitle service. Check your connection."
    }
    return error.localizedDescription
  }
}

// MARK: - Player

extension PlayerController {
  /// Downloads an online subtitle and adds it as an external track (selected unless `select` is false, which
  /// leaves the choice to the remembered track / preferred language logic).
  func addOnlineSubtitle(_ subtitle: OnlineSubtitle, select: Bool = true) async throws {
    let media = session.media
    let episode = session.episode
    let data = try await OnlineSubtitlesService.shared.download(subtitle)
    let format = ["srt", "vtt", "ass", "ssa", "sub"].contains(subtitle.format) ? subtitle.format : "srt"
    let cues = await Task.detached(priority: .userInitiated) {
      PlayerSubtitleParser.parse(data: data, fileExtension: format)
    }.value
    guard session.media.id == media.id, session.episode == episode else { throw OnlineSubtitlesError.episodeChanged }
    guard !cues.isEmpty else { throw OnlineSubtitlesError.notSubtitles }
    addExternalTrack(name: subtitle.trackName, cues: cues, select: select)
  }

  /// "Automatic Online Subtitles": once the stream is ready and the extension subtitle file had time to load,
  /// adds the first online subtitle in the preferred language when the episode has no subtitle track. Quiet on
  /// failure. Called for every episode (PlayerController.begin). Not when the show's remembered subtitle is OFF
  /// (PC `subtitlesOff`): the track would stay off anyway, so no search, download or notice.
  func scheduleAutomaticOnlineSubtitles() {
    onlineSubtitlesTask?.cancel()
    onlineSubtitlesTask = nil
    guard AppSettings.shared.values.onlineSubtitlesAuto,
          PlayerPreferences.lastSubtitle(for: session.media.id) != "OFF" else { return }
    let media = session.media
    let episode = session.episode
    onlineSubtitlesTask = Task { [weak self] in
      for _ in 0..<240 {
        guard !Task.isCancelled, let self else { return }
        if self.isReady { break }
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled, let self, self.isReady, self.session.media.id == media.id, self.session.episode == episode,
            self.embeddedSubtitleTracks.isEmpty, self.externalSubtitleTracks.isEmpty,
            PlayerPreferences.lastSubtitle(for: media.id) != "OFF" else { return }
      let preferred = OnlineSubtitlesService.preferredLanguage(AppSettings.shared.values.subtitleLanguage)
      do {
        let list = try await OnlineSubtitlesService.shared.search(media: media, episode: episode)
        guard let pick = OnlineSubtitlesService.pickAutomatic(list, preferred: preferred) else { return }
        guard !Task.isCancelled, self.embeddedSubtitleTracks.isEmpty, self.externalSubtitleTracks.isEmpty else { return }
        try await self.addOnlineSubtitle(pick, select: false)
        self.showNotice("Online Subtitles", pick.trackName)
      } catch {
        // Quiet: the source simply stays without subtitles.
      }
    }
  }
}

// MARK: - "Search Online Subtitles…" sheet

@MainActor
struct PlayerOnlineSubtitlesSheet: View {
  let controller: PlayerController
  @Environment(\.dismiss) private var dismiss
  @State private var phase: LoadPhase = .loading
  @State private var groups: [OnlineSubtitleGroup] = []
  @State private var expanded: Set<String> = []
  @State private var filter = ""
  @State private var busy: String?
  @State private var failure: String?

  enum LoadPhase: Equatable {
    case loading
    case ready
    case failed(String)
  }

  private var preferred: String {
    OnlineSubtitlesService.preferredLanguage(AppSettings.shared.values.subtitleLanguage)
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Online Subtitles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              Task { await load(force: true) }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .disabled(phase == .loading)
            .accessibilityLabel("Search Again")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
          }
        }
    }
    .preferredColorScheme(.dark)
    .task { await load(force: false) }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .loading:
      ProgressView("Searching online subtitles…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView("No Subtitles", systemImage: "captions.bubble", description: Text(message))
    case .ready:
      if groups.isEmpty {
        ContentUnavailableView("No Subtitles", systemImage: "captions.bubble", description: Text("No online subtitles found for this episode."))
      } else {
        list
      }
    }
  }

  private var list: some View {
    let shown = filteredGroups
    let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
    return List {
      if let failure {
        Section {
          Label(failure, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      if shown.isEmpty {
        Section {
          Text("Nothing matches this filter.")
            .foregroundStyle(.secondary)
        }
      }
      ForEach(shown) { group in
        Section {
          if filtering || expanded.contains(group.language) {
            ForEach(group.items) { item in
              row(item)
            }
          }
        } header: {
          header(group, open: filtering || expanded.contains(group.language))
        }
      }
    }
    .listStyle(.insetGrouped)
    .searchable(text: $filter, prompt: "Filter by language or release")
  }

  private func header(_ group: OnlineSubtitleGroup, open: Bool) -> some View {
    Button {
      if expanded.contains(group.language) {
        expanded.remove(group.language)
      } else {
        expanded.insert(group.language)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: open ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.bold))
        Text(group.name)
        if group.language == preferred {
          Text("Preferred")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.3), in: Capsule())
        }
        Spacer(minLength: 8)
        Text("\(group.items.count)")
          .monospacedDigit()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func row(_ item: OnlineSubtitle) -> some View {
    Button {
      Task { await pick(item) }
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.subheadline)
            .lineLimit(2)
            .foregroundStyle(.primary)
          if !item.source.isEmpty {
            Text(item.source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if busy == item.id {
          ProgressView()
        }
      }
      .contentShape(Rectangle())
    }
    .disabled(busy != nil)
  }

  private var filteredGroups: [OnlineSubtitleGroup] {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return groups }
    return groups.compactMap { group in
      if group.name.lowercased().contains(query) { return group }
      let items = group.items.filter { $0.name.lowercased().contains(query) }
      return items.isEmpty ? nil : OnlineSubtitleGroup(language: group.language, name: group.name, items: items)
    }
  }

  private func load(force: Bool) async {
    phase = .loading
    failure = nil
    let media = controller.session.media
    let episode = controller.session.episode
    do {
      let list = try await OnlineSubtitlesService.shared.search(media: media, episode: episode, force: force)
      groups = OnlineSubtitlesService.groups(list, preferred: preferred)
      expanded = Set(groups.prefix(1).map(\.language))
      phase = .ready
    } catch {
      phase = .failed(OnlineSubtitlesService.message(for: error))
    }
  }

  private func pick(_ item: OnlineSubtitle) async {
    guard busy == nil else { return }
    busy = item.id
    failure = nil
    do {
      try await controller.addOnlineSubtitle(item)
      controller.showNotice("Subtitles", "Added \(item.trackName)")
      busy = nil
      dismiss()
    } catch {
      failure = OnlineSubtitlesService.message(for: error)
      busy = nil
    }
  }
}
