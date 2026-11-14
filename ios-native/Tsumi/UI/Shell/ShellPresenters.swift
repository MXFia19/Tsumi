import SwiftUI

// Presentation hosts of the shell. App.svelte stacks DetailsModal, ExtensionModal, DefaultLoadingModal,
// ServerSelectorModal, NotificationsModal, Profiles and the player layer; on iOS each layer presents only
// from the controller on top, so the playback dialogs (PlaybackRequestSheetView) and the toasts are hosted
// by whichever layer is currently the top one (see ShellLayers).

/// Playback dialogs (default extension loading, extension results, server selector) on one layer.
/// Same binding and dismissal semantics as `.playbackRequestPresenter()`, restricted to the top layer.
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
    .modifier(ShellPlaybackDialogHost(layer: .rootSheet))
    .modifier(ShellToastHost(layer: .rootSheet))
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

/// Full screen player (replaces `.playerPresentationHost()`): same `PlayerPresentation` state, plus the
/// details sheet over the player and the dialogs / toasts of the player layers.
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
        // pagePause: resume the player when the details close (unless it is being replaced).
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

/// Details shown over the player ("Now Playing" details): the player pauses while it is open.
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
