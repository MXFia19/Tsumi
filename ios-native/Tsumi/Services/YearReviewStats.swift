import Foundation

// Year in Review: pure statistics, port of common/modules/yearreview/stats.js (keep both in step; the node tests
// of stats.test.mjs document the expected results).
//
// Episode counting (AniList list activities):
// - "watched episode 4 - 6" counts 3, overlapping ranges of the same title are only counted once;
// - "completed" has no episode number: it adds the episodes between the last progress seen and the total.
//   Without an earlier progress in the year, the progress before the year (prior) is used, else the whole
//   title counts when it was started this year (or has no start date) and only the last episode otherwise;
// - "rewatched episode" / "rewatched" are counted the same way in a separate rewatch cycle;
// - a list entry completed this year without a "completed" activity in the year is treated as one at its
//   completion date.

/// ListActivity of the year (normalised).
struct YearReviewActivity: Codable, Hashable {
  var id: Int
  var status: String
  var progress: String?
  /// Epoch seconds.
  var createdAt: Int
  var mediaId: Int
}

/// Media fields used by the review.
struct YearReviewMedia: Codable, Hashable {
  var id: Int
  var title: String
  var cover: String?
  var color: String?
  var banner: String?
  var format: String?
  var episodes: Int?
  var duration: Int?
  var genres: [String] = []
  var studios: [String] = []

  var coverURL: URL? { URL.lenient(cover) }
  var bannerURL: URL? { URL.lenient(banner) }

  /// Keeps the non-empty fields of both (list entries carry the studios, activities do not).
  func merged(with next: YearReviewMedia?) -> YearReviewMedia {
    guard let next else { return self }
    var result = self
    if !next.title.isEmpty && next.title != YearReviewCalc.unknownTitle { result.title = next.title }
    if next.cover != nil { result.cover = next.cover }
    if next.color != nil { result.color = next.color }
    if next.banner != nil { result.banner = next.banner }
    if next.format != nil { result.format = next.format }
    if next.episodes != nil { result.episodes = next.episodes }
    if next.duration != nil { result.duration = next.duration }
    if !next.genres.isEmpty { result.genres = next.genres }
    if !next.studios.isEmpty { result.studios = next.studios }
    return result
  }
}

/// List entry (MediaList) of the user.
struct YearReviewEntry: Codable, Hashable {
  var mediaId: Int
  var status: String
  /// 0-10 (POINT_10_DECIMAL), 0 = no score.
  var score: Double
  var progress: Int
  var repeatCount: Int
  var startedAt: FuzzyDate?
  var completedAt: FuzzyDate?
  /// Epoch seconds, 0 when unknown.
  var updatedAt: Int
  var createdAt: Int
}

/// Activity read for the progress before the year (newest first).
struct YearReviewPriorActivity: Hashable {
  var mediaId: Int
  var status: String
  var progress: String?
}

enum YearReviewActivityKind {
  case watch, rewatch, complete, rewatched, drop, pause, plan, other
}

struct YearReviewTopItem: Hashable, Identifiable {
  var mediaId: Int
  var episodes: Int
  var minutes: Int
  var id: Int { mediaId }
}

struct YearReviewRanked: Hashable, Identifiable {
  var name: String
  var count: Int
  var episodes: Int
  var minutes: Int
  var id: String { name }
}

struct YearReviewDay: Hashable {
  /// "YYYY-MM-DD" (local).
  var date: String
  var episodes: Int
  var minutes: Int
  var mediaIds: [Int]
}

struct YearReviewStreak: Hashable {
  var days: Int
  var start: String
  var end: String
}

struct YearReviewMoment: Hashable {
  var mediaId: Int
  var time: Int
}

struct YearReviewRated: Hashable {
  var mediaId: Int
  var score: Double
}

struct YearReviewStats: Hashable {
  var year: Int
  var hasData: Bool
  var episodes: Int
  var minutes: Int
  var titles: Int
  var rewatchEpisodes: Int
  var started: Int
  var completed: Int
  var dropped: Int
  var startedIds: [Int]
  var completedIds: [Int]
  var droppedIds: [Int]
  var averageScore: Double?
  var scoredCount: Int
  var topRated: YearReviewRated?
  var topAnime: [YearReviewTopItem]
  var genres: [YearReviewRanked]
  var studios: [YearReviewRanked]
  var months: [Int]
  var monthMinutes: [Int]
  var bingeDay: YearReviewDay?
  var activeDays: Int
  var longestStreak: YearReviewStreak?
  var first: YearReviewMoment?
  var last: YearReviewMoment?
  var touched: Int
}

/// Local watch history record (shows / movies from TMDB).
struct YearReviewLocalRecord: Hashable {
  var key: String
  var episode: Int?
  var currentTime: Double
  var duration: Double
  var updatedAt: Date
}

struct YearReviewLocalTitle: Hashable, Identifiable {
  var key: String
  var episodes: Int
  var minutes: Int
  var lastWatched: Date
  var id: String { key }
}

struct YearReviewLocalStats: Hashable {
  var year: Int
  var hasData: Bool
  var titles: Int
  var episodes: Int
  var minutes: Int
  var top: [YearReviewLocalTitle]

  static func empty(_ year: Int) -> YearReviewLocalStats {
    YearReviewLocalStats(year: year, hasData: false, titles: 0, episodes: 0, minutes: 0, top: [])
  }
}

/// Insertion-ordered set of ids (the JS Set).
private struct YearReviewOrderedIds {
  private(set) var order: [Int] = []
  private var members = Set<Int>()

  mutating func insert(_ id: Int) {
    if members.insert(id).inserted { order.append(id) }
  }

  func contains(_ id: Int) -> Bool { members.contains(id) }
  var count: Int { order.count }
}

enum YearReviewCalc {
  static let statsVersion = 1
  static let unknownTitle = "Unknown title"
  static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  /// Minutes per episode when AniList has no duration.
  static let defaultEpisodeMinutes = 24
  static let defaultMovieMinutes = 90
  /// A local history record counts as a watched episode from this fraction.
  static let localWatchedFraction = 0.8
  private static let maxRange = 5000
  private static let topCount = 5

  /// Gregorian calendar in the device time zone (AniList years are Gregorian).
  static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone.current
    return value
  }

  private static func epoch(year: Int, month: Int, day: Int, hour: Int) -> Int {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    return Int(date.timeIntervalSince1970.rounded(.down))
  }

  /// Local-time bounds of a year in epoch seconds: start <= createdAt < end.
  static func yearBounds(_ year: Int) -> (start: Int, end: Int) {
    (epoch(year: year, month: 1, day: 1, hour: 0), epoch(year: year + 1, month: 1, day: 1, hour: 0))
  }

  /// "5" → (5, 5), "1 - 12" → (1, 12), anything else → nil.
  static func parseProgress(_ progress: String?) -> (from: Int, to: Int)? {
    guard let progress else { return nil }
    let numbers = progress.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
    guard let first = numbers.first, let last = numbers.last else { return nil }
    let from = min(first, last)
    let to = max(first, last)
    if to - from > maxRange { return nil }
    return (from, to)
  }

  static func activityKind(_ status: String?) -> YearReviewActivityKind {
    let text = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasPrefix("rewatched episode") { return .rewatch }
    if text.hasPrefix("watched episode") { return .watch }
    if text == "rewatched" { return .rewatched }
    if text == "completed" { return .complete }
    if text == "dropped" { return .drop }
    if text.hasPrefix("paused") { return .pause }
    if text.hasPrefix("plans") { return .plan }
    if text.hasPrefix("rewatching") { return .rewatch }
    if text.hasPrefix("watching") { return .watch }
    return .other
  }

  /// Fuzzy date → epoch seconds at local noon (nil without a year).
  static func fuzzyToTime(_ date: FuzzyDate?) -> Int? {
    guard let year = date?.year else { return nil }
    return epoch(year: year, month: date?.month ?? 1, day: date?.day ?? 1, hour: 12)
  }

  static func fuzzyInYear(_ date: FuzzyDate?, _ year: Int) -> Bool {
    date?.year == year
  }

  private static func fuzzyBefore(_ date: FuzzyDate?, _ year: Int) -> Bool {
    guard let value = date?.year else { return false }
    return value < year
  }

  /// Local calendar day "YYYY-MM-DD" of epoch seconds.
  static func dayKey(_ seconds: Int) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 1, components.day ?? 1)
  }

  private static func dayParts(_ key: String) -> (year: Int, month: Int, day: Int)? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return (parts[0], parts[1], parts[2])
  }

  private static func dayIndex(_ key: String) -> Int {
    guard let parts = dayParts(key) else { return 0 }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    var components = DateComponents()
    components.year = parts.year
    components.month = parts.month
    components.day = parts.day
    let date = utc.date(from: components) ?? Date(timeIntervalSince1970: 0)
    return Int((date.timeIntervalSince1970 / 86_400).rounded())
  }

  /// "YYYY-MM-DD" → "Saturday, March 14".
  static func formatDay(_ key: String) -> String {
    guard let parts = dayParts(key), (1...12).contains(parts.month) else { return "" }
    var components = DateComponents()
    components.year = parts.year
    components.month = parts.month
    components.day = parts.day
    components.hour = 12
    let weekday = calendar.date(from: components).map { calendar.component(.weekday, from: $0) } ?? 1
    return "\(weekdays[(weekday - 1 + 7) % 7]), \(monthNames[parts.month - 1]) \(parts.day)"
  }

  /// "YYYY-MM-DD" → "Mar 14".
  static func formatShortDay(_ key: String) -> String {
    guard let parts = dayParts(key), (1...12).contains(parts.month) else { return "" }
    return "\(months[parts.month - 1]) \(parts.day)"
  }

  /// Hours for display: one decimal under 10 hours, whole hours above.
  static func hoursValue(_ minutes: Int) -> Double {
    let hours = Double(minutes) / 60
    return hours < 10 ? (hours * 10).rounded() / 10 : hours.rounded()
  }

  /// "12,345" (English grouping); one decimal is kept for values like the "1.5" of hoursValue.
  static func formatNumber(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    let whole = Int(abs(rounded).rounded(.down))
    let tenths = Int(((abs(rounded) - Double(whole)) * 10).rounded())
    var digits = String(whole)
    var grouped = ""
    while digits.count > 3 {
      grouped = "," + String(digits.suffix(3)) + grouped
      digits = String(digits.dropLast(3))
    }
    let text = digits + grouped + (tenths > 0 ? ".\(tenths)" : "")
    return rounded < 0 ? "-" + text : text
  }

  static func formatNumber(_ value: Int) -> String {
    formatNumber(Double(value))
  }

  /// "3 episodes" / "1 episode" ("anime" has no plural).
  static func plural(_ value: Int, _ word: String) -> String {
    "\(formatNumber(value)) \(word)\(value == 1 || word == "anime" ? "" : "s")"
  }

  static func episodeMinutes(_ media: YearReviewMedia?) -> Int {
    if let duration = media?.duration, duration > 0 { return duration }
    return media?.format == "MOVIE" ? defaultMovieMinutes : defaultEpisodeMinutes
  }

  /// Episode total used by completions: 1 for movies, nil when unknown.
  private static func totalEpisodes(_ media: YearReviewMedia?) -> Int? {
    if let episodes = media?.episodes, episodes > 0 { return episodes }
    return media?.format == "MOVIE" ? 1 : nil
  }

  private static func entryMap(_ entries: [YearReviewEntry]) -> [Int: YearReviewEntry] {
    var map: [Int: YearReviewEntry] = [:]
    for entry in entries where map[entry.mediaId] == nil {
      map[entry.mediaId] = entry
    }
    return map
  }

  private static let completedStatuses: Set<String> = ["COMPLETED", "REPEATING"]

  /// Activities of the year in chronological order, plus a synthetic "completed" activity for every entry
  /// completed this year without a "completed" activity in the year.
  private static func timeline(year: Int, activities: [YearReviewActivity], entries: [YearReviewEntry]) -> [YearReviewActivity] {
    let bounds = yearBounds(year)
    var list = activities.filter { $0.createdAt >= bounds.start && $0.createdAt < bounds.end }
    var withCompletion = Set(list.filter { activityKind($0.status) == .complete }.map(\.mediaId))
    for entry in entries {
      if withCompletion.contains(entry.mediaId) { continue }
      guard completedStatuses.contains(entry.status), fuzzyInYear(entry.completedAt, year), let time = fuzzyToTime(entry.completedAt) else { continue }
      list.append(YearReviewActivity(id: 0, status: "completed", progress: nil, createdAt: min(max(time, bounds.start), bounds.end - 1), mediaId: entry.mediaId))
      withCompletion.insert(entry.mediaId)
    }
    return list.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  /// Titles whose first completion of the year has no earlier progress in the year (see stats.js).
  static func mediaNeedingPrior(year: Int, activities: [YearReviewActivity], media: [Int: YearReviewMedia], entries: [YearReviewEntry]) -> [Int] {
    let start = yearBounds(year).start
    let entriesById = entryMap(entries)
    var seen = Set<Int>()
    var result: [Int] = []
    for activity in timeline(year: year, activities: activities, entries: entries) {
      let kind = activityKind(activity.status)
      if seen.contains(activity.mediaId) { continue }
      if kind == .watch || kind == .rewatch || kind == .rewatched {
        seen.insert(activity.mediaId)
        continue
      }
      if kind != .complete { continue }
      seen.insert(activity.mediaId)
      let total = totalEpisodes(media[activity.mediaId])
      let added = entriesById[activity.mediaId]?.createdAt ?? 0
      if let total, total > 1, !(added >= start) { result.append(activity.mediaId) }
    }
    return result
  }

  /// Progress before the year from the latest earlier activities of the given titles (newest first).
  static func priorFromActivities(_ activities: [YearReviewPriorActivity], media: [Int: YearReviewMedia]) -> [Int: Int] {
    var prior: [Int: Int] = [:]
    for activity in activities where prior[activity.mediaId] == nil {
      let kind = activityKind(activity.status)
      let range = parseProgress(activity.progress)
      let total = totalEpisodes(media[activity.mediaId])
      if kind == .watch, let range {
        prior[activity.mediaId] = range.to
      } else if kind == .complete || kind == .rewatch || kind == .rewatched, let total {
        prior[activity.mediaId] = total
      } else if kind == .plan {
        prior[activity.mediaId] = 0
      }
    }
    return prior
  }

  /// Every statistic of the Year in Review screen.
  static func compute(year: Int, activities: [YearReviewActivity], media: [Int: YearReviewMedia], entries: [YearReviewEntry], prior: [Int: Int]) -> YearReviewStats {
    struct TitleTotal {
      var mediaId: Int
      var episodes = 0
      var minutes = 0
    }
    struct TitleState {
      var maxProgress: Int?
      var rewatchMax: Int?
      var seenWatch = false
    }
    struct Event {
      var mediaId: Int
      var time: Int
      var episodes: Int
      var minutes: Int
    }

    let entriesById = entryMap(entries)
    let bounds = yearBounds(year)
    var titles: [Int: TitleTotal] = [:]
    var titleOrder: [Int] = []
    var states: [Int: TitleState] = [:]
    var events: [Event] = []
    var started = YearReviewOrderedIds()
    var completed = YearReviewOrderedIds()
    var dropped = YearReviewOrderedIds()
    var touched = Set<Int>()
    var rewatchEpisodes = 0

    func add(_ id: Int, _ time: Int, _ episodes: Int, _ rewatch: Bool) {
      guard episodes > 0 else { return }
      let minutes = episodes * episodeMinutes(media[id])
      if titles[id] == nil {
        titles[id] = TitleTotal(mediaId: id)
        titleOrder.append(id)
      }
      titles[id]?.episodes += episodes
      titles[id]?.minutes += minutes
      if rewatch { rewatchEpisodes += episodes }
      events.append(Event(mediaId: id, time: time, episodes: episodes, minutes: minutes))
    }

    for activity in timeline(year: year, activities: activities, entries: entries) {
      let id = activity.mediaId
      let range = parseProgress(activity.progress)
      let total = totalEpisodes(media[id])
      var current = states[id] ?? TitleState()
      touched.insert(id)

      switch activityKind(activity.status) {
      case .watch:
        if let range {
          if !current.seenWatch && range.from <= 1 { started.insert(id) }
          let base = max(range.from - 1, current.maxProgress ?? -1)
          add(id, activity.createdAt, max(0, range.to - base), false)
          current.maxProgress = max(current.maxProgress ?? 0, range.to)
        }
        current.seenWatch = true
      case .rewatch:
        if let range {
          if range.from <= 1 { current.rewatchMax = 0 }
          let base = max(range.from - 1, current.rewatchMax ?? -1)
          add(id, activity.createdAt, max(0, range.to - base), true)
          current.rewatchMax = max(current.rewatchMax ?? 0, range.to)
        }
      case .complete:
        completed.insert(id)
        var base = current.maxProgress
        if base == nil, let value = prior[id] { base = value }
        if let total {
          let resolved = base ?? (fuzzyBefore(entriesById[id]?.startedAt, year) ? total - 1 : 0)
          if resolved <= 0 && !current.seenWatch { started.insert(id) }
          add(id, activity.createdAt, max(0, total - resolved), false)
          current.maxProgress = max(current.maxProgress ?? 0, total)
        } else if !current.seenWatch {
          // Unknown total (should not happen for a completed title): at least the last episode.
          add(id, activity.createdAt, 1, false)
        }
        current.seenWatch = true
      case .rewatched:
        if let total {
          add(id, activity.createdAt, max(0, total - (current.rewatchMax ?? 0)), true)
        }
        current.rewatchMax = nil
      case .drop:
        dropped.insert(id)
      case .pause, .plan, .other:
        break
      }
      states[id] = current
    }

    for entry in entries {
      if completedStatuses.contains(entry.status) && fuzzyInYear(entry.completedAt, year) {
        completed.insert(entry.mediaId)
        touched.insert(entry.mediaId)
      }
      if fuzzyInYear(entry.startedAt, year) {
        started.insert(entry.mediaId)
        touched.insert(entry.mediaId)
      }
      if entry.status == "DROPPED" && entry.updatedAt >= bounds.start && entry.updatedAt < bounds.end && (titles[entry.mediaId]?.episodes ?? 0) > 0 {
        dropped.insert(entry.mediaId)
      }
    }

    let watched = titleOrder.compactMap { titles[$0] }.filter { $0.episodes > 0 }
    let episodes = watched.reduce(0) { $0 + $1.episodes }
    let minutes = watched.reduce(0) { $0 + $1.minutes }

    // Months and days
    var months = Array(repeating: 0, count: 12)
    var monthMinutes = Array(repeating: 0, count: 12)
    struct DayTotal {
      var date: String
      var episodes = 0
      var minutes = 0
      var perMedia: [Int: Int] = [:]
      var mediaOrder: [Int] = []
    }
    var days: [String: DayTotal] = [:]
    let cal = calendar
    for event in events {
      let month = cal.component(.month, from: Date(timeIntervalSince1970: TimeInterval(event.time))) - 1
      if (0..<12).contains(month) {
        months[month] += event.episodes
        monthMinutes[month] += event.minutes
      }
      let key = dayKey(event.time)
      var day = days[key] ?? DayTotal(date: key)
      day.episodes += event.episodes
      day.minutes += event.minutes
      if day.perMedia[event.mediaId] == nil { day.mediaOrder.append(event.mediaId) }
      day.perMedia[event.mediaId, default: 0] += event.episodes
      days[key] = day
    }
    var best: DayTotal?
    for day in days.values.sorted(by: { $0.date < $1.date }) where best == nil || day.episodes > (best?.episodes ?? 0) {
      best = day
    }
    let bingeDay = best.map { day -> YearReviewDay in
      let ordered = day.mediaOrder.enumerated().sorted { lhs, rhs in
        let left = day.perMedia[lhs.element] ?? 0
        let right = day.perMedia[rhs.element] ?? 0
        return left != right ? left > right : lhs.offset < rhs.offset
      }
      return YearReviewDay(date: day.date, episodes: day.episodes, minutes: day.minutes, mediaIds: ordered.map(\.element))
    }
    var longestStreak: YearReviewStreak?
    var runStart = ""
    var previous: Int?
    for key in days.keys.sorted() {
      let index = dayIndex(key)
      if previous == nil || index != (previous ?? 0) + 1 { runStart = key }
      let length = index - dayIndex(runStart) + 1
      if longestStreak == nil || length > (longestStreak?.days ?? 0) {
        longestStreak = YearReviewStreak(days: length, start: runStart, end: key)
      }
      previous = index
    }

    // Ranked lists
    let sortedWatched = watched.sorted { lhs, rhs in
      if lhs.episodes != rhs.episodes { return lhs.episodes > rhs.episodes }
      if lhs.minutes != rhs.minutes { return lhs.minutes > rhs.minutes }
      return lhs.mediaId < rhs.mediaId
    }
    let topAnime = sortedWatched.prefix(topCount).map { YearReviewTopItem(mediaId: $0.mediaId, episodes: $0.episodes, minutes: $0.minutes) }
    func rank(_ names: (YearReviewMedia) -> [String]) -> [YearReviewRanked] {
      var map: [String: YearReviewRanked] = [:]
      for title in sortedWatched {
        guard let item = media[title.mediaId] else { continue }
        var seenNames = Set<String>()
        for name in names(item) where !name.isEmpty && seenNames.insert(name).inserted {
          var ranked = map[name] ?? YearReviewRanked(name: name, count: 0, episodes: 0, minutes: 0)
          ranked.count += 1
          ranked.episodes += title.episodes
          ranked.minutes += title.minutes
          map[name] = ranked
        }
      }
      return Array(map.values.sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if lhs.minutes != rhs.minutes { return lhs.minutes > rhs.minutes }
        return lhs.name.localizedCompare(rhs.name) == .orderedAscending
      }.prefix(topCount))
    }

    // Scores of the titles watched / completed this year
    var scoreSum = 0.0
    var scoredCount = 0
    var topRated: (mediaId: Int, score: Double, episodes: Int)?
    var scoredIds = YearReviewOrderedIds()
    for title in sortedWatched { scoredIds.insert(title.mediaId) }
    for id in completed.order { scoredIds.insert(id) }
    for id in scoredIds.order {
      guard let score = entriesById[id]?.score, score > 0 else { continue }
      scoreSum += score
      scoredCount += 1
      let episodesOf = titles[id]?.episodes ?? 0
      if let current = topRated {
        if score > current.score || (score == current.score && episodesOf > current.episodes) {
          topRated = (id, score, episodesOf)
        }
      } else {
        topRated = (id, score, episodesOf)
      }
    }

    let first = events.first.map { YearReviewMoment(mediaId: $0.mediaId, time: $0.time) }
    let last = events.last.map { YearReviewMoment(mediaId: $0.mediaId, time: $0.time) }

    return YearReviewStats(
      year: year,
      hasData: episodes > 0 || completed.count > 0 || started.count > 0 || dropped.count > 0,
      episodes: episodes,
      minutes: minutes,
      titles: watched.count,
      rewatchEpisodes: rewatchEpisodes,
      started: started.count,
      completed: completed.count,
      dropped: dropped.count,
      startedIds: started.order,
      completedIds: completed.order,
      droppedIds: dropped.order,
      averageScore: scoredCount > 0 ? (scoreSum / Double(scoredCount) * 10).rounded() / 10 : nil,
      scoredCount: scoredCount,
      topRated: topRated.map { YearReviewRated(mediaId: $0.mediaId, score: $0.score) },
      topAnime: Array(topAnime),
      genres: rank { $0.genres },
      studios: rank { $0.studios },
      months: months,
      monthMinutes: monthMinutes,
      bingeDay: bingeDay,
      activeDays: days.count,
      longestStreak: longestStreak,
      first: first,
      last: last,
      touched: touched.count
    )
  }

  /// Local watch history (shows and movies from TMDB, not on AniList) for one year.
  static func computeLocal(_ records: [YearReviewLocalRecord], year: Int) -> YearReviewLocalStats {
    let bounds = yearBounds(year)
    let start = Date(timeIntervalSince1970: TimeInterval(bounds.start))
    let end = Date(timeIntervalSince1970: TimeInterval(bounds.end))
    struct Total {
      var key: String
      var episodes = 0
      var minutes = 0.0
      var lastWatched = Date(timeIntervalSince1970: 0)
    }
    var titles: [String: Total] = [:]
    var episodes = 0
    var minutes = 0.0
    for record in records where record.updatedAt >= start && record.updatedAt < end {
      guard record.duration > 0 else { continue }
      let watchedSeconds = min(max(record.currentTime, 0), record.duration)
      let finished = watchedSeconds / record.duration >= localWatchedFraction ? 1 : 0
      var title = titles[record.key] ?? Total(key: record.key)
      title.episodes += finished
      title.minutes += watchedSeconds / 60
      title.lastWatched = max(title.lastWatched, record.updatedAt)
      titles[record.key] = title
      episodes += finished
      minutes += watchedSeconds / 60
    }
    let top = titles.values.sorted { lhs, rhs in
      if lhs.minutes != rhs.minutes { return lhs.minutes > rhs.minutes }
      if lhs.episodes != rhs.episodes { return lhs.episodes > rhs.episodes }
      return lhs.key < rhs.key
    }.prefix(topCount).map {
      YearReviewLocalTitle(key: $0.key, episodes: $0.episodes, minutes: Int($0.minutes.rounded()), lastWatched: $0.lastWatched)
    }
    return YearReviewLocalStats(year: year, hasData: !titles.isEmpty, titles: titles.count, episodes: episodes, minutes: Int(minutes.rounded()), top: Array(top))
  }

  /// Years offered by the picker: the current year plus every year found in the list entries
  /// (started / completed / added / updated) and in the extra years (local history), newest first.
  static func availableYears(entries: [YearReviewEntry], now: Date = Date(), extra: [Int] = []) -> [Int] {
    let current = calendar.component(.year, from: now)
    var years = Set([current] + extra)
    func yearOf(_ seconds: Int) -> Int? {
      seconds > 0 ? calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(seconds))) : nil
    }
    for entry in entries {
      for year in [entry.startedAt?.year, entry.completedAt?.year, yearOf(entry.createdAt), yearOf(entry.updatedAt)] {
        if let year { years.insert(year) }
      }
    }
    return years.filter { $0 >= 2000 && $0 <= current }.sorted(by: >)
  }

  /// Year shown by the Home banner: December → this year, January → last year, else nil.
  static func bannerYear(now: Date = Date()) -> Int? {
    let components = calendar.dateComponents([.year, .month], from: now)
    guard let year = components.year, let month = components.month else { return nil }
    if month == 12 { return year }
    if month == 1 { return year - 1 }
    return nil
  }
}
