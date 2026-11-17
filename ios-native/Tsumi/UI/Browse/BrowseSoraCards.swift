import SwiftUI

// Cards of a Sora module source on the Search page (SmallCard.svelte / FullCard.svelte with `isSora`): the module's
// image and title, and the module name in place of the year / format line. A module result has no AniList / TMDB data,
// so there is no preview or context menu: a tap looks for the matching title first (BrowseSearchModel.openSoraResult),
// or opens the module page (SoraResultView) when the module's "Link results to AniList / TMDB" is off.

/// One module result (small or large card, like the other results).
@MainActor
struct BrowseSoraResultCard: View {
  let result: SoraSearchResult
  var style: BrowseCardStyle = .small
  /// The matching AniList / TMDB title is being looked up: spinner over the cover.
  var isMatching = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      switch style {
      case .small: small
      case .full: full
      }
    }
    .buttonStyle(BrowsePressableStyle())
    .accessibilityLabel("\(result.title), \(result.extensionName)")
    .accessibilityHint(Text(hint))
  }

  private var hint: String {
    if isMatching { return "Looking for this title on AniList and TMDB" }
    return ExtensionManager.shared.linksResults(result.extensionKey) ? "Opens the matching AniList or TMDB title" : "Opens the module page"
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 6) {
      cover
        .aspectRatio(BrowseSmallCard.coverRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      Text(result.title)
        .font(.subheadline.weight(.heavy))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      moduleLine
    }
    .contentShape(Rectangle())
  }

  private var full: some View {
    HStack(spacing: 0) {
      cover
        .frame(width: BrowseFullCard.height * 0.66, height: BrowseFullCard.height)
        .clipped()
      VStack(alignment: .leading, spacing: 6) {
        Text(result.title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
        moduleLine
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: BrowseFullCard.height)
    .frame(maxWidth: .infinity)
    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
  }

  private var cover: some View {
    // Module-supplied address: extension image rules (size cap, no local address, downsampled).
    ExtensionCoverImage(url: result.imageURL, placeholder: BrowsePalette.skeleton, allowsLocalNetwork: ExtensionImageLoader.allowsLocalNetwork(extensionKey: result.extensionKey))
      .overlay {
        if isMatching {
          ZStack {
            Color.black.opacity(0.55)
            ProgressView()
              .tint(.white)
          }
        }
      }
  }

  /// The module name in place of the year / format line.
  private var moduleLine: some View {
    HStack(spacing: 4) {
      Image(systemName: "puzzlepiece.extension")
      Text(result.extensionName)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(BrowsePalette.muted)
  }
}

/// Placeholder of a module source without a title: "Type a title to search <module>".
struct BrowseSoraHint: View {
  let moduleName: String
  var height: CGFloat? = 220

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(BrowsePalette.muted)
      Text("Type a title to search \(moduleName)")
        .font(.subheadline)
        .foregroundStyle(BrowsePalette.muted)
        .multilineTextAlignment(.center)
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .frame(height: height)
  }
}
