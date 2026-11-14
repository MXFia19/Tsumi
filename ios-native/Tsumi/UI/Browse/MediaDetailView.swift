import SwiftUI
import Observation

// modals/details/DetailsModal.svelte: details sheet of a title. Shows what is already known at once, then
// loads the full details (relations, recommendations, TMDB enrichment), the episode list, the trailer and
// the friends following the title.

@MainActor
@Observable
final class BrowseDetailModel {
  private(set) var media: Media
  private(set) var detailsLoaded = false
  private(set) var episodes: [EpisodeInfo] = []
  private(set) var episodesLoaded = false
  /// Episodes whose title repeats an earlier one (shown as "Episode N").
  private(set) var duplicateTitleIds: Set<String> = []
  private(set) var following: [AniListFollowingEntry] = []
  private(set) var trailerId: String? = nil
  /// episodeOrder (reverse button).
  var reversed = false
  /// TMDB season filter of the episode list (nil = every season).
  var selectedSeason: Int? = nil

  init(media: Media) {
    var start = MediaStore.shared.media(media.id) ?? media
    if start.relations.isEmpty { start.relations = media.relations }
    if start.recommendations.isEmpty { start.recommendations = media.recommendations }
    if start.images.banner == nil { start.images.banner = media.images.banner }
    if start.images.logo == nil { start.images.logo = media.images.logo }
    self.media = start
    trailerId = start.trailerYouTubeId
  }

  var hasZeroEpisode: Bool {
    episodes.first?.number == 0
  }

  /// Seasons of a TMDB show (season picker).
  var seasons: [Int] {
    Array(Set(episodes.compactMap { $0.season })).sorted()
  }

  /// Full details (MediaDetailsService.details), then the trailer when the media has none.
  func loadDetails() async {
    let full = await Services.shared.details.details(for: media)
    if Task.isCancelled { return }
    media = full
    detailsLoaded = true
    if trailerId == nil {
      let id = await Services.shared.details.trailer(for: full)
      if Task.isCancelled { return }
      trailerId = id
    }
  }

  /// EpisodeList.svelte load / loadTmdbEpisodes.
  func loadEpisodes() async {
    let list = await Services.shared.details.episodes(for: media)
    if Task.isCancelled { return }
    var seen = Set<String>()
    var duplicates = Set<String>()
    for episode in list {
      guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !title.isEmpty else { continue }
      if seen.contains(title) {
        duplicates.insert(episode.id)
      } else {
        seen.insert(title)
      }
    }
    duplicateTitleIds = duplicates
    episodes = list
    episodesLoaded = true
  }

  /// Following.svelte (AniList accounts only).
  func loadFollowing() async {
    guard ProfilesService.shared.isAniList, media.source == .anilist else { return }
    let list = await Services.shared.details.following(for: media)
    if Task.isCancelled { return }
    following = list
  }

  /// Episodes shown: every episode of finished titles, otherwise the aired ones plus the next one.
  func displayedEpisodes(now: Date) -> [EpisodeInfo] {
    var list = episodes
    if let season = selectedSeason {
      list = list.filter { $0.season == season }
    }
    var visible: [EpisodeInfo] = []
    for index in list.indices {
      let item = list[index]
      if media.status == .finished || index == 0 {
        visible.append(item)
        continue
      }
      let previous = list[index - 1]
      if let previousDate = previous.airDate, previousDate <= now {
        visible.append(item)
        continue
      }
      if media.status != .notYetReleased, let date = item.airDate, let previousDate = previous.airDate, date == previousDate {
        visible.append(item)
      }
    }
    return reversed ? Array(visible.reversed()) : visible
  }
}

/// Details of a media (presented by the shell in a sheet when AppRouter.presentedMedia is set).
@MainActor
struct MediaDetailView: View {
  let media: Media

  var body: some View {
    BrowseDetailScreen(media: media)
      .id(media.id)
  }
}

@MainActor
struct BrowseDetailScreen: View {
  @State private var model: BrowseDetailModel
  @Environment(\.dismiss) private var dismiss

  init(media: Media) {
    _model = State(initialValue: BrowseDetailModel(media: media))
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        BrowseDetailTop(model: model)
        BrowseDetailEpisodes(model: model)
        BrowseDetailBottom(model: model)
        Color.clear.frame(height: 30)
      }
    }
    .background(BrowsePalette.background)
    .scrollIndicators(.hidden)
    .overlay(alignment: .topTrailing) {
      closeButton
    }
    .task {
      await model.loadDetails()
    }
    .task {
      await model.loadEpisodes()
    }
    .task {
      await model.loadFollowing()
    }
  }

  private var closeButton: some View {
    Button {
      AppRouter.shared.closeDetails()
      dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(Color.black.opacity(0.6), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close")
    .padding(.top, 14)
    .padding(.trailing, 16)
  }
}

/// Header, actions, following, details strip, tags, genres and synopsis.
@MainActor
struct BrowseDetailTop: View {
  let model: BrowseDetailModel

  var body: some View {
    let media = model.media
    VStack(alignment: .leading, spacing: 16) {
      BrowseDetailHeader(media: media)
      BrowseDetailStats(media: media)
        .padding(.horizontal, 16)
      BrowseDetailActions(model: model)
        .padding(.horizontal, 16)
      if !model.following.isEmpty {
        BrowseFollowingRow(entries: model.following)
          .padding(.horizontal, 16)
      }
      BrowseDetailInfoStrip(media: media)
      BrowseDetailChips(media: media)
      BrowseDetailSynopsis(media: media)
        .padding(.horizontal, 16)
    }
  }
}
