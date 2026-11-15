import AVFoundation
import Foundation

// Chapters and intro/outro skipping. Ports of PlayerPage.svelte (skippableChaptersRx, isChapterSkippable,
// findChapter, mergeMicroSkippable, sanitiseChapters) and common/modules/anime/anime.js
// (getChaptersAniSkip, constructChapters). Times are in seconds (the Svelte code uses milliseconds).

struct PlayerChapter: Hashable, Identifiable, Sendable {
  var start: Double
  var end: Double
  var text: String

  var id: String { "\(start)-\(end)-\(text)" }
  var length: Double { end - start }
}

/// One AniSkip result (skipType "op" | "ed" | "recap").
struct PlayerSkipInterval: Hashable, Sendable {
  var type: String
  var start: Double
  var end: Double
  var episodeLength: Double?
}

enum PlayerChapterLogic {
  /// MAX_TOTAL_SKIP_TIME: anything longer than 3 minutes is likely invalid.
  static let maxTotalSkipTime: Double = 180

  /// skippableChaptersRx: returns "Intro", "Opening", "Outro", "Ending", "Credits", "Preview" or "Recap".
  static func matchName(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    if lines.contains("intro") { return "Intro" }
    if lines.contains(where: { $0 == "op" || $0.hasSuffix("opening") || $0.hasSuffix("title") || $0.hasPrefix("ncop") }) {
      return "Opening"
    }
    if lines.contains("outro") { return "Outro" }
    if lines.contains(where: { $0 == "ed" || $0.hasSuffix("ending") || $0.hasPrefix("nced") }) { return "Ending" }
    if trimmed.contains("credits") { return "Credits" }
    if lines.contains(where: { $0 == "preview" || $0.hasSuffix("previews") || $0.hasSuffix("pv") || $0.hasSuffix("next") }) {
      return "Preview"
    }
    if trimmed.contains("recap") { return "Recap" }
    return nil
  }

  /// isChapterSkippable.
  static func skippableName(_ chapter: PlayerChapter) -> String? {
    guard chapter.length <= maxTotalSkipTime else { return nil }
    return matchName(chapter.text)
  }

  /// findChapter.
  static func chapter(at time: Double, in chapters: [PlayerChapter]) -> PlayerChapter? {
    chapters.first { time < $0.end && time >= $0.start }
  }

  /// Names shown on the scrubber: timestamp-like names become "Chapter N" (sanitiseChapters).
  static func displayNames(_ chapters: [PlayerChapter]) -> [String] {
    var counter = 1
    return chapters.map { chapter in
      let trimmed = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && trimmed.allSatisfy({ "0123456789:. \t".contains($0) }) {
        let name = "Chapter \(counter)"
        counter += 1
        return name
      }
      return chapter.text
    }
  }

  private static func milliseconds(_ seconds: Double) -> Double {
    (seconds * 1000).rounded(.towardZero)
  }

  /// constructChapters: turns AniSkip intervals into a full chapter list covering the episode.
  static func construct(_ intervals: [PlayerSkipInterval], duration: Double) -> [PlayerChapter] {
    guard duration > 0, duration.isFinite else { return [] }
    var chapters: [PlayerChapter] = intervals.compactMap { interval in
      let diff = duration - (interval.episodeLength ?? duration)
      let start = interval.start + diff
      let end = interval.end + diff
      guard start.isFinite, end.isFinite else { return nil }
      let upper = interval.type.uppercased()
      return PlayerChapter(start: start, end: end, text: upper == "RECAP" ? "Recap" : upper)
    }
    guard !chapters.isEmpty else { return [] }
    chapters.sort { $0.start < $1.start }
    let ed = chapters.first { $0.text == "ED" }
    if milliseconds(chapters[0].start) != 0 {
      let first = chapters[0]
      chapters.insert(PlayerChapter(start: 0, end: first.start, text: first.text == "OP" ? "Intro" : "Episode"), at: 0)
    }
    if let ed {
      if ed.end + 5 - duration < 0 {
        chapters.append(PlayerChapter(start: ed.end, end: duration, text: "Preview"))
      }
    } else if let last = chapters.last, last.end + 5 - duration < 0 {
      chapters.append(PlayerChapter(start: last.end, end: duration, text: "Episode"))
    }
    let count = chapters.count
    if count >= 2 {
      for index in 0...(count - 2) {
        let current = chapters[index]
        let next = chapters[index + 1]
        if milliseconds(current.end) != milliseconds(next.start) {
          chapters.append(PlayerChapter(start: current.end, end: next.start, text: "Episode"))
        }
      }
    }
    chapters.sort { $0.start < $1.start }
    return chapters
  }

  /// sanitiseChapters (the part that fixes the chapter list; display mapping is in displayNames).
  static func sanitise(_ input: [PlayerChapter], duration: Double) -> [PlayerChapter] {
    guard !input.isEmpty, duration > 0, duration.isFinite else { return input }
    var chapters = input.map { PlayerChapter(start: abs($0.start), end: abs($0.end), text: $0.text) }
    let first = chapters[0]
    if first.start != 0 && chapters.contains(where: { $0.start == 0 }) {
      chapters.sort { $0.start < $1.start }
    }
    let boundaryMatches = chapters.enumerated()
      .filter { $0.element.start == first.end }
      .sorted { $0.element.length < $1.element.length }
    if let boundary = boundaryMatches.first?.offset, boundary > 1, boundary <= chapters.count {
      chapters.removeSubrange(1..<boundary)
    }
    let snapshot = chapters
    chapters = snapshot.enumerated().map { index, chapter in
      guard chapter.start == chapter.end else { return chapter }
      let nextStart = index + 1 < snapshot.count ? snapshot[index + 1].start : duration
      return PlayerChapter(start: chapter.start, end: nextStart, text: chapter.text)
    }
    chapters[chapters.count - 1].end = duration
    chapters[0].start = 0
    chapters = mergeMicroSkippable(chapters)
    return chapters.filter { $0.start <= duration }.map { chapter in
      PlayerChapter(start: chapter.start, end: min(chapter.end, duration), text: chapter.text)
    }
  }

  /// mergeMicroSkippable: glues tiny (< 10 s) skippable chapters to their skippable neighbour.
  static func mergeMicroSkippable(_ input: [PlayerChapter]) -> [PlayerChapter] {
    var chapters = input
    let isSkippable: (PlayerChapter) -> Bool = { matchName($0.text) != nil }
    let isShort: (PlayerChapter) -> Bool = { $0.length < 10 }
    let underMaxSkip: (PlayerChapter) -> Bool = { $0.length <= maxTotalSkipTime }
    var index = 0
    while index < chapters.count - 1 {
      let current = chapters[index]
      let next = chapters[index + 1]
      if isSkippable(current) && isSkippable(next) && underMaxSkip(current) && underMaxSkip(next) {
        if isShort(current) && !isShort(next) {
          chapters[index + 1].start = current.start
          chapters.remove(at: index)
          index = max(index - 1, -1)
        } else if isShort(next) {
          chapters[index].end = next.end
          chapters.remove(at: index + 1)
          index = max(index - 1, -1)
        }
      }
      index += 1
    }
    return chapters
  }
}

/// getChaptersAniSkip: community intro/outro timestamps from api.aniskip.com, by MyAnimeList id + episode.
enum PlayerAniSkip {
  private struct Response: Decodable {
    let results: [Entry]?
    let statusCode: Int?
  }

  private struct Entry: Decodable {
    let interval: Interval
    let skipType: String
    let episodeLength: Double?
  }

  private struct Interval: Decodable {
    let startTime: Double
    let endTime: Double
  }

  static func chapters(malId: Int, episode: Int, duration: Double) async -> [PlayerChapter] {
    guard duration > 0, duration.isFinite else { return [] }
    async let accurateRequest = fetch(malId: malId, episode: episode, episodeLength: duration)
    async let roughRequest = fetch(malId: malId, episode: episode, episodeLength: 0)
    let accurate = await accurateRequest
    let rough = await roughRequest
    if accurate?.statusCode == 500 || rough?.statusCode == 500 { return [] }
    var picked: [String: Entry] = [:]
    var order: [String] = []
    for entry in (accurate?.results ?? []) + (rough?.results ?? []) where picked[entry.skipType] == nil {
      picked[entry.skipType] = entry
      order.append(entry.skipType)
    }
    let intervals = order.compactMap { picked[$0] }.map { entry in
      PlayerSkipInterval(
        type: entry.skipType,
        start: entry.interval.startTime,
        end: entry.interval.endTime,
        episodeLength: entry.episodeLength
      )
    }
    guard !intervals.isEmpty else { return [] }
    return PlayerChapterLogic.construct(intervals, duration: duration)
  }

  private static func fetch(malId: Int, episode: Int, episodeLength: Double) async -> Response? {
    let length = episodeLength > 0 ? String(episodeLength) : "0"
    let address = "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)/?episodeLength=\(length)&types=op&types=ed&types=recap"
    guard let url = URL(string: address) else { return nil }
    guard let response = try? await HTTP.data(url, timeout: 10, allowErrorStatus: true) else { return nil }
    return try? JSONDecoder().decode(Response.self, from: response.0)
  }
}

/// Embedded chapters of the stream (MP4/MOV chapter tracks), the "Embedded" chapter source.
enum PlayerChapterLoader {
  static func embeddedChapters(of asset: AVAsset) async -> [PlayerChapter] {
    let languages = Locale.preferredLanguages
    guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages) else {
      return []
    }
    var chapters: [PlayerChapter] = []
    for (index, group) in groups.enumerated() {
      let start = group.timeRange.start.seconds
      let end = group.timeRange.end.seconds
      guard start.isFinite, end.isFinite, end > start else { continue }
      let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
      var title = "Chapter \(index + 1)"
      if let value = titleItem?.stringValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { title = trimmed }
      }
      chapters.append(PlayerChapter(start: start, end: end, text: title))
    }
    return chapters
  }
}

/// Filler/recap lookup on Jikan (episodesList.getSingleEpisode in common/modules/episodes.js), through the
/// Jikan mirrors and caches of AnimeMappingsService.
enum PlayerEpisodeFlagsLookup {
  static func jikan(media: Media, episode: EpisodeRef) async -> PlayerEpisodeFlags? {
    guard media.isAnime, let malId = media.malId, episode.number > 0,
          let data = await AnimeMappingsService.shared.jikanEpisode(malId: malId, episode: episode.number) else { return nil }
    return PlayerEpisodeFlags(isFiller: data.filler, isRecap: data.recap)
  }
}
