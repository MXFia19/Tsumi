import Foundation

// Watch Together v2: the pure part of the protocol (common/routes/w2g/PROTOCOL.md). Same rules and texts as the
// Svelte app's common/routes/w2g/components/sync.js, so both apps show the same names, badges and notices and
// elect the same host. No UI, no networking, no player: WatchTogetherClient and the views use it.
//
// Times: media positions are seconds (Double). `…Ms` / `…At` values are milliseconds since the epoch on the local
// clock (`nowMs()`), like Date.now() in the Svelte app.

enum W2GSync {
  static let protocolVersion = 2
  /// `init.client` of this app.
  static let clientName = "tsumi-ios"

  /// `status` heartbeat period (PROTOCOL "Sync check").
  static let heartbeatMs: Double = 3_000
  /// `ping` to every peer every 10 s.
  static let pingMs: Double = 10_000
  /// A member without `status` for 10 s shows "No signal".
  static let noSignalMs: Double = 10_000
  /// A paused or idle member may only report changes: its pings keep it alive this long (sync.js STATIC_SIGNAL_MS).
  static let staticSignalMs: Double = 25_000
  /// "In sync" when |drift| <= 1.5 s.
  static let inSyncSeconds: Double = 1.5
  /// Auto-sync when |drift| > 2 s ...
  static let autoSyncSeconds: Double = 2
  /// ... for two consecutive host heartbeats ...
  static let autoSyncStreak = 2
  /// ... at most once every 10 s.
  static let autoSyncCooldownMs: Double = 10_000
  /// A host request prompt counts as declined after 15 s.
  static let requestTimeoutMs: Double = 15_000
  /// Action notices over the video.
  static let noticeSeconds: Double = 3
  /// "Only the host controls playback" stays a bit longer (it has a button).
  static let blockedNoticeSeconds: Double = 5
  /// Chat bubbles over the video.
  static let bubbleSeconds: Double = 5
  /// Floating reactions.
  static let reactionSeconds: Double = 2.6
  /// Default length of "Start together".
  static let countdownDefaultSeconds = 3
  /// A local seek smaller than this is a player fix-up, not a user action.
  static let seekThresholdSeconds: Double = 0.5
  /// Longest display name typed by an anonymous user.
  static let maxNameLength = 32

  /// The only reactions allowed on the wire (anything else is dropped).
  static let reactions = ["😂", "😮", "😍", "😢", "👏", "🔥", "👀", "❤️"]

  /// Date.now()
  static func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
  }

  // MARK: - Normalization

  /// Positive rate up to 16, else 1.
  static func normalizeRate(_ rate: Double?) -> Double {
    guard let rate, rate.isFinite, rate > 0, rate <= 16 else { return 1 }
    return rate
  }

  /// One of the eight protocol emoji (a bare ❤ is accepted as ❤️), nil otherwise.
  static func normalizeReaction(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    if reactions.contains(trimmed) { return trimmed }
    if trimmed == "\u{2764}" { return "\u{2764}\u{FE0F}" }
    return nil
  }

  /// Countdown length: a whole number of seconds in 1-10; missing or invalid values use the default.
  static func normalizeCountdownSeconds(_ seconds: Double?) -> Int {
    guard let seconds, seconds.isFinite else { return countdownDefaultSeconds }
    // Math.round
    let rounded = (seconds + 0.5).rounded(.down)
    return Int(min(10, max(1, rounded)))
  }

  /// Display name typed by an anonymous user: trimmed, at most 32 characters, nil when empty.
  static func cleanDisplayName(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maxNameLength))
  }

  /// Name shown for a participant: AniList / MAL name, else the typed display name, else "Guest <4 first chars>".
  static func memberName(name: String?, typedName: String?, id: String?) -> String {
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    if let typed = cleanDisplayName(typedName) { return typed }
    if let id, !id.isEmpty { return "Guest \(String(id.prefix(4)))" }
    return "Anonymous"
  }

  // MARK: - Host election

  /// JavaScript `a < b` for strings (UTF-16 code unit order).
  static func jsLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
  }

  /// Host migration: the smallest userId (string comparison) among self and the connected peers.
  static func electHost(_ ids: [String]) -> String? {
    var best: String?
    for id in ids where !id.isEmpty {
      if let current = best {
        if jsLess(id, current) { best = id }
      } else {
        best = id
      }
    }
    return best
  }

  // MARK: - Expected time and drift

  /// expected(M) = s.time + (playing ? (now − r) / 1000 × s.rate + rtt / 2000 : 0)
  static func expectedTime(_ status: W2GStatus, receivedAt: Double, now: Double, rttMs: Double?) -> Double {
    guard status.state == .playing else { return status.time }
    let elapsed = max(0, now - receivedAt) / 1000
    var latency: Double = 0
    if let rttMs, rttMs.isFinite, rttMs > 0 { latency = rttMs / 2000 }
    return status.time + elapsed * normalizeRate(status.rate) + latency
  }

  /// Drift = expected(M) − localTime. Positive: the member is ahead.
  static func drift(expected: Double, localTime: Double) -> Double {
    expected - localTime
  }

  // MARK: - Texts

  /// "12:34", or "1:02:03" past an hour.
  static func formatClock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? seconds : 0
    let total = Int(max(0, value.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    let secText = secs < 10 ? "0\(secs)" : "\(secs)"
    if hours > 0 {
      let minText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
      return "\(hours):\(minText):\(secText)"
    }
    return "\(minutes):\(secText)"
  }

  /// "+1:30" / "-0:05"
  static func formatDelta(_ seconds: Double) -> String {
    let value = seconds.isFinite ? seconds : 0
    let rounded = (value + 0.5).rounded(.down)
    return (rounded < 0 ? "-" : "+") + formatClock(abs(rounded))
  }

  /// Notice / system line of an action; nil for `sync`, which is never announced.
  static func describeAction(name: String, action: W2GAction, time: Double, delta: Double?) -> String? {
    switch action {
    case .pause:
      return "\(name) paused at \(formatClock(time))"
    case .play:
      return "\(name) resumed"
    case .seek:
      var text = "\(name) jumped to \(formatClock(time))"
      if let delta, delta.isFinite { text += " (\(formatDelta(delta)))" }
      return text
    case .sync:
      return nil
    }
  }

  /// Chat line of a request.
  static func describeRequest(name: String, kind: W2GRequestKind, time: Double?) -> String {
    switch kind {
    case .pause: return "\(name) asked to pause"
    case .play: return "\(name) asked to resume"
    case .seek: return "\(name) asked to jump to \(formatClock(time ?? 0))"
    }
  }

  /// Host prompt text of a request.
  static func requestPrompt(name: String, kind: W2GRequestKind, time: Double?) -> String {
    switch kind {
    case .pause: return "\(name) wants to pause"
    case .play: return "\(name) wants to resume"
    case .seek: return "\(name) wants to jump to \(formatClock(time ?? 0))"
    }
  }

  /// Action of a v1 `player` event (no `action` field): a play state change, else a seek.
  static func inferAction(previousPaused: Bool?, nextPaused: Bool) -> W2GAction {
    guard let previousPaused, previousPaused == nextPaused else {
      return nextPaused ? .pause : .play
    }
    return .seek
  }

  // MARK: - Badges

  /// Label of our own row.
  static func selfBadge(_ local: W2GLocalStatus?) -> W2GBadge {
    guard let state = local?.state else { return W2GBadge(kind: .idle, text: "Not in the player") }
    switch state {
    case .playing: return W2GBadge(kind: .playing, text: "Playing")
    case .paused: return W2GBadge(kind: .paused, text: "Paused")
    case .buffering: return W2GBadge(kind: .buffering, text: "Buffering")
    case .loading: return W2GBadge(kind: .loading, text: "Loading")
    case .idle: return W2GBadge(kind: .idle, text: "Not in the player")
    }
  }

  /// Sync badge of another member compared with our own player.
  /// - Parameters:
  ///   - protocolVersion: 1 when its `init` had no `protocol` (v1 client), nil before any `init`.
  ///   - lastSeen: when anything was last received from it (pings included).
  static func syncBadge(signal: W2GSignal, protocolVersion: Int?, lastSeen: Double?, local: W2GLocalStatus?, now: Double) -> W2GBadge {
    guard let status = signal.status else {
      if protocolVersion == 1 { return W2GBadge(kind: .old, text: "Old version") }
      return W2GBadge(kind: .nosignal, text: "No signal")
    }
    let receivedAt = signal.receivedAt ?? 0
    if now - receivedAt > noSignalMs {
      let isStatic = status.state == .paused || status.state == .idle
      let alive = isStatic && (lastSeen.map { now - $0 <= staticSignalMs } ?? false)
      if !alive { return W2GBadge(kind: .nosignal, text: "No signal") }
    }

    switch status.state {
    case .idle: return W2GBadge(kind: .idle, text: "Not in the player")
    case .loading: return W2GBadge(kind: .loading, text: "Loading")
    case .buffering: return W2GBadge(kind: .buffering, text: "Buffering")
    case .playing, .paused: break
    }

    // We are not watching: nothing to compare with, show what the member does.
    guard let local, local.state != .idle, local.state != .loading else {
      return status.state == .playing ? W2GBadge(kind: .playing, text: "Playing") : W2GBadge(kind: .paused, text: "Paused")
    }

    if status.mediaKey != local.mediaKey { return W2GBadge(kind: .other, text: "Other episode") }

    let expected = expectedTime(status, receivedAt: signal.receivedAt ?? now, now: now, rttMs: signal.rtt)
    let localTime = expectedTime(local.status, receivedAt: local.at, now: now, rttMs: 0)
    let value = drift(expected: expected, localTime: localTime)
    let samePlayState = (status.state == .playing) == (local.state == .playing)
    if samePlayState && abs(value) <= inSyncSeconds {
      return W2GBadge(kind: .sync, text: "In sync", drift: value)
    }
    let amount = String(format: "%.1f", (abs(value) * 10 + 0.5).rounded(.down) / 10)
    if value >= 0 { return W2GBadge(kind: .ahead, text: "+\(amount) s ahead", drift: value) }
    return W2GBadge(kind: .behind, text: "\(amount) s behind", drift: value)
  }

  // MARK: - Auto-sync

  /// One auto-sync decision, made on each heartbeat received from the host. A non-host whose drift against the
  /// host stays above 2 s while both play the same mediaKey for two consecutive heartbeats seeks to expected(host),
  /// at most once every 10 s.
  static func autoSyncStep(
    _ memory: W2GAutoSyncMemory,
    enabled: Bool,
    isHost: Bool,
    hostStatus: W2GStatus?,
    hostReceivedAt: Double,
    hostRtt: Double?,
    local: W2GLocalStatus?,
    now: Double
  ) -> W2GAutoSyncResult {
    let idle = W2GAutoSyncResult(memory: W2GAutoSyncMemory(streak: 0, lastSyncAt: memory.lastSyncAt), seekTo: nil)
    guard enabled, !isHost, let hostStatus, let local else { return idle }
    guard hostStatus.state == .playing, local.state == .playing else { return idle }
    guard hostStatus.mediaKey == local.mediaKey else { return idle }

    let expected = expectedTime(hostStatus, receivedAt: hostReceivedAt, now: now, rttMs: hostRtt)
    let localTime = expectedTime(local.status, receivedAt: local.at, now: now, rttMs: 0)
    guard abs(drift(expected: expected, localTime: localTime)) > autoSyncSeconds else { return idle }

    let streak = memory.streak + 1
    if streak >= autoSyncStreak && now - memory.lastSyncAt >= autoSyncCooldownMs {
      return W2GAutoSyncResult(memory: W2GAutoSyncMemory(streak: 0, lastSyncAt: now), seekTo: expected)
    }
    return W2GAutoSyncResult(memory: W2GAutoSyncMemory(streak: streak, lastSyncAt: memory.lastSyncAt), seekTo: nil)
  }

  /// Where a non-host should be to follow the host: from its last `status`, else from its last applied `player`
  /// event (v1 host). nil when nothing usable is known. `mediaKey` is nil when it comes from a `player` event.
  static func hostReference(status: W2GStatus?, receivedAt: Double?, rttMs: Double?, lastPlayer: W2GHostPlayer?, now: Double) -> W2GHostTarget? {
    if let status {
      // A paused status stays true until the next one; a playing one is only extrapolated for a while.
      let fresh = status.state == .paused || now - (receivedAt ?? 0) <= noSignalMs * 3
      if fresh && (status.state == .playing || status.state == .paused || status.state == .buffering) {
        return W2GHostTarget(
          time: expectedTime(status, receivedAt: receivedAt ?? now, now: now, rttMs: rttMs),
          // A buffering host still means to play.
          paused: status.state == .paused,
          mediaKey: status.mediaKey
        )
      }
    }
    if let lastPlayer, lastPlayer.time.isFinite {
      let elapsed = lastPlayer.paused ? 0 : max(0, now - lastPlayer.at) / 1000 * normalizeRate(lastPlayer.rate)
      return W2GHostTarget(time: lastPlayer.time + elapsed, paused: lastPlayer.paused, mediaKey: nil)
    }
    return nil
  }
}

// MARK: - Protocol values

/// `host.mode`.
enum W2GMode: String {
  case everyone
  case host

  /// Anything but "host" is "everyone".
  static func normalize(_ value: String?) -> W2GMode {
    value == "host" ? .host : .everyone
  }
}

/// `status.state`.
enum W2GPlaybackState: String {
  case playing
  case paused
  case buffering
  case loading
  case idle

  static func normalize(_ value: String?) -> W2GPlaybackState? {
    guard let value else { return nil }
    return W2GPlaybackState(rawValue: value)
  }
}

/// `player.action`.
enum W2GAction: String {
  case play
  case pause
  case seek
  /// A correction that is never announced.
  case sync
}

/// `request.kind`.
enum W2GRequestKind: String {
  case pause
  case play
  case seek
}

/// A member's last `status`.
struct W2GStatus: Equatable {
  var state: W2GPlaybackState
  var time: Double
  var mediaKey: String
  var rate: Double
}

/// Our own player; `time` was read at `at` (ms).
struct W2GLocalStatus: Equatable {
  var state: W2GPlaybackState
  var time: Double
  var mediaKey: String
  var rate: Double
  var at: Double

  var status: W2GStatus {
    W2GStatus(state: state, time: time, mediaKey: mediaKey, rate: rate)
  }

  static func idle(at now: Double) -> W2GLocalStatus {
    W2GLocalStatus(state: .idle, time: 0, mediaKey: "", rate: 1, at: now)
  }
}

/// Last `status` (and when it arrived) and last round-trip time of a member, by userId.
struct W2GSignal: Equatable {
  var status: W2GStatus?
  var receivedAt: Double?
  var rtt: Double?
}

/// Sync badge of a member row.
struct W2GBadge: Equatable {
  enum Kind: String {
    case old, nosignal, idle, loading, buffering, other, sync, ahead, behind, playing, paused
  }

  var kind: Kind
  var text: String
  var drift: Double?
}

struct W2GAutoSyncMemory: Equatable {
  var streak: Int = 0
  var lastSyncAt: Double = -Double.infinity
}

struct W2GAutoSyncResult: Equatable {
  var memory: W2GAutoSyncMemory
  /// Position to seek to (expected(host)), nil when nothing is to be done.
  var seekTo: Double?
}

/// Last applied `player` event of the host (reference when the host sends no `status`, e.g. a v1 host).
struct W2GHostPlayer: Equatable {
  var time: Double
  var paused: Bool
  var rate: Double
  var at: Double
}

/// Where the host is expected to be now.
struct W2GHostTarget: Equatable {
  var time: Double
  var paused: Bool
  /// nil when only a `player` event is known (no mediaKey to compare).
  var mediaKey: String?
}
