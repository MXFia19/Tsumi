import SwiftUI

// Bottom of DetailsModal.svelte: Relations and Recommendations (ToggleList.svelte rows of SmallCards with
// the relation type), characters and staff (TMDB / AniList details), external links.

@MainActor
struct BrowseDetailBottom: View {
  let model: BrowseDetailModel

  var body: some View {
    let media = model.media
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
      BrowseToggleList(title: "Relations") {
        ForEach(items) { relation in
          BrowseMediaCard(media: relation.media, style: .small, typeLabel: relation.relationType, width: 128)
        }
      }
    } else if !model.detailsLoaded && media.source == .anilist {
      BrowseToggleList(title: "Relations") {
        ForEach(0..<4, id: \.self) { _ in
          BrowseSmallCardSkeleton(width: 128)
        }
      }
    }
  }

  @ViewBuilder
  private func recommendationsSection(_ media: Media) -> some View {
    let items = BrowseSectionRowModel.unique(media.recommendations.filter { BrowseMediaInfo.passesAdultFilter($0) && $0.id != media.id })
    if !items.isEmpty {
      BrowseToggleList(title: "Recommendations") {
        ForEach(items) { item in
          BrowseMediaCard(media: item, style: .small, width: 128)
        }
      }
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
