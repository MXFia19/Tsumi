import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// Widget extension of Tsumi: Continue Watching (home screen), Next Episode (home and lock screen) and the
// episode countdown Live Activity (lock screen + Dynamic Island).

@main
struct TsumiWidgetsBundle: WidgetBundle {
  var body: some Widget {
    ContinueWatchingWidget()
    NextEpisodeWidget()
    TsumiCountdownLiveActivity()
  }
}

/// Widget configuration: optional AniList username. Empty = the account signed in to Tsumi (shared container).
struct TsumiWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Tsumi List"
  static var description = IntentDescription("Leave the username empty to show the account signed in to Tsumi. Enter an AniList username to show that user's public list instead (needed when Tsumi was sideloaded without App Groups).")

  @Parameter(title: "AniList Username")
  var username: String?

  init() {}
}

enum TsumiWidgetStyle {
  static let backgroundTop = Color(red: 0.10, green: 0.10, blue: 0.13)
  static let backgroundBottom = Color(red: 0.03, green: 0.03, blue: 0.05)
  /// --tertiary-color of the app.
  static let accent = Color(red: 0.186, green: 0.457, blue: 0.894)
  static let success = Color(red: 0.30, green: 0.78, blue: 0.40)
  static let muted = Color.white.opacity(0.62)

  static var background: some View {
    LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
  }

  /// "#RRGGBB" → Color.
  static func color(hex: String?) -> Color? {
    guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}

/// Cover thumbnail, or the cover colour with an icon when there is none.
struct TsumiWidgetCover: View {
  let image: UIImage?
  let color: String?
  var cornerRadius: CGFloat = 8

  var body: some View {
    Rectangle()
      .fill(TsumiWidgetStyle.color(hex: color) ?? Color.white.opacity(0.12))
      .overlay {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "play.rectangle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.55))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

/// Countdown that ticks by itself: a running timer within a day, a relative time further away, "Out now" once aired.
struct TsumiCountdownText: View {
  let airingAt: Date
  /// Date of the timeline entry being rendered.
  let now: Date

  var body: some View {
    if airingAt <= now {
      Text("Out now")
        .foregroundStyle(TsumiWidgetStyle.success)
    } else if airingAt.timeIntervalSince(now) < 24 * 3600 {
      Text(airingAt, style: .timer)
        .monospacedDigit()
    } else {
      Text(airingAt, style: .relative)
    }
  }
}

/// Message shown when a widget has nothing to show.
struct TsumiWidgetMessage: View {
  let title: String
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "play.tv.fill")
          .foregroundStyle(TsumiWidgetStyle.accent)
        Text(title)
          .font(.system(size: 13, weight: .heavy))
          .foregroundStyle(.white)
      }
      Text(message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(TsumiWidgetStyle.muted)
        .minimumScaleFactor(0.7)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
