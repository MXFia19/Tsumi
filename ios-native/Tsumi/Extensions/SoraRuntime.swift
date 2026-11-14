import CryptoKit
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
/// All JavaScript work runs on one serial queue.
enum SoraRuntime {
  static let queue = DispatchQueue(label: "org.tsumi.extensions.javascript", qos: .userInitiated)
  static let executionTimeout: TimeInterval = 30

  /// Calls `functionName(arguments...)` defined by `script`. Returns the JSON-decoded result
  /// (dictionary, array, string, number) or nil for null/undefined.
  static func call(script: String, functionName: String, arguments: [Any], timeout: TimeInterval = SoraRuntime.executionTimeout) async throws -> Any? {
    guard isIdentifier(functionName) else {
      throw ExtensionFailure("Invalid extension function name: \(functionName)")
    }
    let argumentList = try encodeArguments(arguments)
    let state = SoraCallState()
    let output: SoraCallOutput = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SoraCallOutput, Error>) in
        SoraRuntime.queue.async {
          if state.cancelled {
            continuation.resume(throwing: CancellationError())
            return
          }
          state.continuation = continuation
          SoraRuntime.run(state: state, script: script, functionName: functionName, argumentList: argumentList, timeout: timeout)
        }
      }
    } onCancel: {
      SoraRuntime.queue.async {
        state.cancelled = true
        state.finish(.failure(CancellationError()))
      }
    }
    return output.value
  }

  // MARK: - Execution

  private static func run(state: SoraCallState, script: String, functionName: String, argumentList: String, timeout: TimeInterval) {
    let machine = JSVirtualMachine()
    let created: JSContext? = JSContext(virtualMachine: machine)
    guard let context = created else {
      state.finish(.failure(ExtensionFailure("Could not start the JavaScript engine")))
      return
    }
    state.context = context
    context.exceptionHandler = { [weak state] _, exception in
      state?.recordException(SoraRuntime.describe(exception))
    }
    SoraBridge.install(in: context, state: state)

    _ = context.evaluateScript(SoraPrelude.source, withSourceURL: URL(string: "tsumi://extension-runtime.js"))
    if let message = state.takeException() {
      state.finish(.failure(ExtensionFailure("Extension runtime failed to start: \(message)")))
      return
    }

    // Same shape as the Svelte AsyncFunction body: module code, then `return await fn(args)`.
    let code = "(async function () {\n" + script + "\n;return await " + functionName + "(" + argumentList + ");\n})().then(__tsumiResolve, __tsumiReject);"
    _ = context.evaluateScript(code, withSourceURL: URL(string: "tsumi://extension-module.js"))
    if let message = state.takeException() {
      state.finish(.failure(ExtensionFailure(message)))
      return
    }

    SoraRuntime.queue.asyncAfter(deadline: .now() + timeout) { [weak state] in
      state?.finish(.failure(ExtensionFailure("Extension execution timeout")))
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

/// Value returned by a call, boxed so it can cross the continuation.
struct SoraCallOutput: @unchecked Sendable {
  let value: Any?
}

/// State of one running call. Only touched on `SoraRuntime.queue`.
final class SoraCallState: @unchecked Sendable {
  var context: JSContext?
  var continuation: CheckedContinuation<SoraCallOutput, Error>?
  var finished = false
  var cancelled = false
  var tasks: [URLSessionTask] = []
  var bodies: [Int: Data] = [:]
  var nextBodyID = 0
  private var pendingException: String?

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

  func storeBody(_ data: Data) -> Int {
    let identifier = nextBodyID
    nextBodyID += 1
    bodies[identifier] = data
    return identifier
  }

  func finish(_ result: Result<SoraCallOutput, Error>) {
    guard !finished else { return }
    finished = true
    let pending = continuation
    continuation = nil
    for task in tasks { task.cancel() }
    tasks.removeAll()
    bodies.removeAll()
    // finish() may run inside a JavaScript callback: keep the context alive until the current
    // queue work item has returned, then let it go.
    let retiring = context
    context = nil
    SoraRuntime.queue.async {
      retiring?.exceptionHandler = nil
    }
    pending?.resume(with: result)
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
      guard state != nil else { return }
      let timerID = identifier.toInt32()
      var milliseconds = delay.toDouble()
      if !milliseconds.isFinite || milliseconds < 0 { milliseconds = 0 }
      milliseconds = min(milliseconds, 600_000)
      SoraRuntime.queue.asyncAfter(deadline: .now() + milliseconds / 1000) { [weak state] in
        guard let state, !state.finished, let context = state.context else { return }
        _ = context.objectForKeyedSubscript("__tsumiFireTimer")?.call(withArguments: [NSNumber(value: timerID)])
      }
    }

    let fetch: @convention(block) (String, JSValue) -> Void = { [weak state] request, callback in
      guard let state, !state.finished else { return }
      SoraNetwork.start(requestJSON: request, callback: callback, state: state)
    }

    let bytes: @convention(block) (JSValue) -> String = { [weak state] identifier in
      guard let state, let data = state.bodies[Int(identifier.toInt32())] else { return "" }
      return data.base64EncodedString()
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
/// network failures answered as HTTP 500 with `{"error": message}` for fetchv2.
enum SoraNetwork {
  static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    // No automatic cookie jar: modules send their own Cookie headers (like the proxy).
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.httpMaximumConnectionsPerHost = 8
    return URLSession(configuration: configuration)
  }()

  static func start(requestJSON: String, callback: JSValue, state: SoraCallState) {
    guard let request = ExtensionJSON.parse(requestJSON) as? [String: Any],
          let urlString = request["url"] as? String,
          let url = URL.lenient(urlString),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      let target = (ExtensionJSON.parse(requestJSON) as? [String: Any])?["url"] as? String ?? ""
      SoraRuntime.queue.async {
        SoraNetwork.deliverFailure(callback, state: state, url: target, message: "Invalid URL")
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

    let task = session.dataTask(with: urlRequest) { [weak state] data, response, error in
      SoraRuntime.queue.async { [weak state] in
        guard let state, !state.finished else { return }
        if let error {
          SoraNetwork.deliverFailure(callback, state: state, url: requestedURL, message: error.localizedDescription)
          return
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        if let http {
          for (key, value) in http.allHeaderFields {
            if let name = key as? String { headers[name] = String(describing: value) }
          }
        }
        let status = http?.statusCode ?? 200
        let body = data ?? Data()
        let meta: [String: Any] = [
          "status": status,
          "statusText": SoraNetwork.statusText(status),
          "url": response?.url?.absoluteString ?? requestedURL,
          "headers": headers,
          "text": SoraNetwork.decode(body, encoding: encoding),
          "bodyId": state.storeBody(body)
        ]
        _ = callback.call(withArguments: [meta])
      }
    }
    if !follow { task.delegate = SoraRedirectBlocker.shared }
    state.tasks.append(task)
    task.resume()
  }

  private static func deliverFailure(_ callback: JSValue, state: SoraCallState, url: String, message: String) {
    guard !state.finished else { return }
    let body = ExtensionJSON.stringify(["error": message]) ?? "{}"
    let meta: [String: Any] = [
      "status": 500,
      "statusText": "Internal Server Error",
      "url": url,
      "headers": ["content-type": "application/json"],
      "text": body,
      "bodyId": state.storeBody(Data(body.utf8)),
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

/// Per-task delegate used when a module calls fetchv2 with `redirect = false` (Sora API) or
/// fetch with `redirect: 'manual'`.
final class SoraRedirectBlocker: NSObject, URLSessionTaskDelegate {
  static let shared = SoraRedirectBlocker()

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
