import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Lock screen / Dynamic Island countdown to the next episode (TsumiCountdownAttributes, started by the app).
// Without a push server the app cannot update it while closed: the stale date is the airing time, so iOS
// re-renders it as "Out now" by itself when the episode airs; the app ends it (and has it dismissed later) the
// next time it runs.

struct TsumiCountdownLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TsumiCountdownAttributes.self) { context in
      TsumiCountdownLockScreenView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.72))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(context.attributes.link)
    } dynamicIsland: { context in
      let out = TsumiCountdownState.isOut(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          TsumiActivityCover(attributes: context.attributes)
            .frame(width: 40, height: 56)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          TsumiActivityCountdown(state: context.state, out: out)
            .font(.system(size: 22, weight: .bold))
            .frame(maxWidth: 110, alignment: .trailing)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.title)
              .font(.system(size: 15, weight: .semibold))
              .lineLimit(1)
            Text(TsumiCountdownState.episodeText(context))
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.white.opacity(0.65))
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if out {
            Text("Episode \(context.state.episode) is out. Tap to open Tsumi.")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(TsumiWidgetStyle.success)
          } else {
            Text("Airs \(context.state.airingAt.formatted(date: .abbreviated, time: .shortened))")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.white.opacity(0.65))
          }
        }
      } compactLeading: {
        TsumiActivityCover(attributes: context.attributes)
          .frame(width: 20, height: 26)
      } compactTrailing: {
        TsumiActivityCountdown(state: context.state, out: out)
          .font(.system(size: 14, weight: .semibold))
          .frame(maxWidth: 64)
      } minimal: {
        Image(systemName: out ? "checkmark.circle.fill" : "timer")
          .foregroundStyle(out ? TsumiWidgetStyle.success : TsumiWidgetStyle.accent)
      }
      .widgetURL(context.attributes.link)
      .keylineTint(TsumiWidgetStyle.accent)
    }
  }
}

enum TsumiCountdownState {
  /// Aired: ended by the app, past its stale date (the app could not update it), or simply past the time.
  static func isOut(_ context: ActivityViewContext<TsumiCountdownAttributes>) -> Bool {
    context.state.isOut || context.isStale || context.state.airingAt <= Date()
  }

  static func episodeText(_ context: ActivityViewContext<TsumiCountdownAttributes>) -> String {
    if let total = context.attributes.totalEpisodes, total > 0 {
      return "Episode \(context.state.episode) of \(total)"
    }
    return "Episode \(context.state.episode)"
  }
}

struct TsumiCountdownLockScreenView: View {
  let context: ActivityViewContext<TsumiCountdownAttributes>

  var body: some View {
    let out = TsumiCountdownState.isOut(context)
    HStack(spacing: 12) {
      TsumiActivityCover(attributes: context.attributes)
        .frame(width: 44, height: 62)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
        Text(TsumiCountdownState.episodeText(context))
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.65))
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 0) {
        Text(out ? "Episode" : "Airs in")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.6))
        TsumiActivityCountdown(state: context.state, out: out)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(maxWidth: 120, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }
}

/// Running countdown, or "Out now".
struct TsumiActivityCountdown: View {
  let state: TsumiCountdownAttributes.ContentState
  let out: Bool

  var body: some View {
    let now = Date()
    if out || state.airingAt <= now {
      Text("Out now")
        .foregroundStyle(TsumiWidgetStyle.success)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    } else {
      Text(timerInterval: now...state.airingAt, countsDown: true)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
  }
}

/// Cover thumbnail from the shared container (written by the app), or the cover colour.
struct TsumiActivityCover: View {
  let attributes: TsumiCountdownAttributes

  var body: some View {
    TsumiWidgetCover(image: image, color: attributes.color, cornerRadius: 6)
  }

  private var image: UIImage? {
    guard let cover = attributes.cover, let location = TsumiSharedContainer.readableLocation() else { return nil }
    return UIImage(contentsOfFile: location.coversDirectory.appendingPathComponent(cover).path)
  }
}
