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
  /// Results of the selected Sora module (filters.soraModule), shown instead of `media`; no next page.
  private(set) var soraResults: [SoraSearchResult] = []
  /// Module result being matched to an AniList / TMDB title (spinner on its card).
  private(set) var matchingResultID: String?
  @ObservationIgnored private var matchTask: Task<Void, Never>?
  @ObservationIgnored private var matchToken = 0
  /// Pages of the selected Stremio catalog (filters.catalogKey), shown instead of `media` (BrowseCatalogSource.swift).
  private(set) var catalogResults: StremioCatalogPageModel?
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
    !badges.isEmpty || sectionTitle != nil || isTraceMode || filters.soraModule != nil || filters.catalogKey != nil
  }

  var isEmpty: Bool { media.isEmpty && episodes.isEmpty && soraResults.isEmpty }

  /// A Sora module is the Source: the AniList / TMDB filters (genres, season, format, status, sort, list and dub
  /// filters) do not apply and are disabled.
  var isSoraSource: Bool { filters.soraModule != nil }

  /// A Stremio addon catalog is the Source: same, the filters do not apply.
  var isCatalogSource: Bool { filters.catalogKey != nil }

  /// A Sora module or a Stremio catalog is the Source (SearchBar.svelte catalogMode).
  var ignoresFilters: Bool { isSoraSource || isCatalogSource }

  /// The title field searches the selected catalog (itself or a search catalog of its addon); a catalog that cannot
  /// search disables it (sections.js catalogSearch).
  var catalogCanSearch: Bool {
    filters.catalogKey.map { BrowseCatalogSource.canSearch($0) } ?? false
  }

  /// Name of the selected Sora module (nil for AniList / TMDB).
  var soraModuleName: String? {
    filters.soraModule.map { Self.moduleDisplayName($0) }
  }

  /// Name of a Sora module for the Source menu and the hints. A module that is not installed any more is not shown
  /// by its key (an internal id).
  static func moduleDisplayName(_ key: String) -> String {
    ExtensionManager.shared.installedExtension(key)?.displayName ?? "Removed Module"
  }

  /// Why the selected Sora module or Stremio catalog cannot be searched (disabled, removed or not loaded), nil when
  /// it can or AniList / TMDB is the source. Its card then offers the Extensions settings and Both
  /// (BrowseSourceUnavailableCard) instead of only a Retry that keeps failing.
  var unavailableSourceMessage: String? {
    if let key = filters.soraModule {
      guard !SoraSearchSource.modules().contains(where: { $0.key == key }) else { return nil }
      if let installed = ExtensionManager.shared.installedExtension(key) {
        return "\(installed.displayName) is disabled or could not be loaded."
      }
      return "This Sora module is not installed any more."
    }
    if let key = filters.catalogKey {
      guard BrowseCatalogSource.displayName(key) == nil else { return nil }
      return "This catalog is not available any more: its addon is disabled, removed or could not be loaded."
    }
    return nil
  }

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

  /// Source menu (SearchBar.svelte changeSource): a Sora module (its key) or back to AniList / TMDB (nil). A module
  /// keeps the typed title, which is what it searches, and clears the filters it ignores.
  func selectSoraModule(_ key: String?) {
    guard let key else {
      if filters.soraModule != nil { filters.soraModule = nil }
      return
    }
    guard filters.soraModule != key else { return }
    var next = BrowseSearchFilters()
    next.text = filters.text
    next.soraModule = key
    filters = next
    isTraceMode = false
  }

  /// Source menu: a Stremio addon catalog (its key) or back to AniList / TMDB (nil). Like PC changeSource, a catalog
  /// starts from empty filters (it ignores them, and the title is typed afterwards to search it).
  func selectCatalog(_ key: String?) {
    guard let key else {
      if filters.catalogKey != nil { filters.catalogKey = nil }
      return
    }
    guard filters.catalogKey != key else { return }
    var next = BrowseSearchFilters()
    next.catalogKey = key
    filters = next
    isTraceMode = false
  }

  /// "Search Both" of the unavailable source card: back to AniList / TMDB, both catalogues.
  func leaveExternalSource() {
    var next = filters
    next.soraModule = nil
    next.catalogKey = nil
    next.western = nil
    filters = next
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
    soraResults = []
    cancelSoraMatch()
    catalogResults?.cancel()
    catalogResults = nil
    page = 0
    hasNextPage = false
    // Not while a Sora module or a catalog is the source (SearchBar.svelte clearNext): picking it cleared the other
    // filters, so its first search saved the bare title over the last AniList / TMDB search.
    if section == nil && filters.soraModule == nil && filters.catalogKey == nil { filters.save(key: Self.storageKey) }
    do {
      if section == nil, let catalogKey = key.filters.catalogKey {
        // Stremio catalog source: the catalog, or its search for the typed title, paged by its own model
        // (BrowseCatalogSource.swift). A refresh of the extensions may still be loading the addon.
        await ExtensionManager.shared.awaitPendingLoads()
        guard current == token else { return }
        if Task.isCancelled {
          lastRunKey = nil
          return
        }
        guard let catalog = BrowseCatalogSource.section(catalogKey, text: key.filters.text) else {
          phase = .failed("This catalog is not available any more.")
          return
        }
        let pages = StremioCatalogPageModel(section: catalog)
        catalogResults = pages
        pages.start()
        phase = .loaded
        return
      }
      if section == nil, let moduleKey = key.filters.soraModule {
        // Sora module source: its own search of the title, one page of cards (SoraSearchSource.swift).
        let found = try await SoraSearchSource.search(moduleKey: moduleKey, title: key.filters.text)
        guard current == token else { return }
        if Task.isCancelled {
          lastRunKey = nil
          return
        }
        soraResults = found
        phase = .loaded
        return
      }
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
      soraResults = []
      cancelSoraMatch()
      catalogResults?.cancel()
      catalogResults = nil
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

  // MARK: Sora module results (searchsource.js openSoraResult)

  /// Card tap on a module result: finds the matching AniList / TMDB title, opens its details and remembers the
  /// module result for Play (session only). A tap on another result replaces the running lookup. A module whose
  /// "Link results to AniList / TMDB" is off opens its module page instead (SoraResultView), and so does "Open as
  /// is" of the toast when nothing matches.
  func openSoraResult(_ result: SoraSearchResult) {
    guard ExtensionManager.shared.linksResults(result.extensionKey) else {
      cancelSoraMatch()
      ShellNavigation.openSoraResult(result)
      return
    }
    guard matchingResultID != result.id else { return }
    cancelSoraMatch()
    matchToken += 1
    let current = matchToken
    matchingResultID = result.id
    matchTask = Task { [weak self] in
      do {
        let match = try await SoraSearchSource.findMatch(result)
        guard let self, current == self.matchToken, !Task.isCancelled else { return }
        self.matchingResultID = nil
        self.matchTask = nil
        guard let match else {
          ServiceMessages.shared.post(.error, "No AniList or TMDB title matches this result", "\(result.title) (\(result.extensionName))", actionLabel: "Open as is") {
            ShellNavigation.openSoraResult(result)
          }
          return
        }
        SoraPreferredSources.shared.remember(PlaybackSource(extensionKey: result.extensionKey, href: result.href, title: result.title), for: match.id)
        BrowseActions.open(match)
      } catch {
        guard let self, current == self.matchToken else { return }
        self.matchingResultID = nil
        self.matchTask = nil
        if PlaybackResolver.isCancellation(error) { return }
        ServiceMessages.shared.post(.error, "Could not open this result", error.localizedDescription)
      }
    }
  }

  /// Stops the running lookup (its results were replaced).
  private func cancelSoraMatch() {
    matchTask?.cancel()
    matchTask = nil
    matchToken += 1
    matchingResultID = nil
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
    .onChange(of: model.unavailableSourceMessage == nil) { _, available in
      // The module or addon came back (enabled from the Extensions settings, or done loading): searched again.
      if available, case .failed = model.phase {
        model.retry()
      }
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
        BrowseSourceMenu(
          western: $model.filters.western,
          disabled: model.context.lockSource || model.context.disableSearch,
          modules: SoraSearchSource.modules(),
          selectedModule: model.filters.soraModule,
          onSelectModule: { key in model.selectSoraModule(key) },
          catalogs: BrowseCatalogSource.groups(),
          selectedCatalog: model.filters.catalogKey,
          onSelectCatalog: { key in model.selectCatalog(key) }
        )
        BrowseSearchField(text: $model.filters.text, disabled: titleDisabled, placeholder: titlePlaceholder)
      }
      buttons
      BrowseFilterBadgesView(badges: model.badges) { badge in
        model.remove(badge)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  /// SearchBar.svelte titleDisabled: feeds, and a catalog that cannot search.
  private var titleDisabled: Bool {
    model.context.disableSearch || (model.isCatalogSource && !model.catalogCanSearch)
  }

  private var titlePlaceholder: String {
    if model.isSoraSource { return "Type a title to search" }
    if model.isCatalogSource { return model.catalogCanSearch ? "Search the addon" : "Not searchable" }
    return "Any"
  }

  private var buttons: some View {
    let context = model.context
    let authorized = ProfilesService.shared.isAuthorized
    // A Sora module or a catalog source only searches the title: the AniList / TMDB filters are disabled.
    let externalSource = model.ignoresFilters
    return HStack(spacing: 8) {
      BrowseIconButton(systemImage: "slider.horizontal.3", active: model.filters.activeCount > 0, badge: model.filters.activeCount, label: "Advanced Search") {
        showFilters = true
      }
      .disabled(context.disableSearch || externalSource)
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
      .disabled(context.disableHide || context.disableSearch || !authorized || externalSource)
      BrowseIconButton(systemImage: "mic", active: model.filters.dubOnly, label: "Dubbed Audio") {
        model.filters.dubOnly.toggle()
      }
      .disabled(context.disableSearch || externalSource)
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

/// Source select: Both / Anime / Western, then the catalogs of each Stremio addon ("Catalogs · Addon" submenus) and
/// the enabled Sora modules in a "Sora Modules" submenu (Search page only, SearchBar.svelte buildSourceGroups).
@MainActor
struct BrowseSourceMenu: View {
  @Binding var western: Bool?
  var disabled = false
  /// Enabled Sora modules (SoraSearchSource.modules); empty on the Schedule page.
  var modules: [SoraModuleOption] = []
  /// Key of the selected module, nil for AniList / TMDB.
  var selectedModule: String? = nil
  /// Picks a module (its key) or leaves it (nil, before Both / Anime / Western applies).
  var onSelectModule: ((String?) -> Void)? = nil
  /// Catalogs of the enabled Stremio addons (BrowseCatalogSource.groups); empty on the Schedule page.
  var catalogs: [BrowseCatalogGroup] = []
  /// Key of the selected catalog, nil for AniList / TMDB.
  var selectedCatalog: String? = nil
  /// Picks a catalog (its key) or leaves it (nil, before Both / Anime / Western applies).
  var onSelectCatalog: ((String?) -> Void)? = nil

  /// A Sora module or a catalog is the source (Both / Anime / Western then have no checkmark).
  private var externalSelected: Bool {
    selectedModule != nil || selectedCatalog != nil
  }

  private var title: String {
    if let selectedModule {
      return modules.first { $0.key == selectedModule }?.name ?? BrowseSearchModel.moduleDisplayName(selectedModule)
    }
    if let selectedCatalog {
      for group in catalogs {
        if let option = group.catalogs.first(where: { $0.key == selectedCatalog }) { return option.name }
      }
      return "Removed Catalog"
    }
    return Self.basicTitle(western)
  }

  private static func basicTitle(_ value: Bool?) -> String {
    switch value {
    case .none: return "Both"
    case .some(false): return "Anime"
    case .some(true): return "Western"
    }
  }

  private var systemImage: String {
    if selectedModule != nil { return "puzzlepiece.extension" }
    if selectedCatalog != nil { return "movieclapper" }
    return "square.grid.2x2"
  }

  /// A long module name is shortened, so the title field keeps its room.
  private var shortTitle: String {
    let value = title
    return value.count > 18 ? String(value.prefix(17)) + "…" : value
  }

  private func pick(_ value: Bool?) {
    if selectedModule != nil { onSelectModule?(nil) }
    if selectedCatalog != nil { onSelectCatalog?(nil) }
    western = value
  }

  /// A menu entry, with a checkmark when it is the current source.
  @ViewBuilder
  private func entry(_ label: String, selected: Bool) -> some View {
    if selected {
      Label(label, systemImage: "checkmark")
    } else {
      Text(label)
    }
  }

  var body: some View {
    let basic = !externalSelected
    return Menu {
      Button {
        pick(nil)
      } label: {
        entry("Both", selected: basic && western == nil)
      }
      Button {
        pick(false)
      } label: {
        entry("Anime", selected: basic && western == false)
      }
      Button {
        pick(true)
      } label: {
        entry("Western", selected: basic && western == true)
      }
      ForEach(catalogs) { group in
        Menu {
          ForEach(group.catalogs) { option in
            Button {
              onSelectCatalog?(option.key)
            } label: {
              entry(option.name, selected: option.key == selectedCatalog)
            }
          }
        } label: {
          Label("Catalogs · \(group.addonName)", systemImage: "movieclapper")
        }
      }
      if !modules.isEmpty {
        Menu {
          ForEach(modules) { module in
            Button {
              onSelectModule?(module.key)
            } label: {
              entry(module.name, selected: module.key == selectedModule)
            }
          }
        } label: {
          Label("Sora Modules", systemImage: "puzzlepiece.extension")
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: systemImage)
        Text(shortTitle)
          .lineLimit(1)
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
    // The selected source (the button text can be shortened).
    .accessibilityValue(title)
  }
}

/// Title input with clear button.
@MainActor
struct BrowseSearchField: View {
  @Binding var text: String
  var disabled = false
  var placeholder = "Any"

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(BrowsePalette.dimmed)
      TextField(placeholder, text: $text)
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
      if let catalog = model.catalogResults {
        BrowseCatalogSourceResults(model: catalog, style: style, columns: columns, searching: !model.filters.trimmedText.isEmpty)
      } else if model.isEmpty {
        placeholder
      } else {
        grid
      }
    }
    .padding(.horizontal, 16)
  }

  /// The selected module or catalog cannot be searched (once its search ran): Extensions settings or Both.
  private var unavailableMessage: String? {
    switch model.phase {
    case .failed, .loaded: return model.unavailableSourceMessage
    case .idle, .loading: return nil
    }
  }

  @ViewBuilder
  private var placeholder: some View {
    if let message = unavailableMessage {
      BrowseSourceUnavailableCard(message: message, height: 300, onRetry: { model.retry() }, onSearchBoth: { model.leaveExternalSource() })
    } else {
      phasePlaceholder
    }
  }

  @ViewBuilder
  private var phasePlaceholder: some View {
    switch model.phase {
    case .idle, .loading:
      skeletonGrid
    case .failed(let message):
      BrowseErrorCard(kind: .failed(message), height: 300, onRetry: { model.retry() })
    case .loaded:
      if let moduleName = model.soraModuleName, model.filters.trimmedText.isEmpty {
        // A module searches titles only: nothing to show before one is typed.
        BrowseSoraHint(moduleName: moduleName, height: 300)
      } else {
        BrowseErrorCard(kind: model.filters == BrowseSearchFilters() && model.sectionTitle == nil ? .empty : .noResults, height: 300)
      }
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
      if !model.soraResults.isEmpty {
        ForEach(model.soraResults) { result in
          BrowseSoraResultCard(result: result, style: style, isMatching: model.matchingResultID == result.id) {
            model.openSoraResult(result)
          }
        }
      } else if model.episodes.isEmpty {
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
