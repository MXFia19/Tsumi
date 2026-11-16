import Foundation
import Network

/// Loopback HTTP server for the HLS downloads saved segment by segment (the /downloads route of the desktop stream
/// proxy): AVPlayer plays http://127.0.0.1:<port>/<id>/index.m3u8 with the AES-128 keys saved next to the
/// segments, without network. Only GET of files inside the downloads folder, with Range support.
final class DownloadLocalServer: @unchecked Sendable {
  static let shared = DownloadLocalServer()

  private let queue = DispatchQueue(label: "org.tsumi.downloads.server")
  private var listener: NWListener?
  private var port: UInt16?
  /// Port of the last listener that ran. iOS can reclaim the listening socket while the app is suspended; the
  /// listener then starts again on this port, because a player item keeps the loopback URL it was given.
  private var lastPort: UInt16?
  /// The current listener reached `.ready` (a failure after that is a reclaimed socket, not a bind error).
  private var listenerWasReady = false
  private var waiters: [CheckedContinuation<UInt16?, Never>] = []

  private init() {}

  /// Port of the running server, starting it when needed (nil when it can't listen).
  func ensureRunning() async -> UInt16? {
    await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
      queue.async {
        if let port = self.port, self.listener != nil {
          continuation.resume(returning: port)
          return
        }
        self.waiters.append(continuation)
        if self.listener == nil { self.startListener(port: self.lastPort) }
      }
    }
  }

  /// Back in the foreground (DownloadCenter): a server that ran is listening again, on the same port.
  func restartIfNeeded() {
    queue.async {
      guard let lastPort = self.lastPort else { return }
      if let listener = self.listener {
        switch listener.state {
        case .ready, .setup:
          return
        default:
          listener.cancel()
          self.listener = nil
          self.port = nil
        }
      }
      self.startListener(port: lastPort)
    }
  }

  /// URL of a file of a download.
  static func url(port: UInt16, id: String, file: String) -> URL? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    let encodedFile = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
    return URL(string: "http://127.0.0.1:\(port)/\(encodedID)/\(encodedFile)")
  }

  /// Starts a listener on `port` (any free port when nil). Runs on `queue`.
  private func startListener(port requested: UInt16? = nil) {
    do {
      let parameters = NWParameters.tcp
      let endpointPort = requested.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
      parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
      parameters.allowLocalEndpointReuse = true
      let listener = try NWListener(using: parameters)
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        guard let self, let listener else { return }
        // A replaced listener (restarted meanwhile) must not touch the current one.
        guard self.listener === listener else {
          switch state {
          case .ready, .failed: listener.cancel()
          default: break
          }
          return
        }
        switch state {
        case .ready:
          self.listenerWasReady = true
          self.port = listener.port?.rawValue
          if let port = self.port { self.lastPort = port }
          self.finishWaiters(self.port)
        case .failed, .cancelled:
          let wasReady = self.listenerWasReady
          listener.cancel()
          self.listener = nil
          self.port = nil
          if case .failed = state {
            // Socket reclaimed while it ran (app suspended): the same port again. A port that can't be bound
            // any more: any free port (an item still playing the old URL then has to be reloaded).
            if wasReady, let lastPort = self.lastPort {
              self.startListener(port: lastPort)
              return
            }
            if requested != nil {
              self.startListener()
              return
            }
          }
          self.finishWaiters(nil)
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.serve(connection)
      }
      self.listener = listener
      listenerWasReady = false
      listener.start(queue: queue)
    } catch {
      listener = nil
      if requested != nil {
        startListener()
        return
      }
      finishWaiters(nil)
    }
  }

  private func finishWaiters(_ port: UInt16?) {
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(returning: port) }
  }

  // MARK: - HTTP

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveRequest(connection, buffer: Data())
  }

  private func receiveRequest(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var received = buffer
      if let data { received.append(data) }
      if let end = received.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: received[received.startIndex..<end.lowerBound], as: UTF8.self)
        self.respond(connection, head: head)
        return
      }
      if error != nil || isComplete || received.count > 64 * 1024 {
        connection.cancel()
        return
      }
      self.receiveRequest(connection, buffer: received)
    }
  }

  private func respond(_ connection: NWConnection, head: String) {
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2, requestLine[0] == "GET" || requestLine[0] == "HEAD" else {
      return send(connection, status: "405 Method Not Allowed", headers: [:], body: Data())
    }
    let isHead = requestLine[0] == "HEAD"
    let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? ""
    let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    guard parts.count == 2, let fileURL = DownloadStorage.fileURL(id: parts[0], file: parts[1]),
          let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
      return send(connection, status: "404 Not Found", headers: [:], body: Data())
    }
    var range: ClosedRange<Int>?
    for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
      let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces).lowercased()
      guard value.hasPrefix("bytes=") else { continue }
      let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
      if bounds.count == 2, let start = Int(bounds[0]), start < data.count {
        let end = min(Int(bounds[1]) ?? (data.count - 1), data.count - 1)
        if end >= start { range = start...end }
      }
    }
    var headers = [
      "Content-Type": Self.contentType(fileURL.pathExtension),
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-cache"
    ]
    if let range {
      let body = data.subdata(in: range.lowerBound..<(range.upperBound + 1))
      headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)"
      headers["Content-Length"] = String(body.count)
      send(connection, status: "206 Partial Content", headers: headers, body: isHead ? Data() : body)
    } else {
      headers["Content-Length"] = String(data.count)
      send(connection, status: "200 OK", headers: headers, body: isHead ? Data() : data)
    }
  }

  private func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data) {
    var head = "HTTP/1.1 \(status)\r\n"
    var all = headers
    all["Connection"] = "close"
    if all["Content-Length"] == nil { all["Content-Length"] = String(body.count) }
    for (key, value) in all { head += "\(key): \(value)\r\n" }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static func contentType(_ ext: String) -> String {
    switch ext.lowercased() {
    case "m3u8": return "application/vnd.apple.mpegurl"
    case "ts": return "video/mp2t"
    case "aac": return "audio/aac"
    case "mp4", "m4s", "m4v", "cmfv": return "video/mp4"
    case "m4a", "cmfa": return "audio/mp4"
    case "vtt", "webvtt": return "text/vtt"
    default: return "application/octet-stream"
    }
  }
}
