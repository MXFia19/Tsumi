import SwiftUI

// Presentation hosts of the shell. App.svelte stacks DetailsModal, ExtensionModal, DefaultLoadingModal,
// ServerSelectorModal, NotificationsModal, Profiles and the player layer; on iOS each layer presents only
// from the controller on top, so the playback dialogs (PlaybackRequestSheetView) and the toasts are hosted
// by whichever layer is currently the top one (see ShellLayers). The in-app miniplayer (Miniplayer.svelte)
// floats over the root view, or over the details sheet when one is open.

/// Playback dialogs (default extension loading, extension results, server selector) on one layer.
/// Binds `PlaybackRequestCoordinator.presentation` (a sheet on the top layer only); closing the sheet stops
/// the running resolution (`sheetDidDismiss`).
@MainActor
struct ShellPlaybackDialogHost: ViewModifier {
  let layer: ShellLayer

  func body(content: Content) -> some View {
    ShellLayers.track()
    let coordinator = PlaybackRequestCoordinator.shared
    let layer = self.layer
    return content.sheet(
      item: Binding<PlaybackRequestPresentation?>(
        get: { ShellLayers.top == layer ? coordinator.presentation : nil },
        set: { value in
          if ShellLayers.top == layer { coordinator.presentation = value }
        }
      ),
      onDismiss: { PlaybackRequestCoordinator.shared.sheetDidDismiss() },
      content: { presentation in
        PlaybackRequestSheetView(presentation: presentation)
      }
    )
  }
}

/// Everything the root view presents: root sheets, playback dialogs, the player and the toasts.
@MainActor
struct ShellRootPresenters: ViewModifier {
  func body(content: Content) -> some View {
    ShellLayers.track()
    return content
      .sheet(
        item: Binding<ShellRootSheet?>(
          get: { ShellLayers.playerVisible ? nil : ShellLayers.rootSheet },
          set: { value in
            if value == nil { ShellNavigation.clearRootSheets() }
          }
        ),
        onDismiss: { ShellNavigation.rootSheetDidDismiss() },
        content: { sheet in
          ShellRootSheetContent(sheet: sheet)
        }
      )
      .modifier(ShellPlaybackDialogHost(layer: .root))
      .modifier(ShellPlayerHost())
      .modifier(ShellToastHost(layer: .root))
  }
}

/// Content of a root sheet, which becomes the top layer while it is shown.
@MainActor
struct ShellRootSheetContent: View {
  let sheet: ShellRootSheet

  var body: some View {
    Group {
      switch sheet {
      case .details(let media):
        ShellDetailsContainer(media: media)
      case .notifications:
        NotificationsView()
      case .profiles:
        ProfilesView()
      }
    }
    .overlay {
      ShellMiniPlayerOverlay(layer: .rootSheet)
    }
    .modifier(ShellPlaybackDialogHost(layer: .rootSheet))
    .modifier(ShellToastHost(layer: .rootSheet))
  }
}

/// In-app miniplayer (App.svelte `miniplayer`): shown while the player is minimized and not in Picture in
/// Picture, across every tab. It sits on the root view, or on the details sheet while one is open (Svelte keeps
/// it above the details modal); other sheets cover it. Tap restores the full player, X closes it.
@MainActor
struct ShellMiniPlayerOverlay: View {
  let layer: ShellLayer

  /// Layer hosting the miniplayer: the details sheet when shown, else the root view.
  static var hostLayer: ShellLayer {
    if case .some(.details) = ShellLayers.rootSheet { return .rootSheet }
    return .root
  }

  var body: some View {
    ShellLayers.track()
    let controller = PlayerPresentation.shared.miniPlayerController
    let visible = controller != nil && ShellMiniPlayerOverlay.hostLayer == layer
    return ZStack {
      if let controller, visible {
        PlayerMiniPlayerDock(
          controller: controller,
          insets: insets,
          onExpand: { ShellPlayback.restorePlayer() },
          onClose: { PlayerPresentation.shared.dismiss() }
        )
        .id(ObjectIdentifier(controller))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: visible)
  }

  /// Root: clear of the navigation bar and the tab bar. Sheet: small margins.
  private var insets: EdgeInsets {
    layer == .root
      ? EdgeInsets(top: 60, leading: 12, bottom: 60, trailing: 12)
      : EdgeInsets(top: 56, leading: 12, bottom: 16, trailing: 12)
  }
}

/// DetailsModal. MediaDetailView draws its own close button (closeDetails + dismiss) and pushes nothing,
/// so it is shown without a navigation bar; another title replaces the content in place (.id inside).
@MainActor
struct ShellDetailsContainer: View {
  let media: Media

  var body: some View {
    MediaDetailView(media: media)
      .presentationDragIndicator(.visible)
  }
}

/// Full screen player: `PlayerPresentation.isPresented` / `controller`, plus the details sheet over the player
/// and the dialogs / toasts of the player layers. Minimizing dismisses it; the miniplayer takes over.
@MainActor
struct ShellPlayerHost: ViewModifier {
  func body(content: Content) -> some View {
    ShellLayers.track()
    let presentation = PlayerPresentation.shared
    return content.fullScreenCover(
      isPresented: Binding<Bool>(
        get: { presentation.isPresented },
        set: { presentation.isPresented = $0 }
      )
    ) {
      ShellPlayerCover()
    }
  }
}

@MainActor
struct ShellPlayerCover: View {
  var body: some View {
    ShellLayers.track()
    let presentation = PlayerPresentation.shared
    return ZStack {
      Color.black.ignoresSafeArea()
      if let controller = presentation.controller {
        PlayerView(controller: controller)
          .id(ObjectIdentifier(controller))
      }
    }
    .sheet(
      item: Binding<ShellMediaItem?>(
        get: { ShellLayers.playerVisible ? AppRouter.shared.presentedMedia.map { ShellMediaItem(media: $0) } : nil },
        set: { value in
          if value == nil { AppRouter.shared.presentedMedia = nil }
        }
      ),
      onDismiss: {
        // The details closed: the player gets its keyboard focus back (unless it is being replaced).
        if !ShellState.shared.replacingPlayer {
          PlayerPresentation.shared.controller?.setExternalOverlay(presented: false)
        }
      },
      content: { item in
        ShellPlayerDetailsSheet(media: item.media)
      }
    )
    .modifier(ShellPlaybackDialogHost(layer: .player))
  }
}

/// Details shown over the player ("Now Playing" details). The player keeps playing underneath, like the
/// Svelte app (details over the player do not pause it).
@MainActor
struct ShellPlayerDetailsSheet: View {
  let media: Media

  var body: some View {
    ShellDetailsContainer(media: media)
      .modifier(ShellPlaybackDialogHost(layer: .playerSheet))
      .modifier(ShellToastHost(layer: .playerSheet))
      .onAppear {
        PlayerPresentation.shared.controller?.setExternalOverlay(presented: true)
      }
  }
}
