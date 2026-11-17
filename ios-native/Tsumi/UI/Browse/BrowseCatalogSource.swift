import SwiftUI

// Stremio addon catalogs as a Source of the Search page (common/routes/catalogs/sections.js, SearchBar.svelte
// buildSourceGroups / changeSource): the Source menu lists the catalogs of every enabled addon, one submenu per addon.
// A picked catalog fills the results grid (paged like the Catalogs screen); a typed title is searched through the
// catalog itself when it can search, else through a search catalog of the same addon and type, and the title field is
// disabled when there is none. The rows, pages and AniList swap are those of the Catalogs screen
// (Extensions/CatalogsView.swift: StremioCatalogSection, StremioCatalogPageModel).

/// One catalog of the Source menu.
struct BrowseCatalogOption: Identifiable, Hashable {
  /// Same key as the browse rows of StremioCatalogSections.build: `${ext.key}|${type}|${id}|`.
  var key: String
  /// Catalog name without the addon name (its submenu shows it).
  var name: String

  var id: String { key }
}

/// The catalogs of one addon ("Catalogs · Cinemeta" submenu).
struct BrowseCatalogGroup: Identifiable, Hashable {
  var addonKey: String
  var addonName: String
  var catalogs: [BrowseCatalogOption]

  var id: String { addonKey }
}

@MainActor
enum BrowseCatalogSource {
  /// Enabled Stremio addons, in the order of the settings (Sora modules have no catalogs).
  static func addons() -> [LoadedExtension] {
    ExtensionManager.shared.enabledExtensions().filter { $0.kind == .stremio }
  }

  /// Groups of the Source menu: one per addon with catalogs to browse (catalogs needing a filter are left out, like
  /// the Catalogs screen).
  static func groups() -> [BrowseCatalogGroup] {
    addons().compactMap { ext -> BrowseCatalogGroup? in
      guard let addon = ext.stremioAddon else { return nil }
      let catalogs = addon.listCatalogs()
      guard !catalogs.isEmpty else { return nil }
      // Two catalogs with the same name ("Popular" movies and "Popular" series) get their type.
      var counts: [String: Int] = [:]
      for catalog in catalogs {
        counts[catalogName(catalog), default: 0] += 1
      }
      let options = catalogs.map { catalog -> BrowseCatalogOption in
        let base = catalogName(catalog)
        let label = (counts[base] ?? 0) > 1 ? "\(base) · \(StremioCatalogSections.typeLabel(catalog.type))" : base
        return BrowseCatalogOption(key: catalogKey(ext.key, catalog), name: label)
      }
      return BrowseCatalogGroup(addonKey: ext.key, addonName: ext.displayName, catalogs: options)
    }
  }

  /// Name of a catalog for the Source button, nil when it is not available any more (addon disabled, removed or not
  /// loaded, or catalog gone from its manifest).
  static func displayName(_ key: String) -> String? {
    for group in groups() {
      if let option = group.catalogs.first(where: { $0.key == key }) { return option.name }
    }
    return nil
  }

  /// Whether the title field can search this catalog (sections.js catalogSearch).
  static func canSearch(_ key: String) -> Bool {
    guard let found = find(key) else { return false }
    return searchCatalog(found.addon, for: found.catalog) != nil
  }

  /// What the results grid loads (sections.js makeSection load): the catalog, or its search for `text` when the
  /// catalog (or another catalog of the addon for the same type) can search. Nil when the catalog is not available.
  static func section(_ key: String, text: String) -> StremioCatalogSection? {
    guard let found = find(key) else { return nil }
    let title = "\(catalogName(found.catalog)) · \(found.ext.displayName)"
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty, let search = searchCatalog(found.addon, for: found.catalog) {
      return StremioCatalogSection(
        id: "\(found.ext.key)|\(search.type)|\(search.id)|\(query)",
        title: title,
        addon: found.addon,
        catalog: search,
        extra: [StremioExtraParam(name: "search", value: query)]
      )
    }
    return StremioCatalogSection(id: key, title: title, addon: found.addon, catalog: found.catalog, extra: [])
  }

  // MARK: Helpers

  private static func catalogName(_ catalog: StremioCatalog) -> String {
    catalog.name ?? StremioCatalogSections.typeLabel(catalog.type)
  }

  private static func catalogKey(_ extensionKey: String, _ catalog: StremioCatalog) -> String {
    "\(extensionKey)|\(catalog.type)|\(catalog.id)|"
  }

  /// The addon and the catalog behind a key.
  private static func find(_ key: String) -> (ext: LoadedExtension, addon: StremioAddon, catalog: StremioCatalog)? {
    for ext in addons() {
      guard let addon = ext.stremioAddon else { continue }
      if let catalog = addon.listCatalogs().first(where: { Self.catalogKey(ext.key, $0) == key }) {
        return (ext: ext, addon: addon, catalog: catalog)
      }
    }
    return nil
  }

  /// The catalog itself when it can search, else the first search catalog of the addon for the same type.
  private static func searchCatalog(_ addon: StremioAddon, for catalog: StremioCatalog) -> StremioCatalog? {
    if catalog.supports("search") { return catalog }
    return addon.listCatalogs(search: true).first { $0.type == catalog.type }
  }
}

/// Results grid of a catalog source: its page model (StremioCatalogPageModel) with skeletons, error / empty states
/// with Retry, and the next page when the last row shows (SearchPage.svelte infinite scroll).
@MainActor
struct BrowseCatalogSourceResults: View {
  let model: StremioCatalogPageModel
  let style: BrowseCardStyle
  let columns: [GridItem]
  /// A title is being searched: an empty answer is "No results found." rather than an empty catalog.
  var searching = false

  var body: some View {
    switch model.phase {
    case .idle, .loading:
      LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
        ForEach(0..<12, id: \.self) { _ in
          if style == .full {
            BrowseFullCardSkeleton()
          } else {
            BrowseSmallCardSkeleton()
          }
        }
      }
    case .failed(let message):
      BrowseErrorCard(kind: .failed(message), height: 300, onRetry: { model.retry() })
    case .loaded:
      if model.items.isEmpty {
        // An empty page can also come from lookups that failed for every item: Retry, like the Catalogs screen.
        BrowseErrorCard(kind: searching ? .noResults : .empty, height: 300, onRetry: { model.retry() })
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
          ForEach(model.items) { media in
            BrowseMediaCard(media: media, style: style)
          }
          if model.hasNextPage {
            ProgressView()
              .tint(.white)
              .frame(maxWidth: .infinity, minHeight: 80)
              // A new identity per page, so it asks again while it stays on screen (loadTillFull).
              .id(model.items.count)
              .onAppear { model.loadMore() }
          }
        }
      }
    }
  }
}

/// The selected Sora module or Stremio catalog cannot be searched (disabled, removed or not loaded): the Extensions
/// settings or back to Both, instead of only a Retry that keeps failing. Retry stays for a module still loading.
@MainActor
struct BrowseSourceUnavailableCard: View {
  let message: String
  var height: CGFloat? = 300
  let onRetry: () -> Void
  let onSearchBoth: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text("Ooops!")
        .font(.title.bold())
        .foregroundStyle(.white)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(BrowsePalette.muted)
        .multilineTextAlignment(.center)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { buttons }
        VStack(spacing: 8) { buttons }
      }
      .padding(.top, 4)
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .frame(height: height)
  }

  @ViewBuilder
  private var buttons: some View {
    Button {
      ShellNavigation.openSettings(.extensions)
    } label: {
      Label("Open Extensions", systemImage: "puzzlepiece.extension")
        .font(.subheadline.weight(.semibold))
    }
    .buttonStyle(.borderedProminent)
    Button {
      onSearchBoth()
    } label: {
      Label("Search Both", systemImage: "square.grid.2x2")
        .font(.subheadline.weight(.semibold))
    }
    .buttonStyle(.bordered)
    .tint(.white)
    Button {
      onRetry()
    } label: {
      Label("Retry", systemImage: "arrow.clockwise")
        .font(.subheadline.weight(.semibold))
    }
    .buttonStyle(.bordered)
    .tint(.white)
  }
}
