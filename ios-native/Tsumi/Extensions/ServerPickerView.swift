import SwiftUI

/// "Select Server" dialog (ServerSelectorModal.svelte): back button, "Remember selection for this
/// session" (StreamSessionMemory), one row per server ("Server N" when untitled).
@MainActor
struct ServerPickerView: View {
  let servers: [StreamServer]
  var onSelect: (Int) -> Void
  var onBack: () -> Void

  @State private var remember = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 15) {
        Button(action: onBack) {
          Image(systemName: "arrow.left")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        Text("Select Server")
          .font(.title3.bold())
          .foregroundStyle(.white)
        Spacer()
      }
      .padding(.bottom, 20)

      Toggle(isOn: $remember) {
        Text("Remember selection for this session")
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
      }
      .toggleStyle(.switch)
      .padding(.bottom, 10)

      ScrollView {
        VStack(spacing: 10) {
          ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
            Button {
              pick(index)
            } label: {
              HStack(spacing: 15) {
                Image(systemName: "server.rack")
                  .font(.title2)
                  .foregroundStyle(Color.accentColor)
                Text(server.title.isEmpty ? "Server \(index + 1)" : server.title)
                  .font(.body.weight(.semibold))
                  .foregroundStyle(.white)
                  .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
              }
              .padding(15)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.black.opacity(0.92))
  }

  private func pick(_ index: Int) {
    guard servers.indices.contains(index) else { return }
    if remember {
      let title = servers[index].title
      StreamSessionMemory.preferredServerTitle = title.isEmpty ? "Server \(index + 1)" : title
    }
    onSelect(index)
  }
}
