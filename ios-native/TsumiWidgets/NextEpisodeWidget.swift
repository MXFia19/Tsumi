import AppIntents
import SwiftUI
import WidgetKit

// "Next Episode": countdown to the next airing episode of the followed titles (Watching, Rewatching, Planning).
// The countdowns are Text timers, so they tick without timeline reloads; the timeline only has entries where
// the display changes (an episode airs, leaves "Out now", or gets within a day).

struct NextEpisodeEntry: TimelineEntry {
  let date: Date
  let data: TsumiWidgetData
}

struct NextEpisodeProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> NextEpisodeEntry {
    NextEpisodeEntry(date: Date(), data: .preview)
  }

  func snapshot(for configuration: TsumiWidgetIntent, in context: Context) async -> NextEpisodeEntry {
    if context.isPreview { return NextEpisodeEntry(date: Date(), data: .preview) }
    return NextEpisodeEntry(date: Date(), data: await TsumiWidgetDataLoader.load(username: configuration.username))
  }

  func timeline(for configuration: TsumiWidgetIntent, in context: Context) async -> Timeline<NextEpisodeEntry> {
    let data = await TsumiWidgetDataLoader.load(username: configuration.username)
    let now = Date()
    let horizon = now.addingTimeInterval(24 * 3600)
    var dates: Set<Date> = [now]
    for airing in data.snapshot?.airings(at: now).prefix(10) ?? [] {
      for date in [airing.airingAt.addingTimeInterval(-24 * 3600), airing.airingAt, airing.airingAt.addingTimeInterval(TsumiWidgetSnapshot.outWindow)] where date > now && date < horizon {
        dates.insert(date)
      }
    }
    let entries = dates.sorted().prefix(40).map { NextEpisodeEntry(date: $0, data: data) }
    // The app snapshot holds the next few episodes of each title, so it lasts; the public list only has the next one.
    let refresh = now.addingTimeInterval(data.isUsernameMode ? 60 * 60 : 4 * 3600)
    return Timeline(entries: entries, policy: .after(refresh))
  }
}

struct NextEpisodeWidget: Widget {
  let kind = "TsumiNextEpisode"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: kind, intent: TsumiWidgetIntent.self, provider: NextEpisodeProvider()) { entry in
      NextEpisodeView(entry: entry)
    }
    .configurationDisplayName("Next Episode")
    .description("Countdown to the next episode of the shows you follow.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
  }
}

struct NextEpisodeView: View {
  let entry: NextEpisodeEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    let airings = entry.data.snapshot?.airings(at: entry.date) ?? []
    switch family {
    case .accessoryRectangular:
      rectangular(airings.first)
        .containerBackground(for: .widget) { Color.clear }
    case .accessoryCircular:
      circular(airings.first)
        .containerBackground(for: .widget) { Color.clear }
    case .accessoryInline:
      inline(airings.first)
        .containerBackground(for: .widget) { Color.clear }
    case .systemMedium:
      system(airings, rows: 3)
        .containerBackground(for: .widget) { TsumiWidgetStyle.background }
    default:
      system(airings, rows: 1)
        .containerBackground(for: .widget) { TsumiWidgetStyle.background }
    }
  }

  private var emptyMessage: String {
    entry.data.message ?? "No upcoming episodes for the shows on your Watching and Planning lists."
  }

  // MARK: Home screen

  @ViewBuilder
  private func system(_ airings: [TsumiWidgetAiring], rows: Int) -> some View {
    if let first = airings.first, entry.data.message == nil {
      if rows == 1 {
        small(first)
          .widgetURL(first.link)
      } else {
        medium(Array(airings.prefix(rows)))
      }
    } else {
      TsumiWidgetMessage(title: "Next Episode", message: emptyMessage)
        .widgetURL(TsumiWidgetLinks.schedule)
    }
  }

  private func small(_ airing: TsumiWidgetAiring) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .top) {
        TsumiWidgetCover(image: entry.data.image(airing.cover), color: airing.color, cornerRadius: 6)
          .frame(width: 36, height: 50)
        Spacer(minLength: 0)
        Image(systemName: "timer")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(TsumiWidgetStyle.accent)
      }
      Spacer(minLength: 0)
      Text(airing.title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
      Text(airing.episodeText)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TsumiWidgetStyle.muted)
        .lineLimit(1)
      TsumiCountdownText(airingAt: airing.airingAt, now: entry.date)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func medium(_ airings: [TsumiWidgetAiring]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "timer")
          .foregroundStyle(TsumiWidgetStyle.accent)
        Text("Next Episodes")
          .font(.system(size: 13, weight: .heavy))
          .foregroundStyle(.white)
        Spacer(minLength: 0)
      }
      ForEach(airings) { airing in
        Link(destination: airing.link) {
          HStack(spacing: 8) {
            TsumiWidgetCover(image: entry.data.image(airing.cover), color: airing.color, cornerRadius: 4)
              .frame(width: 22, height: 31)
            VStack(alignment: .leading, spacing: 0) {
              Text(airing.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
              Text(airing.episodeText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TsumiWidgetStyle.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            TsumiCountdownText(airingAt: airing.airingAt, now: entry.date)
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(.white)
              .multilineTextAlignment(.trailing)
              .lineLimit(1)
              .frame(maxWidth: 110, alignment: .trailing)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: Lock screen

  @ViewBuilder
  private func rectangular(_ airing: TsumiWidgetAiring?) -> some View {
    if let airing {
      VStack(alignment: .leading, spacing: 0) {
        Text(airing.title)
          .font(.headline)
          .lineLimit(1)
          .widgetAccentable()
        Text("Episode \(airing.episode)")
          .font(.caption)
          .lineLimit(1)
        TsumiCountdownText(airingAt: airing.airingAt, now: entry.date)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(airing.link)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        Text("Tsumi")
          .font(.headline)
          .widgetAccentable()
        Text(entry.data.message == nil ? "No upcoming episodes" : "Open Tsumi to set up")
          .font(.caption)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(TsumiWidgetLinks.schedule)
    }
  }

  @ViewBuilder
  private func circular(_ airing: TsumiWidgetAiring?) -> some View {
    if let airing, airing.airingAt > entry.date {
      // Ring draining over the week before the episode airs (full until then). The start is fixed: anchored on the
      // entry date, it refilled at every timeline reload.
      let start = airing.airingAt.addingTimeInterval(-7 * 86400)
      ProgressView(timerInterval: start...airing.airingAt, countsDown: true) {
        Text("Episode \(airing.episode)")
      } currentValueLabel: {
        VStack(spacing: -2) {
          Text("EP")
            .font(.system(size: 9, weight: .bold))
          Text("\(airing.episode)")
            .font(.system(size: 16, weight: .bold))
            .minimumScaleFactor(0.6)
        }
      }
      .progressViewStyle(.circular)
      .widgetAccentable()
      .widgetURL(airing.link)
    } else if let airing {
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: -1) {
          Text("EP \(airing.episode)")
            .font(.system(size: 10, weight: .bold))
          Text("OUT")
            .font(.system(size: 14, weight: .heavy))
            .widgetAccentable()
        }
      }
      .widgetURL(airing.link)
    } else {
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "timer")
          .font(.system(size: 20, weight: .semibold))
      }
      .widgetURL(TsumiWidgetLinks.schedule)
    }
  }

  @ViewBuilder
  private func inline(_ airing: TsumiWidgetAiring?) -> some View {
    if let airing {
      if airing.airingAt <= entry.date {
        Label("Ep \(airing.episode) out now · \(airing.title)", systemImage: "play.circle")
      } else {
        Label {
          Text("Ep \(airing.episode) in \(Text(airing.airingAt, style: .relative))")
        } icon: {
          Image(systemName: "timer")
        }
      }
    } else {
      Label("No upcoming episodes", systemImage: "timer")
    }
  }
}
