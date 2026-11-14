import Observation
import SwiftUI

/// Keeps the current PlayerController alive and tells the shell how to show it: full screen (`isPresented`),
/// minimized to the in-app miniplayer (Miniplayer.svelte) or to Picture in Picture. The shell presents
/// `PlayerView` while `isPresented` is true (ShellPlayerHost) and the miniplayer while `miniPlayerController`
/// is set (ShellMiniPlayerOverlay).
///
/// Usage: set the controller hooks, then `PlayerPresentation.shared.present(controller)`.
@MainActor
@Observable
final class PlayerPresentation {
  static let shared = PlayerPresentation()

  private(set) var controller: PlayerController?
  var isPresented = false
  /// Presents the player UI after "restore" in the Picture in Picture window. The shell sets it to close its
  /// sheets first; without it the player is presented at once.
  @ObservationIgnored var restoreHandler: (() -> Void)?

  /// The player UI is dismissed while playback continues (miniplayer or Picture in Picture).
  var isMinimized: Bool { controller != nil && !isPresented }

  /// Controller to show in the in-app miniplayer: minimized and not in Picture in Picture (the PiP window
  /// already shows the video; closing it brings the video back to the miniplayer).
  var miniPlayerController: PlayerController? {
    guard let controller, !isPresented, !controller.isPictureInPictureActive else { return nil }
    return controller
  }

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
      guard let self else { return }
      if let handler = self.restoreHandler {
        handler()
      } else {
        self.isPresented = true
      }
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
