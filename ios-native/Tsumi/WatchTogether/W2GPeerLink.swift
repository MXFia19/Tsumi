import Foundation
import WebRTC

// One WebRTC connection to another participant: the native equivalent of a simple-peer
// instance as P2PT creates it (@thaunknown/simple-peer lite.js through bittorrent-tracker's
// websocket-tracker.js `_createPeer`):
//   - trickle: false → the offer/answer is sent once ICE gathering is complete (or 5 s after
//     the first candidate), with every candidate inside the SDP, and `a=ice-options:trickle`
//     removed (filterTrickle)
//   - default config: STUN stun.l.google.com:19302 + global.stun.twilio.com:3478, unified plan
//   - the initiator creates one data channel, label = 20 random bytes in hex, default options
//     (ordered, reliable); the answerer takes the channel announced by the remote side
//   - messages are text frames (P2PT sends strings)

/// Shared WebRTC objects (one factory per process, like the browser's global RTCPeerConnection).
@MainActor
enum W2GRTC {
  /// simple-peer `Peer.config.iceServers`.
  static let iceServerURLs = ["stun:stun.l.google.com:19302", "stun:global.stun.twilio.com:3478"]

  static let factory: RTCPeerConnectionFactory = {
    _ = RTCInitializeSSL()
    return RTCPeerConnectionFactory()
  }()

  static func makeConfiguration() -> RTCConfiguration {
    let configuration = RTCConfiguration()
    configuration.iceServers = [RTCIceServer(urlStrings: iceServerURLs)]
    return configuration
  }

  static func makeConstraints() -> RTCMediaConstraints {
    RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
  }

  /// simple-peer filterTrickle: `sdp.replace(/a=ice-options:trickle\s\n/g, '')`.
  nonisolated static func filterTrickle(_ sdp: String) -> String {
    sdp.replacingOccurrences(of: "a=ice-options:trickle\r\n", with: "")
      .replacingOccurrences(of: "a=ice-options:trickle \n", with: "")
  }
}

/// WebRTC calls its delegates on internal threads: this proxy forwards every callback to the
/// main actor, where W2GPeerLink lives. It holds the link weakly (WebRTC holds the proxy weakly,
/// the link holds it strongly).
final class W2GRTCDelegateProxy: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
  weak var link: W2GPeerLink?

  private func forward(_ body: @escaping @MainActor (W2GPeerLink) -> Void) {
    w2gOnMain {
      guard let link = self.link else { return }
      body(link)
    }
  }

  // MARK: RTCPeerConnectionDelegate (required methods)

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
    let failed = newState == .failed || newState == .closed
    forward { link in link.iceConnectionChanged(failed: failed) }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    let complete = newState == .complete
    forward { link in link.iceGatheringChanged(complete: complete) }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    forward { link in link.iceCandidateGenerated() }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    forward { link in link.remoteChannelAnnounced(dataChannel) }
  }

  // MARK: RTCDataChannelDelegate

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    let state = dataChannel.readyState
    let isOpen = state == .open
    let isClosed = state == .closed
    forward { link in link.channelStateChanged(dataChannel, isOpen: isOpen, isClosed: isClosed) }
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    let data = buffer.data
    forward { link in link.channelReceived(data) }
  }
}

@MainActor
final class W2GPeerLink {
  /// simple-peer ICECOMPLETE_TIMEOUT: send the SDP anyway 5 s after the first candidate.
  static let iceCompleteTimeout: Double = 5
  /// Safety net when no candidate is ever gathered (simple-peer would wait forever).
  static let gatheringDeadline: Double = 12
  /// A link that does not open this long after the remote SDP was applied is dropped.
  static let connectTimeout: Double = 40

  let isInitiator: Bool
  /// Hex id (40 chars) of the remote P2PT peer, set once the tracker relayed its offer/answer.
  var remotePeerId: String?
  private(set) var channelLabel: String?
  private(set) var isOpen = false
  private(set) var isDestroyed = false

  /// Local SDP ready to be relayed by the tracker: (link, "offer" | "answer", sdp).
  var onSignal: ((W2GPeerLink, String, String) -> Void)?
  var onOpen: ((W2GPeerLink) -> Void)?
  var onMessage: ((W2GPeerLink, String) -> Void)?
  var onClose: ((W2GPeerLink) -> Void)?

  private var connection: RTCPeerConnection?
  private var channel: RTCDataChannel?
  private let proxy = W2GRTCDelegateProxy()
  private var localDescriptionReady = false
  private var iceComplete = false
  private var signalSent = false
  private var iceTimer: Task<Void, Never>?
  private var gatheringTimer: Task<Void, Never>?
  private var connectTimer: Task<Void, Never>?

  init?(initiator: Bool) {
    isInitiator = initiator
    let created: RTCPeerConnection? = W2GRTC.factory.peerConnection(
      with: W2GRTC.makeConfiguration(),
      constraints: W2GRTC.makeConstraints(),
      delegate: nil
    )
    guard let pc = created else { return nil }
    connection = pc
    proxy.link = self
    pc.delegate = proxy

    if initiator {
      let configuration = RTCDataChannelConfiguration()
      let label = W2GHex.encode(W2GHex.randomBytes(20))
      let made: RTCDataChannel? = pc.dataChannel(forLabel: label, configuration: configuration)
      guard let dataChannel = made else {
        pc.delegate = nil
        pc.close()
        connection = nil
        return nil
      }
      attach(dataChannel)
      createOffer()
    }
  }

  // MARK: Signaling

  private func createOffer() {
    guard let pc = connection else { return }
    pc.offer(for: W2GRTC.makeConstraints()) { @Sendable (description, error) in
      let sdp = error == nil ? description?.sdp : nil
      w2gOnMain { self.localDescriptionCreated(sdp: sdp, isOffer: true) }
    }
  }

  private func createAnswer() {
    guard let pc = connection else { return }
    pc.answer(for: W2GRTC.makeConstraints()) { @Sendable (description, error) in
      let sdp = error == nil ? description?.sdp : nil
      w2gOnMain { self.localDescriptionCreated(sdp: sdp, isOffer: false) }
    }
  }

  private func localDescriptionCreated(sdp: String?, isOffer: Bool) {
    guard !isDestroyed, let pc = connection else { return }
    guard let sdp else {
      destroy()
      return
    }
    let description = RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: W2GRTC.filterTrickle(sdp))
    pc.setLocalDescription(description) { @Sendable (error) in
      let ok = error == nil
      w2gOnMain { self.localDescriptionApplied(ok) }
    }
  }

  private func localDescriptionApplied(_ ok: Bool) {
    guard !isDestroyed else { return }
    guard ok else {
      destroy()
      return
    }
    localDescriptionReady = true
    if iceComplete || connection?.iceGatheringState == .complete {
      iceComplete = true
      emitSignal()
    } else {
      gatheringTimer = w2gAfter(Self.gatheringDeadline) { [weak self] in self?.markIceComplete() }
    }
  }

  /// Applies the remote offer or answer (simple-peer `signal({ type, sdp })`).
  func applyRemote(type: String, sdp: String) {
    guard !isDestroyed, let pc = connection else { return }
    let isOffer = type != "answer" && type != "pranswer"
    let description = RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp)
    pc.setRemoteDescription(description) { @Sendable (error) in
      let ok = error == nil
      w2gOnMain { self.remoteDescriptionApplied(ok, isOffer: isOffer) }
    }
    connectTimer?.cancel()
    connectTimer = w2gAfter(Self.connectTimeout) { [weak self] in
      guard let self, !self.isOpen else { return }
      self.destroy()
    }
  }

  private func remoteDescriptionApplied(_ ok: Bool, isOffer: Bool) {
    guard !isDestroyed else { return }
    guard ok else {
      destroy()
      return
    }
    if isOffer { createAnswer() }
  }

  // MARK: ICE (trickle disabled)

  fileprivate func iceCandidateGenerated() {
    guard !isDestroyed, !iceComplete, iceTimer == nil else { return }
    iceTimer = w2gAfter(Self.iceCompleteTimeout) { [weak self] in self?.markIceComplete() }
  }

  fileprivate func iceGatheringChanged(complete: Bool) {
    if complete { markIceComplete() }
  }

  private func markIceComplete() {
    guard !isDestroyed, !iceComplete else { return }
    iceComplete = true
    iceTimer?.cancel()
    if localDescriptionReady { emitSignal() }
  }

  private func emitSignal() {
    guard !signalSent, !isDestroyed, let local = connection?.localDescription else { return }
    signalSent = true
    gatheringTimer?.cancel()
    iceTimer?.cancel()
    let type = local.type == .offer ? "offer" : "answer"
    onSignal?(self, type, W2GRTC.filterTrickle(local.sdp))
  }

  fileprivate func iceConnectionChanged(failed: Bool) {
    if failed { destroy() }
  }

  // MARK: Data channel

  private func attach(_ dataChannel: RTCDataChannel) {
    channel = dataChannel
    channelLabel = dataChannel.label
    dataChannel.delegate = proxy
    if dataChannel.readyState == .open { channelOpened() }
  }

  fileprivate func remoteChannelAnnounced(_ dataChannel: RTCDataChannel) {
    guard !isDestroyed, channel == nil else { return }
    attach(dataChannel)
  }

  fileprivate func channelStateChanged(_ dataChannel: RTCDataChannel, isOpen open: Bool, isClosed closed: Bool) {
    guard !isDestroyed, dataChannel === channel else { return }
    if open { channelOpened() }
    if closed { destroy() }
  }

  private func channelOpened() {
    guard !isDestroyed, !isOpen else { return }
    isOpen = true
    connectTimer?.cancel()
    onOpen?(self)
  }

  fileprivate func channelReceived(_ data: Data) {
    guard !isDestroyed else { return }
    onMessage?(self, String(decoding: data, as: UTF8.self))
  }

  /// Sends one text frame. Returns false when the channel is not open.
  @discardableResult
  func send(_ text: String) -> Bool {
    guard isOpen, !isDestroyed, let dataChannel = channel, dataChannel.readyState == .open else { return false }
    return dataChannel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
  }

  // MARK: Teardown

  func destroy() {
    guard !isDestroyed else { return }
    isDestroyed = true
    isOpen = false
    iceTimer?.cancel()
    gatheringTimer?.cancel()
    connectTimer?.cancel()
    if let dataChannel = channel {
      dataChannel.delegate = nil
      dataChannel.close()
    }
    if let pc = connection {
      pc.delegate = nil
      pc.close()
    }
    channel = nil
    connection = nil
    proxy.link = nil
    let closeHandler = onClose
    onSignal = nil
    onOpen = nil
    onMessage = nil
    onClose = nil
    closeHandler?(self)
  }
}
