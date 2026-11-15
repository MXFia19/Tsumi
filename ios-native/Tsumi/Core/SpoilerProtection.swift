import Foundation

// Spoiler protection (Settings > Interface > Spoiler Protection): common/modules/spoilers.js, adapted from the
// "Spoiler Control" of Shiru 6.6.0. A level (each one includes everything from the level before it) applies to the
// titles whose list status is selected; episode content is only hidden after the list progress. Same rules, defaults
// and texts as the Svelte module (unit tested there by spoilers.test.mjs).

enum SpoilerLevel: String, CaseIterable, Identifiable {
  case off, minimal, moderate, strict, hermit

  var id: String { rawValue }

  var rank: Int {
    switch self {
    case .off: return 0
    case .minimal: return 1
    case .moderate: return 2
    case .strict: return 3
    case .hermit: return 4
    }
  }

  var label: String { rawValue.capitalized }
}

/// What a level hides (SPOILER_ITEMS).
enum SpoilerItem {
  case episodeImage, episodeDescription, reviews, mediaSpoilerTags, episodeTitle, synopsis, rating, generalSpoilerTags, duration

  /// Lowest level hiding the item.
  var minimumLevel: SpoilerLevel {
    switch self {
    case .episodeImage: return .minimal
    case .episodeDescription, .reviews, .mediaSpoilerTags: return .moderate
    case .episodeTitle, .synopsis, .rating, .generalSpoilerTags: return .strict
    case .duration: return .hermit
    }
  }
}

struct SpoilerStatusOption: Identifiable, Hashable {
  let value: String
  let label: String
  var id: String { value }
}

enum SpoilerProtection {
  static let notOnList = "NOTONLIST"

  /// List statuses protection can apply to. Completed is left out: nothing is left to spoil.
  static let statusOptions: [SpoilerStatusOption] = [
    SpoilerStatusOption(value: ListStatus.current.rawValue, label: "Watching"),
    SpoilerStatusOption(value: ListStatus.repeating.rawValue, label: "Rewatching"),
    SpoilerStatusOption(value: ListStatus.planning.rawValue, label: "Planning"),
    SpoilerStatusOption(value: ListStatus.paused.rawValue, label: "Paused"),
    SpoilerStatusOption(value: ListStatus.dropped.rawValue, label: "Dropped"),
    SpoilerStatusOption(value: notOnList, label: "Not on List")
  ]

  static let defaultStatuses = [ListStatus.current.rawValue, ListStatus.repeating.rawValue]

  /// Shown instead of a hidden episode title or description, or of a hidden synopsis.
  static let hiddenText = "Hidden to avoid spoilers"

  static let description = "Hides what you have not watched yet, for the titles whose list status is selected below. Episode content is only hidden after your progress, and each level includes everything from the level before it.\n\n"
    + "Minimal hides the thumbnails of the episodes you have not watched.\n"
    + "Moderate also hides their descriptions, the review count, and the tags marked as spoilers for the title.\n"
    + "Strict also hides their titles, the synopsis and rating of the title (next seasons and sequels too when their status is selected), and the tags marked as general spoilers.\n"
    + "Hermit also hides episode durations and the length of the title."

  static let statusDescription = "Spoiler protection only applies to titles with one of these list statuses, everything else shows normally. For example, with only \"Watching\", the series you are currently watching are protected. Add \"Planning\" or \"Not on List\" to also protect the next seasons and sequels you have not started."

  /// The selected level (off when unknown).
  static func level(_ values: SettingsValues) -> SpoilerLevel {
    SpoilerLevel(rawValue: values.spoilers) ?? .off
  }

  /// The level hides this item at all (whatever the title).
  static func levelHides(_ item: SpoilerItem, _ values: SettingsValues) -> Bool {
    level(values).rank >= item.minimumLevel.rank
  }

  /// List status of a title, "NOTONLIST" without a list entry.
  static func listStatus(_ entry: ListEntry?) -> String {
    entry?.status.rawValue ?? notOnList
  }

  /// Protection is on and applies to the list status of this title.
  static func isProtected(_ entry: ListEntry?, _ values: SettingsValues) -> Bool {
    guard level(values) != .off else { return false }
    return values.spoilerStatus.contains(listStatus(entry))
  }

  /// The episode comes after the list progress (`episode` counted like the progress; nil is not an episode to protect).
  static func isUnwatched(_ entry: ListEntry?, episode: Int?) -> Bool {
    guard let episode else { return false }
    return (entry?.progress ?? 0) < episode
  }

  /// Series content (synopsis, rating, review count, length, spoiler tags) of a protected title.
  static func hidesMedia(_ item: SpoilerItem, entry: ListEntry?, values: SettingsValues = AppSettings.shared.values) -> Bool {
    levelHides(item, values) && isProtected(entry, values)
  }

  /// Content of an episode after the progress of a protected title (thumbnail, description, title, duration).
  static func hidesEpisode(_ item: SpoilerItem, entry: ListEntry?, episode: Int?, values: SettingsValues = AppSettings.shared.values) -> Bool {
    levelHides(item, values) && isProtected(entry, values) && isUnwatched(entry, episode: episode)
  }

  /// AniList tags marked as spoilers: for this title (isMediaSpoiler) from Moderate, in general (isGeneralSpoiler) from Strict.
  static func hidesTag(general: Bool, media: Bool, entry: ListEntry?, values: SettingsValues = AppSettings.shared.values) -> Bool {
    if media && hidesMedia(.mediaSpoilerTags, entry: entry, values: values) { return true }
    return general && hidesMedia(.generalSpoilerTags, entry: entry, values: values)
  }

  /// Episode cards of the feeds show the banner / cover instead of the episode image. Tsumi always did it for the
  /// titles you watch, rewatch, paused or plan before you reach the episode (kept as is when protection is off);
  /// protection adds the statuses selected in its setting.
  static func hidesEpisodeThumbnail(entry: ListEntry?, episode: Int?, values: SettingsValues = AppSettings.shared.values) -> Bool {
    if let entry, let episode, [ListStatus.current, .repeating, .paused, .planning].contains(entry.status), entry.progress < episode {
      return true
    }
    return hidesEpisode(.episodeImage, entry: entry, episode: episode, values: values)
  }

  /// The text, or the placeholder when it is hidden (an empty text stays as it is).
  static func text(_ text: String?, hidden: Bool) -> String? {
    guard hidden, let text, !text.isEmpty else { return text }
    return hiddenText
  }
}

/// What spoiler protection hides of one episode (nothing by default).
struct EpisodeSpoilers: Hashable {
  var image = false
  var title = false
  var description = false
  var duration = false

  static let none = EpisodeSpoilers()

  init() {}

  /// `episode` counted like the list progress (+1 when the series has an episode 0).
  init(entry: ListEntry?, episode: Int?, values: SettingsValues = AppSettings.shared.values) {
    image = SpoilerProtection.hidesEpisode(.episodeImage, entry: entry, episode: episode, values: values)
    title = SpoilerProtection.hidesEpisode(.episodeTitle, entry: entry, episode: episode, values: values)
    description = SpoilerProtection.hidesEpisode(.episodeDescription, entry: entry, episode: episode, values: values)
    duration = SpoilerProtection.hidesEpisode(.duration, entry: entry, episode: episode, values: values)
  }
}
