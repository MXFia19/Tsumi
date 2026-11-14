import SwiftUI
import UIKit

// Display rules shared by the cards, the banner and the details (SmallCard / FullCard / PreviewCard /
// FullBanner / DetailsModal labels) and the user actions (playMedia of anime.js, details, favourite).

@MainActor
enum BrowseMediaInfo {
  static let watchingStatuses: [ListStatus] = [.current, .repeating, .paused, .dropped]

  /// anilistClient.title (userPreferred when logged into AniList, else the titleLang setting).
  static func title(_ media: Media) -> String {
    AniListService.shared.title(media)
  }

  /// Latest copy of a media (mediaCache) with its current list entry. Reads the list revision so the
  /// calling view refreshes after a list change.
  static func current(_ media: Media) -> Media {
    _ = MediaListService.shared.revision
    if let stored = MediaStore.shared.media(media.id) {
      return stored
    }
    var result = media
    if let entry = MediaListService.shared.entry(for: media) {
      result.listEntry = entry
    }
    return result
  }

  static func entry(_ media: Media) -> ListEntry? {
    _ = MediaListService.shared.revision
    return MediaListService.shared.entry(for: media)
  }

  /// getPlayButtonText: Watch Now / Continue Now / Rewatch Now.
  static func playButtonText(_ entry: ListEntry?) -> String {
    guard let entry, entry.progress > 0 else { return "Watch Now" }
    return entry.status == .completed ? "Rewatch Now" : "Continue Now"
  }

  /// Anime that are not released yet cannot be played (western titles can).
  static func isPlayable(_ media: Media) -> Bool {
    !(media.status == .notYetReleased && media.source != .tmdb)
  }

  /// Scoring.svelte is shown when logged in, for AniList media only (`typeof media.id !== 'string'`).
  static func canEditList(_ media: Media) -> Bool {
    ProfilesService.shared.isAuthorized && media.source == .anilist
  }

  /// Favourite button: AniList account and AniList media.
  static func canFavourite(_ media: Media) -> Bool {
    ProfilesService.shared.isAniList && media.source == .anilist
  }

  static func formatText(_ media: Media) -> String {
    AnimeCatalog.formatLabel(media.format)
  }

  /// SmallCard year: seasonYear, TBA (not released), start year, current year (releasing) or N/A.
  static func yearText(_ media: Media) -> String {
    if let year = media.seasonYear { return String(year) }
    if media.status == .notYetReleased { return "TBA" }
    if let start = media.startDate {
      return String(Calendar.current.component(.year, from: start))
    }
    if media.status == .releasing { return String(AnimeSeasonClock.currentYear) }
    return "N/A"
  }

  /// Season + year ("Fall 2024"), "In Production" for unreleased titles without a date, nil otherwise.
  static func seasonText(_ media: Media) -> String? {
    var parts: [String] = []
    if let season = media.season { parts.append(season.rawValue.capitalized) }
    if let year = media.seasonYear {
      parts.append(String(year))
    } else if let start = media.startDate {
      parts.append(String(Calendar.current.component(.year, from: start)))
    }
    if !parts.isEmpty { return parts.joined(separator: " ") }
    if media.status == .notYetReleased { return "In Production" }
    return nil
  }

  /// FullCard / PreviewCard episode badge ("3 / 12 Episodes", "12 Episodes", "24 Minutes").
  static func episodesText(_ media: Media, entry: ListEntry?) -> String? {
    let maxEpisode = AnimeHelpers.maxEpisode(media)
    let progress = entry?.progress ?? 0
    let inProgress = entry.map { watchingStatuses.contains($0.status) } == true && progress > 0
    if maxEpisode > 1 || (maxEpisode != 1 && inProgress) {
      let prefix = inProgress ? "\(progress) / " : ""
      let total = (maxEpisode != 0 && !(progress > maxEpisode)) ? String(maxEpisode) : "?"
      return "\(prefix)\(total) Episodes"
    }
    if let duration = media.duration { return "\(duration) Minutes" }
    return nil
  }

  /// FullBanner episode label ("3 / 12 Episodes" while watching).
  static func bannerEpisodesText(_ media: Media, entry: ListEntry?) -> String? {
    if let episodes = media.episodes, episodes != 1 {
      if let entry, entry.status == .current, entry.progress > 0 {
        return "\(entry.progress) / \(episodes) Episodes"
      }
      return "\(episodes) Episodes"
    }
    if let duration = media.duration { return "\(duration) Minutes" }
    return nil
  }

  static func youTubeThumbnails(_ id: String?) -> [URL?] {
    guard let id, !id.isEmpty else { return [] }
    return [
      URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"),
      URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    ]
  }

  /// Banner images: banner, trailer thumbnails, cover.
  static func bannerURLs(_ media: Media) -> [URL?] {
    [media.images.banner] + youTubeThumbnails(media.trailerYouTubeId) + [media.images.coverLarge, media.images.cover]
  }

  static func coverURLs(_ media: Media) -> [URL?] {
    [media.images.coverLarge, media.images.cover]
  }

  static func coverColor(_ media: Media) -> Color {
    BrowsePalette.color(hex: media.images.color) ?? BrowsePalette.tertiary.opacity(0.35)
  }

  /// Relations / recommendations adult filters (settings.adult none | hentai).
  static func passesAdultFilter(_ media: Media) -> Bool {
    let adult = AppSettings.shared.values.adult
    if adult == "none" && media.isAdult { return false }
    if adult != "hentai" && media.genres.contains("Hentai") { return false }
    return true
  }

  /// AniList / MyAnimeList / TMDB / IMDb pages of a media (share buttons of DetailsModal).
  static func links(_ media: Media) -> [BrowseExternalLink] {
    var result: [BrowseExternalLink] = []
    if media.source == .anilist, let id = media.anilistId, let url = URL(string: "https://anilist.co/anime/\(id)") {
      result.append(BrowseExternalLink(name: "AniList", url: url))
    }
    if media.source == .anilist, let id = media.malId, let url = URL(string: "https://myanimelist.net/anime/\(id)") {
      result.append(BrowseExternalLink(name: "MyAnimeList", url: url))
    }
    if let id = media.tmdbId {
      let type = media.tmdbType ?? (media.format == .movie ? .movie : .tv)
      if let url = URL(string: "https://www.themoviedb.org/\(type.rawValue)/\(id)") {
        result.append(BrowseExternalLink(name: "TMDB", url: url))
      }
    }
    if let imdb = media.imdbId, !imdb.isEmpty, let url = URL(string: "https://www.imdb.com/title/\(imdb)") {
      result.append(BrowseExternalLink(name: "IMDb", url: url))
    }
    return result
  }

  /// Countries of Details.svelte countryMap.
  static func countryName(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    let map: [String: String] = [
      "JP": "Japan", "KR": "South Korea", "US": "United States", "CN": "China", "HK": "Hong Kong",
      "TW": "Taiwan", "GB": "United Kingdom", "UK": "United Kingdom", "DE": "Germany", "FR": "France",
      "ES": "Spain", "IT": "Italy", "CA": "Canada", "AU": "Australia", "IN": "India"
    ]
    return map[code.uppercased()]
  }
}

struct BrowseExternalLink: Identifiable, Hashable {
  var id: String { name }
  let name: String
  let url: URL
}

/// User actions shared by every browse screen.
@MainActor
enum BrowseActions {
  /// Opens the details sheet (modal.open(ANIME_DETAILS)).
  static func open(_ media: Media) {
    AppRouter.shared.open(media)
  }

  /// playMedia of anime.js: continues after the list progress (zero episode aware), a completed entry
  /// becomes Rewatching from the start. `force` opens the extension picker (right click / long press).
  static func playMedia(_ media: Media, force: Bool = false) {
    guard BrowseMediaInfo.isPlayable(media) else { return }
    Task { @MainActor in
      let episode = await MediaListService.shared.startEpisode(for: media)
      PlaybackRequestCoordinator.shared.play(media: media, episode: EpisodeRef(number: episode, season: nil, localEpisode: nil), force: force)
    }
  }

  /// playAnime(media, episode, force).
  static func play(_ media: Media, episode: EpisodeRef, force: Bool = false) {
    PlaybackRequestCoordinator.shared.play(media: media, episode: episode, force: force)
  }

  static func play(_ media: Media, episodeNumber: Int, force: Bool = false) {
    play(media, episode: EpisodeRef(number: episodeNumber, season: nil, localEpisode: nil), force: force)
  }

  /// anilistClient.favourite: optimistic toggle, returns the new state.
  @discardableResult
  static func toggleFavourite(_ media: Media) -> Bool {
    Services.shared.details.toggleFavourite(media)
  }

  static func isFavourite(_ media: Media) -> Bool {
    Services.shared.details.isFavourite(media)
  }

  /// copyToClipboard of clipboard.js.
  static func copy(_ url: URL, detail: String) {
    UIPasteboard.general.string = url.absoluteString
    ServiceMessages.shared.post(.info, "Copied to clipboard", "Copied \(detail) to clipboard")
  }
}
