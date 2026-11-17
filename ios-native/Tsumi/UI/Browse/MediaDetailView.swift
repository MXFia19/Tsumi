import SwiftUI
import Observation

// modals/details/DetailsModal.svelte: details sheet of a title. Shows what is already known at once, then
// loads the full details (relations, recommendations, TMDB enrichment), the episode list, the trailer and
// the friends following the title. Two columns (details | episodes) on regular width, like col-lg-7 / col-lg-5.

@MainActor
@Observable
final class BrowseDetailModel {
  private(set) var media: Media
  private(set) var detailsLoaded = false
  private(set) var episodes: [EpisodeInfo] = []
  private(set) var episodesLoaded = false
  /// The episode list could not be built in time: error card with a Retry button instead of skeletons.
  private(set) var episodesFailed = false
  /// Episodes whose title repeats an earlier one (shown as "Episode N").
  private(set) var duplicateTitleIds: Set<String> = []
  private(set) var following: [AniListFollowingEntry] = []
  private(set) var trailerId: String? = nil
  /// Dub / Sub airing rows of the episode list (Card Audio setting), keyed by episode number.
  private(set) var dubAirings: [Int: DubEpisodeAiring] = [:]
  /// Recommendation likes (AniList recommendation rating), keyed by media id.
  private(set) var recommendationLikes: [String: Int] = [:]
  /// Extended profiles of the followed users (User.svelte popover), loaded when a popover is first opened.
  private(set) var followingProfiles: [Int: FollowingUserProfile] = [:]
  /// TMDB movies: theatrical and digital release days (release alert bell), nil until loaded.
  private(set) var movieReleaseDays: MovieReleaseDays? = nil
  /// episodeOrder (reverse button).
  var reversed = false
  /// TMDB season filter of the episode list (nil = every season).
  var selectedSeason: Int? = nil
  /// Episode list before the dub air dates are applied.
  @ObservationIgnored private var rawEpisodes: [EpisodeInfo] = []
  @ObservationIgnored private var episodeToken = 0
  @ObservationIgnored private var profilesRequested = false

  init(media: Media) {
    var start = MediaStore.shared.media(media.id) ?? media
    if start.relations.isEmpty { start.relations = media.relations }
    if start.recommendations.isEmpty { start.recommendations = media.recommendations }
    if start.images.banner == nil { start.images.banner = media.images.banner }
    if start.images.logo == nil { start.images.logo = media.images.logo }
    self.media = start
    trailerId = start.trailerYouTubeId
  }

  /// The media with its latest stored state (list entry, progress, banner...), so the details refresh after a
  /// list edit like the mediaCache subscription of DetailsModal.svelte. Details-only fields of the loaded copy
  /// are kept when the stored copy lacks them.
  var live: Media {
    _ = MediaListService.shared.revision
    guard var stored = MediaStore.shared.media(media.id) else { return media }
    if stored.relations.isEmpty { stored.relations = media.relations }
    if stored.recommendations.isEmpty { stored.recommendations = media.recommendations }
    if stored.characters.isEmpty { stored.characters = media.characters }
    if stored.staff.isEmpty { stored.staff = media.staff }
    if stored.studios.isEmpty { stored.studios = media.studios }
    if stored.images.banner == nil { stored.images.banner = media.images.banner }
    if stored.images.logo == nil { stored.images.logo = media.images.logo }
    if stored.trailerYouTubeId == nil { stored.trailerYouTubeId = media.trailerYouTubeId }
    if stored.description == nil { stored.description = media.description }
    return stored
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
    // Fresh details carry isFavourite: refresh every heart.
    BrowseFavouriteStore.shared.changed()
    if trailerId == nil {
      let id = await Services.shared.details.trailer(for: full)
      if Task.isCancelled { return }
      trailerId = id
    }
  }

  /// Recommendation ratings (DetailsModal sorts the recommendations by rating, SmallCard shows "N likes").
  func loadRecommendationLikes() async {
    guard media.source == .anilist else { return }
    let ratings = await Services.shared.details.recommendationRatings(for: media)
    if Task.isCancelled { return }
    var likes: [String: Int] = [:]
    for (id, rating) in ratings {
      likes[Media.anilistKey(id)] = rating
    }
    recommendationLikes = likes
  }

  /// EpisodeList.svelte load / loadTmdbEpisodes. The list is shown as soon as the first pass is built; dub
  /// rows, Jikan titles and filler / recap flags are filled in afterwards. A first pass that takes longer
  /// than 30 seconds ends in the error state (Retry) instead of endless skeletons.
  func loadEpisodes() async {
    episodeToken += 1
    let token = episodeToken
    episodesFailed = false
    let current = media
    let first: [EpisodeInfo]? = await MediaDetailsService.withTimeout(30, fallback: nil) {
      await MediaDetailsService.shared.quickEpisodes(for: current)
    }
    if Task.isCancelled || token != episodeToken { return }
    guard let first, !first.isEmpty else {
      episodes = []
      rawEpisodes = []
      episodesFailed = true
      episodesLoaded = true
      return
    }
    apply(first)
    episodesLoaded = true

    let numbers = first.map { $0.number }
    let airings: [Int: DubEpisodeAiring] = await MediaDetailsService.withTimeout(15, fallback: [:]) {
      await AnimeScheduleService.shared.dubEpisodeAirings(for: current, episodes: numbers)
    }
    if Task.isCancelled || token != episodeToken { return }
    if !airings.isEmpty {
      dubAirings = airings
      apply(rawEpisodes)
    }

    let enriched: [EpisodeInfo] = await MediaDetailsService.withTimeout(120, fallback: first) {
      await MediaDetailsService.shared.enrichEpisodes(first, for: current)
    }
    if Task.isCancelled || token != episodeToken { return }
    if enriched != first {
      apply(enriched)
    }
  }

  /// Retry button of the episode list error state.
  func retryEpisodes() {
    episodesLoaded = false
    episodesFailed = false
    Task { await loadEpisodes() }
  }

  /// Stores the list: dub air dates (a dub that aired before the sub date means the sub exists too), then the
  /// titles that repeat an earlier episode (matchPhrase strict 0.1 = same title once normalized).
  private func apply(_ list: [EpisodeInfo]) {
    rawEpisodes = list
    var adjusted = list
    if media.status != .finished && !dubAirings.isEmpty {
      for index in adjusted.indices {
        guard let dubDate = dubAirings[adjusted[index].number]?.airdate, let airDate = adjusted[index].airDate, dubDate < airDate else { continue }
        adjusted[index].airDate = dubDate
      }
    }
    var seen = Set<String>()
    var duplicates = Set<String>()
    for episode in adjusted.sorted(by: { $0.number < $1.number }) {
      guard let title = episode.title, !title.isEmpty else { continue }
      let key = ServiceText.clean(title)
      if key.isEmpty { continue }
      if seen.contains(key) {
        duplicates.insert(episode.id)
      } else {
        seen.insert(key)
      }
    }
    duplicateTitleIds = duplicates
    episodes = adjusted
  }

  /// Release days of a TMDB movie (cached release_dates request): they decide whether the release alert bell
  /// is offered and fill the "In theaters ... · Digital ..." line.
  func loadMovieReleaseDays() async {
    guard MovieAlertsService.supports(media), let tmdbId = media.tmdbId else { return }
    let days = await MovieAlertsService.shared.releaseDays(movieId: tmdbId)
    if Task.isCancelled { return }
    movieReleaseDays = days
  }

  /// Following.svelte (AniList accounts only).
  func loadFollowing() async {
    guard ProfilesService.shared.isAniList, media.source == .anilist else { return }
    let list = await Services.shared.details.following(for: media)
    if Task.isCancelled { return }
    following = list
  }

  /// User.svelte popover data (banner, colour, join date, statistics), requested once per details.
  func loadFollowingProfiles() async {
    guard !profilesRequested else { return }
    profilesRequested = true
    let profiles = await Services.shared.details.followingProfiles(for: media)
    if profiles.isEmpty { profilesRequested = false }
    followingProfiles = profiles
  }

  /// Episodes shown: every episode of finished titles, otherwise the aired ones plus the next one (and the
  /// episodes airing, or dubbed, at the same time as the previous one).
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
        continue
      }
      if let previousDub = dubAirings[previous.number]?.airdate, let dub = dubAirings[item.number]?.airdate, previousDub == dub {
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
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(media: Media) {
    _model = State(initialValue: BrowseDetailModel(media: media))
  }

  var body: some View {
    GeometryReader { proxy in
      if sizeClass == .regular && proxy.size.width >= 700 {
        wideLayout(width: proxy.size.width)
      } else {
        compactLayout
      }
    }
    .background(BrowsePalette.background)
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
    .task {
      await model.loadRecommendationLikes()
    }
    .task {
      await model.loadMovieReleaseDays()
    }
  }

  /// One column. A plain VStack: an outer lazy stack of heterogeneous sections mis-estimated the content
  /// height (the sheet scrolled past the end); only the episode rows stay lazy.
  private var compactLayout: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        BrowseDetailTop(model: model)
        BrowseDetailEpisodes(model: model)
        BrowseDetailBottom(model: model)
        Color.clear.frame(height: 30)
      }
    }
    .scrollIndicators(.hidden)
  }

  /// Regular width: details on the left, the episode list in its own scroll view on the right.
  private func wideLayout(width: CGFloat) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          BrowseDetailTop(model: model)
          BrowseDetailBottom(model: model)
          Color.clear.frame(height: 30)
        }
      }
      .scrollIndicators(.hidden)
      .frame(width: width * 0.58)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Color.clear.frame(height: 50)
          BrowseDetailEpisodes(model: model)
          Color.clear.frame(height: 30)
        }
      }
      .scrollIndicators(.hidden)
      .frame(width: width * 0.42)
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
    // Esc closes the details with a hardware keyboard (checkClose of DetailsModal.svelte).
    .keyboardShortcut(.cancelAction)
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
    let media = model.live
    VStack(alignment: .leading, spacing: 16) {
      BrowseDetailHeader(media: media)
      BrowseDetailStats(media: media)
        .padding(.horizontal, 16)
      BrowseDetailActions(model: model)
        .padding(.horizontal, 16)
      if !model.following.isEmpty {
        BrowseFollowingRow(entries: model.following, profiles: model.followingProfiles, onOpen: {
          Task { await model.loadFollowingProfiles() }
        })
        .padding(.horizontal, 16)
      }
      BrowseDetailInfoStrip(media: media)
      BrowseDetailChips(media: media)
      BrowseDetailSynopsis(media: media)
        .padding(.horizontal, 16)
    }
  }
}
