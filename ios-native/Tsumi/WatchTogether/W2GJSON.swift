import Foundation

// JSON for the Watch Together wire protocol.
//
// Foundation's JSONSerialization is not used here on purpose: the WebTorrent tracker protocol
// carries 20-byte ids as JavaScript "binary strings" (one char per byte, U+0000...U+00FF), and
// P2PT splits messages by JavaScript string length (UTF-16 code units). Strings are therefore
// kept as UTF-16 code unit arrays, exactly like a JS string, and written the way JSON.stringify
// writes them.

/// A JSON value whose strings are raw UTF-16 code units (a JavaScript string).
enum W2GJSON {
  case null
  case bool(Bool)
  case number(Double)
  case string([UInt16])
  case array([W2GJSON])
  /// Ordered members (JSON.stringify keeps insertion order; lookups take the last duplicate like JSON.parse).
  case object([W2GJSONMember])
}

struct W2GJSONMember {
  var key: String
  var value: W2GJSON
}

extension W2GJSON {
  static func text(_ value: String) -> W2GJSON { .string(Array(value.utf16)) }

  /// JS "binary string": one char per byte.
  static func binary(_ bytes: [UInt8]) -> W2GJSON { .string(bytes.map { UInt16($0) }) }

  static func int(_ value: Int) -> W2GJSON { .number(Double(value)) }

  /// Object from ordered pairs; nil values are skipped (like `undefined` in JSON.stringify).
  static func dict(_ pairs: [(String, W2GJSON?)]) -> W2GJSON {
    var members: [W2GJSONMember] = []
    for (key, value) in pairs {
      if let value { members.append(W2GJSONMember(key: key, value: value)) }
    }
    return .object(members)
  }

  subscript(key: String) -> W2GJSON? {
    guard case .object(let members) = self else { return nil }
    return members.last(where: { $0.key == key })?.value
  }

  var stringValue: String? {
    guard case .string(let units) = self else { return nil }
    return String(decoding: units, as: UTF16.self)
  }

  var utf16Value: [UInt16]? {
    guard case .string(let units) = self else { return nil }
    return units
  }

  /// Bytes of a JS binary string (nil when a char is above U+00FF).
  var binaryValue: [UInt8]? {
    guard case .string(let units) = self else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(units.count)
    for unit in units {
      guard unit <= 0xFF else { return nil }
      bytes.append(UInt8(unit))
    }
    return bytes
  }

  var doubleValue: Double? {
    guard case .number(let value) = self, value.isFinite else { return nil }
    return value
  }

  var intValue: Int? {
    guard let value = doubleValue, abs(value) < 9.0e15 else { return nil }
    return Int(value.rounded(.towardZero))
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var arrayValue: [W2GJSON]? {
    guard case .array(let items) = self else { return nil }
    return items
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  var isObject: Bool {
    if case .object = self { return true }
    return false
  }

  /// JavaScript truthiness (`if (value)`).
  var isTruthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .number(let value): return value != 0 && !value.isNaN
    case .string(let units): return !units.isEmpty
    case .array, .object: return true
    }
  }

  /// `${value}` in a JS template literal (used by mediaKey()).
  static func jsTemplateString(_ value: W2GJSON?) -> String {
    guard let value else { return "undefined" }
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .number(let number): return jsNumberString(number)
    case .string(let units): return String(decoding: units, as: UTF16.self)
    case .array(let items):
      return items.map { item -> String in
        if item.isNull { return "" }
        return jsTemplateString(item)
      }.joined(separator: ",")
    case .object: return "[object Object]"
    }
  }

  /// Number#toString for the values that matter here (integers and plain decimals).
  static func jsNumberString(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
    if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
    return "\(number)"
  }
}

// MARK: - Writer (JSON.stringify)

enum W2GJSONWriter {
  static func string(_ value: W2GJSON) -> String {
    var out: [UInt16] = []
    write(value, into: &out)
    return String(decoding: out, as: UTF16.self)
  }

  private static func appendASCII(_ text: String, _ out: inout [UInt16]) {
    out.append(contentsOf: text.utf16)
  }

  private static func write(_ value: W2GJSON, into out: inout [UInt16]) {
    switch value {
    case .null:
      appendASCII("null", &out)
    case .bool(let flag):
      appendASCII(flag ? "true" : "false", &out)
    case .number(let number):
      if number.isFinite {
        appendASCII(W2GJSON.jsNumberString(number), &out)
      } else {
        appendASCII("null", &out) // JSON.stringify(NaN) === 'null'
      }
    case .string(let units):
      writeString(units, &out)
    case .array(let items):
      out.append(0x5B) // [
      for (index, item) in items.enumerated() {
        if index > 0 { out.append(0x2C) }
        write(item, into: &out)
      }
      out.append(0x5D) // ]
    case .object(let members):
      out.append(0x7B) // {
      for (index, member) in members.enumerated() {
        if index > 0 { out.append(0x2C) }
        writeString(Array(member.key.utf16), &out)
        out.append(0x3A) // :
        write(member.value, into: &out)
      }
      out.append(0x7D) // }
    }
  }

  private static let hexDigits: [UInt16] = Array("0123456789abcdef".utf16)

  private static func writeEscape(_ unit: UInt16, _ out: inout [UInt16]) {
    out.append(0x5C) // \
    out.append(0x75) // u
    out.append(hexDigits[Int((unit >> 12) & 0xF)])
    out.append(hexDigits[Int((unit >> 8) & 0xF)])
    out.append(hexDigits[Int((unit >> 4) & 0xF)])
    out.append(hexDigits[Int(unit & 0xF)])
  }

  private static func writeString(_ units: [UInt16], _ out: inout [UInt16]) {
    out.append(0x22)
    var index = 0
    while index < units.count {
      let unit = units[index]
      switch unit {
      case 0x22: out.append(0x5C); out.append(0x22)
      case 0x5C: out.append(0x5C); out.append(0x5C)
      case 0x08: out.append(0x5C); out.append(0x62)
      case 0x0C: out.append(0x5C); out.append(0x66)
      case 0x0A: out.append(0x5C); out.append(0x6E)
      case 0x0D: out.append(0x5C); out.append(0x72)
      case 0x09: out.append(0x5C); out.append(0x74)
      case 0x00..<0x20:
        writeEscape(unit, &out)
      case 0xD800...0xDBFF:
        // Keep valid surrogate pairs, escape lone ones (well-formed JSON.stringify).
        if index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) {
          out.append(unit)
          out.append(units[index + 1])
          index += 1
        } else {
          writeEscape(unit, &out)
        }
      case 0xDC00...0xDFFF:
        writeEscape(unit, &out)
      default:
        out.append(unit)
      }
      index += 1
    }
    out.append(0x22)
  }
}

// MARK: - Parser (JSON.parse)

struct W2GJSONParser {
  private let bytes: [UInt8]
  private var position = 0
  private var depth = 0
  private static let maxDepth = 64

  private init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// Parses a complete JSON document; nil when malformed.
  static func parse(_ text: String) -> W2GJSON? {
    var parser = W2GJSONParser(bytes: Array(text.utf8))
    guard let value = parser.parseValue() else { return nil }
    parser.skipWhitespace()
    return parser.position == parser.bytes.count ? value : nil
  }

  private mutating func skipWhitespace() {
    while position < bytes.count {
      let byte = bytes[position]
      if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
        position += 1
      } else {
        return
      }
    }
  }

  private mutating func parseValue() -> W2GJSON? {
    skipWhitespace()
    guard position < bytes.count else { return nil }
    switch bytes[position] {
    case 0x7B: return parseObject()
    case 0x5B: return parseArray()
    case 0x22:
      guard let units = parseString() else { return nil }
      return .string(units)
    case 0x74: return parseLiteral("true", .bool(true))
    case 0x66: return parseLiteral("false", .bool(false))
    case 0x6E: return parseLiteral("null", .null)
    default: return parseNumber()
    }
  }

  private mutating func parseLiteral(_ word: String, _ value: W2GJSON) -> W2GJSON? {
    let expected = Array(word.utf8)
    guard position + expected.count <= bytes.count else { return nil }
    for (offset, byte) in expected.enumerated() where bytes[position + offset] != byte {
      return nil
    }
    position += expected.count
    return value
  }

  private mutating func parseNumber() -> W2GJSON? {
    let start = position
    while position < bytes.count {
      let byte = bytes[position]
      let isNumberChar = (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B
        || byte == 0x2E || byte == 0x65 || byte == 0x45
      if !isNumberChar { break }
      position += 1
    }
    guard position > start else { return nil }
    let text = String(decoding: bytes[start..<position], as: UTF8.self)
    guard let value = Double(text), value.isFinite else { return nil }
    return .number(value)
  }

  private func hex4(at offset: Int) -> UInt16? {
    var value: UInt16 = 0
    for index in offset..<(offset + 4) {
      let byte = bytes[index]
      let digit: UInt16
      switch byte {
      case 0x30...0x39: digit = UInt16(byte - 0x30)
      case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
      case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
      default: return nil
      }
      value = (value << 4) | digit
    }
    return value
  }

  private func appendRun(from start: Int, to end: Int, into units: inout [UInt16]) {
    guard end > start else { return }
    units.append(contentsOf: String(decoding: bytes[start..<end], as: UTF8.self).utf16)
  }

  private mutating func parseString() -> [UInt16]? {
    guard position < bytes.count, bytes[position] == 0x22 else { return nil }
    position += 1
    var units: [UInt16] = []
    var runStart = position
    while position < bytes.count {
      let byte = bytes[position]
      if byte == 0x22 {
        appendRun(from: runStart, to: position, into: &units)
        position += 1
        return units
      }
      if byte == 0x5C {
        appendRun(from: runStart, to: position, into: &units)
        position += 1
        guard position < bytes.count else { return nil }
        switch bytes[position] {
        case 0x22: units.append(0x22)
        case 0x5C: units.append(0x5C)
        case 0x2F: units.append(0x2F)
        case 0x62: units.append(0x08)
        case 0x66: units.append(0x0C)
        case 0x6E: units.append(0x0A)
        case 0x72: units.append(0x0D)
        case 0x74: units.append(0x09)
        case 0x75:
          guard position + 4 < bytes.count, let unit = hex4(at: position + 1) else { return nil }
          units.append(unit)
          position += 4
        default:
          return nil
        }
        position += 1
        runStart = position
        continue
      }
      if byte < 0x20 { return nil } // raw control characters are invalid JSON
      position += 1
    }
    return nil
  }

  private mutating func parseArray() -> W2GJSON? {
    depth += 1
    defer { depth -= 1 }
    guard depth <= Self.maxDepth else { return nil }
    position += 1 // [
    var items: [W2GJSON] = []
    skipWhitespace()
    if position < bytes.count, bytes[position] == 0x5D {
      position += 1
      return .array(items)
    }
    while true {
      guard let item = parseValue() else { return nil }
      items.append(item)
      skipWhitespace()
      guard position < bytes.count else { return nil }
      if bytes[position] == 0x2C {
        position += 1
        continue
      }
      if bytes[position] == 0x5D {
        position += 1
        return .array(items)
      }
      return nil
    }
  }

  private mutating func parseObject() -> W2GJSON? {
    depth += 1
    defer { depth -= 1 }
    guard depth <= Self.maxDepth else { return nil }
    position += 1 // {
    var members: [W2GJSONMember] = []
    skipWhitespace()
    if position < bytes.count, bytes[position] == 0x7D {
      position += 1
      return .object(members)
    }
    while true {
      skipWhitespace()
      guard let keyUnits = parseString() else { return nil }
      skipWhitespace()
      guard position < bytes.count, bytes[position] == 0x3A else { return nil }
      position += 1
      guard let value = parseValue() else { return nil }
      members.append(W2GJSONMember(key: String(decoding: keyUnits, as: UTF16.self), value: value))
      skipWhitespace()
      guard position < bytes.count else { return nil }
      if bytes[position] == 0x2C {
        position += 1
        continue
      }
      if bytes[position] == 0x7D {
        position += 1
        return .object(members)
      }
      return nil
    }
  }
}

// MARK: - Hex / random helpers (uint8-util arr2hex / randomBytes, util.js generateRandomHexCode)

enum W2GHex {
  private static let alphabet = Array("0123456789abcdef")

  static func encode(_ bytes: [UInt8]) -> String {
    var chars: [Character] = []
    chars.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      chars.append(alphabet[Int(byte >> 4)])
      chars.append(alphabet[Int(byte & 0x0F)])
    }
    return String(chars)
  }

  static func randomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
  }

  /// generateRandomHexCode(len): lowercase hex string (lobby codes, anonymous user ids).
  static func randomCode(_ length: Int) -> String {
    String((0..<length).map { _ in alphabet[Int.random(in: 0..<16)] })
  }
}

// MARK: - Main-thread helpers

/// Runs `body` on the main actor, in FIFO order with every other hop (WebRTC and URLSession
/// call their delegates/completions on background threads).
func w2gOnMain(_ body: @escaping @MainActor () -> Void) {
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      body()
    }
  }
}

/// setTimeout equivalent on the main actor; cancel the returned task to clear it.
@discardableResult
func w2gAfter(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
  Task { @MainActor in
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    if Task.isCancelled { return }
    body()
  }
}
