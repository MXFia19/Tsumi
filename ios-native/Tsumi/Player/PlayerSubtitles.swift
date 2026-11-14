import Foundation
import UniformTypeIdentifiers

// External subtitles (common/modules/subtitles.js). The Svelte app converts everything to ASS and renders it
// with JASSUB (libass). Natively, every format is parsed to plain cues drawn by PlayerSubtitleOverlay:
// WebVTT and SRT tags are stripped (italics kept), ASS/SSA override tags are stripped, vector drawings and
// positioned typesetting signs are dropped, \an7-9 / top styles are drawn at the top.

struct PlayerSubtitleCue: Identifiable, Hashable, Sendable {
  let id: Int
  let start: Double
  let end: Double
  let text: String
  let isTop: Bool
  let italic: Bool
}

/// A subtitle file loaded by the player (extension URL, Files import or clipboard).
struct PlayerExternalSubtitleTrack: Identifiable, Hashable {
  let id: Int
  let name: String
  /// Sorted by start time.
  let cues: [PlayerSubtitleCue]

  /// Cues visible at `time` (seconds, subtitle offset already applied).
  func activeCues(at time: Double) -> [PlayerSubtitleCue] {
    guard !cues.isEmpty, time.isFinite else { return [] }
    var low = 0
    var high = cues.count
    while low < high {
      let mid = (low + high) / 2
      if cues[mid].start <= time {
        low = mid + 1
      } else {
        high = mid
      }
    }
    var result: [PlayerSubtitleCue] = []
    var index = low - 1
    let lowerBound = max(0, low - 400)
    while index >= lowerBound {
      let cue = cues[index]
      if cue.end > time { result.append(cue) }
      index -= 1
    }
    return result.reversed()
  }
}

enum PlayerSubtitleParser {
  /// Same extensions as the Svelte file input (.srt,.vtt,.ass,.ssa,.sub,.txt).
  static var importTypes: [UTType] {
    var types: [UTType] = []
    for fileExtension in ["srt", "vtt", "ass", "ssa", "sub", "txt"] {
      if let type = UTType(filenameExtension: fileExtension) { types.append(type) }
    }
    types.append(.plainText)
    types.append(.data)
    return types
  }

  static func parse(data: Data, fileExtension: String) -> [PlayerSubtitleCue] {
    guard let text = decode(data) else { return [] }
    return parse(text: text, fileExtension: fileExtension)
  }

  static func decode(_ data: Data) -> String? {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16)
    }
    if let text = String(data: data, encoding: .utf8) { return text }
    return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
  }

  /// Parses subtitle text. `fileExtension` picks the format; unknown extensions are detected from the content
  /// ("subbers have a tendency to not set the extensions properly", convertSubText).
  static func parse(text raw: String, fileExtension: String) -> [PlayerSubtitleCue] {
    var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if let first = text.unicodeScalars.first, first.value == 0xFEFF {
      text.removeFirst()
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var cues: [PlayerSubtitleCue]
    switch fileExtension.lowercased() {
    case "ass", "ssa":
      cues = parseASS(text)
    case "srt", "vtt":
      cues = parseTimed(text)
    case "sub":
      cues = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? parseMicroDVD(text) : parseTimed(text)
    default:
      if trimmed.contains("[Script Info]") || trimmed.contains("[Events]") {
        cues = parseASS(text)
      } else if trimmed.contains("-->") {
        cues = parseTimed(text)
      } else if trimmed.hasPrefix("{") {
        cues = parseMicroDVD(text)
      } else {
        cues = []
      }
    }
    if cues.isEmpty {
      // Wrong extension: try the other formats.
      if trimmed.contains("-->") {
        cues = parseTimed(text)
      } else if trimmed.contains("[Events]") {
        cues = parseASS(text)
      }
    }
    let sorted = cues.sorted { $0.start < $1.start }
    return sorted.enumerated().map { index, cue in
      PlayerSubtitleCue(id: index, start: cue.start, end: cue.end, text: cue.text, isTop: cue.isTop, italic: cue.italic)
    }
  }

  // MARK: - SRT / WebVTT

  private static func parseTimed(_ text: String) -> [PlayerSubtitleCue] {
    let lines = text.components(separatedBy: "\n")
    var cues: [PlayerSubtitleCue] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      guard let arrow = line.range(of: "-->") else {
        index += 1
        continue
      }
      let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
      let startToken = line[..<arrow.lowerBound].split(whereSeparator: isBlank).last.map(String.init) ?? ""
      let after = line[arrow.upperBound...].split(whereSeparator: isBlank)
      let endToken = after.first.map(String.init) ?? ""
      let settings = after.dropFirst().joined(separator: " ")
      index += 1
      var body: [String] = []
      while index < lines.count {
        let next = lines[index]
        if next.trimmingCharacters(in: .whitespaces).isEmpty || next.contains("-->") { break }
        body.append(next)
        index += 1
      }
      guard let start = parseTimestamp(startToken), let end = parseTimestamp(endToken), end > start else { continue }
      let cleaned = cleanMarkup(body.joined(separator: "\n"))
      guard !cleaned.text.isEmpty else { continue }
      cues.append(PlayerSubtitleCue(
        id: cues.count,
        start: start,
        end: end,
        text: cleaned.text,
        isTop: cleaned.isTop || vttIsTop(settings),
        italic: cleaned.italic
      ))
    }
    return cues
  }

  /// "hh:mm:ss,mmm", "hh:mm:ss.mmm", "mm:ss.mmm" or ASS "h:mm:ss.cc".
  static func parseTimestamp(_ token: String) -> Double? {
    let cleaned = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let components = cleaned.split(separator: ":")
    guard components.count == 2 || components.count == 3 else { return nil }
    var total = 0.0
    for component in components {
      guard let value = Double(component), value.isFinite, value >= 0 else { return nil }
      total = total * 60 + value
    }
    return total
  }

  /// WebVTT "line:" cue setting placing the cue near the top of the frame.
  private static func vttIsTop(_ settings: String) -> Bool {
    for token in settings.split(separator: " ") where token.hasPrefix("line:") {
      let value = token.dropFirst(5).split(separator: ",").first.map(String.init) ?? ""
      if value.hasSuffix("%") {
        if let percent = Double(value.dropLast()) { return percent < 50 }
      } else if let lineNumber = Int(value) {
        return lineNumber >= 0 && lineNumber < 6
      }
    }
    return false
  }

  private static func cleanMarkup(_ raw: String) -> (text: String, isTop: Bool, italic: Bool) {
    let lower = raw.lowercased()
    let isTop = lower.contains("{\\an7}") || lower.contains("{\\an8}") || lower.contains("{\\an9}")
    let italic = lower.hasPrefix("<i>") || lower.hasPrefix("{\\i1}")
    var text = stripBlocks(raw, open: "<", close: ">")
    text = stripBlocks(text, open: "{", close: "}")
    text = decodeEntities(text)
    let lines = text.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return (lines.joined(separator: "\n"), isTop, italic)
  }

  // MARK: - ASS / SSA

  private static func parseASS(_ text: String) -> [PlayerSubtitleCue] {
    var section = ""
    var eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
    var styleFields: [String] = []
    var topStyles = Set<String>()
    var italicStyles = Set<String>()
    var seen = Set<String>()
    var cues: [PlayerSubtitleCue] = []

    for rawLine in text.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix(";") else { continue }
      let lower = line.lowercased()
      if line.hasPrefix("[") && line.hasSuffix("]") {
        section = lower
        continue
      }
      if section.contains("styles") {
        if lower.hasPrefix("format:") {
          styleFields = fieldList(line)
        } else if lower.hasPrefix("style:") {
          let values = splitFields(value(after: line), count: max(styleFields.count, 1))
          guard let nameIndex = styleFields.firstIndex(of: "name"), nameIndex < values.count else { continue }
          let name = values[nameIndex].lowercased()
          if let alignIndex = styleFields.firstIndex(of: "alignment"), alignIndex < values.count,
             let alignment = Int(values[alignIndex]) {
            // SSA ([V4 Styles]) uses legacy alignment values: 5-7 are the top row.
            let legacy = !section.contains("+")
            let top = legacy ? (5...7).contains(alignment) : (7...9).contains(alignment)
            if top { topStyles.insert(name) }
          }
          if let italicIndex = styleFields.firstIndex(of: "italic"), italicIndex < values.count,
             values[italicIndex] != "0" {
            italicStyles.insert(name)
          }
        }
      } else if section == "[events]" {
        if lower.hasPrefix("format:") {
          eventFields = fieldList(line)
        } else if lower.hasPrefix("dialogue:") {
          let values = splitFields(value(after: line), count: eventFields.count)
          let field: (String) -> String? = { key in
            guard let position = eventFields.firstIndex(of: key), position < values.count else { return nil }
            return values[position]
          }
          guard let startText = field("start"), let endText = field("end"), let rawText = field("text"),
                let start = parseTimestamp(startText), let end = parseTimestamp(endText), end > start else { continue }
          let style = (field("style") ?? "").lowercased()
          let overrides = overrideBlocks(rawText)
          if containsDrawing(overrides) { continue }
          let positioned = overrides.contains("\\pos(") || overrides.contains("\\move(")
            || overrides.contains("\\clip(") || overrides.contains("\\org(")
          if positioned && !isDialogueStyle(style) { continue }
          let isTop = topStyles.contains(style) || overrides.contains("\\an7") || overrides.contains("\\an8")
            || overrides.contains("\\an9") || overrides.contains("\\a5") || overrides.contains("\\a6")
            || overrides.contains("\\a7")
          let italic = italicStyles.contains(style) || overrides.contains("\\i1")
          var body = stripBlocks(rawText, open: "{", close: "}")
          body = body.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
          let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          guard !lines.isEmpty else { continue }
          let joined = lines.joined(separator: "\n")
          let key = "\(start)|\(end)|\(joined)"
          guard !seen.contains(key) else { continue }
          seen.insert(key)
          cues.append(PlayerSubtitleCue(id: cues.count, start: start, end: end, text: joined, isTop: isTop, italic: italic))
        }
      }
    }
    return cues
  }

  private static func value(after line: String) -> String {
    guard let colon = line.firstIndex(of: ":") else { return "" }
    return String(line[line.index(after: colon)...])
  }

  private static func fieldList(_ line: String) -> [String] {
    value(after: line).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
  }

  /// Splits on commas into at most `count` fields: the last one (Text) keeps its commas.
  private static func splitFields(_ text: String, count: Int) -> [String] {
    var result: [String] = []
    var current = ""
    for character in text {
      if character == ",", result.count < count - 1 {
        result.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    result.append(current)
    return result.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// Content of every {...} override block, lowercased.
  private static func overrideBlocks(_ text: String) -> String {
    var result = ""
    var inside = false
    for character in text {
      if character == "{" {
        inside = true
        continue
      }
      if character == "}" {
        inside = false
        result.append(" ")
        continue
      }
      if inside { result.append(character) }
    }
    return result.lowercased()
  }

  /// \p1...\p9 switch ASS into vector drawing mode: the "text" is a path, not dialogue.
  private static func containsDrawing(_ overrides: String) -> Bool {
    for digit in 1...9 where overrides.contains("\\p\(digit)") {
      return true
    }
    return false
  }

  private static func isDialogueStyle(_ style: String) -> Bool {
    let markers = ["default", "main", "dialog", "italic", "flashback", "top", "alt", "narrat", "thought", "overlap"]
    return markers.contains { style.contains($0) }
  }

  // MARK: - MicroDVD (.sub)

  private static func parseMicroDVD(_ text: String) -> [PlayerSubtitleCue] {
    var frameMilliseconds = 41.708
    var cues: [PlayerSubtitleCue] = []
    var isFirst = true
    for line in text.components(separatedBy: "\n") {
      guard let parsed = parseMicroLine(line) else { continue }
      if isFirst {
        isFirst = false
        // "{1}{1}23.976": the first line gives the frame rate.
        if let fps = Double(parsed.text.trimmingCharacters(in: .whitespaces)), fps > 0, fps.isFinite {
          frameMilliseconds = 1000 / fps
          continue
        }
      }
      let start = Double(parsed.start) * frameMilliseconds / 1000
      let end = Double(parsed.end) * frameMilliseconds / 1000
      guard end > start else { continue }
      var body = stripBlocks(parsed.text, open: "{", close: "}")
      let italic = body.hasPrefix("/")
      body = body.replacingOccurrences(of: "|", with: "\n")
      let lines = body.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " /")) }
        .filter { !$0.isEmpty }
      guard !lines.isEmpty else { continue }
      cues.append(PlayerSubtitleCue(
        id: cues.count,
        start: start,
        end: end,
        text: lines.joined(separator: "\n"),
        isTop: false,
        italic: italic
      ))
    }
    return cues
  }

  private static func parseMicroLine(_ line: String) -> (start: Int, end: Int, text: String)? {
    var rest = Substring(line.trimmingCharacters(in: .whitespaces))
    func readNumber() -> Int? {
      guard let open = rest.first, open == "{" || open == "[" else { return nil }
      rest = rest.dropFirst()
      let digits = rest.prefix { ("0"..."9").contains($0) }
      guard !digits.isEmpty, let number = Int(digits) else { return nil }
      rest = rest.dropFirst(digits.count)
      guard let close = rest.first, close == "}" || close == "]" else { return nil }
      rest = rest.dropFirst()
      return number
    }
    guard let start = readNumber(), let end = readNumber() else { return nil }
    return (start, end, String(rest))
  }

  // MARK: - Helpers

  /// Removes `open...close` blocks that stay on one line (HTML tags, ASS overrides).
  static func stripBlocks(_ text: String, open: Character, close: Character) -> String {
    var output = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == open,
         let closeIndex = text[index...].firstIndex(of: close),
         !text[index..<closeIndex].contains("\n") {
        index = text.index(after: closeIndex)
        continue
      }
      output.append(character)
      index = text.index(after: index)
    }
    return output
  }

  private static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = text
    let entities: [(String, String)] = [
      ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
      ("&apos;", "'"), ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&")
    ]
    for (entity, replacement) in entities {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
  }
}
