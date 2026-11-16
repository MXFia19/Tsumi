import SwiftUI

// routes/search/components/SearchBar.svelte: search variables (source, title, genres / tags with
// exclusions, season, year, formats, statuses, sort, hide / show my anime, dubbed audio), the removable
// filter badges and the advanced filters (shown in a sheet on iOS). Shared by the Search and Schedule pages.

/// The `search` object of SearchBar.svelte.
struct BrowseSearchFilters: Codable, Equatable {
  var text = ""
  /// Source: nil = Both, false = Anime, true = Western.
  var western: Bool?
  var genres: [String] = []
  var genresNot: [String] = []
  var tags: [String] = []
  var tagsNot: [String] = []
  /// "" = Any.
  var season = ""
  var year: Int?
  var formats: [String] = []
  var formatsNot: [String] = []
  var status: [String] = []
  var statusNot: [String] = []
  /// "" = Trending.
  var sort = ""
  var hideMyAnime = false
  var showMyAnime = false
  /// hideSubs: dubbed anime only.
  var dubOnly = false
  /// Schedule "Release" filter (nil = Any), optional so older saved filters still decode.
  var release: ScheduleRelease?

  /// Statuses hidden / shown by the "Hide My Anime" button.
  static let myAnimeStatuses: [ListStatus] = [.current, .completed, .dropped, .paused, .repeating]

  /// Schedule page defaults (lastSchedule): anime, TV.
  static var scheduleDefault: BrowseSearchFilters {
    var filters = BrowseSearchFilters()
    filters.western = false
    filters.formats = ["TV"]
    return filters
  }

  var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Number of active filters (badge count of the filter button).
  var activeCount: Int {
    var count = genres.count + genresNot.count + tags.count + tagsNot.count + formats.count + formatsNot.count + status.count + statusNot.count
    if !season.isEmpty { count += 1 }
    if year != nil { count += 1 }
    if !sort.isEmpty && sort != "TRENDING_DESC" { count += 1 }
    if hideMyAnime { count += 1 }
    if showMyAnime { count += 1 }
    if dubOnly { count += 1 }
    if let release, release != .any { count += 1 }
    return count
  }

  // MARK: Conversions

  /// Preset query (AppRouter.search: genre / tag chips of the details).
  init(query: MediaQuery) {
    text = query.text ?? ""
    switch query.scope {
    case .anime: western = false
    case .western: western = true
    case .both: western = nil
    }
    formats = query.formats.map { $0.rawValue }
    genres = query.genres
    genresNot = query.excludedGenres
    tags = query.tags
    tagsNot = query.excludedTags
    season = query.season?.rawValue ?? ""
    year = query.year
    status = query.status.map { $0.rawValue }
    statusNot = query.excludedStatus.map { $0.rawValue }
    sort = query.sort == .trending ? "" : query.sort.rawValue
    // onList preset: on my list = Show My Anime, not on my list = Hide My Anime.
    if let onList = query.onList {
      showMyAnime = onList
      hideMyAnime = !onList
    }
  }

  /// "See all" of a home section: the section variables become the filters.
  init(section variables: SectionQuery) {
    text = variables.text ?? ""
    western = variables.western
    genres = variables.genres
    genresNot = variables.genresNot
    tags = variables.tags
    tagsNot = variables.tagsNot
    season = variables.season ?? ""
    year = variables.year
    formats = variables.formats
    formatsNot = variables.formatsNot
    status = variables.status
    statusNot = variables.statusNot
    if let value = variables.sort, value != "TRENDING_DESC", value != "N/A" { sort = value }
    hideMyAnime = variables.hideMyAnime
    showMyAnime = variables.showMyAnime
    dubOnly = variables.dubOnly
  }

  init() {}

  /// Variables passed to the loader (createFallbackLoad or the section loader).
  func sectionQuery(base: SectionQuery, isSection: Bool) -> SectionQuery {
    var query = base
    if !isSection {
      query.western = western
      query.isSearch = true
    }
    query.text = trimmedText.isEmpty ? nil : trimmedText
    query.genres = genres
    query.genresNot = genresNot
    query.tags = tags
    query.tagsNot = tagsNot
    query.season = season.isEmpty ? nil : season
    query.year = year
    query.formats = formats
    query.formatsNot = formatsNot
    query.status = status
    query.statusNot = statusNot
    query.sort = sort.isEmpty ? nil : sort
    query.hideMyAnime = hideMyAnime
    query.showMyAnime = showMyAnime
    if hideMyAnime && query.hideStatus.isEmpty { query.hideStatus = Self.myAnimeStatuses }
    if showMyAnime { query.showStatus = Self.myAnimeStatuses }
    query.dubOnly = dubOnly
    query.tmdbGenres = genres
    return query
  }

  /// Schedule page variables.
  var scheduleFilter: ScheduleFilter {
    var filter = ScheduleFilter()
    filter.dubs = dubOnly
    filter.western = western
    filter.formats = formats
    filter.genres = genres
    filter.excludedGenres = genresNot
    filter.tags = tags
    filter.excludedTags = tagsNot
    filter.hideMyAnime = hideMyAnime
    filter.showMyAnime = showMyAnime
    filter.listStatuses = Self.myAnimeStatuses
    filter.release = release ?? .any
    return filter
  }

  // MARK: Persistence (lastSearched / lastSchedule)

  static func load(key: String, fallback: BrowseSearchFilters) -> BrowseSearchFilters {
    guard let data = UserDefaults.standard.data(forKey: key),
          let stored = try? JSONDecoder().decode(BrowseSearchFilters.self, from: data) else { return fallback }
    return stored
  }

  func save(key: String) {
    if let data = try? JSONEncoder().encode(self) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}

/// One option of a SearchBar dropdown.
struct BrowseOption: Identifiable, Hashable {
  var id: String { value }
  let value: String
  let label: String

  init(_ value: String, _ label: String) {
    self.value = value
    self.label = label
  }
}

/// Labels of the SearchBar options.
enum BrowseFilterOptions {
  static let formats: [BrowseOption] = [
    BrowseOption("TV", "TV Show"), BrowseOption("MOVIE", "Movie"), BrowseOption("TV_SHORT", "TV Short"),
    BrowseOption("SPECIAL", "Special"), BrowseOption("OVA", "OVA"), BrowseOption("ONA", "ONA")
  ]
  static let statuses: [BrowseOption] = [
    BrowseOption("RELEASING", "Releasing"), BrowseOption("FINISHED", "Finished"),
    BrowseOption("NOT_YET_RELEASED", "Not Yet Released"), BrowseOption("CANCELLED", "Cancelled")
  ]
  static let seasons: [BrowseOption] = [
    BrowseOption("WINTER", "Winter"), BrowseOption("SPRING", "Spring"), BrowseOption("SUMMER", "Summer"), BrowseOption("FALL", "Fall")
  ]
  static let sortNames: [String: String] = [
    "TITLE_ROMAJI": "Title", "START_DATE_DESC": "Release Date", "SCORE_DESC": "Score", "POPULARITY_DESC": "Popularity",
    "UPDATED_AT_DESC": "Date Updated", "UPDATED_TIME_DESC": "Last Updated", "STARTED_ON_DESC": "Start Date",
    "FINISHED_ON_DESC": "Completed Date", "PROGRESS_DESC": "Your Progress", "USER_SCORE_DESC": "Your Score",
    "TRENDING_DESC": "Trending", "SEARCH_MATCH": "Relevance"
  ]

  static func formatName(_ value: String) -> String {
    formats.first { $0.value == value }?.label ?? value
  }

  static func sortName(_ value: String) -> String {
    sortNames[value] ?? value
  }

  /// Years of the year dropdown (next year down to 1940).
  static var years: [Int] {
    let current = AnimeSeasonClock.currentYear
    return Array(stride(from: current + 1, through: 1940, by: -1))
  }
}

/// Context of the filters (section "see all", schedule page...).
struct BrowseFilterContext: Equatable {
  /// SchedulePage: no season / status / sort / image search.
  var isSchedule = false
  /// RSS sections (disableSearch): every filter is locked.
  var disableSearch = false
  /// User list sections (disableHide): hide / show my anime locked.
  var disableHide = false
  /// The source cannot change while a section is shown.
  var lockSource = false
  /// Section flags for the user sorts.
  var userList = false
  var missedList = false
  var completedList = false
  var planningList = false
  var droppedList = false

  /// Sort options (user sorts only for user list sections). With a text query on the plain Search page, the
  /// default ("") is Relevance (SearchRelevance.swift) and Trending stays available (SearchBar.svelte).
  /// `current`: the selected sort (an explicit TRENDING_DESC keeps its own Trending entry).
  func sortOptions(hasQuery: Bool, current: String = "") -> [BrowseOption] {
    let relevance = hasQuery && !lockSource && !isSchedule
    var options: [BrowseOption] = relevance
      ? [BrowseOption("", "Relevance"), BrowseOption("TRENDING_DESC", "Trending")]
      : [BrowseOption(current == "TRENDING_DESC" ? "TRENDING_DESC" : "", "Trending")]
    options += [
      BrowseOption("POPULARITY_DESC", "Popularity"), BrowseOption("TITLE_ROMAJI", "Title"),
      BrowseOption("SCORE_DESC", "Score"), BrowseOption("START_DATE_DESC", "Release Date")
    ]
    if userList && !missedList {
      if completedList { options.append(BrowseOption("FINISHED_ON_DESC", "Completed Date")) }
      if !planningList { options.append(BrowseOption("STARTED_ON_DESC", "Start Date")) }
      options.append(BrowseOption("UPDATED_TIME_DESC", "Last Updated"))
      if !completedList && !planningList { options.append(BrowseOption("PROGRESS_DESC", "Your Progress")) }
      if completedList || droppedList { options.append(BrowseOption("USER_SCORE_DESC", "Your Score")) }
    }
    return options
  }

  /// Flags of a home section (sections.js variables: userList, missedList, completedList...).
  static func section(_ section: HomeSection) -> BrowseFilterContext {
    var context = BrowseFilterContext()
    context.disableSearch = section.isRSS
    context.disableHide = section.isUserList
    context.lockSource = true
    context.userList = section.isUserList
    context.missedList = section.title == "Sequels You Missed" || section.title == "Stories You Missed"
    context.completedList = section.title == "Completed List"
    context.planningList = section.title == "Planning List"
    context.droppedList = section.title == "Dropped List"
    return context
  }
}

// MARK: - Badges

/// One removable badge under the search bar.
struct BrowseFilterBadge: Identifiable, Hashable {
  var id: String { key + ":" + value }
  let key: String
  let value: String
  let label: String
  let systemImage: String
  var negative: Bool { key.hasSuffix("_not") }

  /// badgeKeys order of SearchBar.svelte.
  static func badges(_ filters: BrowseSearchFilters, sectionTitle: String?) -> [BrowseFilterBadge] {
    var result: [BrowseFilterBadge] = []
    if let sectionTitle {
      result.append(BrowseFilterBadge(key: "title", value: sectionTitle, label: sectionTitle, systemImage: "book"))
    }
    if !filters.trimmedText.isEmpty {
      result.append(BrowseFilterBadge(key: "search", value: filters.trimmedText, label: filters.trimmedText, systemImage: "textformat"))
    }
    for genre in filters.genres {
      result.append(BrowseFilterBadge(key: "genre", value: genre, label: genre, systemImage: BrowseGenreIcons.symbol(genre) ?? "number"))
    }
    for genre in filters.genresNot {
      result.append(BrowseFilterBadge(key: "genre_not", value: genre, label: genre, systemImage: "number"))
    }
    for tag in filters.tags {
      result.append(BrowseFilterBadge(key: "tag", value: tag, label: tag, systemImage: "number"))
    }
    for tag in filters.tagsNot {
      result.append(BrowseFilterBadge(key: "tag_not", value: tag, label: tag, systemImage: "number"))
    }
    if !filters.season.isEmpty {
      result.append(BrowseFilterBadge(key: "season", value: filters.season, label: BrowseText.capitalizedWords(filters.season), systemImage: "calendar"))
    }
    if let year = filters.year {
      result.append(BrowseFilterBadge(key: "year", value: String(year), label: String(year), systemImage: "leaf"))
    }
    for format in filters.formats {
      result.append(BrowseFilterBadge(key: "format", value: format, label: BrowseFilterOptions.formatName(format), systemImage: "tv"))
    }
    for format in filters.formatsNot {
      result.append(BrowseFilterBadge(key: "format_not", value: format, label: BrowseFilterOptions.formatName(format), systemImage: "display"))
    }
    for status in filters.status {
      result.append(BrowseFilterBadge(key: "status", value: status, label: BrowseText.capitalizedWords(status), systemImage: "play.rectangle"))
    }
    for status in filters.statusNot {
      result.append(BrowseFilterBadge(key: "status_not", value: status, label: BrowseText.capitalizedWords(status), systemImage: "xmark.rectangle"))
    }
    if !filters.sort.isEmpty && filters.sort != "TRENDING_DESC" {
      result.append(BrowseFilterBadge(key: "sort", value: filters.sort, label: BrowseFilterOptions.sortName(filters.sort), systemImage: "arrow.up.arrow.down"))
    }
    if filters.dubOnly {
      result.append(BrowseFilterBadge(key: "hideSubs", value: "true", label: "Dubbed", systemImage: "mic"))
    }
    if filters.hideMyAnime {
      result.append(BrowseFilterBadge(key: "hideMyAnime", value: "true", label: "Hide My Anime", systemImage: "eye.slash"))
    }
    if filters.showMyAnime {
      result.append(BrowseFilterBadge(key: "showMyAnime", value: "true", label: "Show My Anime", systemImage: "hourglass"))
    }
    return result
  }

  /// removeBadge (the "title" badge is handled by the page: it leaves the section).
  static func remove(_ badge: BrowseFilterBadge, from filters: inout BrowseSearchFilters) {
    switch badge.key {
    case "search": filters.text = ""
    case "genre": filters.genres.removeAll { $0 == badge.value }
    case "genre_not": filters.genresNot.removeAll { $0 == badge.value }
    case "tag": filters.tags.removeAll { $0 == badge.value }
    case "tag_not": filters.tagsNot.removeAll { $0 == badge.value }
    case "season": filters.season = ""
    case "year": filters.year = nil
    case "format": filters.formats.removeAll { $0 == badge.value }
    case "format_not": filters.formatsNot.removeAll { $0 == badge.value }
    case "status": filters.status.removeAll { $0 == badge.value }
    case "status_not": filters.statusNot.removeAll { $0 == badge.value }
    case "sort": filters.sort = ""
    case "hideSubs": filters.dubOnly = false
    case "hideMyAnime": filters.hideMyAnime = false
    case "showMyAnime": filters.showMyAnime = false
    default: break
    }
  }
}

/// Wrapping row of removable badges.
@MainActor
struct BrowseFilterBadgesView: View {
  let badges: [BrowseFilterBadge]
  let onRemove: (BrowseFilterBadge) -> Void

  var body: some View {
    if !badges.isEmpty {
      BrowseFlowLayout(spacing: 6, lineSpacing: 6) {
        ForEach(badges) { badge in
          Button {
            onRemove(badge)
          } label: {
            HStack(spacing: 5) {
              Image(systemName: badge.systemImage)
              Text(badge.label)
                .lineLimit(1)
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(badge.negative ? BrowsePalette.dangerDim : BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove Filter \(badge.label)")
        }
      }
    }
  }
}

// MARK: - Advanced filters sheet

/// Include / exclude state of a dropdown option (CustomDropdown value / altValue).
enum BrowseTriState {
  case none
  case include
  case exclude

  static func of(_ value: String, included: [String], excluded: [String]) -> BrowseTriState {
    if included.contains(value) { return .include }
    if excluded.contains(value) { return .exclude }
    return .none
  }

  /// none -> include -> exclude -> none (one inout access to the whole filters).
  static func cycle(_ value: String, in filters: inout BrowseSearchFilters, include: WritableKeyPath<BrowseSearchFilters, [String]>, exclude: WritableKeyPath<BrowseSearchFilters, [String]>) {
    var included = filters[keyPath: include]
    var excluded = filters[keyPath: exclude]
    if included.contains(value) {
      included.removeAll { $0 == value }
      excluded.append(value)
    } else if excluded.contains(value) {
      excluded.removeAll { $0 == value }
    } else {
      included.append(value)
    }
    filters[keyPath: include] = included
    filters[keyPath: exclude] = excluded
  }
}

/// Option row with the include (check) / exclude (minus) mark.
struct BrowseTriStateRow: View {
  let label: String
  let state: BrowseTriState
  var systemImage: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let systemImage {
          Image(systemName: systemImage)
            .frame(width: 22)
            .foregroundStyle(BrowsePalette.muted)
        }
        Text(label)
          .foregroundStyle(state == .exclude ? BrowsePalette.danger : Color.white)
          .strikethrough(state == .exclude)
        Spacer()
        mark
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var mark: some View {
    switch state {
    case .include:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(BrowsePalette.success)
    case .exclude:
      Image(systemName: "minus.circle.fill").foregroundStyle(BrowsePalette.danger)
    case .none:
      Image(systemName: "circle").foregroundStyle(BrowsePalette.dimmed)
    }
  }
}

/// Genres (anime + western) and tags with include / exclude (tags-input CustomDropdown).
@MainActor
struct BrowseTagPicker: View {
  @Binding var filters: BrowseSearchFilters
  @State private var query = ""

  private func matches(_ value: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespaces)
    return text.isEmpty || value.localizedCaseInsensitiveContains(text)
  }

  var body: some View {
    List {
      Section {
        Text("Tap once to include, twice to exclude, three times to clear.")
          .font(.footnote)
          .foregroundStyle(BrowsePalette.muted)
      }
      genreSection("Anime Genres", values: AnimeCatalog.genres)
      genreSection("Western Genres", values: AnimeCatalog.tmdbGenres)
      tagSection
    }
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Any")
    .navigationTitle("Genres & Tags")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func genreSection(_ title: String, values: [String]) -> some View {
    Section(title) {
      ForEach(values.filter { matches($0) }, id: \.self) { genre in
        BrowseTriStateRow(label: genre, state: BrowseTriState.of(genre, included: filters.genres, excluded: filters.genresNot), systemImage: BrowseGenreIcons.symbol(genre) ?? "number") {
          BrowseTriState.cycle(genre, in: &filters, include: \.genres, exclude: \.genresNot)
        }
      }
    }
  }

  private var tagSection: some View {
    Section("Tags") {
      ForEach(AnimeCatalog.tags.filter { matches($0) }, id: \.self) { tag in
        BrowseTriStateRow(label: tag, state: BrowseTriState.of(tag, included: filters.tags, excluded: filters.tagsNot), systemImage: "number") {
          BrowseTriState.cycle(tag, in: &filters, include: \.tags, exclude: \.tagsNot)
        }
      }
    }
  }
}

/// Advanced filters (the SearchBar columns hidden behind "Advanced Search" on small screens).
@MainActor
struct BrowseFilterSheet: View {
  @Binding var filters: BrowseSearchFilters
  let context: BrowseFilterContext
  var onReset: (() -> Void)?
  @Environment(\.dismiss) private var dismiss

  private var isAuthorized: Bool { ProfilesService.shared.isAuthorized }

  /// clearTags: genre / tag filters cannot be combined with user sorts without AniList.
  private var tagsLocked: Bool {
    !ProfilesService.shared.isAniList && UserListSorts.isUserSort(filters.sort)
  }

  var body: some View {
    NavigationStack {
      Form {
        sourceSection
        if context.isSchedule {
          releaseSection
        }
        tagsSection
        if !context.isSchedule {
          seasonSection
        }
        formatSection
        if !context.isSchedule {
          statusSection
          sortSection
        }
        listSection
        resetSection
      }
      .disabled(context.disableSearch)
      .navigationTitle("Filters")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.large])
    .preferredColorScheme(.dark)
  }

  private var sourceBinding: Binding<Int> {
    Binding(
      get: {
        switch filters.western {
        case .none: return 0
        case .some(false): return 1
        case .some(true): return 2
        }
      },
      set: { value in
        switch value {
        case 1: filters.western = false
        case 2: filters.western = true
        default: filters.western = nil
        }
      }
    )
  }

  private var sourceSection: some View {
    Section("Source") {
      Picker("Source", selection: sourceBinding) {
        Text("Both").tag(0)
        Text("Anime").tag(1)
        Text("Western").tag(2)
      }
      .pickerStyle(.segmented)
      .disabled(context.lockSource)
    }
  }

  private var releaseBinding: Binding<ScheduleRelease> {
    Binding(
      get: { filters.release ?? .any },
      set: { filters.release = $0 == .any ? nil : $0 }
    )
  }

  /// Schedule only: episodes, movies in theaters, movies on digital (MovieReleases).
  private var releaseSection: some View {
    Section {
      Picker("Release", selection: releaseBinding) {
        ForEach(ScheduleRelease.allCases) { option in
          Text(option.label).tag(option)
        }
      }
    } header: {
      Text("Release")
    } footer: {
      Text("Movies show up at their theatrical release and again at their digital release.")
    }
  }

  private var tagsSummary: String {
    let count = filters.genres.count + filters.genresNot.count + filters.tags.count + filters.tagsNot.count
    return count == 0 ? "Any" : "\(count) selected"
  }

  private var tagsSection: some View {
    Section {
      NavigationLink {
        BrowseTagPicker(filters: $filters)
      } label: {
        HStack {
          Label("Genres & Tags", systemImage: "number")
          Spacer()
          Text(tagsSummary).foregroundStyle(BrowsePalette.muted)
        }
      }
      .disabled(tagsLocked)
    } footer: {
      if tagsLocked {
        Text("Cannot use with sort: \(BrowseFilterOptions.sortName(filters.sort))")
      }
    }
  }

  private var seasonSection: some View {
    Section("Season") {
      Picker("Season", selection: $filters.season) {
        Text("Any").tag("")
        ForEach(BrowseFilterOptions.seasons) { option in
          Text(option.label).tag(option.value)
        }
      }
      Picker("Year", selection: $filters.year) {
        Text("Any").tag(Int?.none)
        ForEach(BrowseFilterOptions.years, id: \.self) { year in
          Text(String(year)).tag(Int?.some(year))
        }
      }
    }
  }

  private var formatSection: some View {
    Section("Format") {
      ForEach(BrowseFilterOptions.formats) { option in
        BrowseTriStateRow(label: option.label, state: BrowseTriState.of(option.value, included: filters.formats, excluded: filters.formatsNot)) {
          BrowseTriState.cycle(option.value, in: &filters, include: \.formats, exclude: \.formatsNot)
        }
      }
    }
  }

  private var statusSection: some View {
    Section("Status") {
      ForEach(BrowseFilterOptions.statuses) { option in
        BrowseTriStateRow(label: option.label, state: BrowseTriState.of(option.value, included: filters.status, excluded: filters.statusNot)) {
          BrowseTriState.cycle(option.value, in: &filters, include: \.status, exclude: \.statusNot)
        }
      }
    }
  }

  private var sortSection: some View {
    Section("Sort") {
      Picker("Sort", selection: $filters.sort) {
        ForEach(context.sortOptions(hasQuery: !filters.trimmedText.isEmpty, current: filters.sort)) { option in
          Text(option.label).tag(option.value)
        }
      }
      .onChange(of: filters.sort) { _, _ in
        if tagsLocked {
          filters.genres = []
          filters.genresNot = []
          filters.tags = []
          filters.tagsNot = []
        }
      }
    }
  }

  private var hideBinding: Binding<Bool> {
    Binding(get: { filters.hideMyAnime }, set: { value in
      filters.hideMyAnime = value
      if value { filters.showMyAnime = false }
    })
  }

  private var showBinding: Binding<Bool> {
    Binding(get: { filters.showMyAnime }, set: { value in
      filters.showMyAnime = value
      if value { filters.hideMyAnime = false }
    })
  }

  private var listSection: some View {
    Section {
      Toggle(isOn: hideBinding) {
        Label("Hide My Anime", systemImage: "eye.slash")
      }
      .disabled(context.disableHide || !isAuthorized)
      Toggle(isOn: showBinding) {
        Label("Show My Anime", systemImage: "hourglass")
      }
      .disabled(context.disableHide || !isAuthorized)
      Toggle(isOn: $filters.dubOnly) {
        Label("Dubbed Audio", systemImage: "mic")
      }
    }
  }

  private var resetSection: some View {
    Section {
      Button(role: .destructive) {
        if let onReset {
          onReset()
        } else {
          filters = BrowseSearchFilters()
        }
      } label: {
        Label("Reset Filters", systemImage: "line.3.horizontal.decrease.circle")
      }
    }
  }
}
