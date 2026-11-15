import SwiftUI

// "Update available" UI of the sideloaded app (AppUpdateChecker): a banner over every tab until it is closed for
// that version, and a row at the top of Settings. Both open the download page.

/// Root hook (RootView): checks for a new release at launch and when the app comes back to the foreground (at most
/// every few hours) and shows the banner at the top.
@MainActor
struct ShellUpdateCheck: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) {
        ShellUpdateBanner()
      }
      .task {
        await AppUpdateChecker.shared.checkIfNeeded()
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { await AppUpdateChecker.shared.checkIfNeeded() }
      }
  }
}

@MainActor
struct ShellUpdateBanner: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    let checker = AppUpdateChecker.shared
    return Group {
      if checker.showsBanner, let update = checker.available {
        HStack(spacing: 10) {
          Image(systemName: "arrow.down.circle.fill")
            .foregroundStyle(ShellPalette.current)
          Text("Update available: v\(update.version)")
            .lineLimit(1)
          Spacer(minLength: 8)
          Button("Download") {
            openURL(AppUpdateChecker.downloadPage)
          }
          .foregroundStyle(ShellPalette.current)
          Button {
            checker.dismissBanner()
          } label: {
            Image(systemName: "xmark")
              .foregroundStyle(Color.secondary)
          }
          .accessibilityLabel("Close")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ShellPalette.color(0x101114))
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: checker.showsBanner)
  }
}

/// First section of Settings while a newer release exists.
@MainActor
struct ShellUpdateSection: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    let checker = AppUpdateChecker.shared
    if let update = checker.available {
      Section {
        Button {
          openURL(AppUpdateChecker.downloadPage)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
              .font(.title2)
              .foregroundStyle(ShellPalette.current)
            VStack(alignment: .leading, spacing: 2) {
              Text("Update available")
                .font(.body.weight(.semibold))
              Text("Tsumi v\(update.version) is out, you have v\(checker.installedVersion).")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right.square")
              .foregroundStyle(Color.secondary)
          }
          .foregroundStyle(Color.primary)
        }
      } footer: {
        Text("Update from the Tsumi source in Feather, or download the new .ipa and install it like the first time.")
      }
    }
  }
}
