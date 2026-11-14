import Foundation

/// Typed failures of the playback flow, with the messages of the Svelte app.
enum PlaybackResolutionError: LocalizedError, Equatable {
  /// DefaultLoadingModal: 'Default extension not found or disabled'
  case defaultExtensionUnavailable
  /// DefaultLoadingModal: 'No results found from default extension'
  case noResults
  /// 'No episodes found for this title'
  case noEpisodes
  /// 'No stream URL found' (default flow) / 'No stream URL found for this episode' (manual flow)
  case noStreamURL
  /// Error thrown by the extension itself (error.message).
  case extensionFailed(String)

  var errorDescription: String? {
    switch self {
    case .defaultExtensionUnavailable: return "Default extension not found or disabled"
    case .noResults: return "No results found from default extension"
    case .noEpisodes: return "No episodes found for this title"
    case .noStreamURL: return "No stream URL found"
    case .extensionFailed(let message): return message
    }
  }
}

/// Search result a playback came from (extension + result href). The next / previous episode is resolved
/// from this exact result, so a result picked by hand (a dub, another season or variant) is kept.
struct PlaybackSource: Hashable {
  var extensionKey: String
  var href: String
  var title: String?
}

/// Stream of one episode of one search result, with the episode actually played.
struct PlaybackSourceStream {
  var stream: ExtensionStream
  var episode: EpisodeRef
  var source: PlaybackSource
}

/// Next step once a stream is found.
enum PlaybackResolutionStep {
  case ready(ResolvedPlayback)
  case chooseServer(PlaybackServerChoice)
}

/// Non-UI logic of DefaultLoadingModal.svelte / ExtensionResults.svelte: title scoring,
/// season-aware episode matching, stream resolution and server memory.
enum PlaybackResolver {
  // MARK: Scoring

  private static func normalizedForScore(_ text: String) -> String {
    let lowered = text.lowercased()
    var scalars = String.UnicodeScalarView()
    for scalar in lowered.unicodeScalars {
      let value = scalar.value
      let isLetter = value >= 0x61 && value <= 0x7A
      let isDigit = value >= 0x30 && value <= 0x39
      if isLetter || isDigit || CharacterSet.whitespacesAndNewlines.contains(scalar) {
        scalars.append(scalar)
      }
    }
    return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// titleScore(searchTitle, resultTitle): 100 exact, 90 containment, up to 80 by matching words.
  static func titleScore(_ searchTitle: String?, _ resultTitle: String?) -> Int {
    guard let searchTitle, !searchTitle.isEmpty, let resultTitle, !resultTitle.isEmpty else { return 0 }
    let a = normalizedForScore(searchTitle)
    let b = normalizedForScore(resultTitle)
    if a == b { return 100 }
    if b.contains(a) || a.contains(b) || a.isEmpty || b.isEmpty { return 90 }
    let aWords = a.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let bWords = b.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let matches = aWords.filter { word in
      bWords.contains { other in other == word || (word.count > 2 && other.contains(word)) }
    }.count
    let ratio = Double(matches) / Double(max(aWords.count, 1)) * 80
    return min(Int(ratio.rounded()), 80)
  }

  // MARK: Episode matching

  /// Season-aware episode pick of DefaultLoadingModal / ExtensionResults:
  /// season+local number, then "/S/E" in the href, then inferred seasons (numbering restarts),
  /// then a unique local number; absolute number otherwise. Nil = use the first episode.
  static func matchEpisode(_ episodes: [ExtensionEpisode], for episode: EpisodeRef) -> ExtensionEpisode? {
    if let targetSeason = episode.season, let targetLocal = episode.localEpisode {
      let season = Double(targetSeason)
      let local = Double(targetLocal)

      if let match = episodes.first(where: { $0.season != nil && $0.season == season && $0.number == local }) {
        return match
      }

      let pattern = "/\(targetSeason)/\(targetLocal)"
      if let match = episodes.first(where: { $0.href.contains(pattern + "/") || $0.href.hasSuffix(pattern) }) {
        return match
      }

      var currentInferredSeason: Double = episodes.first?.season ?? 1
      var lastNumber: Double = 0
      var inferred: [Double] = []
      for item in episodes {
        let number = item.number
        if let explicit = item.season {
          currentInferredSeason = explicit
        } else if number < lastNumber {
          currentInferredSeason += 1
        }
        inferred.append(currentInferredSeason)
        lastNumber = number
      }
      if let index = episodes.indices.first(where: { inferred[$0] == season && episodes[$0].number == local }) {
        return episodes[index]
      }

      let localMatches = episodes.filter { $0.number == local }
      if localMatches.count == 1 { return localMatches[0] }
      return nil
    }
    let target = Double(episode.number)
    return episodes.first { $0.number == target }
  }

  /// Episode reported to the player. Without a season in the request, the matched episode's number is used
  /// (launchPlayer gets `targetEp.number || capturedEpisode` in DefaultLoadingModal / ExtensionResults), so a
  /// fallback to the first episode is shown and saved as the episode that really plays.
  static func playedEpisode(_ matched: ExtensionEpisode, requested: EpisodeRef) -> EpisodeRef {
    guard requested.season == nil else { return requested }
    let number = matched.number
    // 0 / NaN are falsy in `targetEp.number || capturedEpisode`.
    guard number.isFinite, number > 0, number == number.rounded(), number < 1_000_000 else { return requested }
    let value = Int(number)
    if value == requested.number { return requested }
    return EpisodeRef(number: value, season: nil, localEpisode: nil)
  }

  // MARK: Extension steps

  /// searchResults of one extension, scored against the title and sorted (best first, stable).
  static func scoredResults(_ ext: LoadedExtension, title: String, media: Media) async throws -> [ExtensionSearchResult] {
    let items = try await ExtensionCalls.searchResults(ext, title: title, media: ext.kind == .stremio ? media : nil)
    let scored = items.enumerated().map { index, item in
      ExtensionSearchResult(
        id: "\(ext.key)#\(index)",
        title: item.title,
        imageURL: imageURL(item.image),
        href: item.href,
        extensionKey: ext.key,
        score: titleScore(title, item.title)
      )
    }
    return scored.enumerated().sorted { lhs, rhs in
      if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
      return lhs.offset < rhs.offset
    }.map { $0.element }
  }

  /// Group of results for the picker (nil when the extension found nothing).
  static func resultGroup(_ ext: LoadedExtension, title: String, media: Media, starredKey: String?) async throws -> ExtensionResultGroup? {
    let results = try await scoredResults(ext, title: title, media: media)
    guard !results.isEmpty else { return nil }
    return ExtensionResultGroup(extensionKey: ext.key, extensionName: ext.displayName, extensionIcon: ext.iconURL, isStarred: ext.key == starredKey, results: results)
  }

  /// extractEpisodes + episode pick + extractStreamUrl + parseStreamResponse for one search result.
  static func resolveStream(_ ext: LoadedExtension, href: String, episode: EpisodeRef) async throws -> ExtensionStream {
    try await resolveSourceStream(ext, href: href, episode: episode).stream
  }

  /// Same as `resolveStream`, keeping the result and the episode that plays. `strict` (next / previous episode
  /// from a remembered result) refuses the first-episode fallback when the result lists several episodes.
  static func resolveSourceStream(
    _ ext: LoadedExtension,
    href: String,
    episode: EpisodeRef,
    title: String? = nil,
    strict: Bool = false
  ) async throws -> PlaybackSourceStream {
    let episodes = try await ExtensionCalls.extractEpisodes(ext, href: href)
    guard let first = episodes.first else { throw PlaybackResolutionError.noEpisodes }
    let match = matchEpisode(episodes, for: episode)
    if strict && match == nil && episodes.count > 1 { throw PlaybackResolutionError.noEpisodes }
    let target = match ?? first
    let stream = try await fetchStream(ext, episodeHref: target.href)
    return PlaybackSourceStream(
      stream: stream,
      episode: playedEpisode(target, requested: episode),
      source: PlaybackSource(extensionKey: ext.key, href: href, title: title)
    )
  }

  /// extractStreamUrl + parseStreamResponse (+ fallback) for one episode href.
  static func fetchStream(_ ext: LoadedExtension, episodeHref: String) async throws -> ExtensionStream {
    let raw = try await ExtensionCalls.extractStream(ext, href: episodeHref)
    guard let parsed = ExtensionStreamParser.streamData(from: raw), let stream = ExtensionStream(parsed: parsed) else {
      throw PlaybackResolutionError.noStreamURL
    }
    return stream
  }

  /// Auto-play with the default extension (DefaultLoadingModal.autoPlay), reporting the status texts.
  @MainActor
  static func resolveWithDefault(media: Media, episode: EpisodeRef, onStatus: @escaping (String) -> Void) async throws -> (stream: ExtensionStream, extensionKey: String) {
    let found = try await resolveWithDefaultSource(media: media, episode: episode, onStatus: onStatus)
    return (found.stream, found.source.extensionKey)
  }

  /// `resolveWithDefault` keeping the chosen result and the episode that plays.
  @MainActor
  static func resolveWithDefaultSource(media: Media, episode: EpisodeRef, onStatus: @escaping (String) -> Void) async throws -> PlaybackSourceStream {
    onStatus("Connecting to extension...")
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads()
    let title = ExtensionContext.shared.displayTitle(media)
    guard let defaultKey = AppSettings.shared.values.defaultExtension,
          let ext = manager.enabledExtensions().first(where: { $0.key == defaultKey }) else {
      throw PlaybackResolutionError.defaultExtensionUnavailable
    }

    onStatus("Searching...")
    let results = try await scoredResults(ext, title: title, media: media)
    guard let best = results.first else { throw PlaybackResolutionError.noResults }

    onStatus("Extracting episodes...")
    let episodes = try await ExtensionCalls.extractEpisodes(ext, href: best.href)
    guard let first = episodes.first else { throw PlaybackResolutionError.noEpisodes }
    let target = matchEpisode(episodes, for: episode) ?? first

    onStatus("Loading stream...")
    let found = try await fetchStream(ext, episodeHref: target.href)
    return PlaybackSourceStream(
      stream: found,
      episode: playedEpisode(target, requested: episode),
      source: PlaybackSource(extensionKey: ext.key, href: best.href, title: best.title)
    )
  }

  /// After a stream is found: remembered server, server choice or direct playback.
  @MainActor
  static func nextStep(media: Media, episode: EpisodeRef, stream: ExtensionStream, extensionKey: String) -> PlaybackResolutionStep {
    if stream.needsServerChoice {
      if let index = stream.rememberedIndex(StreamSessionMemory.preferredServerTitle) {
        return .ready(playback(media: media, episode: episode, stream: stream, selectedIndex: index, extensionKey: extensionKey))
      }
      return .chooseServer(PlaybackServerChoice(media: media, episode: episode, stream: stream, extensionKey: extensionKey))
    }
    return .ready(playback(media: media, episode: episode, stream: stream, selectedIndex: 0, extensionKey: extensionKey))
  }

  static func playback(media: Media, episode: EpisodeRef, stream: ExtensionStream, selectedIndex: Int, extensionKey: String) -> ResolvedPlayback {
    let index = stream.servers.isEmpty ? 0 : min(max(selectedIndex, 0), stream.servers.count - 1)
    return ResolvedPlayback(
      media: media,
      episode: episode,
      servers: stream.servers,
      selectedIndex: index,
      subtitleURL: stream.subtitleURL,
      extensionKey: extensionKey,
      displayName: "\(ExtensionContext.shared.displayTitle(media)) - Episode \(episode.number)"
    )
  }

  // MARK: Messages

  /// Reason shown in the "Default extension failed" banner (error.message || 'Stream failed').
  static func failureReason(_ error: Error) -> String {
    let message = error.localizedDescription
    return message.isEmpty ? "Stream failed" : message
  }

  /// Toast text of ExtensionResults.selectResult.
  static func manualFailureMessage(_ error: Error) -> String {
    if let resolution = error as? PlaybackResolutionError {
      switch resolution {
      case .noEpisodes: return "No episodes found for this title"
      case .noStreamURL: return "No stream URL found for this episode"
      default: break
      }
    }
    return "Stream failed: " + error.localizedDescription
  }

  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }

  private static func imageURL(_ text: String) -> URL? {
    guard let url = URL.lenient(text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return url
  }
}
