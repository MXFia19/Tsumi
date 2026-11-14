import Foundation

enum HTTPError: LocalizedError {
  case status(Int, URL?)
  case invalidResponse
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .status(let code, let url): return "HTTP \(code) for \(url?.host() ?? "request")"
    case .invalidResponse: return "Invalid server response"
    case .decoding(let message): return "Could not read the response: \(message)"
    }
  }
}

/// Small async HTTP helper shared by every service.
enum HTTP {
  static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.requestCachePolicy = .useProtocolCachePolicy
    config.httpAdditionalHeaders = ["User-Agent": "Tsumi/iOS"]
    return URLSession(configuration: config)
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// Raw request; throws on non-2xx unless `allowErrorStatus` is set.
  @discardableResult
  static func data(
    _ url: URL,
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 30,
    allowErrorStatus: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = body
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
    if !allowErrorStatus, !(200..<300).contains(http.statusCode) { throw HTTPError.status(http.statusCode, url) }
    return (data, http)
  }

  static func json<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
    let (data, _) = try await data(url, headers: headers, timeout: timeout)
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw HTTPError.decoding(String(describing: error))
    }
  }

  /// Untyped JSON (dictionaries/arrays), for loosely structured APIs.
  static func jsonObject(from url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Any {
    let (data, _) = try await data(url, headers: headers, timeout: timeout)
    return try JSONSerialization.jsonObject(with: data)
  }

  static func postJSON(_ url: URL, body: Any, headers: [String: String] = [:]) async throws -> Any {
    var allHeaders = headers
    allHeaders["Content-Type"] = "application/json"
    allHeaders["Accept"] = "application/json"
    let payload = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await data(url, method: "POST", headers: allHeaders, body: payload)
    return try JSONSerialization.jsonObject(with: data)
  }
}

extension URL {
  /// URL from a string that may contain spaces or unicode.
  static func lenient(_ string: String?) -> URL? {
    guard let string, !string.isEmpty else { return nil }
    return URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
  }
}

/// Helpers to read untyped JSON safely.
extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
  func int(_ key: String) -> Int? {
    if let value = self[key] as? Int { return value }
    if let value = self[key] as? Double { return Int(value) }
    if let value = self[key] as? String { return Int(value) }
    return nil
  }
  func double(_ key: String) -> Double? {
    if let value = self[key] as? Double { return value }
    if let value = self[key] as? Int { return Double(value) }
    if let value = self[key] as? String { return Double(value) }
    return nil
  }
  func bool(_ key: String) -> Bool? { self[key] as? Bool }
  func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
  func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
