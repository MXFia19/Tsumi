import CryptoKit
import Darwin
import Foundation
import JavaScriptCore

/// Runs Sora module functions with JavaScriptCore. Port of `executeExtensionFunction` and
/// `callExtensionFunction` (common/modules/extension.js):
/// - every call gets a fresh JSContext (the Svelte app builds a new AsyncFunction per call);
/// - the module code and the call are wrapped in an async function, so `await` works anywhere;
/// - `fetchv2` (both call styles) and `fetch` are native, backed by URLSession, with every header
///   allowed (User-Agent, Cookie, Referer), like the Electron fetch proxy;
/// - 30 s timeout ("Extension execution timeout");
/// - string results are JSON-parsed when possible.
///
/// Every call runs on its own serial queue (its own virtual machine too), so a module stuck in a loop only blocks
/// itself. The timeout and the cancellation are delivered from outside that queue, and JavaScriptCore's watchdog
/// then stops the stuck script (see `SoraWatchdog`).
enum SoraRuntime {
  static let executionTimeout: TimeInterval = 30

  /// Calls `functionName(arguments...)` defined by `script`. Returns the JSON-decoded result
  /// (dictionary, array, string, number) or nil for null/undefined. `allowsLocalNetwork`: the module was installed
  /// from this device or the local network, so it may fetch local addresses too.
  static func call(
    script: String,
    functionName: String,
    arguments: [Any],
    allowsLocalNetwork: Bool = false,
    timeout: TimeInterval = SoraRuntime.executionTimeout
  ) async throws -> Any? {
    guard isIdentifier(functionName) else {
      throw ExtensionFailure("Invalid extension function name: \(functionName)")
    }
    let argumentList = try encodeArguments(arguments)
    let state = SoraCallState(allowsLocalNetwork: allowsLocalNetwork)
    let output: SoraCallOutput = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SoraCallOutput, Error>) in
        // Already cancelled: attach resumes the continuation at once.
        guard state.attach(continuation) else { return }
        state.queue.async {
          SoraRuntime.run(state: state, script: script, functionName: functionName, argumentList: argumentList)
        }
        // Armed on another queue: it fires even when the module never gives its own queue back.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak state] in
          state?.finish(.failure(ExtensionFailure("Extension execution timeout")))
        }
      }
    } onCancel: {
      state.finish(.failure(CancellationError()))
    }
    return output.value
  }

  // MARK: - Execution

  /// Runs on `state.queue`.
  private static func run(state: SoraCallState, script: String, functionName: String, argumentList: String) {
    guard !state.isFinished else { return }
    let machine = JSVirtualMachine()
    let created: JSContext? = JSContext(virtualMachine: machine)
    guard let context = created else {
      state.finish(.failure(ExtensionFailure("Could not start the JavaScript engine")))
      return
    }
    state.context = context
    state.watchdogArmed = SoraWatchdog.arm(context, state: state)
    context.exceptionHandler = { [weak state] _, exception in
      state?.recordException(SoraRuntime.describe(exception))
    }
    SoraBridge.install(in: context, state: state)

    _ = context.evaluateScript(SoraPrelude.source, withSourceURL: URL(string: "tsumi://extension-runtime.js"))
    if let message = state.takeException() {
      state.finish(.failure(ExtensionFailure("Extension runtime failed to start: \(message)")))
      return
    }
    guard !state.isFinished else { return }

    // Same shape as the Svelte AsyncFunction body: module code, then `return await fn(args)`.
    let code = "(async function () {\n" + script + "\n;return await " + functionName + "(" + argumentList + ");\n})().then(__tsumiResolve, __tsumiReject);"
    _ = context.evaluateScript(code, withSourceURL: URL(string: "tsumi://extension-module.js"))
    if let message = state.takeException() {
      state.finish(.failure(ExtensionFailure(message)))
    }
  }

  /// `JSON.parse(result)` when the function returned a string, falling back to the raw string.
  static func decodeResult(_ text: String?, isString: Bool) -> Any? {
    guard let text else { return nil }
    if let parsed = ExtensionJSON.parse(text) {
      return parsed is NSNull ? nil : parsed
    }
    return isString ? text : nil
  }

  static func describe(_ exception: JSValue?) -> String {
    guard let exception, !exception.isUndefined, !exception.isNull else { return "Unknown JavaScript error" }
    if exception.isObject, let message = exception.objectForKeyedSubscript("message"), message.isString {
      let text: String? = message.toString()
      if let text, !text.isEmpty { return text }
    }
    let text: String? = exception.toString()
    return text ?? "Unknown JavaScript error"
  }

  private static func isIdentifier(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first else { return false }
    let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
    let tail = head.union(.decimalDigits)
    guard head.contains(first) else { return false }
    return name.unicodeScalars.allSatisfy { tail.contains($0) }
  }

  /// `args.map(a => JSON.stringify(a)).join(', ')`
  private static func encodeArguments(_ arguments: [Any]) throws -> String {
    var parts: [String] = []
    for argument in arguments {
      if let text = argument as? String {
        parts.append(ExtensionJSON.quote(text))
      } else if argument is NSNull {
        parts.append("null")
      } else if let number = argument as? NSNumber {
        if ExtensionJSON.isBoolean(number) {
          parts.append(number.boolValue ? "true" : "false")
        } else {
          let value = number.doubleValue
          parts.append(value.isFinite ? number.stringValue : "null")
        }
      } else if let json = ExtensionJSON.stringify(argument) {
        parts.append(json)
      } else {
        throw ExtensionFailure("Unsupported extension argument")
      }
    }
    return parts.joined(separator: ", ")
  }
}

/// JavaScriptCore's watchdog (`JSContextGroupSetExecutionTimeLimit`, a C function of JavaScriptCore that is not in
/// the public headers, looked up at run time). While a script runs, JavaScriptCore asks every `checkInterval`
/// seconds of execution whether to stop it; it is stopped once its call is over (timeout or cancellation), which
/// gives the thread of a module stuck in `while (true) {}` back. When the symbol is missing, nothing is armed: the
/// call still ends on time, only the stuck thread keeps spinning until the app quits.
enum SoraWatchdog {
  typealias ShouldTerminate = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
  typealias SetLimit = @convention(c) (OpaquePointer?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
  typealias ClearLimit = @convention(c) (OpaquePointer?) -> Void

  static let checkInterval: Double = 1

  private static let setLimit: SetLimit? = {
    guard let symbol = lookup("JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(symbol, to: SetLimit.self)
  }()

  private static let clearLimit: ClearLimit? = {
    guard let symbol = lookup("JSContextGroupClearExecutionTimeLimit") else { return nil }
    return unsafeBitCast(symbol, to: ClearLimit.self)
  }()

  /// `context` is the call state (alive whenever its script runs: every entry into the script holds it).
  private static let shouldTerminate: ShouldTerminate = { _, context in
    guard let context else { return true }
    return Unmanaged<SoraCallState>.fromOpaque(context).takeUnretainedValue().isFinished
  }

  private static func lookup(_ name: String) -> UnsafeMutableRawPointer? {
    if let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW | RTLD_NOLOAD),
       let symbol = dlsym(handle, name) {
      return symbol
    }
    // RTLD_DEFAULT ((void *)-2): every image loaded in the process.
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
  }

  /// Arms the watchdog of the context's group before any script runs; false when the API is not available.
  static func arm(_ context: JSContext, state: SoraCallState) -> Bool {
    guard let setLimit, let global = context.jsGlobalContextRef else { return false }
    let group = JSContextGetGroup(global)
    setLimit(group, checkInterval, shouldTerminate, Unmanaged.passUnretained(state).toOpaque())
    return true
  }

  /// Removes the watchdog before the context goes away (no script runs any more at that point).
  static func disarm(_ context: JSContext) {
    guard let clearLimit, let global = context.jsGlobalContextRef else { return }
    clearLimit(JSContextGetGroup(global))
  }
}

/// Value returned by a call, boxed so it can cross the continuation.
struct SoraCallOutput: @unchecked Sendable {
  let value: Any?
}

/// Response body kept for the module until it reads it (see `SoraBridge`: `__tsumiText` / `__tsumiBytes`).
struct SoraResponseBody {
  var data: Data
  /// fetchv2 6th argument (text encoding asked by the module), nil = UTF-8.
  var encoding: String?
  var textRead = false
}

/// State of one running call.
/// - `queue` runs every JavaScript entry of the call (script, timers, network callbacks) and its clean-up; the
///   JavaScript-side state (`context`, `bodies`, exceptions) is only touched there.
/// - `finish` can be called from any thread (timeout, cancellation, result): the outcome is decided under a lock
///   and the continuation is resumed at once, without waiting for `queue`.
final class SoraCallState: @unchecked Sendable {
  let queue = DispatchQueue(label: "org.tsumi.extensions.call", qos: .userInitiated)
  let allowsLocalNetwork: Bool

  // Queue-only state.
  var context: JSContext?
  var watchdogArmed = false
  var bodies: [Int: SoraResponseBody] = [:]
  var nextBodyID = 0
  private var pendingException: String?

  // Locked state.
  private let lock = NSLock()
  private var finished = false
  private var continuation: CheckedContinuation<SoraCallOutput, Error>?
  /// Outcome decided before a continuation was attached (cancelled before starting).
  private var outcome: Result<SoraCallOutput, Error>?
  private var tasks: [URLSessionTask] = []

  init(allowsLocalNetwork: Bool) {
    self.allowsLocalNetwork = allowsLocalNetwork
  }

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  /// Hands the continuation to the call; false (and the continuation resumed) when the call is already over.
  func attach(_ continuation: CheckedContinuation<SoraCallOutput, Error>) -> Bool {
    lock.lock()
    if finished {
      let result = outcome ?? .failure(CancellationError())
      outcome = nil
      lock.unlock()
      continuation.resume(with: result)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  /// Network task of the call (cancelled with it); false when the call is already over.
  func register(_ task: URLSessionTask) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return false }
    tasks.append(task)
    return true
  }

  func unregister(_ task: URLSessionTask) {
    lock.lock()
    tasks.removeAll { $0 === task }
    lock.unlock()
  }

  func recordException(_ message: String) {
    #if DEBUG
    print("[Extension] JavaScript exception: \(message)")
    #endif
    if pendingException == nil { pendingException = message }
  }

  func takeException() -> String? {
    let message = pendingException
    pendingException = nil
    return message
  }

  func storeBody(_ data: Data, encoding: String?) -> Int {
    let identifier = nextBodyID
    nextBodyID += 1
    bodies[identifier] = SoraResponseBody(data: data, encoding: encoding)
    return identifier
  }

  /// Ends the call with `result` (first caller wins), from any thread.
  func finish(_ result: Result<SoraCallOutput, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let pending = continuation
    continuation = nil
    if pending == nil { outcome = result }
    let running = tasks
    tasks.removeAll()
    lock.unlock()

    for task in running { task.cancel() }
    // finish() may run inside a JavaScript callback: the context (and the response bodies) are released once the
    // current work item of the call's queue has returned. A module stuck in a loop gets there once the watchdog
    // stopped it.
    queue.async {
      self.cleanUp()
    }
    pending?.resume(with: result)
  }

  private func cleanUp() {
    if let context {
      if watchdogArmed { SoraWatchdog.disarm(context) }
      context.exceptionHandler = nil
    }
    context = nil
    bodies.removeAll()
  }
}

/// Native functions exposed to the module (console, timers, network, result channel).
enum SoraBridge {
  static func install(in context: JSContext, state: SoraCallState) {
    let log: @convention(block) (String, String) -> Void = { level, message in
      #if DEBUG
      print("[Extension \(level)] \(message)")
      #endif
    }

    let schedule: @convention(block) (JSValue, JSValue) -> Void = { [weak state] identifier, delay in
      guard let state else { return }
      let timerID = identifier.toInt32()
      var milliseconds = delay.toDouble()
      if !milliseconds.isFinite || milliseconds < 0 { milliseconds = 0 }
      milliseconds = min(milliseconds, 600_000)
      state.queue.asyncAfter(deadline: .now() + milliseconds / 1000) { [weak state] in
        guard let state, !state.isFinished, let context = state.context else { return }
        _ = context.objectForKeyedSubscript("__tsumiFireTimer")?.call(withArguments: [NSNumber(value: timerID)])
      }
    }

    let fetch: @convention(block) (String, JSValue) -> Void = { [weak state] request, callback in
      guard let state, !state.isFinished else { return }
      SoraNetwork.start(requestJSON: request, callback: callback, state: state)
    }

    // Response text, decoded on first use (a binary answer is never decoded). Valid UTF-8 is released at once:
    // its bytes are the text's UTF-8 encoding, which the prelude rebuilds if the module asks for them later.
    let text: @convention(block) (JSValue) -> JSValue = { [weak state] identifier in
      let current: JSContext = identifier.context
      let key = Int(identifier.toInt32())
      guard let state, var body = state.bodies[key] else { return JSValue(nullIn: current) }
      let decoded: String
      if body.encoding == nil, let valid = String(data: body.data, encoding: .utf8) {
        decoded = valid
        state.bodies[key] = nil
      } else {
        decoded = SoraNetwork.decode(body.data, encoding: body.encoding)
        body.textRead = true
        state.bodies[key] = body
      }
      return JSValue(object: decoded, in: current)
    }

    // Response bytes (base64), copied on first use. Kept for a later text read (decoded natively, much faster than in
    // JavaScript), released once the text was read too.
    let bytes: @convention(block) (JSValue) -> JSValue = { [weak state] identifier in
      let current: JSContext = identifier.context
      let key = Int(identifier.toInt32())
      guard let state, let body = state.bodies[key] else { return JSValue(nullIn: current) }
      let encoded = body.data.base64EncodedString()
      if body.textRead {
        state.bodies[key] = nil
      }
      return JSValue(object: encoded, in: current)
    }

    let done: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak state] ok, payload, isString in
      guard let state else { return }
      let text: String? = (payload.isUndefined || payload.isNull) ? nil : payload.toString()
      if ok.toBool() {
        let value = SoraRuntime.decodeResult(text, isString: isString.toBool())
        state.finish(.success(SoraCallOutput(value: value)))
      } else {
        state.finish(.failure(ExtensionFailure(text ?? "Unknown extension error")))
      }
    }

    // crypto.getRandomValues / randomUUID: `count` random bytes (system CSPRNG), base64.
    let random: @convention(block) (JSValue) -> String = { count in
      SoraBridge.randomBytes(count: Int(count.toInt32()))
    }

    // crypto.subtle.digest: (SHA1 | SHA256 | SHA384 | SHA512, base64 data) -> base64 digest, "" if unknown.
    let digest: @convention(block) (String, String) -> String = { algorithm, payload in
      SoraBridge.digest(algorithm: algorithm, base64: payload)
    }

    context.setObject(log, forKeyedSubscript: "__tsumiLog" as NSString)
    context.setObject(schedule, forKeyedSubscript: "__tsumiSchedule" as NSString)
    context.setObject(fetch, forKeyedSubscript: "__tsumiFetch" as NSString)
    context.setObject(text, forKeyedSubscript: "__tsumiText" as NSString)
    context.setObject(bytes, forKeyedSubscript: "__tsumiBytes" as NSString)
    context.setObject(done, forKeyedSubscript: "__tsumiDone" as NSString)
    context.setObject(random, forKeyedSubscript: "__tsumiRandom" as NSString)
    context.setObject(digest, forKeyedSubscript: "__tsumiDigest" as NSString)
  }

  /// Random bytes for the crypto shim (SystemRandomNumberGenerator is cryptographically secure on
  /// Apple platforms). Capped at 65536 bytes like getRandomValues.
  static func randomBytes(count: Int) -> String {
    let length = max(0, min(count, 65_536))
    var generator = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: length)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
    }
    return Data(bytes).base64EncodedString()
  }

  /// SubtleCrypto.digest with CryptoKit. `algorithm` is upper-cased without dashes by the prelude.
  static func digest(algorithm: String, base64: String) -> String {
    let data = Data(base64Encoded: base64) ?? Data()
    let name = algorithm.uppercased().replacingOccurrences(of: "-", with: "")
    let output: [UInt8]
    switch name {
    case "SHA1":
      output = Array(Insecure.SHA1.hash(data: data))
    case "SHA256":
      output = Array(SHA256.hash(data: data))
    case "SHA384":
      output = Array(SHA384.hash(data: data))
    case "SHA512":
      output = Array(SHA512.hash(data: data))
    default:
      return ""
    }
    return Data(output).base64EncodedString()
  }
}

/// URLSession side of `fetchv2` / `fetch`. Mirrors the Electron fetch proxy (electron/src/main/streamProxy.js):
/// desktop Chrome User-Agent unless the module sets one, any header allowed, body ignored for GET/HEAD,
/// network failures answered as HTTP 500 with `{"error": message}` for fetchv2. On top of the proxy: answers are
/// capped at 20 MB, and local addresses (this device, the local network) are refused, redirects included, unless the
/// module itself was installed from such an address.
enum SoraNetwork {
  static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  static let fetcher: ExtensionFetchSession = {
    let configuration = URLSessionConfiguration.default
    // No automatic cookie jar: modules send their own Cookie headers (like the proxy).
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = ExtensionHTTP.resourceTimeout
    configuration.httpMaximumConnectionsPerHost = 8
    return ExtensionFetchSession(configuration: configuration, name: "org.tsumi.extensions.module-network")
  }()

  /// Called from the module (on the call's queue).
  static func start(requestJSON: String, callback: JSValue, state: SoraCallState) {
    let parsed = ExtensionJSON.parse(requestJSON) as? [String: Any]
    let target = parsed?["url"] as? String ?? ""
    guard let request = parsed,
          let url = URL.lenient(target),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      state.queue.async {
        SoraNetwork.deliverFailure(callback, state: state, url: target, message: "Invalid URL")
      }
      return
    }
    let allowsLocal = state.allowsLocalNetwork
    if !allowsLocal && ExtensionNetworkPolicy.isLocal(url) {
      state.queue.async {
        SoraNetwork.deliverFailure(callback, state: state, url: target, message: ExtensionNetworkPolicy.blockedMessage)
      }
      return
    }

    let method = ((request["method"] as? String) ?? "GET").uppercased()
    var urlRequest = URLRequest(url: url, timeoutInterval: 30)
    urlRequest.httpMethod = method
    var hasUserAgent = false
    var hasContentType = false
    for (name, value) in ExtensionJSON.headers(request["headers"]) {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let lower = trimmed.lowercased()
      if lower == "user-agent" { hasUserAgent = true }
      if lower == "content-type" { hasContentType = true }
      urlRequest.setValue(value, forHTTPHeaderField: trimmed)
    }
    if method != "GET" && method != "HEAD" {
      if let text = request["bodyText"] as? String {
        urlRequest.httpBody = Data(text.utf8)
        if !hasContentType { urlRequest.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type") }
      } else if let base64 = request["bodyBase64"] as? String, let data = Data(base64Encoded: base64) {
        urlRequest.httpBody = data
      }
    }
    if !hasUserAgent { urlRequest.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent") }
    let follow = (request["follow"] as? Bool) ?? true
    let encoding = request["encoding"] as? String
    let requestedURL = url.absoluteString

    var taskBox: URLSessionTask?
    let task = fetcher.makeTask(
      urlRequest,
      limit: ExtensionHTTP.maxResponseBytes,
      follow: follow,
      allowRedirect: { allowsLocal || !ExtensionNetworkPolicy.isLocal($0) }
    ) { [weak state] result in
      guard let state else { return }
      state.queue.async { [weak state] in
        guard let state else { return }
        if let finishedTask = taskBox { state.unregister(finishedTask) }
        guard !state.isFinished else { return }
        switch result {
        case .failure(let error):
          SoraNetwork.deliverFailure(callback, state: state, url: requestedURL, message: error.localizedDescription)
        case .success(let value):
          let http = value.1 as? HTTPURLResponse
          var headers: [String: String] = [:]
          if let http {
            for (key, headerValue) in http.allHeaderFields {
              if let name = key as? String { headers[name] = String(describing: headerValue) }
            }
          }
          let status = http?.statusCode ?? 200
          // No "text": the prelude asks for it (or for the bytes) when the module reads the body.
          let meta: [String: Any] = [
            "status": status,
            "statusText": SoraNetwork.statusText(status),
            "url": value.1?.url?.absoluteString ?? requestedURL,
            "headers": headers,
            "bodyId": state.storeBody(value.0, encoding: encoding)
          ]
          _ = callback.call(withArguments: [meta])
        }
      }
    }
    taskBox = task
    guard state.register(task) else {
      fetcher.discard(task)
      return
    }
    task.resume()
  }

  private static func deliverFailure(_ callback: JSValue, state: SoraCallState, url: String, message: String) {
    guard !state.isFinished else { return }
    let body = ExtensionJSON.stringify(["error": message]) ?? "{}"
    let meta: [String: Any] = [
      "status": 500,
      "statusText": "Internal Server Error",
      "url": url,
      "headers": ["content-type": "application/json"],
      "text": body,
      "bodyId": state.storeBody(Data(body.utf8), encoding: nil),
      "networkError": message
    ]
    _ = callback.call(withArguments: [meta])
  }

  /// Response text: UTF-8 with replacement characters (like Response.text()), or the
  /// encoding a Sora module asked for (fetchv2 6th argument).
  static func decode(_ data: Data, encoding: String?) -> String {
    if let name = encoding?.lowercased() {
      let requested: String.Encoding?
      switch name {
      case "windows-1251", "cp1251": requested = .windowsCP1251
      case "windows-1252", "cp1252": requested = .windowsCP1252
      case "iso-8859-1", "latin1": requested = .isoLatin1
      case "ascii": requested = .ascii
      case "utf-16", "utf16": requested = .utf16
      default: requested = nil
      }
      if let requested, let text = String(data: data, encoding: requested) { return text }
    }
    return String(decoding: data, as: UTF8.self)
  }

  static func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 201: return "Created"
    case 202: return "Accepted"
    case 204: return "No Content"
    case 206: return "Partial Content"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 303: return "See Other"
    case 304: return "Not Modified"
    case 307: return "Temporary Redirect"
    case 308: return "Permanent Redirect"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 410: return "Gone"
    case 429: return "Too Many Requests"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default: return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
  }
}
