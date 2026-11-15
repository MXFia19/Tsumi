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
  static func syncBadge(
    signal: W2GSignal,
    protocolVersion: Int?,
    lastSeen: Double?,
    local: W2GLocalStatus?,
    now: Double,
    introducedAt: Double? = nil
  ) -> W2GBadge {
    guard let status = signal.status else {
      if protocolVersion == 1 { return W2GBadge(kind: .old, text: "Old version") }
      // v2.3: a v2 member is "No signal" only once 10 s passed after its `init` without any status.
      if let introducedAt, now - introducedAt < noSignalMs { return W2GBadge(kind: .connecting, text: "Connecting\u{2026}") }
      return W2GBadge(kind: .nosignal, text: "No signal")
    }
    let receivedAt = signal.receivedAt ?? 0
    if now - receivedAt > noSignalMs {
      let isStatic = status.state == .paused || status.state == .idle
      let alive = isStatic && (lastSeen.map { now - $0 <= staticSignalMs } ?? false)
      if !alive { return W2GBadge(kind: .nosignal, text: "No signal") }
    }

    if status.state == .idle { return W2GBadge(kind: .idle, text: "Not in the player") }
    // v2.2: an independent member shows no drift (same order as sync.js).
    if !status.following { return W2GBadge(kind: .independent, text: "Watching on their own") }
    switch status.state {
    case .loading: return W2GBadge(kind: .loading, text: "Loading")
    case .buffering: return W2GBadge(kind: .buffering, text: "Buffering")
    case .playing, .paused, .idle: break
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
    guard hostStatus.following, local.following else { return idle }
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

  // MARK: - v2.1 source, presence, invite (sync.js "v2.1"), v2.2 independent watching

  /// The same member and kind announces at most once every 5 s.
  static let presenceDebounceMs: Double = 5_000
  /// "is buffering…" once a buffering period lasts more than 8 s.
  static let bufferingAnnounceMs: Double = 8_000
  /// "lost connection" once "No signal" (no status, no pong) lasted 10 s: 10 s + 10 s without either.
  static let lostConnectionMs: Double = noSignalMs + 10_000
  /// A joined invite whose episode never loads is dropped after this long.
  static let inviteJoinTTLMs: Double = 120_000

  private static let watchingStates: [W2GPlaybackState] = [.loading, .playing, .paused]

  /// `status.source`: extension / addon name, then the server label, joined with " · " (max 80 characters).
  static func formatSource(_ parts: [String?]) -> String {
    let kept = parts.compactMap { part -> String? in
      guard let part else { return nil }
      let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return String(kept.joined(separator: " \u{00B7} ").prefix(80))
  }

  /// w2g.js mediaKey split: "mediaId:episode" or "mediaId:season:episode"; nil otherwise.
  static func parseMediaKey(_ key: String) -> (mediaId: String, season: String?, episode: String)? {
    guard !key.isEmpty else { return nil }
    let parts = key.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }
    if parts.count == 2 { return (mediaId: parts[0], season: nil, episode: parts[1]) }
    if parts.count == 3 { return (mediaId: parts[0], season: parts[1].isEmpty ? nil : parts[1], episode: parts[2]) }
    return nil
  }

  private static func validPart(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty && value != "undefined" && value != "null"
  }

  /// "Episode 5", or "S2 E5" when a season is known; nil without an episode number.
  static func formatEpisode(season: String?, episode: String?) -> String? {
    guard validPart(episode), let episode else { return nil }
    if validPart(season), let season { return "S\(season) E\(episode)" }
    return "Episode \(episode)"
  }

  /// Label of an episode (sync.js episodeLabelOf): "Episode 5" / "S2 E5".
  static func episodeLabel(number: Int, season: Int?, localEpisode: Int?) -> String {
    formatEpisode(season: season.map { String($0) }, episode: String(localEpisode ?? number)) ?? "Episode \(number)"
  }

  /// Label for "Alice switched to {label}": the episode of the new key, or "another title" when the media differs.
  static func switchLabel(from previousKey: String, to newKey: String) -> String {
    guard let next = parseMediaKey(newKey) else { return "another title" }
    if let previous = parseMediaKey(previousKey), previous.mediaId != next.mediaId { return "another title" }
    return formatEpisode(season: next.season, episode: next.episode) ?? "another title"
  }

  /// System line / notice of a presence change.
  static func describePresence(_ event: W2GPresenceEvent, name: String) -> String {
    switch event.kind {
    case .started: return "\(name) started watching"
    case .again: return "\(name) is watching again"
    case .stopped: return "\(name) stopped watching"
    case .switched: return "\(name) switched to \(event.detail.isEmpty ? "another title" : event.detail)"
    case .source: return "\(name) changed source: \(event.detail)"
    case .buffering: return "\(name) is buffering\u{2026}"
    case .lost: return "\(name) lost connection"
    case .independent: return "\(name) is watching on their own"
    case .rejoined: return "\(name) is back in sync"
    case .watching: return "\(name) is watching \(event.detail.isEmpty ? "another title" : event.detail)"
    }
  }

  /// Presence announcements caused by a `status` received from another member (never for ourselves).
  static func presenceAfterStatus(_ memory: W2GPresenceMemory, status: W2GStatus, now: Double) -> W2GPresenceStep {
    let previous = memory.lastStatus
    var events: [W2GPresenceEvent] = []
    if let previous {
      if status.state == .idle && previous.state != .idle {
        events.append(W2GPresenceEvent(kind: .stopped))
      }
      if previous.state == .idle && watchingStates.contains(status.state) {
        events.append(W2GPresenceEvent(kind: .again))
      }
      // v2.2: independent watching.
      if previous.following && !status.following {
        events.append(W2GPresenceEvent(kind: .independent))
      } else if !previous.following && status.following {
        events.append(W2GPresenceEvent(kind: .rejoined))
      }
      let previousKey = previous.mediaKey
      let nextKey = status.mediaKey
      if status.state != .idle && !previousKey.isEmpty && !nextKey.isEmpty && previousKey != nextKey {
        if !status.following {
          // v2.2: "Alice is watching {title · episode}" replaces "switched to".
          let label = status.nowPlaying?.label ?? ""
          events.append(W2GPresenceEvent(kind: .watching, detail: label.isEmpty ? switchLabel(from: previousKey, to: nextKey) : label))
        } else {
          events.append(W2GPresenceEvent(kind: .switched, detail: switchLabel(from: previousKey, to: nextKey)))
        }
      }
      if previousKey == nextKey && !previous.source.isEmpty && !status.source.isEmpty && previous.source != status.source {
        events.append(W2GPresenceEvent(kind: .source, detail: status.source))
      }
    } else if watchingStates.contains(status.state) {
      // The first status after joining only says "started watching".
      events.append(W2GPresenceEvent(kind: .started))
    }
    let buffering = status.state == .buffering
    let continued = buffering && previous?.state == .buffering && memory.bufferingSince != nil
    var next = memory
    next.lastStatus = status
    next.lostAnnounced = false
    next.bufferingSince = buffering ? (continued ? memory.bufferingSince : now) : nil
    next.bufferingAnnounced = continued ? memory.bufferingAnnounced : false
    return debounced(next, events, now: now)
  }

  /// Time-based announcements, checked about once a second: long buffering, lost connection.
  static func presenceTick(_ memory: W2GPresenceMemory, lastStatusAt: Double?, lastPongAt: Double?, now: Double) -> W2GPresenceStep {
    guard let status = memory.lastStatus else { return W2GPresenceStep(memory: memory, events: []) }
    var next = memory
    var events: [W2GPresenceEvent] = []
    if status.state == .buffering, let since = next.bufferingSince, !next.bufferingAnnounced, now - since > bufferingAnnounceMs {
      next.bufferingAnnounced = true
      events.append(W2GPresenceEvent(kind: .buffering))
    }
    let lastSignal = max(lastStatusAt ?? -Double.infinity, lastPongAt ?? -Double.infinity)
    if !next.lostAnnounced && now - lastSignal >= lostConnectionMs {
      next.lostAnnounced = true
      events.append(W2GPresenceEvent(kind: .lost))
    }
    guard !events.isEmpty else { return W2GPresenceStep(memory: next, events: []) }
    return debounced(next, events, now: now)
  }

  private static func debounced(_ memory: W2GPresenceMemory, _ events: [W2GPresenceEvent], now: Double) -> W2GPresenceStep {
    var next = memory
    var kept: [W2GPresenceEvent] = []
    for event in events {
      let key = event.kind.rawValue
      if let last = next.lastAnnounced[key], now - last < presenceDebounceMs { continue }
      next.lastAnnounced[key] = now
      kept.append(event)
    }
    return W2GPresenceStep(memory: next, events: kept)
  }

  /// v2.3 "Invite to watch" on a member row: there is a media to offer (`offeredKey`: ours, else the lobby media
  /// while the lobby is watching); the member is a v2 client that is idle, on another key, independent, or
  /// "No signal" (including no `status` 10 s after its `init`); in `host` mode only the host invites.
  static func canInvite(
    offeredKey: String?,
    mode: W2GMode,
    isHost: Bool,
    isSelf: Bool,
    protocolVersion: Int?,
    badge: W2GBadge.Kind,
    status: W2GStatus?,
    introducedAt: Double?,
    now: Double
  ) -> Bool {
    guard let offeredKey, !offeredKey.isEmpty, !isSelf, (protocolVersion ?? 1) >= protocolVersion2 else { return false }
    if mode == .host && !isHost { return false }
    guard let status else {
      // No `status` yet: "No signal" once 10 s passed since its `init`.
      guard let introducedAt else { return false }
      return now - introducedAt >= noSignalMs
    }
    if badge == .nosignal { return true }
    return status.state == .idle || !status.following || status.mediaKey != offeredKey
  }

  // MARK: - v2.3 lobby watching, join, invite from anywhere

  /// A `media`, `index` or `player` received this soon after its sender's `init` is the lobby state sent to
  /// newcomers (sync.js INITIAL_STATE_MS): remembered, never started (the user presses Join).
  static let sessionStateWindowMs: Double = 5_000
  /// The first-connection Join prompt is shown when the lobby is watching within this time after joining.
  static let firstJoinWindowMs: Double = 20_000
  /// "Invite everyone not watching": one invite every 200 ms.
  static let inviteSpacingSeconds: Double = 0.2

  /// `playing`, `paused`, `buffering` or `loading`: the member has a media open.
  static func isWatchingState(_ state: W2GPlaybackState) -> Bool {
    state == .playing || state == .paused || state == .buffering || state == .loading
  }

  /// The status follows the lobby and is on the lobby key in a watching state.
  static func matchesLobby(_ status: W2GStatus?, lobbyKey: String) -> Bool {
    guard let status, !lobbyKey.isEmpty else { return false }
    return status.following && status.mediaKey == lobbyKey && isWatchingState(status.state)
  }

  /// The lobby's reference member: the host when it watches the lobby media, else the smallest following userId
  /// that does; nil when the lobby is not watching.
  static func lobbyReference(lobbyKey: String?, hostId: String?, candidates: [W2GReferenceCandidate]) -> String? {
    guard let lobbyKey, !lobbyKey.isEmpty else { return nil }
    if let hostId, let host = candidates.first(where: { $0.userId == hostId }) {
      if matchesLobby(host.status, lobbyKey: lobbyKey) { return hostId }
      // Only an idle or independent host (or one without status) hands the reference to another member.
      let hostAway = host.status == nil || host.status?.state == .idle || host.status?.following == false
      if !hostAway { return nil }
    }
    return electHost(candidates.filter { matchesLobby($0.status, lobbyKey: lobbyKey) }.map { $0.userId })
  }

  /// Where the reference is expected to be now, and its play / pause state.
  static func referenceTarget(status: W2GStatus, receivedAt: Double, rttMs: Double?, now: Double) -> W2GHostTarget {
    W2GHostTarget(
      time: expectedTime(status, receivedAt: receivedAt, now: now, rttMs: rttMs),
      paused: status.state == .paused,
      mediaKey: status.mediaKey
    )
  }

  /// The Join card is offered: the lobby is watching (a reference other than us) and we are not on the lobby
  /// media (idle, another key, or independent).
  static func offersJoin(referenceId: String?, selfId: String, localState: W2GPlaybackState, localKey: String, following: Bool, lobbyKey: String) -> Bool {
    guard let referenceId, referenceId != selfId, !lobbyKey.isEmpty else { return false }
    if !following { return true }
    return localState == .idle || localKey != lobbyKey
  }

  private static let protocolVersion2 = 2

  /// sync.js acceptsInvite: for us, not from us; anyone in `everyone` mode, the host only in `host` mode.
  static func acceptsInvite(to: String?, selfId: String, senderId: String, hostId: String?, mode: W2GMode) -> Bool {
    guard let to, to == selfId, senderId != selfId else { return false }
    return mode != .host || senderId == hostId
  }

  /// sync.js inviteTarget: the host's expected position if it is on the same episode, else the inviter's time
  /// plus the elapsed time when it was playing. `fromHost` tells which one was used.
  static func inviteTarget(key: String, time: Double, paused: Bool, receivedAt: Double, host: W2GHostTarget?, now: Double) -> (time: Double, paused: Bool, fromHost: Bool) {
    if let host, let hostKey = host.mediaKey, hostKey == key, host.time.isFinite {
      return (time: host.time, paused: host.paused, fromHost: true)
    }
    let elapsed = paused ? 0 : max(0, now - receivedAt) / 1000
    return (time: max(0, time + elapsed), paused: paused, fromHost: false)
  }

  /// v2.2 `nowPlaying.episode`: "Movie" for a single-episode movie, else "Episode 5" / "S2 E5".
  static func nowPlayingEpisode(isMovie: Bool, episodes: Int?, number: Int, season: Int?, localEpisode: Int?) -> String {
    if isMovie && (episodes ?? 1) <= 1 { return "Movie" }
    return episodeLabel(number: number, season: season, localEpisode: localEpisode)
  }

  /// v2.2 host hand-off when the host stops following: the smallest userId among the connected v2 peers whose
  /// last `status` does not say `following: false`; nil when there is none (the host stays).
  static func handOffTarget(_ peers: [W2GElectionCandidate]) -> String? {
    electHost(peers.filter { ($0.protocolVersion ?? 1) >= protocolVersion2 && $0.following }.map { $0.userId })
  }

  /// v2.2 host migration: members that follow first; everyone when nobody follows.
  static func migrationCandidates(selfId: String, selfFollowing: Bool, peers: [W2GElectionCandidate]) -> [String] {
    var following: [String] = selfFollowing ? [selfId] : []
    following += peers.filter { $0.following }.map { $0.userId }
    if !following.isEmpty { return following }
    return [selfId] + peers.map { $0.userId }
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
  /// v2.1 `status.source`: "Extension · Server", "" when unknown (informational, never compared for sync).
  var source: String = ""
  /// v2.2 `status.following` (true when absent).
  var following: Bool = true
  /// v2.2 `status.nowPlaying`, nil when not in the player.
  var nowPlaying: W2GNowPlaying? = nil
}

/// Our own player; `time` was read at `at` (ms).
struct W2GLocalStatus: Equatable {
  var state: W2GPlaybackState
  var time: Double
  var mediaKey: String
  var rate: Double
  var at: Double
  /// v2.1 `status.source`.
  var source: String = ""
  /// v2.2 `status.following`.
  var following: Bool = true

  var status: W2GStatus {
    W2GStatus(state: state, time: time, mediaKey: mediaKey, rate: rate, source: source, following: following)
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
  /// When the last `pong` arrived (ms), for "lost connection".
  var pongAt: Double?
}

/// Sync badge of a member row.
struct W2GBadge: Equatable {
  enum Kind: String {
    case old, nosignal, connecting, idle, loading, buffering, other, sync, ahead, behind, playing, paused, independent
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

// MARK: - v2.1 presence and invite values, v2.2 now playing

enum W2GPresenceKind: String {
  case started
  case again
  case stopped
  case switched
  case source
  case buffering
  case lost
  /// v2.2 `following` true → false.
  case independent
  /// v2.2 `following` false → true.
  case rejoined
  /// v2.2 `mediaKey` change while not following.
  case watching
}

/// One presence announcement; `detail` is the episode label, the new source or what is watched.
struct W2GPresenceEvent: Equatable {
  var kind: W2GPresenceKind
  var detail: String = ""
}

/// What is remembered of a member to derive its presence announcements (sync.js Presence).
struct W2GPresenceMemory: Equatable {
  var lastStatus: W2GStatus?
  var bufferingSince: Double?
  var bufferingAnnounced = false
  var lostAnnounced = false
  /// Last announcement time per kind (`W2GPresenceKind.rawValue`), for the 5 s debounce.
  var lastAnnounced: [String: Double] = [:]
}

struct W2GPresenceStep: Equatable {
  var memory: W2GPresenceMemory
  var events: [W2GPresenceEvent]
}

/// v2.2 `status.nowPlaying` `{ mediaId, title, episode }`.
struct W2GNowPlaying: Equatable {
  var mediaId: String
  var title: String
  var episode: String

  /// "Title · Episode 5"
  var label: String {
    W2GSync.formatSource([title, episode])
  }
}

/// A member for host election / hand-off.
struct W2GElectionCandidate: Equatable {
  var userId: String
  var protocolVersion: Int?
  /// Its last `status` does not say `following: false`.
  var following: Bool
}

/// A member considered for the lobby's reference (v2.3).
struct W2GReferenceCandidate: Equatable {
  var userId: String
  var status: W2GStatus?
}
