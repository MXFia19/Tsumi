import SwiftUI
import UIKit

// Shareable summary card of the Year in Review: the same 1080 x 1350 layout as the PC image
// (common/modules/yearreview/shareImage.js), drawn by ImageRenderer at 360 x 450 points, scale 3.

/// Remote images of the card, downloaded before rendering (ImageRenderer does not wait for remote images).
struct YearReviewShareImages {
  var hero: UIImage?
  var avatar: UIImage?
  var covers: [Int: UIImage] = [:]

  static func load(result: YearReviewResult, avatar: URL?) async -> YearReviewShareImages {
    let top = Array(result.stats.topAnime.prefix(5))
    let heroMedia = top.first.map { result.media($0.mediaId) }
    let coverURLs = top.map { (id: $0.mediaId, url: result.media($0.mediaId).coverURL) }
    async let hero = image(heroMedia?.bannerURL ?? heroMedia?.coverURL)
    async let avatarImage = image(avatar)
    let covers = await withTaskGroup(of: (Int, UIImage?).self, returning: [Int: UIImage].self) { group in
      for item in coverURLs {
        group.addTask { (item.id, await YearReviewShareImages.image(item.url)) }
      }
      var loaded: [Int: UIImage] = [:]
      for await (id, cover) in group {
        if let cover { loaded[id] = cover }
      }
      return loaded
    }
    return YearReviewShareImages(hero: await hero, avatar: await avatarImage, covers: covers)
  }

  private static func image(_ url: URL?) async -> UIImage? {
    guard let url else { return nil }
    return await BrowseImageCache.shared.load(url)
  }
}

@MainActor
enum YearReviewShareRenderer {
  static let size = CGSize(width: 360, height: 450)

  static func render(result: YearReviewResult, account: YearReviewAccount, images: YearReviewShareImages) -> UIImage? {
    let card = YearReviewShareCard(result: result, account: account, images: images, accent: YearReviewStyle.accent)
      .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: card)
    renderer.scale = 3
    renderer.proposedSize = ProposedViewSize(size)
    renderer.isOpaque = true
    return renderer.uiImage
  }
}

struct YearReviewShareCard: View {
  let result: YearReviewResult
  let account: YearReviewAccount
  let images: YearReviewShareImages
  let accent: Color

  private let muted = Color.white.opacity(0.62)
  private let margin: CGFloat = 21

  var body: some View {
    let stats = result.stats
    let top = Array(stats.topAnime.prefix(5))
    let heroColor = YearReviewStyle.color(top.first.map { result.media($0.mediaId).color } ?? nil)
    ZStack(alignment: .topLeading) {
      YearReviewStyle.background
      if let hero = images.hero {
        Image(uiImage: hero)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 360, height: 200)
          .clipped()
          .opacity(0.42)
      }
      LinearGradient(
        stops: [
          .init(color: YearReviewStyle.background.opacity(0.3), location: 0),
          .init(color: YearReviewStyle.background, location: 1)
        ],
        startPoint: UnitPoint(x: 0.5, y: 0.2),
        endPoint: .bottom
      )
      .frame(width: 360, height: 200)
      RadialGradient(colors: [(heroColor ?? .white).opacity(heroColor == nil ? 0.10 : 0.33), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 300)

      VStack(alignment: .leading, spacing: 0) {
        header
          .padding(.top, 26)
        HStack(spacing: 8) {
          tile(YearReviewCalc.formatNumber(stats.episodes), "episodes")
          tile(YearReviewCalc.formatNumber(YearReviewCalc.hoursValue(stats.minutes)), "hours")
          tile(YearReviewCalc.formatNumber(stats.titles), "anime")
        }
        .padding(.top, 18)
        HStack(spacing: 0) {
          small(YearReviewCalc.formatNumber(stats.started), "started")
          small(YearReviewCalc.formatNumber(stats.completed), "completed")
          small(YearReviewCalc.formatNumber(stats.dropped), "dropped")
          small(stats.averageScore.map { YearReviewCalc.formatNumber($0) } ?? "–", "avg score")
        }
        .padding(.top, 16)
        Text("Top anime")
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(Color.white)
          .padding(.top, 16)
        covers(top)
          .padding(.top, 8)
        lines(stats)
          .padding(.top, 10)
        Spacer(minLength: 0)
        footer
      }
      .padding(.horizontal, margin)
      .padding(.bottom, 12)
      .frame(width: 360, height: 450, alignment: .topLeading)
    }
    .frame(width: 360, height: 450)
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("YEAR IN REVIEW")
          .font(.system(size: 10, weight: .heavy))
          .tracking(2)
          .foregroundStyle(accent)
        Text(verbatim: "My \(result.year) in anime")
          .font(.system(size: 28, weight: .heavy))
          .foregroundStyle(Color.white)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(verbatim: account.name)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(muted)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if let avatar = images.avatar {
        Image(uiImage: avatar)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 43, height: 43)
          .clipShape(Circle())
          .overlay(Circle().stroke(accent, lineWidth: 1.7))
      }
    }
  }

  private func tile(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: value)
        .font(.system(size: 25, weight: .heavy))
        .foregroundStyle(accent)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(verbatim: label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(muted)
    }
    .padding(.horizontal, 9)
    .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private func small(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: value)
        .font(.system(size: 15, weight: .heavy))
        .foregroundStyle(Color.white)
        .lineLimit(1)
      Text(verbatim: label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func covers(_ top: [YearReviewTopItem]) -> some View {
    HStack(alignment: .top, spacing: 7) {
      ForEach(Array(top.enumerated()), id: \.element.mediaId) { index, item in
        let media = result.media(item.mediaId)
        VStack(alignment: .leading, spacing: 2) {
          ZStack(alignment: .topLeading) {
            if let cover = images.covers[item.mediaId] {
              Image(uiImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 59, height: 83)
                .clipped()
            } else {
              (YearReviewStyle.color(media.color) ?? Color.white.opacity(0.1))
                .frame(width: 59, height: 83)
            }
            Text(verbatim: String(index + 1))
              .font(.system(size: 8, weight: .heavy))
              .foregroundStyle(index == 0 ? YearReviewStyle.background : Color.white)
              .frame(width: 15, height: 15)
              .background(index == 0 ? accent : YearReviewStyle.background.opacity(0.85), in: Circle())
              .padding(3)
          }
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          Text(verbatim: media.title)
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.top, 4)
          Text(verbatim: "\(YearReviewCalc.formatNumber(item.episodes)) ep\(item.episodes == 1 ? "" : "s")")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(muted)
        }
        .frame(width: 59, alignment: .leading)
      }
      if top.isEmpty {
        Text("No episodes tracked this year.")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(muted)
      }
    }
  }

  private func lines(_ stats: YearReviewStats) -> some View {
    var rows: [(String, String)] = []
    if !stats.genres.isEmpty { rows.append(("Top genres", stats.genres.prefix(3).map(\.name).joined(separator: " · "))) }
    if let studio = stats.studios.first { rows.append(("Top studio", studio.name)) }
    if let day = stats.bingeDay {
      rows.append(("Biggest binge", "\(YearReviewCalc.formatShortDay(day.date)) · \(YearReviewCalc.plural(day.episodes, "episode"))"))
    }
    return VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { _, row in
        HStack(spacing: 0) {
          Text(verbatim: row.0)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(muted)
            .frame(width: 83, alignment: .leading)
          Text(verbatim: row.1)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
        }
      }
    }
  }

  private var footer: some View {
    VStack(spacing: 8) {
      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(height: 0.7)
      HStack {
        Text("Tsumi · Year in Review")
        Spacer()
        Text("Data from AniList")
      }
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(muted)
    }
  }
}
