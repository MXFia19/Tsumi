import Foundation
import UniformTypeIdentifiers

// External subtitles (common/modules/subtitles.js). The Svelte app converts everything to ASS and renders it
// with JASSUB (libass). libass is not available natively:
// - WebVTT, SRT and MicroDVD are parsed to plain cues drawn by PlayerSubtitleOverlay (tags stripped, italics
//   kept, `line:` / {\an8} → top).
// - ASS/SSA keep their typesetting in `PlayerASSLayout` (styles of [V4+ Styles] / [V4 Styles], \pos, \move,
//   \an, \a, colours, \b \i \u \s, \fn \fs, \bord \shad, \fad / \fade, \frz, \fscx / \fscy, \r) and are drawn by
//   PlayerASSOverlay, scaled from PlayResX / PlayResY to the video rect. Vector drawings (\p1) are dropped;
//   \t animations, \clip, karaoke timing, blur and \org are ignored.

struct PlayerSubtitleCue: Identifiable, Hashable, Sendable {
  let id: Int
  let start: Double
  let end: Double
  /// Plain text (every run joined), used by the plain overlay and as a fallback.
  let text: String
  let isTop: Bool
  let italic: Bool
  /// ASS/SSA layout and styling; nil for plain cues (SRT, WebVTT, MicroDVD).
  var ass: PlayerASSLayout? = nil
}

/// RGBA colour of an ASS style or override tag (stored as &HAABBGGRR; ASS alpha 00 = opaque).
struct PlayerASSColor: Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  /// 1 = opaque (ASS alpha 00), 0 = transparent (ASS alpha FF).
  var opacity: Double

  static let white = PlayerASSColor(red: 1, green: 1, blue: 1, opacity: 1)
  static let black = PlayerASSColor(red: 0, green: 0, blue: 0, opacity: 1)

  init(red: Double, green: Double, blue: Double, opacity: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  /// &HAABBGGRR value.
  init(value: UInt32) {
    red = Double(value & 0xFF) / 255
    green = Double((value >> 8) & 0xFF) / 255
    blue = Double((value >> 16) & 0xFF) / 255
    opacity = 1 - Double((value >> 24) & 0xFF) / 255
  }

  /// "&H00FFFFFF", "&HFFFFFF&", "H0000FF" or a decimal number (SSA styles).
  static func parse(_ raw: String) -> PlayerASSColor? {
    guard let value = number(raw) else { return nil }
    return PlayerASSColor(value: value)
  }

  /// Same colour with the RGB of `other` (\c keeps the current alpha).
  func withRGB(of other: PlayerASSColor) -> PlayerASSColor {
    PlayerASSColor(red: other.red, green: other.green, blue: other.blue, opacity: opacity)
  }

  /// Same colour with an ASS alpha byte (\alpha, \1a, \3a, \4a).
  func withAlpha(_ alpha: UInt32) -> PlayerASSColor {
    PlayerASSColor(red: red, green: green, blue: blue, opacity: 1 - Double(alpha & 0xFF) / 255)
  }

  /// Hexadecimal (&H / H prefix) or decimal value of a colour or alpha field.
  static func number(_ raw: String) -> UInt32? {
    let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "&() \t"))
    if let first = text.first, first == "H" || first == "h" {
      let hex = text.dropFirst().prefix { $0.isHexDigit }
      guard !hex.isEmpty else { return nil }
      return UInt32(String(hex.suffix(8)), radix: 16)
    }
    if let decimal = Int64(text) { return UInt32(truncatingIfNeeded: decimal) }
    let hex = text.prefix { $0.isHexDigit }
    guard !hex.isEmpty else { return nil }
    return UInt32(String(hex.suffix(8)), radix: 16)
  }
}

/// Point in script coordinates (PlayResX × PlayResY).
struct PlayerASSPoint: Hashable, Sendable {
  var x: Double
  var y: Double
}

/// \fade(a1,a2,a3,t1,t2,t3,t4): alpha a1 before t1, a1→a2 until t2, a2 until t3, a2→a3 until t4, then a3.
/// Times in milliseconds from the cue start, alphas 0 (opaque) to 255 (transparent). \fad(in,out) is
/// stored as (255, 0, 255, 0, in, duration - out, duration).
struct PlayerASSFade: Hashable, Sendable {
  var a1: Double
  var a2: Double
  var a3: Double
  var t1: Double
  var t2: Double
  var t3: Double
  var t4: Double

  /// Opacity (0...1) `elapsed` ms after the cue start.
  func opacity(at elapsed: Double) -> Double {
    let alpha: Double
    if elapsed < t1 {
      alpha = a1
    } else if elapsed < t2 {
      alpha = t2 > t1 ? a1 + (a2 - a1) * (elapsed - t1) / (t2 - t1) : a2
    } else if elapsed < t3 {
      alpha = a2
    } else if elapsed < t4 {
      alpha = t4 > t3 ? a2 + (a3 - a2) * (elapsed - t3) / (t4 - t3) : a3
    } else {
      alpha = a3
    }
    return min(max(1 - alpha / 255, 0), 1)
  }
}

/// A piece of text with one set of character styles.
struct PlayerASSRun: Hashable, Sendable {
  var text: String
  var fontName: String
  /// Script units (scaled by the video height / PlayResY).
  var fontSize: Double
  var bold: Bool
  var italic: Bool
  var underline: Bool
  var strikeout: Bool
  var primary: PlayerASSColor
}

/// Layout of one ASS/SSA dialogue line.
struct PlayerASSLayout: Hashable, Sendable {
  var playResX: Double
  var playResY: Double
  var layer: Int
  /// Numpad alignment 1...9 (\an): 1-3 bottom, 4-6 middle, 7-9 top; 1/4/7 left, 2/5/8 centre, 3/6/9 right.
  var alignment: Int
  var marginL: Double
  var marginR: Double
  var marginV: Double
  /// \pos(x,y), or the start point of \move.
  var position: PlayerASSPoint?
  /// \move end point and its window in ms from the cue start (both 0 = the whole cue).
  var moveTo: PlayerASSPoint?
  var moveStart: Double = 0
  var moveEnd: Double = 0
  var fade: PlayerASSFade?
  /// Outline width and shadow depth, script units.
  var outline: Double
  var shadow: Double
  /// 1 = outline + drop shadow, 3 = opaque box.
  var borderStyle: Int
  var outlineColor: PlayerASSColor
  var backColor: PlayerASSColor
  /// \fscx / \fscy in percent.
  var scaleX: Double = 100
  var scaleY: Double = 100
  /// \frz in degrees, counter-clockwise.
  var rotation: Double = 0
  var runs: [PlayerASSRun]

  /// Needs the playback clock while shown (fade or move).
  var isAnimated: Bool { fade != nil || moveTo != nil }

  var isTop: Bool { alignment >= 7 }
  var isMiddle: Bool { (4...6).contains(alignment) }
  /// 0 = left, 0.5 = centre, 1 = right.
  var horizontalFraction: Double {
    switch alignment % 3 {
    case 1: return 0
    case 0: return 1
    default: return 0.5
    }
  }
  /// 0 = top, 0.5 = middle, 1 = bottom.
  var verticalFraction: Double {
    if isTop { return 0 }
    if isMiddle { return 0.5 }
    return 1
  }

  /// Anchor in script coordinates `elapsed` ms after the cue start (\pos / \move, else the margins).
  func anchor(elapsed: Double, duration: Double) -> PlayerASSPoint {
    if let start = position {
      guard let end = moveTo else { return start }
      var t1 = moveStart
      var t2 = moveEnd
      if t1 == 0 && t2 == 0 { t2 = duration }
      if t2 < t1 { swap(&t1, &t2) }
      let progress = t2 > t1 ? min(max((elapsed - t1) / (t2 - t1), 0), 1) : (elapsed >= t2 ? 1 : 0)
      return PlayerASSPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }
    let x: Double
    switch alignment % 3 {
    case 1: x = marginL
    case 0: x = playResX - marginR
    default: x = (marginL + playResX - marginR) / 2
    }
    let y: Double
    if isTop {
      y = marginV
    } else if isMiddle {
      y = playResY / 2
    } else {
      y = playResY - marginV
    }
    return PlayerASSPoint(x: x, y: y)
  }

  /// Width available for wrapping, in script units.
  var wrapWidth: Double {
    max(playResX - marginL - marginR, playResX * 0.2)
  }

  /// Opacity from the fade `elapsed` ms after the cue start.
  func opacity(elapsed: Double) -> Double {
    fade?.opacity(at: elapsed) ?? 1
  }
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
  /// Int of a number read from a subtitle file without trapping: `Int(Double)` crashes the app on a value outside
  /// the Int range (a hostile `\an99999999999999999999` or a 1e300 style field), so the value is clamped first to
  /// ±1,000,000, far beyond any real alignment, border style or margin. NaN gives 0.
  static func safeInt(_ value: Double) -> Int {
    guard !value.isNaN else { return 0 }
    return Int(min(max(value, -1_000_000), 1_000_000))
  }

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
    let sorted = cues.enumerated().sorted { lhs, rhs in
      if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
      return lhs.offset < rhs.offset
    }.map { $0.element }
    return sorted.enumerated().map { index, cue in
      PlayerSubtitleCue(id: index, start: cue.start, end: cue.end, text: cue.text, isTop: cue.isTop, italic: cue.italic, ass: cue.ass)
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

  /// Style line of [V4+ Styles] / [V4 Styles] (libass defaults for missing fields).
  private struct ASSStyle {
    var fontName = "Arial"
    var fontSize: Double = 20
    var primary = PlayerASSColor.white
    var outlineColor = PlayerASSColor.black
    var backColor = PlayerASSColor.black
    var bold = false
    var italic = false
    var underline = false
    var strikeout = false
    var scaleX: Double = 100
    var scaleY: Double = 100
    var angle: Double = 0
    var borderStyle = 1
    var outline: Double = 2
    var shadow: Double = 2
    var alignment = 2
    var marginL: Double = 10
    var marginR: Double = 10
    var marginV: Double = 10
  }

  /// Character styles while reading a dialogue text (changed by override tags, one run per change).
  private struct ASSRunState {
    var fontName: String
    var fontSize: Double
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikeout: Bool
    var primary: PlayerASSColor

    init(_ style: ASSStyle) {
      fontName = style.fontName
      fontSize = style.fontSize
      bold = style.bold
      italic = style.italic
      underline = style.underline
      strikeout = style.strikeout
      primary = style.primary
    }

    func makeRun(_ text: String) -> PlayerASSRun {
      PlayerASSRun(
        text: text,
        fontName: fontName,
        fontSize: fontSize,
        bold: bold,
        italic: italic,
        underline: underline,
        strikeout: strikeout,
        primary: primary
      )
    }
  }

  /// Line-wide values of a dialogue (the last tag wins, except \an / \a / \pos / \move where the first wins).
  private struct ASSLineState {
    var alignment: Int?
    var position: PlayerASSPoint?
    var moveTo: PlayerASSPoint?
    var moveStart: Double = 0
    var moveEnd: Double = 0
    var positionSet = false
    var fade: PlayerASSFade?
    var outline: Double
    var shadow: Double
    var outlineColor: PlayerASSColor
    var backColor: PlayerASSColor
    var scaleX: Double
    var scaleY: Double
    var rotation: Double
    var drawing = false

    init(_ style: ASSStyle) {
      outline = style.outline
      shadow = style.shadow
      outlineColor = style.outlineColor
      backColor = style.backColor
      scaleX = style.scaleX
      scaleY = style.scaleY
      rotation = style.angle
    }

    /// \r: back to a style's values.
    mutating func reset(to style: ASSStyle) {
      outline = style.outline
      shadow = style.shadow
      outlineColor = style.outlineColor
      backColor = style.backColor
      scaleX = style.scaleX
      scaleY = style.scaleY
      rotation = style.angle
    }
  }

  private static let defaultStyleFields = [
    "name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
    "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
    "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding"
  ]

  private static let defaultLegacyStyleFields = [
    "name", "fontname", "fontsize", "primarycolour", "secondarycolour", "tertiarycolour", "backcolour",
    "bold", "italic", "borderstyle", "outline", "shadow", "alignment", "marginl", "marginr", "marginv",
    "alphalevel", "encoding"
  ]

  private static func parseASS(_ text: String) -> [PlayerSubtitleCue] {
    var section = ""
    var info: [String: String] = [:]
    var styleFields: [String] = []
    var styles: [String: ASSStyle] = [:]
    var eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
    var dialogues: [[String: String]] = []

    for rawLine in text.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix(";") else { continue }
      let lower = line.lowercased()
      if line.hasPrefix("[") && line.hasSuffix("]") {
        section = lower
        continue
      }
      if section == "[script info]" {
        if let colon = line.firstIndex(of: ":") {
          let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
          info[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
      } else if section.contains("styles") {
        // SSA ([V4 Styles]) uses the legacy alignment values and TertiaryColour.
        let legacy = !section.contains("+")
        if lower.hasPrefix("format:") {
          styleFields = fieldList(line)
        } else if lower.hasPrefix("style:") {
          let fields = styleFields.isEmpty ? (legacy ? defaultLegacyStyleFields : defaultStyleFields) : styleFields
          let values = splitFields(value(after: line), count: max(fields.count, 1))
          var map: [String: String] = [:]
          for (index, key) in fields.enumerated() where index < values.count {
            map[key] = values[index]
          }
          guard let name = map["name"] else { continue }
          styles[styleKey(name)] = makeStyle(map, legacy: legacy)
        }
      } else if section == "[events]" {
        if lower.hasPrefix("format:") {
          eventFields = fieldList(line)
        } else if lower.hasPrefix("dialogue:") {
          let values = splitFields(value(after: line), count: eventFields.count)
          var map: [String: String] = [:]
          for (index, key) in eventFields.enumerated() where index < values.count {
            map[key] = values[index]
          }
          dialogues.append(map)
        }
      }
    }

    // PlayResX / PlayResY with the libass defaults when one or both are missing.
    var playResX = info["playresx"].flatMap { Double($0) } ?? 0
    var playResY = info["playresy"].flatMap { Double($0) } ?? 0
    if playResX <= 0 && playResY <= 0 {
      playResX = 384
      playResY = 288
    } else if playResY <= 0 {
      playResY = playResX == 1280 ? 1024 : playResX * 3 / 4
    } else if playResX <= 0 {
      playResX = playResY == 1024 ? 1280 : playResY * 4 / 3
    }
    let wrapStyle = info["wrapstyle"].flatMap { Int($0) } ?? 0
    let fallbackStyle = styles["default"] ?? ASSStyle()

    var cues: [PlayerSubtitleCue] = []
    var seen: [String: Int] = [:]
    for map in dialogues {
      guard let startText = map["start"], let endText = map["end"], let rawText = map["text"],
            let start = parseTimestamp(startText), let end = parseTimestamp(endText), end > start else { continue }
      let style = styles[styleKey(map["style"] ?? "Default")] ?? fallbackStyle
      let layer = Int(map["layer"] ?? "") ?? 0
      let duration = (end - start) * 1000
      let parsed = parseASSText(rawText, style: style, styles: styles, wrapStyle: wrapStyle, duration: duration)
      let runs = trimmedRuns(parsed.runs)
      let plain = plainText(runs)
      guard !plain.isEmpty else { continue }
      let line = parsed.line
      let layout = PlayerASSLayout(
        playResX: playResX,
        playResY: playResY,
        layer: layer,
        alignment: line.alignment ?? style.alignment,
        marginL: eventMargin(map["marginl"]) ?? style.marginL,
        marginR: eventMargin(map["marginr"]) ?? style.marginR,
        marginV: eventMargin(map["marginv"]) ?? style.marginV,
        position: line.position,
        moveTo: line.moveTo,
        moveStart: line.moveStart,
        moveEnd: line.moveEnd,
        fade: line.fade,
        outline: line.outline,
        shadow: line.shadow,
        borderStyle: style.borderStyle,
        outlineColor: line.outlineColor,
        backColor: line.backColor,
        scaleX: line.scaleX,
        scaleY: line.scaleY,
        rotation: line.rotation,
        runs: runs
      )
      let cue = PlayerSubtitleCue(
        id: cues.count,
        start: start,
        end: end,
        text: plain,
        isTop: layout.isTop,
        italic: runs.first?.italic ?? false,
        ass: layout
      )
      // The same line repeated on several layers (glow / border copies): keep the top layer only.
      let positionKey = layout.position.map { "\($0.x),\($0.y)" } ?? "-"
      let key = "\(start)|\(end)|\(plain)|\(layout.alignment)|\(positionKey)"
      if let existing = seen[key] {
        if (cues[existing].ass?.layer ?? 0) <= layer { cues[existing] = cue }
        continue
      }
      seen[key] = cues.count
      cues.append(cue)
    }
    return cues
  }

  private static func styleKey(_ name: String) -> String {
    var key = name.trimmingCharacters(in: .whitespaces)
    while key.hasPrefix("*") { key.removeFirst() }
    return key.lowercased()
  }

  private static func makeStyle(_ map: [String: String], legacy: Bool) -> ASSStyle {
    var style = ASSStyle()
    if let name = map["fontname"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      style.fontName = name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
    if let size = double(map["fontsize"]), size > 0 { style.fontSize = size }
    if let color = map["primarycolour"].flatMap({ PlayerASSColor.parse($0) }) { style.primary = color }
    if let color = (map["outlinecolour"] ?? map["tertiarycolour"]).flatMap({ PlayerASSColor.parse($0) }) {
      style.outlineColor = color
    }
    if let color = map["backcolour"].flatMap({ PlayerASSColor.parse($0) }) { style.backColor = color }
    style.bold = flag(map["bold"])
    style.italic = flag(map["italic"])
    style.underline = flag(map["underline"])
    style.strikeout = flag(map["strikeout"])
    if let value = double(map["scalex"]), value > 0 { style.scaleX = value }
    if let value = double(map["scaley"]), value > 0 { style.scaleY = value }
    if let value = double(map["angle"]) { style.angle = value }
    if let value = double(map["borderstyle"]) { style.borderStyle = safeInt(value) }
    if let value = double(map["outline"]), value >= 0 { style.outline = value }
    if let value = double(map["shadow"]), value >= 0 { style.shadow = value }
    if let value = double(map["alignment"]) {
      let raw = safeInt(value)
      style.alignment = legacy ? legacyAlignment(raw) : ((1...9).contains(raw) ? raw : 2)
    }
    if let value = double(map["marginl"]) { style.marginL = value }
    if let value = double(map["marginr"]) { style.marginR = value }
    if let value = double(map["marginv"]) { style.marginV = value }
    return style
  }

  /// SSA / \a alignment: 1-3 bottom, +4 top, +8 middle → numpad (\an) value.
  private static func legacyAlignment(_ value: Int) -> Int {
    let horizontal = value & 3
    guard horizontal > 0 else { return 2 }
    if value & 4 != 0 { return horizontal + 6 }
    if value & 8 != 0 { return horizontal + 3 }
    return horizontal
  }

  /// Non-zero event margins override the style margins.
  private static func eventMargin(_ text: String?) -> Double? {
    guard let value = double(text), value > 0 else { return nil }
    return value
  }

  private static func double(_ text: String?) -> Double? {
    guard let text else { return nil }
    let value = Double(text.trimmingCharacters(in: .whitespaces))
    return value.flatMap { $0.isFinite ? $0 : nil }
  }

  /// Style booleans: -1 / 1 = on, 0 = off (bold may also be a font weight).
  private static func flag(_ text: String?) -> Bool {
    guard let value = double(text) else { return false }
    return value == -1 || value == 1 || value >= 600
  }

  /// Reads the text of a dialogue: override blocks change the run / line state, \N \n \h are line breaks and
  /// hard spaces, text drawn in \p mode (vector drawings) is dropped.
  private static func parseASSText(
    _ raw: String,
    style: ASSStyle,
    styles: [String: ASSStyle],
    wrapStyle: Int,
    duration: Double
  ) -> (runs: [PlayerASSRun], line: ASSLineState) {
    var run = ASSRunState(style)
    var line = ASSLineState(style)
    var runs: [PlayerASSRun] = []
    var buffer = ""
    let characters = Array(raw)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "{", let close = characters[(index + 1)...].firstIndex(of: "}") {
        if !buffer.isEmpty {
          runs.append(run.makeRun(buffer))
          buffer = ""
        }
        let block = String(characters[(index + 1)..<close])
        for tag in tagTokens(block) {
          applyTag(tag, run: &run, line: &line, style: style, styles: styles, duration: duration)
        }
        index = close + 1
        continue
      }
      if character == "\\", index + 1 < characters.count {
        let next = characters[index + 1]
        if next == "N" || next == "n" || next == "h" {
          if !line.drawing {
            if next == "N" {
              buffer.append("\n")
            } else if next == "n" {
              buffer.append(wrapStyle == 2 ? "\n" : " ")
            } else {
              buffer.append("\u{00A0}")
            }
          }
          index += 2
          continue
        }
      }
      if !line.drawing { buffer.append(character) }
      index += 1
    }
    if !buffer.isEmpty { runs.append(run.makeRun(buffer)) }
    return (runs, line)
  }

  /// Tags of one override block, split on backslashes outside parentheses (\t(...) keeps its inner tags).
  /// Text before the first backslash is a comment.
  private static func tagTokens(_ block: String) -> [String] {
    var tokens: [String] = []
    var current: String?
    var depth = 0
    for character in block {
      if character == "(" { depth += 1 }
      if character == ")" { depth = max(depth - 1, 0) }
      if character == "\\" && depth == 0 {
        if let finished = current, !finished.isEmpty { tokens.append(finished) }
        current = ""
        continue
      }
      current?.append(character)
    }
    if let finished = current, !finished.isEmpty { tokens.append(finished) }
    return tokens
  }

  // Tag names are matched longest first ("fscx" before "fs", "bord" before "b", "clip" before "c"...).
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func applyTag(
    _ raw: String,
    run: inout ASSRunState,
    line: inout ASSLineState,
    style: ASSStyle,
    styles: [String: ASSStyle],
    duration: Double
  ) {
    let tag = raw.trimmingCharacters(in: .whitespaces)
    func argument(_ name: String) -> String? {
      guard tag.hasPrefix(name) else { return nil }
      return String(tag.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
    }
    if let value = argument("fscx") {
      line.scaleX = leadingNumber(value).map { max($0, 0) } ?? style.scaleX
    } else if let value = argument("fscy") {
      line.scaleY = leadingNumber(value).map { max($0, 0) } ?? style.scaleY
    } else if argument("fsp") != nil {
      // Letter spacing: not supported.
    } else if let value = argument("fs") {
      if let number = leadingNumber(value) {
        if value.hasPrefix("+") || value.hasPrefix("-") {
          run.fontSize = max(1, run.fontSize * (1 + number / 10))
        } else {
          run.fontSize = number > 0 ? number : style.fontSize
        }
      } else {
        run.fontSize = style.fontSize
      }
    } else if let value = argument("fn") {
      run.fontName = value.isEmpty ? style.fontName : value
    } else if let value = argument("fade") {
      let values = numbers(value)
      if values.count >= 7 {
        line.fade = PlayerASSFade(a1: values[0], a2: values[1], a3: values[2], t1: values[3], t2: values[4], t3: values[5], t4: values[6])
      }
    } else if let value = argument("fad") {
      let values = numbers(value)
      if values.count >= 2 {
        let fadeIn = max(values[0], 0)
        let fadeOut = max(values[1], 0)
        line.fade = PlayerASSFade(a1: 255, a2: 0, a3: 255, t1: 0, t2: fadeIn, t3: duration - fadeOut, t4: duration)
      }
    } else if argument("frx") != nil || argument("fry") != nil {
      // 3D rotation: not supported.
    } else if let value = argument("frz") {
      line.rotation = leadingNumber(value) ?? style.angle
    } else if let value = argument("fr") {
      line.rotation = leadingNumber(value) ?? style.angle
    } else if argument("fe") != nil {
      // Font encoding.
    } else if let value = argument("bord") {
      line.outline = max(leadingNumber(value) ?? style.outline, 0)
    } else if argument("be") != nil || argument("blur") != nil {
      // Edge blur: not supported.
    } else if let value = argument("b") {
      if let number = leadingNumber(value) {
        run.bold = number == 1 || number >= 600
      } else {
        run.bold = style.bold
      }
    } else if let value = argument("shad") {
      line.shadow = max(leadingNumber(value) ?? style.shadow, 0)
    } else if let value = argument("s") {
      run.strikeout = leadingNumber(value).map { $0 != 0 } ?? style.strikeout
    } else if let value = argument("alpha") {
      if let alpha = PlayerASSColor.number(value) {
        run.primary = run.primary.withAlpha(alpha)
        line.outlineColor = line.outlineColor.withAlpha(alpha)
        line.backColor = line.backColor.withAlpha(alpha)
      } else {
        run.primary.opacity = style.primary.opacity
        line.outlineColor.opacity = style.outlineColor.opacity
        line.backColor.opacity = style.backColor.opacity
      }
    } else if let value = argument("an") {
      if line.alignment == nil, let number = leadingNumber(value), (1...9).contains(safeInt(number)) {
        line.alignment = safeInt(number)
      }
    } else if let value = argument("a") {
      if line.alignment == nil, let number = leadingNumber(value) {
        line.alignment = legacyAlignment(safeInt(number))
      }
    } else if argument("iclip") != nil || argument("clip") != nil {
      // Clipping: not supported (the whole text is drawn).
    } else if let value = argument("1c") {
      run.primary = run.primary.withRGB(of: PlayerASSColor.parse(value) ?? style.primary)
    } else if argument("2c") != nil {
      // Secondary (karaoke) colour: karaoke is not animated.
    } else if let value = argument("3c") {
      line.outlineColor = line.outlineColor.withRGB(of: PlayerASSColor.parse(value) ?? style.outlineColor)
    } else if let value = argument("4c") {
      line.backColor = line.backColor.withRGB(of: PlayerASSColor.parse(value) ?? style.backColor)
    } else if let value = argument("1a") {
      run.primary = PlayerASSColor.number(value).map { run.primary.withAlpha($0) } ?? run.primary
    } else if argument("2a") != nil {
      // Secondary alpha.
    } else if let value = argument("3a") {
      line.outlineColor = PlayerASSColor.number(value).map { line.outlineColor.withAlpha($0) } ?? line.outlineColor
    } else if let value = argument("4a") {
      line.backColor = PlayerASSColor.number(value).map { line.backColor.withAlpha($0) } ?? line.backColor
    } else if let value = argument("c") {
      run.primary = run.primary.withRGB(of: PlayerASSColor.parse(value) ?? style.primary)
    } else if let value = argument("i") {
      run.italic = leadingNumber(value).map { $0 != 0 } ?? style.italic
    } else if let value = argument("u") {
      run.underline = leadingNumber(value).map { $0 != 0 } ?? style.underline
    } else if let value = argument("pos") {
      let values = numbers(value)
      if !line.positionSet, values.count >= 2 {
        line.position = PlayerASSPoint(x: values[0], y: values[1])
        line.positionSet = true
      }
    } else if argument("pbo") != nil {
      // Drawing baseline offset.
    } else if let value = argument("p") {
      line.drawing = (leadingNumber(value) ?? 0) > 0
    } else if let value = argument("move") {
      let values = numbers(value)
      if !line.positionSet, values.count >= 4 {
        line.position = PlayerASSPoint(x: values[0], y: values[1])
        line.moveTo = PlayerASSPoint(x: values[2], y: values[3])
        if values.count >= 6 {
          line.moveStart = values[4]
          line.moveEnd = values[5]
        }
        line.positionSet = true
      }
    } else if argument("org") != nil || argument("t") != nil {
      // Rotation origin and animated transforms: not supported (initial values are kept).
    } else if argument("kf") != nil || argument("ko") != nil || argument("k") != nil || argument("K") != nil {
      // Karaoke timing: the text is shown with its primary colour.
    } else if let value = argument("r") {
      let target = value.isEmpty ? style : (styles[styleKey(value)] ?? style)
      run = ASSRunState(target)
      line.reset(to: target)
    }
  }

  /// Number at the start of a tag argument ("1", "20.5", "-3", "+2", "(320,240)" → 320).
  private static func leadingNumber(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "( \t"))
    var number = ""
    for character in trimmed {
      if ("0"..."9").contains(character) || character == "." {
        number.append(character)
      } else if (character == "-" || character == "+") && number.isEmpty {
        number.append(character)
      } else {
        break
      }
    }
    if number.hasPrefix("+") { number.removeFirst() }
    guard let value = Double(number), value.isFinite else { return nil }
    return value
  }

  /// Comma separated numbers of a tag argument ("(320,240)" → [320, 240]).
  private static func numbers(_ text: String) -> [Double] {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "() \t"))
      .split(separator: ",")
      .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
      .filter { $0.isFinite }
  }

  /// Drops empty runs and the spaces / line breaks around the whole text.
  private static func trimmedRuns(_ input: [PlayerASSRun]) -> [PlayerASSRun] {
    let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\t" }
    var runs = input.filter { !$0.text.isEmpty }
    while let first = runs.first, first.text.allSatisfy(isBlank) { runs.removeFirst() }
    while let last = runs.last, last.text.allSatisfy(isBlank) { runs.removeLast() }
    guard !runs.isEmpty else { return [] }
    runs[0].text = String(runs[0].text.drop(while: isBlank))
    let lastIndex = runs.count - 1
    while let character = runs[lastIndex].text.last, isBlank(character) {
      runs[lastIndex].text.removeLast()
    }
    return runs.filter { !$0.text.isEmpty }
  }

  /// Plain text of the runs: lines trimmed, empty lines dropped, hard spaces as spaces.
  private static func plainText(_ runs: [PlayerASSRun]) -> String {
    let joined = runs.map(\.text).joined().replacingOccurrences(of: "\u{00A0}", with: " ")
    return joined.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
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
