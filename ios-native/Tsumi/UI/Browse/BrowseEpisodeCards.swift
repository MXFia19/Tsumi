import SwiftUI

// EpisodeCard.svelte and EpisodePreviewCard.svelte: cards of the episode feeds (Recent Subs / Dubs /
// Hentai, Western - Recent TV Episodes) and of the image search results (trace.moe, "Confidence: x%").

/// One episode card (feed entry or trace.moe match).
struct BrowseEpisodeCardData: Identifiable, Hashable {
  let id: String
  var media: Media
  var episode: Int?
  var date: Date?
  var dub: Bool = false
  var episodeTitle: String?
  var thumbnail: URL?
  /// trace.moe similarity (0-1).
  var similarity: Double?
  /// Episode summary (EpisodePreviewCard: episodeData.summary / overview).
  var summary: String? = nil
  /// Last episode of a batch release ("Episodes 1 ~ 3").
  var lastEpisode: Int? = nil
  /// Release name of the source (parseObject.anime_title), used for the "Season N" label of batches.
  var releaseTitle: String? = nil

  init(feed: EpisodeFeedItem) {
    id = feed.id
    media = feed.media
    episode = feed.episode
    date = feed.date
    dub = feed.dub
    episodeTitle = feed.episodeTitle
    thumbnail = feed.thumbnail
    similarity = nil
    summary = feed.summary
    lastEpisode = feed.lastEpisode
  }

  init(trace: TraceMoeMatch) {
    id = trace.id
    media = trace.media
    episode = trace.episode
    date = nil
    dub = false
    episodeTitle = trace.episodeTitle
    thumbnail = trace.image ?? trace.thumbnail
    similarity = trace.similarity
  }
}

/// Episode state derived from the list entry (EpisodeCard.svelte reactive statements).
@MainActor
struct BrowseEpisodeCardState {
  let media: Media
  let data: BrowseEpisodeCardData

  init(data: BrowseEpisodeCardData) {
    self.data = data
    self.media = BrowseMediaInfo.current(data.media)
  }

  var entry: ListEntry? { media.listEntry }

  /// lastEpisode: the last episode of a batch, the episode, or 1 for single episode media.
  var lastEpisode: Int? {
    if let last = data.lastEpisode, let first = data.episode, last > first { return last }
    if let episode = data.episode { return episode }
    return media.episodes == 1 ? 1 : nil
  }

  /// Episode played by a tap (the first episode of a batch).
  var playEpisode: Int? {
    if let episode = data.episode { return episode }
    return media.episodes == 1 ? 1 : nil
  }

  /// "Episodes 1 ~ 3" range of a batch, nil for a single episode.
  var episodeRange: (first: Int, last: Int)? {
    guard let first = data.episode, let last = data.lastEpisode, last > first else { return nil }
    return (first, last)
  }

  /// Duration of the episode (times the number of episodes of a batch).
  var durationMinutes: Int? {
    guard let duration = media.duration else { return nil }
    if let range = episodeRange { return duration * (range.last - range.first + 1) }
    return duration
  }

  /// Hentai titles without episode image nor banner show their cover rotated (cover-rotated).
  var rotatedCover: Bool {
    data.thumbnail == nil && media.images.banner == nil && media.genres.contains("Hentai")
  }

  /// Preview text: the episode summary, else the media description.
  var summaryText: String {
    let summary = BrowseText.plain(data.summary)
    return summary.isEmpty ? BrowseText.plain(media.description) : summary
  }

  var watched: Bool { entry?.status == .completed }

  var completed: Bool {
    guard !watched, let lastEpisode, let progress = entry?.progress else { return false }
    return progress >= lastEpisode
  }

  /// Hides episode thumbnails (spoilers) of watched-list titles that did not reach this episode yet.
  var thumbnailURLs: [URL?] {
    var showEpisodeImage = true
    if data.similarity == nil, let entry, let lastEpisode {
      let followed: [ListStatus] = [.current, .repeating, .paused, .planning]
      if followed.contains(entry.status) && entry.progress < lastEpisode { showEpisodeImage = false }
    }
    var urls: [URL?] = []
    if showEpisodeImage { urls.append(data.thumbnail) }
    urls.append(media.images.banner)
    urls.append(media.images.coverLarge)
    urls.append(media.images.cover)
    return urls
  }

  var progressPercent: Int {
    guard let episode = data.episode else { return 0 }
    return Services.shared.progress.episodeProgress(mediaKey: media.id, episode: episode, completed: completed) ?? 0
  }

  /// EpisodeCard.svelte label: "Episodes 1 ~ 3", "Episode 5", "Movie", "Season 2" or "Batch".
  var episodeLabel: String {
    if let range = episodeRange { return "Episodes \(range.first) ~ \(range.last)" }
    if let episode = data.episode { return "Episode \(episode)" }
    if media.format == .movie { return "Movie" }
    if let season = Self.seasonNumber(data.releaseTitle) { return "Season \(season)" }
    return data.similarity == nil ? "Batch" : ""
  }

  /// `anime_title.match(/S(\d{2})/)` of EpisodeCard.svelte.
  static func seasonNumber(_ title: String?) -> Int? {
    guard let title, let range = title.range(of: "S[0-9]{2}", options: .regularExpression) else { return nil }
    return Int(String(title[range].dropFirst()))
  }

  /// AudioLabel banner/episode mode: Dub / Partial Dub / Sub, only with the Card Audio setting.
  var audioLabel: String? {
    if data.similarity != nil { return nil }
    if !ServiceSettingsExtras.cardAudio { return nil }
    if data.dub {
      return Services.shared.dubs.isIncomplete(malId: media.malId) ? "Partial Dub" : "Dub"
    }
    return "Sub"
  }

  /// "x ago" or "Confidence: 93%".
  func secondaryText(now: Date) -> String? {
    if let date = data.date { return ServiceText.since(date) }
    if let similarity = data.similarity { return "Confidence: \(Int((similarity * 100).rounded()))%" }
    return nil
  }

  /// The "Continue Anyway?" prompt is shown when earlier episodes were not watched.
  var needsPrompt: Bool {
    guard data.similarity == nil, let episode = playEpisode else { return false }
    if episode - 1 < 1 { return false }
    if entry?.status == .completed { return false }
    return (entry?.progress ?? -1) < episode - 1
  }

  var promptTitle: String {
    guard let progress = entry?.progress, progress > 0 else { return "You Haven't Watched Any Episodes Yet!" }
    return "Your Current Progress Is At Episode \(progress)"
  }
}

/// EpisodeCard.svelte: tap plays the episode (with the progress prompt), long press shows the preview.
@MainActor
struct BrowseEpisodeCard: View {
  let data: BrowseEpisodeCardData
  var width: CGFloat?
  @State private var showPrompt = false

  var body: some View {
    let state = BrowseEpisodeCardState(data: data)
    Button {
      tap(state)
    } label: {
      BrowseEpisodeCardContent(state: state)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
    .buttonStyle(BrowsePressableStyle())
    // Hardware keyboard: Return on the focused card plays it (or opens the details).
    .focusable()
    .onKeyPress(.return) {
      tap(state)
      return .handled
    }
    .contextMenu {
      menuItems(state)
    } preview: {
      BrowseEpisodePreviewCard(state: state)
    }
    .alert(state.promptTitle, isPresented: $showPrompt) {
      Button("Continue Anyway?") {
        play(state, force: false)
      }
      Button("View Details") {
        BrowseActions.open(state.media)
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder
  private func menuItems(_ state: BrowseEpisodeCardState) -> some View {
    if state.playEpisode != nil {
      let playTitle: String = state.episodeLabel.isEmpty ? "Play" : "Play " + state.episodeLabel
      Button {
        play(state, force: false)
      } label: {
        Label(playTitle, systemImage: "play.fill")
      }
      Button {
        play(state, force: true)
      } label: {
        Label("Choose Extension", systemImage: "puzzlepiece.extension")
      }
    }
    Button {
      BrowseActions.open(state.media)
    } label: {
      Label("View Details", systemImage: "info.circle")
    }
  }

  private func tap(_ state: BrowseEpisodeCardState) {
    if state.needsPrompt {
      showPrompt = true
    } else if state.playEpisode != nil {
      play(state, force: false)
    } else {
      BrowseActions.open(state.media)
    }
  }

  private func play(_ state: BrowseEpisodeCardState, force: Bool) {
    guard let episode = state.playEpisode else {
      BrowseActions.open(state.media)
      return
    }
    BrowseActions.play(state.media, episodeNumber: episode, force: force)
  }
}

/// Visual part of EpisodeCard.svelte.
@MainActor
struct BrowseEpisodeCardContent: View {
  let state: BrowseEpisodeCardState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      BrowseEpisodeThumbnail(state: state, height: 168)
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          titleRow
          Text(state.data.episodeTitle ?? "")
            .font(.caption)
            .foregroundStyle(BrowsePalette.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 3) {
          Text(state.episodeLabel)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
          BrowseEpisodeMetaLine(state: state)
        }
      }
    }
    .opacity(state.completed ? 0.3 : 1)
    .contentShape(Rectangle())
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let status = state.entry?.status {
        BrowseListStatusDot(status: status)
      }
      Text(BrowseMediaInfo.title(state.media))
        .font(.subheadline.weight(.heavy))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
  }
}

/// "Dub • 3 hours ago" line, refreshed every minute.
@MainActor
struct BrowseEpisodeMetaLine: View {
  let state: BrowseEpisodeCardState

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let parts = [state.audioLabel, state.secondaryText(now: context.date)].compactMap { $0 }
      Text(parts.joined(separator: " \u{2022} "))
        .font(.caption)
        .foregroundStyle(BrowsePalette.muted)
        .lineLimit(1)
    }
  }
}

/// Thumbnail with gradient, play icon, duration and watch progress.
@MainActor
struct BrowseEpisodeThumbnail: View {
  let state: BrowseEpisodeCardState
  var height: CGFloat

  var body: some View {
    image
      .frame(height: height)
      .frame(maxWidth: .infinity)
      .overlay {
        LinearGradient(colors: [Color.clear, Color.black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
      }
      .overlay(alignment: .bottomLeading) {
        Image(systemName: "play.fill")
          .font(.title3)
          .foregroundStyle(.white)
          .padding(10)
      }
      .overlay(alignment: .bottomTrailing) {
        if let duration = state.durationMinutes {
          Text("\(duration)m")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(10)
        }
      }
      .overlay(alignment: .bottom) {
        progressBar
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  @ViewBuilder
  private var image: some View {
    if state.rotatedCover {
      BrowseRotatedCover(urls: BrowseMediaInfo.coverURLs(state.media), placeholder: BrowseMediaInfo.coverColor(state.media))
    } else {
      BrowseImage(state.thumbnailURLs, placeholder: BrowseMediaInfo.coverColor(state.media))
    }
  }

  @ViewBuilder
  private var progressBar: some View {
    if state.completed {
      BrowseProgressBar(percent: 100, height: 2)
    } else {
      let percent = state.progressPercent
      if percent > 0 {
        BrowseProgressBar(percent: Double(percent), height: 2)
      }
    }
  }
}

/// EpisodePreviewCard.svelte (context menu preview).
@MainActor
struct BrowseEpisodePreviewCard: View {
  let state: BrowseEpisodeCardState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      BrowseEpisodeThumbnail(state: state, height: 200)
      VStack(alignment: .leading, spacing: 8) {
        header
        Text(summary)
          .font(.footnote)
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(3)
        footer
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 14)
    }
    .frame(width: 360)
    .background(Color(white: 0.1))
  }

  private var summary: String {
    state.summaryText
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          if let status = state.entry?.status {
            BrowseListStatusDot(status: status)
          }
          Text(BrowseMediaInfo.title(state.media))
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        if let title = state.data.episodeTitle, !title.isEmpty {
          Text(title)
            .font(.caption)
            .foregroundStyle(BrowsePalette.muted)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 3) {
        Text(state.episodeLabel)
          .font(.subheadline.weight(.heavy))
          .foregroundStyle(.white)
        BrowseEpisodeMetaLine(state: state)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 4) {
      Image(systemName: "calendar")
      Text(state.media.seasonYear.map { String($0) } ?? "N/A")
      Spacer()
      Text(BrowseMediaInfo.formatText(state.media))
      Image(systemName: "tv")
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(BrowsePalette.muted)
  }
}
