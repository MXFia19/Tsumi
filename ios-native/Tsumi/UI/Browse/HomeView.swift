import SwiftUI
import Observation

// routes/home/HomePage.svelte: hero banner, then every section of settings.homeSections in order,
// reloaded when HomeSectionsService.revision changes (lists, settings) and on pull to refresh; an episode
// feed row also reloads when its own feed changed (feedRevision), the other rows do not.

@MainActor
@Observable
final class BrowseHomeModel {
  let banner = BrowseBannerModel()
  /// Incremented by pull to refresh: every row reloads its first page.
  private(set) var refreshToken = 0
  @ObservationIgnored private var rows: [String: BrowseSectionRowModel] = [:]

  /// Row state survives scrolling (LazyVStack) and section rebuilds with the same title.
  func row(for section: HomeSection) -> BrowseSectionRowModel {
    if let existing = rows[section.title] {
      existing.section = section
      return existing
    }
    let created = BrowseSectionRowModel(section: section)
    rows[section.title] = created
    return created
  }

  func refresh() async {
    refreshToken += 1
    await banner.load(force: true)
  }
}

@MainActor
struct HomeView: View {
  @State private var model = BrowseHomeModel()

  var body: some View {
    let service = Services.shared.sections
    let reloadKey = "\(service.revision)-\(model.refreshToken)"
    ScrollView {
      // Plain stack of the rows (each row scrolls horizontally in its own lazy stack): an outer lazy stack of
      // heterogeneous sections mis-estimated the content height.
      VStack(alignment: .leading, spacing: 26) {
        BrowseHeroBanner(model: model.banner)
        ForEach(service.sections) { section in
          BrowseHomeSectionRow(row: model.row(for: section), reloadKey: reloadKey + "-\(service.feedRevision(forSection: section.title))")
        }
        if service.sections.isEmpty {
          BrowseErrorCard(kind: .empty)
        }
        Color.clear.frame(height: 20)
      }
    }
    .background(BrowsePalette.background)
    .scrollIndicators(.hidden)
    .refreshable {
      await model.refresh()
    }
    .navigationTitle("Home")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: BrowseBannerModel.settingsKey) {
      await model.banner.load()
      // getTitles(true) every 5 minutes.
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
        if Task.isCancelled { break }
        await model.banner.load(force: true)
      }
    }
  }
}

// MARK: - Sections (HomeSection.svelte)

@MainActor
@Observable
final class BrowseSectionRowModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  static let pageSize = 50

  let title: String
  let kind: HomeSectionKind
  @ObservationIgnored var section: HomeSection
  private(set) var media: [Media] = []
  private(set) var episodes: [BrowseEpisodeCardData] = []
  private(set) var phase: Phase = .idle
  private(set) var hasNextPage = false
  private(set) var isLoadingMore = false
  private(set) var page = 0
  @ObservationIgnored private var loadedKey: String? = nil
  @ObservationIgnored private var generation = 0

  init(section: HomeSection) {
    title = section.title
    kind = section.kind
    self.section = section
  }

  var isEmpty: Bool { media.isEmpty && episodes.isEmpty }

  /// Loads the first page (deferredLoad on appear, refreshSections when the key changes). The current
  /// cards stay visible while reloading and are kept when the first page did not change.
  func load(key: String) async {
    if loadedKey == key { return }
    generation += 1
    let current = generation
    if isEmpty { phase = .loading }
    do {
      let result = try await section.load(page: 1, perPage: Self.pageSize)
      if Task.isCancelled || current != generation { return }
      loadedKey = key
      applyFirstPage(result)
    } catch {
      if Task.isCancelled || current != generation { return }
      loadedKey = key
      phase = isEmpty ? .failed(error.localizedDescription) : .loaded
    }
  }

  func retry() {
    loadedKey = nil
    phase = .loading
    let key = "retry-\(generation)"
    Task { await load(key: key) }
  }

  /// Next page when the end of the row is reached.
  func loadMore() async {
    guard hasNextPage, !isLoadingMore, phase == .loaded else { return }
    isLoadingMore = true
    let current = generation
    do {
      let result = try await section.load(page: page + 1, perPage: Self.pageSize)
      isLoadingMore = false
      guard current == generation else { return }
      page += 1
      let added = append(result)
      hasNextPage = result.hasNextPage && added > 0
    } catch {
      isLoadingMore = false
      guard current == generation else { return }
      hasNextPage = false
    }
  }

  private func applyFirstPage(_ result: HomeSectionPage) {
    let newMedia = Self.unique(result.media)
    let newEpisodes = Self.unique(result.episodes.map { BrowseEpisodeCardData(feed: $0) })
    let sameMedia = !media.isEmpty && Array(media.prefix(newMedia.count)).map { $0.id } == newMedia.map { $0.id }
    let sameEpisodes = !episodes.isEmpty && Array(episodes.prefix(newEpisodes.count)).map { $0.id } == newEpisodes.map { $0.id }
    let unchanged = kind == .episodes ? sameEpisodes : sameMedia
    if !unchanged {
      media = newMedia
      episodes = newEpisodes
      page = 1
      hasNextPage = result.hasNextPage
    }
    phase = .loaded
  }

  private func append(_ result: HomeSectionPage) -> Int {
    var added = 0
    var mediaIds = Set(media.map { $0.id })
    for item in result.media where !mediaIds.contains(item.id) {
      media.append(item)
      mediaIds.insert(item.id)
      added += 1
    }
    var episodeIds = Set(episodes.map { $0.id })
    for item in result.episodes {
      let data = BrowseEpisodeCardData(feed: item)
      if episodeIds.contains(data.id) { continue }
      episodes.append(data)
      episodeIds.insert(data.id)
      added += 1
    }
    return added
  }

  static func unique(_ items: [Media]) -> [Media] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
  }

  static func unique(_ items: [BrowseEpisodeCardData]) -> [BrowseEpisodeCardData] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
  }
}

/// One home row: title (opens the full list in Search), then a horizontal gallery that loads more pages.
@MainActor
struct BrowseHomeSectionRow: View {
  let row: BrowseSectionRowModel
  let reloadKey: String
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  private var style: BrowseCardStyle {
    cardMode == BrowseCardMode.full.rawValue ? .full : .small
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      content
    }
    .task(id: reloadKey) {
      await row.load(key: reloadKey)
    }
  }

  private var header: some View {
    Button {
      AppRouter.shared.showAll(sectionTitle: row.title)
    } label: {
      HStack(spacing: 6) {
        Text(row.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(BrowsePalette.dimmed)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 16)
  }

  @ViewBuilder
  private var content: some View {
    if row.isEmpty {
      switch row.phase {
      case .idle, .loading:
        skeletons
      case .failed(let message):
        BrowseErrorCard(kind: .failed(message), height: 200, onRetry: { row.retry() })
      case .loaded:
        BrowseErrorCard(kind: .empty, height: 160)
      }
    } else {
      gallery
    }
  }

  private var skeletons: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 14) {
        ForEach(0..<6, id: \.self) { _ in
          skeleton
        }
      }
      .padding(.horizontal, 16)
    }
    .disabled(true)
  }

  @ViewBuilder
  private var skeleton: some View {
    if row.kind == .episodes {
      BrowseEpisodeCardSkeleton(width: 290)
    } else if style == .full {
      BrowseFullCardSkeleton(width: 330)
    } else {
      BrowseSmallCardSkeleton(width: 128)
    }
  }

  private var gallery: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: 14) {
        cards
        if row.hasNextPage {
          ProgressView()
            .tint(.white)
            .frame(width: 60, height: 160)
            .id(row.page)
            .onAppear {
              Task { await row.loadMore() }
            }
        }
      }
      .padding(.horizontal, 16)
    }
  }

  @ViewBuilder
  private var cards: some View {
    if row.kind == .episodes {
      ForEach(row.episodes) { item in
        BrowseEpisodeCard(data: item, width: 290)
      }
    } else {
      ForEach(row.media) { media in
        BrowseMediaCard(media: media, style: style, width: style == .full ? 330 : 128)
      }
    }
  }
}
