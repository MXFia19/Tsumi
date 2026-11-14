import SwiftUI

// Bottom of DetailsModal.svelte: Relations and Recommendations (ToggleList.svelte rows of SmallCards with
// the relation type, or the recommendation likes sorted by rating), characters and staff (TMDB / AniList
// details), external links. The Expandable Lists setting (toggleList) wraps the lists and collapses them to
// one row with a Show More toggle.

@MainActor
struct BrowseDetailBottom: View {
  let model: BrowseDetailModel

  var body: some View {
    let media = model.live
    VStack(alignment: .leading, spacing: 22) {
      relationsSection(media)
      recommendationsSection(media)
      if !media.characters.isEmpty {
        BrowseCharacterRow(characters: media.characters)
      }
      if !media.staff.isEmpty {
        BrowseStaffRow(staff: media.staff)
      }
      BrowseExternalLinks(media: media)
        .padding(.horizontal, 16)
    }
    .padding(.top, 8)
  }

  /// Relations without characters / music / filtered adult titles, oldest first.
  private func relations(_ media: Media) -> [MediaRelation] {
    let filtered = media.relations.filter { relation in
      relation.relationType != "CHARACTER" && relation.media.format != .music && BrowseMediaInfo.passesAdultFilter(relation.media)
    }
    return filtered.sorted { lhs, rhs in
      (lhs.media.seasonYear ?? Int.max) < (rhs.media.seasonYear ?? Int.max)
    }
  }

  @ViewBuilder
  private func relationsSection(_ media: Media) -> some View {
    let items = relations(media)
    if !items.isEmpty {
      BrowseExpandableList(title: "Relations", items: items) { relation in
        BrowseMediaCard(media: relation.media, style: .small, typeLabel: relation.relationType, width: 128)
      }
    } else if !model.detailsLoaded && media.source == .anilist {
      BrowseToggleList(title: "Relations") {
        ForEach(0..<4, id: \.self) { _ in
          BrowseSmallCardSkeleton(width: 128)
        }
      }
    }
  }

  /// Recommendations, highest rating first once the ratings are known.
  private func recommendations(_ media: Media, likes: [String: Int]) -> [Media] {
    let items = BrowseSectionRowModel.unique(media.recommendations.filter { BrowseMediaInfo.passesAdultFilter($0) && $0.id != media.id })
    if likes.isEmpty { return items }
    return items.enumerated().sorted { lhs, rhs in
      let left = likes[lhs.element.id] ?? Int.min
      let right = likes[rhs.element.id] ?? Int.min
      return left != right ? left > right : lhs.offset < rhs.offset
    }.map { $0.element }
  }

  @ViewBuilder
  private func recommendationsSection(_ media: Media) -> some View {
    let likes = model.recommendationLikes
    let items = recommendations(media, likes: likes)
    if !items.isEmpty {
      BrowseExpandableList(title: "Recommendations", items: items) { item in
        BrowseMediaCard(media: item, style: .small, width: 128, likes: likes[item.id])
      }
    }
  }
}

/// ToggleList.svelte: one horizontal row, or with the Expandable Lists setting (toggleList) a wrapping list
/// collapsed to its first row, opened and closed from the title or the round button under it.
@MainActor
struct BrowseExpandableList<Item: Identifiable, Card: View>: View {
  let title: String
  let items: [Item]
  var itemWidth: CGFloat = 128
  @ViewBuilder let card: (Item) -> Card
  @State private var expanded = false
  @State private var width: CGFloat = 0

  private var spacing: CGFloat { 14 }

  var body: some View {
    if AppSettings.shared.values.toggleList {
      wrapped
    } else {
      BrowseToggleList(title: title) {
        ForEach(items) { item in
          card(item)
        }
      }
    }
  }

  /// previewLength: the cards that fit in one row.
  private var rowLength: Int {
    guard width > 0 else { return 4 }
    return max(Int((width + spacing) / (itemWidth + spacing)), 1)
  }

  private var wrapped: some View {
    let canToggle = items.count > rowLength
    let shown: [Item] = (expanded || !canToggle) ? items : Array(items.prefix(rowLength))
    return VStack(alignment: .leading, spacing: 12) {
      Button {
        toggle()
      } label: {
        BrowseSectionDivider(title: title)
      }
      .buttonStyle(.plain)
      .disabled(!canToggle)
      .padding(.horizontal, 16)
      BrowseFlowLayout(spacing: spacing, lineSpacing: 18) {
        ForEach(shown) { item in
          card(item)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        GeometryReader { proxy in
          Color.clear
            .onAppear { width = proxy.size.width }
            .onChange(of: proxy.size.width) { _, value in width = value }
        }
      }
      .padding(.horizontal, 16)
      if canToggle {
        Button {
          toggle()
        } label: {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(BrowsePalette.cardStrong, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(expanded ? "Show Less" : "Show More")
      }
    }
  }

  private func toggle() {
    withAnimation(.easeInOut(duration: 0.2)) {
      expanded.toggle()
    }
  }
}

/// ToggleList.svelte in its mobile layout (toggleList off: one horizontal row).
struct BrowseToggleList<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BrowseSectionDivider(title: title)
        .padding(.horizontal, 16)
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 14) {
          content()
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

/// Characters (and their voice actors).
@MainActor
struct BrowseCharacterRow: View {
  let characters: [MediaCharacter]

  private var unique: [MediaCharacter] {
    var seen = Set<String>()
    return characters.filter { seen.insert($0.id).inserted }
  }

  var body: some View {
    BrowseToggleList(title: "Characters") {
      ForEach(unique) { character in
        BrowsePersonCard(name: character.name, detail: character.actorName ?? character.role.map { BrowseText.capitalizedWords($0) }, image: character.image)
      }
    }
  }
}

/// Staff and their roles.
@MainActor
struct BrowseStaffRow: View {
  let staff: [MediaStaff]

  private var unique: [MediaStaff] {
    var seen = Set<String>()
    return staff.filter { seen.insert($0.id).inserted }
  }

  var body: some View {
    BrowseToggleList(title: "Staff") {
      ForEach(unique) { person in
        BrowsePersonCard(name: person.name, detail: person.role, image: person.image)
      }
    }
  }
}

struct BrowsePersonCard: View {
  let name: String
  let detail: String?
  let image: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        Rectangle().fill(BrowsePalette.skeleton)
        if image != nil {
          BrowseImage([image], placeholder: BrowsePalette.skeleton)
        } else {
          Image(systemName: "person.fill")
            .font(.largeTitle)
            .foregroundStyle(BrowsePalette.dimmed)
        }
      }
      .frame(width: 100, height: 140)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      Text(name)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(2)
      }
    }
    .frame(width: 100, alignment: .topLeading)
  }
}

/// External pages (AniList, MyAnimeList, TMDB, IMDb) and the studios / networks of the title.
@MainActor
struct BrowseExternalLinks: View {
  let media: Media
  @Environment(\.openURL) private var openURL

  var body: some View {
    let links = BrowseMediaInfo.links(media)
    let extras = Services.shared.store.extras(for: media)
    let companies = media.studios + extras.networks.filter { !media.studios.contains($0) }
    VStack(alignment: .leading, spacing: 12) {
      if !companies.isEmpty {
        BrowseSectionDivider(title: "Studios")
        Text(companies.joined(separator: " \u{2022} "))
          .font(.subheadline)
          .foregroundStyle(Color.white.opacity(0.85))
          .textSelection(.enabled)
      }
      if !extras.streamingProviders.isEmpty {
        BrowseSectionDivider(title: "Streaming")
        Text(extras.streamingProviders.joined(separator: " \u{2022} "))
          .font(.subheadline)
          .foregroundStyle(Color.white.opacity(0.85))
      }
      if !links.isEmpty {
        BrowseSectionDivider(title: "Links")
        BrowseFlowLayout(spacing: 8, lineSpacing: 8) {
          ForEach(links) { link in
            Button {
              openURL(link.url)
            } label: {
              Label(link.name, systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button {
                BrowseActions.copy(link.url, detail: "share URL")
              } label: {
                Label("Share to Clipboard", systemImage: "doc.on.doc")
              }
              ShareLink(item: link.url) {
                Label("Share", systemImage: "square.and.arrow.up")
              }
            }
          }
        }
      }
    }
  }
}
