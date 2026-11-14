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

  func load(page: Int, perPage: Int = 50) async throws -> MediaPage {
    try await addon.loadCatalogPage(catalog, page: page, perPage: perPage, extra: extra)
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

/// Loading state of one row or grid.
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
  private var page = 0

  init(section: StremioCatalogSection) {
    self.section = section
  }

  /// First page (rows load lazily when they appear, like the IntersectionObserver deferredLoad).
  func loadIfNeeded() async {
    guard phase == .idle else { return }
    phase = .loading
    do {
      let result = try await section.load(page: 1)
      items = result.items
      hasNextPage = result.hasNextPage
      page = 1
      phase = .loaded
    } catch {
      if PlaybackResolver.isCancellation(error) {
        phase = .idle
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }

  /// Next page for the full grid.
  func loadMore() async {
    guard phase == .loaded, hasNextPage, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let result = try await section.load(page: page + 1)
      let known = Set(items.map(\.id))
      items.append(contentsOf: result.items.filter { !known.contains($0.id) })
      hasNextPage = result.hasNextPage
      page += 1
    } catch {
      hasNextPage = false
    }
  }

  func retry() async {
    phase = .idle
    await loadIfNeeded()
  }
}

/// Catalogs page (common/routes/catalogs/CatalogPage.svelte): one horizontal row per catalog of the
/// enabled Stremio addons, search across addons (debounced 500 ms), empty states. Tapping a row title
/// opens the whole catalog in a grid; tapping a poster calls `onSelect`.
@MainActor
struct CatalogsView: View {
  var onSelect: (Media) -> Void
  /// "Open Settings" button of the "No Stremio addon" card (page.navigateTo(page.SETTINGS)).
  var onOpenSettings: (() -> Void)?

  @State private var query = ""
  @State private var activeQuery = ""
  @State private var debounceTask: Task<Void, Never>? = nil
  @State private var gridSection: StremioCatalogSection? = nil

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
            StremioCatalogRowView(section: section, onSelect: onSelect, onOpenAll: { gridSection = section })
              .id(section.id)
          }
        }
      }
      .padding(.vertical, 15)
    }
    .background(Color.black)
    .sheet(item: $gridSection) { section in
      StremioCatalogGridView(section: section) { media in
        gridSection = nil
        onSelect(media)
      }
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

/// One horizontal row (HomeSection equivalent): title (opens the full catalog), posters.
@MainActor
struct StremioCatalogRowView: View {
  let section: StremioCatalogSection
  var onSelect: (Media) -> Void
  var onOpenAll: () -> Void

  @State private var model: StremioCatalogPageModel? = nil

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
        LazyHStack(alignment: .top, spacing: 12) {
          rowContent
        }
        .padding(.horizontal, 20)
      }
    }
    .task(id: section.id) {
      let current: StremioCatalogPageModel
      if let model, model.section.id == section.id {
        current = model
      } else {
        current = StremioCatalogPageModel(section: section)
        model = current
      }
      await current.loadIfNeeded()
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    if let model {
      switch model.phase {
      case .idle, .loading:
        placeholders
      case .failed(let message):
        failureCard(message, model: model)
      case .loaded:
        if model.items.isEmpty {
          Text("Nothing to show")
            .font(.subheadline)
            .foregroundStyle(ExtensionPalette.muted)
            .frame(height: 60)
        } else {
          ForEach(model.items) { media in
            StremioCatalogCard(media: media) { onSelect(media) }
              .frame(width: 112)
          }
        }
      }
    } else {
      placeholders
    }
  }

  private var placeholders: some View {
    ForEach(0..<6, id: \.self) { _ in
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.06))
        .frame(width: 112, height: 168)
    }
  }

  private func failureCard(_ message: String, model: StremioCatalogPageModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(message)
        .font(.footnote)
        .foregroundStyle(ExtensionPalette.muted)
        .lineLimit(3)
      Button("Retry") {
        Task { await model.retry() }
      }
      .font(.footnote.weight(.semibold))
    }
    .padding(12)
    .frame(width: 220, height: 168, alignment: .topLeading)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// Poster + title card.
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

/// Whole catalog in a grid with pagination (the Search page opened by a section title).
@MainActor
struct StremioCatalogGridView: View {
  let section: StremioCatalogSection
  var onSelect: (Media) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var model: StremioCatalogPageModel? = nil

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14, alignment: .top)]

  var body: some View {
    NavigationStack {
      ScrollView {
        content
          .padding(16)
      }
      .background(Color.black)
      .navigationTitle(section.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Close") { dismiss() }
        }
      }
    }
    .task {
      if model == nil {
        let created = StremioCatalogPageModel(section: section)
        model = created
        await created.loadIfNeeded()
      }
    }
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
          Button("Retry") { Task { await model.retry() } }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
      case .loaded:
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
          ForEach(model.items) { media in
            StremioCatalogCard(media: media) { onSelect(media) }
              .onAppear {
                if media.id == model.items.last?.id {
                  Task { await model.loadMore() }
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
