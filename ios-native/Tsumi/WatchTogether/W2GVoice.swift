import AVFoundation
import Foundation
import WebRTC

// Watch Together voice chat (common/routes/w2g/PROTOCOL.md v2.4), native port of
// common/routes/w2g/components/voice.js:
//   - the microphone as one WebRTC audio track (echo cancellation and noise suppression by the voice processing
//     I/O unit WebRTC uses on iOS), shared by every link;
//   - one dedicated RTCPeerConnection per member in voice (the data channel links stay as they are), signaled with
//     `voiceSignal` through the lobby's data channels, no trickle (3 s after the first candidate, 8 s at most);
//   - remote voices played by WebRTC, with a local mute (track disabled) and volume (source gain) per member;
//   - our speaking state from the `media-source` audio level of the stats, read every 100 ms;
//   - the audio session: playAndRecord while in voice (the video keeps playing), restored when leaving.

/// Audio session while in voice. WebRTC runs the audio unit only while `isAudioEnabled` (manual audio).
/// Not actor-bound: PlayerAudioSession reads `isActive`; every call comes from the main thread.
enum W2GVoiceAudio {
  /// In voice: PlayerAudioSession leaves the session alone.
  static private(set) var isActive = false

  static func activate() {
    let configuration = RTCAudioSessionConfiguration.webRTC()
    configuration.category = AVAudioSession.Category.playAndRecord.rawValue
    // videoChat: speaker by default, voice processing on; the video keeps playing through the same session.
    configuration.mode = AVAudioSession.Mode.videoChat.rawValue
    configuration.categoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
    RTCAudioSessionConfiguration.setWebRTC(configuration)
    let session = RTCAudioSession.sharedInstance()
    session.useManualAudio = true
    session.lockForConfiguration()
    do {
      try session.setConfiguration(configuration, active: true)
    } catch {
      // The links still work; audio may route differently.
    }
    session.unlockForConfiguration()
    session.isAudioEnabled = true
    isActive = true
  }

  /// Back to what the player uses (`.playback` / `.moviePlayback`), or released without a player.
  static func deactivate(playerOpen: Bool) {
    guard isActive else { return }
    let session = RTCAudioSession.sharedInstance()
    session.isAudioEnabled = false
    isActive = false
    if playerOpen {
      PlayerAudioSession.activate()
    } else {
      PlayerAudioSession.deactivate()
    }
  }
}

/// Forwards the WebRTC callbacks of a voice link to the main actor (same pattern as W2GRTCDelegateProxy).
final class W2GVoiceDelegateProxy: NSObject, RTCPeerConnectionDelegate {
  weak var link: W2GVoiceLink?

  private func forward(_ body: @escaping @MainActor (W2GVoiceLink) -> Void) {
    w2gOnMain {
      guard let link = self.link else { return }
      body(link)
    }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
    let connected = newState == .connected || newState == .completed
    let failed = newState == .failed || newState == .closed
    forward { link in link.iceConnectionChanged(connected: connected, failed: failed) }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    let complete = newState == .complete
    forward { link in if complete { link.markGatheringComplete() } }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    forward { link in link.candidateGenerated() }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// One audio link with a member.
@MainActor
final class W2GVoiceLink {
  let userId: String
  /// Offer id, echoed by the answer.
  let id: String
  private(set) var isConnected = false
  private(set) var isClosed = false
  private(set) var connection: RTCPeerConnection?
  var onConnected: (() -> Void)?
  var onFailed: (() -> Void)?

  private let proxy = W2GVoiceDelegateProxy()
  private var localReady = false
  private var gatheringComplete = false
  private var descriptionSent = false
  private var onDescription: ((String, String) -> Void)?
  private var candidateTimer: Task<Void, Never>?
  private var maxTimer: Task<Void, Never>?
  private var connectTimer: Task<Void, Never>?

  init?(userId: String, id: String) {
    let configuration = RTCConfiguration()
    configuration.iceServers = [RTCIceServer(urlStrings: W2GRTC.iceServerURLs)]
    let created: RTCPeerConnection? = W2GRTC.factory.peerConnection(with: configuration, constraints: W2GRTC.makeConstraints(), delegate: nil)
    guard let pc = created else { return nil }
    self.userId = userId
    self.id = id
    connection = pc
    proxy.link = self
    pc.delegate = proxy
    connectTimer = w2gAfter(W2GSync.voiceConnectTimeoutSeconds) { [weak self] in
      guard let self, !self.isConnected else { return }
      self.fail()
    }
  }

  /// Our microphone on the audio transceiver (an answerer reuses the one the offer created), or receive only.
  func attach(_ track: RTCAudioTrack?) {
    guard let pc = connection else { return }
    if let track {
      _ = pc.add(track, streamIds: ["w2g-voice"])
    } else if !pc.transceivers.contains(where: { $0.mediaType == .audio }) {
      _ = pc.addTransceiver(of: .audio)
    }
  }

  /// Local mute (track disabled) and volume (source gain) of the remote voice.
  func apply(_ mix: W2GVoiceMix) {
    guard let pc = connection else { return }
    for transceiver in pc.transceivers where transceiver.mediaType == .audio {
      guard let track = transceiver.receiver.track as? RTCAudioTrack else { continue }
      track.isEnabled = !mix.muted
      track.source.volume = max(0, min(1, mix.volume))
    }
  }

  // MARK: Offer / answer (no trickle)

  /// Offerer: creates the offer; `completion(type, sdp)` once ICE gathering is done.
  func makeOffer(_ completion: @escaping (String, String) -> Void) {
    guard let pc = connection else { return }
    onDescription = completion
    pc.offer(for: W2GRTC.makeConstraints()) { @Sendable (description, error) in
      let sdp = error == nil ? description?.sdp : nil
      w2gOnMain { [weak self] in self?.localCreated(sdp: sdp, isOffer: true) }
    }
  }

  /// Answerer: applies the offer, adds the microphone, answers.
  func answer(offer sdp: String, track: RTCAudioTrack?, mix: W2GVoiceMix, completion: @escaping (String, String) -> Void) {
    guard let pc = connection else { return }
    onDescription = completion
    pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { @Sendable (error) in
      let ok = error == nil
      w2gOnMain { [weak self] in
        guard let self, !self.isClosed, let pc = self.connection else { return }
        guard ok else {
          self.fail()
          return
        }
        self.attach(track)
        self.apply(mix)
        pc.answer(for: W2GRTC.makeConstraints()) { @Sendable (description, error) in
          let answer = error == nil ? description?.sdp : nil
          w2gOnMain { [weak self] in self?.localCreated(sdp: answer, isOffer: false) }
        }
      }
    }
  }

  /// Offerer: the answer arrived.
  func applyAnswer(_ sdp: String, mix: W2GVoiceMix) {
    guard let pc = connection, pc.signalingState == .haveLocalOffer else { return }
    pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { @Sendable (error) in
      let ok = error == nil
      w2gOnMain { [weak self] in
        guard let self, !self.isClosed else { return }
        if ok { self.apply(mix) } else { self.fail() }
      }
    }
  }

  private func localCreated(sdp: String?, isOffer: Bool) {
    guard !isClosed, let pc = connection else { return }
    guard let sdp else {
      fail()
      return
    }
    let description = RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp)
    pc.setLocalDescription(description) { @Sendable (error) in
      let ok = error == nil
      w2gOnMain { [weak self] in
        guard let self, !self.isClosed else { return }
        guard ok else {
          self.fail()
          return
        }
        self.localReady = true
        self.maxTimer = w2gAfter(W2GSync.voiceGatherMaxSeconds) { [weak self] in self?.markGatheringComplete() }
        if self.gatheringComplete || pc.iceGatheringState == .complete { self.markGatheringComplete() }
      }
    }
  }

  fileprivate func candidateGenerated() {
    guard !isClosed, !gatheringComplete, candidateTimer == nil else { return }
    candidateTimer = w2gAfter(W2GSync.voiceGatherAfterCandidateSeconds) { [weak self] in self?.markGatheringComplete() }
  }

  fileprivate func markGatheringComplete() {
    guard !isClosed else { return }
    gatheringComplete = true
    guard localReady, !descriptionSent, let local = connection?.localDescription else { return }
    descriptionSent = true
    candidateTimer?.cancel()
    maxTimer?.cancel()
    let type = local.type == .offer ? "offer" : "answer"
    let send = onDescription
    onDescription = nil
    send?(type, local.sdp)
  }

  fileprivate func iceConnectionChanged(connected: Bool, failed: Bool) {
    guard !isClosed else { return }
    if connected && !isConnected {
      isConnected = true
      connectTimer?.cancel()
      onConnected?()
    } else if failed {
      fail()
    }
  }

  private func fail() {
    guard !isClosed else { return }
    let handler = onFailed
    close()
    handler?()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    candidateTimer?.cancel()
    maxTimer?.cancel()
    connectTimer?.cancel()
    if let pc = connection {
      pc.delegate = nil
      pc.close()
    }
    connection = nil
    proxy.link = nil
    onConnected = nil
    onFailed = nil
    onDescription = nil
  }

  /// Peak level (0-1) of our microphone from the `media-source` stats, nil when unknown.
  func readMicLevel(_ completion: @escaping @MainActor (Double?) -> Void) {
    guard let pc = connection else {
      completion(nil)
      return
    }
    pc.statistics { @Sendable report in
      var level: Double?
      for statistic in report.statistics.values where statistic.type == "media-source" {
        if let kind = statistic.values["kind"] as? String, kind != "audio" { continue }
        if let value = statistic.values["audioLevel"] as? NSNumber { level = max(level ?? 0, value.doubleValue) }
      }
      let result = level
      w2gOnMain { completion(result) }
    }
  }
}

/// Our side of the voice chat: microphone, links, per-member mix, speaking. WatchTogetherClient decides who to link
/// with (W2GSync.voiceLinkAction) and relays the signals.
@MainActor
final class W2GVoiceEngine {
  private(set) var joined = false
  private(set) var starting = false
  private(set) var hasMic = false
  private(set) var muted = false
  private(set) var held = false
  private(set) var speaking = false
  private(set) var error: String?

  /// Our voice state changed.
  var onStateChange: (() -> Void)?
  /// Send a `voiceSignal` payload to that member.
  var onSignal: ((String, W2GJSON) -> Void)?
  /// A link connected, failed or closed.
  var onLinksChange: (() -> Void)?
  /// We should be offering to that member now (both in voice, we are the smaller id).
  var wantsOffer: ((String) -> Bool)?

  private var source: RTCAudioSource?
  private var track: RTCAudioTrack?
  private var links: [String: W2GVoiceLink] = [:]
  private var mixes: [String: W2GVoiceMix] = [:]
  private var failures: [String: Int] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private var levelTask: Task<Void, Never>?
  private var speakingMemory = W2GSpeakingMemory()

  var pushToTalk: Bool { AppSettings.shared.values.w2gPushToTalk }

  var transmitting: Bool {
    W2GSync.voiceTransmitting(joined: joined, hasMic: hasMic, muted: muted, pushToTalk: pushToTalk, held: held)
  }

  /// `voice` payload.
  var payload: W2GVoiceState {
    W2GVoiceState(joined: joined, muted: !transmitting, speaking: joined && transmitting && speaking)
  }

  var view: W2GVoiceView {
    W2GVoiceView(
      joined: joined,
      starting: starting,
      hasMic: hasMic,
      muted: muted,
      pushToTalk: pushToTalk,
      held: held,
      transmitting: transmitting,
      speaking: payload.speaking,
      error: error
    )
  }

  /// Opens the microphone (asks for the permission); without it we still join and listen.
  func join() async {
    guard !joined, !starting else { return }
    starting = true
    error = nil
    onStateChange?()
    let granted: Bool = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    guard starting else { return }
    starting = false
    joined = true
    W2GVoiceAudio.activate()
    if granted {
      let constraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true", "googHighpassFilter": "true"]
      )
      let audioSource = W2GRTC.factory.audioSource(with: constraints)
      source = audioSource
      track = W2GRTC.factory.audioTrack(with: audioSource, trackId: "w2g-mic")
      hasMic = track != nil
    } else {
      error = "Microphone not allowed: you can listen, not talk. Allow it in Settings > Tsumi."
    }
    applyTransmit()
    startLevelMeter()
    onStateChange?()
  }

  func leave(playerOpen: Bool) {
    guard joined || starting else { return }
    starting = false
    joined = false
    speaking = false
    held = false
    for userId in Array(links.keys) { close(userId) }
    for task in retryTasks.values { task.cancel() }
    retryTasks = [:]
    failures = [:]
    levelTask?.cancel()
    levelTask = nil
    track?.isEnabled = false
    track = nil
    source = nil
    hasMic = false
    speakingMemory = W2GSpeakingMemory()
    W2GVoiceAudio.deactivate(playerOpen: playerOpen)
    onStateChange?()
  }

  func setMuted(_ value: Bool) {
    guard muted != value else { return }
    muted = value
    applyTransmit()
    onStateChange?()
  }

  /// Hold-to-talk button pressed / released.
  func setHeld(_ value: Bool) {
    guard held != value else { return }
    held = value
    applyTransmit()
    onStateChange?()
  }

  /// Push-to-talk switched in the settings.
  func refresh() {
    applyTransmit()
    onStateChange?()
  }

  func mix(of userId: String) -> W2GVoiceMix {
    mixes[userId] ?? W2GVoiceMix()
  }

  func setMix(_ userId: String, muted: Bool? = nil, volume: Double? = nil) {
    var value = mix(of: userId)
    if let muted { value.muted = muted }
    if let volume { value.volume = max(0, min(1, volume)) }
    mixes[userId] = value
    links[userId]?.apply(value)
    onLinksChange?()
  }

  func hasLink(_ userId: String) -> Bool {
    links[userId] != nil
  }

  /// userId → connected.
  var linkStates: [String: Bool] {
    links.mapValues { $0.isConnected }
  }

  /// Offerer: create the link and send the offer.
  func connect(_ userId: String) {
    guard joined, links[userId] == nil else { return }
    retryTasks[userId]?.cancel()
    retryTasks[userId] = nil
    guard let link = makeLink(userId: userId, id: W2GHex.randomCode(12)) else { return }
    link.attach(track)
    link.apply(mix(of: userId))
    let offerId = link.id
    link.makeOffer { [weak self] type, sdp in
      self?.onSignal?(userId, Self.signalPayload(id: offerId, type: type, sdp: sdp))
    }
  }

  /// A `voiceSignal` (offers are only passed here once accepted).
  func signal(from userId: String, payload: W2GJSON) {
    guard joined, let id = W2GSync.queueId(payload["id"]) else { return }
    guard let sdp = payload["sdp"]?["sdp"]?.stringValue, !sdp.isEmpty else { return }
    let type = payload["sdp"]?["type"]?.stringValue
    if type == "offer" {
      // A new offer replaces the link we had with that member.
      close(userId)
      guard let link = makeLink(userId: userId, id: id) else { return }
      link.answer(offer: sdp, track: track, mix: mix(of: userId)) { [weak self] type, answer in
        self?.onSignal?(userId, Self.signalPayload(id: id, type: type, sdp: answer))
      }
    } else if type == "answer" {
      guard let link = links[userId], link.id == id else { return }
      link.applyAnswer(sdp, mix: mix(of: userId))
    }
  }

  /// Closes the link with a member (left voice, left the lobby, kicked).
  func close(_ userId: String) {
    retryTasks[userId]?.cancel()
    retryTasks[userId] = nil
    guard let link = links.removeValue(forKey: userId) else { return }
    link.close()
    onLinksChange?()
  }

  /// A member left the lobby: its mix is forgotten too.
  func forget(_ userId: String) {
    close(userId)
    failures[userId] = nil
    mixes[userId] = nil
  }

  private static func signalPayload(id: String, type: String, sdp: String) -> W2GJSON {
    .dict([("id", .text(id)), ("sdp", .dict([("type", .text(type)), ("sdp", .text(sdp))]))])
  }

  private func makeLink(userId: String, id: String) -> W2GVoiceLink? {
    guard let link = W2GVoiceLink(userId: userId, id: id) else { return nil }
    link.onConnected = { [weak self, weak link] in
      guard let self, let link else { return }
      self.failures[userId] = nil
      link.apply(self.mix(of: userId))
      self.onLinksChange?()
    }
    link.onFailed = { [weak self, weak link] in
      guard let self, let link else { return }
      self.failed(userId, link)
    }
    links[userId] = link
    onLinksChange?()
    return link
  }

  /// A link failed: the offerer tries again after 3 s, at most 5 times in a row.
  private func failed(_ userId: String, _ link: W2GVoiceLink) {
    if links[userId] === link { links[userId] = nil }
    onLinksChange?()
    guard joined, wantsOffer?(userId) == true else { return }
    let count = (failures[userId] ?? 0) + 1
    failures[userId] = count
    guard let delay = W2GSync.voiceRetryDelay(failures: count) else { return }
    retryTasks[userId]?.cancel()
    retryTasks[userId] = w2gAfter(delay) { [weak self] in
      guard let self else { return }
      self.retryTasks[userId] = nil
      if self.joined, self.wantsOffer?(userId) == true { self.connect(userId) }
    }
  }

  private func applyTransmit() {
    track?.isEnabled = transmitting
    if !transmitting && speaking {
      speaking = false
      speakingMemory = W2GSpeakingMemory()
    }
  }

  /// Our microphone level every 100 ms (from any connected link's stats: they share the track).
  private func startLevelMeter() {
    levelTask?.cancel()
    levelTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard let self, self.joined else { return }
        self.readLevel()
      }
    }
  }

  private func readLevel() {
    guard transmitting, let link = links.values.first(where: { $0.isConnected }) else {
      levelRead(nil)
      return
    }
    link.readMicLevel { [weak self] level in self?.levelRead(level) }
  }

  private func levelRead(_ level: Double?) {
    guard joined else { return }
    speakingMemory = W2GSync.speakingStep(speakingMemory, level: level, transmitting: transmitting, now: W2GSync.nowMs())
    guard speakingMemory.speaking != speaking else { return }
    speaking = speakingMemory.speaking
    onStateChange?()
  }
}
