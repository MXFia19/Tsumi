import SwiftUI
import UIKit

// Hold to speed up (Shiru 6.9.0, #180; PC: common/modules/holdspeed.js + PlayerPage.svelte): a long press on the
// video (not on the controls, which sit above the gesture layer) or holding Space on a hardware keyboard plays at
// `playerHoldSpeed` until released, with a "2× ▶▶" indicator; a short tap keeps its usual action. Off while the
// player follows a Watch Together lobby: a temporary rate would drift from the others (PROTOCOL.md "Auto-sync").

enum PlayerHoldSpeed {
  /// Speeds offered by the `playerHoldSpeed` setting (holdspeed.js HOLD_SPEEDS).
  static let speeds: [Double] = [1.5, 2, 3]
  static let defaultSpeed: Double = 2
  /// A press longer than this (seconds) is a hold (holdspeed.js HOLD_DELAY).
  static let delay: Double = 0.5

  /// The setting as one of `speeds` (the default when unknown).
  static func speed(_ value: Double) -> Double {
    speeds.contains(value) ? value : defaultSpeed
  }

  /// "2×", "1.5×"
  static func label(_ speed: Double) -> String {
    String(format: "%g×", speed)
  }
}

enum PlayerHoldSource {
  case touch
  case key
}

/// Kept by PlayerController (`holdSpeedState`).
struct PlayerHoldSpeedState {
  /// What is held; set even when the hold was refused (Watch Together) so its release does nothing.
  var source: PlayerHoldSource?
  /// The hold started on a paused video: paused again when it ends.
  var startedPaused = false
  /// When the last hold ended: the tap that ends a long press is not a tap on the video.
  var endedAt = Date.distantPast
  /// Space is down, not held long enough yet.
  var keyTask: Task<Void, Never>?
}

extension PlayerController {
  /// A hold is going on or just ended: the video tap that comes with it is ignored.
  var isHoldingOrJustHeld: Bool {
    holdSpeedState.source != nil || Date().timeIntervalSince(holdSpeedState.endedAt) < 0.4
  }

  private var canHoldSpeed: Bool {
    AppSettings.shared.values.playerHoldSpeedUp && isReady && !hasEnded && !isLoadingEpisode && failure == nil
  }

  /// Following the lobby's playback (watching on our own nothing is synced).
  private var isSyncedWithLobby: Bool {
    let client = WatchTogetherClient.shared
    return client.isInLobby && client.following
  }

  /// The press became a hold (long press recognized, or Space held long enough): faster from now on.
  func beginHoldSpeed(_ source: PlayerHoldSource) {
    guard holdSpeedState.source == nil, canHoldSpeed else { return }
    holdSpeedState.source = source
    if isSyncedWithLobby {
      if source == .touch { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
      showNotice("Watch Together", "Hold to speed up is off while you watch in sync with the lobby.")
      return
    }
    var rate = Float(PlayerHoldSpeed.speed(AppSettings.shared.values.playerHoldSpeed))
    // Rates above 2 need an item that can fast forward.
    if rate > 2, player.currentItem?.canPlayFastForward == false { rate = 2 }
    holdSpeedState.startedPaused = !isPlaying
    holdSpeedRate = rate
    player.rate = rate
    if source == .touch { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
  }

  /// The finger lifted / Space was released: back to the normal rate, paused again when it started paused.
  func endHoldSpeed(_ source: PlayerHoldSource) {
    guard holdSpeedState.source == source else { return }
    holdSpeedState.source = nil
    holdSpeedState.endedAt = Date()
    stopHoldSpeed(pause: true)
  }

  /// Ends the faster rate (the press may go on). Returns true when it paused the video again.
  @discardableResult
  func stopHoldSpeed(pause: Bool) -> Bool {
    guard holdSpeedRate != nil else { return false }
    holdSpeedRate = nil
    if pause && holdSpeedState.startedPaused {
      player.pause()
      return true
    }
    if player.rate != 0 { player.rate = playbackRate }
    return false
  }

  /// App leaving, player closing, keyboard focus lost: ends the press and the hold without a tap action.
  @discardableResult
  func cancelHoldSpeed() -> Bool {
    holdSpeedState.keyTask?.cancel()
    holdSpeedState.keyTask = nil
    if holdSpeedState.source != nil { holdSpeedState.endedAt = Date() }
    holdSpeedState.source = nil
    return stopHoldSpeed(pause: true)
  }

  /// Space down. True when the release decides: a tap plays / pauses, a hold plays faster meanwhile.
  func pressHoldSpeedKey() -> Bool {
    // A release that never came (focus moved meanwhile): this press starts over.
    if holdSpeedState.keyTask != nil || holdSpeedState.source == .key { cancelHoldSpeed() }
    guard holdSpeedState.source == nil, canHoldSpeed else { return false }
    holdSpeedState.keyTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(PlayerHoldSpeed.delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.holdSpeedState.keyTask = nil
      self.beginHoldSpeed(.key)
    }
    return true
  }

  /// Space up. True when it was ours: a short press played / paused, or the hold ended.
  func releaseHoldSpeedKey() -> Bool {
    if let task = holdSpeedState.keyTask {
      task.cancel()
      holdSpeedState.keyTask = nil
      togglePlayPause()
      return true
    }
    guard holdSpeedState.source == .key else { return false }
    endHoldSpeed(.key)
    return true
  }

  /// The player view lost the keyboard focus: Space's release will not come.
  func cancelHoldSpeedKey() {
    if holdSpeedState.keyTask != nil || holdSpeedState.source == .key { cancelHoldSpeed() }
  }
}

/// Long press on the video layer: faster while the finger stays down (PlayerView's gesture layer).
@MainActor
struct PlayerHoldSpeedGesture: ViewModifier {
  let controller: PlayerController
  @GestureState private var held = false

  func body(content: Content) -> some View {
    content
      .simultaneousGesture(
        LongPressGesture(minimumDuration: PlayerHoldSpeed.delay, maximumDistance: 20)
          .sequenced(before: DragGesture(minimumDistance: 0))
          .updating($held) { value, state, _ in
            if case .second(true, _) = value { state = true }
          }
      )
      .onChange(of: held) { _, isHeld in
        if isHeld {
          controller.beginHoldSpeed(.touch)
        } else {
          controller.endHoldSpeed(.touch)
        }
      }
  }
}

/// "2× ▶▶" at the top of the video while it is held.
@MainActor
struct PlayerHoldSpeedIndicator: View {
  let rate: Float

  var body: some View {
    VStack {
      HStack(spacing: 6) {
        Text(PlayerHoldSpeed.label(Double(rate)))
          .font(.headline.monospacedDigit())
        Image(systemName: "forward.fill")
          .font(.subheadline)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Capsule().fill(Color.black.opacity(0.55)))
      .padding(.top, 72)
      Spacer(minLength: 0)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Playing at \(PlayerHoldSpeed.label(Double(rate))) speed")
  }
}
