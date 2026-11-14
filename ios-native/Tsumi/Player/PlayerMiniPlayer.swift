import SwiftUI

// In-app miniplayer (components/Miniplayer.svelte + the `miniplayer` mode of PlayerPage.svelte): the video keeps
// playing in a small floating window while the rest of the app is used. It shows the same AVPlayerLayer as the
// full screen player, docks in a corner (dragged to another corner, remembered like 'posMiniplayer'), restores
// the player when tapped and has play / pause, previous / next and close (X) buttons.

/// Miniplayer docked in a corner of the area it is placed in. Lay it out over the content (overlay); it only
/// takes touches on the miniplayer itself.
@MainActor
struct PlayerMiniPlayerDock: View {
  let controller: PlayerController
  /// Space kept free around the miniplayer (navigation bar, tab bar).
  var insets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
  let onExpand: () -> Void
  let onClose: () -> Void

  @State private var corner = PlayerPreferences.miniPlayerCorner
  @State private var dragOffset: CGSize = .zero

  var body: some View {
    GeometryReader { proxy in
      let size = CGSize(width: PlayerMiniPlayerDock.width(for: proxy.size), height: PlayerMiniPlayerDock.width(for: proxy.size) * 9 / 16)
      PlayerMiniPlayer(controller: controller, onExpand: onExpand, onClose: onClose)
        .frame(width: size.width, height: size.height)
        .offset(dragOffset)
        .gesture(
          DragGesture(minimumDistance: 12)
            .onChanged { value in
              dragOffset = value.translation
            }
            .onEnded { value in
              // Snap to the corner nearest to where the throw ends (Miniplayer.svelte dragEnd).
              let center = dockedCenter(container: proxy.size, size: size)
              let endX = center.x + value.predictedEndTranslation.width
              let endY = center.y + value.predictedEndTranslation.height
              let target = PlayerMiniPlayerCorner.nearest(
                top: endY < proxy.size.height / 2,
                leading: endX < proxy.size.width / 2
              )
              PlayerPreferences.miniPlayerCorner = target
              withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                corner = target
                dragOffset = .zero
              }
            }
        )
        .padding(insets)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: PlayerMiniPlayerDock.alignment(corner))
    }
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }

  /// Centre of the miniplayer docked in `corner`, in the dock's coordinates.
  private func dockedCenter(container: CGSize, size: CGSize) -> CGPoint {
    let x = corner.isLeading ? insets.leading + size.width / 2 : container.width - insets.trailing - size.width / 2
    let y = corner.isTop ? insets.top + size.height / 2 : container.height - insets.bottom - size.height / 2
    return CGPoint(x: x, y: y)
  }

  /// Phones: half the width (max 300 pt); larger screens: about a quarter (Miniplayer.svelte min ratio).
  static func width(for size: CGSize) -> CGFloat {
    let available = max(size.width, 1)
    if available < 600 { return min(max(available * 0.52, 180), 300) }
    return min(max(available * 0.28, 260), 420)
  }

  static func alignment(_ corner: PlayerMiniPlayerCorner) -> Alignment {
    switch corner {
    case .topLeading: return .topLeading
    case .topTrailing: return .topTrailing
    case .bottomLeading: return .bottomLeading
    case .bottomTrailing: return .bottomTrailing
    }
  }
}

/// The miniplayer window: video, spinner, play / pause, previous / next, close, progress line.
@MainActor
struct PlayerMiniPlayer: View {
  let controller: PlayerController
  let onExpand: () -> Void
  let onClose: () -> Void

  var body: some View {
    ZStack {
      Color.black
      PlayerVideoSurface(controller: controller)
        .allowsHitTesting(false)
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .accessibilityLabel("Open Player")
        .accessibilityAddTraits(.isButton)
      if showSpinner {
        ProgressView()
          .tint(.white)
          .allowsHitTesting(false)
      }
      controls
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    .environment(\.colorScheme, .dark)
  }

  private var showSpinner: Bool {
    if controller.isLoadingEpisode { return true }
    guard controller.failure == nil else { return false }
    return controller.isBuffering || controller.phase == .loading
  }

  private var controls: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        button("xmark", label: "Exit", size: 13, action: onClose)
      }
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        if controller.hasLast {
          button("backward.end.fill", label: "Last", size: 13) {
            Task { await controller.playPrevious() }
          }
        }
        button(playIcon, label: "Play/Pause", size: 15) { controller.togglePlayPause() }
        if controller.hasNext {
          button("forward.end.fill", label: "Next", size: 13) {
            Task { await controller.playNext() }
          }
        }
        Spacer(minLength: 0)
        button("arrow.up.left.and.arrow.down.right", label: "Open Player", size: 12, action: onExpand)
      }
      progressLine
    }
    .foregroundStyle(.white)
  }

  private var playIcon: String {
    if controller.hasEnded { return "arrow.clockwise" }
    return controller.isPlaying ? "pause.fill" : "play.fill"
  }

  private var progressLine: some View {
    GeometryReader { proxy in
      let total = controller.safeDuration
      let fraction = total > 0 ? CGFloat(min(max(controller.displayTime / total, 0), 1)) : 0
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.white.opacity(0.25))
        Rectangle()
          .fill(controller.isEpisodeWatched ? Color.green.opacity(0.8) : Color.accentColor)
          .frame(width: proxy.size.width * fraction)
      }
    }
    .frame(height: 3)
    .allowsHitTesting(false)
  }

  private func button(_ systemName: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .bold))
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.45)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(3)
    .accessibilityLabel(label)
  }
}
