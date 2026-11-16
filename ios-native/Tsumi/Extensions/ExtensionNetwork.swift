import Darwin
import Foundation

// Network plumbing shared by the extension system: the rules applied to third-party module traffic, the masking of
// manifest URLs (they can carry private tokens) and a URLSession wrapper that caps response bodies.

/// Hosts a third-party Sora module may not reach unless it was itself installed from such a host.
enum ExtensionNetworkPolicy {
  static let blockedMessage = "Blocked: extensions can't reach this device or the local network"

  static func isLocal(_ url: URL) -> Bool {
    isLocalHost(url.host)
  }

  /// Loopback, private (RFC 1918), shared (100.64/10), link-local and unspecified addresses, `localhost` and
  /// `.local` / `.localhost` names. Numeric hosts are read like the system resolver reads them (127.1, 0x7f.1,
  /// 2130706433 are all 127.0.0.1). A public name that resolves to a local address is not caught (no DNS lookup).
  static func isLocalHost(_ rawHost: String?) -> Bool {
    guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
    if host.hasPrefix("[") && host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    if let zone = host.firstIndex(of: "%") {
      host = String(host[..<zone])
    }
    while host.hasSuffix(".") {
      host.removeLast()
    }
    if host.isEmpty { return false }
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
    if host.contains(":") { return isLocalIPv6(host) }
    var address = in_addr()
    if inet_aton(host, &address) != 0 {
      return isLocalIPv4(UInt32(bigEndian: address.s_addr))
    }
    return false
  }

  /// `value` in host byte order.
  private static func isLocalIPv4(_ value: UInt32) -> Bool {
    let first = value >> 24
    let second = (value >> 16) & 0xFF
    switch first {
    case 0, 10, 127:
      return true
    case 100:
      return second >= 64 && second <= 127
    case 169:
      return second == 254
    case 172:
      return second >= 16 && second <= 31
    case 192:
      return second == 168
    default:
      return value == 0xFFFF_FFFF
    }
  }

  private static func isLocalIPv6(_ host: String) -> Bool {
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
    let bytes: [UInt8] = withUnsafeBytes(of: address) { Array($0) }
    guard bytes.count == 16 else { return false }
    let head = bytes[0..<15]
    // :: and ::1
    if head.allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) { return true }
    // fe80::/10 (link-local)
    if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
    // fc00::/7 (unique local)
    if (bytes[0] & 0xFE) == 0xFC { return true }
    // ::ffff:a.b.c.d (IPv4-mapped)
    if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
      var value = UInt32(bytes[12]) << 24
      value |= UInt32(bytes[13]) << 16
      value |= UInt32(bytes[14]) << 8
      value |= UInt32(bytes[15])
      return isLocalIPv4(value)
    }
    return false
  }
}

/// Manifest URLs can carry private tokens (configured Stremio addons put them in the path): the interface and the
/// error messages only show their host.
enum ExtensionURLMask {
  static let unknown = "unknown address"

  static func host(_ text: String?) -> String {
    guard let text, let url = URL.lenient(StremioAddon.normalizeManifestURL(text)) else { return unknown }
    return host(url)
  }

  static func host(_ url: URL) -> String {
    guard let host = url.host, !host.isEmpty else { return unknown }
    return host
  }
}

/// URLSession wrapper for extension traffic: response bodies are capped (an addon or a module answering with a
/// 1 GB file must not exhaust the app's memory; the download is stopped as soon as it goes over the limit), and
/// redirects can be refused or checked per request.
final class ExtensionFetchSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Completion = (Result<(Data, URLResponse?), Error>) -> Void

  /// State of one task. Only touched on the session's (serial) delegate queue once the task runs.
  private final class Handler {
    let limit: Int
    let follow: Bool
    let allowRedirect: (URL) -> Bool
    let completion: Completion
    var data = Data()
    var failure: Error?

    init(limit: Int, follow: Bool, allowRedirect: @escaping (URL) -> Bool, completion: @escaping Completion) {
      self.limit = limit
      self.follow = follow
      self.allowRedirect = allowRedirect
      self.completion = completion
    }
  }

  private let lock = NSLock()
  private var handlers: [Int: Handler] = [:]
  private var session: URLSession!

  init(configuration: URLSessionConfiguration, name: String) {
    super.init()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = name
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  /// A task (not resumed yet) whose result goes to `completion`, called once on the delegate queue. A task that
  /// will not be resumed must be given to `discard`.
  func makeTask(
    _ request: URLRequest,
    limit: Int = ExtensionHTTP.maxResponseBytes,
    follow: Bool = true,
    allowRedirect: @escaping (URL) -> Bool = { _ in true },
    completion: @escaping Completion
  ) -> URLSessionDataTask {
    let task = session.dataTask(with: request)
    let handler = Handler(limit: limit, follow: follow, allowRedirect: allowRedirect, completion: completion)
    lock.lock()
    handlers[task.taskIdentifier] = handler
    lock.unlock()
    return task
  }

  /// Forgets a task that was never resumed (its completion is not called).
  func discard(_ task: URLSessionTask) {
    lock.lock()
    handlers[task.taskIdentifier] = nil
    lock.unlock()
    task.cancel()
  }

  private func handler(for task: URLSessionTask) -> Handler? {
    lock.lock()
    defer { lock.unlock() }
    return handlers[task.taskIdentifier]
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if let handler = handler(for: dataTask) {
      let expected = response.expectedContentLength
      if expected > Int64(handler.limit) {
        handler.failure = ExtensionHTTP.tooLarge
        completionHandler(.cancel)
        return
      }
      if expected > 0 {
        handler.data.reserveCapacity(Int(expected))
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let handler = handler(for: dataTask), handler.failure == nil else { return }
    if handler.data.count + data.count > handler.limit {
      handler.failure = ExtensionHTTP.tooLarge
      handler.data = Data()
      dataTask.cancel()
      return
    }
    handler.data.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let handler = handler(for: task) else {
      completionHandler(request)
      return
    }
    guard handler.follow else {
      // fetchv2 redirect = false / fetch redirect: 'manual': the 3xx answer is the result.
      completionHandler(nil)
      return
    }
    if let url = request.url, !handler.allowRedirect(url) {
      handler.failure = ExtensionFailure(ExtensionNetworkPolicy.blockedMessage)
      completionHandler(nil)
      task.cancel()
      return
    }
    completionHandler(request)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let handler = handlers.removeValue(forKey: task.taskIdentifier)
    lock.unlock()
    guard let handler else { return }
    if let failure = handler.failure {
      handler.completion(.failure(failure))
    } else if let error {
      handler.completion(.failure(error))
    } else {
      let data = handler.data
      handler.data = Data()
      handler.completion(.success((data, task.response)))
    }
  }
}

/// Requests of the extension system outside module code: manifests, module scripts, Stremio addon answers.
enum ExtensionHTTP {
  /// Largest body read from a manifest, a script, an addon answer or a module fetch.
  static let maxResponseBytes = 20 * 1024 * 1024
  static let tooLarge = ExtensionFailure("The answer is too large (over 20 MB)")

  /// Same settings as the app's shared session (HTTP.session).
  static let fetcher: ExtensionFetchSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.httpAdditionalHeaders = ["User-Agent": "Tsumi/iOS"]
    return ExtensionFetchSession(configuration: configuration, name: "org.tsumi.extensions.http")
  }()

  /// GET with the size cap. Any status is returned (the callers word their own errors); only http(s) URLs.
  static func data(_ url: URL, timeout: TimeInterval = 30, limit: Int = maxResponseBytes) async throws -> (Data, HTTPURLResponse) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw ExtensionFailure("Only http and https addresses are allowed")
    }
    let request = URLRequest(url: url, timeoutInterval: timeout)
    return try await perform(request, limit: limit, on: fetcher)
  }

  static func perform(_ request: URLRequest, limit: Int, on fetcher: ExtensionFetchSession) async throws -> (Data, HTTPURLResponse) {
    let holder = ExtensionTaskHolder()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
        let task = fetcher.makeTask(request, limit: limit) { result in
          switch result {
          case .success(let value):
            if let http = value.1 as? HTTPURLResponse {
              continuation.resume(returning: (value.0, http))
            } else {
              continuation.resume(throwing: HTTPError.invalidResponse)
            }
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
        holder.start(task)
      }
    } onCancel: {
      holder.cancel()
    }
  }
}

/// URLSession task of an async request, cancelled with the Swift task (also when the cancellation came first).
final class ExtensionTaskHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var cancelled = false

  func start(_ task: URLSessionTask) {
    lock.lock()
    self.task = task
    let wasCancelled = cancelled
    lock.unlock()
    task.resume()
    if wasCancelled { task.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let current = task
    lock.unlock()
    current?.cancel()
  }
}
