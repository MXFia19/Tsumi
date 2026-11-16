import CryptoKit
import Foundation

// Native equivalent of P2PT (github:ThaUnknown/p2pt#modernise, p2pt.js):
//   - info_hash = SHA-1(UTF-8 of the identifier string, i.e. the 16-hex lobby code), 20 bytes
//   - peer_id = 20 random bytes; remote peers are keyed by the hex of their peer_id
//   - several WebRTC links to the same peer id are kept as backups (one per tracker/offer);
//     'peerconnect' fires when the first one opens, 'peerclose' when the last one closes
//   - message framing: "^" + JSON.stringify({ id, msg, c, last? }) per chunk, where `id` is a
//     random integer in 100000...199999, `msg` a slice of at most 16000 UTF-16 code units of the
//     payload string, `c` the chunk index and `last: true` on the final chunk; `o: 1` means the
//     reassembled payload is itself JSON (P2PT `send(peer, object)`; w2g.js always sends strings)

@MainActor
final class W2GSwarm {
  /// P2PT MAX_MESSAGE_LENGTH (UTF-16 code units per chunk).
  static let maxMessageLength = 16000
  /// P2PT JSON_MESSAGE_IDENTIFIER.
  static let messagePrefix = "^"
  /// Backup links kept per remote peer (P2PT keeps them all; capped here to save resources).
  static let maxLinksPerPeer = 3
  /// v2.5 (W2GSync limits, sync.js ChunkAssembler): chunk index `c` below maxChunks, at most maxEventUnits per message
  /// and maxBufferedUnits in total, maxPendingMessages in progress per peer, each dropped after chunkTimeoutMs.
  static let maxChunksPerMessage = W2GSync.maxChunks
  /// A frame carries at most 16000 units of message (escaped at worst six times): anything bigger is not P2PT.
  static let maxFrameUnits = 128_000

  let identifier: String
  let infoHash: [UInt8]
  let peerId: [UInt8]
  let peerIdHex: String
  let announceURLs: [String]

  var onPeerConnect: ((String) -> Void)?
  /// (remote peer id, payload): `.string` for plain messages, any JSON when sent with `o: 1`.
  var onMessage: ((String, W2GJSON) -> Void)?
  var onPeerClose: ((String) -> Void)?
  var onStatusChange: (() -> Void)?

  private var trackers: [W2GTrackerConnection] = []
  /// Open links by remote peer id (P2PT `this.peers[id][channelName]`).
  private var openLinks: [String: [W2GPeerLink]] = [:]
  /// Links whose remote peer is known but that are not open yet.
  private var connectingLinks: [ObjectIdentifier: W2GPeerLink] = [:]
  /// Partial messages: "<peer id>:<msg id>" → chunks received so far.
  private var chunkBuffers: [String: W2GPartialMessage] = [:]
  /// UTF-16 units held by `chunkBuffers`.
  private var bufferedUnits = 0
  /// P2PT message ids each peer sent us (see send(_:to:)).
  private var receivedMessageIds: [String: Set<Int>] = [:]
  /// Peers removed from the lobby (Watch Together `kick`): their links are closed and refused.
  private var blockedPeerIds = Set<String>()
  private var isDestroyed = false

  init(announceURLs: [String], identifier: String) {
    self.announceURLs = announceURLs
    self.identifier = identifier
    infoHash = Array(Insecure.SHA1.hash(data: Data(identifier.utf8)))
    let id = W2GHex.randomBytes(20)
    peerId = id
    peerIdHex = W2GHex.encode(id)
  }

  /// P2PT start(): one WebSocket tracker per announce URL, each announcing with 5 offers.
  func start() {
    guard trackers.isEmpty, !isDestroyed else { return }
    for string in announceURLs {
      guard let url = URL(string: string) else { continue }
      let tracker = W2GTrackerConnection(url: url, swarm: self)
      trackers.append(tracker)
      tracker.start()
    }
    onStatusChange?()
  }

  /// requestMorePeers(), plus an immediate reconnect of trackers that are down.
  func refresh() {
    for tracker in trackers { tracker.refresh() }
  }

  var trackerCount: Int { trackers.count }
  var connectedTrackerCount: Int { trackers.filter { $0.isConnected }.count }
  var connectedPeerIds: [String] { Array(openLinks.keys) }

  func isPeerConnected(_ peerId: String) -> Bool {
    !(openLinks[peerId] ?? []).isEmpty
  }
  var openLinkCount: Int { openLinks.values.reduce(0) { $0 + $1.count } }

  func trackerStatusChanged() {
    onStatusChange?()
  }

  // MARK: Links (P2PT 'peer' / 'connect' / 'close' handling)

  func makeLink(initiator: Bool) -> W2GPeerLink? {
    guard !isDestroyed else { return nil }
    return W2GPeerLink(initiator: initiator)
  }

  func canAcceptLink(from peerId: String) -> Bool {
    guard !isDestroyed, peerId != peerIdHex, !blockedPeerIds.contains(peerId) else { return false }
    let open = openLinks[peerId]?.count ?? 0
    let pending = connectingLinks.values.filter { $0.remotePeerId == peerId }.count
    return open + pending < Self.maxLinksPerPeer
  }

  /// A link whose remote peer id is known (P2PT 'peer' event).
  func adopt(_ link: W2GPeerLink, peerId: String) {
    guard !isDestroyed else {
      link.destroy()
      return
    }
    link.remotePeerId = peerId
    connectingLinks[ObjectIdentifier(link)] = link
    link.onOpen = { [weak self] link in self?.linkOpened(link) }
    link.onMessage = { [weak self] link, text in self?.linkReceived(link, text) }
    link.onClose = { [weak self] link in self?.linkClosed(link) }
    if link.isOpen { linkOpened(link) }
  }

  private func linkOpened(_ link: W2GPeerLink) {
    connectingLinks[ObjectIdentifier(link)] = nil
    guard let id = link.remotePeerId, !blockedPeerIds.contains(id) else {
      link.destroy()
      return
    }
    var links = openLinks[id] ?? []
    let isNewPeer = links.isEmpty
    links.append(link)
    openLinks[id] = links
    onStatusChange?()
    if isNewPeer { onPeerConnect?(id) }
  }

  private func linkClosed(_ link: W2GPeerLink) {
    connectingLinks[ObjectIdentifier(link)] = nil
    guard let id = link.remotePeerId, var links = openLinks[id] else { return }
    let before = links.count
    links.removeAll { $0 === link }
    guard links.count != before else { return }
    if links.isEmpty {
      openLinks[id] = nil
      receivedMessageIds[id] = nil // P2PT forgets responseWaiting[id] on peerclose too
      let prefix = id + ":"
      for key in Array(chunkBuffers.keys) where key.hasPrefix(prefix) { dropChunks(key) }
      onStatusChange?()
      onPeerClose?(id)
    } else {
      openLinks[id] = links
      onStatusChange?()
    }
  }

  // MARK: Messages

  /// P2PT 'data' handler: unwraps "^{...}" envelopes and reassembles chunks, within the v2.5 limits.
  private func linkReceived(_ link: W2GPeerLink, _ text: String) {
    guard let id = link.remotePeerId, text.hasPrefix(Self.messagePrefix), text.utf16.count <= Self.maxFrameUnits else { return }
    guard let envelope = W2GJSONParser.parse(String(text.dropFirst())) else { return }
    guard let messageId = envelope["id"], let units = envelope["msg"]?.utf16Value else { return }
    // Only ids we could pick ourselves can collide (send(_:to:)): the others are not kept (a peer could send millions).
    if let number = messageId.intValue, (100000...199999).contains(number) { receivedMessageIds[id, default: []].insert(number) }
    let now = W2GSync.nowMs()
    expireChunks(now: now)
    let idText = W2GJSONWriter.string(messageId)
    guard idText.utf16.count <= 64 else { return }
    let key = id + ":" + idText
    // The chunk index a peer sends is bounded (an index of 4e9 made a reassembly walk billions of slots).
    var index = 0
    if let value = envelope["c"] {
      guard let number = value.doubleValue, number == number.rounded(), number >= 0, number < Double(Self.maxChunksPerMessage) else {
        dropChunks(key)
        return
      }
      index = Int(number)
    }
    var entry: W2GPartialMessage
    if let existing = chunkBuffers[key] {
      entry = existing
    } else {
      // Too many messages in progress from this peer: its oldest one goes.
      let prefix = id + ":"
      let mine = chunkBuffers.filter { $0.key.hasPrefix(prefix) }
      if mine.count >= W2GSync.maxPendingMessages, let oldest = mine.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
        dropChunks(oldest)
      }
      entry = W2GPartialMessage(startedAt: now)
    }
    let growth = units.count - (entry.parts[index]?.count ?? 0)
    guard entry.size + growth <= W2GSync.maxEventUnits, bufferedUnits + growth <= W2GSync.maxBufferedUnits else {
      dropChunks(key)
      return
    }
    entry.parts[index] = units
    entry.size += growth
    bufferedUnits += growth
    chunkBuffers[key] = entry

    guard envelope["last"]?.isTruthy == true else { return }
    dropChunks(key)
    // Complete: every chunk up to the last one, none after it.
    guard entry.parts.count == index + 1 else { return }
    var joined: [UInt16] = []
    joined.reserveCapacity(entry.size)
    for chunkIndex in 0...index {
      guard let chunk = entry.parts[chunkIndex] else { return }
      joined.append(contentsOf: chunk)
    }
    if envelope["o"]?.isTruthy == true {
      guard let object = W2GJSONParser.parse(String(decoding: joined, as: UTF16.self)) else { return }
      onMessage?(id, object)
    } else {
      onMessage?(id, .string(joined))
    }
  }

  private func dropChunks(_ key: String) {
    guard let entry = chunkBuffers.removeValue(forKey: key) else { return }
    bufferedUnits -= entry.size
  }

  /// Partial messages whose last chunk did not come in time.
  private func expireChunks(now: Double) {
    for (key, entry) in chunkBuffers where now - entry.startedAt > W2GSync.chunkTimeoutMs { dropChunks(key) }
  }

  /// P2PT send(peer, string): uses any open link of that peer, chunked by 16000 UTF-16 units.
  @discardableResult
  func send(_ message: String, to peerId: String) -> Bool {
    guard !isDestroyed, let link = openLinks[peerId]?.first(where: { $0.isOpen }) else { return false }
    let units = Array(message.utf16)
    // P2PT treats an incoming id equal to one it sent to us as the *reply* to that message and
    // does not emit it: never reuse an id this peer already used towards us.
    let usedIds = receivedMessageIds[peerId] ?? []
    var messageId = Int.random(in: 100000...199999)
    var attempts = 0
    while usedIds.contains(messageId), attempts < 50 {
      messageId = Int.random(in: 100000...199999)
      attempts += 1
    }
    var offset = 0
    var chunk = 0
    var delivered = true
    while offset < units.count {
      let end = min(offset + Self.maxMessageLength, units.count)
      var pairs: [(String, W2GJSON?)] = [
        ("id", .int(messageId)),
        ("msg", .string(Array(units[offset..<end]))),
        ("c", .int(chunk))
      ]
      if end == units.count { pairs.append(("last", .bool(true))) }
      if !link.send(Self.messagePrefix + W2GJSONWriter.string(.dict(pairs))) { delivered = false }
      offset = end
      chunk += 1
    }
    return delivered
  }

  /// Closes every link of a remote peer and refuses its next ones (kick, or a banned user that came back).
  /// 'peerclose' follows when it had open links.
  func block(_ peerId: String) {
    guard !isDestroyed else { return }
    blockedPeerIds.insert(peerId)
    var links = openLinks[peerId] ?? []
    links.append(contentsOf: connectingLinks.values.filter { $0.remotePeerId == peerId })
    for link in links { link.destroy() }
  }

  // MARK: Teardown

  func destroy() {
    guard !isDestroyed else { return }
    isDestroyed = true
    for tracker in trackers { tracker.destroy() }
    trackers.removeAll()
    var links = Array(connectingLinks.values)
    for group in openLinks.values { links.append(contentsOf: group) }
    connectingLinks.removeAll()
    openLinks.removeAll()
    chunkBuffers.removeAll()
    bufferedUnits = 0
    receivedMessageIds.removeAll()
    for link in links {
      link.onClose = nil
      link.destroy()
    }
    onPeerConnect = nil
    onMessage = nil
    onPeerClose = nil
    onStatusChange = nil
  }
}

/// A message being reassembled (W2GSwarm.linkReceived).
struct W2GPartialMessage {
  /// Chunk index → UTF-16 units.
  var parts: [Int: [UInt16]] = [:]
  /// Units held.
  var size = 0
  /// When its first chunk came (ms).
  var startedAt: Double
}
