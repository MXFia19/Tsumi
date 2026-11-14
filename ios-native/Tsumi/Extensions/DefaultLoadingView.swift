import SwiftUI

/// Compact dialog shown while the default extension resolves a stream (DefaultLoadingModal.svelte):
/// spinner, title (2 lines), "Episode N" and the current step
/// ("Connecting to extension...", "Searching...", "Extracting episodes...", "Loading stream...").
@MainActor
struct DefaultLoadingView: View {
  let model: DefaultLoadingModel

  var body: some View {
    VStack(spacing: 0) {
      ProgressView()
        .controlSize(.large)
        .tint(Color.accentColor)
        .padding(.bottom, 20)
      Text(model.title)
        .font(.headline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.bottom, 5)
      Text("Episode \(model.episode.number)")
        .font(.subheadline)
        .foregroundStyle(ExtensionPalette.muted)
      Text(model.statusText)
        .font(.subheadline)
        .foregroundStyle(ExtensionPalette.muted)
        .padding(.top, 15)
        .animation(.default, value: model.statusText)
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.92))
  }
}
