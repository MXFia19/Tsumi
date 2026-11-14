import Foundation
import Network
import Observation

// Shared helpers of the data/services layer (rate limiting, locks, dates, fuzzy text matching,
// network status, toasts). Mirrors small utilities of common/modules/util.js and networking.js.

// MARK: - Errors

enum ServiceError: LocalizedError {
  case offline
  case notAuthorized
  case api(String)
  case rateLimited
  case invalidResponse
  case cancelled

  var errorDescription: String? {
    switch self {
    case .offline: return "The network is offline."
    case .notAuthorized: return "You need to be logged in to do this."
    case .api(let message): return message
    case .rateLimited: return "Too many requests, try again in a minute."
    case .invalidResponse: return "Invalid server response."
    case .cancelled: return "The operation was cancelled."
    }
  }
}

// MARK: - Lock

/// Small thread-safe box (NSLock.withLock is usable from async code).
final class ServiceLocked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.withLock { value }
  }

  func set(_ newValue: Value) {
    lock.withLock { value = newValue }
  }

  @discardableResult
  func update<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&value) }
  }
}

// MARK: - Rate limiter (Bottleneck equivalent: reservoir per interval + minimum spacing)

actor ServiceRateLimiter {
  private let capacity: Int
  private let interval: TimeInterval
  private let minSpacing: TimeInterval
  private var tokens: Int
  private var windowStart: Date = Date()
  private var nextSlot: Date = .distantPast
  private var pausedUntil: Date = .distantPast

  init(capacity: Int, interval: TimeInterval, minSpacing: TimeInterval) {
    self.capacity = capacity
    self.interval = interval
    self.minSpacing = minSpacing
    self.tokens = capacity
  }

  /// Waits until a request may be sent.
  func acquire() async {
    while true {
      let now = Date()
      if now.timeIntervalSince(windowStart) >= interval {
        tokens = capacity
        windowStart = now
      }
      var wait: TimeInterval = 0
      if pausedUntil > now {
        wait = pausedUntil.timeIntervalSince(now)
      } else if tokens <= 0 {
        wait = interval - now.timeIntervalSince(windowStart)
      } else if nextSlot > now {
        wait = nextSlot.timeIntervalSince(now)
      }
      if wait <= 0 {
        tokens -= 1
        nextSlot = now.addingTimeInterval(minSpacing)
        return
      }
      let nanos = UInt64(max(wait, 0.01) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
    }
  }

  /// Blocks every request for `seconds` (429 Retry-After handling).
  func pause(for seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    if until > pausedUntil { pausedUntil = until }
  }
}

// MARK: - In-flight request de-duplication (cache.js #pending / concurrentRequests maps)

/// Type-erased result box (Task results must be Sendable).
final class ServiceAnyBox: @unchecked Sendable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }
}

actor ServiceInflight {
  private var tasks: [String: Task<ServiceAnyBox, Error>] = [:]

  func run<T>(_ key: String, _ work: @escaping () async throws -> T) async throws -> T {
    if let existing = tasks[key] {
      let box = try await existing.value
      if let typed = box.value as? T { return typed }
    }
    let task = Task<ServiceAnyBox, Error> {
      let result: T = try await work()
      return ServiceAnyBox(result)
    }
    tasks[key] = task
    defer { tasks[key] = nil }
    let box = try await task.value
    guard let typed = box.value as? T else { throw ServiceError.invalidResponse }
    return typed
  }
}

// MARK: - Fuzzy dates (AniList FuzzyDate)

struct FuzzyDate: Codable, Hashable {
  var year: Int?
  var month: Int?
  var day: Int?

  var isComplete: Bool { year != nil && month != nil && day != nil }
  var isEmpty: Bool { year == nil && month == nil && day == nil }
  var sortValue: Int { (year ?? 0) * 10000 + (month ?? 0) * 100 + (day ?? 0) }

  var date: Date? {
    guard let year else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month ?? 1
    components.day = day ?? 1
    return Calendar(identifier: .gregorian).date(from: components)
  }

  /// "YYYY-MM-DD" when complete (MyAnimeList start_date / finish_date format).
  var isoDay: String? {
    guard let year, let month, let day else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  /// FuzzyDateInput for GraphQL mutations.
  var graphQL: [String: Any] {
    var result: [String: Any] = [:]
    if let year { result["year"] = year }
    if let month { result["month"] = month }
    if let day { result["day"] = day }
    return result
  }

  static func from(_ date: Date) -> FuzzyDate {
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
    return FuzzyDate(year: components.year, month: components.month, day: components.day)
  }

  static func parse(_ dict: [String: Any]?) -> FuzzyDate? {
    guard let dict else { return nil }
    let value = FuzzyDate(year: dict.int("year"), month: dict.int("month"), day: dict.int("day"))
    return value.isEmpty ? nil : value
  }

  /// Parses "YYYY-MM-DD" (or a longer ISO string).
  static func parse(isoDay: String?) -> FuzzyDate? {
    guard let isoDay, isoDay.count >= 4 else { return nil }
    let parts = isoDay.prefix(10).split(separator: "-").map { Int($0) }
    let year = parts.count > 0 ? parts[0] : nil
    let month = parts.count > 1 ? parts[1] : nil
    let day = parts.count > 2 ? parts[2] : nil
    let value = FuzzyDate(year: year, month: month, day: day)
    return value.isEmpty ? nil : value
  }
}

// MARK: - Dates

enum ServiceDates {
  private static let isoPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let localDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
  }()

  private static let longFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "EEEE, MMM dd, yyyy, hh:mm a"
    return formatter
  }()

  /// Epoch seconds (or milliseconds when the value is huge).
  static func epoch(_ value: Double) -> Date {
    value > 10_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
  }

  /// Parses epoch numbers, ISO 8601 strings, "YYYY-MM-DD" (local midnight) and local date-times.
  static func parse(_ value: Any?) -> Date? {
    if let number = value as? Int { return epoch(Double(number)) }
    if let number = value as? Double { return epoch(number) }
    guard let string = value as? String, !string.isEmpty else { return nil }
    if let date = isoPlain.date(from: string) { return date }
    if let date = isoFractional.date(from: string) { return date }
    if string.count == 10, let date = dayFormatter.date(from: string) { return date }
    if let date = localDateTimeFormatter.date(from: String(string.prefix(19))) { return date }
    return nil
  }

  /// `new Date(`${day}T23:59:59`)` of tmdb.js (local end of day).
  static func endOfDay(_ isoDay: String) -> Date? {
    if isoDay.contains("T") { return parse(isoDay) }
    return localDateTimeFormatter.date(from: String(isoDay.prefix(10)) + "T23:59:59")
  }

  static func dayString(_ date: Date) -> String {
    dayFormatter.string(from: date)
  }

  /// toLocaleString('en-US', { weekday: 'long', year, month: 'short', day: '2-digit', hour, minute, hour12 })
  static func longString(_ date: Date) -> String {
    longFormatter.string(from: date)
  }
}

// MARK: - Seasons (anilist.js currentSeason / currentYear)

enum AnimeSeasonClock {
  static let ordered: [MediaSeason] = [.winter, .spring, .summer, .fall]

  static var currentSeason: MediaSeason {
    let month = Calendar.current.component(.month, from: Date()) - 1
    let index = Int((Double(month) / 12.0 * 4.0).rounded(.down)) % 4
    return ordered[index]
  }

  static var currentYear: Int {
    Calendar.current.component(.year, from: Date())
  }

  /// Season after the current one (Anime - Upcoming Next Season).
  static var nextSeason: (season: MediaSeason, year: Int) {
    let current = currentSeason
    let index = ordered.firstIndex(of: current) ?? 0
    let next = ordered[(index + 1) % ordered.count]
    return (next, currentYear + (current == .fall ? 1 : 0))
  }
}

// MARK: - JSON helpers (namespaced to avoid clashing with other extensions)

enum ServiceJSON {
  static func strings(_ dict: [String: Any]?, _ key: String) -> [String] {
    guard let raw = dict?[key] as? [Any] else { return [] }
    return raw.compactMap { $0 as? String }
  }

  static func ints(_ dict: [String: Any]?, _ key: String) -> [Int] {
    guard let raw = dict?[key] as? [Any] else { return [] }
    return raw.compactMap { value -> Int? in
      if let int = value as? Int { return int }
      if let double = value as? Double { return Int(double) }
      if let string = value as? String { return Int(string) }
      return nil
    }
  }

  static func object(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// First GraphQL / REST error message of a response, if any.
  static func errorMessage(_ json: [String: Any]?) -> String? {
    guard let json else { return nil }
    if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
      return first.string("message") ?? first.string("title") ?? "Request failed"
    }
    if let error = json["error"] as? String { return error }
    return nil
  }

  /// application/x-www-form-urlencoded body.
  static func formBody(_ values: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let pairs = values.keys.sorted().map { key -> String in
      let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let value = (values[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return name + "=" + value
    }
    return Data(pairs.joined(separator: "&").utf8)
  }

  /// Stable cache key for any Encodable value.
  static func cacheKey<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else { return UUID().uuidString }
    return string
  }
}

/// Lossy decoding helpers for loosely typed third party JSON (ani.zip, kitsu, feeds).
extension KeyedDecodingContainer {
  func svcLossyInt(_ key: Key) -> Int? {
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) ?? Double(value).map { Int($0) } }
    return nil
  }

  func svcLossyDouble(_ key: Key) -> Double? {
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
    return nil
  }

  func svcLossyString(_ key: Key) -> String? {
    if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
    return nil
  }

  func svcLossyBool(_ key: Key) -> Bool? {
    if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
    return nil
  }
}

// MARK: - Text (util.js matchKeys / matchPhrase / countdown / since, js-levenshtein)

enum ServiceText {
  static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
    let source = Array(lhs)
    let target = Array(rhs)
    if source.isEmpty { return target.count }
    if target.isEmpty { return source.count }
    var previous = Array(0...target.count)
    var current = [Int](repeating: 0, count: target.count + 1)
    for i in 1...source.count {
      current[0] = i
      for j in 1...target.count {
        let cost = source[i - 1] == target[j - 1] ? 0 : 1
        current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[target.count]
  }

  private static let numberWords: [Int: String] = [
    1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten",
    11: "Eleven", 12: "Twelve", 13: "Thirteen", 14: "Fourteen", 15: "Fifteen", 16: "Sixteen", 17: "Seventeen",
    18: "Eighteen", 19: "Nineteen", 20: "Twenty"
  ]

  private static let hyphenRegex = try? NSRegularExpression(pattern: "(\\w)-(\\w)")
  private static let symbolRegex = try? NSRegularExpression(pattern: "[^\\p{L}\\p{N}\\p{Zs}\\p{Pd}]")
  private static let seasonRegex = try? NSRegularExpression(pattern: "Season (\\d{1,2})", options: [.caseInsensitive])

  private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
    guard let regex else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }

  /// cleanText of util.js, lowercased.
  static func clean(_ text: String) -> String {
    var value = replace(hyphenRegex, in: text, with: "$1 $2")
    value = replace(symbolRegex, in: value, with: "")
    if let regex = seasonRegex {
      let nsValue = value as NSString
      let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
      var result = value
      for match in matches.reversed() {
        let number = Int(nsValue.substring(with: match.range(at: 1))) ?? 0
        if let word = numberWords[number], let range = Range(match.range, in: result) {
          result.replaceSubrange(range, with: "Season \(word)")
        }
      }
      value = result
    }
    return value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Approximate Fuse.js matching: substring, or best window Levenshtein ratio under `threshold`.
  static func fuzzyContains(_ haystack: String, _ needle: String, threshold: Double) -> Bool {
    if needle.isEmpty { return true }
    if haystack.isEmpty { return false }
    if haystack.contains(needle) { return true }
    let hay = Array(haystack)
    let pattern = Array(needle)
    let allowed = Int((Double(pattern.count) * threshold).rounded(.down))
    if allowed <= 0 { return false }
    if hay.count <= pattern.count {
      return levenshtein(haystack, needle) <= allowed
    }
    var best = Int.max
    let lengths = [pattern.count, pattern.count - 1, pattern.count + 1].filter { $0 > 0 && $0 <= hay.count }
    for length in lengths {
      var start = 0
      while start + length <= hay.count {
        let window = String(hay[start..<(start + length)])
        best = Swift.min(best, levenshtein(window, needle))
        if best == 0 { return true }
        start += 1
      }
    }
    return best <= allowed
  }

  /// matchKeys: true when `phrase` is empty or loosely matches one of the candidate strings.
  static func matchKeys(_ candidates: [String], phrase: String?, threshold: Double = 0.4) -> Bool {
    guard let phrase, !phrase.isEmpty else { return true }
    let cleanedPhrase = clean(phrase)
    if cleanedPhrase.isEmpty { return true }
    for candidate in candidates {
      let cleaned = clean(candidate)
      if cleaned.isEmpty { continue }
      if fuzzyContains(cleaned, cleanedPhrase, threshold: threshold) { return true }
      if fuzzyContains(cleanedPhrase, cleaned, threshold: threshold) { return true }
    }
    return false
  }

  /// matchPhrase (non strict): inclusion, or one word within `threshold` edits.
  static func matchPhrase(_ search: String?, _ phrases: [String], threshold: Int) -> Bool {
    guard let search, !search.isEmpty else { return false }
    let normalized = clean(search)
    for phrase in phrases where !phrase.isEmpty {
      let target = clean(phrase)
      if target.isEmpty { continue }
      if normalized.contains(target) { return true }
      for word in normalized.split(whereSeparator: { $0 == " " }) where levenshtein(String(word), target) <= threshold {
        return true
      }
    }
    return false
  }

  /// countdown(seconds) of util.js: "1d 2h 3m".
  static func countdown(_ seconds: TimeInterval) -> String {
    var remaining = Int(abs(seconds).rounded(.down))
    let days = remaining / 86400
    remaining -= days * 86400
    let hours = remaining / 3600
    remaining -= hours * 3600
    let minutes = remaining / 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if days > 0 || hours > 0 { parts.append("\(hours)h") }
    if days > 0 || hours > 0 || minutes > 0 { parts.append("\(minutes)m") }
    if parts.isEmpty { parts.append("1m") }
    return parts.joined(separator: " ")
  }

  /// since(date) of util.js: "in 3 days" / "2 hours ago".
  static func since(_ date: Date) -> String {
    let elapsed = date.timeIntervalSinceNow
    let ranges: [(Calendar.Component, Double)] = [
      (.year, 3600 * 24 * 365), (.month, 3600 * 24 * 30), (.weekOfMonth, 3600 * 24 * 7),
      (.day, 3600 * 24), (.hour, 3600), (.minute, 60), (.second, 1)
    ]
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    for (unit, seconds) in ranges where seconds < abs(elapsed) {
      let delta = Int((elapsed / seconds).rounded())
      var components = DateComponents()
      switch unit {
      case .year: components.year = delta
      case .month: components.month = delta
      case .weekOfMonth: components.weekOfMonth = delta
      case .day: components.day = delta
      case .hour: components.hour = delta
      case .minute: components.minute = delta
      default: components.second = delta
      }
      return formatter.localizedString(from: components)
    }
    return formatter.localizedString(fromTimeInterval: 0)
  }

  /// monthDay(date, year) of util.js.
  static func monthDay(_ date: Date, year: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    if year {
      formatter.dateFormat = "MMMM yyyy"
      return formatter.string(from: date)
    }
    formatter.dateFormat = "MMMM"
    let day = Calendar.current.component(.day, from: date)
    let suffix: String
    switch day {
    case 1, 21, 31: suffix = "st"
    case 2, 22: suffix = "nd"
    case 3, 23: suffix = "rd"
    default: suffix = "th"
    }
    return formatter.string(from: date) + " \(day)\(suffix)"
  }

  /// generateRandomString of util.js (PKCE state / challenge).
  static func randomString(_ length: Int) -> String {
    let possible = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var result = ""
    for _ in 0..<length {
      if let character = possible.randomElement() { result.append(character) }
    }
    return result
  }

  static func base64(_ encoded: String) -> String {
    guard let data = Data(base64Encoded: encoded), let string = String(data: data, encoding: .utf8) else { return "" }
    return string
  }
}

// MARK: - Network status (networking.js `status`)

final class ServiceNetworkMonitor: @unchecked Sendable {
  static let shared = ServiceNetworkMonitor()

  private let monitor = NWPathMonitor()
  private let online = ServiceLocked<Bool>(true)

  var isOnline: Bool { online.get() }

  private init() {
    let box = online
    monitor.pathUpdateHandler = { path in
      box.set(path.status == .satisfied)
    }
    monitor.start(queue: DispatchQueue(label: "org.tsumi.services.network"))
  }
}

// MARK: - Extra settings not present in Core SettingsValues

/// Settings used by the Svelte modules that Core/Settings.swift does not define (stored in UserDefaults).
enum ServiceSettingsExtras {
  private static let defaults = UserDefaults.standard

  /// releasesNotify 'NOTONLIST' option (notify for media that are not on the user's list).
  static var releasesNotifyNotOnList: Bool {
    get { defaults.bool(forKey: "tsumi.services.releasesNotify.notOnList") }
    set { defaults.set(newValue, forKey: "tsumi.services.releasesNotify.notOnList") }
  }

  /// hentaiAnnounce: none | limited | all.
  static var hentaiAnnounce: String {
    get { defaults.string(forKey: "tsumi.services.hentaiAnnounce") ?? "none" }
    set { defaults.set(newValue, forKey: "tsumi.services.hentaiAnnounce") }
  }

  /// cardAudio: shows dub airing info in episode lists.
  static var cardAudio: Bool {
    get { defaults.bool(forKey: "tsumi.services.cardAudio") }
    set { defaults.set(newValue, forKey: "tsumi.services.cardAudio") }
  }
}

// MARK: - Toasts (svelte-sonner toasts / printError)

@Observable
@MainActor
final class ServiceMessages {
  static let shared = ServiceMessages()

  enum Kind: String, Hashable {
    case success
    case warning
    case error
    case info
  }

  struct Message: Identifiable, Hashable {
    let id: UUID
    var kind: Kind
    var title: String
    var detail: String
    var date: Date
  }

  private(set) var messages: [Message] = []

  var latest: Message? { messages.last }

  private init() {}

  /// Posts a toast if the `toasts` setting allows it (All | Errors | None).
  func post(_ kind: Kind, _ title: String, _ detail: String = "") {
    let setting = AppSettings.shared.values.toasts
    if setting.contains("None") { return }
    if kind != .error && !setting.contains("All") { return }
    messages.append(Message(id: UUID(), kind: kind, title: title, detail: detail, date: Date()))
    if messages.count > 20 { messages.removeFirst(messages.count - 20) }
  }

  func dismiss(_ id: UUID) {
    messages.removeAll { $0.id == id }
  }

  func clear() {
    messages.removeAll()
  }

  /// Posts from any thread.
  nonisolated static func send(_ kind: Kind, _ title: String, _ detail: String = "") {
    Task { @MainActor in
      ServiceMessages.shared.post(kind, title, detail)
    }
  }
}
