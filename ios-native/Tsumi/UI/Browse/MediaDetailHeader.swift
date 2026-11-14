import SwiftUI

// Top of DetailsModal.svelte: banner, cover, title, rating / format / episodes / reviews, play button,
// list editor (Scoring.svelte), favourite, trailer (TrailerModal.svelte), share links, friends
// (Following.svelte + User.svelte), the details strip (Details.svelte), tags, genres and the synopsis.

/// Banner, cover, title and alternative titles.
@MainActor
struct BrowseDetailHeader: View {
  let media: Media

  static let bannerHeight: CGFloat = 300

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      BrowseImage(BrowseMediaInfo.bannerURLs(media), placeholder: Color.black)
        .frame(height: Self.bannerHeight)
        .frame(maxWidth: .infinity)
        .overlay {
          LinearGradient(
            stops: [
              .init(color: Color.black.opacity(0.1), location: 0),
              .init(color: Color.black.opacity(0.45), location: 0.55),
              .init(color: Color.black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      HStack(alignment: .bottom, spacing: 14) {
        cover
        titles
      }
      .padding(.horizontal, 16)
      .offset(y: 40)
    }
    .padding(.bottom, 40)
  }

  private var cover: some View {
    BrowseImage(BrowseMediaInfo.coverURLs(media), placeholder: BrowseMediaInfo.coverColor(media))
      .frame(width: 112, height: 160)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(alignment: .bottomTrailing) {
        BrowseAudioLabel(media: media).padding(4)
      }
      .shadow(color: Color.black.opacity(0.6), radius: 8)
  }

  private var titles: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(BrowseMediaInfo.title(media))
        .font(.title2.weight(.heavy))
        .foregroundStyle(.white)
        .lineLimit(3)
        .textSelection(.enabled)
      if !alternativeTitles.isEmpty {
        Text(alternativeTitles)
          .font(.footnote)
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(2)
          .textSelection(.enabled)
      }
    }
  }

  /// Other titles (english / romaji / native and synonyms) without the displayed one.
  private var alternativeTitles: String {
    let shown = BrowseMediaInfo.title(media)
    var seen = Set<String>([shown.lowercased()])
    var result: [String] = []
    for title in [media.title.english, media.title.romaji, media.title.native].compactMap({ $0 }) + media.synonyms {
      let key = title.lowercased()
      if title.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      result.append(title)
    }
    return result.joined(separator: " \u{00B7} ")
  }
}

/// Rating / Format / Episodes or Length / Reviews line.
@MainActor
struct BrowseDetailStats: View {
  let media: Media

  var body: some View {
    BrowseFlowLayout(spacing: 14, lineSpacing: 8) {
      if let score = media.averageScore {
        stat("chart.line.uptrend.xyaxis", "Rating: \(score)%")
      }
      if media.format != .unknown {
        stat("tv", "Format: \(BrowseMediaInfo.formatText(media))")
      }
      if media.episodes != 1 {
        let maxEpisode = AnimeHelpers.maxEpisode(media)
        stat("film.stack", "Episodes: \(maxEpisode > 0 ? String(maxEpisode) : "?")")
      } else if let duration = media.duration {
        stat("timer", "Length: \(duration) min")
      }
      if media.averageScore != nil {
        let reviews = Services.shared.details.reviews(media)
        if reviews != "?" {
          stat("person.2", "Reviews: \(reviews)")
        }
      }
    }
  }

  private func stat(_ systemImage: String, _ text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text)
    }
    .font(.subheadline)
    .foregroundStyle(.white)
  }
}

/// Play, list editor, favourite, trailer and share buttons.
@MainActor
struct BrowseDetailActions: View {
  let model: BrowseDetailModel
  @State private var showTrailer = false

  var body: some View {
    let media = model.media
    let entry = BrowseMediaInfo.entry(media)
    VStack(alignment: .leading, spacing: 10) {
      Button {
        BrowseActions.playMedia(media)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "play.fill")
          Text(BrowseMediaInfo.playButtonText(entry))
            .fontWeight(.bold)
        }
        .font(.headline)
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(BrowsePalette.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(media.status == .notYetReleased)
      .opacity(media.status == .notYetReleased ? 0.5 : 1)
      .contextMenu {
        Button {
          BrowseActions.playMedia(media, force: true)
        } label: {
          Label("Choose Extension", systemImage: "puzzlepiece.extension")
        }
      }
      HStack(spacing: 10) {
        if BrowseMediaInfo.canEditList(media) {
          BrowseListEditorButton(media: media)
        }
        if BrowseMediaInfo.canFavourite(media) {
          BrowseFavouriteButton(media: media)
        }
        if let trailerId = model.trailerId {
          trailerButton(trailerId, media: media)
        }
        ForEach(BrowseMediaInfo.links(media)) { link in
          BrowseShareLinkButton(link: link)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func trailerButton(_ trailerId: String, media: Media) -> some View {
    Button {
      showTrailer = true
    } label: {
      Image(systemName: "play.tv")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Watch Trailer")
    .sheet(isPresented: $showTrailer) {
      BrowseTrailerSheet(videoId: trailerId, title: BrowseMediaInfo.title(media), fallbackImages: [media.images.banner, media.images.coverLarge])
    }
  }
}

/// Share to Clipboard / share sheet / open in the browser (the right click of the Svelte buttons).
@MainActor
struct BrowseShareLinkButton: View {
  let link: BrowseExternalLink
  @Environment(\.openURL) private var openURL

  private var shortName: String {
    switch link.name {
    case "AniList": return "AL"
    case "MyAnimeList": return "MAL"
    default: return link.name
    }
  }

  var body: some View {
    Menu {
      Button {
        BrowseActions.copy(link.url, detail: "share URL")
      } label: {
        Label("Share to Clipboard", systemImage: "doc.on.doc")
      }
      ShareLink(item: link.url) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      Button {
        openURL(link.url)
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
    } label: {
      Text(shortName)
        .font(.system(size: 12, weight: .heavy))
        .foregroundStyle(.white)
        .frame(minWidth: 44, minHeight: 44)
        .padding(.horizontal, shortName.count > 3 ? 6 : 0)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .accessibilityLabel(link.name)
  }
}

/// Following.svelte: avatars of the followed users who have the title (11 shown, then "+N").
@MainActor
struct BrowseFollowingRow: View {
  let entries: [AniListFollowingEntry]
  @State private var selectedId: Int? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: -10) {
        ForEach(Array(entries.prefix(11))) { entry in
          Button {
            selectedId = selectedId == entry.id ? nil : entry.id
          } label: {
            BrowseUserAvatar(entry: entry, size: 44)
          }
          .buttonStyle(.plain)
          .zIndex(selectedId == entry.id ? 1 : 0)
        }
        if entries.count > 11 {
          Text("+\(entries.count - 11)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color(white: 0.18), in: Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.9), lineWidth: 3))
        }
      }
      if let selected = entries.first(where: { $0.id == selectedId }) {
        BrowseUserCard(entry: selected)
      }
    }
  }
}

struct BrowseUserAvatar: View {
  let entry: AniListFollowingEntry
  var size: CGFloat

  private var initials: String {
    let parts = entry.name.split(separator: " ").prefix(2)
    return parts.compactMap { $0.first }.map { String($0) }.joined().uppercased()
  }

  var body: some View {
    ZStack {
      Circle().fill(Color(white: 0.18))
      if entry.avatar != nil {
        BrowseImage([entry.avatar], placeholder: Color(white: 0.18))
          .clipShape(Circle())
      } else {
        Text(initials)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
    .overlay(Circle().stroke(Color.black.opacity(0.9), lineWidth: 3))
  }
}

/// User.svelte popover: name, list status, progress, score and profile link.
@MainActor
struct BrowseUserCard: View {
  let entry: AniListFollowingEntry
  @Environment(\.openURL) private var openURL

  var body: some View {
    HStack(spacing: 12) {
      BrowseUserAvatar(entry: entry, size: 56)
      VStack(alignment: .leading, spacing: 6) {
        Text(entry.name)
          .font(.headline)
          .foregroundStyle(.white)
          .lineLimit(1)
        HStack(spacing: 6) {
          BrowseChip(text: entry.status?.label ?? "Not on List")
          if let status = entry.status, status != .completed, status != .planning, entry.progress > 0 {
            BrowseChip(text: "Progress: \(entry.progress)")
          }
          if entry.status != .current, entry.score > 0 {
            BrowseChip(text: "Score: \(scoreText)")
          }
        }
      }
      Spacer(minLength: 0)
      if let url = entry.siteURL {
        Menu {
          Button {
            BrowseActions.copy(url, detail: "user URL")
          } label: {
            Label("Share to Clipboard", systemImage: "doc.on.doc")
          }
          Button {
            openURL(url)
          } label: {
            Label("Open in Browser", systemImage: "safari")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.white)
        }
      }
    }
    .padding(12)
    .background(BrowsePalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var scoreText: String {
    entry.score.rounded() == entry.score ? String(Int(entry.score)) : String(entry.score)
  }
}

/// Details.svelte: season, status, studio, source, country, adult, english / romaji / native titles,
/// plus popularity and the next airing countdown.
@MainActor
struct BrowseDetailInfoStrip: View {
  let media: Media

  private struct Item: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let systemImage: String?
    let glyph: String?
  }

  private var items: [Item] {
    let extras = Services.shared.store.extras(for: media)
    var result: [Item] = []
    if let season = BrowseMediaInfo.seasonText(media) {
      result.append(Item(label: "Season", value: season, systemImage: "calendar", glyph: nil))
    }
    if media.status != .unknown {
      result.append(Item(label: "Status", value: media.status.label, systemImage: "play.rectangle", glyph: nil))
    }
    if let studio = media.studios.first ?? extras.networks.first {
      result.append(Item(label: "Studio", value: studio, systemImage: "building.2", glyph: nil))
    }
    if let source = extras.source, !source.isEmpty {
      result.append(Item(label: "Source", value: BrowseText.capitalizedWords(source), systemImage: "folder", glyph: nil))
    }
    if let country = BrowseMediaInfo.countryName(media.countryOfOrigin ?? extras.originCountries.first) {
      result.append(Item(label: "Country", value: country, systemImage: "globe", glyph: nil))
    }
    if media.isAdult {
      result.append(Item(label: "Adult", value: "Rated 18+", systemImage: "exclamationmark.triangle", glyph: nil))
    }
    if let rating = extras.contentRating, !rating.isEmpty, rating != "NR" {
      result.append(Item(label: "Rating", value: rating, systemImage: "checkmark.shield", glyph: nil))
    }
    if let duration = media.duration, duration > 0, media.episodes != 1 {
      result.append(Item(label: "Duration", value: "\(duration) min", systemImage: "timer", glyph: nil))
    }
    if let popularity = media.popularity, popularity > 0, media.source == .anilist {
      result.append(Item(label: "Popularity", value: BrowseText.number(popularity), systemImage: "heart", glyph: nil))
    }
    if let english = media.title.english, !english.isEmpty {
      result.append(Item(label: "English", value: english, systemImage: "textformat", glyph: nil))
    }
    if let romaji = media.title.romaji, !romaji.isEmpty, media.source == .anilist {
      result.append(Item(label: "Romaji", value: romaji, systemImage: "character.book.closed", glyph: nil))
    }
    if let native = media.title.native, !native.isEmpty, media.source == .anilist {
      result.append(Item(label: "Native", value: native, systemImage: nil, glyph: "\u{8A9E}"))
    }
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BrowseNextAiringLine(media: media)
        .padding(.horizontal, 16)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
          ForEach(items) { item in
            itemView(item)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
      .background(BrowsePalette.card)
    }
  }

  private func itemView(_ item: Item) -> some View {
    HStack(spacing: 8) {
      if let systemImage = item.systemImage {
        Image(systemName: systemImage)
          .font(.title3)
          .foregroundStyle(BrowsePalette.muted)
      } else if let glyph = item.glyph {
        Text(glyph)
          .font(.caption.weight(.bold))
          .foregroundStyle(BrowsePalette.muted)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(item.value)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .textSelection(.enabled)
        Text(item.label)
          .font(.caption2)
          .foregroundStyle(BrowsePalette.dimmed)
      }
    }
  }
}

/// "Episode 5 in 2d 3h 4m" of the details (airing schedule or TMDB next episode).
@MainActor
struct BrowseNextAiringLine: View {
  let media: Media

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      if let info = AnimeHelpers.airingInfo(media) {
        line(prefix: info.episode, time: info.time)
      } else if let next = media.nextAiring, next.airingAt > Date() {
        line(prefix: "Episode \(next.episode) in", time: ServiceText.countdown(next.airingAt.timeIntervalSinceNow))
      }
    }
  }

  private func line(prefix: String, time: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "clock")
      Text(prefix)
        .foregroundStyle(BrowsePalette.muted)
      Text(time)
        .fontWeight(.bold)
        .foregroundStyle(prefix.contains("out for") ? BrowsePalette.success : Color.white)
    }
    .font(.subheadline)
  }
}

/// Tags (with their AniList rank) and genres; a tap searches them.
@MainActor
struct BrowseDetailChips: View {
  let media: Media

  var body: some View {
    let ranks = Services.shared.store.extras(for: media).tagRanks
    VStack(alignment: .leading, spacing: 10) {
      if !media.tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(media.tags, id: \.self) { tag in
              tagChip(tag, rank: ranks[tag])
            }
          }
          .padding(.horizontal, 16)
        }
      }
      if !media.genres.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(media.genres, id: \.self) { genre in
              genreChip(genre)
            }
          }
          .padding(.horizontal, 16)
        }
      }
    }
  }

  private func tagChip(_ tag: String, rank: Int?) -> some View {
    Button {
      search(tag: tag)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "number")
        Text(tag).fontWeight(.bold)
        if media.source == .anilist, let rank {
          Text(verbatim: ": \(rank)%").fontWeight(.light)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(media.source != .anilist)
  }

  private func genreChip(_ genre: String) -> some View {
    Button {
      search(genre: genre)
    } label: {
      HStack(spacing: 6) {
        if let symbol = BrowseGenreIcons.symbol(genre) {
          Image(systemName: symbol)
        }
        Text(genre).fontWeight(.semibold)
      }
      .font(.subheadline)
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func search(genre: String) {
    var query = MediaQuery()
    query.scope = media.source == .tmdb ? .western : .anime
    query.genres = [genre]
    AppRouter.shared.search(query)
  }

  private func search(tag: String) {
    var query = MediaQuery()
    query.scope = .anime
    query.tags = [tag]
    AppRouter.shared.search(query)
  }
}

/// "Synopsis" section (sanitized description with bold / italic / links).
@MainActor
struct BrowseDetailSynopsis: View {
  let media: Media
  @State private var expanded = false

  var body: some View {
    let text = BrowseText.attributed(media.description)
    let toggleTitle: String = expanded ? "Show Less" : "Show More"
    if !text.characters.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        BrowseSectionDivider(title: "Synopsis")
        Text(text)
          .font(.callout)
          .foregroundStyle(Color.white.opacity(0.88))
          .lineLimit(expanded ? nil : 8)
          .textSelection(.enabled)
          .tint(BrowsePalette.tertiary)
        Button(toggleTitle) {
          withAnimation(.easeInOut(duration: 0.2)) {
            expanded.toggle()
          }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(BrowsePalette.muted)
      }
    }
  }
}
