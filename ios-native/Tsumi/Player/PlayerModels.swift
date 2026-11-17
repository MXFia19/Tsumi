import Foundation

// Input/output types and small helpers of the native video player.
// Svelte reference: common/routes/player/PlayerPage.svelte, common/components/MediaHandler.svelte,
// common/modules/util.js (toTS), common/modules/anime/anime.js (getMediaMaxEp).

/// One episode ready to play. Mirrors the single "file" the Svelte app builds in
/// ExtensionResults.launchPlayer (url, streamHeaders, streamServers, activeServerIndex, subtitle, media/episode).
struct PlaybackSession: Hashable {
  var media: Media
  var episode: EpisodeRef
  /// Episode title shown under the media title (MediaHandler nowPlaying.episodeTitle).
  var episodeTitle: String?
  var servers: [StreamServer]
  var selectedServer: Int
  /// External subtitle returned by the extension (WebVTT, SRT, ASS/SSA, MicroDVD).
  var subtitleURL: URL?
  /// Headers used to fetch `subtitleURL`; defaults to the selected server headers (Svelte passes streamHeaders).
  var subtitleHeaders: [String: String]?
  /// Saved position to resume from (the player starts 5 s earlier, like loadAnimeProgress).
  var startTime: Double?
  /// Filler/recap flags when already known; nil = looked up on Jikan like the Svelte filler prompt.
  var isFiller: Bool?
  var isRecap: Bool?
  /// The media has an episode 0 (prologue), like MediaHandler `zeroEpisode` (checkForZero). nil = derived from
  /// the episode list (an entry numbered 0).
  var zeroEpisode: Bool?

  init(
    media: Media,
    episode: EpisodeRef,
    episodeTitle: String? = nil,
    servers: [StreamServer],
    selectedServer: Int = 0,
    subtitleURL: URL? = nil,
    subtitleHeaders: [String: String]? = nil,
    startTime: Double? = nil,
    isFiller: Bool? = nil,
    isRecap: Bool? = nil,
    zeroEpisode: Bool? = nil
  ) {
    self.media = media
    self.episode = episode
    self.episodeTitle = episodeTitle
    self.servers = servers
    self.selectedServer = selectedServer
    self.subtitleURL = subtitleURL
    self.subtitleHeaders = subtitleHeaders
    self.startTime = startTime
    self.isFiller = isFiller
    self.isRecap = isRecap
    self.zeroEpisode = zeroEpisode
  }

  /// Convenience initializer from an extension `StreamResult`.
  init(
    media: Media,
    episode: EpisodeRef,
    episodeTitle: String? = nil,
    result: StreamResult,
    selectedServer: Int = 0,
    startTime: Double? = nil
  ) {
    self.init(
      media: media,
      episode: episode,
      episodeTitle: episodeTitle,
      servers: result.servers,
      selectedServer: selectedServer,
      subtitleURL: result.subtitleURL,
      startTime: startTime
    )
  }

  var currentServer: StreamServer? {
    servers.indices.contains(selectedServer) ? servers[selectedServer] : servers.first
  }
}

/// Position report sent to `PlayerController.onProgress` (setAnimeProgress in animeprogress.js).
struct PlayerProgressSnapshot: Hashable {
  var media: Media
  var episode: EpisodeRef
  var currentTime: Double
  /// "safeduration": the real duration, or the current time when the duration is unknown.
  var duration: Double

  /// Watched percentage (0-100), rounded up like liveAnimeEpisodeProgress.
  var percent: Int {
    guard duration > 0, currentTime.isFinite, duration.isFinite else { return 0 }
    let value = (currentTime / duration * 100).rounded(.up)
    return Int(min(max(value, 0), 100))
  }
}

enum PlayerPhase: Equatable {
  case loading
  case ready
  case failed(PlayerFailure)
}

/// Playback error shown in the player (checkError toasts in PlayerPage.svelte).
struct PlayerFailure: Equatable {
  var title: String
  var message: String
  var detail: String?

  static let noServers = PlayerFailure(
    title: "No Stream Available",
    message: "This source did not return any playable server. Try a different source from another extension.",
    detail: nil
  )

  static func from(_ error: NSError?) -> PlayerFailure {
    guard let error else {
      return PlayerFailure(title: "Video Codec Unsupported", message: unsupportedMessage, detail: nil)
    }
    let chain = errorChain(error)
    let detail = error.localizedDescription
    if chain.contains(where: { $0.domain == NSURLErrorDomain || $0.domain == "CoreMediaErrorDomain" }) {
      return PlayerFailure(
        title: "Video Network Error",
        message: "A network error caused the video download to fail part-way.",
        detail: detail
      )
    }
    if chain.contains(where: { $0.domain == AVFoundationErrorDomainName && $0.code == decodeFailedCode }) {
      return PlayerFailure(
        title: "Video Decode Error",
        message: "The video playback was aborted due to a corruption problem.",
        detail: detail
      )
    }
    return PlayerFailure(title: "Video Codec Unsupported", message: unsupportedMessage, detail: detail)
  }

  private static let unsupportedMessage = "The video could not be loaded, either because the server or network failed or because the format is not supported. Try a different source from another extension."
  /// AVFoundationErrorDomain / AVError.decodeFailed, kept as literals so this file only needs Foundation.
  private static let AVFoundationErrorDomainName = "AVFoundationErrorDomain"
  private static let decodeFailedCode = -11821

  private static func errorChain(_ error: NSError) -> [NSError] {
    var result = [error]
    var current = error
    while result.count < 6, let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
      result.append(underlying)
      current = underlying
    }
    return result
  }
}

/// Thrown by `PlayerController.loadEpisode` when the app took the episode over itself (for example it opened
/// the extension picker because the remembered source failed): the player shows no error and stays paused.
struct PlayerEpisodeHandedOff: Error {}

/// "Up next" card shown during the end credits / preview while autoplay is on (`PlayerController.upNext`).
struct PlayerUpNext: Equatable {
  var episode: EpisodeRef
  /// Title of the next episode (nil when unknown or hidden by spoiler protection).
  var title: String?
  /// Video time at which the next episode starts: the countdown follows playback (it waits while paused).
  var startsAt: Double
}

/// A saved position was restored when the episode loaded (`PlayerController.resumeChoice`): "Resume" keeps it,
/// "Start Over" goes back to the beginning.
struct PlayerResumeChoice: Identifiable, Equatable {
  let id = UUID()
  var time: Double
}

/// Short message shown at the top of the player (replaces svelte-sonner toasts).
struct PlayerNotice: Identifiable, Equatable {
  let id = UUID()
  var title: String
  var message: String?
  var isError: Bool = false
}

/// Watch Together v2 `status` of the player (`PlayerController.syncSnapshot`).
struct PlayerSyncSnapshot {
  enum State {
    case playing
    case paused
    case buffering
    case loading
    case idle
  }

  var state: State
  var time: Double
  var rate: Double
  var media: Media
  var episode: EpisodeRef
  /// "Extension · Server" (Watch Together v2.1 `status.source`), "" when unknown.
  var source: String
}

/// Watch Together v2: a play / pause / seek the user made (`PlayerController.onSyncAction`).
struct PlayerSyncAction {
  enum Kind {
    case play
    case pause
    case seek
  }

  var kind: Kind
  /// Position after the action (seconds).
  var time: Double
  var paused: Bool
  /// Seek distance in seconds ("jumped to 12:34 (+1:30)"), nil for play / pause.
  var delta: Double?
  var rate: Double
  /// A pause made by the system (app sent to the background, audio interruption), not by the user.
  var automatic: Bool
}

/// Audio or embedded subtitle track (AVMediaSelectionOption).
struct PlayerTrackOption: Identifiable, Hashable {
  let id: Int
  let name: String
  let languageTag: String?
}

/// Audio track picked from the audio menu, remembered per show: display name and language tag.
struct PlayerAudioMemory: Hashable {
  var name: String
  var language: String?
}

enum PlayerSubtitleChoice: Hashable {
  case off
  /// Index in `PlayerController.embeddedSubtitleTracks` (rendered by AVPlayer).
  case embedded(Int)
  /// Id of a `PlayerExternalSubtitleTrack` (rendered by the overlay).
  case external(Int)
}

struct PlayerStatLine: Identifiable, Hashable {
  var id: String { label }
  let label: String
  let value: String
}

/// Chapter drawn on the scrubber, in 0...1 fractions of the duration.
struct PlayerScrubberSegment: Identifiable, Hashable {
  var id: String { "\(start)-\(end)" }
  let start: Double
  let end: Double
  let skippable: Bool
}

/// Flags of the current episode (Jikan filler/recap, MediaHandler/promptFiller).
struct PlayerEpisodeFlags: Hashable, Sendable {
  var isFiller: Bool
  var isRecap: Bool

  /// "Filler" / "Recap", the word used in "This episode has been marked as a ...".
  var promptLabel: String? {
    if isFiller { return "Filler" }
    if isRecap { return "Recap" }
    return nil
  }
}

/// iOS replacement of the desktop "External Player" option: hands the stream URL to another app.
enum PlayerExternalApp: String, CaseIterable, Identifiable {
  case vlc
  case infuse

  var id: String { rawValue }

  var name: String {
    switch self {
    case .vlc: return "VLC"
    case .infuse: return "Infuse"
    }
  }

  func url(for stream: URL) -> URL? {
    guard let encoded = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    switch self {
    case .vlc: return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
    case .infuse: return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
    }
  }
}

/// Corner where the in-app miniplayer docks (Miniplayer.svelte `position`: "top left", "bottom right"...).
enum PlayerMiniPlayerCorner: String, CaseIterable {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing

  var isTop: Bool { self == .topLeading || self == .topTrailing }
  var isLeading: Bool { self == .topLeading || self == .bottomLeading }

  static func nearest(top: Bool, leading: Bool) -> PlayerMiniPlayerCorner {
    switch (top, leading) {
    case (true, true): return .topLeading
    case (true, false): return .topTrailing
    case (false, true): return .bottomLeading
    case (false, false): return .bottomTrailing
    }
  }
}

/// Player-only preferences that are not part of Core `SettingsValues` (stored in UserDefaults).
/// The settings screen can bind to these static properties directly.
enum PlayerPreferences {
  private static let autoPictureInPictureKey = "tsumi.player.autoPictureInPicture"
  private static let lastSubtitleKey = "tsumi.player.lastSubtitle"
  /// Audio track picked per show ([mediaKey: ["name": display name, "lang": language tag]]).
  static let lastAudioKey = "tsumi.player.lastAudio"
  private static let playbackRateKey = "tsumi.player.playbackRate"
  private static let miniPlayerCornerKey = "tsumi.player.miniPlayerCorner"
  private static let subtitleOffsetKey = "tsumi.player.subtitleOffset"
  /// Shows whose subtitle offset is kept (the oldest are forgotten past it).
  private static let subtitleOffsetLimit = 200

  /// Settings reset: removes the auto Picture in Picture, last subtitle and audio track per media, subtitle offset
  /// per show and playback rate keys, so every value falls back to its default (and the chapter source key of older
  /// versions). The miniplayer position is a cache, not a setting.
  static func resetAll() {
    let defaults = UserDefaults.standard
    for key in ["tsumi.player.chapterSource", autoPictureInPictureKey, lastSubtitleKey, lastAudioKey, playbackRateKey, subtitleOffsetKey] {
      defaults.removeObject(forKey: key)
    }
  }

  /// "Subtitle Offset" remembered per show (seconds, 0 when none).
  static func subtitleOffset(for mediaKey: String) -> Double {
    let stored = UserDefaults.standard.dictionary(forKey: subtitleOffsetKey) as? [String: [Double]]
    guard let value = stored?[mediaKey]?.first, value.isFinite else { return 0 }
    return min(max(value, -600), 600)
  }

  /// Stores [offset, time saved]; 0 forgets the show.
  static func setSubtitleOffset(_ value: Double, for mediaKey: String) {
    guard value.isFinite else { return }
    var stored = (UserDefaults.standard.dictionary(forKey: subtitleOffsetKey) as? [String: [Double]]) ?? [:]
    if value == 0 {
      stored.removeValue(forKey: mediaKey)
    } else {
      stored[mediaKey] = [value, Date().timeIntervalSince1970]
      if stored.count > subtitleOffsetLimit {
        let oldest = stored.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(stored.count - subtitleOffsetLimit)
        for (key, _) in oldest { stored.removeValue(forKey: key) }
      }
    }
    if stored.isEmpty {
      UserDefaults.standard.removeObject(forKey: subtitleOffsetKey)
    } else {
      UserDefaults.standard.set(stored, forKey: subtitleOffsetKey)
    }
  }

  /// Start Picture in Picture automatically when the app goes to background while playing.
  /// Off by default so "Pause On Lost Focus" (`playerPause`, on by default) behaves like the Svelte app:
  /// leaving the app pauses, unless Picture in Picture runs (handleVisibility skips the pause in PiP).
  static var autoPictureInPicture: Bool {
    get { UserDefaults.standard.object(forKey: autoPictureInPictureKey) as? Bool ?? false }
    set { UserDefaults.standard.set(newValue, forKey: autoPictureInPictureKey) }
  }

  /// Playback speed kept between episodes (PlayerPage.svelte keeps `playbackRate` for the app session).
  static var playbackRate: Float {
    get {
      guard let stored = UserDefaults.standard.object(forKey: playbackRateKey) as? Double,
            stored.isFinite, stored >= 0.1, stored <= 4 else { return 1 }
      return Float(stored)
    }
    set {
      guard newValue.isFinite else { return }
      if newValue == 1 {
        UserDefaults.standard.removeObject(forKey: playbackRateKey)
      } else {
        UserDefaults.standard.set(Double(newValue), forKey: playbackRateKey)
      }
    }
  }

  /// Corner of the in-app miniplayer (cache 'posMiniplayer' in Miniplayer.svelte), "bottom right" by default.
  static var miniPlayerCorner: PlayerMiniPlayerCorner {
    get {
      guard let raw = UserDefaults.standard.string(forKey: miniPlayerCornerKey) else { return .bottomTrailing }
      return PlayerMiniPlayerCorner(rawValue: raw) ?? .bottomTrailing
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: miniPlayerCornerKey) }
  }

  /// Last subtitle track picked per media ("OFF" or the track name), like caches.HISTORY 'lastSubtitle'.
  static func lastSubtitle(for mediaKey: String) -> String? {
    let stored = UserDefaults.standard.dictionary(forKey: lastSubtitleKey) as? [String: String]
    return stored?[mediaKey]
  }

  static func setLastSubtitle(_ value: String, for mediaKey: String) {
    var stored = (UserDefaults.standard.dictionary(forKey: lastSubtitleKey) as? [String: String]) ?? [:]
    stored[mediaKey] = value
    UserDefaults.standard.set(stored, forKey: lastSubtitleKey)
  }

  /// Last audio track picked from the audio menu for a show (same scope as `lastSubtitle`).
  static func lastAudio(for mediaKey: String) -> PlayerAudioMemory? {
    let stored = UserDefaults.standard.dictionary(forKey: lastAudioKey) as? [String: [String: String]]
    guard let value = stored?[mediaKey], let name = value["name"] else { return nil }
    return PlayerAudioMemory(name: name, language: PlayerLanguage.normalizedTag(value["lang"]))
  }

  static func setLastAudio(_ memory: PlayerAudioMemory, for mediaKey: String) {
    var stored = (UserDefaults.standard.dictionary(forKey: lastAudioKey) as? [String: [String: String]]) ?? [:]
    var value = ["name": memory.name]
    if let language = PlayerLanguage.normalizedTag(memory.language) { value["lang"] = language }
    stored[mediaKey] = value
    UserDefaults.standard.set(stored, forKey: lastAudioKey)
  }
}

/// Port of toTS (common/modules/util.js).
enum PlayerTime {
  /// full: 1 = h:mm:ss.cc, 2 = h:mm:ss, 3 = mm:ss, 0 = m:ss (hours are added when needed).
  static func format(_ seconds: Double, full: Int = 0) -> String {
    guard seconds.isFinite, seconds >= 0 else {
      switch full {
      case 1: return "0:00:00.00"
      case 2: return "0:00:00"
      case 3: return "00:00"
      default: return "0:00"
      }
    }
    let total = min(seconds, 359_999_999)
    let hours = Int(total / 3600)
    let minutes = Int(total / 60) - hours * 60
    let minuteText = (minutes < 10 && (hours > 0 || full != 0)) ? "0\(minutes)" : "\(minutes)"
    let secondText: String
    if full == 1 {
      let value = total.truncatingRemainder(dividingBy: 60)
      let formatted = String(format: "%.2f", value)
      secondText = value < 10 ? "0" + formatted : formatted
    } else {
      let value = Int(total.truncatingRemainder(dividingBy: 60))
      secondText = value < 10 ? "0\(value)" : "\(value)"
    }
    if hours > 0 || full == 1 || full == 2 {
      return "\(hours):\(minuteText):\(secondText)"
    }
    return "\(minuteText):\(secondText)"
  }

  /// Format used by the player time display: h:mm:ss above one hour, mm:ss otherwise.
  static func full(for duration: Double) -> Int {
    duration > 3600 ? 2 : 3
  }
}

/// Matches AVFoundation language tags (BCP 47, "ja", "en-US", sometimes "jpn") against the
/// ISO 639-2 codes stored in the settings (subtitleLanguage / audioLanguage).
enum PlayerLanguage {
  private static let twoLetter: [String: [String]] = [
    "eng": ["en"], "jpn": ["ja"], "chi": ["zh"], "zho": ["zh"], "por": ["pt"], "spa": ["es"],
    "lat": ["es"], "ger": ["de"], "deu": ["de"], "pol": ["pl"], "cze": ["cs"], "ces": ["cs"],
    "dan": ["da"], "gre": ["el"], "ell": ["el"], "fin": ["fi"], "fre": ["fr"], "fra": ["fr"],
    "hun": ["hu"], "ita": ["it"], "kor": ["ko"], "dut": ["nl"], "nld": ["nl"],
    "nor": ["no", "nb", "nn"], "nob": ["nb", "no"], "rum": ["ro"], "ron": ["ro"], "rus": ["ru"],
    "slo": ["sk"], "slk": ["sk"], "swe": ["sv"], "ara": ["ar"], "idn": ["id"], "ind": ["id"]
  ]

  static func matches(tag: String?, wanted: String) -> Bool {
    guard let tag, !tag.isEmpty, !wanted.isEmpty else { return false }
    let lower = tag.lowercased()
    let primary = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
    let wantedLower = wanted.lowercased()
    if wantedLower == "lat" {
      return primary == "es" && (lower.contains("419") || lower.contains("mx") || lower.contains("lat"))
    }
    if primary == wantedLower { return true }
    let candidates = twoLetter[wantedLower] ?? []
    if candidates.contains(primary) { return true }
    if primary.count == 3, let codes = twoLetter[primary] {
      return !Set(codes).isDisjoint(with: candidates)
    }
    return false
  }

  /// English is the fallback of the Svelte subtitle selection (a track without language counts as English).
  static func isEnglishOrUnknown(_ tag: String?) -> Bool {
    guard let tag, !tag.isEmpty else { return true }
    return matches(tag: tag, wanted: "eng")
  }

  /// Trimmed tag, nil when empty or undetermined ("und").
  static func normalizedTag(_ tag: String?) -> String? {
    guard let trimmed = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
          trimmed.lowercased() != "und" else { return nil }
    return trimmed
  }

  /// Primary subtag, lowercased ("pt-BR" -> "pt").
  static func primary(_ tag: String) -> String {
    let lower = tag.lowercased()
    return lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
  }

  /// Same language for two tags in any form ("ja", "ja-JP", "jpn").
  static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = normalizedTag(lhs), let rhs = normalizedTag(rhs) else { return false }
    return matches(tag: lhs, wanted: primary(rhs)) || matches(tag: rhs, wanted: primary(lhs))
  }

  /// Audio track picked when a stream with several audio tracks loads (checkAudio plus the per-show memory): the
  /// track remembered for the show (same name and language, else same language), then the preferred audio
  /// language setting, then Japanese. Nil keeps the stream's default track.
  static func preferredAudioTrack(_ tracks: [PlayerTrackOption], remembered: PlayerAudioMemory?, preferred: String) -> Int? {
    if let remembered {
      let name = remembered.name.lowercased()
      if let language = normalizedTag(remembered.language) {
        // Same name and language, else the same tag, else the same language in another form ("ja" / "jpn").
        if let match = tracks.first(where: { $0.name.lowercased() == name && sameLanguage($0.languageTag, language) })
            ?? tracks.first(where: { normalizedTag($0.languageTag)?.lowercased() == language.lowercased() })
            ?? tracks.first(where: { sameLanguage($0.languageTag, language) }) {
          return match.id
        }
      } else if let match = tracks.first(where: { $0.name.lowercased() == name && normalizedTag($0.languageTag) == nil }) {
        // A track without language: the same name, also without language.
        return match.id
      }
    }
    if let match = tracks.first(where: { matches(tag: $0.languageTag, wanted: preferred) }) { return match.id }
    return tracks.first(where: { matches(tag: $0.languageTag, wanted: "jpn") })?.id
  }

  /// Audio menu label: the track name, plus its language when the name does not already say it ("Main (fr)";
  /// "Japanese" or "English (en)" stay as they are).
  static func audioLabel(name: String, tag: String?) -> String {
    guard let tag = normalizedTag(tag), !mentionsLanguage(name, tag: tag) else { return name }
    return "\(name) (\(tag))"
  }

  /// The name contains the tag ("en-US"), its code ("en", "jpn") or the language name in English, in the device
  /// language or in the language itself ("Japanese", "Japonais", the Japanese name).
  static func mentionsLanguage(_ name: String, tag: String) -> Bool {
    let lowerName = name.lowercased()
    let code = primary(tag)
    let words = lowerName.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
    if words.contains(tag.lowercased()) || words.contains(code) { return true }
    if words.contains(where: { $0.count == 3 && sameLanguage($0, code) }) { return true }
    for locale in [Locale(identifier: "en"), Locale.current, Locale(identifier: code)] {
      if let language = locale.localizedString(forLanguageCode: code)?.lowercased(), !language.isEmpty, lowerName.contains(language) {
        return true
      }
    }
    return false
  }
}

enum PlayerEpisodeMath {
  /// getMediaMaxEp (common/modules/anime/anime.js) with the fields available on the native `Media`.
  static func maxEpisode(_ media: Media) -> Int {
    let value = max(media.episodes ?? 0, media.nextAiring?.episode ?? 0)
    if value > 0 { return value }
    if media.status == .releasing { return media.listEntry?.progress ?? 1 }
    return 0
  }
}

enum PlayerText {
  /// Equivalent of the Svelte regex `(?<![\d.])N(?![\d.])`: the episode title already mentions the number.
  static func containsStandalone(number: Int, in text: String) -> Bool {
    let needle = String(number)
    var searchStart = text.startIndex
    while searchStart < text.endIndex, let range = text.range(of: needle, range: searchStart..<text.endIndex) {
      let beforeOK = range.lowerBound == text.startIndex || !isDigitOrDot(text[text.index(before: range.lowerBound)])
      let afterOK = range.upperBound == text.endIndex || !isDigitOrDot(text[range.upperBound])
      if beforeOK && afterOK { return true }
      searchStart = range.upperBound
    }
    return false
  }

  private static func isDigitOrDot(_ character: Character) -> Bool {
    character == "." || ("0"..."9").contains(character)
  }

  /// Rejects empty titles and the "undefined" strings the Svelte app filters out.
  static func cleanedTitle(_ title: String?) -> String? {
    guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
          trimmed.lowercased() != "undefined" else { return nil }
    return trimmed
  }
}

/// Keyboard shortcuts of the player (svelte-keybinds defaults in PlayerPage.svelte), shown by the help overlay.
struct PlayerKeybind: Identifiable, Hashable, Sendable {
  var id: String { key }
  let key: String
  let description: String

  static let all: [PlayerKeybind] = [
    PlayerKeybind(key: "Space", description: "Play/Pause (Hold to Speed Up)"),
    PlayerKeybind(key: "N", description: "Next Episode"),
    PlayerKeybind(key: "B", description: "Previous Episode"),
    PlayerKeybind(key: "←", description: "Rewind"),
    PlayerKeybind(key: "→", description: "Seek"),
    PlayerKeybind(key: "↑", description: "Volume Up"),
    PlayerKeybind(key: "↓", description: "Volume Down"),
    PlayerKeybind(key: "M", description: "Toggle Mute"),
    PlayerKeybind(key: "S", description: "Skip Intro/90s"),
    PlayerKeybind(key: "C", description: "Cycle Subtitles"),
    PlayerKeybind(key: "P", description: "Toggle Picture in Picture"),
    PlayerKeybind(key: "W", description: "Toggle Video Cover"),
    PlayerKeybind(key: "I", description: "Toggle Stats"),
    PlayerKeybind(key: "O", description: "Toggle Now Playing"),
    PlayerKeybind(key: "H", description: "Toggle Episode List"),
    PlayerKeybind(key: "X", description: "Save Screenshot to Clipboard"),
    PlayerKeybind(key: "[", description: "Decrease Playback Rate"),
    PlayerKeybind(key: "]", description: "Increase Playback Rate"),
    PlayerKeybind(key: "\\", description: "Reset Playback Rate"),
    PlayerKeybind(key: "`", description: "Toggle Keybinds")
  ]
}
