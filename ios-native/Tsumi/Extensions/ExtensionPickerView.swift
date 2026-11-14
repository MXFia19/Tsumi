import SwiftUI

/// Results of every enabled extension for one episode (ExtensionModal.svelte + ExtensionResults.svelte):
/// banner header with the title and a close button, "Default extension failed" banner, groups per
/// extension (starred first, icon, "Starred" badge, result count, "+ N More" / "Show Less"), cards
/// with a "% match" badge; tapping a card resolves the stream (spinner on the card), several
/// servers open the server selector on top.
@MainActor
struct ExtensionPickerView: View {
  @Bindable var model: ExtensionPickerModel
  var onClose: () -> Void

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14, alignment: .top)]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        VStack(alignment: .leading, spacing: 20) {
          if model.defaultFailed {
            ExtensionNoticeBanner(
              systemImage: "exclamationmark.triangle.fill",
              tint: ExtensionPalette.warning,
              title: "Default extension failed",
              message: "\(model.failReason ?? "Unable to auto-play from your default extension.") Showing all results instead."
            )
          }
          if let error = model.errorMessage {
            ExtensionNoticeBanner(systemImage: "xmark.octagon.fill", tint: ExtensionPalette.danger, title: nil, message: error)
              .onTapGesture { model.errorMessage = nil }
          }
          content
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 30)
      }
    }
    .background(Color.black.opacity(0.95))
    .onAppear { model.start() }
    .sheet(item: $model.serverChoice) { choice in
      ServerPickerView(
        servers: choice.servers,
        onSelect: { index in model.chooseServer(choice, index: index) },
        onBack: { model.serverChoice = nil }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
  }

  // MARK: Header

  private var bannerURL: URL? {
    let media = model.media
    if let banner = media.images.banner { return banner }
    if let trailer = media.trailerYouTubeId, !trailer.isEmpty {
      return URL(string: "https://i.ytimg.com/vi/\(trailer)/maxresdefault.jpg")
    }
    return media.images.coverLarge ?? media.images.cover
  }

  private var header: some View {
    ZStack(alignment: .bottomLeading) {
      Color.white.opacity(0.05)
      if let url = bannerURL {
        AsyncImage(url: url) { phase in
          if case .success(let image) = phase {
            image.resizable().scaledToFill()
          } else {
            Color.clear
          }
        }
      }
      LinearGradient(colors: [Color.black.opacity(0.2), Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
      HStack(alignment: .bottom, spacing: 12) {
        Text(model.title)
          .font(.title.bold())
          .foregroundStyle(.white)
          .lineLimit(1)
          .truncationMode(.tail)
          .shadow(color: .black, radius: 4, x: 2, y: 2)
        Spacer(minLength: 0)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.headline.weight(.heavy))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 14)
    }
    .frame(height: 150)
    .frame(maxWidth: .infinity)
    .clipped()
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if model.loading {
      VStack(spacing: 20) {
        ProgressView()
          .controlSize(.large)
          .tint(ExtensionPalette.muted)
        Text("Searching extensions...")
          .font(.title3)
          .foregroundStyle(ExtensionPalette.muted)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 60)
    } else if model.groups.isEmpty {
      VStack(spacing: 8) {
        Text("Ooops!")
          .font(.title.bold())
          .foregroundStyle(.white)
        Text(model.hasEnabledExtensions
             ? "No results found from any extension."
             : "No extensions enabled. Add extensions in Settings → Extensions.")
          .font(.title3)
          .foregroundStyle(ExtensionPalette.muted)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 60)
    } else {
      ForEach(model.groups) { group in
        groupSection(group)
      }
    }
  }

  private func groupSection(_ group: ExtensionResultGroup) -> some View {
    let expanded = model.isExpanded(group.extensionKey)
    let visible = (expanded || group.results.count <= 5) ? group.results : Array(group.results.prefix(5))
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if group.extensionIcon != nil {
          ExtensionIconView(url: group.extensionIcon, size: 22, circle: true)
        }
        Text(group.extensionName)
          .font(.headline)
          .foregroundStyle(.white)
          .lineLimit(1)
        if group.isStarred {
          ExtensionBadge(text: "Starred", color: ExtensionPalette.warning, foreground: .black)
        }
        Text("\(group.results.count) result\(group.results.count == 1 ? "" : "s")")
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
      }
      LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
        ForEach(visible) { result in
          resultCard(result)
        }
      }
      if group.results.count > 5 {
        Button {
          withAnimation { model.toggleGroup(group.extensionKey) }
        } label: {
          Text(expanded ? "Show Less" : "+ \(group.results.count - 5) More")
            .font(.subheadline)
            .foregroundStyle(ExtensionPalette.muted)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func resultCard(_ result: ExtensionSearchResult) -> some View {
    let isPlaying = model.playingResultID == result.id
    let busy = model.playingResultID != nil
    return Button {
      model.select(result)
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        ExtensionPosterImage(url: result.imageURL)
          .overlay {
            if isPlaying {
              ZStack {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.large).tint(.white)
              }
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
        Text(result.title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        ExtensionBadge(text: "\(result.score)% match", color: scoreColor(result.score), foreground: result.score >= 50 ? .black : .white)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(busy)
    .opacity(busy && !isPlaying ? 0.6 : 1)
  }

  private func scoreColor(_ score: Int) -> Color {
    if score >= 80 { return ExtensionPalette.success }
    if score >= 50 { return ExtensionPalette.warning }
    return Color.white.opacity(0.2)
  }
}
