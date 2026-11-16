import SwiftUI
import Observation

// components/banner/Banner.svelte + FullBanner.svelte: hero carousel of the home page (trending titles
// with a banner or a trailer, shuffled, 10 at most), auto-advancing every 15 seconds, swipeable.

@MainActor
@Observable
final class BrowseBannerModel {
  private(set) var items: [Media] = []
  private(set) var isLoading = true
  private(set) var failed = false
  var index = 0
  @ObservationIgnored private var lastLoaded: Date? = nil
  @ObservationIgnored private var lastKey: String? = nil

  /// Settings that change the banner source (bannerProvider, adult, hentaiBanner).
  static var settingsKey: String {
    let values = AppSettings.shared.values
    return "\(values.bannerProvider)-\(values.adult)-\(values.hentaiBanner)"
  }

  var current: Media? {
    guard items.indices.contains(index) else { return items.first }
    return items[index]
  }

  /// getTitles + shuffleAndFilter. Without `force`, a banner loaded less than 5 minutes ago with the same
  /// settings is kept (the home tab reappearing does not reshuffle it).
  func load(force: Bool = false) async {
    let key = Self.settingsKey
    if !force, !items.isEmpty, key == lastKey, let lastLoaded, Date().timeIntervalSince(lastLoaded) < 290 { return }
    if items.isEmpty { isLoading = true }
    let all = await Services.shared.sections.banner()
    if Task.isCancelled { return }
    lastLoaded = Date()
    lastKey = key
    isLoading = false
    let picked = Self.shuffleAndFilter(all)
    if picked.isEmpty {
      failed = items.isEmpty
      return
    }
    failed = false
    items = picked
    index = 0
  }

  func advance() {
    guard !items.isEmpty else { return }
    index = (index + 1) % items.count
  }

  /// Keeps titles with a banner or a trailer (or a cover for the hentai banner), shuffles the first 20, keeps 10.
  static func shuffleAndFilter(_ media: [Media]) -> [Media] {
    let settings = AppSettings.shared.values
    let hentaiBanner = settings.adult == "hentai" && settings.hentaiBanner
    var seen = Set<String>()
    let eligible = media.filter { item in
      guard seen.insert(item.id).inserted else { return false }
      return item.images.banner != nil || item.trailerYouTubeId != nil || (hentaiBanner && item.images.coverLarge != nil)
    }
    let shuffled = Array(eligible.prefix(20)).shuffled() + Array(eligible.dropFirst(20))
    return Array(shuffled.prefix(10))
  }
}

@MainActor
struct BrowseHeroBanner: View {
  let model: BrowseBannerModel

  static let height: CGFloat = 540

  var body: some View {
    Group {
      if model.items.isEmpty {
        if model.isLoading {
          BrowseBannerSkeleton()
        } else {
          BrowseErrorCard(kind: model.failed ? .failed("") : .empty, height: nil, onRetry: {
            Task { await model.load(force: true) }
          })
        }
      } else {
        carousel
      }
    }
    .frame(height: Self.height)
    .frame(maxWidth: .infinity)
  }

  private var selection: Binding<Int> {
    Binding(get: { model.index }, set: { model.index = $0 })
  }

  private var carousel: some View {
    TabView(selection: selection) {
      ForEach(Array(model.items.enumerated()), id: \.element.id) { pair in
        BrowseBannerPage(media: pair.element)
          .tag(pair.offset)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .overlay(alignment: .bottomLeading) {
      BrowseBannerIndicators(count: model.items.count, index: model.index) { value in
        model.index = value
      }
      .padding(.leading, 16)
      .padding(.bottom, 10)
    }
    .task(id: model.index) {
      try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
      if Task.isCancelled { return }
      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.6)) {
          model.advance()
        }
      }
    }
  }
}

/// Progress badges under the banner (the active one fills in 15 seconds).
@MainActor
struct BrowseBannerIndicators: View {
  let count: Int
  let index: Int
  let onSelect: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<count, id: \.self) { position in
        Button {
          onSelect(position)
        } label: {
          BrowseBannerIndicator(active: position == index)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(position == index)
      }
    }
  }
}

struct BrowseBannerIndicator: View {
  let active: Bool
  /// Start of the 15 second fill. The fill is computed from a timeline instead of a 15 second
  /// `withAnimation` started in onAppear (that transaction also animated the layout of the page).
  @State private var start = Date()

  var body: some View {
    Capsule()
      .fill(Color.white.opacity(0.25))
      .frame(width: active ? 50 : 27, height: 3)
      .overlay(alignment: .leading) {
        if active {
          TimelineView(.periodic(from: start, by: 0.1)) { context in
            let progress = min(max(context.date.timeIntervalSince(start) / 15, 0), 1)
            Capsule()
              .fill(Color.white)
              .frame(width: CGFloat(50 * progress), height: 3)
          }
        }
      }
      .animation(.easeInOut(duration: 0.8), value: active)
      .onAppear { start = Date() }
      .onChange(of: active) { _, _ in start = Date() }
  }
}

/// One banner page (FullBanner.svelte content).
@MainActor
struct BrowseBannerPage: View {
  let media: Media

  var body: some View {
    let current = BrowseMediaInfo.current(media)
    let settings = AppSettings.shared.values
    // FullBanner rotated: no banner and no trailer, adult "hentai" with the hentai banner setting.
    let rotated = current.images.banner == nil && current.trailerYouTubeId == nil && settings.adult == "hentai" && settings.hentaiBanner
    ZStack(alignment: .bottomLeading) {
      if rotated {
        BrowseRotatedCover(urls: BrowseMediaInfo.coverURLs(current), placeholder: Color.black)
      } else {
        BrowseImage(BrowseMediaInfo.bannerURLs(current), placeholder: Color.black)
      }
      LinearGradient(
        stops: [
          .init(color: Color.black.opacity(0.15), location: 0),
          .init(color: Color.black.opacity(0.35), location: 0.4),
          .init(color: Color.black, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      BrowseBannerInfo(media: current)
        .padding(.horizontal, 16)
        .padding(.bottom, 36)
    }
    .clipped()
  }
}

/// Logo / title, details, description, genres and buttons of the banner.
@MainActor
struct BrowseBannerInfo: View {
  let media: Media

  var body: some View {
    // Spoiler protection (Core/SpoilerProtection.swift): synopsis.
    let hideSynopsis = SpoilerProtection.hidesMedia(.synopsis, entry: BrowseMediaInfo.entry(media))
    VStack(alignment: .leading, spacing: 10) {
      titleView
      Text(detailsLine)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .lineLimit(1)
      Text(SpoilerProtection.text(BrowseText.plain(media.description), hidden: hideSynopsis) ?? "")
        .font(.subheadline)
        .italic(hideSynopsis)
        .foregroundStyle(BrowsePalette.muted)
        .lineLimit(3)
      if !media.genres.isEmpty {
        Text(media.genres.joined(separator: "  \u{2022}  "))
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
      }
      BrowseBannerButtons(media: media)
    }
    .frame(maxWidth: 600, alignment: .leading)
  }

  @ViewBuilder
  private var titleView: some View {
    if let logo = media.images.logo {
      BrowseImage([logo], placeholder: Color.clear, contentMode: .fit, alignment: .bottomLeading)
        .frame(maxWidth: 280, alignment: .leading)
        .frame(height: 90)
        .shadow(color: Color.black.opacity(0.5), radius: 10)
        .accessibilityLabel(BrowseMediaInfo.title(media))
    } else {
      Text(BrowseMediaInfo.title(media))
        .font(.largeTitle.bold())
        .foregroundStyle(.white)
        .lineLimit(2)
        .shadow(color: Color.black, radius: 4, x: 2, y: 2)
    }
  }

  /// Format • Episodes • Rated 18+ • Season Year.
  private var detailsLine: String {
    var parts: [String] = []
    if media.format != .unknown { parts.append(BrowseMediaInfo.formatText(media)) }
    let showDuration = !SpoilerProtection.hidesMedia(.duration, entry: BrowseMediaInfo.entry(media))
    if let episodes = BrowseMediaInfo.bannerEpisodesText(media, entry: media.listEntry, showDuration: showDuration) { parts.append(episodes) }
    if ServiceSettingsExtras.cardAudio && media.source == .anilist {
      if Services.shared.dubs.isFullyDubbed(malId: media.malId) {
        parts.append("Dub | Sub")
      } else if Services.shared.dubs.isIncomplete(malId: media.malId) {
        parts.append("Partial Dub | Sub")
      } else {
        parts.append("Sub")
      }
    }
    if media.isAdult { parts.append("Rated 18+") }
    var season: [String] = []
    if let value = media.season { season.append(value.rawValue.capitalized) }
    if let year = media.seasonYear { season.append(String(year)) }
    if !season.isEmpty { parts.append(season.joined(separator: " ")) }
    return parts.joined(separator: "  \u{2022}  ")
  }
}

/// Watch Now / View Details / list editor / favourite.
@MainActor
struct BrowseBannerButtons: View {
  let media: Media

  var body: some View {
    // With the list editor and favourite buttons, the labelled row is wider than an iPhone (the labels were
    // truncated): View Details then falls back to an icon button.
    ViewThatFits(in: .horizontal) {
      row(compactDetails: false)
      row(compactDetails: true)
    }
    .buttonStyle(.plain)
  }

  private func row(compactDetails: Bool) -> some View {
    let entry = media.listEntry
    return HStack(spacing: 10) {
      Button {
        BrowseActions.playMedia(media)
      } label: {
        Label(BrowseMediaInfo.playButtonText(entry), systemImage: "play.fill")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .foregroundStyle(.white)
          .padding(.horizontal, 16)
          .frame(height: 44)
          .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      Button {
        BrowseActions.open(media)
      } label: {
        Group {
          if compactDetails {
            Image(systemName: "info.circle")
              .font(.system(size: 18, weight: .semibold))
              .frame(width: 44, height: 44)
          } else {
            Text("View Details")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .padding(.horizontal, 16)
              .frame(height: 44)
          }
        }
        .foregroundStyle(.white)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .accessibilityLabel("View Details")
      if BrowseMediaInfo.canEditList(media) {
        BrowseListEditorButton(media: media)
      }
      if BrowseMediaInfo.canFavourite(media) {
        BrowseFavouriteButton(media: media)
      }
    }
  }
}

/// Heart button (AniList favourite).
@MainActor
struct BrowseFavouriteButton: View {
  let media: Media
  var size: CGFloat = 44

  var body: some View {
    // Observable (BrowseFavouriteStore): every heart and menu entry of the media updates together.
    let value = BrowseActions.isFavourite(media)
    let label: String = value ? "Unfavourite" : "Favourite"
    Button {
      BrowseActions.toggleFavourite(media)
    } label: {
      Image(systemName: value ? "heart.fill" : "heart")
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(value ? BrowsePalette.tertiary : Color.white)
        .frame(width: size, height: size)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}
