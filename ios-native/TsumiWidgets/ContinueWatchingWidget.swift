import AppIntents
import SwiftUI
import WidgetKit

// "Continue Watching": next episodes to watch from the Watching / Rewatching list. Tapping a title opens its
// details in the app (tsumi://anime/<id>); on the medium and large widgets, the play button of an AniList title whose
// next episode is out plays it (tsumi://search/<id>, the app plays progress + 1).

struct ContinueWatchingEntry: TimelineEntry {
  let date: Date
  let data: TsumiWidgetData
}

struct ContinueWatchingProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ContinueWatchingEntry {
    ContinueWatchingEntry(date: Date(), data: .preview)
  }

  func snapshot(for configuration: TsumiWidgetIntent, in context: Context) async -> ContinueWatchingEntry {
    if context.isPreview { return ContinueWatchingEntry(date: Date(), data: .preview) }
    return ContinueWatchingEntry(date: Date(), data: await TsumiWidgetDataLoader.load(username: configuration.username))
  }

  func timeline(for configuration: TsumiWidgetIntent, in context: Context) async -> Timeline<ContinueWatchingEntry> {
    let data = await TsumiWidgetDataLoader.load(username: configuration.username)
    let now = Date()
    // New entries when a waiting title's next episode airs (it becomes watchable).
    var dates = [now]
    for show in data.snapshot?.continueWatching.prefix(8) ?? [] {
      if let airingAt = show.nextEpisodeAiringAt, airingAt > now, airingAt < now.addingTimeInterval(12 * 3600) {
        dates.append(airingAt)
      }
    }
    let entries = Set(dates).sorted().map { ContinueWatchingEntry(date: $0, data: data) }
    // The app reloads the widgets when its lists change; the public list is polled.
    let refresh = now.addingTimeInterval(data.isUsernameMode ? 30 * 60 : 2 * 3600)
    return Timeline(entries: entries, policy: .after(refresh))
  }
}

struct ContinueWatchingWidget: Widget {
  let kind = "TsumiContinueWatching"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: kind, intent: TsumiWidgetIntent.self, provider: ContinueWatchingProvider()) { entry in
      ContinueWatchingView(entry: entry)
    }
    .configurationDisplayName("Continue Watching")
    .description("The next episodes to watch from your Watching list.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct ContinueWatchingView: View {
  let entry: ContinueWatchingEntry
  @Environment(\.widgetFamily) private var family

  private var shows: [TsumiWidgetShow] {
    TsumiWidgetOrdering.continueWatching(entry.data.snapshot?.continueWatching ?? [], now: entry.date)
  }

  var body: some View {
    let shows = self.shows
    if let message = entry.data.message ?? (shows.isEmpty ? emptyMessage : nil) {
      TsumiWidgetMessage(title: "Continue Watching", message: message)
        .containerBackground(for: .widget) { TsumiWidgetStyle.background }
        .widgetURL(TsumiWidgetLinks.openApp)
    } else {
      switch family {
      case .systemSmall:
        small(shows[0])
      case .systemLarge:
        large(Array(shows.prefix(5)))
          .containerBackground(for: .widget) { TsumiWidgetStyle.background }
      default:
        medium(Array(shows.prefix(3)))
          .containerBackground(for: .widget) { TsumiWidgetStyle.background }
      }
    }
  }

  private var emptyMessage: String {
    "Nothing to continue. Titles you are watching show up here."
  }

  // MARK: Small: one title on its cover

  private func small(_ show: TsumiWidgetShow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Spacer(minLength: 0)
      Text("CONTINUE")
        .font(.system(size: 10, weight: .heavy))
        .foregroundStyle(Color.white.opacity(0.75))
      Text(show.title)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
      episodeLine(show)
        .font(.system(size: 12, weight: .semibold))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .containerBackground(for: .widget) {
      ZStack {
        TsumiWidgetCover(image: entry.data.image(show.cover), color: show.color, cornerRadius: 0)
        LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
      }
    }
    .widgetURL(show.link)
  }

  // MARK: Medium: three covers

  private func medium(_ shows: [TsumiWidgetShow]) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(shows) { show in
        // Two sibling links (a link inside a link has no defined target): details, and play over the cover.
        ZStack(alignment: .topTrailing) {
          Link(destination: show.link) {
            VStack(alignment: .leading, spacing: 3) {
              TsumiWidgetCover(image: entry.data.image(show.cover), color: show.color)
                .frame(maxWidth: .infinity)
                .frame(height: 84)
              Text(show.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
              episodeLine(show)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            }
          }
          if let play = playLink(show) {
            Link(destination: play) {
              playBadge
            }
            .padding(5)
          }
        }
      }
      ForEach(0..<max(0, 3 - shows.count), id: \.self) { _ in
        Color.clear.frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  // MARK: Large: a list with progress bars

  private func large(_ shows: [TsumiWidgetShow]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "play.circle.fill")
          .foregroundStyle(TsumiWidgetStyle.accent)
        Text("Continue Watching")
          .font(.system(size: 14, weight: .heavy))
          .foregroundStyle(.white)
        Spacer(minLength: 0)
      }
      ForEach(shows) { show in
        HStack(spacing: 10) {
          Link(destination: show.link) {
            HStack(spacing: 10) {
              TsumiWidgetCover(image: entry.data.image(show.cover), color: show.color, cornerRadius: 6)
                .frame(width: 34, height: 48)
              VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(.white)
                  .lineLimit(1)
                episodeLine(show)
                  .font(.system(size: 11, weight: .medium))
                  .lineLimit(1)
                if show.total != nil {
                  ProgressView(value: show.fraction)
                    .tint(TsumiWidgetStyle.accent)
                }
              }
              Spacer(minLength: 0)
            }
          }
          if let play = playLink(show) {
            Link(destination: play) {
              playBadge
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// Play link of a title whose next episode is out (AniList titles only: the app's play link takes an AniList id).
  private func playLink(_ show: TsumiWidgetShow) -> URL? {
    guard show.isAvailable(at: entry.date) else { return nil }
    return TsumiWidgetLinks.play(mediaKey: show.id)
  }

  private var playBadge: some View {
    Image(systemName: "play.fill")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 26, height: 26)
      .background(TsumiWidgetStyle.accent, in: Circle())
      .accessibilityLabel("Play next episode")
  }

  /// "Ep 6 of 12", or "Ep 7 in 2 days" when it has not aired yet.
  @ViewBuilder
  private func episodeLine(_ show: TsumiWidgetShow) -> some View {
    if show.isAvailable(at: entry.date) {
      Text(show.episodeText)
        .foregroundStyle(TsumiWidgetStyle.accent)
    } else if let airingAt = show.nextEpisodeAiringAt {
      Text("Ep \(show.nextEpisode) in \(Text(airingAt, style: .relative))")
        .foregroundStyle(TsumiWidgetStyle.muted)
    } else {
      Text("Ep \(show.nextEpisode) soon")
        .foregroundStyle(TsumiWidgetStyle.muted)
    }
  }
}
