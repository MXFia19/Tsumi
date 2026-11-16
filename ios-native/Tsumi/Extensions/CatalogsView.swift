import SwiftUI
import Observation

/// One catalog row (makeSection in CatalogPage.svelte).
struct StremioCatalogSection: Identifiable, Hashable {
  /// `${ext.key}|${catalog.type}|${catalog.id}|${search}`
  var id: String
  var title: String
  var addon: StremioAddon
  var catalog: StremioCatalog
  var extra: [StremioExtraParam]

  /// The page starting at `skip` (0 = first page) and the `skip` of the next one.
  func load(skip: Int, perPage: Int = 50) async throws -> StremioCatalogPage {
    try await addon.loadCatalogPage(catalog, skip: skip, perPage: perPage, extra: extra)
  }

  static func == (lhs: StremioCatalogSection, rhs: StremioCatalogSection) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum StremioCatalogSections {
  static func typeLabel(_ type: String) -> String {
    switch type {
    case "movie": return "Movies"
    case "series": return "Series"
    default: return type
    }
  }

  /// buildSections(addons, search)
  static func build(_ addons: [LoadedExtension], search: String) -> [StremioCatalogSection] {
    var sections: [StremioCatalogSection] = []
    let several = addons.count > 1
    for ext in addons {
      guard let addon = ext.stremioAddon else { continue }
      let addonName = ext.displayName
      if !search.isEmpty {
        // One searchable catalog per type is enough (they search the same library).
        var seenTypes = Set<String>()
        for catalog in addon.listCatalogs(search: true) where !seenTypes.contains(catalog.type) {
          seenTypes.insert(catalog.type)
          sections.append(StremioCatalogSection(
            id: "\(ext.key)|\(catalog.type)|\(catalog.id)|\(search)",
            title: "\(typeLabel(catalog.type)) · \(addonName)",
            addon: addon,
            catalog: catalog,
            extra: [StremioExtraParam(name: "search", value: search)]
          ))
        }
      } else {
        for catalog in addon.listCatalogs() {
          let name = catalog.name ?? typeLabel(catalog.type)
          sections.append(StremioCatalogSection(
            id: "\(ext.key)|\(catalog.type)|\(catalog.id)|",
            title: several ? "\(name) · \(addonName)" : name,
            addon: addon,
            catalog: catalog,
            extra: []
          ))
        }
      }
    }
    return sections
  }
}

/// Row models of the catalogs page, kept while the page lives: a row scrolled away and back (the lazy stack drops
/// its views) keeps its items, and the full grid of a catalog starts from the row's items.
@MainActor
final class StremioCatalogModelStore {
  private var models: [String: StremioCatalogPageModel] = [:]

  nonisolated init() {}

  func model(for section: StremioCatalogSection) -> StremioCatalogPageModel {
    if let existing = models[section.id] { return existing }
    let created = StremioCatalogPageModel(section: section)
    models[section.id] = created
    return created
  }

  /// Drops (and stops) the models of the sections not in `ids` (a previous search, a removed addon).
  func keep(only ids: Set<String>) {
    for (id, model) in models where !ids.contains(id) {
      model.cancel()
      models[id] = nil
    }
  }
}

/// Loading state of one row or grid. The loads belong to the model, not to the view: a row scrolled away or a
/// details sheet opened over it does not cancel them (a cancelled load used to commit an empty page, since the TMDB
/// lookups of a cancelled task fail).
@MainActor
@Observable
final class StremioCatalogPageModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  let section: StremioCatalogSection
  var items: [Media] = []
  var phase: Phase = .idle
  var hasNextPage = false
  var loadingMore = false
  /// `skip` of the next page: the real position after every item read so far (StremioAddon.loadCatalogPage).
  @ObservationIgnored private var nextSkip = 0
  /// Ids of the items as the addon returned them (before the AniList swap), to drop repeats.
  @ObservationIgnored private var sourceIDs = Set<String>()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var moreTask: Task<Void, Never>?
  /// Bumped by every start / cancel: a load finishing for an older generation is ignored.
  @ObservationIgnored private var generation = 0
  /// Pages in a row that brought nothing new (an addon ignoring skip): the next page is not chained after 3.
  @ObservationIgnored private var emptyPages = 0

  init(section: StremioCatalogSection) {
    self.section = section
  }

  /// First page (rows start when they appear, like the IntersectionObserver deferredLoad). No-op once started.
  func start() {
    guard phase == .idle else { return }
    generation += 1
    let current = generation
    phase = .loading
    let section = self.section
    loadTask = Task { [weak self] in
      do {
        let result = try await section.load(skip: 0)
        guard let self, self.generation == current else { return }
        self.loadTask = nil
        // Cancelled: the page may be missing items, so nothing is kept and the next start loads it again.
        if Task.isCancelled {
          self.phase = .idle
          return
        }
        self.sourceIDs = []
        self.emptyPages = 0
        self.items = self.unseen(result.page.items)
        self.hasNextPage = result.page.hasNextPage
        self.nextSkip = result.nextSkip
        self.phase = .loaded
        self.showAnimeEntries()
      } catch {
        guard let self, self.generation == current else { return }
        self.loadTask = nil
        if Task.isCancelled || PlaybackResolver.isCancellation(error) {
          self.phase = .idle
          return
        }
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// Next page for the full grid.
  func loadMore() {
    guard phase == .loaded, hasNextPage, !loadingMore else { return }
    loadingMore = true
    let current = generation
    let section = self.section
    let skip = nextSkip
    moreTask = Task { [weak self] in
      do {
        let result = try await section.load(skip: skip)
        guard let self, self.generation == current else { return }
        self.loadingMore = false
        self.moreTask = nil
        if Task.isCancelled { return }
        let fresh = self.unseen(result.page.items)
        self.items.append(contentsOf: fresh)
        self.hasNextPage = result.page.hasNextPage
        self.nextSkip = result.nextSkip
        self.showAnimeEntries()
        // Nothing new (repeats only): the grid's last card did not change, so its onAppear will not ask again.
        self.emptyPages = fresh.isEmpty ? self.emptyPages + 1 : 0
        if fresh.isEmpty && self.hasNextPage && self.emptyPages < 3 {
          self.loadMore()
        }
      } catch {
        guard let self, self.generation == current else { return }
        self.loadingMore = false
        self.moreTask = nil
        if Task.isCancelled || PlaybackResolver.isCancellation(error) { return }
        self.hasNextPage = false
      }
    }
  }

  /// Loads the first page again (after an error, or a page that showed nothing).
  func retry() {
    cancel()
    items = []
    hasNextPage = false
    phase = .idle
    start()
  }

  /// Stops the loads in progress; an unfinished first page goes back to idle.
  func cancel() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    moreTask?.cancel()
    moreTask = nil
    loadingMore = false
    if phase == .loading { phase = .idle }
  }

  /// Items not returned before (addons repeat items, and skip pages can overlap).
  private func unseen(_ list: [Media]) -> [Media] {
    var fresh: [Media] = []
    for media in list where !sourceIDs.contains(media.id) {
      sourceIDs.insert(media.id)
      fresh.append(media)
    }
    return fresh
  }

  /// tmdb.js normalizeMedia gives a catalog item that maps to an AniList anime the AniList id, so its
  /// card (mediaCache) and its details are the AniList entry (stremio.js metaToMedia). Entries already
  /// stored are swapped in at once; the others are requested (batched AniList query) and swapped in
  /// when they arrive. An anime already in the list is not added twice.
  private func showAnimeEntries() {
    var list = items
    var present = Set(list.map(\.id))
    var missing = Set<Int>()
    var changed = false
    for index in list.indices {
      let item = list[index]
      guard item.source == .tmdb, let anilistId = item.anilistId else { continue }
      if let stored = MediaStore.shared.anilist(anilistId) {
        guard !present.contains(stored.id) else { continue }
        present.insert(stored.id)
        list[index] = stored
        changed = true
      } else {
        missing.insert(anilistId)
      }
    }
    if changed { items = list }
    guard !missing.isEmpty else { return }
    let ids = Array(missing)
    Task { [weak self] in
      let found = await StremioCatalogPageModel.fetchAnime(ids)
      self?.applyAnime(found)
    }
  }

  private func applyAnime(_ found: [Int: Media]) {
    guard !found.isEmpty else { return }
    var list = items
    var present = Set(list.map(\.id))
    var changed = false
    for index in list.indices {
      let item = list[index]
      guard item.source == .tmdb, let anilistId = item.anilistId, let anime = found[anilistId], !present.contains(anime.id) else { continue }
      present.insert(anime.id)
      list[index] = anime
      changed = true
    }
    if changed { items = list }
  }

  /// requestMediaID: AniList entries by id, batched by AniListService.
  private static func fetchAnime(_ ids: [Int]) async -> [Int: Media] {
    await withTaskGroup(of: (Int, Media?).self, returning: [Int: Media].self) { group in
      for id in ids {
        group.addTask { (id, await AniListService.shared.requestMedia(id: id)) }
      }
      var found: [Int: Media] = [:]
      for await (id, media) in group {
        if let media { found[id] = media }
      }
      return found
    }
  }
}

/// Catalogs page (common/routes/catalogs/CatalogPage.svelte): one horizontal row per catalog of the
/// enabled Stremio addons, search across addons (debounced 500 ms), empty states. Tapping a row title
/// pushes the whole catalog as a grid (the Search page in the Svelte app). The cards are the standard
/// browse cards (Card.svelte): tap opens the details, long press shows the preview with play, extension
/// picker, list editor and favourite; list status and card type (small / full) follow the settings.
/// Must be inside a NavigationStack (the shell tab stacks).
@MainActor
struct CatalogsView: View {
  /// Kept for the callers; card taps now go through the standard card action (BrowseActions.open),
  /// the same thing the shell passed here.
  var onSelect: (Media) -> Void
  /// "Open Settings" button of the "No Stremio addon" card (page.navigateTo(page.SETTINGS)).
  var onOpenSettings: (() -> Void)?

  @State private var query = ""
  @State private var activeQuery = ""
  @State private var debounceTask: Task<Void, Never>? = nil
  @State private var gridSection: StremioCatalogSection? = nil
  @State private var models = StremioCatalogModelStore()

  init(onSelect: @escaping (Media) -> Void, onOpenSettings: (() -> Void)? = nil) {
    self.onSelect = onSelect
    self.onOpenSettings = onOpenSettings
  }

  /// Enabled Stremio addons (Sora modules have no catalogs).
  private var addons: [LoadedExtension] {
    ExtensionManager.shared.enabledExtensions().filter { $0.kind == .stremio }
  }

  var body: some View {
    let addons = self.addons
    let sections = StremioCatalogSections.build(addons, search: activeQuery)
    let canSearch = addons.contains { !($0.stremioAddon?.listCatalogs(search: true).isEmpty ?? true) }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        header(canSearch: canSearch)
        if addons.isEmpty {
          noAddonCard
        } else if sections.isEmpty {
          Text(activeQuery.isEmpty ? "Your Stremio addons have no catalogs to browse." : "None of your addons can search.")
            .foregroundStyle(ExtensionPalette.muted)
            .padding(.horizontal, 20)
        } else {
          ForEach(sections) { section in
            StremioCatalogRowView(section: section, model: models.model(for: section), onSelect: onSelect, onOpenAll: { gridSection = section })
              .id(section.id)
          }
        }
      }
      .padding(.vertical, 15)
    }
    .background(Color.black)
    // Pushed rather than presented: the details, playback dialogs and toasts are hosted by the root
    // layer, which a sheet would cover.
    .navigationDestination(item: $gridSection) { section in
      StremioCatalogGridView(section: section, onSelect: onSelect, catalogs: StremioCatalogSections.build(self.addons, search: ""), models: models)
    }
    .onChange(of: sections.map(\.id)) { _, ids in
      // Rows of a previous search (or of a removed addon) are dropped; the browse rows are kept.
      let browse = StremioCatalogSections.build(self.addons, search: "").map(\.id)
      models.keep(only: Set(ids + browse))
    }
    .onDisappear { debounceTask?.cancel() }
  }

  private func header(canSearch: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "movieclapper")
          .font(.title2)
          .foregroundStyle(.white)
        Text("Catalogs")
          .font(.title.bold())
          .foregroundStyle(.white)
      }
      if canSearch {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(ExtensionPalette.dimmed)
          TextField("Search in your addons", text: $query)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
              debounceTask?.cancel()
              activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
          if !query.isEmpty {
            Button {
              clearSearch()
            } label: {
              Image(systemName: "xmark")
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ExtensionPalette.cardBorder, lineWidth: 1))
      }
    }
    .padding(.horizontal, 20)
  }

  private var noAddonCard: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(.white)
      VStack(alignment: .leading, spacing: 4) {
        Text("No Stremio addon")
          .font(.headline)
          .foregroundStyle(.white)
        Text("Add a Stremio addon in Settings > Extensions by pasting the URL of its manifest.json. Its catalogs will show up here.")
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
          .fixedSize(horizontal: false, vertical: true)
        if let onOpenSettings {
          Button(action: onOpenSettings) {
            Text("Open Settings")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 15)
              .padding(.vertical, 9)
              .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
          .buttonStyle(.plain)
          .padding(.top, 10)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(15)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ExtensionPalette.cardBorder, lineWidth: 1))
    .padding(.horizontal, 20)
  }

  private func scheduleSearch(_ text: String) {
    debounceTask?.cancel()
    debounceTask = Task {
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      activeQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func clearSearch() {
    debounceTask?.cancel()
    query = ""
    activeQuery = ""
  }
}

/// One horizontal row (HomeSection equivalent): title (opens the full catalog), standard browse cards
/// (HomeSection uses Card.svelte with the `cards` setting, like the home rows).
@MainActor
struct StremioCatalogRowView: View {
  let section: StremioCatalogSection
  /// Owned by the catalogs page (StremioCatalogModelStore), so it outlives this view.
  let model: StremioCatalogPageModel
  /// Kept for the callers; the cards use the standard card actions.
  var onSelect: (Media) -> Void
  var onOpenAll: () -> Void

  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  private var style: BrowseCardStyle {
    cardMode == BrowseCardMode.full.rawValue ? .full : .small
  }

  /// Same card widths as the home rows.
  private var cardWidth: CGFloat {
    style == .full ? 330 : 128
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onOpenAll) {
        HStack(spacing: 6) {
          Text(section.title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(ExtensionPalette.muted)
            .lineLimit(1)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.bold))
            .foregroundStyle(ExtensionPalette.dimmed)
        }
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 14) {
          rowContent
        }
        .padding(.horizontal, 20)
      }
    }
    .onAppear { model.start() }
  }

  @ViewBuilder
  private var rowContent: some View {
    switch model.phase {
    case .idle, .loading:
      placeholders
    case .failed(let message):
      messageCard(message)
    case .loaded:
      if model.items.isEmpty {
        messageCard("Nothing to show")
      } else {
        ForEach(model.items) { media in
          BrowseMediaCard(media: media, style: style, width: cardWidth)
        }
      }
    }
  }

  private var placeholders: some View {
    ForEach(0..<6, id: \.self) { _ in
      if style == .full {
        BrowseFullCardSkeleton(width: cardWidth)
      } else {
        BrowseSmallCardSkeleton(width: cardWidth)
      }
    }
  }

  /// Error or empty page, with Retry (an empty page can come from a lookup that failed for every item).
  private func messageCard(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(message)
        .font(.footnote)
        .foregroundStyle(ExtensionPalette.muted)
        .lineLimit(3)
      Button("Retry") {
        model.retry()
      }
      .font(.footnote.weight(.semibold))
    }
    .padding(12)
    .frame(width: 220, height: 168, alignment: .topLeading)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// Poster + title card (no longer used by the catalog screens, which show BrowseMediaCard).
struct StremioCatalogCard: View {
  let media: Media
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        ExtensionPosterImage(url: media.images.coverLarge ?? media.images.cover, placeholderSymbol: "film")
        Text(media.title.display(AppSettings.shared.values.titleLang))
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Whole catalog in a grid with pagination (the Search page opened by a section title), pushed on the
/// navigation stack of the catalogs screen. Standard browse cards, same columns as the Search grid.
@MainActor
struct StremioCatalogGridView: View {
  let section: StremioCatalogSection
  /// Kept for the callers; the cards use the standard card actions.
  var onSelect: (Media) -> Void
  /// Catalogs of the switcher menu (the Source menu of the search page on Windows lists them the same way).
  var catalogs: [StremioCatalogSection] = []
  /// Models of the catalogs page: the grid continues the row's list (nil = a model of its own).
  var models: StremioCatalogModelStore? = nil

  @State private var model: StremioCatalogPageModel? = nil
  /// Catalog picked in the switcher, nil = `section`.
  @State private var selected: StremioCatalogSection? = nil
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  private var style: BrowseCardStyle {
    cardMode == BrowseCardMode.full.rawValue ? .full : .small
  }

  private var columns: [GridItem] {
    switch style {
    case .small: return [GridItem(.adaptive(minimum: 105, maximum: 180), spacing: 12, alignment: .top)]
    case .full: return [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]
    }
  }

  private var shown: StremioCatalogSection { selected ?? section }

  var body: some View {
    ScrollView {
      content
        .padding(16)
    }
    .background(Color.black)
    .navigationTitle(shown.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if catalogs.count > 1 {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Picker("Catalog", selection: catalogSelection) {
              ForEach(catalogs) { catalog in
                Text(catalog.title).tag(catalog.id)
              }
            }
          } label: {
            Image(systemName: "rectangle.stack")
          }
          .accessibilityLabel("Catalog")
        }
      }
    }
    .task(id: shown.id) {
      if model?.section.id != shown.id {
        model = models?.model(for: shown) ?? StremioCatalogPageModel(section: shown)
      }
      model?.start()
    }
  }

  private var catalogSelection: Binding<String> {
    Binding(
      get: { shown.id },
      set: { id in
        if let catalog = catalogs.first(where: { $0.id == id }) { selected = catalog }
      }
    )
  }

  @ViewBuilder
  private var content: some View {
    if let model {
      switch model.phase {
      case .idle, .loading:
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
      case .failed(let message):
        VStack(spacing: 12) {
          Text(message)
            .foregroundStyle(ExtensionPalette.muted)
            .multilineTextAlignment(.center)
          Button("Retry") { model.retry() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
      case .loaded:
        if model.items.isEmpty {
          VStack(spacing: 12) {
            Text("Nothing to show")
              .foregroundStyle(ExtensionPalette.muted)
            Button("Retry") { model.retry() }
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
          ForEach(model.items) { media in
            BrowseMediaCard(media: media, style: style)
              .onAppear {
                if media.id == model.items.last?.id {
                  model.loadMore()
                }
              }
          }
        }
        if model.loadingMore {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
      }
    } else {
      ProgressView()
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
  }
}
