import SwiftUI

// Media cards: Card.svelte dispatch, SmallCard.svelte, FullCard.svelte, PreviewCard.svelte (long-press
// preview with its actions) and the cover labels of AudioLabel.svelte (cardAudio setting).

enum BrowseCardStyle: Hashable {
  case small
  case full
}

/// Card.svelte: a media card (small or full) that opens the details on tap and shows the PreviewCard on
/// long press (context menu with play, details, extension picker, list editor and favourite).
@MainActor
struct BrowseMediaCard: View {
  let media: Media
  var style: BrowseCardStyle = .small
  /// Relation type ("sequel") or recommendation label shown above the title (SmallCard `type`).
  var typeLabel: String?
  /// Airing countdown (Schedule page, SmallCard `scheduleList`).
  var airing: AiringEpisode?
  var width: CGFloat?
  /// Recommendation rating ("12 likes" with a thumb, SmallCard numeric `type`).
  var likes: Int? = nil
  @State private var showEditor = false

  var body: some View {
    let current = BrowseMediaInfo.current(media)
    decorated(current)
      .sheet(isPresented: $showEditor) {
        BrowseListEditor(media: current)
      }
  }

  private func button(_ current: Media) -> some View {
    Button {
      BrowseActions.open(current)
    } label: {
      label(current)
    }
    .buttonStyle(BrowsePressableStyle())
    // Hardware keyboard: Return on the focused card opens the details.
    .focusable()
    .onKeyPress(.return) {
      BrowseActions.open(current)
      return .handled
    }
  }

  @ViewBuilder
  private func label(_ current: Media) -> some View {
    switch style {
    case .small:
      BrowseSmallCard(media: current, typeLabel: typeLabel, airing: airing, width: width, likes: likes)
    case .full:
      BrowseFullCard(media: current, airing: airing, width: width)
    }
  }

  @ViewBuilder
  private func decorated(_ current: Media) -> some View {
    if AppSettings.shared.values.cardPreview {
      button(current)
        .contextMenu {
          BrowseMediaMenuItems(media: current, onEditList: { showEditor = true })
        } preview: {
          BrowsePreviewCard(media: current, typeLabel: typeLabel)
        }
    } else {
      button(current)
        .contextMenu {
          BrowseMediaMenuItems(media: current, onEditList: { showEditor = true })
        }
    }
  }
}

/// Actions of the PreviewCard (play, list editor, favourite) plus "View Details" and the extension picker.
@MainActor
struct BrowseMediaMenuItems: View {
  let media: Media
  let onEditList: () -> Void

  var body: some View {
    let entry = BrowseMediaInfo.entry(media)
    Button {
      BrowseActions.playMedia(media)
    } label: {
      Label(BrowseMediaInfo.playButtonText(entry), systemImage: "play.fill")
    }
    .disabled(!BrowseMediaInfo.isPlayable(media))
    Button {
      BrowseActions.open(media)
    } label: {
      Label("View Details", systemImage: "info.circle")
    }
    Button {
      BrowseActions.playMedia(media, force: true)
    } label: {
      Label("Choose Extension", systemImage: "puzzlepiece.extension")
    }
    .disabled(!BrowseMediaInfo.isPlayable(media))
    if BrowseMediaInfo.canEditList(media) {
      Button {
        onEditList()
      } label: {
        Label("List Editor", systemImage: entry == nil ? "bookmark" : "square.and.pencil")
      }
    }
    if BrowseMediaInfo.canFavourite(media) {
      BrowseFavouriteMenuButton(media: media)
    }
  }
}

/// Favourite / Unfavourite entry of the context menus.
@MainActor
struct BrowseFavouriteMenuButton: View {
  let media: Media

  var body: some View {
    let favourite = BrowseActions.isFavourite(media)
    let title: String = favourite ? "Unfavourite" : "Favourite"
    Button {
      BrowseActions.toggleFavourite(media)
    } label: {
      Label(title, systemImage: favourite ? "heart.slash" : "heart")
    }
  }
}

/// "Episode 5 in 2d 3h 4m" (getAiringInfo), green and "out for" once aired; "Episode 5 ~ 7" when several
/// episodes air at once; "Episode 5 is Suspended" for a suspended dub.
@MainActor
struct BrowseAiringLine: View {
  let episode: Int
  let airingAt: Date
  var showTime = false
  var alignment: HorizontalAlignment = .center
  /// Last episode airing at the same time (range "Episode 5 ~ 7").
  var lastEpisode: Int? = nil
  /// Dub production suspended (delayedIndefinitely): "Suspended" instead of a countdown.
  var suspended = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let seconds = airingAt.timeIntervalSince(context.date)
      let aired = !suspended && seconds <= 0
      let range = (lastEpisode ?? 0) > episode ? "Episode \(episode) ~ \(lastEpisode ?? episode)" : "Episode \(episode)"
      let prefix = range + " " + (suspended ? "is" : (aired ? "out for" : "in"))
      VStack(alignment: alignment, spacing: 2) {
        HStack(spacing: 4) {
          Text(prefix)
            .foregroundStyle(BrowsePalette.muted)
          Text(suspended ? "Suspended" : ServiceText.countdown(seconds))
            .fontWeight(.bold)
            .foregroundStyle(aired ? BrowsePalette.success : Color.white)
        }
        if showTime && !suspended {
          Text(BrowseText.time(airingAt))
            .foregroundStyle(BrowsePalette.dimmed)
        }
      }
      .font(.caption)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
    }
  }
}

/// "AIRING" badge of the cards, with the airing-pulse ring of SmallCard.svelte. The pulse is a
/// PhaseAnimator scoped to the ring (no repeatForever transaction that could move the layout).
struct BrowseAiringBadge: View {
  var body: some View {
    Text("AIRING")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(BrowsePalette.success, in: Capsule())
      .background {
        Capsule()
          .stroke(BrowsePalette.success, lineWidth: 2)
          .phaseAnimator([false, true]) { ring, expanded in
            ring
              .scaleEffect(expanded ? 1.6 : 1)
              .opacity(expanded ? 0 : 0.9)
          } animation: { expanded in
            expanded ? Animation.easeOut(duration: 3.5) : nil
          }
          .allowsHitTesting(false)
      }
  }
}

/// Loads the dub schedule and the dub episode feed once for every audio label (the dub episode counts).
@MainActor
enum BrowseDubFeed {
  private static var task: Task<Void, Never>?

  static func load() async {
    if let existing = Self.task {
      await existing.value
      return
    }
    let created = Task {
      _ = await AnimeScheduleService.shared.airedList(.dub)
      _ = await AnimeScheduleService.shared.dubAiringList()
    }
    Self.task = created
    await created.value
  }
}

/// AudioLabel.svelte (cover mode, only with the cardAudio setting): playable / aired episodes, dub with the
/// aired dub episode count, partial dub, progress, adult.
@MainActor
struct BrowseAudioLabel: View {
  let media: Media
  /// Set once the dub feed is loaded so the counts refresh.
  @State private var feedLoaded = false

  var body: some View {
    if ServiceSettingsExtras.cardAudio && media.source == .anilist {
      labels
        .task(id: media.id) {
          await loadDubFeed()
        }
    }
  }

  private var labels: some View {
    let refreshed = feedLoaded
    let dubs = Services.shared.dubs
    let dubbed = dubs.isFullyDubbed(malId: media.malId)
    let partial = dubs.isIncomplete(malId: media.malId)
    let dubEpisodes = Self.dubEpisodes(media, dubbed: dubbed, partial: partial, refreshed: refreshed)
    let playable = (media.status != .notYetReleased && media.status != .cancelled) ? AnimeHelpers.maxEpisode(media, playable: media.status != .finished) : 0
    // subEpisodes falls back to the dub count, and the larger of the two is shown.
    let subCount = max(playable, dubEpisodes)
    return HStack(spacing: 2) {
      if media.isAdult {
        label(systemImage: "exclamationmark.triangle.fill", text: nil, color: BrowsePalette.adult)
      }
      if partial && dubEpisodes <= 0 {
        label(systemImage: "mic.slash.fill", text: nil, color: BrowsePalette.partialDub)
      }
      if let progress = media.listEntry?.progress, progress > 0 {
        label(systemImage: "clock", text: String(progress), color: BrowsePalette.status(.current))
      }
      if dubbed || (partial && dubEpisodes > 0) {
        label(systemImage: dubbed ? "mic.fill" : "mic.slash.fill", text: dubEpisodes > 0 ? String(dubEpisodes) : nil, color: partial ? BrowsePalette.partialDub : BrowsePalette.dub)
      }
      label(systemImage: "captions.bubble.fill", text: subCount > 0 ? String(subCount) : nil, color: BrowsePalette.sub)
    }
  }

  /// dubEpisodes of AudioLabel.svelte: aired dub episodes of a dubbed title, else the episode count of an
  /// older finished title without an unaired dub entry; 0 when unknown.
  static func dubEpisodes(_ media: Media, dubbed: Bool, partial: Bool, refreshed: Bool = false) -> Int {
    guard media.malId != nil, let id = media.anilistId else { return 0 }
    let schedule = AnimeScheduleService.shared
    if dubbed || partial, let aired = schedule.loadedDubAiredCount(anilistId: id), aired > 0 {
      return aired
    }
    let unaired = schedule.loadedDubAiringList()?.contains { $0.unaired == true && $0.anime?.id == id } ?? false
    if !partial && media.status != .releasing && media.status != .notYetReleased && (media.seasonYear ?? 0) < 2025 && !unaired {
      return AnimeHelpers.maxEpisode(media)
    }
    return 0
  }

  private func loadDubFeed() async {
    guard media.malId != nil else { return }
    let schedule = AnimeScheduleService.shared
    if schedule.loadedAiredList(.dub) != nil && schedule.loadedDubAiringList() != nil { return }
    await BrowseDubFeed.load()
    if Task.isCancelled { return }
    feedLoaded = true
  }

  private func label(systemImage: String, text: String?, color: Color) -> some View {
    HStack(spacing: 2) {
      Image(systemName: systemImage)
      if let text {
        Text(text)
      }
    }
    .font(.system(size: 10, weight: .bold))
    .foregroundStyle(.black)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
  }
}

/// SmallCard.svelte.
@MainActor
struct BrowseSmallCard: View {
  let media: Media
  var typeLabel: String?
  var airing: AiringEpisode?
  var width: CGFloat?
  /// Recommendation rating: thumb up (green, muted at 0) or down with "N likes".
  var likes: Int? = nil

  static let coverRatio: CGFloat = 230.0 / 331.0

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let airing {
        BrowseAiringLine(episode: airing.episode, airingAt: airing.airingAt, showTime: true, lastEpisode: airing.lastEpisode, suspended: airing.delayedIndefinitely)
          .frame(maxWidth: .infinity)
      }
      cover
      if let likes {
        likesRow(likes)
      } else if let typeLabel {
        Text(BrowseText.capitalizedWords(typeLabel))
          .font(.caption.weight(.semibold))
          .foregroundStyle(BrowsePalette.success)
          .lineLimit(1)
      }
      titleRow
      Spacer(minLength: 0)
      footer
    }
    .frame(width: width, alignment: .topLeading)
    .contentShape(Rectangle())
  }

  private var aired: Bool {
    guard let airing, !airing.delayedIndefinitely else { return false }
    return airing.airingAt <= Date()
  }

  /// "12 likes" / "1 like" / "3 dislikes" (SmallCard numeric type).
  private func likesRow(_ value: Int) -> some View {
    let count = abs(value)
    let word = value >= 0 ? "like" : "dislike"
    let text = BrowseText.number(count) + " " + word + (count == 1 ? "" : "s")
    return HStack(spacing: 4) {
      Image(systemName: value >= 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
        .foregroundStyle(value > 0 ? BrowsePalette.success : (value == 0 ? BrowsePalette.muted : BrowsePalette.danger))
      Text(text)
        .foregroundStyle(.white)
    }
    .font(.caption.weight(.semibold))
    .lineLimit(1)
  }

  private var cover: some View {
    BrowseImage(BrowseMediaInfo.coverURLs(media), placeholder: BrowseMediaInfo.coverColor(media))
      .aspectRatio(Self.coverRatio, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(alignment: .topTrailing) {
        if aired {
          BrowseAiringBadge().padding(4)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if airing == nil {
          BrowseAudioLabel(media: media).padding(4)
        }
      }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let status = media.listEntry?.status {
        BrowseListStatusDot(status: status)
      }
      Text(BrowseMediaInfo.title(media))
        .font(.subheadline.weight(.heavy))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack(spacing: 4) {
      Image(systemName: "calendar")
      Text(BrowseMediaInfo.yearText(media))
      Spacer(minLength: 4)
      Text(BrowseMediaInfo.formatText(media))
        .lineLimit(1)
      Image(systemName: "tv")
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(BrowsePalette.muted)
  }
}

/// FullCard.svelte.
@MainActor
struct BrowseFullCard: View {
  let media: Media
  var airing: AiringEpisode?
  var width: CGFloat?

  static let height: CGFloat = 186

  var body: some View {
    HStack(spacing: 0) {
      cover
      VStack(alignment: .leading, spacing: 6) {
        titleRow
        BrowseMediaChips(media: media, showReviews: true)
        if let airing {
          BrowseAiringLine(episode: airing.episode, airingAt: airing.airingAt, showTime: true, alignment: .leading, lastEpisode: airing.lastEpisode, suspended: airing.delayedIndefinitely)
        }
        description
        Spacer(minLength: 0)
        genres
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: width, height: Self.height)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
  }

  private var cover: some View {
    BrowseImage(BrowseMediaInfo.coverURLs(media), placeholder: BrowseMediaInfo.coverColor(media))
      .frame(width: Self.height * 0.66, height: Self.height)
      .overlay(alignment: .topLeading) {
        if let airing, !airing.delayedIndefinitely, airing.airingAt <= Date() {
          BrowseAiringBadge().padding(4)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if airing == nil {
          BrowseAudioLabel(media: media).padding(4)
        }
      }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let status = media.listEntry?.status {
        BrowseListStatusDot(status: status)
      }
      Text(BrowseMediaInfo.title(media))
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
  }

  @ViewBuilder
  private var description: some View {
    let text = BrowseText.plain(media.description)
    if !text.isEmpty {
      Text(text)
        .font(.caption2)
        .foregroundStyle(BrowsePalette.muted)
        .lineLimit(4)
        .multilineTextAlignment(.leading)
    }
  }

  @ViewBuilder
  private var genres: some View {
    if !media.genres.isEmpty {
      let color = BrowsePalette.color(hex: media.images.color) ?? BrowsePalette.tertiary
      HStack(spacing: 4) {
        ForEach(Array(media.genres.prefix(3)), id: \.self) { genre in
          BrowseChip(text: genre, background: color, foreground: .black, font: .system(size: 10, weight: .bold))
        }
      }
    }
  }
}

/// Badges of the full / preview cards: format, episodes, Rated 18+, season, rating, reviews.
@MainActor
struct BrowseMediaChips: View {
  let media: Media
  var showReviews = true
  var font: Font = .system(size: 10, weight: .semibold)

  var body: some View {
    let entry = media.listEntry
    BrowseFlowLayout(spacing: 4, lineSpacing: 4) {
      BrowseChip(text: BrowseMediaInfo.formatText(media), font: font)
      if let episodes = BrowseMediaInfo.episodesText(media, entry: entry) {
        BrowseChip(text: episodes, font: font)
      }
      if media.isAdult {
        BrowseChip(text: "Rated 18+", font: font)
      }
      if let season = BrowseMediaInfo.seasonText(media) {
        BrowseChip(text: season, font: font)
      }
      if media.status == .notYetReleased && media.season == nil && media.seasonYear == nil {
        BrowseChip(text: "Not Released", font: font)
      }
      if let score = media.averageScore {
        BrowseChip(text: "\(score)% Rating", font: font)
        if showReviews {
          let reviews = Services.shared.details.reviews(media)
          if reviews != "?" {
            BrowseChip(text: "\(reviews) Reviews", font: font)
          }
        }
      }
    }
  }
}

/// PreviewCard.svelte (shown as the context menu preview).
@MainActor
struct BrowsePreviewCard: View {
  let media: Media
  var typeLabel: String?

  var body: some View {
    let entry = media.listEntry
    VStack(alignment: .leading, spacing: 10) {
      BrowseImage(BrowseMediaInfo.bannerURLs(media), placeholder: Color.black)
        .frame(width: 340, height: 191)
        .overlay(alignment: .bottom) {
          LinearGradient(colors: [Color.clear, Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            .frame(height: 60)
        }
      VStack(alignment: .leading, spacing: 8) {
        Text(BrowseMediaInfo.title(media))
          .font(.title3.bold())
          .foregroundStyle(.white)
          .lineLimit(1)
        playRow(entry)
        if let typeLabel {
          BrowseChip(text: BrowseText.capitalizedWords(typeLabel))
        }
        BrowseMediaChips(media: media, showReviews: typeLabel == nil, font: .caption.weight(.semibold))
        Text(BrowseText.plain(media.description))
          .font(.footnote)
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(6)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)
    }
    .frame(width: 340)
    .background(Color(white: 0.1))
  }

  private func playRow(_ entry: ListEntry?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "play.fill")
      Text(BrowseMediaInfo.playButtonText(entry))
        .fontWeight(.bold)
    }
    .font(.subheadline)
    .foregroundStyle(.black)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(BrowseMediaInfo.isPlayable(media) ? BrowsePalette.secondary : BrowsePalette.secondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
