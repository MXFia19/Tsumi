import Foundation

// WebTorrent WebSocket tracker client used for signaling only: the native equivalent of
// bittorrent-tracker lib/client/websocket-tracker.js as P2PT drives it.
//
// Wire format (JSON text frames, ids are 20-byte JS "binary strings"):
//   → announce: {"numwant":5,"uploaded":0,"downloaded":0,"action":"announce",
//                "info_hash":<20B>,"peer_id":<20B>[,"trackerid":…],
//                "offers":[{"offer":{"type":"offer","sdp":…},"offer_id":<20B>}, ×5]}
//   ← stats:    {"action":"announce","interval":120,"info_hash":…,"complete":0,"incomplete":2}
//   ← offer:    {"action":"announce","info_hash":…,"peer_id":<remote>,"offer_id":…,"offer":{type,sdp}}
//   → answer:   {"action":"announce","info_hash":…,"peer_id":<self>,"to_peer_id":<remote>,
//                "answer":{"type":"answer","sdp":…},"offer_id":…[,"trackerid":…]}
//   ← answer:   {"action":"announce","info_hash":…,"peer_id":<remote>,"offer_id":<ours>,"answer":{type,sdp}}
// Re-announce (5 new offers) every `interval || min interval` seconds; unanswered offers are
// destroyed after 50 s; on socket close/error, reconnect with exponential backoff and announce.

/// URLSession delegate bridge (URLSession retains it; invalidated on teardown).
final class W2GSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: (@MainActor () -> Void)?
  var onClose: (@MainActor () -> Void)?

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiatedProtocol: String?) {
    let handler = onOpen
    w2gOnMain { handler?() }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let handler = onClose
    w2gOnMain { handler?() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let handler = onClose
    w2gOnMain { handler?() }
  }
}

/// Offers generated for one announce (websocket-tracker.js `_generateOffers`).
@MainActor
final class W2GOfferBatch {
  var expected: Int
  var offers: [W2GJSON] = []
  var settled: Set<ObjectIdentifier> = []
  var sent = false
  var deadline: Task<Void, Never>?

  init(expected: Int) {
    self.expected = expected
  }

  var isComplete: Bool { settled.count >= expected }
}

@MainActor
final class W2GTrackerConnection {
  /// Math.min(numwant 50, 5) offers per announce.
  static let offersPerAnnounce = 5
  /// OFFER_TIMEOUT
  static let offerTimeout: Double = 50
  /// RECONNECT_MINIMUM / RECONNECT_MAXIMUM
  static let reconnectMinimum: Double = 10
  static let reconnectMaximum: Double = 60 * 60
  /// RECONNECT_VARIANCE is 5 minutes in JS; kept short here (mobile apps lose sockets often).
  static let reconnectVariance: Double = 5
  /// Offers whose ICE gathering hangs are dropped from the announce after this delay.
  static let offerGenerationDeadline: Double = 14

  let announceURL: URL
  private weak var swarm: W2GSwarm?

  private(set) var isConnected = false
  private var isDestroyed = false
  private var reconnecting = false
  private var retries = 0
  private var generation = 0
  private var trackerId: W2GJSON?

  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var socketDelegate: W2GSocketDelegate?
  private var intervalTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  /// Unanswered offers: offer id (hex) → link (websocket-tracker.js `this.peers`).
  private var pendingOffers: [String: W2GPeerLink] = [:]
  private var offerTimeouts: [String: Task<Void, Never>] = [:]

  init(url: URL, swarm: W2GSwarm) {
    announceURL = url
    self.swarm = swarm
  }

  func start() {
    openSocket()
  }

  // MARK: Socket

  private func openSocket() {
    guard !isDestroyed else { return }
    generation += 1
    let gen = generation
    let delegate = W2GSocketDelegate()
    delegate.onOpen = { [weak self] in self?.socketOpened(gen) }
    delegate.onClose = { [weak self] in self?.socketFailed(gen) }
    let newSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: OperationQueue.main)
    let task = newSession.webSocketTask(with: announceURL)
    session = newSession
    socket = task
    socketDelegate = delegate
    task.resume()
    receiveNext(task, gen)
  }

  private func receiveNext(_ task: URLSessionWebSocketTask, _ gen: Int) {
    task.receive { result in
      w2gOnMain { self.handleReceive(result, task: task, gen: gen) }
    }
  }

  private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, task: URLSessionWebSocketTask, gen: Int) {
    guard gen == generation, !isDestroyed else { return }
    switch result {
    case .failure:
      socketFailed(gen)
    case .success(let message):
      var text: String?
      switch message {
      case .string(let string): text = string
      case .data(let data): text = String(data: data, encoding: .utf8)
      @unknown default: text = nil
      }
      if let text { handleTrackerMessage(text) }
      if gen == generation, !isDestroyed { receiveNext(task, gen) }
    }
  }

  private func socketOpened(_ gen: Int) {
    guard gen == generation, !isDestroyed else { return }
    isConnected = true
    if reconnecting {
      reconnecting = false
      retries = 0
    }
    swarm?.trackerStatusChanged()
    startPinging(gen)
    announce()
  }

  /// Keeps idle sockets alive between announces (not in the JS client; harmless for trackers).
  private func startPinging(_ gen: Int) {
    pingTask?.cancel()
    pingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if Task.isCancelled { return }
        self?.ping(gen)
      }
    }
  }

  private func ping(_ gen: Int) {
    guard gen == generation, let socket, isConnected else { return }
    socket.sendPing { error in
      guard error != nil else { return }
      w2gOnMain { self.socketFailed(gen) }
    }
  }

  /// websocket-tracker.js `_onSocketClose` / `_onSocketError`: drop everything, reconnect later.
  private func socketFailed(_ gen: Int) {
    guard gen == generation, !isDestroyed else { return }
    teardownSocket()
    swarm?.trackerStatusChanged()
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    reconnecting = true
    reconnectTask?.cancel()
    let backoff = min(pow(2, Double(retries)) * Self.reconnectMinimum, Self.reconnectMaximum)
    let delay = backoff + Double.random(in: 0..<Self.reconnectVariance)
    reconnectTask = w2gAfter(delay) { [weak self] in
      guard let self, !self.isDestroyed else { return }
      self.retries += 1
      self.openSocket()
    }
  }

  /// Reconnects now if the socket is down (app back in foreground), else announces again.
  func refresh() {
    guard !isDestroyed else { return }
    if isConnected {
      announce()
    } else if reconnecting {
      reconnectTask?.cancel()
      retries = 0
      openSocket()
    }
  }

  private func teardownSocket() {
    generation += 1
    isConnected = false
    intervalTask?.cancel()
    intervalTask = nil
    pingTask?.cancel()
    pingTask = nil
    for task in offerTimeouts.values { task.cancel() }
    offerTimeouts.removeAll()
    let links = Array(pendingOffers.values)
    pendingOffers.removeAll()
    for link in links { link.destroy() }
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
    socket = nil
    session = nil
    socketDelegate = nil
  }

  func destroy() {
    guard !isDestroyed else { return }
    teardownSocket()
    isDestroyed = true
    reconnecting = false
    reconnectTask?.cancel()
    reconnectTask = nil
  }

  private func send(_ value: W2GJSON) {
    guard let socket, isConnected, !isDestroyed else { return }
    let gen = generation
    socket.send(.string(W2GJSONWriter.string(value))) { error in
      guard error != nil else { return }
      w2gOnMain { self.socketFailed(gen) }
    }
  }

  // MARK: Announce

  func announce() {
    guard !isDestroyed, !reconnecting, isConnected, let swarm else { return }
    let gen = generation
    let batch = W2GOfferBatch(expected: Self.offersPerAnnounce)
    for _ in 0..<Self.offersPerAnnounce {
      let offerId = W2GHex.randomBytes(20)
      let key = W2GHex.encode(offerId)
      guard let link = swarm.makeLink(initiator: true) else {
        batch.expected -= 1
        continue
      }
      pendingOffers[key] = link
      link.onSignal = { [weak self] link, type, sdp in
        guard let self else { return }
        batch.offers.append(.dict([
          ("offer", .dict([("type", .text(type)), ("sdp", .text(sdp))])),
          ("offer_id", .binary(offerId))
        ]))
        batch.settled.insert(ObjectIdentifier(link))
        self.offerBatchProgress(batch, gen)
      }
      link.onClose = { [weak self] link in
        guard let self else { return }
        if self.pendingOffers[key] === link {
          self.pendingOffers[key] = nil
          self.offerTimeouts.removeValue(forKey: key)?.cancel()
        }
        batch.settled.insert(ObjectIdentifier(link))
        self.offerBatchProgress(batch, gen)
      }
      offerTimeouts[key] = w2gAfter(Self.offerTimeout) { [weak self] in
        guard let self else { return }
        self.offerTimeouts[key] = nil
        self.pendingOffers.removeValue(forKey: key)?.destroy()
      }
    }
    batch.deadline = w2gAfter(Self.offerGenerationDeadline) { [weak self] in
      self?.flushOffers(batch, gen)
    }
    offerBatchProgress(batch, gen)
  }

  private func offerBatchProgress(_ batch: W2GOfferBatch, _ gen: Int) {
    guard !batch.sent, batch.isComplete else { return }
    flushOffers(batch, gen)
  }

  private func flushOffers(_ batch: W2GOfferBatch, _ gen: Int) {
    guard !batch.sent else { return }
    batch.sent = true
    batch.deadline?.cancel()
    guard gen == generation, !isDestroyed, let swarm else { return }
    var params: [(String, W2GJSON?)] = [
      ("numwant", .int(Self.offersPerAnnounce)),
      ("uploaded", .int(0)),
      ("downloaded", .int(0)),
      ("action", .text("announce")),
      ("info_hash", .binary(swarm.infoHash)),
      ("peer_id", .binary(swarm.peerId))
    ]
    if let trackerId { params.append(("trackerid", trackerId)) }
    params.append(("offers", .array(batch.offers)))
    send(.dict(params))
  }

  private func setAnnounceInterval(_ seconds: Double) {
    intervalTask?.cancel()
    let period = max(seconds, 10)
    intervalTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
        if Task.isCancelled { return }
        self?.announce()
      }
    }
  }

  // MARK: Tracker messages (websocket-tracker.js `_onAnnounceResponse`)

  private func handleTrackerMessage(_ text: String) {
    guard let swarm, let data = W2GJSONParser.parse(text) else { return }
    guard data["action"]?.stringValue == "announce" else { return }
    guard let infoHash = data["info_hash"]?.binaryValue, infoHash == swarm.infoHash else { return }

    let remotePeer = data["peer_id"]?.binaryValue
    if let remotePeer, remotePeer == swarm.peerId { return } // our own offers/answers

    if let failure = data["failure reason"], failure.isTruthy { return }

    let interval = (data["interval"]?.isTruthy == true ? data["interval"] : data["min interval"])?.doubleValue
    if let interval, interval > 0 { setAnnounceInterval(interval) }

    if let newTrackerId = data["tracker id"], newTrackerId.isTruthy { trackerId = newTrackerId }

    if let complete = data["complete"], !complete.isNull { swarm.trackerStatusChanged() }

    if let offer = data["offer"], offer.isTruthy, let remotePeer, !remotePeer.isEmpty {
      handleRemoteOffer(offer, from: remotePeer, offerId: data["offer_id"])
    }

    if let answer = data["answer"], answer.isTruthy, let remotePeer, !remotePeer.isEmpty {
      handleRemoteAnswer(answer, from: remotePeer, offerId: data["offer_id"])
    }
  }

  private func handleRemoteOffer(_ offer: W2GJSON, from remotePeer: [UInt8], offerId: W2GJSON?) {
    guard let swarm, let sdp = offer["sdp"]?.stringValue else { return }
    let peerHex = W2GHex.encode(remotePeer)
    guard swarm.canAcceptLink(from: peerHex), let link = swarm.makeLink(initiator: false) else { return }
    let echoedOfferId = offerId ?? .null
    link.onSignal = { [weak self] _, type, answerSdp in
      guard let self, let swarm = self.swarm else { return }
      var params: [(String, W2GJSON?)] = [
        ("action", .text("announce")),
        ("info_hash", .binary(swarm.infoHash)),
        ("peer_id", .binary(swarm.peerId)),
        ("to_peer_id", .binary(remotePeer)),
        ("answer", .dict([("type", .text(type)), ("sdp", .text(answerSdp))])),
        ("offer_id", echoedOfferId)
      ]
      if let trackerId = self.trackerId { params.append(("trackerid", trackerId)) }
      self.send(.dict(params))
    }
    swarm.adopt(link, peerId: peerHex)
    link.applyRemote(type: offer["type"]?.stringValue ?? "offer", sdp: sdp)
  }

  private func handleRemoteAnswer(_ answer: W2GJSON, from remotePeer: [UInt8], offerId: W2GJSON?) {
    guard let swarm, let offerBytes = offerId?.binaryValue else { return }
    let key = W2GHex.encode(offerBytes)
    guard let link = pendingOffers.removeValue(forKey: key) else { return } // unexpected answer
    offerTimeouts.removeValue(forKey: key)?.cancel()
    let peerHex = W2GHex.encode(remotePeer)
    // No per-peer cap here: the remote side already emitted its P2PT 'peer' for this link, and
    // killing it could swallow that peer's one-time 'peerconnect' (it would never send `init`).
    guard let sdp = answer["sdp"]?.stringValue, peerHex != swarm.peerIdHex else {
      link.destroy()
      return
    }
    link.onSignal = nil
    swarm.adopt(link, peerId: peerHex)
    link.applyRemote(type: answer["type"]?.stringValue ?? "answer", sdp: sdp)
  }
}
