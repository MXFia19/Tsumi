import SwiftUI

// Sections of the Year in Review (common/routes/yearreview/components/ReviewContent.svelte + MonthChart.svelte):
// hero with the big numbers, stat cards, top anime, episodes per month, genres / studios, highlights (binge day,
// first / last anime, highest rated) and the local history of TMDB shows / movies.

private func plural(_ value: Int, _ word: String) -> String {
  YearReviewCalc.plural(value, word)
}

private func hoursText(_ minutes: Int) -> String {
  YearReviewCalc.formatNumber(YearReviewCalc.hoursValue(minutes))
}

@MainActor
struct YearReviewSections: View {
  let result: YearReviewResult
  let account: YearReviewAccount
  let accent: Color

  var body: some View {
    let stats = result.stats
    VStack(alignment: .leading, spacing: 14) {
      YearReviewHero(result: result, account: account, accent: accent)
      YearReviewStatGrid(stats: stats)
      if !stats.topAnime.isEmpty {
        YearReviewPanel(title: "Top anime") {
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(Array(stats.topAnime.enumerated()), id: \.element.mediaId) { index, item in
                let media = result.media(item.mediaId)
                YearReviewCoverTile(
                  url: media.coverURL,
                  color: YearReviewStyle.color(media.color),
                  title: media.title,
                  subtitle: "\(plural(item.episodes, "episode")) · \(hoursText(item.minutes)) h",
                  rank: index + 1,
                  accent: accent
                )
              }
            }
          }
          .scrollIndicators(.hidden)
        }
      }
      YearReviewPanel(title: "Episodes per month") {
        VStack(alignment: .leading, spacing: 10) {
          if let best = stats.months.indices.max(by: { stats.months[$0] < stats.months[$1] }), stats.months[best] > 0 {
            Text(verbatim: "Busiest month: \(YearReviewCalc.monthNames[best]) (\(plural(stats.months[best], "episode")))")
              .font(.footnote)
              .foregroundStyle(YearReviewStyle.muted)
          }
          YearReviewMonthChart(months: stats.months, accent: accent)
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 14) {
          genresPanel(stats).frame(minWidth: 300)
          studiosPanel(stats).frame(minWidth: 300)
        }
        VStack(spacing: 14) {
          genresPanel(stats)
          studiosPanel(stats)
        }
      }
      YearReviewHighlights(result: result, accent: accent)
      if result.local.hasData {
        YearReviewLocalSection(result: result, accent: accent)
      }
      Text(verbatim: "Estimated from your AniList list activity: episode counts follow your progress updates, hours use each episode's length. Updated \(YearReviewStyle.updatedText(result.fetchedAt)).")
        .font(.caption2)
        .foregroundStyle(YearReviewStyle.muted)
        .padding(.top, 6)
    }
  }

  private func genresPanel(_ stats: YearReviewStats) -> some View {
    let maxCount = max(1, stats.genres.map(\.count).max() ?? 1)
    return YearReviewPanel(title: "Top genres") {
      VStack(alignment: .leading, spacing: 12) {
        if stats.genres.isEmpty {
          Text("No genres yet.").foregroundStyle(YearReviewStyle.muted)
        }
        ForEach(stats.genres) { genre in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(verbatim: genre.name).font(.subheadline.weight(.bold))
              Spacer()
              Text(verbatim: plural(genre.count, "anime"))
                .font(.footnote)
                .foregroundStyle(YearReviewStyle.muted)
            }
            GeometryReader { proxy in
              ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(accent).frame(width: proxy.size.width * CGFloat(genre.count) / CGFloat(maxCount))
              }
            }
            .frame(height: 7)
          }
        }
      }
    }
  }

  private func studiosPanel(_ stats: YearReviewStats) -> some View {
    YearReviewPanel(title: "Top studios") {
      VStack(alignment: .leading, spacing: 0) {
        if stats.studios.isEmpty {
          Text("No studios yet.").foregroundStyle(YearReviewStyle.muted)
        }
        ForEach(Array(stats.studios.enumerated()), id: \.element.name) { index, studio in
          HStack(spacing: 10) {
            Text(verbatim: String(index + 1))
              .font(.subheadline.weight(.heavy))
              .foregroundStyle(accent)
              .frame(width: 22, alignment: .leading)
            Text(verbatim: studio.name)
              .font(.subheadline.weight(.bold))
              .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: "\(plural(studio.count, "anime")) · \(plural(studio.episodes, "ep"))")
              .font(.caption)
              .foregroundStyle(YearReviewStyle.muted)
              .lineLimit(1)
          }
          .padding(.vertical, 8)
          if index < stats.studios.count - 1 {
            Divider().overlay(Color.white.opacity(0.06))
          }
        }
      }
    }
  }
}

/// Rounded card with a title.
@MainActor
struct YearReviewPanel<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: title)
        .font(.title3.weight(.heavy))
      content
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(YearReviewStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

@MainActor
struct YearReviewHero: View {
  let result: YearReviewResult
  let account: YearReviewAccount
  let accent: Color

  var body: some View {
    let stats = result.stats
    let hero = stats.topAnime.first.map { result.media($0.mediaId) }
    VStack(alignment: .leading, spacing: 8) {
      Text("YEAR IN REVIEW")
        .font(.caption.weight(.heavy))
        .tracking(3)
        .foregroundStyle(accent)
      Text(verbatim: "Your \(result.year) in anime")
        .font(.largeTitle.weight(.heavy))
        .minimumScaleFactor(0.6)
        .lineLimit(2)
      HStack(spacing: 8) {
        if let avatar = account.avatar {
          BrowseImage([avatar])
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        }
        Text(verbatim: account.name)
          .font(.subheadline)
          .foregroundStyle(YearReviewStyle.muted)
      }
      HStack(alignment: .firstTextBaseline, spacing: 22) {
        big(YearReviewCalc.formatNumber(stats.episodes), "episodes")
        big(hoursText(stats.minutes), "hours")
        big(YearReviewCalc.formatNumber(stats.titles), "anime")
      }
      .padding(.top, 12)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 240, alignment: .bottomLeading)
    .background {
      ZStack {
        YearReviewStyle.card
        if let url = hero?.bannerURL ?? hero?.coverURL {
          BrowseImage([url], placeholder: .clear)
            .opacity(0.45)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private func big(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: value)
        .font(.system(size: 34, weight: .black))
        .foregroundStyle(accent)
        .minimumScaleFactor(0.5)
        .lineLimit(1)
      Text(verbatim: label)
        .font(.footnote)
        .foregroundStyle(YearReviewStyle.muted)
    }
  }
}

@MainActor
struct YearReviewStatGrid: View {
  let stats: YearReviewStats

  var body: some View {
    let score = stats.averageScore.map { YearReviewCalc.formatNumber($0) }
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
      card(YearReviewCalc.formatNumber(stats.started), nil, "anime started")
      card(YearReviewCalc.formatNumber(stats.completed), nil, "completed")
      card(YearReviewCalc.formatNumber(stats.dropped), nil, "dropped")
      card(score ?? "–", score == nil ? nil : " / 10", "average score" + (stats.scoredCount > 0 ? " (\(plural(stats.scoredCount, "rating")))" : ""))
      card(YearReviewCalc.formatNumber(stats.activeDays), nil, "days with anime")
      card(YearReviewCalc.formatNumber(stats.longestStreak?.days ?? 0), nil, "longest daily streak")
    }
  }

  private func card(_ value: String, _ unit: String?, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(verbatim: value).font(.system(size: 26, weight: .heavy))
        if let unit {
          Text(verbatim: unit).font(.subheadline.weight(.semibold)).foregroundStyle(YearReviewStyle.muted)
        }
      }
      Text(verbatim: label)
        .font(.footnote)
        .foregroundStyle(YearReviewStyle.muted)
        .lineLimit(2)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(YearReviewStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

/// Cover with an optional rank badge, title and subtitle.
@MainActor
struct YearReviewCoverTile: View {
  let url: URL?
  let color: Color?
  let title: String
  let subtitle: String
  var rank: Int?
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      BrowseImage([url], placeholder: color?.opacity(0.5) ?? Color.white.opacity(0.08))
        .frame(width: 112, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
          if let rank {
            Text(verbatim: String(rank))
              .font(.subheadline.weight(.heavy))
              .foregroundStyle(rank == 1 ? YearReviewStyle.background : Color.white)
              .frame(width: 28, height: 28)
              .background(rank == 1 ? accent : YearReviewStyle.background.opacity(0.85), in: Circle())
              .padding(7)
          }
        }
      Text(verbatim: title)
        .font(.footnote.weight(.bold))
        .lineLimit(1)
      Text(verbatim: subtitle)
        .font(.caption2)
        .foregroundStyle(YearReviewStyle.muted)
        .lineLimit(1)
    }
    .frame(width: 112, alignment: .leading)
  }
}

/// Episodes per month (MonthChart.svelte): the busiest month at full accent, the others dimmed.
@MainActor
struct YearReviewMonthChart: View {
  let months: [Int]
  let accent: Color
  private let barArea: CGFloat = 140

  var body: some View {
    let maxValue = max(1, months.max() ?? 0)
    let best = months.indices.max(by: { months[$0] < months[$1] })
    HStack(alignment: .bottom, spacing: 5) {
      ForEach(months.indices, id: \.self) { index in
        let value = months[index]
        VStack(spacing: 4) {
          Text(verbatim: value > 0 ? YearReviewCalc.formatNumber(value) : " ")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(YearReviewStyle.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(accent.opacity(index == best && value > 0 ? 1 : 0.35))
            .frame(height: value > 0 ? max(3, barArea * CGFloat(value) / CGFloat(maxValue)) : 2)
          Text(verbatim: YearReviewCalc.months[index % 12])
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(YearReviewStyle.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(YearReviewCalc.monthNames[index % 12]): \(plural(value, "episode"))"))
      }
    }
    .frame(height: barArea + 34, alignment: .bottom)
  }
}

@MainActor
struct YearReviewHighlights: View {
  let result: YearReviewResult
  let accent: Color

  var body: some View {
    let stats = result.stats
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
      if let day = stats.bingeDay {
        card(icon: "flame.fill", heading: "Biggest binge day") {
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: YearReviewCalc.formatDay(day.date)).font(.title3.weight(.heavy))
            Text(verbatim: "\(plural(day.episodes, "episode")) · \(hoursText(day.minutes)) hours")
              .font(.footnote)
              .foregroundStyle(YearReviewStyle.muted)
            HStack(spacing: 8) {
              ForEach(day.mediaIds.prefix(4), id: \.self) { id in
                BrowseImage([result.media(id).coverURL])
                  .frame(width: 44, height: 62)
                  .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
              }
            }
          }
        }
      }
      if let first = stats.first {
        moment(icon: "play.fill", heading: "First anime of the year", media: result.media(first.mediaId), detail: YearReviewCalc.formatDay(YearReviewCalc.dayKey(first.time)))
      }
      if let last = stats.last {
        moment(icon: "flag.fill", heading: "Last anime of the year", media: result.media(last.mediaId), detail: YearReviewCalc.formatDay(YearReviewCalc.dayKey(last.time)))
      }
      if let rated = stats.topRated {
        moment(icon: "star.fill", heading: "Highest rated", media: result.media(rated.mediaId), detail: "\(YearReviewCalc.formatNumber(rated.score)) / 10")
      }
    }
  }

  private func card<Content: View>(icon: String, heading: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(heading.uppercased(), systemImage: icon)
        .font(.caption.weight(.bold))
        .tracking(1)
        .foregroundStyle(accent)
      content()
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(YearReviewStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func moment(icon: String, heading: String, media: YearReviewMedia, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      BrowseImage([media.coverURL], placeholder: YearReviewStyle.color(media.color)?.opacity(0.5) ?? Color.white.opacity(0.08))
        .frame(width: 70, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 6) {
        Label(heading.uppercased(), systemImage: icon)
          .font(.caption.weight(.bold))
          .tracking(1)
          .foregroundStyle(accent)
        Text(verbatim: media.title)
          .font(.headline.weight(.heavy))
          .lineLimit(2)
        Text(verbatim: detail)
          .font(.footnote)
          .foregroundStyle(YearReviewStyle.muted)
      }
      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(YearReviewStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

/// Shows & movies from the local watch history (TMDB titles are not on AniList).
@MainActor
struct YearReviewLocalSection: View {
  let result: YearReviewResult
  let accent: Color

  var body: some View {
    let local = result.local
    YearReviewPanel(title: "Shows & movies") {
      VStack(alignment: .leading, spacing: 12) {
        Text("From this device's watch history (not on AniList)")
          .font(.footnote)
          .foregroundStyle(YearReviewStyle.muted)
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          number(YearReviewCalc.formatNumber(local.titles), "titles")
          number(YearReviewCalc.formatNumber(local.episodes), "finished")
          number(hoursText(local.minutes), "hours")
        }
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(result.localItems) { item in
              YearReviewCoverTile(
                url: item.cover,
                color: nil,
                title: item.title,
                subtitle: "\(hoursText(item.minutes)) h" + (item.episodes > 0 && !item.isMovie ? " · \(plural(item.episodes, "episode"))" : ""),
                rank: nil,
                accent: accent
              )
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private func number(_ value: String, _ label: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(verbatim: value).font(.title2.weight(.heavy)).foregroundStyle(accent)
      Text(verbatim: label).font(.footnote).foregroundStyle(YearReviewStyle.muted)
    }
  }
}
