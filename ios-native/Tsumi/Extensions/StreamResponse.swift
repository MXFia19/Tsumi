import Foundation

/// One server of a stream answer, before URL validation (streamData.servers entries).
struct ExtensionParsedServer: Hashable {
  var title: String?
  var streamUrl: String?
  var headers: [String: String]
}

/// Result of parseStreamResponse (common/modules/streaming.js).
struct ExtensionParsedStream: Hashable {
  var url: String
  var headers: [String: String]
  var subtitle: URL?
  /// nil for a plain string answer (no server list).
  var servers: [ExtensionParsedServer]?
}

/// Port of parseStreamResponse / getStreamServers. Accepted shapes:
/// - a plain URL string;
/// - `{ streams: [{ title, streamUrl, headers }], subtitles }`;
/// - `{ streams: ["DUB", url, "SUB", url], headers, subtitles }` (flat title/url pairs);
/// - `{ streamUrl, headers, subtitles }`.
enum ExtensionStreamParser {
  static func parse(_ response: Any?) throws -> ExtensionParsedStream {
    if let text = response as? String {
      return ExtensionParsedStream(url: text, headers: [:], subtitle: nil, servers: nil)
    }
    guard let object = response as? [String: Any] else { throw ExtensionFailure("Invalid stream response") }
    let subtitle = subtitleURL(object["subtitles"]) ?? subtitleURL(object["subtitle"])

    if let streams = object["streams"] as? [Any] {
      if let first = streams.first, first is String {
        let shared = ExtensionJSON.headers(object["headers"])
        var servers: [ExtensionParsedServer] = []
        var index = 0
        while index + 1 < streams.count {
          servers.append(ExtensionParsedServer(title: ExtensionJSON.string(streams[index]), streamUrl: ExtensionJSON.string(streams[index + 1]), headers: shared))
          index += 2
        }
        if let primary = servers.first {
          return ExtensionParsedStream(url: primary.streamUrl ?? "", headers: primary.headers, subtitle: subtitle, servers: servers)
        }
      }
      guard let first = streams.first, !(first is NSNull) else { throw ExtensionFailure("Invalid stream response") }
      let servers = streams.map { entry -> ExtensionParsedServer in
        guard let stream = entry as? [String: Any] else { return ExtensionParsedServer(title: nil, streamUrl: nil, headers: [:]) }
        return server(from: stream)
      }
      let primary = (first as? [String: Any]).map { server(from: $0) }
      return ExtensionParsedStream(url: primary?.streamUrl ?? "", headers: primary?.headers ?? [:], subtitle: subtitle, servers: servers)
    }

    if let streamUrl = ExtensionJSON.truthyString(object["streamUrl"]) {
      let headers = ExtensionJSON.headers(object["headers"])
      return ExtensionParsedStream(url: streamUrl, headers: headers, subtitle: subtitle, servers: [ExtensionParsedServer(title: "Server", streamUrl: streamUrl, headers: headers)])
    }
    throw ExtensionFailure("Invalid stream response")
  }

  /// getStreamServers
  static func servers(_ response: Any?) -> [ExtensionParsedServer] {
    if let text = response as? String { return [ExtensionParsedServer(title: "Server", streamUrl: text, headers: [:])] }
    guard let object = response as? [String: Any] else { return [] }
    if let streams = object["streams"] as? [Any] {
      return streams.map { entry in
        if let stream = entry as? [String: Any] { return server(from: stream) }
        return ExtensionParsedServer(title: nil, streamUrl: ExtensionJSON.string(entry), headers: [:])
      }
    }
    if let streamUrl = ExtensionJSON.truthyString(object["streamUrl"]) {
      return [ExtensionParsedServer(title: "Server", streamUrl: streamUrl, headers: ExtensionJSON.headers(object["headers"]))]
    }
    return []
  }

  /// parseStreamResponse plus the fallback both Svelte callers apply
  /// (`url = typeof raw === 'string' ? raw : raw?.url || raw?.streamUrl`); nil when no URL.
  static func streamData(from raw: Any?) -> ExtensionParsedStream? {
    var parsed: ExtensionParsedStream?
    do {
      parsed = try parse(raw)
    } catch {
      let object = raw as? [String: Any]
      let url = (raw as? String) ?? ExtensionJSON.truthyString(object?["url"]) ?? ExtensionJSON.truthyString(object?["streamUrl"])
      if let url { parsed = ExtensionParsedStream(url: url, headers: [:], subtitle: nil, servers: nil) }
    }
    guard let parsed, !parsed.url.isEmpty else { return nil }
    return parsed
  }

  private static func server(from stream: [String: Any]) -> ExtensionParsedServer {
    // `streamUrl` is the Sora field; `url` is accepted too (common in hand-written modules).
    ExtensionParsedServer(
      title: ExtensionJSON.string(stream["title"]),
      streamUrl: ExtensionJSON.truthyString(stream["streamUrl"]) ?? ExtensionJSON.truthyString(stream["url"]),
      headers: ExtensionJSON.headers(stream["headers"])
    )
  }

  /// Subtitle URL from a string, an array (strings or { url | file, lang }, French first) or an object.
  static func subtitleURL(_ value: Any?) -> URL? {
    if let text = ExtensionJSON.truthyString(value) { return URL.lenient(text) }
    if let object = value as? [String: Any] {
      return URL.lenient(ExtensionJSON.truthyString(object["url"]) ?? ExtensionJSON.truthyString(object["file"]) ?? ExtensionJSON.truthyString(object["src"]))
    }
    if let list = value as? [Any] {
      let french = list.first { entry in
        guard let object = entry as? [String: Any] else { return false }
        let lang = ExtensionJSON.string(object["lang"]) ?? ExtensionJSON.string(object["language"]) ?? ExtensionJSON.string(object["label"]) ?? ""
        return lang.range(of: "^(fr|fre|fra|french)", options: [.regularExpression, .caseInsensitive]) != nil
      }
      if let french, let url = subtitleURL(french) { return url }
      for entry in list {
        if let url = subtitleURL(entry) { return url }
      }
    }
    return nil
  }
}

/// Playable stream of one episode: validated servers ("Server N" titles when missing) + subtitle.
struct ExtensionStream: Hashable {
  var servers: [StreamServer]
  var subtitleURL: URL?

  /// More than one server: the user picks one (ServerSelectorModal), unless the session remembers one.
  var needsServerChoice: Bool { servers.count > 1 }

  init(servers: [StreamServer], subtitleURL: URL?) {
    self.servers = servers
    self.subtitleURL = subtitleURL
  }

  init?(parsed: ExtensionParsedStream) {
    var list: [StreamServer] = []
    if let servers = parsed.servers {
      for (index, server) in servers.enumerated() {
        guard let text = server.streamUrl, let url = URL.lenient(text) else { continue }
        let title = ExtensionJSON.nonEmpty(server.title) ?? "Server \(index + 1)"
        list.append(StreamServer(title: title, url: url, headers: server.headers))
      }
    }
    if list.isEmpty {
      guard let url = URL.lenient(parsed.url) else { return nil }
      let title = ExtensionJSON.nonEmpty(parsed.servers?.first?.title) ?? "Server"
      list = [StreamServer(title: title, url: url, headers: parsed.headers)]
    }
    servers = list
    subtitleURL = parsed.subtitle
  }

  /// Index of the server remembered for this session (sessionServer), if any.
  func rememberedIndex(_ title: String?) -> Int? {
    guard let title else { return nil }
    return servers.firstIndex { $0.title == title }
  }
}

/// "Remember selection for this session" (common/modules/session.js `sessionServer`):
/// server title reused automatically until the app quits.
@MainActor
enum StreamSessionMemory {
  static var preferredServerTitle: String?
}

/// Everything the player needs once a stream is resolved (the `files` entry of the Svelte app:
/// url/streamHeaders = servers[selectedIndex], streamServers, subtitle, activeServerIndex).
struct ResolvedPlayback: Identifiable, Hashable {
  let id = UUID()
  var media: Media
  var episode: EpisodeRef
  var servers: [StreamServer]
  var selectedIndex: Int
  var subtitleURL: URL?
  var extensionKey: String
  /// "<title> - Episode <n>" (file name shown by the player, without ".mp4").
  var displayName: String

  var selectedServer: StreamServer? {
    guard !servers.isEmpty else { return nil }
    return servers[min(max(selectedIndex, 0), servers.count - 1)]
  }

  var streamResult: StreamResult { StreamResult(servers: servers, subtitleURL: subtitleURL) }
}

/// Pending "Select Server" step (ServerSelectorModal data).
struct PlaybackServerChoice: Identifiable {
  let id = UUID()
  var media: Media
  var episode: EpisodeRef
  var stream: ExtensionStream
  var extensionKey: String

  var servers: [StreamServer] { stream.servers }

  func playback(selecting index: Int) -> ResolvedPlayback {
    PlaybackResolver.playback(media: media, episode: episode, stream: stream, selectedIndex: index, extensionKey: extensionKey)
  }
}
