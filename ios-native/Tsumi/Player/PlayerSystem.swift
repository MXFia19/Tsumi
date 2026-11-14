import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

// System integrations of the player: video layer (needed for Picture in Picture), AirPlay picker,
// Picture in Picture, Now Playing / remote commands (navigator.mediaSession in the Svelte app),
// orientation lock (screen.orientation.lock('landscape')) and the audio session.

/// UIView hosting the AVPlayerLayer. Owned by PlayerController so the layer survives while the player UI is
/// dismissed during Picture in Picture.
final class PlayerLayerUIView: UIView {
  let playerLayer = AVPlayerLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setUp()
  }

  private func setUp() {
    backgroundColor = .black
    clipsToBounds = true
    playerLayer.videoGravity = .resizeAspect
    layer.addSublayer(playerLayer)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
  }
}

/// Container of the shared video view. The full screen player and the in-app miniplayer each have one; the
/// one that most recently entered a window takes the video layer, so the same AVPlayerLayer moves between
/// them (and keeps Picture in Picture attached).
final class PlayerVideoContainerView: UIView {
  var onEnterWindow: ((PlayerVideoContainerView) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { onEnterWindow?(self) }
  }
}

/// SwiftUI host of the controller's video view.
@MainActor
struct PlayerVideoSurface: UIViewRepresentable {
  let controller: PlayerController

  func makeUIView(context: Context) -> PlayerVideoContainerView {
    let container = PlayerVideoContainerView()
    container.backgroundColor = .black
    container.clipsToBounds = true
    let controller = self.controller
    container.onEnterWindow = { [weak controller] view in
      MainActor.assumeIsolated {
        controller?.mountVideoView(in: view)
      }
    }
    controller.mountVideoView(in: container)
    return container
  }

  func updateUIView(_ uiView: PlayerVideoContainerView, context: Context) {
    // Only reclaim an orphaned layer: another visible surface may own it.
    if controller.layerView.superview == nil || controller.layerView.superview === uiView {
      controller.mountVideoView(in: uiView)
    }
  }
}

/// AirPlay route picker (the Svelte app had a commented-out Cast button).
@MainActor
struct PlayerAirPlayButton: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = .white
    picker.activeTintColor = .systemBlue
    picker.prioritizesVideoDevices = true
    picker.backgroundColor = .clear
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Wraps AVPictureInPictureController and forwards its delegate events as closures on the main actor.
@MainActor
final class PlayerPiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
  private(set) var pipController: AVPictureInPictureController?
  private var cancellables = Set<AnyCancellable>()

  var onPossibleChanged: ((Bool) -> Void)?
  var onWillStart: (() -> Void)?
  var onDidStart: (() -> Void)?
  var onDidStop: (() -> Void)?
  var onFailed: ((String) -> Void)?
  /// The user tapped "restore" in the PiP window: the player UI must be shown again.
  var onRestore: (() -> Void)?

  static var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  var isActive: Bool {
    pipController?.isPictureInPictureActive ?? false
  }

  func attach(to playerLayer: AVPlayerLayer, autoStart: Bool) {
    guard Self.isSupported else { return }
    if let existing = pipController, existing.playerLayer === playerLayer {
      existing.canStartPictureInPictureAutomaticallyFromInline = autoStart
      return
    }
    guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = autoStart
    pipController = controller
    cancellables.removeAll()
    controller.publisher(for: \.isPictureInPicturePossible)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] possible in
        self?.onPossibleChanged?(possible)
      }
      .store(in: &cancellables)
  }

  func detach() {
    cancellables.removeAll()
    pipController?.delegate = nil
    pipController = nil
  }

  func start() {
    pipController?.startPictureInPicture()
  }

  func stop() {
    pipController?.stopPictureInPicture()
  }

  nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor in
      self.onWillStart?()
    }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor in
      self.onDidStart?()
    }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    let message = error.localizedDescription
    Task { @MainActor in
      self.onFailed?(message)
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    Task { @MainActor in
      self.onDidStop?()
    }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    Task { @MainActor in
      self.onRestore?()
      // Leave time for the player UI to be presented again before PiP animates back into it.
      try? await Task.sleep(nanoseconds: 450_000_000)
      completionHandler(true)
    }
  }
}

/// Lock screen / Control Center info and remote commands (setMediaSession in MediaHandler.svelte and the
/// navigator.mediaSession action handlers in PlayerPage.svelte).
@MainActor
final class PlayerNowPlaying {
  struct Commands {
    var play: () -> Void
    var pause: () -> Void
    var toggle: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var skipForward: () -> Void
    var skipBackward: () -> Void
    var seek: (Double) -> Void
  }

  private var targets: [(command: MPRemoteCommand, token: Any)] = []
  private var info: [String: Any] = [:]
  private var artworkURL: URL?
  private var artworkTask: Task<Void, Never>?

  func enable(_ commands: Commands, skipInterval: Double) {
    disableCommands()
    let center = MPRemoteCommandCenter.shared()
    register(center.playCommand, commands.play)
    register(center.pauseCommand, commands.pause)
    register(center.togglePlayPauseCommand, commands.toggle)
    register(center.nextTrackCommand, commands.next)
    register(center.previousTrackCommand, commands.previous)
    let interval = NSNumber(value: max(skipInterval, 1))
    center.skipForwardCommand.preferredIntervals = [interval]
    center.skipBackwardCommand.preferredIntervals = [interval]
    register(center.skipForwardCommand, commands.skipForward)
    register(center.skipBackwardCommand, commands.skipBackward)

    let seek = commands.seek
    let positionCommand: MPRemoteCommand = center.changePlaybackPositionCommand
    positionCommand.isEnabled = true
    let token = positionCommand.addTarget { event in
      guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let position = positionEvent.positionTime
      DispatchQueue.main.async {
        seek(position)
      }
      return .success
    }
    targets.append((command: positionCommand, token: token))
  }

  private func register(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
    command.isEnabled = true
    let token = command.addTarget { _ in
      DispatchQueue.main.async {
        action()
      }
      return .success
    }
    targets.append((command: command, token: token))
  }

  func disableCommands() {
    for target in targets {
      target.command.removeTarget(target.token)
      target.command.isEnabled = false
    }
    targets.removeAll()
  }

  func setTrackCommands(next: Bool, previous: Bool) {
    guard !targets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    center.nextTrackCommand.isEnabled = next
    center.previousTrackCommand.isEnabled = previous
  }

  func setMetadata(title: String, subtitle: String?, artworkURL: URL?) {
    info[MPMediaItemPropertyTitle] = title
    info[MPMediaItemPropertyArtist] = subtitle
    info[MPMediaItemPropertyAlbumTitle] = "Tsumi"
    info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue)
    if artworkURL != self.artworkURL {
      self.artworkURL = artworkURL
      info[MPMediaItemPropertyArtwork] = nil
      loadArtwork(artworkURL)
    }
    push()
  }

  func setPlayback(elapsed: Double, duration: Double, rate: Double) {
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: elapsed.isFinite ? max(elapsed, 0) : 0)
    if duration.isFinite && duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
    } else {
      info[MPMediaItemPropertyPlaybackDuration] = nil
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: rate)
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = NSNumber(value: 1.0)
    push()
  }

  func clear() {
    disableCommands()
    artworkTask?.cancel()
    artworkTask = nil
    artworkURL = nil
    info = [:]
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func push() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func loadArtwork(_ url: URL?) {
    artworkTask?.cancel()
    artworkTask = nil
    guard let url else { return }
    artworkTask = Task { [weak self] in
      guard let response = try? await HTTP.data(url, timeout: 20),
            let image = UIImage(data: response.0) else { return }
      guard !Task.isCancelled, let self, self.artworkURL == url else { return }
      self.info[MPMediaItemPropertyArtwork] = PlayerNowPlaying.makeArtwork(image)
      self.push()
    }
  }

  /// Built outside the main actor: MediaPlayer calls the request handler on a background queue.
  nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }
}

/// Landscape lock while the player is shown. For a hard lock the app delegate should return
/// `PlayerOrientation.supportedMask` from `application(_:supportedInterfaceOrientationsFor:)`;
/// without it the player still rotates to landscape when it opens.
@MainActor
enum PlayerOrientation {
  static var supportedMask: UIInterfaceOrientationMask = defaultMask

  static var defaultMask: UIInterfaceOrientationMask {
    UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
  }

  static func lockLandscape() {
    supportedMask = .landscape
    apply(.landscape)
  }

  static func unlock() {
    supportedMask = defaultMask
    apply(defaultMask)
  }

  private static func apply(_ mask: UIInterfaceOrientationMask) {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows {
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      }
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
  }
}

/// AVAudioSession `.playback`: sound with the silent switch on, background audio and Picture in Picture.
enum PlayerAudioSession {
  static func activate() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      // Playback still works with the default session, only background audio is affected.
    }
  }

  static func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
