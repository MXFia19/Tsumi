import Foundation
import Observation
import UIKit

// Watch Together lobby: native port of common/routes/w2g/components/w2g.js (W2GClient),
// session.js (shareNowPlaying) and the module part of WatchTogetherPage.svelte (joinLobby,
// invite, deep links). Participants find each other through public WebTorrent trackers
// (W2GSwarm, P2PT protocol) and exchange small JSON events over WebRTC data channels:
//   {"payload": …, "type": "init" | "media" | "index" | "player" | "message"}
//
// Wiring (done in UI/Shell/AppWiring.swift configureWatchTogether, UI/Shell/ShellPlayback.swift and
// UI/Shell/ShellNavigation.swift):
//   currentUser, onRemoteMedia, onRemotePlayer, onRemoteIndex, onNotice, onShowLobby closures;
//   deep links → handle(url:) / join(link:); scenePhase .active → appBecameActive();
//   player: shareMedia(media:episode:) when an episode starts, playerStateChanged(paused:time:) on
//   play/pause/seeked, mediaIndexChanged(_:) on file change.

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

  // MARK: Wiring

  /// Signed-in account (Helper.getUser()); nil → anonymous `{ id: <16 hex> }`.
  @ObservationIgnored var currentUser: () -> Viewer? = { nil }
  /// Another participant started a title: start the same one locally.
  @ObservationIgnored var onRemoteMedia: ((Media, EpisodeRef) -> Void)?
  /// Remote play/pause/seek: (paused, time in seconds).
  @ObservationIgnored var onRemotePlayer: ((Bool, Double) -> Void)?
  /// Remote file index change (playlist position in the player).
  @ObservationIgnored var onRemoteIndex: ((Int) -> Void)?
  /// Toast request (title, message).
  @ObservationIgnored var onNotice: ((String, String) -> Void)?
  /// A deep link joined a lobby: show the Watch Together screen.
  @ObservationIgnored var onShowLobby: (() -> Void)?

  // MARK: State

  private(set) var code: String?
  private(set) var isHost = false
  private(set) var selfUser = W2GUser.anonymous()
  /// Local user first, then remote participants that introduced themselves (`init`).
  private(set) var members: [W2GMember] = []
  private(set) var messages: [W2GChatMessage] = []
  private(set) var sharedMedia: W2GSharedMedia?
  private(set) var player = W2GPlayerState()
  private(set) var mediaIndex = 0
  private(set) var connectedTrackers = 0
  private(set) var totalTrackers = 0
  /// Open WebRTC links (all peers, backups included).
  private(set) var openConnections = 0
  /// Latest notice, for the in-screen banner.
  private(set) var notice: W2GNotice?

  @ObservationIgnored private var swarm: W2GSwarm?

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
    swarm?.destroy()
    swarm = nil
    code = nil
    isHost = false
    members = []
    messages = []
    sharedMedia = nil
    player = W2GPlayerState()
    mediaIndex = 0
    connectedTrackers = 0
    totalTrackers = 0
    openConnections = 0
    notice = nil
  }

  /// Call when the app returns to the foreground: reconnects dropped trackers and re-announces.
  func appBecameActive() {
    swarm?.refresh()
  }

  private func start(code requested: String?) {
    leave()
    let lobbyCode = requested ?? W2GHex.randomCode(16)
    isHost = requested == nil
    if let viewer = currentUser() {
      selfUser = W2GUser(viewer: viewer)
    } else {
      selfUser = W2GUser.anonymous()
    }
    code = lobbyCode
    members = [W2GMember(id: "self", user: selfUser, isSelf: true)]

    let newSwarm = W2GSwarm(announceURLs: Self.signalingServers, identifier: lobbyCode)
    newSwarm.onPeerConnect = { [weak self] peerId in self?.peerConnected(peerId) }
    newSwarm.onMessage = { [weak self] peerId, payload in self?.received(payload, from: peerId) }
    newSwarm.onPeerClose = { [weak self] peerId in self?.peerClosed(peerId) }
    newSwarm.onStatusChange = { [weak self] in self?.refreshStatus() }
    swarm = newSwarm
    newSwarm.start()
    refreshStatus()

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

  // MARK: Outgoing (w2g.js public API)

  /// session.js shareNowPlaying → W2GClient.shareMedia: a title/episode was started locally.
  func shareMedia(media: Media, episode: EpisodeRef) {
    guard isInLobby else { return }
    let mediaJSON = W2GMediaPayload.json(from: media)
    let episodeJSON = W2GMediaPayload.episodeJSON(episode)
    let payloadId = mediaJSON["id"] ?? W2GJSON.null
    let key = W2GMediaPayload.key(mediaId: payloadId, episode: episodeJSON)
    if let current = sharedMedia {
      // Already what everyone plays (also stops the echo after a remote `media` event).
      if current.key == key || current.matches(media: media, episode: episode, payloadId: payloadId) { return }
    }
    let shared = W2GSharedMedia(key: key, mediaJSON: mediaJSON, episodeJSON: episodeJSON, media: media, episode: episode)
    sharedMedia = shared
    broadcast(type: "media", payload: shared.payload)
  }

  /// W2GClient.playerStateChanged; the JS player sends Math.floor(currentTime) on play/pause/seeked.
  func playerStateChanged(paused: Bool, time: Double) {
    guard isInLobby, time.isFinite else { return }
    let state = W2GPlayerState(paused: paused, time: max(0, time.rounded(.down)))
    guard state != player else { return }
    player = state
    broadcast(type: "player", payload: state.json)
  }

  /// W2GClient.mediaIndexChanged.
  func mediaIndexChanged(_ index: Int) {
    guard isInLobby, index != mediaIndex else { return }
    mediaIndex = index
    broadcast(type: "index", payload: W2GJSON.dict([("index", W2GJSON.int(index))]))
  }

  /// W2GClient.message: chat message from the local user.
  func sendMessage(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isInLobby, !trimmed.isEmpty else { return }
    let limited = String(trimmed.prefix(2048))
    messages.append(W2GChatMessage(text: limited, user: selfUser, direction: .outgoing))
    broadcast(type: "message", payload: W2GJSON.text(limited))
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

  /// #sendToPeers: only participants that already sent `init`.
  private func broadcast(type: String, payload: W2GJSON) {
    guard let swarm else { return }
    let text = Self.encodeEvent(type: type, payload: payload)
    for member in members where !member.isSelf {
      swarm.send(text, to: member.id)
    }
  }

  /// #onPeerconnect: introduce ourselves; the host also sends the current state.
  private func peerConnected(_ peerId: String) {
    sendEvent(to: peerId, type: "init", payload: selfUser.json)
    if isHost { sendInitialSessionState(to: peerId) }
    // P2PT can miss its one-time 'peerconnect' when the first of several parallel links fails,
    // and then that peer never sends `init`. List it as anonymous after a while so it still gets
    // the lobby events (its real `init`, if it comes, replaces this entry).
    let lobby = code
    w2gAfter(Self.introductionGrace) { [weak self] in
      guard let self, self.code == lobby, let swarm = self.swarm, swarm.isPeerConnected(peerId) else { return }
      guard !self.members.contains(where: { !$0.isSelf && $0.id == peerId }) else { return }
      self.members.append(W2GMember(id: peerId, user: W2GUser(id: peerId), isSelf: false))
    }
  }

  /// Delay before a connected peer that never sent `init` is listed anyway.
  static let introductionGrace: Double = 8

  private func sendInitialSessionState(to peerId: String) {
    if let sharedMedia { sendEvent(to: peerId, type: "media", payload: sharedMedia.payload) }
    sendEvent(to: peerId, type: "index", payload: W2GJSON.dict([("index", W2GJSON.int(mediaIndex))]))
    sendEvent(to: peerId, type: "player", payload: player.json)
  }

  /// #onPeerclose
  private func peerClosed(_ peerId: String) {
    members.removeAll { !$0.isSelf && $0.id == peerId }
    refreshStatus()
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

    switch type {
    case "init":
      receivedInit(payload, from: peerId)
    case "media":
      receivedMedia(payload)
    case "index":
      guard let index = payload["index"]?.intValue else { return }
      if index != mediaIndex {
        mediaIndex = index
        onRemoteIndex?(index)
      }
    case "player":
      guard let time = payload["time"]?.doubleValue else { return }
      let paused = payload["paused"]?.isTruthy ?? false
      let state = W2GPlayerState(paused: paused, time: time)
      if state != player {
        player = state
        onRemotePlayer?(paused, time)
      }
    case "message":
      receivedChat(payload, from: peerId)
    default:
      break
    }
  }

  private func receivedInit(_ payload: W2GJSON, from peerId: String) {
    let user = W2GUser(json: payload, fallbackId: peerId)
    let member = W2GMember(id: peerId, user: user, isSelf: false)
    if let index = members.firstIndex(where: { !$0.isSelf && $0.id == peerId }) {
      members[index] = member
    } else {
      members.append(member)
    }
  }

  private func receivedMedia(_ payload: W2GJSON) {
    guard let mediaJSON = payload["media"], let mediaId = mediaJSON["id"], mediaId.isTruthy else { return }
    if let sentKey = payload["key"]?.stringValue, sentKey == sharedMedia?.key { return }
    let episodeValue = payload["episode"]
    let key = W2GMediaPayload.key(mediaId: mediaId, episode: episodeValue)
    if key == sharedMedia?.key { return }
    let media = W2GMediaPayload.media(from: mediaJSON)
    let episode = W2GMediaPayload.episodeRef(from: episodeValue) ?? EpisodeRef(number: 1)
    sharedMedia = W2GSharedMedia(key: key, mediaJSON: mediaJSON, episodeJSON: episodeValue ?? W2GJSON.null, media: media, episode: episode)

    // WatchTogetherPage.svelte toast: "Starting <anilistClient.title(media) || 'the shared title'> - Episode N"
    var title = "the shared title"
    if let media, !media.title.all.isEmpty {
      let display = AniListService.shared.title(media)
      if !display.isEmpty { title = display }
    }
    var episodeNumber: Int?
    if let episodeValue {
      episodeNumber = episodeValue.isObject ? episodeValue["number"]?.intValue : episodeValue.intValue
    }
    let suffix = episodeNumber.map { $0 != 0 ? " - Episode \($0)" : "" } ?? ""
    post(title: "Watch Together", message: "Starting \(title)\(suffix)")

    if let media { onRemoteMedia?(media, episode) }
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
    // A message can arrive before the sender introduced itself.
    let user = members.first(where: { !$0.isSelf && $0.id == peerId })?.user ?? W2GUser(id: peerId)
    messages.append(W2GChatMessage(text: text, user: user, direction: .incoming))
  }
}
