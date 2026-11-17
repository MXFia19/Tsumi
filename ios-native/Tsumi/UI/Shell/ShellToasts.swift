import SwiftUI
import Observation
import Network
import Accessibility

// Toasts (svelte-sonner <Toaster visibleToasts={2} position='top-right' theme='dark' richColors
// duration={10_000} closeButton> in App.svelte) fed by ServiceMessages, and the connection status bar
// (common/components/Status.svelte: "Offline" / "AniList Outage" / "Connection Restored").

enum ShellToastStyle {
  static let duration: TimeInterval = 10
  static let visibleCount = 2
}

/// Shows the toasts on one layer, only while it is the top one. Hidden over the bare player like the
/// Svelte toaster in fullscreen; the expiry runs anyway (ShellToastJanitor).
@MainActor
struct ShellToastHost: ViewModifier {
  let layer: ShellLayer

  func body(content: Content) -> some View {
    ShellLayers.track()
    _ = ServiceMessages.shared.messages
    return content.overlay(alignment: .top) {
      if layer != .player && ShellLayers.top == layer {
        VStack(spacing: 8) {
          // Expired AniList / MyAnimeList sessions: Log in again / Log out (ShellSessionExpiry.swift).
          ShellSessionExpiryPrompts()
          ShellToastStack()
          // Watch Together invites outside the full screen player (the player shows its own).
          ShellWatchTogetherInvites()
        }
      }
    }
  }
}

/// Watch Together invites received while not in the full screen player: "Alice invites you to watch …"
/// with Join / Dismiss, app-wide (PROTOCOL.md v2.1 `invite`).
@MainActor
struct ShellWatchTogetherInvites: View {
  var body: some View {
    let client = WatchTogetherClient.shared
    // The lobby screen shows its own Join card.
    let lobbyVisible = AppRouter.shared.selectedTab == .watchTogether && ShellLayers.top == .root
    return VStack(spacing: 8) {
      if client.isInLobby {
        // v2.3: joined a lobby that is already watching: Join prompt once, wherever the user is.
        if !lobbyVisible, let offer = client.appWideJoinOffer {
          W2GJoinCard(offer: offer, client: client, dismissible: true)
            .frame(maxWidth: 420)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        ForEach(client.invites) { invite in
          W2GInvitePrompt(invite: invite, client: client)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
    }
    .padding(.horizontal, 12)
    .animation(.easeInOut(duration: 0.2), value: client.invites)
    .animation(.easeInOut(duration: 0.2), value: client.appWideJoinOffer)
  }
}

@MainActor
struct ShellToastStack: View {
  var body: some View {
    let visible = Array(ServiceMessages.shared.messages.suffix(ShellToastStyle.visibleCount).reversed())
    return VStack(spacing: 8) {
      ForEach(visible) { message in
        ShellToastCard(message: message)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 4)
    .frame(maxWidth: 520)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: visible.map { $0.id })
  }
}

@MainActor
struct ShellToastCard: View {
  let message: ServiceMessages.Message

  private var icon: String {
    switch message.kind {
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    case .info: return "info.circle.fill"
    }
  }

  private var tint: Color {
    switch message.kind {
    case .success: return ShellPalette.color(0x4ADE80)
    case .warning: return ShellPalette.color(0xFACC15)
    case .error: return ShellPalette.color(0xF87171)
    case .info: return Color.white
    }
  }

  private var fill: Color {
    switch message.kind {
    case .success: return ShellPalette.color(0x0B2A17)
    case .warning: return ShellPalette.color(0x2A2405)
    case .error: return ShellPalette.color(0x2D0B0B)
    case .info: return ShellPalette.color(0x18191D)
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 3) {
        Text(message.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.white)
        if !message.detail.isEmpty {
          Text(message.detail)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.75))
            .lineLimit(6)
        }
        // sonner `action` button ("Open as is" of a Sora module result without AniList / TMDB match).
        if let label = message.actionLabel {
          Button {
            ServiceMessages.shared.performAction(message.id)
          } label: {
            Text(label)
              .font(.footnote.weight(.semibold))
              .foregroundStyle(Color.black)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 4)
      Button {
        ServiceMessages.shared.dismiss(message.id)
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(Color.white.opacity(0.7))
          .padding(4)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close toast")
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(fill.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.35), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.45), radius: 10, y: 4)
    .contentShape(Rectangle())
    .onTapGesture {
      ServiceMessages.shared.dismiss(message.id)
    }
    .gesture(
      DragGesture(minimumDistance: 12).onEnded { value in
        if value.translation.height < -20 {
          ServiceMessages.shared.dismiss(message.id)
        }
      }
    )
  }
}

/// VoiceOver reads each new toast: they appear at the top of the screen without taking the focus, so they
/// were silent. Hosted once by the root view (the toast stack itself moves between layers).
@MainActor
struct ShellToastAnnouncer: View {
  /// Toasts posted before this date were already announced (or posted before launch).
  @State private var announcedUntil = Date()

  var body: some View {
    let latestId = ServiceMessages.shared.latest?.id
    return Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: latestId) { _, _ in
        // The latest one also changes when the newest toast is closed: only newer toasts are read.
        guard let message = ServiceMessages.shared.latest, message.date > announcedUntil else { return }
        announcedUntil = message.date
        let text = message.detail.isEmpty ? message.title : "\(message.title). \(message.detail)"
        AccessibilityNotification.Announcement(text).post()
      }
  }
}

/// sonner timers: every toast disappears 10 s after it was posted, visible or not.
@MainActor
enum ShellToastJanitor {
  static func run() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      let now = Date()
      let expired = ServiceMessages.shared.messages.filter { now.timeIntervalSince($0.date) >= ShellToastStyle.duration }
      for message in expired {
        ServiceMessages.shared.dismiss(message.id)
      }
    }
  }
}

// MARK: - Connection status (Status.svelte)

/// NWPathMonitor wrapper outside the main actor (its callbacks run on a private queue).
final class ShellPathWatcher: @unchecked Sendable {
  private let monitor = NWPathMonitor()

  func start(_ onChange: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { path in
      onChange(path.status != .satisfied)
    }
    monitor.start(queue: DispatchQueue(label: "org.tsumi.shell.network"))
  }
}

@MainActor
@Observable
final class ShellConnectionMonitor {
  static let shared = ShellConnectionMonitor()

  private(set) var isOffline = false
  /// "Connection Restored" shown for 2.5 s after coming back online.
  private(set) var showRestored = false

  @ObservationIgnored private let watcher = ShellPathWatcher()
  @ObservationIgnored private var started = false
  @ObservationIgnored private var restoredTask: Task<Void, Never>?

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    watcher.start { offline in
      Task { @MainActor in
        ShellConnectionMonitor.shared.update(offline: offline)
      }
    }
    observeAniListStatus()
  }

  /// Follows ServiceNetworkMonitor.isAniListDown (set by the AniList client) for the restored flash.
  private func observeAniListStatus() {
    withObservationTracking {
      _ = ServiceNetworkMonitor.shared.isAniListDown
    } onChange: {
      Task { @MainActor in
        let monitor = ShellConnectionMonitor.shared
        monitor.aniListStatusChanged(down: ServiceNetworkMonitor.shared.isAniListDown)
        monitor.observeAniListStatus()
      }
    }
  }

  func update(offline: Bool) {
    guard offline != isOffline else { return }
    isOffline = offline
    restoredTask?.cancel()
    if offline {
      showRestored = false
      return
    }
    flashRestored()
  }

  /// End / start of an AniList outage (ServiceNetworkMonitor.isAniListDown): "Connection Restored" when it ends.
  func aniListStatusChanged(down: Bool) {
    restoredTask?.cancel()
    if down || isOffline {
      showRestored = false
      return
    }
    flashRestored()
  }

  private func flashRestored() {
    showRestored = true
    restoredTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      if !Task.isCancelled {
        ShellConnectionMonitor.shared.showRestored = false
      }
    }
  }
}

@MainActor
struct ShellConnectionBanner: View {
  var body: some View {
    let monitor = ShellConnectionMonitor.shared
    let aniListDown = ServiceNetworkMonitor.shared.isAniListDown
    return Group {
      if monitor.isOffline {
        // Tap: the downloads, which play without network.
        Button {
          ShellNavigation.openDownloads()
        } label: {
          bar(text: "Offline · Downloads", icon: "wifi.slash", background: ShellPalette.color(0x101114))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your downloads")
      } else if aniListDown {
        bar(text: "AniList Outage", icon: "exclamationmark.icloud", background: ShellPalette.color(0x101114))
      } else if monitor.showRestored {
        bar(text: "Connection Restored", icon: "globe", background: ShellPalette.color(0x2E7D32))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: monitor.isOffline)
    .animation(.easeInOut(duration: 0.3), value: aniListDown)
    .animation(.easeInOut(duration: 0.3), value: monitor.showRestored)
  }

  private func bar(text: String, icon: String, background: Color) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.subheadline.weight(.semibold))
      Text(text)
        .font(.subheadline.weight(.semibold))
    }
    .foregroundStyle(Color.white)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
    .background(background)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

/// Colors of the Svelte theme (common/css.css variables) used by the shell.
enum ShellPalette {
  static func color(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  static let current = color(0x3DB4F2)
  static let repeating = color(0x3BAEEA)
  static let completed = color(0x5CD13D)
  static let dropped = color(0xE85D75)
  static let announcement = color(0xFFFFF0)
  static let notWatching = color(0x4F5866)
  static let notify = color(0xAF68FA)
  static let anilist = color(0x283342)
  static let myAnimeList = color(0x2C4FA1)
  static let badgeEpisode = color(0xCCCCFF)
  static let badgeDelayed = color(0xBC2023)
  static let badgeDub = color(0xFFD600)
  static let badgeSub = color(0x8927FF)
  static let error = color(0xC0392B)
  static let card = color(0x1C1D21)
}
