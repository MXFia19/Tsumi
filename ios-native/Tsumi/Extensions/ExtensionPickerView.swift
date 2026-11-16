import SwiftUI
import UIKit

/// Results of every enabled extension for one episode (ExtensionModal.svelte + ExtensionResults.svelte):
/// banner header with the title and a close button, "Default extension failed" banner, groups per
/// extension (starred first, icon, "Starred" badge, result count, one row of cards when collapsed with
/// "+ N More" / "Show Less"), cards with a "% match" badge; tapping a card resolves the stream (spinner
/// on the card), several servers open the server selector on top. Errors show as a banner in the sheet
/// and are also posted as toasts (toast.error in the Svelte app).
@MainActor
struct ExtensionPickerView: View {
  @Bindable var model: ExtensionPickerModel
  var onClose: () -> Void

  /// First image of the SmartImage fallback chain that loaded.
  @State private var headerImage: UIImage?
  /// Width of the result grids, to know how many cards fit on one row.
  @State private var gridWidth: CGFloat = 0

  private static let cardMinimumWidth: CGFloat = 104
  private static let cardSpacing: CGFloat = 14
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
    .onChange(of: model.errorMessage) { _, message in
      // selectResult toast.error(...) ("No episodes found for this title", "Stream failed: ...").
      // The banner stays in the sheet, which covers the app toaster.
      if let message, !message.isEmpty {
        Services.shared.messages.post(.error, message)
      }
    }
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

  private var header: some View {
    Color.white.opacity(0.05)
      .frame(height: 150)
      .frame(maxWidth: .infinity)
      .overlay {
        if let headerImage {
          Image(uiImage: headerImage)
            .resizable()
            .scaledToFill()
            .allowsHitTesting(false)
        }
      }
      .clipped()
      .overlay {
        LinearGradient(colors: [Color.black.opacity(0.2), Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
          .allowsHitTesting(false)
      }
      .overlay(alignment: .bottomLeading) {
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
      .task(id: ObjectIdentifier(model)) {
        await loadHeaderImage()
      }
  }

  /// SmartImage list of ExtensionResults.svelte, tried in order until one loads (a 404 or a file that
  /// is not an image moves on): banner, trailer thumbnails (maxresdefault, which YouTube answers with
  /// 404 when the video has no HD frame, then hqdefault), Kitsu cover (original → tiny), thumbnail of
  /// episode 1 (ani.zip / Kitsu metadata), cover. The Kitsu and episode lookups only run when
  /// everything before them failed, like the lazy entries of the Svelte list.
  private func loadHeaderImage() async {
    // Never the image of a previous request.
    headerImage = nil
    let media = model.media
    if let image = await Self.firstImage(Self.headerURLs(media)) {
      headerImage = image
      return
    }
    if let anilistId = media.anilistId {
      if Task.isCancelled { return }
      if let image = await Self.firstImage(await Self.kitsuCoverURLs(anilistId: anilistId)) {
        headerImage = image
        return
      }
      if Task.isCancelled { return }
      let metadata = await AnimeMappingsService.shared.episodeMetadata(for: media)
      if let url = URL.lenient(metadata["1"]?.image), let image = await Self.firstImage([url]) {
        headerImage = image
        return
      }
    }
    if Task.isCancelled { return }
    if let image = await Self.firstImage([media.images.coverLarge, media.images.cover].compactMap { $0 }) {
      headerImage = image
    }
  }

  /// Banner, then the YouTube trailer thumbnails.
  private static func headerURLs(_ media: Media) -> [URL] {
    var urls: [URL] = []
    if let banner = media.images.banner { urls.append(banner) }
    if let trailer = media.trailerYouTubeId, !trailer.isEmpty {
      for name in ["maxresdefault", "hqdefault"] {
        if let url = URL(string: "https://i.ytimg.com/vi/\(trailer)/\(name).jpg") { urls.append(url) }
      }
    }
    return urls
  }

  /// getKitsuMappings(id).included[0].attributes.coverImage: original, large, small, tiny.
  private static func kitsuCoverURLs(anilistId: Int) async -> [URL] {
    guard let url = URL(string: "https://kitsu.app/api/edge/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D=\(anilistId)&include=item"),
          let json = try? await HTTP.jsonObject(from: url) as? [String: Any] else { return [] }
    let cover = json.array("included").first?.dict("attributes")?.dict("coverImage")
    return ["original", "large", "small", "tiny"].compactMap { URL.lenient(cover?.string($0)) }
  }

  /// First URL of the list that downloads and decodes (shared browse image cache).
  private static func firstImage(_ urls: [URL]) async -> UIImage? {
    for url in urls {
      if Task.isCancelled { return nil }
      if let image = await BrowseImageCache.shared.load(url) { return image }
    }
    return nil
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if model.loading && model.groups.isEmpty {
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
      searchStatus
    }
  }

  /// Under the results already shown: the extensions still searching, then the ones that failed.
  @ViewBuilder
  private var searchStatus: some View {
    if model.loading && !model.pendingNames.isEmpty {
      HStack(spacing: 10) {
        ProgressView()
          .tint(ExtensionPalette.muted)
        Text("Still searching: \(model.pendingNames.joined(separator: ", "))")
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
          .lineLimit(2)
      }
    }
    if !model.failedNames.isEmpty {
      Text("Couldn't search with \(model.failedNames.joined(separator: ", ")) (error or no answer in time).")
        .font(.footnote)
        .foregroundStyle(ExtensionPalette.dimmed)
        .lineLimit(2)
    }
  }

  /// Cards on one grid row at the measured width (same rule as the adaptive GridItem: as many minimum
  /// widths as fit, spacing included). 5 until the width is known.
  private var cardsPerRow: Int {
    guard gridWidth > 0 else { return 5 }
    return max(1, Int((gridWidth + Self.cardSpacing) / (Self.cardMinimumWidth + Self.cardSpacing)))
  }

  private var gridWidthReader: some View {
    GeometryReader { proxy in
      Color.clear
        .onAppear { gridWidth = proxy.size.width }
        .onChange(of: proxy.size.width) { _, width in gridWidth = width }
    }
  }

  /// A collapsed group shows one row of cards (`.results-grid-collapsed { max-height: 32rem }`); the
  /// toggle appears whenever that row hides cards and counts the hidden ones.
  private func groupSection(_ group: ExtensionResultGroup) -> some View {
    let expanded = model.isExpanded(group.extensionKey)
    let perRow = cardsPerRow
    let collapsible = group.results.count > perRow
    let visible = (expanded || !collapsible) ? group.results : Array(group.results.prefix(perRow))
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
      .background(gridWidthReader)
      if collapsible {
        Button {
          withAnimation { model.toggleGroup(group.extensionKey) }
        } label: {
          Text(expanded ? "Show Less" : "+ \(group.results.count - perRow) More")
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
