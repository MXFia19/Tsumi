import Foundation
import Observation
import UIKit

// Watch Together lobby: native port of common/routes/w2g/components/w2g.js (W2GClient),
// session.js (shareNowPlaying) and the module part of WatchTogetherPage.svelte (joinLobby,
// invite, deep links). Participants find each other through public WebTorrent trackers
// (W2GSwarm, P2PT protocol) and exchange small JSON events over WebRTC data channels:
//   {"payload": …, "type": …}
// The events, their payloads and the rules (host, control mode, sync check, requests, kick, reactions,
// countdown) are the v2 contract of common/routes/w2g/PROTOCOL.md; the pure rules live in W2GSync.swift.
//
// Wiring (done in UI/Shell/AppWiring.swift configureWatchTogether, UI/Shell/ShellPlayback.swift and
// UI/Shell/ShellNavigation.swift):
//   currentUser, onRemoteMedia, onApplyPlayer (v1: onRemotePlayer), onPerformRequest, localPlayback,
//   onRemoteIndex, onNotice, onShowLobby closures; deep links → handle(url:) / join(link:);
//   scenePhase .active → appBecameActive();
//   player: shareMedia(media:episode:) when an episode starts, localPlayerAction(…) on a play / pause / seek
//   made by the user, playerReady() when a file finished loading, mediaIndexChanged(_:) on file change.

/// Anonymous id, kept for the whole app session (PROTOCOL "Identity").
private let w2gAnonymousId = W2GHex.randomCode(16)

@MainActor
@Observable
final class WatchTogetherClient {
  static let shared = WatchTogetherClient()

  /// w2g.js W2GClient.#signalingServers (same list, same order).
  static let signalingServers = [
    "wss://tracker.openwebtorrent.com",
    "wss://tracker.webtorrent.dev",
    "wss://tracker.files.fm:7073/announce"
  ]

  /// WatchTogetherPage.svelte inviteRx: /([A-z0-9]{16})/i
  static let invitePattern = "([A-z0-9]{16})"

  /// w2g.js MAX_MESSAGES / MAX_MESSAGE_LENGTH.
  static let maxMessages = 200
  static let maxMessageLength = 2048
  /// Member id of the local user in `members`.
  static let selfMemberId = "self"
  /// How often the local player is sampled (state changes are sent as `status` right away).
  static let sampleInterval: Double = 0.25
  /// A position this far from the extrapolated one is a seek: `status` is sent at once.
  static let seekDetectSeconds: Double = 1

  // MARK: Wiring

  /// Signed-in account (Helper.getUser()); nil → anonymous `{ id: <16 hex>, displayName? }`.
  @ObservationIgnored var currentUser: () -> Viewer? = { nil }
  /// Another participant started a title: start the same one locally.
  @ObservationIgnored var onRemoteMedia: ((Media, EpisodeRef) -> Void)?
  /// v1 hook: remote play/pause/seek (paused, time in seconds). Only used when `onApplyPlayer` is not set.
  @ObservationIgnored var onRemotePlayer: ((Bool, Double) -> Void)?
  /// A lobby state to apply to the player (someone's action, host snap-back, auto-sync, resync, countdown).
  /// It must not be reported back as a local action.
  @ObservationIgnored var onApplyPlayer: ((W2GPlayerCommand) -> Void)?
  /// The host accepted a request: the player does it as a local action (which is then broadcast).
  @ObservationIgnored var onPerformRequest: ((W2GRequestKind, Double?) -> Void)?
  /// What the local player is doing now; nil when there is no player (`idle`).
  @ObservationIgnored var localPlayback: (() -> W2GLocalPlayback?)?
  /// Remote file index change (playlist position in the player).
  @ObservationIgnored var onRemoteIndex: ((Int) -> Void)?
  /// Toast request (title, message).
  @ObservationIgnored var onNotice: ((String, String) -> Void)?
  /// A deep link joined a lobby: show the Watch Together screen.
  @ObservationIgnored var onShowLobby: (() -> Void)?
  /// v2.4 voice ducking: the player plays the video at this fraction of the user's volume (1 = normal).
  @ObservationIgnored var onDuck: ((Double) -> Void)?
  /// The full screen player is open (where the audio session goes back when leaving voice).
  @ObservationIgnored var isPlayerOpen: () -> Bool = { false }

  // MARK: State

  private(set) var code: String?
  private(set) var selfUser = W2GUser(id: w2gAnonymousId)
  /// Local user first, then remote participants that introduced themselves (`init`), by transport id.
  private(set) var members: [W2GMember] = []
  private(set) var messages: [W2GChatMessage] = []
  private(set) var sharedMedia: W2GSharedMedia?
  /// Last playback state of the lobby, as sent or received.
  private(set) var player = W2GPlayerState()
  private(set) var mediaIndex = 0
  private(set) var connectedTrackers = 0
  private(set) var totalTrackers = 0
  /// Open WebRTC links (all peers, backups included).
  private(set) var openConnections = 0
  /// Latest notice, for the in-screen banner.
  private(set) var notice: W2GNotice?

  // MARK: State (v2)

  /// Lobby host (userId); nil until a joiner receives `host`.
  private(set) var hostId: String?
  private(set) var mode: W2GMode = .everyone
  /// Last `status` and RTT per userId.
  private(set) var signals: [String: W2GSignal] = [:]
  /// Our own player, updated on state changes only (the live value is `local`).
  private(set) var localStatus = W2GLocalStatus.idle(at: 0)
  /// Host: requests waiting for an answer.
  private(set) var pendingRequests: [W2GHostRequest] = []
  private(set) var countdown: W2GCountdown?

  // Player overlays
  /// Chat messages received while the player panel was closed.
  private(set) var unreadCount = 0
  private(set) var bubbles: [W2GChatBubble] = []
  private(set) var overlayNotices: [W2GOverlayNotice] = []
  private(set) var floatingReactions: [W2GFloatingReaction] = []
  private(set) var isPlayerPanelOpen = false
  /// v2.1 invites received (Join / Dismiss), one per sender.
  private(set) var invites: [W2GInvite] = []
  /// v2.2: we follow the lobby's playback (false = "Watch on my own").
  private(set) var following = true
  /// v2.2: "Rejoin {title · episode}" offered after following again while on another media.
  private(set) var rejoinLabel: String?
  /// v2.3: the first-connection Join prompt is shown app-wide (once per lobby).
  private(set) var firstJoinPrompt = false
  /// v2.3: the floating Join prompt was dismissed for this lobby media key.
  private(set) var dismissedJoinKey: String?

  // MARK: State (v2.4)

  /// Our voice state.
  private(set) var voice = W2GVoiceView()
  /// Last `voice` per userId.
  private(set) var voiceStates: [String: W2GVoiceState] = [:]
  /// Audio link per userId: connected or still connecting.
  private(set) var voiceLinks: [String: Bool] = [:]
  /// Local mute / volume per userId (mirrors the engine, for the views).
  private(set) var voiceMixes: [String: W2GVoiceMix] = [:]
  /// "Up next", owned by the host (a copy elsewhere).
  private(set) var queue = W2GQueue()
  /// Host: auto-advance countdown before the first item plays.
  private(set) var advance: W2GAdvance?

  @ObservationIgnored private var swarm: W2GSwarm?
  /// The elected host after a migration, until it confirms with `host` (any claim is accepted meanwhile).
  @ObservationIgnored private var hostTentative = false
  /// Our player, `time` read at `at`.
  @ObservationIgnored private var local = W2GLocalStatus.idle(at: 0)
  /// Kicked userIds, ignored for the rest of the lobby.
  @ObservationIgnored private var banned = Set<String>()
  /// Last message time per userId (keeps a paused member "alive" between its pings).
  @ObservationIgnored private var lastSeen: [String: Double] = [:]
  @ObservationIgnored private var autoSync = W2GAutoSyncMemory()
  @ObservationIgnored private var lastHostPlayer: W2GHostPlayer?
  @ObservationIgnored private var requestTimers: [String: Task<Void, Never>] = [:]
  /// Request id → requester userId.
  @ObservationIgnored private var requestOwners: [String: String] = [:]
  /// Ids of our own pending requests.
  @ObservationIgnored private var myRequests = Set<String>()
  @ObservationIgnored private var countdownTask: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var lastHeartbeat: Double = 0
  @ObservationIgnored private var lastPing: Double = 0
  @ObservationIgnored private var lastPresenceCheck: Double = 0
  /// After the app was suspended every member looks silent: no "lost connection" until statuses came back.
  @ObservationIgnored private var presenceQuietUntil: Double = 0
  /// v2.1 presence announcements: what is remembered of each member, by userId.
  @ObservationIgnored private var presence: [String: W2GPresenceMemory] = [:]
  /// What the local player plays (media / episode / source), from the last sample.
  @ObservationIgnored private var localPlaying: W2GLocalPlayback?
  /// An accepted invite: seek once its file is loaded.
  @ObservationIgnored private var pendingInvite: W2GInviteJoin?
  /// v2.2 "Rejoin": sync to the host once this media key is loaded.
  @ObservationIgnored private var pendingRejoinKey: String?
  /// v2.3 Join: seek to the reference once this media key is loaded (key, when Join was pressed).
  @ObservationIgnored private var pendingJoin: (key: String, acceptedAt: Double)?
  /// v2.3: when each transport peer connected (its first events are its lobby state for us).
  @ObservationIgnored private var peerConnectedAt: [String: Double] = [:]
  /// v2.3: until when a first-connection Join prompt may be armed (nil once decided).
  @ObservationIgnored private var firstJoinDeadline: Double?
  /// An accepted invite that is not loaded after this long is dropped.
  static let inviteJoinWindowMs: Double = 120_000

  // v2.4
  @ObservationIgnored private var voiceEngineStorage: W2GVoiceEngine?
  @ObservationIgnored private var lastVoicePayload = W2GVoiceState.off
  /// A `queue` was received (or we created the lobby): changes are announced from then on.
  @ObservationIgnored private var queueKnown = false
  /// Our own suggestions we removed (not "declined").
  @ObservationIgnored private var queueCancelled = Set<String>()
  @ObservationIgnored private var advanceTask: Task<Void, Never>?
  /// Host: a queued item was started; count down once it is loaded (key, when).
  @ObservationIgnored private var pendingQueueStart: (key: String, at: Double)?
  @ObservationIgnored private var lastDuck: Double = 1

  init() {}

  var isInLobby: Bool { code != nil }

  var inviteLink: String? {
    guard let code else { return nil }
    return "tsumi://w2g/\(code)"
  }

  var messageGroups: [W2GMessageGroup] { W2GMessageGroup.group(messages) }

  var nowPlayingTitle: String? {
    guard let media = sharedMedia?.media, !media.title.all.isEmpty else { return nil }
    return AniListService.shared.title(media)
  }

  /// Our userId (`init.id` as a string).
  var selfId: String { selfUser.id }

  var isHost: Bool {
    guard let hostId else { return false }
    return hostId == selfId
  }

  /// While no host is known, everyone controls playback.
  var effectiveMode: W2GMode { hostId == nil ? .everyone : mode }

  /// Only the host controls playback and we are not the host.
  var controlLocked: Bool { effectiveMode == .host && !isHost && following }

  /// "Start together" is for the host, or for anyone in `everyone` mode.
  var canCountdown: Bool { following && (isHost || effectiveMode == .everyone) }

  /// The local player is open (not `idle`).
  var isWatching: Bool { localStatus.state != .idle }

  /// Signed in to AniList / MyAnimeList (no display name field then).
  var isLoggedIn: Bool { currentUser() != nil }

  /// Name of the current host, nil when unknown.
  var hostName: String? {
    guard let hostId else { return nil }
    return nameOf(hostId)
  }

  // MARK: Lobby lifecycle

  /// Create Lobby: random 16-hex code, this device is the host (sends state to newcomers).
  func createLobby() {
    start(code: nil)
  }

  /// Join by exact code.
  func join(code: String) {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    start(code: trimmed)
  }

  /// Join from a code, an invite link (tsumi://w2g/CODE) or any text containing a code.
  @discardableResult
  func join(link: String) -> Bool {
    guard let code = Self.lobbyCode(in: link) else { return false }
    start(code: code)
    onShowLobby?()
    return true
  }

  /// Deep link entry point: tsumi://w2g/CODE (shiru:// accepted like the mobile app).
  @discardableResult
  func handle(url: URL) -> Bool {
    guard Self.isLobbyLink(url) else { return false }
    return join(link: url.absoluteString)
  }

  static func isLobbyLink(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "tsumi" || scheme == "shiru" else { return false }
    return url.host?.lowercased() == "w2g"
  }

  /// First 16-char [A-z0-9] run, like WatchTogetherPage.svelte checkInvite.
  static func lobbyCode(in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: invitePattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          let matchRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[matchRange])
  }

  /// Leave button (Lobby.svelte cleanup → W2GClient.destroy).
  func leave() {
    // v2.4: out of voice first (its `voice` goes out while the links are still open).
    voiceEngineStorage?.leave(playerOpen: isPlayerOpen())
    advanceTask?.cancel()
    advanceTask = nil
    advance = nil
    pendingQueueStart = nil
    queue = W2GQueue()
    queueKnown = false
    queueCancelled = []
    voiceStates = [:]
    voiceLinks = [:]
    voiceMixes = [:]
    voice = W2GVoiceView()
    lastVoicePayload = .off
    if lastDuck != 1 {
      lastDuck = 1
      onDuck?(1)
    }
    swarm?.destroy()
    swarm = nil
    tickTask?.cancel()
    tickTask = nil
    countdownTask?.cancel()
    countdownTask = nil
    for task in requestTimers.values { task.cancel() }
    requestTimers = [:]
    code = nil
    members = []
    messages = []
    sharedMedia = nil
    player = W2GPlayerState()
    mediaIndex = 0
    connectedTrackers = 0
    totalTrackers = 0
    openConnections = 0
    notice = nil
    hostId = nil
    mode = .everyone
    hostTentative = false
    signals = [:]
    banned = []
    lastSeen = [:]
    autoSync = W2GAutoSyncMemory()
    lastHostPlayer = nil
    requestOwners = [:]
    myRequests = []
    pendingRequests = []
    countdown = nil
    unreadCount = 0
    bubbles = []
    overlayNotices = []
    floatingReactions = []
    invites = []
    presence = [:]
    localPlaying = nil
    pendingInvite = nil
    pendingRejoinKey = nil
    rejoinLabel = nil
    pendingJoin = nil
    peerConnectedAt = [:]
    firstJoinDeadline = nil
    firstJoinPrompt = false
    dismissedJoinKey = nil
    lastPresenceCheck = 0
    presenceQuietUntil = 0
    let now = W2GSync.nowMs()
    local = W2GLocalStatus.idle(at: now)
    localStatus = local
  }

  /// Call when the app returns to the foreground: reconnects dropped trackers and re-announces.
  func appBecameActive() {
    swarm?.refresh()
  }

  private func start(code requested: String?) {
    leave()
    let lobbyCode = requested ?? W2GHex.randomCode(16)
    if let viewer = currentUser() {
      selfUser = W2GUser(viewer: viewer)
    } else {
      selfUser = W2GUser(id: w2gAnonymousId, typedName: W2GSync.cleanDisplayName(AppSettings.shared.values.w2gDisplayName))
    }
    code = lobbyCode
    members = [W2GMember(id: Self.selfMemberId, user: selfUser, isSelf: true, protocolVersion: W2GSync.protocolVersion, client: W2GSync.clientName)]
    // v2.2: the last "Watch on my own" choice is kept for the next lobby.
    following = !AppSettings.shared.values.w2gWatchOnMyOwn
    // v2.3: joining a lobby that is already watching shows the Join prompt once, app-wide.
    if requested != nil { firstJoinDeadline = W2GSync.nowMs() + W2GSync.firstJoinWindowMs }
    // The lobby creator is the first host; a joiner has none until it receives `host`.
    if requested == nil {
      hostId = selfUser.id
      mode = .everyone
    }
    queueKnown = requested == nil

    let newSwarm = W2GSwarm(announceURLs: Self.signalingServers, identifier: lobbyCode)
    newSwarm.onPeerConnect = { [weak self] peerId in self?.peerConnected(peerId) }
    newSwarm.onMessage = { [weak self] peerId, payload in self?.received(payload, from: peerId) }
    newSwarm.onPeerClose = { [weak self] peerId in self?.peerClosed(peerId) }
    newSwarm.onStatusChange = { [weak self] in self?.refreshStatus() }
    swarm = newSwarm
    newSwarm.start()
    refreshStatus()
    sampleLocalPlayback(announce: false)
    startTicker()

    // WatchTogetherPage.svelte: `if (!code) invite()`
    if requested == nil { copyInvite() }
  }

  /// Invite button: copies tsumi://w2g/CODE.
  func copyInvite() {
    guard let inviteLink else { return }
    UIPasteboard.general.string = inviteLink
    post(title: "Copied to clipboard", message: "Copied invite code to clipboard")
  }

  private func refreshStatus() {
    guard let swarm else { return }
    connectedTrackers = swarm.connectedTrackerCount
    totalTrackers = swarm.trackerCount
    openConnections = swarm.openLinkCount
  }

  private func post(title: String, message: String) {
    notice = W2GNotice(title: title, message: message)
    onNotice?(title, message)
  }

  func dismissNotice(_ id: UUID? = nil) {
    guard let notice else { return }
    if let id, id != notice.id { return }
    self.notice = nil
  }

  // MARK: Heartbeat (status every 3 s, ping every 10 s)

  private func startTicker() {
    tickTask?.cancel()
    let nanoseconds = UInt64(Self.sampleInterval * 1_000_000_000)
    tickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: nanoseconds)
        if Task.isCancelled { return }
        guard let self else { return }
        self.tick()
      }
    }
  }

  private func tick() {
    guard isInLobby else { return }
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now)
    if now - lastHeartbeat >= W2GSync.heartbeatMs {
      lastHeartbeat = now
      sendStatus(now: now)
    }
    if now - lastPing >= W2GSync.pingMs {
      lastPing = now
      pingAll()
    }
    if now - lastPresenceCheck >= 1_000 {
      if lastPresenceCheck > 0 && now - lastPresenceCheck > 5_000 {
        presenceQuietUntil = now + W2GSync.lostConnectionMs
      }
      lastPresenceCheck = now
      if now >= presenceQuietUntil { checkPresence(now: now) }
      updateFirstJoinPrompt(now: now)
      // v2.4: push-to-talk / ducking switched in the settings.
      if voice.joined && voice.pushToTalk != AppSettings.shared.values.w2gPushToTalk { voiceSettingsChanged() }
      updateDuck()
    }
    // v2.4: a player opened while ducked gets the lowered volume too.
    if lastDuck != 1 { onDuck?(lastDuck) }
  }

  /// Reads the player; sends `status` right away when its state, title or rate changed, or after a seek.
  private func sampleLocalPlayback(now: Double = W2GSync.nowMs(), announce: Bool = true) {
    let next = currentLocalStatus(now: now)
    let previous = local
    var jumped = false
    let comparable = next.state == .playing || next.state == .paused || next.state == .buffering
    if comparable, previous.state == next.state, previous.mediaKey == next.mediaKey {
      let predicted = W2GSync.expectedTime(previous.status, receivedAt: previous.at, now: now, rttMs: 0)
      jumped = abs(predicted - next.time) > Self.seekDetectSeconds
    }
    local = next
    let changed = previous.state != next.state || previous.mediaKey != next.mediaKey || previous.rate != next.rate
      || previous.source != next.source || previous.following != next.following
    if changed { localStatus = next }
    if announce && (changed || jumped) { sendStatus(now: now) }
  }

  private func currentLocalStatus(now: Double) -> W2GLocalStatus {
    let playback = localPlayback?()
    localPlaying = playback
    guard let playback else { return W2GLocalStatus.idle(at: now) }
    let time = playback.time.isFinite ? max(0, playback.time) : 0
    let idle = playback.state == .idle
    let key = idle ? "" : mediaKey(for: playback.media, episode: playback.episode)
    return W2GLocalStatus(
      state: playback.state,
      time: time,
      mediaKey: key,
      rate: W2GSync.normalizeRate(playback.rate),
      at: now,
      source: idle ? "" : playback.source,
      following: following
    )
  }

  /// v2.2 `nowPlaying` of our player: `{ mediaId, title, episode }`, nil when not in the player.
  private var localNowPlaying: (mediaId: W2GJSON, value: W2GNowPlaying)? {
    guard local.state != .idle, let playing = localPlaying else { return nil }
    let media = playing.media
    let episode = playing.episode
    let mediaId = W2GMediaPayload.payloadId(for: media)
    var title = AniListService.shared.title(media)
    if title.isEmpty { title = media.title.all.first ?? "" }
    let label = W2GSync.nowPlayingEpisode(
      isMovie: media.isMovie,
      episodes: media.episodes,
      number: episode.number,
      season: episode.season,
      localEpisode: episode.localEpisode
    )
    return (mediaId: mediaId, value: W2GNowPlaying(mediaId: W2GJSON.jsTemplateString(mediaId), title: title, episode: label))
  }

  /// `status.mediaKey` of a title: the lobby's key when it is the shared title, else our own key.
  func mediaKey(for media: Media, episode: EpisodeRef) -> String {
    let payloadId = W2GMediaPayload.payloadId(for: media)
    let ownKey = W2GMediaPayload.key(mediaId: payloadId, episode: W2GMediaPayload.episodeJSON(episode))
    if let shared = sharedMedia {
      if shared.key == ownKey || shared.localKey == ownKey || shared.matches(media: media, episode: episode, payloadId: payloadId) {
        return shared.key
      }
    }
    return ownKey
  }

  private func sendStatus(to peerId: String? = nil, now: Double = W2GSync.nowMs()) {
    let time = max(0, W2GSync.expectedTime(local.status, receivedAt: local.at, now: now, rttMs: 0))
    var fields: [(String, W2GJSON?)] = []
    fields.append(("state", W2GJSON.text(local.state.rawValue)))
    fields.append(("time", W2GJSON.number(time)))
    fields.append(("mediaKey", W2GJSON.text(local.mediaKey)))
    fields.append(("rate", W2GJSON.number(local.rate)))
    fields.append(("sentAt", W2GJSON.number(now.rounded(.down))))
    fields.append(("source", W2GJSON.text(local.source)))
    fields.append(("following", W2GJSON.bool(following)))
    if let playing = localNowPlaying {
      var nowFields: [(String, W2GJSON?)] = []
      nowFields.append(("mediaId", playing.mediaId))
      nowFields.append(("title", W2GJSON.text(playing.value.title)))
      nowFields.append(("episode", W2GJSON.text(playing.value.episode)))
      fields.append(("nowPlaying", W2GJSON.dict(nowFields)))
    } else {
      fields.append(("nowPlaying", W2GJSON.null))
    }
    let payload = W2GJSON.dict(fields)
    if let peerId {
      sendEvent(to: peerId, type: "status", payload: payload)
    } else {
      broadcast(type: "status", payload: payload)
    }
  }

  private func pingAll() {
    guard let swarm else { return }
    for peerId in swarm.connectedPeerIds { ping(peerId) }
  }

  private func ping(_ peerId: String) {
    var fields: [(String, W2GJSON?)] = []
    fields.append(("id", W2GJSON.text(W2GHex.randomCode(8))))
    fields.append(("sentAt", W2GJSON.number(W2GSync.nowMs().rounded(.down))))
    sendEvent(to: peerId, type: "ping", payload: W2GJSON.dict(fields))
  }

  // MARK: Outgoing (w2g.js public API)

  /// session.js shareNowPlaying → W2GClient.shareMedia: a title/episode was started locally.
  func shareMedia(media: Media, episode: EpisodeRef) {
    // v2.2: watching on our own never drags the others (and keeps the lobby's media for "Rejoin").
    guard isInLobby, following else { return }
    let mediaJSON = W2GMediaPayload.json(from: media)
    let episodeJSON = W2GMediaPayload.episodeJSON(episode)
    let payloadId = mediaJSON["id"] ?? W2GJSON.null
    let key = W2GMediaPayload.key(mediaId: payloadId, episode: episodeJSON)
    if let current = sharedMedia {
      // Already what everyone plays (also stops the echo after a remote `media` event).
      if current.key == key || current.localKey == key || current.matches(media: media, episode: episode, payloadId: payloadId) { return }
    }
    let shared = W2GSharedMedia(key: key, localKey: key, mediaJSON: mediaJSON, episodeJSON: episodeJSON, media: media, episode: episode)
    sharedMedia = shared
    broadcast(type: "media", payload: shared.payload)
  }

  /// v1 entry point, kept for callers: a local play / pause / seek with the action inferred.
  func playerStateChanged(paused: Bool, time: Double) {
    let action = W2GSync.inferAction(previousPaused: player.paused, nextPaused: paused)
    localPlayerAction(action, time: time, paused: paused, delta: nil, rate: local.rate)
  }

  /// A play / pause / seek made by the user in the player. In `host` mode a non-host is snapped back to the host
  /// and offered a request instead of broadcasting. `automatic`: a pause the system made (app sent to the
  /// background), which is never snapped back.
  func localPlayerAction(_ action: W2GAction, time: Double, paused: Bool, delta: Double?, rate: Double, automatic: Bool = false) {
    guard isInLobby, time.isFinite else { return }
    let kind: W2GAction = action == .sync ? W2GSync.inferAction(previousPaused: player.paused, nextPaused: paused) : action
    cancelCountdown()
    sampleLocalPlayback()
    // v2.2: watching on our own, nothing is broadcast or snapped back.
    guard following else { return }

    if controlLocked {
      if automatic { return }
      let now = W2GSync.nowMs()
      if let target = hostTarget(now: now), target.mediaKey == nil || target.mediaKey == local.mediaKey {
        applyLocally(time: target.time, paused: target.paused, by: hostId)
      }
      showBlocked(action: kind, time: time)
      return
    }

    player = W2GPlayerState(paused: paused, time: time)
    broadcast(type: "player", payload: playerPayload(time: time, paused: paused, action: kind, rate: W2GSync.normalizeRate(rate)))
    if let text = W2GSync.describeAction(name: "You", action: kind, time: time, delta: delta) {
      system(text)
    }
  }

  /// The player finished loading a file: follow the host if it watches the same thing.
  func playerReady() {
    guard isInLobby else { return }
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now)
    // v2.4: a queued item the host started is loaded: the existing countdown starts everyone together.
    if let queued = pendingQueueStart {
      if now - queued.at > W2GSync.inviteJoinTTLMs {
        pendingQueueStart = nil
      } else if queued.key == local.mediaKey {
        pendingQueueStart = nil
        // Once the player reports its loaded state (position, play / pause).
        w2gAfter(0.3) { [weak self] in
          guard let self, self.isHost else { return }
          self.sampleLocalPlayback()
          guard self.local.mediaKey == queued.key else { return }
          _ = self.startTogether(seconds: W2GSync.queueCountdownSeconds)
        }
        return
      }
    }
    // An accepted invite: its file is loaded, go to the inviter's (or the host's) expected time.
    if applyPendingInvite(now: now) { return }
    // v2.3 Join: the lobby media is loaded, go to the reference.
    if applyPendingJoin(now: now) { return }
    guard following, hostId != nil, !isHost else { return }
    // v2.2 "Rejoin": the lobby media is loaded, sync to the host now.
    if let rejoinKey = pendingRejoinKey, rejoinKey == local.mediaKey {
      pendingRejoinKey = nil
      if let target = hostTarget(now: now), target.mediaKey == nil || target.mediaKey == rejoinKey {
        applyLocally(time: target.time, paused: target.paused, by: hostId)
      }
      return
    }
    if effectiveMode != .host && !AppSettings.shared.values.w2gAutoSync { return }
    guard let target = hostTarget(now: now), let key = target.mediaKey, key == local.mediaKey else { return }
    applyLocally(time: target.time, paused: target.paused, by: hostId)
  }

  /// Manual "Resync": jump to the host's expected position and state now.
  @discardableResult
  func resync() -> Bool {
    guard isInLobby, !isHost else { return false }
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now)
    guard let target = hostTarget(now: now) else {
      info("Nothing to sync with yet")
      return false
    }
    if let key = target.mediaKey, key != local.mediaKey {
      info("The host is on another episode")
      return false
    }
    applyLocally(time: target.time, paused: target.paused, by: hostId)
    return true
  }

  /// Host: send our position to everyone as a silent correction.
  @discardableResult
  func resyncEveryone() -> Bool {
    guard isInLobby, isHost, following else { return false }
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now)
    guard let time = localTime(now) else {
      info("Start playing to resync everyone")
      return false
    }
    let paused = local.state != .playing && local.state != .buffering
    player = W2GPlayerState(paused: paused, time: time)
    broadcast(type: "player", payload: playerPayload(time: time, paused: paused, action: .sync, rate: local.rate))
    info("Everyone was resynced")
    return true
  }

  /// "Start together": everyone seeks to our position, pauses, counts down, then plays.
  @discardableResult
  func startTogether(seconds: Int = W2GSync.countdownDefaultSeconds) -> Bool {
    guard isInLobby, canCountdown else { return false }
    let startAt = W2GSync.nowMs()
    sampleLocalPlayback(now: startAt)
    let time = localTime(startAt) ?? player.time
    let value = W2GSync.normalizeCountdownSeconds(Double(seconds))
    var fields: [(String, W2GJSON?)] = []
    fields.append(("time", W2GJSON.number(time)))
    fields.append(("seconds", W2GJSON.int(value)))
    fields.append(("startAt", W2GJSON.number(startAt.rounded(.down))))
    broadcast(type: "countdown", payload: W2GJSON.dict(fields))
    runCountdown(time: time, seconds: value, endsAt: startAt + Double(value) * 1000, by: selfId)
    system("You started a countdown")
    return true
  }

  /// Host: control mode toggle.
  @discardableResult
  func setMode(_ newMode: W2GMode) -> Bool {
    guard isInLobby, isHost, newMode != mode else { return false }
    setLobby(hostId: selfId, mode: newMode, tentative: false)
    broadcast(type: "host", payload: hostPayload(hostId: selfId))
    return true
  }

  /// Host: give the host role to someone else.
  @discardableResult
  func transferHost(to userId: String) -> Bool {
    guard isInLobby, isHost, userId != selfId, hasUser(userId) else { return false }
    // A v1 client would not know it is host: it could not change the mode, kick or answer requests.
    let version = members.first(where: { !$0.isSelf && $0.userId == userId })?.protocolVersion ?? 1
    guard version >= W2GSync.protocolVersion else { return false }
    broadcast(type: "host", payload: hostPayload(hostId: userId))
    setLobby(hostId: userId, mode: mode, tentative: false)
    return true
  }

  /// Host: remove someone from the lobby.
  @discardableResult
  func kick(_ userId: String) -> Bool {
    guard isInLobby, isHost, userId != selfId else { return false }
    broadcast(type: "kick", payload: W2GJSON.dict([("userId", W2GJSON.text(userId))]))
    ban(userId)
    return true
  }

  /// Non-host: ask the host for a change (`time` only for `seek`).
  @discardableResult
  func request(_ kind: W2GRequestKind, time: Double? = nil) -> Bool {
    guard isInLobby, !isHost else { return false }
    var fields: [(String, W2GJSON?)] = []
    let id = W2GHex.randomCode(12)
    fields.append(("id", W2GJSON.text(id)))
    fields.append(("kind", W2GJSON.text(kind.rawValue)))
    var requestTime: Double?
    if kind == .seek {
      guard let time, time.isFinite else { return false }
      requestTime = time
      fields.append(("time", W2GJSON.number(time)))
    }
    myRequests.insert(id)
    broadcast(type: "request", payload: W2GJSON.dict(fields))
    system(W2GSync.describeRequest(name: "You", kind: kind, time: requestTime))
    return true
  }

  /// "Request pause" / "Request play" button of a notice.
  func sendRequest(_ noticeRequest: W2GNoticeRequest, from noticeId: UUID) {
    request(noticeRequest.kind, time: noticeRequest.time)
    dismissOverlayNotice(noticeId)
  }

  /// Host: answer a request. When accepted, the player does it as a local action, which sends `player`.
  @discardableResult
  func answerRequest(id: String, accepted: Bool, timedOut: Bool = false) -> Bool {
    requestTimers[id]?.cancel()
    requestTimers[id] = nil
    guard let request = pendingRequests.first(where: { $0.id == id }) else { return false }
    pendingRequests.removeAll { $0.id == id }
    guard isHost else { return false }
    var fields: [(String, W2GJSON?)] = []
    fields.append(("id", W2GJSON.text(id)))
    fields.append(("accepted", W2GJSON.bool(accepted)))
    fields.append(("by", W2GJSON.text(selfId)))
    broadcast(type: "requestReply", payload: W2GJSON.dict(fields))
    let verb = accepted ? "accepted" : (timedOut ? "did not answer" : "declined")
    system("You \(verb) \(request.name)'s request")
    if accepted { onPerformRequest?(request.kind, request.time) }
    return true
  }

  /// One of the eight protocol reactions.
  @discardableResult
  func react(_ emoji: String) -> Bool {
    guard isInLobby, let value = W2GSync.normalizeReaction(emoji) else { return false }
    broadcast(type: "reaction", payload: W2GJSON.dict([("emoji", W2GJSON.text(value))]))
    showReaction(value, from: selfId)
    return true
  }

  /// W2GClient.message: chat message from the local user.
  func sendMessage(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isInLobby, !trimmed.isEmpty else { return }
    let limited = String(trimmed.prefix(Self.maxMessageLength))
    push(W2GChatMessage(text: limited, user: selfUser, direction: .outgoing))
    broadcast(type: "message", payload: W2GJSON.text(limited))
  }

  /// Anonymous user: name shown to the others instead of the id (saved in the settings, `w2gDisplayName`).
  func setDisplayName(_ name: String) {
    let value = W2GSync.cleanDisplayName(name) ?? ""
    if AppSettings.shared.values.w2gDisplayName != value {
      AppSettings.shared.values.w2gDisplayName = value
    }
    guard isInLobby, currentUser() == nil else { return }
    let typed: String? = value.isEmpty ? nil : value
    guard selfUser.typedName != typed else { return }
    selfUser.typedName = typed
    if let index = members.firstIndex(where: { $0.isSelf }) {
      members[index].user = selfUser
    }
    broadcast(type: "init", payload: initPayload)
  }

  /// W2GClient.mediaIndexChanged.
  func mediaIndexChanged(_ index: Int) {
    guard isInLobby, following, index != mediaIndex else { return }
    mediaIndex = index
    broadcast(type: "index", payload: W2GJSON.dict([("index", W2GJSON.int(index))]))
  }

  // MARK: Player overlays

  /// The Watch Together panel of the player opened or closed (unread count and bubbles).
  func setPlayerPanelOpen(_ open: Bool) {
    if isPlayerPanelOpen != open { isPlayerPanelOpen = open }
    if open {
      markChatRead()
      if !bubbles.isEmpty { bubbles = [] }
    }
  }

  /// The chat was seen (lobby screen).
  func markChatRead() {
    if unreadCount != 0 { unreadCount = 0 }
  }

  func dismissOverlayNotice(_ id: UUID) {
    overlayNotices.removeAll { $0.id == id }
  }

  /// The host's expected play / pause state, for "Request pause" vs "Request play".
  var hostPaused: Bool {
    hostTarget(now: W2GSync.nowMs())?.paused ?? player.paused
  }

  /// Display name of a participant ("You" for ourselves).
  func nameOf(_ userId: String) -> String {
    if userId == selfId { return "You" }
    if let user = userOf(userId) { return user.displayName }
    return W2GSync.memberName(name: nil, typedName: nil, id: userId)
  }

  /// Member list with host crown and sync badges: host first, then us, then by name.
  func memberViews(now: Double = W2GSync.nowMs()) -> [W2GMemberView] {
    var list: [W2GMemberView] = []
    // v2.3: the media an invite would offer (ours, else the lobby media while the lobby is watching).
    let offered = offeredKey()
    var ownBadge = W2GSync.selfBadge(local)
    if !following && local.state != .idle { ownBadge = W2GBadge(kind: .independent, text: "Watching on your own") }
    list.append(W2GMemberView(
      userId: selfId,
      user: selfUser,
      name: selfUser.displayName,
      isSelf: true,
      isHost: isHost,
      badge: ownBadge,
      protocolVersion: W2GSync.protocolVersion,
      client: W2GSync.clientName,
      rtt: nil,
      watching: localNowPlaying?.value.label ?? "",
      source: local.source,
      canInvite: false,
      hasVoice: true,
      voice: W2GMemberVoice(joined: lastVoicePayload.joined, muted: lastVoicePayload.muted, speaking: lastVoicePayload.speaking)
    ))
    var seen: Set<String> = [selfId]
    for member in members where !member.isSelf {
      let userId = member.userId
      guard !seen.contains(userId), !banned.contains(userId) else { continue }
      seen.insert(userId)
      let signal = signals[userId] ?? W2GSignal()
      let badge = W2GSync.syncBadge(signal: signal, protocolVersion: member.protocolVersion, lastSeen: lastSeen[userId], local: local, now: now, introducedAt: member.introducedAt)
      let status = signal.status
      let watching = status?.state == .idle ? "" : (status?.nowPlaying?.label ?? "")
      list.append(W2GMemberView(
        userId: userId,
        user: member.user,
        name: member.user.displayName,
        isSelf: false,
        isHost: hostId == userId,
        badge: badge,
        protocolVersion: member.protocolVersion,
        client: member.client,
        rtt: signal.rtt,
        watching: watching,
        source: status?.state == .idle ? "" : (status?.source ?? ""),
        canInvite: canInvite(member: member, badge: badge, offeredKey: offered, now: now),
        hasVoice: member.features.contains("voice"),
        voice: memberVoice(userId)
      ))
    }
    return list.sorted { lhs, rhs in
      if lhs.isHost != rhs.isHost { return lhs.isHost }
      if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  // MARK: Events

  /// events.js: JSON.stringify(new Event(type, payload)) → {"payload":…,"type":…}
  private static func encodeEvent(type: String, payload: W2GJSON) -> String {
    var fields: [(String, W2GJSON?)] = []
    fields.append(("payload", payload))
    fields.append(("type", W2GJSON.text(type)))
    return W2GJSONWriter.string(W2GJSON.dict(fields))
  }

  private func sendEvent(to peerId: String, type: String, payload: W2GJSON) {
    swarm?.send(Self.encodeEvent(type: type, payload: payload), to: peerId)
  }

  /// #sendToPeers: every open channel, except kicked users.
  private func broadcast(type: String, payload: W2GJSON) {
    guard let swarm else { return }
    let text = Self.encodeEvent(type: type, payload: payload)
    for peerId in swarm.connectedPeerIds where !banned.contains(userIdOf(peerId)) {
      swarm.send(text, to: peerId)
    }
  }

  /// `init` payload: the viewer object (or `{ id }`), plus the v2 fields.
  private var initPayload: W2GJSON {
    var fields: [W2GJSONMember] = []
    if case .object(let existing) = selfUser.json { fields = existing }
    if (selfUser.name ?? "").isEmpty, let typed = selfUser.typedName, !typed.isEmpty {
      fields.append(W2GJSONMember(key: "displayName", value: W2GJSON.text(typed)))
    }
    fields.append(W2GJSONMember(key: "client", value: W2GJSON.text(W2GSync.clientName)))
    fields.append(W2GJSONMember(key: "protocol", value: W2GJSON.int(W2GSync.protocolVersion)))
    // v2.4: what this client can do.
    fields.append(W2GJSONMember(key: "features", value: W2GJSON.array(W2GSync.features.map { W2GJSON.text($0) })))
    return W2GJSON.object(fields)
  }

  private func hostPayload(hostId newHost: String) -> W2GJSON {
    var fields: [(String, W2GJSON?)] = []
    fields.append(("hostId", W2GJSON.text(newHost)))
    fields.append(("mode", W2GJSON.text(mode.rawValue)))
    return W2GJSON.dict(fields)
  }

  private func playerPayload(time: Double, paused: Bool, action: W2GAction, rate: Double) -> W2GJSON {
    var fields: [(String, W2GJSON?)] = []
    fields.append(("time", W2GJSON.number(time)))
    fields.append(("paused", W2GJSON.bool(paused)))
    fields.append(("by", W2GJSON.text(selfId)))
    fields.append(("action", W2GJSON.text(action.rawValue)))
    fields.append(("rate", W2GJSON.number(rate)))
    return W2GJSON.dict(fields)
  }

  /// #onPeerconnect: introduce ourselves; the host also sends `host` and the current state.
  private func peerConnected(_ peerId: String) {
    peerConnectedAt[peerId] = W2GSync.nowMs()
    sendEvent(to: peerId, type: "init", payload: initPayload)
    if isHost {
      sendEvent(to: peerId, type: "host", payload: hostPayload(hostId: selfId))
      sendInitialSessionState(to: peerId)
      // v2.4: late joiners get the current queue.
      sendEvent(to: peerId, type: "queue", payload: queue.json)
    }
    sendStatus(to: peerId)
    sendEvent(to: peerId, type: "voice", payload: lastVoicePayload.json)
    ping(peerId)
    // P2PT can miss its one-time 'peerconnect' when the first of several parallel links fails,
    // and then that peer never sends `init`. List it as anonymous after a while so it still shows
    // in the lobby (its real `init`, if it comes, replaces this entry).
    let lobby = code
    w2gAfter(Self.introductionGrace) { [weak self] in
      guard let self, self.code == lobby, let swarm = self.swarm, swarm.isPeerConnected(peerId) else { return }
      guard !self.members.contains(where: { !$0.isSelf && $0.id == peerId }), !self.banned.contains(peerId) else { return }
      self.members.append(W2GMember(id: peerId, user: W2GUser(id: peerId), isSelf: false, introduced: false))
    }
  }

  /// Delay before a connected peer that never sent `init` is listed anyway.
  static let introductionGrace: Double = 8

  private func sendInitialSessionState(to peerId: String) {
    if let sharedMedia { sendEvent(to: peerId, type: "media", payload: sharedMedia.payload) }
    sendEvent(to: peerId, type: "index", payload: W2GJSON.dict([("index", W2GJSON.int(mediaIndex))]))
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now, announce: false)
    var state = player
    if let time = localTime(now) {
      state = W2GPlayerState(paused: local.state != .playing && local.state != .buffering, time: time)
    }
    sendEvent(to: peerId, type: "player", payload: playerPayload(time: state.time, paused: state.paused, action: .sync, rate: local.rate))
  }

  /// #onPeerclose
  private func peerClosed(_ peerId: String) {
    peerConnectedAt[peerId] = nil
    refreshStatus()
    guard let index = members.firstIndex(where: { !$0.isSelf && $0.id == peerId }) else { return }
    let member = members.remove(at: index)
    let userId = member.userId
    guard !hasUser(userId) else { return }
    signals[userId] = nil
    lastSeen[userId] = nil
    presence[userId] = nil
    invites.removeAll { $0.from == userId }
    forgetVoice(userId)
    if member.introduced && !banned.contains(userId) { system("\(member.user.displayName) left") }
    if let hostId, userId == hostId { migrateHost() }
  }

  /// #onMsg: malformed or unknown messages are ignored.
  private func received(_ value: W2GJSON, from peerId: String) {
    let event: W2GJSON
    if case .string(let units) = value {
      guard let parsed = W2GJSONParser.parse(String(decoding: units, as: UTF16.self)) else { return }
      event = parsed
    } else {
      event = value
    }
    guard let type = event["type"]?.stringValue else { return }
    let payload = event["payload"] ?? W2GJSON.null

    let userId = userIdOf(peerId)
    if banned.contains(userId) {
      swarm?.block(peerId)
      return
    }
    lastSeen[userId] = W2GSync.nowMs()
    // v2.3: what a v2 peer sends right after connecting is its lobby state for us (the host sends it to every
    // newcomer): remembered, never started; the Join card offers it.
    let sessionState = isSessionState(from: peerId)

    switch type {
    case "init":
      receivedInit(payload, from: peerId)
    case "media":
      receivedMedia(payload, sessionState: sessionState)
    case "index":
      guard let index = payload["index"]?.intValue else { return }
      if index != mediaIndex {
        mediaIndex = index
        // v2.2: not applied while watching on our own.
        if following && !sessionState { onRemoteIndex?(index) }
      }
    case "player":
      receivedPlayer(payload, from: userId, sessionState: sessionState)
    case "message":
      receivedChat(payload, from: peerId)
    case "host":
      receivedHost(payload, from: userId, peerId: peerId)
    case "status":
      receivedStatus(payload, from: userId)
    case "ping":
      if !payload.isNull { sendEvent(to: peerId, type: "pong", payload: payload) }
    case "pong":
      receivedPong(payload, from: userId)
    case "request":
      receivedRequest(payload, from: userId)
    case "requestReply":
      receivedRequestReply(payload, from: userId)
    case "kick":
      receivedKick(payload, from: userId)
    case "reaction":
      if let emoji = W2GSync.normalizeReaction(payload["emoji"]?.stringValue) {
        showReaction(emoji, from: userId)
      }
    case "countdown":
      receivedCountdown(payload, from: userId)
    case "invite":
      receivedInvite(payload, from: userId)
    case "voice":
      receivedVoice(payload, from: userId)
    case "voiceSignal":
      receivedVoiceSignal(payload, from: userId)
    case "queue":
      receivedQueue(payload, from: userId)
    case "queueAdd":
      if isHost {
        _ = hostQueueChange(.add(item: payload["item"] ?? W2GJSON.null, by: userId, byName: nameOf(userId), byHost: false))
      }
    case "queueVote":
      if isHost, let id = W2GSync.queueId(payload["id"]) {
        _ = hostQueueChange(.vote(id: id, by: userId, up: payload["up"]?.boolValue == true))
      }
    case "queueRemove":
      if isHost, let id = W2GSync.queueId(payload["id"]) {
        _ = hostQueueChange(.remove(id: id, by: userId, byHost: false))
      }
    default:
      break
    }
  }

  private func receivedInit(_ payload: W2GJSON, from peerId: String) {
    let user = W2GUser(json: payload, fallbackId: peerId)
    let userId = user.id
    if banned.contains(userId) {
      swarm?.block(peerId)
      return
    }
    let known = hasUser(userId)
    // A v1 client sends no `protocol`.
    let version = payload["protocol"]?.intValue ?? 1
    let client = payload["client"]?.stringValue
    let previous = members.first(where: { !$0.isSelf && $0.id == peerId })
    let introducedAt = previous?.introduced == true ? previous?.introducedAt : W2GSync.nowMs()
    let member = W2GMember(
      id: peerId,
      user: user,
      isSelf: false,
      protocolVersion: version,
      client: client,
      introduced: true,
      introducedAt: introducedAt ?? W2GSync.nowMs(),
      features: W2GSync.normalizeFeatures(payload["features"])
    )
    if let index = members.firstIndex(where: { !$0.isSelf && $0.id == peerId }) {
      members[index] = member
    } else {
      members.append(member)
    }
    lastSeen[userId] = W2GSync.nowMs()
    if !known { system("\(user.displayName) joined") }
  }

  private func receivedMedia(_ payload: W2GJSON, sessionState: Bool = false) {
    guard let mediaJSON = payload["media"], let mediaId = mediaJSON["id"], mediaId.isTruthy else { return }
    let episodeValue = payload["episode"]
    let ownKey = W2GMediaPayload.key(mediaId: mediaId, episode: episodeValue)
    // Keep the sender's key so every client of the lobby compares the same string (`status.mediaKey`).
    var key = ownKey
    if let sentKey = payload["key"]?.stringValue, !sentKey.isEmpty { key = sentKey }
    if key == sharedMedia?.key { return }
    let media = W2GMediaPayload.media(from: mediaJSON)
    let episode = W2GMediaPayload.episodeRef(from: episodeValue) ?? EpisodeRef(number: 1)
    let shared = W2GSharedMedia(key: key, localKey: ownKey, mediaJSON: mediaJSON, episodeJSON: episodeValue ?? W2GJSON.null, media: media, episode: episode)
    guard following, !sessionState, local.state != .idle else {
      // v2.2: remembered (for "Rejoin"), not applied while watching on our own.
      // v2.3: a newcomer's lobby state, or any media while we are not in the player, is remembered too: the
      // Join card starts it (nothing starts on its own).
      sharedMedia = shared
      return
    }
    rejoinLabel = nil
    startShared(shared)
  }

  /// A received `media` (or a joined invite): it becomes the lobby title and starts locally.
  private func startShared(_ shared: W2GSharedMedia) {
    sharedMedia = shared
    // WatchTogetherPage.svelte toast: "Starting <anilistClient.title(media) || 'the shared title'> - Episode N"
    let title = Self.sharedTitle(shared.media)
    var episodeNumber: Int?
    if shared.episodeJSON.isObject {
      episodeNumber = shared.episodeJSON["number"]?.intValue
    } else {
      episodeNumber = shared.episodeJSON.intValue
    }
    let suffix = episodeNumber.map { $0 != 0 ? " - Episode \($0)" : "" } ?? ""
    post(title: "Watch Together", message: "Starting \(title)\(suffix)")

    if let media = shared.media { onRemoteMedia?(media, shared.episode) }
  }

  /// `anilistClient.title(media) || 'the shared title'`
  private static func sharedTitle(_ media: Media?) -> String {
    guard let media, !media.title.all.isEmpty else { return "the shared title" }
    let display = AniListService.shared.title(media)
    return display.isEmpty ? "the shared title" : display
  }

  private func receivedPlayer(_ payload: W2GJSON, from senderId: String, sessionState: Bool = false) {
    guard let time = payload["time"]?.doubleValue else { return }
    let paused = payload["paused"]?.isTruthy ?? false
    // v1 senders omit `by`: the sender is the author.
    let by = Self.idString(payload["by"]) ?? senderId
    if effectiveMode == .host && by != hostId { return }
    let now = W2GSync.nowMs()
    let sentAction = payload["action"]?.stringValue.flatMap { W2GAction(rawValue: $0) }
    var action = sentAction ?? W2GSync.inferAction(previousPaused: player.paused, nextPaused: paused)
    let reference = localTime(now) ?? player.time
    // v1 clients echo every state they apply: a "seek" that moves nothing is not announced.
    if sentAction == nil && action == .seek && abs(time - reference) < W2GSync.inSyncSeconds { action = .sync }
    let rate = W2GSync.normalizeRate(payload["rate"]?.doubleValue)

    player = W2GPlayerState(paused: paused, time: time)
    if let hostId, by == hostId {
      lastHostPlayer = W2GHostPlayer(time: time, paused: paused, rate: rate, at: now)
    }
    // v2.2: not applied while watching on our own (the chat still tells what happened).
    // v2.3: nor the lobby state a peer sends when it connects.
    if following && !sessionState {
      cancelCountdown()
      apply(W2GPlayerCommand(time: time, paused: paused, action: action, by: by, rate: rate, isPrecise: sentAction != nil))
    }

    guard action != .sync else { return }
    let delta: Double? = action == .seek ? time - reference : nil
    guard let text = W2GSync.describeAction(name: nameOf(by), action: action, time: time, delta: delta) else { return }
    system(text)
    guard following else { return }
    showNotice(text)
  }

  private func receivedChat(_ payload: W2GJSON, from peerId: String) {
    let text: String
    switch payload {
    case .string:
      text = payload.stringValue ?? ""
    case .number, .bool:
      text = W2GJSON.jsTemplateString(payload)
    default:
      return
    }
    guard !text.isEmpty else { return }
    let limited = String(text.prefix(Self.maxMessageLength))
    // A message can arrive before the sender introduced itself.
    let user = members.first(where: { !$0.isSelf && $0.id == peerId })?.user ?? W2GUser(id: peerId)
    push(W2GChatMessage(text: limited, user: user, direction: .incoming))
    guard !isPlayerPanelOpen else { return }
    unreadCount += 1
    let short = limited.count > 160 ? String(limited.prefix(160)) + "…" : limited
    let bubble = W2GChatBubble(name: user.displayName, text: short)
    bubbles = Array((bubbles + [bubble]).suffix(3))
    let bubbleId = bubble.id
    w2gAfter(W2GSync.bubbleSeconds) { [weak self] in
      self?.bubbles.removeAll { $0.id == bubbleId }
    }
  }

  private func receivedHost(_ payload: W2GJSON, from senderId: String, peerId: String) {
    guard let newHost = Self.idString(payload["hostId"]) else { return }
    let newMode = W2GMode.normalize(payload["mode"]?.stringValue)
    // Accept `host` only from the current host, or from anyone while no host is known.
    if let current = hostId, !hostTentative, senderId != current {
      // Two hosts (after a split): the smallest userId keeps the role.
      let rivalClaim = isHost && newHost == senderId
      if !(rivalClaim && W2GSync.jsLess(senderId, selfId)) {
        if isHost { sendEvent(to: peerId, type: "host", payload: hostPayload(hostId: selfId)) }
        return
      }
    }
    setLobby(hostId: newHost, mode: newMode, tentative: false)
  }

  private func receivedStatus(_ payload: W2GJSON, from userId: String) {
    guard let state = W2GPlaybackState.normalize(payload["state"]?.stringValue),
          let time = payload["time"]?.doubleValue else { return }
    let now = W2GSync.nowMs()
    var key = ""
    if let value = payload["mediaKey"], !value.isNull { key = W2GJSON.jsTemplateString(value) }
    let source = payload["source"]?.stringValue ?? ""
    // v2.2: `following` is true when absent; `nowPlaying` is null outside the player.
    let followingValue = payload["following"]?.boolValue ?? true
    var nowPlaying: W2GNowPlaying?
    if let value = payload["nowPlaying"], value.isObject {
      var mediaId = ""
      if let id = value["mediaId"], !id.isNull { mediaId = W2GJSON.jsTemplateString(id) }
      nowPlaying = W2GNowPlaying(
        mediaId: mediaId,
        title: String((value["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
        episode: String((value["episode"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
      )
    }
    let status = W2GStatus(
      state: state,
      time: time,
      mediaKey: key,
      rate: W2GSync.normalizeRate(payload["rate"]?.doubleValue),
      source: source,
      following: followingValue,
      nowPlaying: nowPlaying
    )
    if userId != selfId {
      let step = W2GSync.presenceAfterStatus(presence[userId] ?? W2GPresenceMemory(), status: status, now: now)
      presence[userId] = step.memory
      announcePresence(step.events, of: userId)
    }
    var signal = signals[userId] ?? W2GSignal()
    signal.status = status
    signal.receivedAt = now
    signals[userId] = signal
    if let hostId, userId == hostId, !isHost { checkAutoSync(now: now) }
  }

  private func receivedPong(_ payload: W2GJSON, from userId: String) {
    guard let sentAt = payload["sentAt"]?.doubleValue else { return }
    let rtt = W2GSync.nowMs() - sentAt
    guard rtt >= 0, rtt <= 60_000 else { return }
    var signal = signals[userId] ?? W2GSignal()
    signal.rtt = rtt
    signal.pongAt = W2GSync.nowMs()
    signals[userId] = signal
  }

  private func receivedRequest(_ payload: W2GJSON, from userId: String) {
    guard let kind = payload["kind"]?.stringValue.flatMap({ W2GRequestKind(rawValue: $0) }),
          let id = Self.idString(payload["id"]) else { return }
    let time = payload["time"]?.doubleValue
    if kind == .seek && time == nil { return }
    let name = nameOf(userId)
    requestOwners[id] = userId
    system(W2GSync.describeRequest(name: name, kind: kind, time: time))
    guard isHost, requestTimers[id] == nil else { return }
    let request = W2GHostRequest(
      id: id,
      kind: kind,
      time: kind == .seek ? time : nil,
      userId: userId,
      name: name,
      expiresAt: W2GSync.nowMs() + W2GSync.requestTimeoutMs
    )
    var list = pendingRequests.filter { $0.id != id }
    list.append(request)
    pendingRequests = list
    // No answer within 15 s counts as declined.
    requestTimers[id] = w2gAfter(W2GSync.requestTimeoutMs / 1000) { [weak self] in
      _ = self?.answerRequest(id: id, accepted: false, timedOut: true)
    }
  }

  private func receivedRequestReply(_ payload: W2GJSON, from senderId: String) {
    guard let hostId, senderId == hostId, let id = Self.idString(payload["id"]) else { return }
    let mine = myRequests.remove(id) != nil
    let owner = requestOwners.removeValue(forKey: id)
    let whose: String
    if mine {
      whose = "your"
    } else if let owner {
      whose = "\(nameOf(owner))'s"
    } else {
      whose = "a"
    }
    let accepted = payload["accepted"]?.isTruthy ?? false
    let text = "\(nameOf(senderId)) \(accepted ? "accepted" : "declined") \(whose) request"
    system(text)
    if mine { showNotice(text) }
  }

  private func receivedKick(_ payload: W2GJSON, from senderId: String) {
    guard let hostId, senderId == hostId, let target = Self.idString(payload["userId"]) else { return }
    if target == selfId {
      leave()
      post(title: "Watch Together", message: "You were removed from the lobby")
      return
    }
    ban(target)
  }

  private func receivedCountdown(_ payload: W2GJSON, from senderId: String) {
    guard senderId == hostId || effectiveMode == .everyone else { return }
    guard let time = payload["time"]?.doubleValue, time >= 0 else { return }
    let seconds = W2GSync.normalizeCountdownSeconds(Self.numberValue(payload["seconds"]))
    // startAt is on the sender's clock: count from the reception, minus half the trip.
    let rtt: Double = signals[senderId]?.rtt ?? 0
    let endsAt = W2GSync.nowMs() + Double(seconds) * 1000 - rtt / 2
    // v2.2: not applied while watching on our own. v2.4: nor on another episode than the lobby's.
    if following && W2GSync.appliesCountdown(localKey: local.mediaKey, lobbyKey: sharedMedia?.key) {
      runCountdown(time: time, seconds: seconds, endsAt: endsAt, by: senderId)
    }
    system("\(nameOf(senderId)) started a countdown")
  }

  // MARK: v2.1 presence and invite

  /// Long buffering and lost connection of the other members (once a second).
  private func checkPresence(now: Double) {
    for (userId, memory) in presence {
      guard userId != selfId, hasUser(userId), !banned.contains(userId) else { continue }
      let signal = signals[userId]
      let step = W2GSync.presenceTick(memory, lastStatusAt: signal?.receivedAt, lastPongAt: signal?.pongAt, now: now)
      if step.memory != memory { presence[userId] = step.memory }
      announcePresence(step.events, of: userId)
    }
  }

  /// System line + 3 s notice over the video for each presence change of a member.
  private func announcePresence(_ events: [W2GPresenceEvent], of userId: String) {
    guard !events.isEmpty else { return }
    let name = nameOf(userId)
    for event in events {
      let text = W2GSync.describePresence(event, name: name)
      system(text)
      showNotice(text)
    }
  }

  /// v2.3 media we can offer: ours when we are in the player with one, else the lobby media while the lobby is
  /// watching; nil when there is nothing to offer.
  private func offeredKey() -> String? {
    if local.state != .idle, localPlaying != nil, !local.mediaKey.isEmpty { return local.mediaKey }
    guard let shared = sharedMedia, lobbyReferenceId() != nil else { return nil }
    return shared.key
  }

  /// "Invite to watch" is offered on this member row (v2.3 rules).
  private func canInvite(member: W2GMember, badge: W2GBadge, offeredKey: String?, now: Double) -> Bool {
    guard isInLobby else { return false }
    return W2GSync.canInvite(
      offeredKey: offeredKey,
      mode: effectiveMode,
      isHost: isHost,
      isSelf: member.isSelf,
      protocolVersion: member.protocolVersion,
      badge: badge.kind,
      status: signals[member.userId]?.status,
      introducedAt: member.introducedAt,
      now: now
    )
  }

  /// Members "Invite everyone not watching" would invite (v2 members eligible for the offered media).
  private func inviteTargets(now: Double) -> [String] {
    let key = offeredKey()
    var ids: [String] = []
    for member in members where !member.isSelf && member.introduced && !banned.contains(member.userId) {
      guard !ids.contains(member.userId) else { continue }
      let signal = signals[member.userId] ?? W2GSignal()
      let badge = W2GSync.syncBadge(signal: signal, protocolVersion: member.protocolVersion, lastSeen: lastSeen[member.userId], local: local, now: now, introducedAt: member.introducedAt)
      if canInvite(member: member, badge: badge, offeredKey: key, now: now) { ids.append(member.userId) }
    }
    return ids
  }

  /// Host tool "Invite everyone not watching" is offered.
  var canInviteEveryone: Bool {
    guard isInLobby, isHost else { return false }
    return !inviteTargets(now: W2GSync.nowMs()).isEmpty
  }

  /// Host tool: one `invite` to each eligible member, 200 ms apart.
  func inviteEveryoneNotWatching() {
    guard isInLobby, isHost else { return }
    let targets = inviteTargets(now: W2GSync.nowMs())
    for (index, userId) in targets.enumerated() {
      if index == 0 {
        _ = invite(userId)
      } else {
        w2gAfter(W2GSync.inviteSpacingSeconds * Double(index)) { [weak self] in
          _ = self?.invite(userId)
        }
      }
    }
  }

  /// v2.1 `invite`: ask a member to watch our media from our position, or (v2.3, from anywhere) the lobby media
  /// from the reference's position (broadcast; only `to` acts on it).
  @discardableResult
  func invite(_ userId: String) -> Bool {
    guard isInLobby, userId != selfId, effectiveMode == .everyone || isHost else { return false }
    let now = W2GSync.nowMs()
    sampleLocalPlayback(now: now)
    let key: String
    let mediaJSON: W2GJSON
    let episodeJSON: W2GJSON
    let time: Double
    let paused: Bool
    if let playing = localPlaying, local.state != .idle, !local.mediaKey.isEmpty {
      // Our own playback.
      key = local.mediaKey
      if let shared = sharedMedia, shared.key == key {
        mediaJSON = shared.mediaJSON
        episodeJSON = shared.episodeJSON
      } else {
        mediaJSON = W2GMediaPayload.json(from: playing.media)
        episodeJSON = W2GMediaPayload.episodeJSON(playing.episode)
      }
      time = localTime(now) ?? local.time
      paused = local.state != .playing && local.state != .buffering
    } else if let shared = sharedMedia, let referenceId = lobbyReferenceId(), let target = referenceTarget(referenceId, now: now) {
      // The lobby media, at the reference's position.
      key = shared.key
      mediaJSON = shared.mediaJSON
      episodeJSON = shared.episodeJSON
      time = target.time
      paused = target.paused
    } else {
      return false
    }
    var fields: [(String, W2GJSON?)] = []
    fields.append(("to", W2GJSON.text(userId)))
    fields.append(("media", mediaJSON))
    fields.append(("episode", episodeJSON))
    fields.append(("key", W2GJSON.text(key)))
    fields.append(("time", W2GJSON.number(max(0, time))))
    fields.append(("paused", W2GJSON.bool(paused)))
    fields.append(("by", W2GJSON.text(selfId)))
    broadcast(type: "invite", payload: W2GJSON.dict(fields))
    system("You invited \(nameOf(userId))")
    return true
  }

  // MARK: v2.3 lobby watching and Join

  /// The member whose playback the lobby follows: the host on the lobby media, else the smallest following
  /// userId on it (us included); nil when the lobby is not watching.
  func lobbyReferenceId() -> String? {
    guard let shared = sharedMedia else { return nil }
    var candidates: [W2GReferenceCandidate] = [W2GReferenceCandidate(userId: selfId, status: localStatus.status)]
    for member in members where !member.isSelf && member.introduced && !banned.contains(member.userId) {
      candidates.append(W2GReferenceCandidate(userId: member.userId, status: signals[member.userId]?.status))
    }
    return W2GSync.lobbyReference(lobbyKey: shared.key, hostId: hostId, candidates: candidates)
  }

  /// Where the reference is expected to be now.
  private func referenceTarget(_ userId: String, now: Double) -> W2GHostTarget? {
    if userId == selfId {
      guard let time = localTime(now) else { return nil }
      return W2GHostTarget(time: time, paused: local.state == .paused, mediaKey: local.mediaKey)
    }
    guard let signal = signals[userId], let status = signal.status else { return nil }
    return W2GSync.referenceTarget(status: status, receivedAt: signal.receivedAt ?? now, rttMs: signal.rtt, now: now)
  }

  /// "{reference} is watching {title · episode}" [Join]: the lobby is watching and we are not on its media.
  var joinOffer: W2GJoinOffer? {
    guard isInLobby, let shared = sharedMedia else { return nil }
    let reference = lobbyReferenceId()
    guard W2GSync.offersJoin(
      referenceId: reference,
      selfId: selfId,
      localState: localStatus.state,
      localKey: localStatus.mediaKey,
      following: following,
      lobbyKey: shared.key
    ), let referenceId = reference else { return nil }
    let episode = W2GSync.episodeLabel(number: shared.episode.number, season: shared.episode.season, localEpisode: shared.episode.localEpisode)
    let label = W2GSync.formatSource([Self.sharedTitle(shared.media), episode])
    return W2GJoinOffer(referenceId: referenceId, name: nameOf(referenceId), label: label, key: shared.key)
  }

  /// The dismissible Join prompt over the player (panel closed): while following, or the first-connection one.
  var floatingJoinOffer: W2GJoinOffer? {
    guard let offer = joinOffer, offer.key != dismissedJoinKey, following || firstJoinPrompt else { return nil }
    return offer
  }

  /// The first-connection Join prompt shown app-wide.
  var appWideJoinOffer: W2GJoinOffer? {
    guard firstJoinPrompt, let offer = joinOffer, offer.key != dismissedJoinKey else { return nil }
    return offer
  }

  /// Join: plays the lobby media like a received `media` event (even with the same key), then seeks to the
  /// reference and follows again.
  func joinPlayback() {
    guard isInLobby, let shared = sharedMedia else { return }
    firstJoinPrompt = false
    let now = W2GSync.nowMs()
    if !following {
      following = true
      if AppSettings.shared.values.w2gWatchOnMyOwn { AppSettings.shared.values.w2gWatchOnMyOwn = false }
      rejoinLabel = nil
      pendingRejoinKey = nil
      system("You are back in sync")
    }
    pendingJoin = (key: shared.key, acceptedAt: now)
    startShared(shared)
    // Already on that media (nothing reloads): seek now.
    sampleLocalPlayback(now: now)
    _ = applyPendingJoin(now: now)
  }

  /// Hides the floating / app-wide Join prompt for the current lobby media (the cards stay).
  func dismissJoinOffer() {
    dismissedJoinKey = joinOffer?.key ?? sharedMedia?.key
    firstJoinPrompt = false
  }

  private func applyPendingJoin(now: Double) -> Bool {
    guard let join = pendingJoin else { return false }
    if now - join.acceptedAt > W2GSync.inviteJoinTTLMs {
      pendingJoin = nil
      return false
    }
    guard local.mediaKey == join.key, local.state != .idle, local.state != .loading else { return false }
    pendingJoin = nil
    let reference = lobbyReferenceId()
    var found: W2GHostTarget?
    if let referenceId = reference, referenceId != selfId { found = referenceTarget(referenceId, now: now) }
    if found == nil { found = hostTarget(now: now) }
    guard let target = found else { return true }
    applyLocally(time: target.time, paused: target.paused, by: reference ?? hostId)
    return true
  }

  /// The lobby state a v2 peer sends right after connecting (host to newcomer) is not applied.
  private func isSessionState(from peerId: String) -> Bool {
    let member = members.first(where: { !$0.isSelf && $0.id == peerId })
    // Measured from the sender's `init` (sync.js INITIAL_STATE_MS), else from its connection.
    guard let since = member?.introducedAt ?? peerConnectedAt[peerId] else { return false }
    return W2GSync.nowMs() - since < W2GSync.sessionStateWindowMs
  }

  /// Arms the first-connection Join prompt when the lobby turns out to be watching soon after joining.
  private func updateFirstJoinPrompt(now: Double) {
    if let deadline = firstJoinDeadline {
      if joinOffer != nil {
        firstJoinPrompt = true
        firstJoinDeadline = nil
      } else if now > deadline {
        firstJoinDeadline = nil
      }
    } else if firstJoinPrompt && joinOffer == nil {
      firstJoinPrompt = false
    }
  }

  /// Join: plays the invite's media like a received `media` event (even with the same key), then seeks.
  func acceptInvite(_ id: UUID) {
    guard let invite = invites.first(where: { $0.id == id }) else { return }
    invites.removeAll { $0.id == id }
    let now = W2GSync.nowMs()
    var join = W2GInviteJoin(
      key: invite.shared.key,
      by: invite.by,
      time: invite.time,
      paused: invite.paused,
      receivedAt: invite.receivedAt,
      acceptedAt: now
    )
    if following {
      pendingInvite = join
      startShared(invite.shared)
    } else {
      // Watching on our own: play it without replacing the lobby's media (kept for "Rejoin"); our status then
      // uses our own key for it.
      join.key = invite.shared.localKey
      pendingInvite = join
      post(title: "Watch Together", message: "Starting \(Self.sharedTitle(invite.shared.media)) \u{00B7} \(invite.episodeLabel)")
      if let media = invite.shared.media { onRemoteMedia?(media, invite.shared.episode) }
    }
    // Already on that episode (nothing reloads): seek now.
    sampleLocalPlayback(now: now)
    _ = applyPendingInvite(now: now)
  }

  func dismissInvite(_ id: UUID) {
    invites.removeAll { $0.id == id }
  }

  private func receivedInvite(_ payload: W2GJSON, from senderId: String) {
    // For us, not from us; anyone in `everyone` mode, the host only in `host` mode.
    guard W2GSync.acceptsInvite(to: Self.idString(payload["to"]), selfId: selfId, senderId: senderId, hostId: hostId, mode: effectiveMode) else { return }
    guard let mediaJSON = payload["media"], let mediaId = mediaJSON["id"], mediaId.isTruthy else { return }
    let episodeValue = payload["episode"]
    let ownKey = W2GMediaPayload.key(mediaId: mediaId, episode: episodeValue)
    var key = ownKey
    if let sentKey = payload["key"]?.stringValue, !sentKey.isEmpty { key = sentKey }
    let media = W2GMediaPayload.media(from: mediaJSON)
    let episode = W2GMediaPayload.episodeRef(from: episodeValue) ?? EpisodeRef(number: 1)
    let shared = W2GSharedMedia(key: key, localKey: ownKey, mediaJSON: mediaJSON, episodeJSON: episodeValue ?? W2GJSON.null, media: media, episode: episode)
    let name = nameOf(senderId)
    let invite = W2GInvite(
      from: senderId,
      by: Self.idString(payload["by"]) ?? senderId,
      name: name,
      title: Self.sharedTitle(media),
      episodeLabel: W2GSync.episodeLabel(number: episode.number, season: episode.season, localEpisode: episode.localEpisode),
      shared: shared,
      time: max(0, payload["time"]?.doubleValue ?? 0),
      paused: payload["paused"]?.isTruthy ?? false,
      receivedAt: W2GSync.nowMs()
    )
    // A new invite from the same sender replaces the previous one.
    var list = invites.filter { $0.from != senderId }
    list.append(invite)
    invites = list
    system("\(name) invited you to watch")
  }

  /// Seeks an accepted invite once its file plays here: to the host when it is on the same episode, else to the
  /// inviter's expected time. Returns true when it was applied.
  private func applyPendingInvite(now: Double) -> Bool {
    guard let join = pendingInvite else { return false }
    if now - join.acceptedAt > Self.inviteJoinWindowMs {
      pendingInvite = nil
      return false
    }
    guard local.mediaKey == join.key, local.state != .idle, local.state != .loading else { return false }
    pendingInvite = nil
    let target = W2GSync.inviteTarget(
      key: join.key,
      time: join.time,
      paused: join.paused,
      receivedAt: join.receivedAt,
      host: hostTarget(now: now),
      now: now
    )
    applyLocally(time: target.time, paused: target.paused, by: target.fromHost ? hostId : join.by)
    return true
  }

  // MARK: v2.2 independent watching

  /// "Watch on my own" toggle (remembered for the next lobby). Turning it on hands the host role over first;
  /// turning it off resyncs to the host on the lobby's media, or offers "Rejoin".
  func setFollowing(_ value: Bool) {
    if AppSettings.shared.values.w2gWatchOnMyOwn == value {
      AppSettings.shared.values.w2gWatchOnMyOwn = !value
    }
    guard isInLobby, value != following else { return }
    let now = W2GSync.nowMs()
    if !value {
      // The host role moves first, as a normal transfer, to a v2 peer that follows; else we stay host.
      if isHost, let target = W2GSync.handOffTarget(electionPeers()) {
        _ = transferHost(to: target)
      }
      cancelCountdown()
      following = false
      rejoinLabel = nil
      pendingRejoinKey = nil
      system("You are watching on your own")
      sampleLocalPlayback(now: now)
      return
    }
    following = true
    system("You are back in sync")
    sampleLocalPlayback(now: now)
    guard let shared = sharedMedia else { return }
    if local.mediaKey == shared.key && local.state != .idle {
      // Same media as the lobby: resync to the host right away.
      if !isHost, let target = hostTarget(now: now), target.mediaKey == nil || target.mediaKey == shared.key {
        applyLocally(time: target.time, paused: target.paused, by: hostId)
      }
      return
    }
    let title = Self.sharedTitle(shared.media)
    let label = W2GSync.formatSource([title, W2GSync.episodeLabel(number: shared.episode.number, season: shared.episode.season, localEpisode: shared.episode.localEpisode)])
    rejoinLabel = label
  }

  /// "Rejoin {title · episode}": starts the lobby media like a received `media` event, then syncs to the host.
  func rejoin() {
    guard isInLobby, following, let shared = sharedMedia else { return }
    rejoinLabel = nil
    pendingRejoinKey = shared.key
    startShared(shared)
  }

  /// Connected v2 peers and whether their last `status` follows the lobby (host election / hand-off).
  private func electionPeers() -> [W2GElectionCandidate] {
    var list: [W2GElectionCandidate] = []
    for member in members where !member.isSelf && member.introduced && !banned.contains(member.userId) {
      if list.contains(where: { $0.userId == member.userId }) { continue }
      let followingValue = signals[member.userId]?.status?.following ?? true
      list.append(W2GElectionCandidate(userId: member.userId, protocolVersion: member.protocolVersion, following: followingValue))
    }
    return list
  }

  // MARK: v2.4 voice chat

  /// We are in voice.
  var voiceJoined: Bool { voice.joined }

  private var voiceEngineInstance: W2GVoiceEngine {
    if let engine = voiceEngineStorage { return engine }
    let engine = W2GVoiceEngine()
    engine.onStateChange = { [weak self] in self?.voiceEngineChanged() }
    engine.onSignal = { [weak self] userId, payload in self?.sendToUser(userId, type: "voiceSignal", payload: payload) }
    engine.onLinksChange = { [weak self] in
      guard let self, let engine = self.voiceEngineStorage else { return }
      self.voiceLinks = engine.linkStates
      self.updateDuck()
    }
    engine.wantsOffer = { [weak self] userId in
      guard let self else { return false }
      return self.voice.joined && W2GSync.voiceOffers(selfId: self.selfId, otherId: userId) && self.memberInVoice(userId)
    }
    voiceEngineStorage = engine
    return engine
  }

  /// "Join voice": asks for the microphone (listening only without it), then links with the members in voice.
  func joinVoice() {
    guard isInLobby else { return }
    let engine = voiceEngineInstance
    Task { @MainActor [weak self] in
      await engine.join()
      guard let self, engine.joined, self.isInLobby else { return }
      self.system(engine.hasMic ? "You joined voice" : "You joined voice (listening only)")
    }
  }

  func leaveVoice() {
    guard let engine = voiceEngineStorage, engine.joined || engine.starting else { return }
    engine.leave(playerOpen: isPlayerOpen())
    system("You left voice")
  }

  func setVoiceMuted(_ muted: Bool) {
    voiceEngineStorage?.setMuted(muted)
  }

  /// Hold-to-talk button pressed / released.
  func setPushToTalkHeld(_ held: Bool) {
    voiceEngineStorage?.setHeld(held)
  }

  /// Push-to-talk was switched in the settings.
  func voiceSettingsChanged() {
    voiceEngineStorage?.refresh()
    updateDuck()
  }

  /// Local mute / volume (0-1) of a member's voice, only for us.
  func setMemberVoice(_ userId: String, muted: Bool? = nil, volume: Double? = nil) {
    let engine = voiceEngineInstance
    engine.setMix(userId, muted: muted, volume: volume)
    voiceMixes[userId] = engine.mix(of: userId)
  }

  /// Names of the other members speaking (player overlay while the panel is closed).
  var speakingNames: [(userId: String, name: String)] {
    guard voice.joined else { return [] }
    return voiceStates.filter { $0.value.joined && $0.value.speaking && hasUser($0.key) }
      .map { (userId: $0.key, name: nameOf($0.key)) }
      .sorted { $0.name < $1.name }
  }

  private func memberVoice(_ userId: String) -> W2GMemberVoice {
    let state = voiceStates[userId] ?? W2GVoiceState()
    return W2GMemberVoice(joined: state.joined, muted: state.muted, speaking: state.speaking, connected: voiceLinks[userId], mix: voiceMixes[userId] ?? W2GVoiceMix())
  }

  private func hasFeature(_ userId: String, _ feature: String) -> Bool {
    members.contains { !$0.isSelf && $0.userId == userId && $0.features.contains(feature) }
  }

  private func memberInVoice(_ userId: String) -> Bool {
    (voiceStates[userId]?.joined ?? false) && hasFeature(userId, "voice") && !banned.contains(userId)
  }

  /// Sends an event to one member (its first open link).
  @discardableResult
  private func sendToUser(_ userId: String?, type: String, payload: W2GJSON) -> Bool {
    guard let userId, let swarm else { return false }
    for member in members where !member.isSelf && member.userId == userId && swarm.isPeerConnected(member.id) {
      sendEvent(to: member.id, type: type, payload: payload)
      return true
    }
    return false
  }

  /// Our voice state changed: views, `voice` to everyone when it differs, links, ducking.
  private func voiceEngineChanged() {
    guard let engine = voiceEngineStorage else { return }
    voice = engine.view
    let payload = engine.payload
    if payload != lastVoicePayload {
      lastVoicePayload = payload
      broadcast(type: "voice", payload: payload.json)
    }
    syncVoiceLinks()
    updateDuck()
  }

  private func receivedVoice(_ payload: W2GJSON, from userId: String) {
    guard userId != selfId else { return }
    let state = W2GSync.normalizeVoice(payload)
    let previous = voiceStates[userId]
    voiceStates[userId] = state
    if state.joined != (previous?.joined ?? false) && (previous != nil || state.joined) {
      system("\(nameOf(userId)) \(state.joined ? "joined" : "left") voice")
    }
    syncVoiceLinks()
    updateDuck()
  }

  private func receivedVoiceSignal(_ payload: W2GJSON, from userId: String) {
    guard let engine = voiceEngineStorage, engine.joined else { return }
    if payload["sdp"]?["type"]?.stringValue == "offer" {
      guard W2GSync.acceptsVoiceOffer(selfJoined: engine.joined, memberJoined: memberInVoice(userId), selfId: selfId, senderId: userId) else { return }
    }
    engine.signal(from: userId, payload: payload)
  }

  /// Creates the links we offer and closes the ones nobody needs anymore.
  private func syncVoiceLinks() {
    guard let engine = voiceEngineStorage else { return }
    let ids = connectedUserIds()
    for userId in ids {
      let action = W2GSync.voiceLinkAction(
        selfJoined: engine.joined,
        memberJoined: voiceStates[userId]?.joined ?? false,
        memberHasVoice: hasFeature(userId, "voice"),
        hasLink: engine.hasLink(userId),
        selfOffers: W2GSync.voiceOffers(selfId: selfId, otherId: userId)
      )
      switch action {
      case .offer: engine.connect(userId)
      case .close: engine.close(userId)
      case .wait, .none: break
      }
    }
    for userId in engine.linkStates.keys where !ids.contains(userId) { engine.close(userId) }
  }

  /// Lowers the video while a member we hear speaks (setting `w2gVoiceDucking`).
  private func updateDuck() {
    let candidates = connectedUserIds().map { userId -> W2GDuckCandidate in
      let state = voiceStates[userId] ?? W2GVoiceState()
      let mix = voiceMixes[userId] ?? W2GVoiceMix()
      return W2GDuckCandidate(joined: state.joined, speaking: state.speaking, localMuted: mix.muted, volume: mix.volume)
    }
    let level = W2GSync.duckLevel(enabled: AppSettings.shared.values.w2gVoiceDucking, selfJoined: voice.joined, members: candidates)
    guard level != lastDuck else { return }
    lastDuck = level
    onDuck?(level)
  }

  /// A member left the lobby or was kicked: no more voice with it.
  private func forgetVoice(_ userId: String) {
    voiceEngineStorage?.forget(userId)
    voiceStates[userId] = nil
    voiceLinks[userId] = nil
    voiceMixes[userId] = nil
    updateDuck()
  }

  // MARK: v2.4 shared queue

  /// The queue exists: we are the host, or the host's app supports it.
  var queueAvailable: Bool {
    guard isInLobby, let hostId else { return false }
    return hostId == selfId || hasFeature(hostId, "queue")
  }

  /// "Add to Watch Together queue": the host adds it at once, a member sends it to the host (a suggestion when the
  /// host asks for approval). Shows the result as a notice.
  @discardableResult
  func addToQueue(media: Media, episode: EpisodeRef) -> W2GQueueAddResult {
    addToQueue(mediaJSON: W2GMediaPayload.json(from: media), episodeJSON: W2GMediaPayload.episodeJSON(episode), title: Self.sharedTitle(media), cover: (media.images.cover ?? media.images.coverLarge)?.absoluteString ?? "")
  }

  @discardableResult
  private func addToQueue(mediaJSON: W2GJSON, episodeJSON: W2GJSON, title: String, cover: String) -> W2GQueueAddResult {
    guard queueAvailable else {
      post(title: "Watch Together", message: W2GQueueAddResult.unavailable.text)
      return .unavailable
    }
    let key = W2GMediaPayload.key(mediaId: mediaJSON["id"], episode: episodeJSON)
    let result: W2GQueueAddResult
    if (queue.items + queue.pending).contains(where: { W2GSync.sameQueueEntry(key: key, mediaId: mediaJSON["id"], episode: episodeJSON, as: $0) }) {
      result = .duplicate
    } else {
      var fields: [(String, W2GJSON?)] = []
      fields.append(("id", .text(W2GHex.randomCode(12))))
      fields.append(("media", mediaJSON))
      fields.append(("episode", episodeJSON))
      fields.append(("key", .text(key)))
      fields.append(("title", .text(String(title.prefix(120)))))
      fields.append(("cover", .text(String(cover.prefix(500)))))
      fields.append(("addedBy", .text(selfId)))
      fields.append(("addedByName", .text(selfUser.displayName)))
      let item = W2GJSON.dict(fields)
      if isHost {
        result = hostQueueChange(.add(item: item, by: selfId, byName: selfUser.displayName, byHost: true)) ? .added : .duplicate
      } else if sendToUser(hostId, type: "queueAdd", payload: W2GJSON.dict([("item", item)])) {
        result = queue.policy == .approval ? .suggested : .added
      } else {
        result = .unavailable
      }
    }
    post(title: "Watch Together", message: result.text)
    return result
  }

  /// "Add next episode": the episode after the lobby media (or after the last queued one of that title).
  var nextEpisodeLabel: String? {
    guard let target = W2GSync.nextEpisodeTarget(lobbyMedia: sharedMedia?.mediaJSON, lobbyEpisode: sharedMedia?.episodeJSON, queue: queue) else { return nil }
    let ref = W2GMediaPayload.episodeRef(from: target.episode) ?? EpisodeRef(number: 1)
    return W2GSync.episodeLabel(number: ref.number, season: ref.season, localEpisode: ref.localEpisode)
  }

  func addNextEpisode() {
    guard let target = W2GSync.nextEpisodeTarget(lobbyMedia: sharedMedia?.mediaJSON, lobbyEpisode: sharedMedia?.episodeJSON, queue: queue) else { return }
    let media = W2GMediaPayload.media(from: target.media)
    let cover = target.media["coverImage"]?["medium"]?.stringValue ?? target.media["coverImage"]?["extraLarge"]?.stringValue ?? ""
    addToQueue(mediaJSON: target.media, episodeJSON: target.episode, title: Self.sharedTitle(media), cover: cover)
  }

  /// Up-vote toggle on an item.
  func voteQueueItem(_ id: String) {
    guard queueAvailable, let item = queue.items.first(where: { $0.id == id }) else { return }
    let up = !item.votes.contains(selfId)
    if isHost {
      _ = hostQueueChange(.vote(id: id, by: selfId, up: up))
    } else {
      sendToUser(hostId, type: "queueVote", payload: W2GJSON.dict([("id", .text(id)), ("up", .bool(up))]))
    }
  }

  /// The host removes any item; a member removes its own item or suggestion.
  func removeQueueItem(_ id: String) {
    if isHost {
      _ = hostQueueChange(.remove(id: id, by: selfId, byHost: true))
      return
    }
    guard let item = (queue.items + queue.pending).first(where: { $0.id == id }), item.addedBy == selfId else { return }
    queueCancelled.insert(id)
    sendToUser(hostId, type: "queueRemove", payload: W2GJSON.dict([("id", .text(id))]))
  }

  /// Host: move an item up (-1) or down (+1).
  func moveQueueItem(_ id: String, by delta: Int) {
    _ = hostQueueChange(.move(id: id, delta: delta))
  }

  /// Host: accept or decline a suggestion.
  func answerSuggestion(_ id: String, accepted: Bool) {
    _ = hostQueueChange(.answer(id: id, accepted: accepted))
  }

  /// Host: "Members need approval".
  func setQueuePolicy(_ policy: W2GQueuePolicy) {
    _ = hostQueueChange(.policy(policy))
  }

  /// Host "Play now": the item becomes the lobby media and starts here; a countdown follows once it is loaded.
  func playQueueItem(_ id: String) {
    guard isInLobby, isHost, following, let item = queue.items.first(where: { $0.id == id }) else { return }
    cancelAdvance()
    _ = hostQueueChange(.remove(id: id, by: selfId, byHost: true))
    let ownKey = W2GMediaPayload.key(mediaId: item.mediaJSON["id"], episode: item.episodeJSON)
    let shared = W2GSharedMedia(key: item.key, localKey: ownKey, mediaJSON: item.mediaJSON, episodeJSON: item.episodeJSON, media: item.media, episode: item.episode)
    rejoinLabel = nil
    pendingRejoinKey = nil
    pendingJoin = nil
    pendingInvite = nil
    pendingQueueStart = (key: item.key, at: W2GSync.nowMs())
    sharedMedia = shared
    broadcast(type: "media", payload: shared.payload)
    system("You started \(item.label) from Up next")
    startShared(shared)
  }

  /// The player reached the end of the episode. Host with a queued item: "Up next" counts down 5 s, then plays it.
  func playbackEnded() {
    guard isInLobby, isHost, following, advance == nil, let item = queue.items.first else { return }
    advance = W2GAdvance(item: item, endsAt: W2GSync.nowMs() + W2GSync.queueAdvanceSeconds * 1000)
    advanceTask = w2gAfter(W2GSync.queueAdvanceSeconds) { [weak self] in
      self?.advanceTask = nil
      self?.advanceNow()
    }
  }

  /// "Play now" of the auto-advance prompt (also when its countdown ends).
  func advanceNow() {
    guard let item = advance?.item else { return }
    cancelAdvance()
    playQueueItem(item.id)
  }

  func cancelAdvance() {
    advanceTask?.cancel()
    advanceTask = nil
    if advance != nil { advance = nil }
  }

  private func receivedQueue(_ payload: W2GJSON, from senderId: String) {
    guard !isHost, W2GSync.acceptsQueue(senderId: senderId, hostId: hostId, tentative: hostTentative) else { return }
    guard let next = W2GSync.normalizeQueue(payload) else { return }
    applyQueue(next)
  }

  /// Host: one change of the queue, then `queue` to everyone.
  private func hostQueueChange(_ change: W2GQueueChange) -> Bool {
    guard isHost, let next = W2GSync.queueReduce(queue, change) else { return false }
    applyQueue(next)
    broadcast(type: "queue", payload: next.json)
    return true
  }

  /// New queue (ours as host, or the host's): chat lines for what changed, a notice for the host's suggestions.
  private func applyQueue(_ next: W2GQueue) {
    let previous: W2GQueue? = queueKnown ? queue : nil
    queueKnown = true
    queue = next
    for change in W2GSync.queueChanges(previous: previous, next: next, selfId: selfId, cancelled: queueCancelled) {
      let text = W2GSync.describeQueueChange(change, selfId: selfId)
      system(text)
      if change.kind == .suggested && isHost && !isPlayerPanelOpen { showNotice(text) }
    }
    if let current = advance, !next.items.contains(where: { $0.id == current.item.id }) { cancelAdvance() }
  }

  // MARK: Host, sync, helpers

  private func setLobby(hostId newHost: String?, mode newMode: W2GMode, tentative: Bool) {
    let previousHost = hostId
    let previousMode = mode
    hostId = newHost
    mode = newMode
    hostTentative = tentative
    if previousHost != newHost {
      autoSync = W2GAutoSyncMemory()
      lastHostPlayer = nil
      if let newHost {
        system(newHost == selfId ? "You are now the host" : "\(nameOf(newHost)) is now the host")
      }
      if let previousHost, previousHost == selfId {
        // No longer host: pending requests go to the new host.
        for task in requestTimers.values { task.cancel() }
        requestTimers = [:]
        pendingRequests = []
        cancelAdvance()
        pendingQueueStart = nil
      }
      // v2.4: a new host takes over its copy of the queue and shares it at once.
      if let newHost, newHost == selfId, !tentative {
        queueKnown = true
        broadcast(type: "queue", payload: queue.json)
      }
    }
    if previousMode != newMode {
      system(newMode == .host ? "Only the host controls playback now" : "Everyone can control playback now")
    }
  }

  /// The host left: the smallest userId among us and the connected peers takes over.
  private func migrateHost() {
    // v2.2: members watching on their own are skipped unless nobody follows.
    let candidates = W2GSync.migrationCandidates(selfId: selfId, selfFollowing: following, peers: electionPeers())
    let elected = W2GSync.electHost(candidates) ?? selfId
    if elected == selfId {
      setLobby(hostId: selfId, mode: mode, tentative: false)
      broadcast(type: "host", payload: hostPayload(hostId: selfId))
    } else {
      // Until the elected client confirms with `host`, accept a claim from anyone.
      setLobby(hostId: elected, mode: mode, tentative: true)
    }
  }

  private func checkAutoSync(now: Double) {
    guard following, let hostId else { return }
    sampleLocalPlayback(now: now)
    let host = signals[hostId]
    let result = W2GSync.autoSyncStep(
      autoSync,
      enabled: AppSettings.shared.values.w2gAutoSync,
      isHost: isHost,
      hostStatus: host?.status,
      hostReceivedAt: host?.receivedAt ?? now,
      hostRtt: host?.rtt,
      local: local,
      now: now
    )
    autoSync = result.memory
    guard let seekTo = result.seekTo else { return }
    applyLocally(time: seekTo, paused: false, by: hostId)
  }

  private func apply(_ command: W2GPlayerCommand) {
    if let onApplyPlayer {
      onApplyPlayer(command)
    } else {
      onRemotePlayer?(command.paused, command.time)
    }
  }

  /// Applies a state to our player without broadcasting or announcing it (`sync`).
  private func applyLocally(time: Double, paused: Bool, by: String?) {
    player = W2GPlayerState(paused: paused, time: time)
    apply(W2GPlayerCommand(time: time, paused: paused, action: .sync, by: by ?? selfId, rate: 1, isPrecise: true))
  }

  private func hostTarget(now: Double) -> W2GHostTarget? {
    guard let hostId, !isHost else { return nil }
    let host = signals[hostId]
    return W2GSync.hostReference(status: host?.status, receivedAt: host?.receivedAt, rttMs: host?.rtt, lastPlayer: lastHostPlayer, now: now)
  }

  /// Our position now, nil when we are not watching.
  private func localTime(_ now: Double) -> Double? {
    if local.state == .idle || local.state == .loading { return nil }
    return W2GSync.expectedTime(local.status, receivedAt: local.at, now: now, rttMs: 0)
  }

  private func runCountdown(time: Double, seconds: Int, endsAt: Double, by: String) {
    cancelCountdown()
    applyLocally(time: time, paused: true, by: by)
    let value = W2GCountdown(time: time, seconds: seconds, endsAt: endsAt, by: by)
    countdown = value
    let valueId = value.id
    let delay = max(0, endsAt - W2GSync.nowMs()) / 1000
    countdownTask = w2gAfter(delay) { [weak self] in
      guard let self, self.countdown?.id == valueId else { return }
      self.countdownTask = nil
      self.countdown = nil
      self.applyLocally(time: time, paused: false, by: by)
    }
  }

  private func cancelCountdown() {
    countdownTask?.cancel()
    countdownTask = nil
    if countdown != nil { countdown = nil }
  }

  private func ban(_ userId: String) {
    guard !banned.contains(userId) else { return }
    let user = userOf(userId)
    banned.insert(userId)
    let peerIds = members.filter { !$0.isSelf && $0.userId == userId }.map { $0.id }
    members.removeAll { !$0.isSelf && $0.userId == userId }
    signals[userId] = nil
    lastSeen[userId] = nil
    presence[userId] = nil
    invites.removeAll { $0.from == userId }
    forgetVoice(userId)
    for peerId in peerIds { swarm?.block(peerId) }
    let name = user?.displayName ?? W2GSync.memberName(name: nil, typedName: nil, id: userId)
    system("\(name) was removed from the lobby")
  }

  private func showReaction(_ emoji: String, from userId: String) {
    system("\(nameOf(userId)) reacted \(emoji)", emoji: emoji)
    let item = W2GFloatingReaction(emoji: emoji, inset: Double.random(in: 0.04...0.18))
    floatingReactions = Array((floatingReactions + [item]).suffix(12))
    let itemId = item.id
    w2gAfter(W2GSync.reactionSeconds) { [weak self] in
      self?.floatingReactions.removeAll { $0.id == itemId }
    }
  }

  /// Notice over the video (someone's action, request answers, resync feedback).
  private func showNotice(_ text: String, request: W2GNoticeRequest? = nil, seconds: Double = W2GSync.noticeSeconds) {
    let item = W2GOverlayNotice(text: text, request: request)
    var list = overlayNotices
    // Only one "Only the host controls playback" at a time.
    if request != nil { list.removeAll { $0.request != nil } }
    list = Array(list.suffix(2))
    list.append(item)
    overlayNotices = list
    let itemId = item.id
    w2gAfter(seconds) { [weak self] in
      self?.dismissOverlayNotice(itemId)
    }
  }

  /// Local feedback: over the video, and in the lobby screen banner (no toast).
  private func info(_ text: String) {
    showNotice(text)
    notice = W2GNotice(title: "Watch Together", message: text)
  }

  private func showBlocked(action: W2GAction, time: Double) {
    let kind: W2GRequestKind
    let label: String
    switch action {
    case .seek:
      kind = .seek
      label = "Request jump to \(W2GSync.formatClock(time))"
    case .pause:
      kind = .pause
      label = "Request pause"
    case .play, .sync:
      kind = .play
      label = "Request play"
    }
    let request = W2GNoticeRequest(kind: kind, time: kind == .seek ? time : nil, label: label)
    showNotice("Only the host controls playback", request: request, seconds: W2GSync.blockedNoticeSeconds)
  }

  private func userIdOf(_ peerId: String) -> String {
    members.first(where: { !$0.isSelf && $0.id == peerId })?.userId ?? peerId
  }

  private func userOf(_ userId: String) -> W2GUser? {
    if userId == selfId { return selfUser }
    return members.first(where: { !$0.isSelf && $0.userId == userId })?.user
  }

  private func hasUser(_ userId: String) -> Bool {
    members.contains { !$0.isSelf && $0.userId == userId }
  }

  /// Remote participants that introduced themselves (host election).
  private func connectedUserIds() -> [String] {
    var ids: [String] = []
    for member in members where !member.isSelf && member.introduced && !banned.contains(member.userId) {
      if !ids.contains(member.userId) { ids.append(member.userId) }
    }
    return ids
  }

  private func push(_ message: W2GChatMessage) {
    var list = messages
    list.append(message)
    if list.count > Self.maxMessages { list.removeFirst(list.count - Self.maxMessages) }
    messages = list
  }

  /// Local chat line (joins, leaves, actions, requests, reactions).
  private func system(_ text: String, emoji: String? = nil) {
    push(W2GChatMessage(system: text, emoji: emoji))
  }

  /// `String(value)` of an id field; nil when missing, null or "".
  private static func idString(_ value: W2GJSON?) -> String? {
    guard let value, !value.isNull else { return nil }
    if case .string(let units) = value, units.isEmpty { return nil }
    return W2GJSON.jsTemplateString(value)
  }

  /// `Number(value)` for the fields that may come as text; nil when missing or not a number.
  private static func numberValue(_ value: W2GJSON?) -> Double? {
    guard let value else { return nil }
    switch value {
    case .number(let number):
      return number.isFinite ? number : nil
    case .string:
      let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return Double(text)
    case .bool(let flag):
      return flag ? 1 : 0
    default:
      return nil
    }
  }
}
