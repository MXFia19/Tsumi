import Darwin
import Foundation

// Network plumbing shared by the extension system: the rules applied to third-party module traffic, the masking of
// manifest URLs (they can carry private tokens) and a URLSession wrapper that caps response bodies.

/// Hosts a third-party Sora module may not reach unless it was itself installed from such a host.
enum ExtensionNetworkPolicy {
  static let blockedMessage = "Blocked: extensions can't reach this device or the local network"

  /// hostKind of common/modules/sandbox/network.js.
  enum HostKind: String {
    case loopback
    case privateNetwork = "private"
    case linkLocal = "link-local"
    case publicHost = "public"
  }

  /// Local DNS suffixes (intranet names), as on PC.
  private static let localSuffixes = ["local", "lan", "internal", "intranet", "home", "corp", "localdomain", "home.arpa"]

  static func isLocal(_ url: URL) -> Bool {
    isLocalHost(url.host)
  }

  /// Loopback, private and link-local hosts (anything but `.publicHost`).
  static func isLocalHost(_ rawHost: String?) -> Bool {
    hostKind(rawHost) != .publicHost
  }

  /// Port of PC hostKind (common/modules/sandbox/network.js), same rules: loopback, private (RFC 1918, 100.64/10,
  /// 198.18/15, multicast and reserved 224/3, fc00::/7, fec0::/10, ff00::/8), link-local, IPv4-mapped and
  /// IPv4-compatible IPv6 (::ffff:a.b.c.d, ::a.b.c.d), `localhost`, names without a dot (intranet machines) and
  /// local DNS suffixes (.local, .lan, .home.arpa...). An empty host or an IPv6 host that cannot be read counts as
  /// private. Numeric IPv4 hosts are read like the system resolver reads them (127.1, 0x7f.1, 2130706433 are all
  /// 127.0.0.1); on PC the URL parser normalizes them the same way first. A public name that resolves to a local
  /// address is not caught (no DNS lookup), on either platform.
  static func hostKind(_ rawHost: String?) -> HostKind {
    var host = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if host.count >= 2 && host.hasPrefix("[") && host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    // IPv6 zone ("fe80::1%en0"). No other host has a "%", and cutting there can only block more.
    if let zone = host.firstIndex(of: "%") {
      host = String(host[..<zone])
    }
    while host.hasSuffix(".") {
      host.removeLast()
    }
    if host.isEmpty { return .privateNetwork }
    if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
    if host.contains(":") { return ipv6Kind(host) ?? .privateNetwork }
    var address = in_addr()
    if inet_aton(host, &address) != 0 {
      return ipv4Kind(UInt32(bigEndian: address.s_addr))
    }
    if !host.contains(".") { return .privateNetwork }
    if localSuffixes.contains(where: { host.hasSuffix("." + $0) }) { return .privateNetwork }
    return .publicHost
  }

  /// `value` in host byte order.
  private static func ipv4Kind(_ value: UInt32) -> HostKind {
    let first = value >> 24
    let second = (value >> 16) & 0xFF
    if first == 127 || first == 0 { return .loopback }
    if first == 169 && second == 254 { return .linkLocal }
    if first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168) { return .privateNetwork }
    // Carrier-grade NAT.
    if first == 100 && second >= 64 && second <= 127 { return .privateNetwork }
    // Benchmarking networks.
    if first == 198 && (second == 18 || second == 19) { return .privateNetwork }
    // Multicast, reserved, broadcast.
    if first >= 224 { return .privateNetwork }
    return .publicHost
  }

  /// nil when `host` is not an IPv6 address.
  private static func ipv6Kind(_ host: String) -> HostKind? {
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
    let bytes: [UInt8] = withUnsafeBytes(of: address) { Array($0) }
    guard bytes.count == 16 else { return nil }
    var groups: [UInt32] = []
    for index in 0..<8 {
      groups.append((UInt32(bytes[2 * index]) << 8) | UInt32(bytes[2 * index + 1]))
    }
    // :: and ::1
    if groups.allSatisfy({ $0 == 0 }) { return .loopback }
    if groups[0..<7].allSatisfy({ $0 == 0 }) && groups[7] == 1 { return .loopback }
    // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) addresses: the IPv4 rules apply.
    if groups[0..<5].allSatisfy({ $0 == 0 }) && (groups[5] == 0xFFFF || groups[5] == 0) {
      return ipv4Kind((groups[6] << 16) | groups[7])
    }
    // fe80::/10 (link-local)
    if (groups[0] & 0xFFC0) == 0xFE80 { return .linkLocal }
    // fc00::/7 (unique local)
    if (groups[0] & 0xFE00) == 0xFC00 { return .privateNetwork }
    // fec0::/10 (deprecated site-local)
    if (groups[0] & 0xFFC0) == 0xFEC0 { return .privateNetwork }
    // ff00::/8 (multicast)
    if (groups[0] & 0xFF00) == 0xFF00 { return .privateNetwork }
    return .publicHost
  }

  /// Test cases of the PC rules (common/modules/sandbox/network.test.mjs and the cases of the audit comparison
  /// script), checked at launch in debug builds (there is no iOS test target). Returns the hosts whose kind differs.
  static func parityFailures() -> [String] {
    let cases: [(String, HostKind)] = [
      // Loopback (numeric forms as the resolver reads them).
      ("localhost", .loopback), ("LOCALHOST.", .loopback), ("app.localhost", .loopback), ("127.0.0.1", .loopback),
      ("127.8.9.10", .loopback), ("0.0.0.0", .loopback), ("::1", .loopback), ("[::1]", .loopback), ("::", .loopback),
      ("2130706433", .loopback), ("0x7f000001", .loopback), ("0177.0.0.1", .loopback), ("127.1", .loopback),
      ("::ffff:127.0.0.1", .loopback), ("::7f00:1", .loopback), ("::127.0.0.1", .loopback),
      // Private.
      ("10.0.0.1", .privateNetwork), ("172.16.5.4", .privateNetwork), ("172.31.255.255", .privateNetwork),
      ("192.168.1.1", .privateNetwork), ("100.64.0.1", .privateNetwork), ("fd00::1", .privateNetwork),
      ("fc12:3456::1", .privateNetwork), ("router", .privateNetwork), ("nas", .privateNetwork),
      ("nas.local", .privateNetwork), ("printer.local", .privateNetwork), ("box.lan", .privateNetwork),
      ("router.lan", .privateNetwork), ("printer.home.arpa", .privateNetwork),
      ("homeassistant.home.arpa", .privateNetwork), ("svc.internal", .privateNetwork),
      ("server.internal", .privateNetwork), ("box.home", .privateNetwork), ("pc.localdomain", .privateNetwork),
      ("wiki.intranet", .privateNetwork), ("mail.corp", .privateNetwork), ("224.0.0.1", .privateNetwork),
      ("224.0.0.251", .privateNetwork), ("239.255.255.250", .privateNetwork), ("255.255.255.255", .privateNetwork),
      ("198.18.0.1", .privateNetwork), ("198.19.255.1", .privateNetwork), ("fec0::1", .privateNetwork),
      ("ff02::1", .privateNetwork), ("", .privateNetwork), ("::zz", .privateNetwork),
      // Link-local.
      ("169.254.169.254", .linkLocal), ("fe80::1", .linkLocal), ("fe80::1%en0", .linkLocal),
      ("::ffff:169.254.1.1", .linkLocal),
      // Public.
      ("example.com", .publicHost), ("api.ani.zip", .publicHost), ("8.8.8.8", .publicHost),
      ("172.32.0.1", .publicHost), ("172.15.0.1", .publicHost), ("192.169.0.1", .publicHost),
      ("100.128.0.1", .publicHost), ("198.20.0.1", .publicHost), ("2606:4700::1111", .publicHost),
      ("::ffff:8.8.8.8", .publicHost), ("xn--e1afmkfd.xn--p1ai", .publicHost), ("fritz.box", .publicHost),
      ("home.arpa", .publicHost)
    ]
    return cases.compactMap { host, expected in
      let kind = hostKind(host)
      return kind == expected ? nil : "\(host): \(kind.rawValue), expected \(expected.rawValue)"
    }
  }
}

/// Hosts an extension says it contacts, shown before installing it (extensionDomains / moduleDomains of the desktop
/// app): the addon server of a Stremio addon; for a Sora module, the hosts of its manifest (baseUrl, searchBaseUrl),
/// of its script address and of the absolute http(s) URLs written in its script. Best effort: a module can still
/// build other addresses at run time.
enum ExtensionDomains {
  /// At most this many hosts are collected from a script.
  static let maxHosts = 40

  private static let literal = try? NSRegularExpression(pattern: #"https?://[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d+)?"#, options: [.caseInsensitive])

  static func list(_ result: ExtensionLoadResult) -> [String] {
    switch result.backend {
    case .stremio(let addon):
      guard let host = URL.lenient(addon.base)?.host, !host.isEmpty else { return [] }
      return [host.lowercased()]
    case .sora(let script):
      return moduleDomains(result.manifest, script: script, scriptURL: result.scriptURL)
    }
  }

  static func moduleDomains(_ manifest: ExtensionManifest, script: String, scriptURL: URL?) -> [String] {
    var hosts = Set<String>()
    func add(_ value: String?) {
      guard let value, let url = URL.lenient(value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty else { return }
      hosts.insert(host.lowercased())
    }
    add(manifest.baseUrl)
    add(manifest.searchBaseUrl)
    add(scriptURL?.absoluteString)
    if let literal, hosts.count < maxHosts {
      let text = script as NSString
      literal.enumerateMatches(in: script, options: [], range: NSRange(location: 0, length: text.length)) { match, _, stop in
        guard let match else { return }
        add(text.substring(with: match.range))
        if hosts.count >= maxHosts { stop.pointee = true }
      }
    }
    return hosts.sorted()
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

/// Requests of the extension system outside module code: manifests, module scripts, Stremio addon answers, images
/// supplied by modules and addons.
enum ExtensionHTTP {
  /// Largest body read from a manifest, a script, an addon answer or a module fetch.
  static let maxResponseBytes = 20 * 1024 * 1024
  static let tooLarge = ExtensionFailure("The answer is too large (over 20 MB)")
  /// Longest time for a whole request, on top of the idle timeout of each request: a host that trickles its answer
  /// no longer holds a load, a search or a play request back without limit.
  static let resourceTimeout: TimeInterval = 60

  /// Same settings as the app's shared session (HTTP.session).
  static let fetcher: ExtensionFetchSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = resourceTimeout
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.httpAdditionalHeaders = ["User-Agent": "Tsumi/iOS"]
    return ExtensionFetchSession(configuration: configuration, name: "org.tsumi.extensions.http")
  }()

  /// GET with the size cap. Any status is returned (the callers word their own errors); only http(s) URLs.
  /// `allowRedirect` can refuse a redirect (its target), which then fails the request.
  static func data(
    _ url: URL,
    timeout: TimeInterval = 30,
    limit: Int = maxResponseBytes,
    allowRedirect: @escaping (URL) -> Bool = { _ in true }
  ) async throws -> (Data, HTTPURLResponse) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw ExtensionFailure("Only http and https addresses are allowed")
    }
    let request = URLRequest(url: url, timeoutInterval: timeout)
    return try await perform(request, limit: limit, on: fetcher, allowRedirect: allowRedirect)
  }

  static func perform(
    _ request: URLRequest,
    limit: Int,
    on fetcher: ExtensionFetchSession,
    allowRedirect: @escaping (URL) -> Bool = { _ in true }
  ) async throws -> (Data, HTTPURLResponse) {
    let holder = ExtensionTaskHolder()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
        let task = fetcher.makeTask(request, limit: limit, allowRedirect: allowRedirect) { result in
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
