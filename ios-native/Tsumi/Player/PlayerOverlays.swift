import SwiftUI

// Secondary views of the player: subtitles, prompts, errors, notices, stats, keybind help, subtitle offset.

/// Draws external subtitle cues (the JASSUB canvas of the Svelte player). Raised while the controls are shown.
@MainActor
struct PlayerSubtitleOverlay: View {
  let cues: [PlayerSubtitleCue]
  let size: CGSize
  let raised: Bool

  var body: some View {
    let fontSize = max(15, min(size.height, size.width * 9 / 16) * 0.055)
    let topCues = cues.filter { $0.isTop }
    let bottomCues = cues.filter { !$0.isTop }
    VStack(spacing: 0) {
      if !topCues.isEmpty {
        cueStack(topCues, fontSize: fontSize)
          .padding(.top, 20)
      }
      Spacer(minLength: 0)
      if !bottomCues.isEmpty {
        cueStack(bottomCues, fontSize: fontSize)
          .padding(.bottom, raised ? 118 : 26)
      }
    }
    .padding(.horizontal, 24)
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.2), value: raised)
  }

  private func cueStack(_ items: [PlayerSubtitleCue], fontSize: CGFloat) -> some View {
    VStack(spacing: 2) {
      ForEach(items) { cue in
        Text(cue.text)
          .font(.system(size: fontSize, weight: .semibold))
          .italic(cue.italic)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .shadow(color: .black, radius: 0, x: 1.2, y: 1.2)
          .shadow(color: .black, radius: 0, x: -1.2, y: -1.2)
          .shadow(color: .black, radius: 0, x: 1.2, y: -1.2)
          .shadow(color: .black, radius: 0, x: -1.2, y: 1.2)
          .shadow(color: .black.opacity(0.8), radius: 3)
      }
    }
  }
}

/// "This episode has been marked as a Filler, do you want to skip?" (skipPrompt in PlayerPage.svelte).
@MainActor
struct PlayerFillerPrompt: View {
  let label: String
  let onAnswer: (Bool) -> Void

  private var message: AttributedString {
    var text = AttributedString("This episode has been marked as a ")
    var word = AttributedString(label)
    word.inlinePresentationIntent = .stronglyEmphasized
    text += word
    text += AttributedString(", do you want to skip?")
    return text
  }

  var body: some View {
    VStack(spacing: 18) {
      Text(message)
        .font(.body.monospaced())
        .multilineTextAlignment(.center)
      HStack(spacing: 24) {
        Button {
          onAnswer(true)
        } label: {
          Text("Yes").frame(minWidth: 72)
        }
        .buttonStyle(.borderedProminent)
        Button {
          onAnswer(false)
        } label: {
          Text("No").frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
      }
    }
    .foregroundStyle(.white)
    .padding(22)
    .frame(maxWidth: 460)
    .background(Color(white: 0.12).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, 24)
  }
}

/// "Up next" during the end credits / preview while autoplay is on: the next episode starts when the countdown
/// (playback time) runs out; Play Now starts it at once, Cancel lets the credits play.
@MainActor
struct PlayerUpNextCard: View {
  let controller: PlayerController
  let upNext: PlayerUpNext

  /// Seconds left: the countdown, or the end of the episode when it comes first (autoplay takes over there).
  private var remaining: Double {
    let end = controller.duration > 0 ? min(upNext.startsAt, controller.duration) : upNext.startsAt
    return max(end - controller.currentTime, 0)
  }

  private var episodeLabel: String {
    if let season = upNext.episode.season, let local = upNext.episode.localEpisode {
      return "Season \(season) · Episode \(local)"
    }
    return "Episode \(upNext.episode.number)"
  }

  var body: some View {
    let left = remaining
    VStack(alignment: .leading, spacing: 8) {
      Text("Up Next")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.7))
      Text(episodeLabel)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      if let title = upNext.title {
        Text(title)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(2)
      }
      HStack(spacing: 8) {
        Button {
          controller.playUpNext()
        } label: {
          Label("Play Now", systemImage: "play.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
        Button {
          controller.dismissUpNext()
        } label: {
          Text("Cancel")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
      }
      GeometryReader { proxy in
        Capsule()
          .fill(Color.white.opacity(0.55))
          .frame(width: proxy.size.width * CGFloat(min(left / PlayerController.upNextCountdown, 1)), height: 3)
      }
      .frame(height: 3)
      Text(controller.isPlaying ? "Playing in \(Int(left.rounded(.up))) s" : "Paused")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }
    .foregroundStyle(.white)
    .padding(12)
    .frame(width: 270, alignment: .leading)
    .background(Color(white: 0.1).opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Up next: \(episodeLabel)")
  }
}

/// Playback error with reload / next server (checkError toasts).
@MainActor
struct PlayerErrorView: View {
  let failure: PlayerFailure
  let canTryNextServer: Bool
  let serverName: String
  let onReload: () -> Void
  let onNextServer: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 38))
        .foregroundStyle(.yellow)
      Text(failure.title)
        .font(.title3.bold())
      Text(failure.message)
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.85))
      if let detail = failure.detail, !detail.isEmpty {
        Text("\(serverName): \(detail)")
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(3)
      }
      HStack(spacing: 14) {
        Button("Reload", action: onReload)
          .buttonStyle(.borderedProminent)
        if canTryNextServer {
          Button("Try Next Server", action: onNextServer)
            .buttonStyle(.bordered)
        }
        Button("Close", action: onClose)
          .buttonStyle(.bordered)
      }
      .padding(.top, 6)
    }
    .foregroundStyle(.white)
    .padding(24)
    .frame(maxWidth: 520)
    .background(Color(white: 0.1).opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
    .padding(24)
  }
}

/// Spinner while `loadEpisode` runs.
@MainActor
struct PlayerEpisodeLoadingView: View {
  let episode: EpisodeRef

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)
      Text("Loading Episode \(episode.localEpisode ?? episode.number)…")
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(26)
    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
  }
}

/// Toast replacement shown at the top of the player.
@MainActor
struct PlayerNoticeBanner: View {
  let notice: PlayerNotice
  let onDismiss: () -> Void

  var body: some View {
    Button(action: onDismiss) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "info.circle.fill")
          .foregroundStyle(notice.isError ? Color.red : Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(notice.title)
            .font(.subheadline.weight(.semibold))
          if let message = notice.message, !message.isEmpty {
            Text(message)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.8))
              .lineLimit(3)
          }
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Color(white: 0.12).opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: 520)
  }
}

/// "Toggle Stats" panel.
@MainActor
struct PlayerStatsView: View {
  let lines: [PlayerStatLine]
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text("Stats")
          .font(.caption.weight(.bold))
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
        }
        .buttonStyle(.plain)
      }
      ForEach(lines) { line in
        Text("\(line.label): \(line.value)")
          .font(.caption.monospaced())
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white)
    .padding(12)
    .frame(maxWidth: 340, alignment: .leading)
    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// Keyboard shortcut help ("Keybinds [`]").
@MainActor
struct PlayerKeybindsOverlay: View {
  let onClose: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.75)
        .ignoresSafeArea()
        .onTapGesture(perform: onClose)
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Keybinds")
            .font(.title3.bold())
          Spacer()
          Button(action: onClose) {
            Image(systemName: "xmark")
              .font(.headline)
          }
          .buttonStyle(.plain)
        }
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 10) {
            ForEach(PlayerKeybind.all) { keybind in
              HStack(spacing: 10) {
                Text(keybind.key)
                  .font(.system(.body, design: .monospaced).weight(.bold))
                  .frame(minWidth: 52)
                  .padding(.vertical, 4)
                  .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Text(keybind.description)
                  .font(.subheadline)
              }
            }
          }
        }
      }
      .foregroundStyle(.white)
      .padding(22)
      .frame(maxWidth: 760, maxHeight: 460)
      .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
      .padding(24)
    }
  }
}

/// "Subtitle Offset" (subDelay input of the subtitle menu).
@MainActor
struct PlayerSubtitleOffsetPanel: View {
  let delay: Double
  let onChange: (Double) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Text("Subtitle Offset")
        .font(.headline)
      HStack(spacing: 18) {
        stepButton("minus", delta: -0.1)
        Text(String(format: "%+.1f s", delay))
          .font(.title3.monospacedDigit().weight(.semibold))
          .frame(minWidth: 96)
        stepButton("plus", delta: 0.1)
      }
      HStack(spacing: 10) {
        Button("-0.5 s") { onChange(delay - 0.5) }
          .buttonStyle(.bordered)
        Button("Reset") { onChange(0) }
          .buttonStyle(.bordered)
        Button("+0.5 s") { onChange(delay + 0.5) }
          .buttonStyle(.bordered)
        Button("Done", action: onClose)
          .buttonStyle(.borderedProminent)
      }
      Text("Positive values show subtitles earlier. Applies to external subtitles.")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
        .multilineTextAlignment(.center)
    }
    .foregroundStyle(.white)
    .padding(20)
    .frame(maxWidth: 420)
    .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
    .padding(24)
  }

  private func stepButton(_ systemName: String, delta: Double) -> some View {
    Button {
      onChange(delay + delta)
    } label: {
      Image(systemName: systemName)
        .font(.title3.weight(.bold))
        .frame(width: 44, height: 44)
        .background(Color.white.opacity(0.15), in: Circle())
    }
    .buttonStyle(.plain)
  }
}

/// Double-tap seek feedback.
struct PlayerSeekFeedback: Equatable {
  var forward: Bool
  var amount: Double
}

@MainActor
struct PlayerSeekFeedbackView: View {
  let feedback: PlayerSeekFeedback

  var body: some View {
    HStack {
      if feedback.forward { Spacer(minLength: 0) }
      VStack(spacing: 6) {
        Image(systemName: feedback.forward ? "goforward" : "gobackward")
          .font(.system(size: 28, weight: .semibold))
        Text("\(feedback.forward ? "+" : "-")\(String(format: "%g", feedback.amount)) s")
          .font(.headline.monospacedDigit())
      }
      .foregroundStyle(.white)
      .frame(width: 110, height: 110)
      .background(Circle().fill(Color.black.opacity(0.45)))
      .padding(.horizontal, 56)
      if !feedback.forward { Spacer(minLength: 0) }
    }
  }
}
