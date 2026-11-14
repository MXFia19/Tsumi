import Observation
import SwiftUI

/// Optional host for the player: keeps the current PlayerController alive, presents PlayerView full screen,
/// dismisses it while Picture in Picture runs (the desktop miniplayer) and presents it again on PiP restore.
///
/// Usage: attach `.playerPresentationHost()` once near the root view, then
/// `PlayerPresentation.shared.present(controller)` after setting the controller hooks.
@MainActor
@Observable
final class PlayerPresentation {
  static let shared = PlayerPresentation()

  private(set) var controller: PlayerController?
  var isPresented = false

  /// Shows a player, closing the previous one (only one player at a time, like the Svelte app).
  func present(_ newController: PlayerController) {
    if let current = controller, current !== newController {
      controller = nil
      current.close()
    }
    let userClose = newController.onClose
    newController.onClose = { [weak self, weak newController] in
      userClose?()
      guard let self, let newController, self.controller === newController else { return }
      self.isPresented = false
      self.controller = nil
    }
    let userMinimize = newController.onMinimize
    newController.onMinimize = { [weak self] in
      userMinimize?()
      self?.isPresented = false
    }
    let userRestore = newController.onRestoreFromPictureInPicture
    newController.onRestoreFromPictureInPicture = { [weak self] in
      userRestore?()
      self?.isPresented = true
    }
    controller = newController
    isPresented = true
  }

  /// Closes the current player (saves progress, stops playback and Picture in Picture).
  func dismiss() {
    controller?.close()
    controller = nil
    isPresented = false
  }
}

@MainActor
struct PlayerPresentationHost: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    let presentation = PlayerPresentation.shared
    content.fullScreenCover(
      isPresented: Binding(
        get: { presentation.isPresented },
        set: { presentation.isPresented = $0 }
      )
    ) {
      if let controller = presentation.controller {
        PlayerView(controller: controller)
      }
    }
  }
}

extension View {
  /// Presents `PlayerPresentation.shared` full screen. Attach once, near the root view.
  @MainActor
  func playerPresentationHost() -> some View {
    modifier(PlayerPresentationHost())
  }
}
