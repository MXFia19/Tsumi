import SwiftUI
import Observation

// routes/SchedulePage.svelte: airing schedule of the week (sub or dub schedule, plus western shows on the
// air), with the SearchBar filters it keeps (source, title, genres / tags, formats, hide / show my anime,
// dubbed audio), persisted as lastSchedule. Entries are grouped by day with their time and countdown.

@MainActor
@Observable
final class BrowseScheduleModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  struct RunKey: Equatable {
    var filters: BrowseSearchFilters
    var generation: Int
  }

  struct Day: Identifiable {
    var id: Date { date }
    let date: Date
    let title: String
    let items: [AiringEpisode]
  }

  static let storageKey = "tsumi.browse.lastSchedule"

  var filters: BrowseSearchFilters
  private(set) var entries: [AiringEpisode] = []
  private(set) var phase: Phase = .idle
  private(set) var hasNextPage = false
  private(set) var isLoadingMore = false
  private(set) var page = 0
  private var generation = 0
  @ObservationIgnored private var lastRunKey: RunKey? = nil
  @ObservationIgnored private var token = 0

  let context: BrowseFilterContext = {
    var context = BrowseFilterContext()
    context.isSchedule = true
    return context
  }()

  init() {
    filters = BrowseSearchFilters.load(key: Self.storageKey, fallback: BrowseSearchFilters.scheduleDefault)
  }

  var runKey: RunKey {
    RunKey(filters: filters, generation: generation)
  }

  var badges: [BrowseFilterBadge] {
    BrowseFilterBadge.badges(filters, sectionTitle: nil)
  }

  /// Entries matching the local filters (title search and excluded formats), grouped by day.
  var days: [Day] {
    let text = filters.trimmedText.lowercased()
    let excludedFormats = Set(filters.formatsNot)
    let visible = entries.filter { item in
      if excludedFormats.contains(item.media.format.rawValue) { return false }
      if text.isEmpty { return true }
      let titles = item.media.title.all + item.media.synonyms
      return titles.contains { $0.lowercased().contains(text) }
    }
    let calendar = Calendar.current
    var grouped: [Date: [AiringEpisode]] = [:]
    // Suspended dubs have no real date (their predicted node is years ahead): listed last, without a day.
    var suspended: [AiringEpisode] = []
    for item in visible {
      if item.delayedIndefinitely {
        suspended.append(item)
        continue
      }
      grouped[calendar.startOfDay(for: item.airingAt), default: []].append(item)
    }
    var result = grouped.keys.sorted().map { date in
      let items = (grouped[date] ?? []).sorted { $0.airingAt < $1.airingAt }
      return Day(date: date, title: BrowseText.dayTitle(date), items: items)
    }
    if !suspended.isEmpty {
      result.append(Day(date: Date.distantFuture, title: "Suspended", items: suspended))
    }
    return result
  }

  func reset() {
    filters = BrowseSearchFilters()
    generation += 1
  }

  func retry() {
    lastRunKey = nil
    generation += 1
  }

  func remove(_ badge: BrowseFilterBadge) {
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

  /// Only the text filter is local: it applies without a new request.
  private func requestKey(_ key: RunKey) -> RunKey {
    var copy = key
    copy.filters.text = ""
    copy.filters.formatsNot = []
    return copy
  }

  func runIfNeeded() async {
    filters.save(key: Self.storageKey)
    let key = requestKey(runKey)
    if key == lastRunKey { return }
    if lastRunKey != nil {
      try? await Task.sleep(nanoseconds: 500_000_000)
      if Task.isCancelled { return }
    }
    lastRunKey = key
    token += 1
    let current = token
    phase = .loading
    entries = []
    page = 0
    hasNextPage = false
    do {
      let result = try await Services.shared.sections.schedule(filters.scheduleFilter, page: 1)
      guard current == token else { return }
      if Task.isCancelled {
        lastRunKey = nil
        return
      }
      entries = result.items
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

  /// Next western page (anime are all on the first page).
  func loadMore() async {
    guard hasNextPage, !isLoadingMore, phase == .loaded else { return }
    isLoadingMore = true
    let current = token
    do {
      let result = try await Services.shared.sections.schedule(filters.scheduleFilter, page: page + 1)
      isLoadingMore = false
      guard current == token else { return }
      page += 1
      var seen = Set(entries.map { $0.media.id })
      var added = 0
      for item in result.items where !seen.contains(item.media.id) {
        entries.append(item)
        seen.insert(item.media.id)
        added += 1
      }
      entries.sort { $0.airingAt < $1.airingAt }
      hasNextPage = result.hasNextPage && added > 0
    } catch {
      isLoadingMore = false
      guard current == token else { return }
      hasNextPage = false
    }
  }
}

@MainActor
struct ScheduleView: View {
  @State private var model = BrowseScheduleModel()
  @State private var showFilters = false
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  private var style: BrowseCardStyle {
    cardMode == BrowseCardMode.full.rawValue ? .full : .small
  }

  var body: some View {
    ScrollView {
      // Plain stack: the only lazy container is the grid of BrowseScheduleContent (with its pinned day
      // headers), so the content height is not mis-estimated.
      VStack(alignment: .leading, spacing: 16) {
        BrowseScheduleHeader(model: model, showFilters: $showFilters)
        BrowseScheduleContent(model: model, style: style)
      }
      .padding(.bottom, 24)
    }
    .background(BrowsePalette.background)
    .scrollDismissesKeyboard(.immediately)
    .refreshable {
      await MainActor.run {
        model.retry()
      }
    }
    .navigationTitle("Schedule")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showFilters) {
      BrowseFilterSheet(filters: $model.filters, context: model.context, onReset: { model.reset() })
    }
    .task(id: model.runKey) {
      await model.runIfNeeded()
    }
  }
}

/// Source, title and buttons of the schedule (SearchBar.svelte with scheduleList).
@MainActor
struct BrowseScheduleHeader: View {
  @Bindable var model: BrowseScheduleModel
  @Binding var showFilters: Bool
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        BrowseSourceMenu(western: $model.filters.western)
        BrowseSearchField(text: $model.filters.text)
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
    let authorized = ProfilesService.shared.isAuthorized
    let active = !model.badges.isEmpty
    return HStack(spacing: 8) {
      BrowseIconButton(systemImage: "slider.horizontal.3", active: model.filters.activeCount > 0, badge: model.filters.activeCount, label: "Advanced Search") {
        showFilters = true
      }
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
      .disabled(!authorized)
      BrowseIconButton(systemImage: "mic", active: model.filters.dubOnly, label: "Dubbed Audio") {
        model.filters.dubOnly.toggle()
      }
      BrowseIconButton(systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", active: active, tint: BrowsePalette.danger, label: "Reset Filters") {
        model.reset()
      }
      .disabled(!active)
      Spacer(minLength: 0)
      // Small / Large cards (SearchBar.svelte, shown on the Schedule page too).
      BrowseCardModeButtons(cardMode: $cardMode)
    }
  }
}

/// Day sections with the airing cards.
@MainActor
struct BrowseScheduleContent: View {
  let model: BrowseScheduleModel
  let style: BrowseCardStyle

  private var columns: [GridItem] {
    switch style {
    case .small: return [GridItem(.adaptive(minimum: 105, maximum: 180), spacing: 12)]
    case .full: return [GridItem(.adaptive(minimum: 320), spacing: 12)]
    }
  }

  var body: some View {
    let days = model.days
    if days.isEmpty {
      placeholder
        .padding(.horizontal, 16)
    } else {
      // A single lazy grid: one section per day with its pinned header, the next-page loader as the footer
      // of a last empty section (created only when scrolled near, so pages are not loaded eagerly).
      LazyVGrid(columns: columns, alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
        ForEach(days) { day in
          Section {
            ForEach(day.items) { item in
              BrowseMediaCard(media: item.media, style: style, airing: item)
            }
          } header: {
            BrowseScheduleDayHeader(title: day.title, count: day.items.count)
              .padding(.horizontal, -16)
          }
        }
        if model.hasNextPage {
          Section {
            EmptyView()
          } footer: {
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
      .padding(.horizontal, 16)
    }
  }

  @ViewBuilder
  private var placeholder: some View {
    switch model.phase {
    case .idle, .loading:
      LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
        ForEach(0..<9, id: \.self) { _ in
          BrowseSmallCardSkeleton()
        }
      }
    case .failed(let message):
      BrowseErrorCard(kind: .failed(message), height: 300, onRetry: { model.retry() })
    case .loaded:
      BrowseErrorCard(kind: .noResults, height: 300)
    }
  }
}

struct BrowseScheduleDayHeader: View {
  let title: String
  let count: Int

  var body: some View {
    HStack {
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
      Spacer()
      Text("\(count) airing")
        .font(.footnote)
        .foregroundStyle(BrowsePalette.muted)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(BrowsePalette.background.opacity(0.94))
  }
}
