import Foundation

// Port of common/modules/sync/position.js: the playback position kept in the note of the list entry (AniList
// `notes`, MyAnimeList `comments`) for the cross-device resume. One line owned by Tsumi, the rest of the note is
// the user's and is never touched:
//
//   [Tsumi] Ep 5 · 12:34 / 23:40 · iPhone · 2026-11-15T12:00:00Z
//
// episode · position / duration · device · time of the write (UTC). The duration is optional and `|` or `•` are
// accepted as separators too. Keep both files in sync (node common/modules/sync/position.test.mjs tests the rules).

/// A position read from (or written to) a note. `time` / `duration` in seconds.
struct NotePosition: Codable, Hashable {
  var episode: Int
  var time: Double
  var duration: Double?
  var device: String
  var at: Date
}

enum PlaybackPositionNote {
  static let prefix = "[Tsumi]"
  /// Minimum change of position (seconds) worth a new write of the same episode.
  static let minPositionChange: Double = 5
  /// A remote position must differ by more than this (seconds) from the local one to be offered...
  static let offerMinDifference: Double = 15
  /// ... and be newer than it by more than this (seconds): the clocks of two devices are never exact.
  static let offerMinAgeDifference: TimeInterval = 5
  /// Periodic write while playing.
  static let periodicWrite: TimeInterval = 120
  /// Write after a pause (cancelled when playback resumes before).
  static let pauseWriteDelay: TimeInterval = 3

  private static let linePattern: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"^\s*\[Tsumi\]\s*Ep\s*(\d+)\s*[·|•]\s*((?:\d+:)?\d{1,2}:\d{2})(?:\s*/\s*((?:\d+:)?\d{1,2}:\d{2}))?\s*[·|•]\s*(.*?)\s*[·|•]\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s*$"#,
    options: [.caseInsensitive]
  )
  private static let oursPattern: NSRegularExpression? = try? NSRegularExpression(pattern: #"^\s*\[Tsumi\]"#, options: [.caseInsensitive])

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let isoFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// 754 → "12:34", 3723 → "1:02:03".
  static func formatClock(_ seconds: Double) -> String {
    let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    let mm = hours > 0 ? String(format: "%02d", minutes) : String(minutes)
    return (hours > 0 ? "\(hours):" : "") + mm + ":" + String(format: "%02d", secs)
  }

  /// "12:34" → 754, "1:02:03" → 3723.
  static func parseClock(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    var total = 0.0
    for part in parts {
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Double(part) else { return nil }
      total = total * 60 + value
    }
    return total
  }

  /// Device name as written in the line: no separator, no line break, 24 characters at most.
  static func cleanDevice(_ name: String) -> String {
    var cleaned = ""
    for character in name {
      cleaned.append(["\n", "\r", "·", "|", "•"].contains(character) ? " " : character)
    }
    let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let result = String(collapsed.prefix(24)).trimmingCharacters(in: .whitespaces)
    return result.isEmpty ? "Unknown" : result
  }

  static func formatLine(_ position: NotePosition) -> String {
    var clock = formatClock(position.time)
    if let duration = position.duration, duration > 0 { clock += " / " + formatClock(duration) }
    let seconds = Date(timeIntervalSince1970: position.at.timeIntervalSince1970.rounded(.down))
    return "\(prefix) Ep \(max(0, position.episode)) · \(clock) · \(cleanDevice(position.device)) · \(isoFormatter.string(from: seconds))"
  }

  /// One line; nil when it is not a (valid) Tsumi line.
  static func parseLine(_ line: String) -> NotePosition? {
    guard let pattern = linePattern else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = pattern.firstMatch(in: line, options: [], range: range) else { return nil }
    func group(_ index: Int) -> String? {
      guard let groupRange = Range(match.range(at: index), in: line) else { return nil }
      return String(line[groupRange])
    }
    guard let episodeText = group(1), let episode = Int(episodeText),
          let timeText = group(2), let time = parseClock(timeText),
          let iso = group(5),
          let at = isoFormatter.date(from: iso) ?? isoFractionalFormatter.date(from: iso) else { return nil }
    let duration = group(3).flatMap { parseClock($0) }.flatMap { $0 > 0 ? $0 : nil }
    let device = (group(4) ?? "").trimmingCharacters(in: .whitespaces)
    return NotePosition(episode: episode, time: time, duration: duration, device: device.isEmpty ? "Unknown" : device, at: at)
  }

  private static func lines(_ notes: String?) -> [String] {
    let normalized = (notes ?? "").replacingOccurrences(of: "\r\n", with: "\n")
    return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func isOurs(_ line: String) -> Bool {
    guard let pattern = oursPattern else { return line.hasPrefix(prefix) }
    return pattern.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
  }

  /// The position written in a note (the newest valid line when someone left several).
  static func read(_ notes: String?) -> NotePosition? {
    var found: NotePosition?
    for line in lines(notes) {
      if let position = parseLine(line), found == nil || position.at > (found?.at ?? .distantPast) {
        found = position
      }
    }
    return found
  }

  /// Whether the note has a Tsumi line (valid or not).
  static func hasLine(_ notes: String?) -> Bool {
    lines(notes).contains { isOurs($0) }
  }

  /// The user's part of the note: every Tsumi line removed, trailing blank lines trimmed.
  static func strip(_ notes: String?) -> String {
    var text = lines(notes).filter { !isOurs($0) }.joined(separator: "\n")
    while let last = text.last, last.isWhitespace { text.removeLast() }
    return text
  }

  /// The note with our line replaced (or added at the end); nil removes it.
  static func with(_ notes: String?, _ position: NotePosition?) -> String {
    let user = strip(notes)
    guard let position else { return user }
    let line = formatLine(position)
    return user.isEmpty ? line : user + "\n" + line
  }

  /// Whether the remote position of `episode` should be offered instead of the local record.
  static func shouldOffer(remote: NotePosition?, localTime: Double?, localUpdatedAt: Date?, episode: Int) -> Bool {
    guard let remote, remote.episode == episode, remote.time > 0 else { return false }
    if let localUpdatedAt, remote.at <= localUpdatedAt.addingTimeInterval(offerMinAgeDifference) { return false }
    return abs(remote.time - (localTime ?? 0)) > offerMinDifference
  }

  /// Whether a new write is needed: another episode, or a position that moved enough.
  static func needsWrite(last: NotePosition?, next: NotePosition) -> Bool {
    guard let last else { return true }
    if last.episode != next.episode { return true }
    return abs(last.time - next.time) >= minPositionChange
  }

  /// "12:34" when the time is known, "53%" otherwise (Trakt only stores a percentage).
  static func label(time: Double?, percent: Double?) -> String {
    if let time, time > 0 { return formatClock(time) }
    if let percent, percent > 0 { return "\(Int(percent.rounded()))%" }
    return "0:00"
  }
}
