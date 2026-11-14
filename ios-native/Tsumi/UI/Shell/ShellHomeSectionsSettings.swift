import SwiftUI

// Home screen editors of InterfaceTab.svelte: "Anime Sections" (customSections: name, AniList genres, tags),
// "Western Sections (TMDB)" (westernSections: name, TMDB genres, type) and "Sections And Order"
// (components/HomeSections.svelte: section, sort, formats, drag & drop order, delete, add).

/// Defaults and option lists of HomeSections.svelte / sections.js.
@MainActor
enum ShellHomeSectionCatalog {
  static let formatOptions: [ShellOption] = [
    ShellOption("TV", "TV Show"),
    ShellOption("MOVIE", "Movie"),
    ShellOption("TV_SHORT", "TV Short"),
    ShellOption("SPECIAL", "Special"),
    ShellOption("OVA", "OVA"),
    ShellOption("ONA", "ONA")
  ]

  private static let listTitles = ["Continue Watching", "Watching List", "Rewatching List", "Completed List", "Paused List", "Planning List", "Dropped List"]

  /// Sort options of a row (user list sorts only for the list sections).
  static func sortOptions(for title: String) -> [ShellOption] {
    var options = [
      ShellOption("TRENDING_DESC", "Trending"),
      ShellOption("POPULARITY_DESC", "Popularity"),
      ShellOption("TITLE_ROMAJI", "Title"),
      ShellOption("SCORE_DESC", "Score"),
      ShellOption("START_DATE_DESC", "Release Date")
    ]
    let lower = title.lowercased()
    guard listTitles.contains(where: { lower.contains($0.lowercased()) }) else { return options }
    let completed = lower.contains("completed list")
    let planning = lower.contains("planning list")
    let dropped = lower.contains("dropped list")
    if completed { options.append(ShellOption("FINISHED_ON_DESC", "Completed Date")) }
    if !planning { options.append(ShellOption("STARTED_ON_DESC", "Start Date")) }
    options.append(ShellOption("UPDATED_TIME_DESC", "Last Updated"))
    if !completed && !planning { options.append(ShellOption("PROGRESS_DESC", "Your Progress")) }
    if completed || dropped { options.append(ShellOption("USER_SCORE_DESC", "Your Score")) }
    return options
  }

  static func sortLabel(_ sort: String, title: String) -> String {
    if sort.contains("N/A") || sort.isEmpty { return "N/A" }
    return sortOptions(for: title).first { $0.value == sort }?.label ?? sort
  }

  static func formatsLabel(_ formats: [String]) -> String {
    let labels = formatOptions.filter { formats.contains($0.value) }.map { $0.label }
    return labels.isEmpty ? "Any Format" : labels.joined(separator: ", ")
  }

  /// [title, sort, format] of a section in the allowed list (sections.js createSection defaults).
  static func defaultSetting(for title: String) -> HomeSectionSetting {
    let values = AppSettings.shared.values
    if let western = values.westernSections.first(where: { $0.title == title }) {
      return HomeSectionSetting(title: title, sort: "N/A", formats: westernFormats(western.mediaType))
    }
    if values.customSections.contains(where: { $0.title == title }) {
      return HomeSectionSetting(title: title, sort: "TRENDING_DESC", formats: ["TV", "MOVIE"])
    }
    switch title {
    case "Anime - Recent Dubs", "Anime - Recent Subs":
      return HomeSectionSetting(title: title, sort: "N/A", formats: ["TV", "MOVIE", "OVA", "ONA"])
    case "Hentai Releases":
      return HomeSectionSetting(title: title, sort: "N/A", formats: ["OVA"])
    case "Western - Recent TV Episodes":
      return HomeSectionSetting(title: title, sort: "N/A", formats: ["TV"])
    case "Sequels You Missed", "Stories You Missed", "Planning List":
      return HomeSectionSetting(title: title, sort: "POPULARITY_DESC", formats: [])
    case "Continue Watching", "Watching List", "Rewatching List", "Completed List", "Paused List", "Dropped List":
      return HomeSectionSetting(title: title, sort: "UPDATED_TIME_DESC", formats: [])
    case "Anime - Popular This Season", "Anime - Trending now", "Anime - All Time Popular":
      return HomeSectionSetting(title: title, sort: "N/A", formats: ["TV", "MOVIE"])
    case "Anime - Upcoming Next Season":
      return HomeSectionSetting(title: title, sort: "POPULARITY_DESC", formats: ["TV", "MOVIE"])
    default:
      let section = HomeSectionsService.shared.section(titled: title)
      let sort = (section?.isRSS ?? false) ? "N/A" : (section?.variables.sort ?? "N/A")
      return HomeSectionSetting(title: title, sort: sort, formats: section?.formats ?? [])
    }
  }

  static func westernFormats(_ mediaType: String) -> [String] {
    switch mediaType {
    case "Movies": return ["MOVIE"]
    case "TV Shows": return ["TV"]
    default: return ["TV", "MOVIE"]
    }
  }

  /// Every section title (built-in, custom and western) except `excluding`.
  static func titleExists(_ title: String, excluding: String) -> Bool {
    let lower = title.lowercased()
    let values = AppSettings.shared.values
    let names = HomeSectionsService.shared.availableTitles + values.customSections.map { $0.title } + values.westernSections.map { $0.title }
    return names.contains { $0.lowercased() == lower && $0 != excluding }
  }

  /// "New Section", or "New Section 2"... when that name is taken.
  static func uniqueNewTitle() -> String {
    var candidate = "New Section"
    var counter = 2
    while titleExists(candidate, excluding: "") {
      candidate = "New Section \(counter)"
      counter += 1
    }
    return candidate
  }

  /// A renamed custom / western section keeps its place in the home layout.
  static func renameInLayout(from oldTitle: String, to newTitle: String) {
    var layout = AppSettings.shared.values.homeSections
    var changed = false
    for index in layout.indices where layout[index].title == oldTitle {
      layout[index].title = newTitle
      changed = true
    }
    if changed { AppSettings.shared.values.homeSections = layout }
  }

  /// A deleted custom / western section leaves the home layout.
  static func removeFromLayout(_ title: String) {
    let layout = AppSettings.shared.values.homeSections
    let filtered = layout.filter { $0.title != title }
    if filtered.count != layout.count { AppSettings.shared.values.homeSections = filtered }
  }
}

// MARK: - Sections And Order (HomeSections.svelte)

@MainActor
struct ShellHomeSectionsView: View {
  var body: some View {
    let layout = AppSettings.shared.values.homeSections
    let available = HomeSectionsService.shared.availableTitles
    let remaining = available.filter { title in !layout.contains { $0.title == title } }
    return List {
      Section {
        ForEach(layout) { item in
          ShellHomeSectionRow(item: item, remaining: remaining)
        }
        .onMove { source, destination in
          var updated = AppSettings.shared.values.homeSections
          updated.move(fromOffsets: source, toOffset: destination)
          AppSettings.shared.values.homeSections = updated
        }
        .onDelete { offsets in
          var updated = AppSettings.shared.values.homeSections
          updated.remove(atOffsets: offsets)
          AppSettings.shared.values.homeSections = updated
        }
      } footer: {
        Text("Sections and their order on the home screen. Custom Anime and Western sections created above can be added here. Drag/drop these sections to re-order them.")
      }
      Section {
        Menu {
          ForEach(remaining, id: \.self) { title in
            Button(title) {
              AppSettings.shared.values.homeSections.append(ShellHomeSectionCatalog.defaultSetting(for: title))
            }
          }
        } label: {
          Label("Add Section", systemImage: "plus")
        }
        .disabled(remaining.isEmpty)
      }
    }
    .navigationTitle("Sections And Order")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
      }
    }
  }
}

/// One row: section select, sort select (disabled for N/A) and format multi select.
@MainActor
struct ShellHomeSectionRow: View {
  let item: HomeSectionSetting
  let remaining: [String]

  var body: some View {
    let item = self.item
    let sortDisabled = item.sort.contains("N/A")
    return VStack(alignment: .leading, spacing: 8) {
      Menu {
        ForEach([item.title] + remaining, id: \.self) { title in
          Button(title) { replace(with: title) }
        }
      } label: {
        HStack(spacing: 6) {
          Text(item.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(Color.secondary)
        }
      }
      HStack(spacing: 14) {
        Menu {
          ForEach(ShellHomeSectionCatalog.sortOptions(for: item.title)) { option in
            Button {
              update { $0.sort = option.value }
            } label: {
              if option.value == item.sort {
                Label(option.label, systemImage: "checkmark")
              } else {
                Text(option.label)
              }
            }
          }
        } label: {
          Label(ShellHomeSectionCatalog.sortLabel(item.sort, title: item.title), systemImage: "arrow.up.arrow.down")
        }
        .disabled(sortDisabled)
        Menu {
          ForEach(ShellHomeSectionCatalog.formatOptions) { option in
            Toggle(option.label, isOn: formatBinding(option.value))
              .menuActionDismissBehavior(.disabled)
          }
        } label: {
          Label(ShellHomeSectionCatalog.formatsLabel(item.formats), systemImage: "rectangle.stack")
            .lineLimit(1)
        }
      }
      .font(.subheadline)
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 2)
  }

  private func update(_ change: (inout HomeSectionSetting) -> Void) {
    var layout = AppSettings.shared.values.homeSections
    guard let index = layout.firstIndex(where: { $0.title == item.title }) else { return }
    change(&layout[index])
    AppSettings.shared.values.homeSections = layout
  }

  /// Changing the section resets the row to that section's defaults.
  private func replace(with title: String) {
    guard title != item.title else { return }
    let replacement = ShellHomeSectionCatalog.defaultSetting(for: title)
    update { $0 = replacement }
  }

  private func formatBinding(_ format: String) -> Binding<Bool> {
    let title = item.title
    return Binding(
      get: {
        AppSettings.shared.values.homeSections.first { $0.title == title }?.formats.contains(format) ?? false
      },
      set: { isOn in
        var layout = AppSettings.shared.values.homeSections
        guard let index = layout.firstIndex(where: { $0.title == title }) else { return }
        var formats = layout[index].formats.filter { $0 != format }
        if isOn {
          formats.append(format)
          let selected = formats
          formats = ShellHomeSectionCatalog.formatOptions.map { $0.value }.filter { selected.contains($0) }
        }
        layout[index].formats = formats
        AppSettings.shared.values.homeSections = layout
      }
    )
  }
}

// MARK: - Anime Sections (customSections)

@MainActor
struct ShellAnimeSectionsView: View {
  var body: some View {
    let sections = AppSettings.shared.values.customSections
    return List {
      Section {
        ForEach(sections) { section in
          NavigationLink(value: ShellSettingsRoute.animeSection(section.title)) {
            VStack(alignment: .leading, spacing: 3) {
              Text(section.title)
                .font(.body.weight(.semibold))
              Text(summary(section))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
            }
          }
        }
        .onDelete { offsets in
          let removed = offsets.map { sections[$0].title }
          var updated = AppSettings.shared.values.customSections
          updated.remove(atOffsets: offsets)
          AppSettings.shared.values.customSections = updated
          for title in removed { ShellHomeSectionCatalog.removeFromLayout(title) }
        }
      } footer: {
        Text("Create custom anime sections that can be added to the home screen. These use AniList genres and tags.")
      }
      Section {
        Button {
          AppSettings.shared.values.customSections.append(CustomAnimeSection(title: ShellHomeSectionCatalog.uniqueNewTitle()))
        } label: {
          Label("Add Section", systemImage: "plus")
        }
      }
    }
    .navigationTitle("Anime Sections")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
      }
    }
  }

  private func summary(_ section: CustomAnimeSection) -> String {
    let genres = section.genres.isEmpty ? "Any genre" : section.genres.joined(separator: ", ")
    let tags = section.tags.isEmpty ? "Any tag" : section.tags.joined(separator: ", ")
    return "Genres: \(genres) · Tags: \(tags)"
  }
}

@MainActor
struct ShellAnimeSectionEditor: View {
  @State private var title: String
  @State private var name: String
  @State private var error: String? = nil
  @Environment(\.dismiss) private var dismiss

  init(initialTitle: String) {
    _title = State(initialValue: initialTitle)
    _name = State(initialValue: initialTitle)
  }

  private var section: CustomAnimeSection? {
    AppSettings.shared.values.customSections.first { $0.title == title }
  }

  var body: some View {
    Form {
      if let section {
        Section {
          TextField("Name", text: $name)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { commitName() }
          if let error {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Color.red)
          }
        } header: {
          Text("Name")
        }
        Section {
          NavigationLink {
            ShellMultiSelectView(title: "Genres", options: AnimeCatalog.genres, selection: listBinding(\.genres))
          } label: {
            LabeledContent("Genres", value: section.genres.isEmpty ? "Any" : section.genres.joined(separator: ", "))
          }
          NavigationLink {
            ShellMultiSelectView(title: "Tags", options: AnimeCatalog.tags, selection: listBinding(\.tags))
          } label: {
            LabeledContent("Tags", value: section.tags.isEmpty ? "Any" : section.tags.joined(separator: ", "))
          }
        }
        Section {
          Button(role: .destructive) {
            delete()
          } label: {
            Label("Delete Section", systemImage: "trash")
          }
        }
      } else {
        Text("This section no longer exists.")
          .foregroundStyle(Color.secondary)
      }
    }
    .navigationTitle(title)
    .onDisappear { commitName() }
  }

  private func listBinding(_ keyPath: WritableKeyPath<CustomAnimeSection, [String]>) -> Binding<[String]> {
    let current = title
    return Binding(
      get: { AppSettings.shared.values.customSections.first { $0.title == current }?[keyPath: keyPath] ?? [] },
      set: { value in
        var sections = AppSettings.shared.values.customSections
        guard let index = sections.firstIndex(where: { $0.title == current }) else { return }
        sections[index][keyPath: keyPath] = value
        AppSettings.shared.values.customSections = sections
      }
    )
  }

  private func commitName() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != title else {
      error = nil
      return
    }
    guard !trimmed.isEmpty else {
      name = title
      error = nil
      return
    }
    guard !ShellHomeSectionCatalog.titleExists(trimmed, excluding: title) else {
      error = "A section with this name already exists."
      return
    }
    var sections = AppSettings.shared.values.customSections
    guard let index = sections.firstIndex(where: { $0.title == title }) else { return }
    sections[index].title = trimmed
    AppSettings.shared.values.customSections = sections
    ShellHomeSectionCatalog.renameInLayout(from: title, to: trimmed)
    title = trimmed
    name = trimmed
    error = nil
  }

  private func delete() {
    let current = title
    AppSettings.shared.values.customSections.removeAll { $0.title == current }
    ShellHomeSectionCatalog.removeFromLayout(current)
    dismiss()
  }
}

// MARK: - Western Sections (westernSections)

@MainActor
struct ShellWesternSectionsView: View {
  var body: some View {
    let sections = AppSettings.shared.values.westernSections
    return List {
      Section {
        ForEach(sections) { section in
          NavigationLink(value: ShellSettingsRoute.westernSection(section.title)) {
            VStack(alignment: .leading, spacing: 3) {
              Text(section.title)
                .font(.body.weight(.semibold))
              Text("\(section.genres.isEmpty ? "Any genre" : section.genres.joined(separator: ", ")) · \(section.mediaType)")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
            }
          }
        }
        .onDelete { offsets in
          let removed = offsets.map { sections[$0].title }
          var updated = AppSettings.shared.values.westernSections
          updated.remove(atOffsets: offsets)
          AppSettings.shared.values.westernSections = updated
          for title in removed { ShellHomeSectionCatalog.removeFromLayout(title) }
        }
      } footer: {
        Text("Create custom western media sections powered by TMDB. These filter out anime and use TMDB genres.")
      }
      Section {
        Button {
          AppSettings.shared.values.westernSections.append(WesternSection(title: ShellHomeSectionCatalog.uniqueNewTitle()))
        } label: {
          Label("Add Section", systemImage: "plus")
        }
      }
    }
    .navigationTitle("Western Sections (TMDB)")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
      }
    }
  }
}

@MainActor
struct ShellWesternSectionEditor: View {
  @State private var title: String
  @State private var name: String
  @State private var error: String? = nil
  @Environment(\.dismiss) private var dismiss

  static let typeOptions = [ShellOption("Both", "Both"), ShellOption("TV Shows", "TV Shows"), ShellOption("Movies", "Movies")]

  init(initialTitle: String) {
    _title = State(initialValue: initialTitle)
    _name = State(initialValue: initialTitle)
  }

  private var section: WesternSection? {
    AppSettings.shared.values.westernSections.first { $0.title == title }
  }

  var body: some View {
    Form {
      if let section {
        Section {
          TextField("Name", text: $name)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { commitName() }
          if let error {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Color.red)
          }
        } header: {
          Text("Name")
        }
        Section {
          NavigationLink {
            ShellMultiSelectView(title: "Genres", options: AnimeCatalog.tmdbGenres, selection: genresBinding)
          } label: {
            LabeledContent("Genres", value: section.genres.isEmpty ? "Any" : section.genres.joined(separator: ", "))
          }
          Picker("Type", selection: typeBinding) {
            ForEach(Self.typeOptions) { option in
              Text(option.label).tag(option.value)
            }
          }
          .pickerStyle(.menu)
        }
        Section {
          Button(role: .destructive) {
            delete()
          } label: {
            Label("Delete Section", systemImage: "trash")
          }
        }
      } else {
        Text("This section no longer exists.")
          .foregroundStyle(Color.secondary)
      }
    }
    .navigationTitle(title)
    .onDisappear { commitName() }
  }

  private func mutate(_ change: (inout WesternSection) -> Void) {
    var sections = AppSettings.shared.values.westernSections
    guard let index = sections.firstIndex(where: { $0.title == title }) else { return }
    change(&sections[index])
    AppSettings.shared.values.westernSections = sections
  }

  private var genresBinding: Binding<[String]> {
    let current = title
    return Binding(
      get: { AppSettings.shared.values.westernSections.first { $0.title == current }?.genres ?? [] },
      set: { value in
        var sections = AppSettings.shared.values.westernSections
        guard let index = sections.firstIndex(where: { $0.title == current }) else { return }
        sections[index].genres = value
        AppSettings.shared.values.westernSections = sections
      }
    )
  }

  /// <select bind:value={settings.westernSections[i][2]}> (Both / TV Shows / Movies).
  private var typeBinding: Binding<String> {
    let current = title
    return Binding(
      get: { AppSettings.shared.values.westernSections.first { $0.title == current }?.mediaType ?? "Both" },
      set: { value in
        var sections = AppSettings.shared.values.westernSections
        guard let index = sections.firstIndex(where: { $0.title == current }) else { return }
        sections[index].mediaType = value
        AppSettings.shared.values.westernSections = sections
      }
    )
  }

  private func commitName() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != title else {
      error = nil
      return
    }
    guard !trimmed.isEmpty else {
      name = title
      error = nil
      return
    }
    guard !ShellHomeSectionCatalog.titleExists(trimmed, excluding: title) else {
      error = "A section with this name already exists."
      return
    }
    let oldTitle = title
    mutate { $0.title = trimmed }
    ShellHomeSectionCatalog.renameInLayout(from: oldTitle, to: trimmed)
    title = trimmed
    name = trimmed
    error = nil
  }

  private func delete() {
    let current = title
    AppSettings.shared.values.westernSections.removeAll { $0.title == current }
    ShellHomeSectionCatalog.removeFromLayout(current)
    dismiss()
  }
}

// MARK: - Multi select (CustomDropdown.svelte)

@MainActor
struct ShellMultiSelectView: View {
  let title: String
  let options: [String]
  @Binding var selection: [String]
  @State private var query = ""

  var body: some View {
    let extra = selection.filter { !options.contains($0) }
    let all = extra + options
    let shown = query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    return List {
      if !selection.isEmpty {
        Section {
          Button("Clear Selection", role: .destructive) {
            selection = []
          }
        }
      }
      Section {
        ForEach(shown, id: \.self) { option in
          Button {
            toggle(option)
          } label: {
            HStack {
              Text(option)
                .foregroundStyle(Color.primary)
              Spacer()
              if selection.contains(option) {
                Image(systemName: "checkmark")
                  .foregroundStyle(Color.accentColor)
              }
            }
          }
        }
      }
    }
    .navigationTitle(title)
    .searchable(text: $query)
  }

  private func toggle(_ option: String) {
    if selection.contains(option) {
      selection.removeAll { $0 == option }
    } else {
      selection.append(option)
    }
  }
}
