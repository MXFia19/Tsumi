import SwiftUI
import UIKit
import PhotosUI
import Observation

// routes/search/SearchPage.svelte + SearchBar.svelte: debounced search with every filter, results grid
// with infinite scroll, home section "see all" (the section loader with editable filters), preset queries
// from AppRouter.search, image search (trace.moe) and the persisted last search.

@MainActor
@Observable
final class BrowseSearchModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  struct RunKey: Equatable {
    var filters: BrowseSearchFilters
    var sectionTitle: String?
    var generation: Int
  }

  static let storageKey = "tsumi.browse.lastSearched"
  static let pageSize = 50

  var filters: BrowseSearchFilters
  /// "See all" section (search.load of HomeSection.svelte).
  private(set) var sectionTitle: String? = nil
  /// The section title badge disappears when its genres / tags are edited (the loader stays).
  private(set) var showsSectionBadge = true
  @ObservationIgnored private(set) var section: HomeSection? = nil
  private(set) var context = BrowseFilterContext()
  private(set) var media: [Media] = []
  private(set) var episodes: [BrowseEpisodeCardData] = []
  private(set) var phase: Phase = .idle
  private(set) var hasNextPage = false
  private(set) var isLoadingMore = false
  private(set) var page = 0
  /// Image search results (trace.moe) replace the normal results until a filter changes.
  private(set) var isTraceMode = false
  private(set) var isTracing = false
  private var generation = 0
  @ObservationIgnored private var lastRunKey: RunKey? = nil
  @ObservationIgnored private var token = 0

  init() {
    filters = BrowseSearchFilters.load(key: Self.storageKey, fallback: BrowseSearchFilters())
  }

  var runKey: RunKey {
    RunKey(filters: filters, sectionTitle: sectionTitle, generation: generation)
  }

  /// The section title badge is only shown for user-list sections (SearchBar.svelte filteredBadges:
  /// `search.userList || badge.key !== 'title'`); Reset Filters still leaves any section.
  var badges: [BrowseFilterBadge] {
    BrowseFilterBadge.badges(filters, sectionTitle: (showsSectionBadge && context.userList) ? sectionTitle : nil)
  }

  var hasActiveFilters: Bool {
    !badges.isEmpty || sectionTitle != nil || isTraceMode
  }

  var isEmpty: Bool { media.isEmpty && episodes.isEmpty }

  // MARK: Navigation input

  /// AppRouter.showAll(sectionTitle:): the section's loader with its variables as filters.
  func openSection(title: String) {
    let service = HomeSectionsService.shared
    guard let found = service.sections.first(where: { $0.title == title }) ?? service.section(titled: title) else { return }
    section = found
    sectionTitle = found.title
    showsSectionBadge = true
    context = BrowseFilterContext.section(found)
    filters = BrowseSearchFilters(section: found.variables)
    isTraceMode = false
    generation += 1
  }

  /// AppRouter.search(_:): preset query.
  func apply(query: MediaQuery) {
    leaveSection()
    filters = BrowseSearchFilters(query: query)
    isTraceMode = false
    generation += 1
  }

  func leaveSection() {
    section = nil
    sectionTitle = nil
    showsSectionBadge = true
    context = BrowseFilterContext()
  }

  /// searchClear (Reset Filters).
  func reset() {
    leaveSection()
    filters = BrowseSearchFilters()
    isTraceMode = false
    generation += 1
  }

  func remove(_ badge: BrowseFilterBadge) {
    if badge.key == "title" {
      leaveSection()
      if UserListSorts.isUserSort(filters.sort) { filters.sort = "" }
      return
    }
    if (badge.key.hasPrefix("genre") || badge.key.hasPrefix("tag")) && !context.userList {
      showsSectionBadge = false
    }
    BrowseFilterBadge.remove(badge, from: &filters)
  }

  func toggleHideMyAnime() {
    filters.hideMyAnime.toggle()
    if filters.hideMyAnime { filters.showMyAnime = false }
  }

  func toggleShowMyAnime() {
    filters.showMyAnime.toggle()
    if filters.showMyAnime { filters.hideMyAnime = false }
  }

  // MARK: Loading

  /// Debounced run (500 ms like the Svelte input debounce). The task re-fires when the view reappears:
  /// an unchanged key keeps the results.
  func runIfNeeded() async {
    let key = runKey
    if key == lastRunKey { return }
    if lastRunKey != nil {
      try? await Task.sleep(nanoseconds: 500_000_000)
      if Task.isCancelled { return }
    }
    await run(key)
  }

  func retry() {
    lastRunKey = nil
    generation += 1
  }

  private func run(_ key: RunKey) async {
    lastRunKey = key
    token += 1
    let current = token
    isTraceMode = false
    phase = .loading
    media = []
    episodes = []
    page = 0
    hasNextPage = false
    if section == nil { filters.save(key: Self.storageKey) }
    do {
      let result = try await fetch(page: 1)
      guard current == token else { return }
      if Task.isCancelled {
        lastRunKey = nil
        return
      }
      media = BrowseSectionRowModel.unique(result.media)
      episodes = BrowseSectionRowModel.unique(result.episodes.map { BrowseEpisodeCardData(feed: $0) })
      page = 1
      hasNextPage = result.hasNextPage
      phase = .loaded
    } catch {
      guard current == token else { return }
      if Task.isCancelled {
        lastRunKey = nil
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }

  func loadMore() async {
    guard hasNextPage, !isLoadingMore, phase == .loaded, !isTraceMode else { return }
    isLoadingMore = true
    let current = token
    do {
      let result = try await fetch(page: page + 1)
      isLoadingMore = false
      guard current == token else { return }
      page += 1
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
      hasNextPage = result.hasNextPage && added > 0
    } catch {
      isLoadingMore = false
      guard current == token else { return }
      hasNextPage = false
    }
  }

  private func fetch(page: Int) async throws -> HomeSectionPage {
    if let section {
      let variables = filters.sectionQuery(base: section.variables, isSection: true)
      return try await section.load(page: page, perPage: Self.pageSize, variables: variables)
    }
    let query = filters.sectionQuery(base: SectionQuery(), isSection: false)
    let result = try await HomeSectionsService.searchMedia(query, page: page, perPage: Self.pageSize)
    return HomeSectionPage(media: result.items, episodes: [], hasNextPage: result.hasNextPage)
  }

  /// SearchPage.svelte onDestroy: leaving the page clears a feed section search (disableSearch), so the
  /// Search tab does not reopen stuck on it. It goes back to the last plain search (a feed is never saved as
  /// lastSearched): resetting to empty filters saved those over it.
  func leavePage() {
    guard section != nil, context.disableSearch else { return }
    leaveSection()
    filters = BrowseSearchFilters.load(key: Self.storageKey, fallback: BrowseSearchFilters())
    isTraceMode = false
    generation += 1
  }

  // MARK: Image search (traceAnime)

  func trace(imageData: Data) async {
    await trace { try await AnimeHelpers.traceAnime(imageData: imageData) }
  }

  /// traceAnime with an image URL (pasted link).
  func trace(imageURL: URL) async {
    await trace { try await AnimeHelpers.traceAnime(imageURL: imageURL) }
  }

  /// Paste of an image or an image URL (clipboard.js): image data first, then a URL or a link in the text.
  func traceFromPasteboard() async {
    let pasteboard = UIPasteboard.general
    if let image = pasteboard.image, let data = image.jpegData(compressionQuality: 0.9) {
      await trace(imageData: data)
      return
    }
    if let url = pasteboard.url, url.scheme?.lowercased().hasPrefix("http") == true {
      await trace(imageURL: url)
      return
    }
    if let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true {
      await trace(imageURL: url)
      return
    }
    ServiceMessages.shared.post(.error, "Search Failed", "The clipboard has no image or image URL.")
  }

  private func trace(_ lookup: () async throws -> [TraceMoeMatch]) async {
    isTracing = true
    ServiceMessages.shared.post(.info, "Looking up anime for image...", "You can also paste an image or an image URL: long press the image button.")
    do {
      let matches = try await lookup()
      isTracing = false
      guard !matches.isEmpty else { throw ServiceError.invalidResponse }
      token += 1
      isTraceMode = true
      leaveSection()
      media = []
      episodes = matches.sorted { $0.similarity > $1.similarity }.map { BrowseEpisodeCardData(trace: $0) }
      hasNextPage = false
      phase = .loaded
      // The key changed (section left): keep the image results instead of running the search again.
      lastRunKey = runKey
      ServiceMessages.shared.post(.success, "Found anime for image!")
    } catch {
      isTracing = false
      ServiceMessages.shared.post(.error, "Search Failed", "Couldn't find anime for specified image! Try to remove black bars, or use a more detailed image.")
    }
  }

}

@MainActor
struct SearchView: View {
  @State private var model = BrowseSearchModel()
  @State private var showFilters = false
  @State private var photoItem: PhotosPickerItem? = nil
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  private var style: BrowseCardStyle {
    cardMode == BrowseCardMode.full.rawValue ? .full : .small
  }

  var body: some View {
    let router = AppRouter.shared
    ScrollView {
      // Plain stack: the results grid is the only lazy container (no lazy stack around a lazy grid).
      VStack(alignment: .leading, spacing: 14) {
        BrowseSearchHeader(model: model, showFilters: $showFilters, photoItem: $photoItem, cardMode: $cardMode)
        BrowseSearchResults(model: model, style: style)
      }
      .padding(.bottom, 24)
    }
    .onDisappear {
      // Only a real tab change leaves a feed: the page also disappears under the full screen player and
      // under a screen pushed on the Search stack, and the feed must still be there when they close.
      if AppRouter.shared.selectedTab != .search {
        model.leavePage()
      }
    }
    .onChange(of: router.selectedTab) { _, tab in
      // Tab changed while a screen was pushed over the page (no disappearance of the page itself then).
      if tab != .search {
        model.leavePage()
      }
    }
    .background(BrowsePalette.background)
    .scrollDismissesKeyboard(.immediately)
    .navigationTitle("Search")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showFilters) {
      BrowseFilterSheet(filters: $model.filters, context: model.context, onReset: { model.reset() })
    }
    .task(id: model.runKey) {
      await model.runIfNeeded()
    }
    .task(id: router.pendingSearch?.id) {
      await MainActor.run {
        consumePendingSearch()
      }
    }
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      Task { @MainActor in
        if let data = try? await item.loadTransferable(type: Data.self) {
          await model.trace(imageData: data)
        } else {
          ServiceMessages.shared.post(.error, "Search Failed", "Couldn't read the selected image.")
        }
        photoItem = nil
      }
    }
  }

  private func consumePendingSearch() {
    let router = AppRouter.shared
    guard let pending = router.pendingSearch else { return }
    router.pendingSearch = nil
    if let title = pending.sectionTitle {
      model.openSection(title: title)
    } else if let query = pending.query {
      model.apply(query: query)
    }
  }
}

/// Search bar, buttons and badges (SearchBar.svelte).
@MainActor
struct BrowseSearchHeader: View {
  @Bindable var model: BrowseSearchModel
  @Binding var showFilters: Bool
  @Binding var photoItem: PhotosPickerItem?
  @Binding var cardMode: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        BrowseSourceMenu(western: $model.filters.western, disabled: model.context.lockSource || model.context.disableSearch)
        BrowseSearchField(text: $model.filters.text, disabled: model.context.disableSearch)
      }
      buttons
      BrowseFilterBadgesView(badges: model.badges) { badge in
        model.remove(badge)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  private var buttons: some View {
    let context = model.context
    let authorized = ProfilesService.shared.isAuthorized
    return HStack(spacing: 8) {
      BrowseIconButton(systemImage: "slider.horizontal.3", active: model.filters.activeCount > 0, badge: model.filters.activeCount, label: "Advanced Search") {
        showFilters = true
      }
      .disabled(context.disableSearch)
      BrowseIconButton(systemImage: model.filters.showMyAnime ? "hourglass" : "eye.slash", active: model.filters.hideMyAnime || model.filters.showMyAnime, tint: model.filters.showMyAnime ? BrowsePalette.partialDub : BrowsePalette.tertiary, label: model.filters.showMyAnime ? "Show My Anime" : "Hide My Anime") {
        model.toggleHideMyAnime()
      }
      .contextMenu {
        Button {
          model.toggleShowMyAnime()
        } label: {
          Label("Show My Anime", systemImage: "hourglass")
        }
      }
      .disabled(context.disableHide || context.disableSearch || !authorized)
      BrowseIconButton(systemImage: "mic", active: model.filters.dubOnly, label: "Dubbed Audio") {
        model.filters.dubOnly.toggle()
      }
      .disabled(context.disableSearch)
      PhotosPicker(selection: $photoItem, matching: .images) {
        BrowseIconLabel(systemImage: model.isTracing ? "hourglass" : "photo.badge.arrow.down", active: model.isTraceMode)
      }
      .accessibilityLabel("Image Search")
      .contextMenu {
        // Paste of an image or an image URL (clipboard.js paste handler).
        Button {
          Task { await model.traceFromPasteboard() }
        } label: {
          Label("Paste Image or URL", systemImage: "doc.on.clipboard")
        }
      }
      .accessibilityAction(named: "Paste Image or URL") {
        Task { await model.traceFromPasteboard() }
      }
      .disabled(model.isTracing)
      BrowseIconButton(systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", active: model.hasActiveFilters, tint: BrowsePalette.danger, label: "Reset Filters") {
        model.reset()
      }
      .disabled(!model.hasActiveFilters)
      Spacer(minLength: 0)
      if !context.disableSearch && model.sectionTitle == nil && !model.isTraceMode {
        cardModeButtons
      }
    }
  }

  private var cardModeButtons: some View {
    BrowseCardModeButtons(cardMode: $cardMode)
  }
}

/// Small / Large cards buttons (SearchBar.svelte), shared by the Search and Schedule headers.
@MainActor
struct BrowseCardModeButtons: View {
  @Binding var cardMode: String

  var body: some View {
    HStack(spacing: 4) {
      BrowseIconButton(systemImage: "square.grid.3x3", active: cardMode == BrowseCardMode.small.rawValue, label: "Small Cards") {
        cardMode = BrowseCardMode.small.rawValue
      }
      BrowseIconButton(systemImage: "square.grid.2x2", active: cardMode == BrowseCardMode.full.rawValue, label: "Large Cards") {
        cardMode = BrowseCardMode.full.rawValue
      }
    }
  }
}

/// Source select: Both / Anime / Western.
@MainActor
struct BrowseSourceMenu: View {
  @Binding var western: Bool?
  var disabled = false

  private var title: String {
    switch western {
    case .none: return "Both"
    case .some(false): return "Anime"
    case .some(true): return "Western"
    }
  }

  var body: some View {
    Menu {
      Button("Both") { western = nil }
      Button("Anime") { western = false }
      Button("Western") { western = true }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "square.grid.2x2")
        Text(title)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .frame(height: 40)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .disabled(disabled)
    .accessibilityLabel("Source")
  }
}

/// Title input with clear button.
@MainActor
struct BrowseSearchField: View {
  @Binding var text: String
  var disabled = false

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(BrowsePalette.dimmed)
      TextField("Any", text: $text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .submitLabel(.search)
        .foregroundStyle(.white)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(BrowsePalette.dimmed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
    .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .disabled(disabled)
    .opacity(disabled ? 0.5 : 1)
  }
}

/// Square icon button of the search bar.
@MainActor
struct BrowseIconButton: View {
  let systemImage: String
  var active = false
  var badge = 0
  var tint: Color = BrowsePalette.tertiary
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      BrowseIconLabel(systemImage: systemImage, active: active, badge: badge, tint: tint)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

struct BrowseIconLabel: View {
  let systemImage: String
  var active = false
  var badge = 0
  var tint: Color = BrowsePalette.tertiary
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(active ? tint : Color.white)
      .frame(width: 40, height: 40)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(alignment: .topTrailing) {
        if badge > 0 {
          Text(String(badge))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(tint, in: Capsule())
            .offset(x: 4, y: -4)
        }
      }
      .opacity(isEnabled ? 1 : 0.4)
  }
}

/// Results grid with infinite scroll (SearchPage.svelte loadTillFull / infiniteScroll).
@MainActor
struct BrowseSearchResults: View {
  let model: BrowseSearchModel
  let style: BrowseCardStyle

  private var columns: [GridItem] {
    if !model.episodes.isEmpty {
      return [GridItem(.adaptive(minimum: 300), spacing: 14)]
    }
    switch style {
    case .small: return [GridItem(.adaptive(minimum: 105, maximum: 180), spacing: 12)]
    case .full: return [GridItem(.adaptive(minimum: 320), spacing: 12)]
    }
  }

  var body: some View {
    Group {
      if model.isEmpty {
        placeholder
      } else {
        grid
      }
    }
    .padding(.horizontal, 16)
  }

  @ViewBuilder
  private var placeholder: some View {
    switch model.phase {
    case .idle, .loading:
      skeletonGrid
    case .failed(let message):
      BrowseErrorCard(kind: .failed(message), height: 300, onRetry: { model.retry() })
    case .loaded:
      BrowseErrorCard(kind: model.filters == BrowseSearchFilters() && model.sectionTitle == nil ? .empty : .noResults, height: 300)
    }
  }

  private var skeletonGrid: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
      ForEach(0..<12, id: \.self) { _ in
        if style == .full {
          BrowseFullCardSkeleton()
        } else {
          BrowseSmallCardSkeleton()
        }
      }
    }
  }

  private var grid: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
      if model.episodes.isEmpty {
        ForEach(model.media) { media in
          BrowseMediaCard(media: media, style: style)
        }
      } else {
        ForEach(model.episodes) { item in
          BrowseEpisodeCard(data: item)
        }
      }
      if model.hasNextPage {
        ProgressView()
          .tint(.white)
          .frame(maxWidth: .infinity, minHeight: 80)
          .id(model.page)
          .onAppear {
            Task { await model.loadMore() }
          }
      }
    }
  }
}
