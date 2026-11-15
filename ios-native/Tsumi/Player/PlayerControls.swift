import SwiftUI

// Controls overlay of the player (top bar, middle buttons, seekbar and bottom bar of PlayerPage.svelte).

@MainActor
struct PlayerControlsOverlay: View {
  let controller: PlayerController
  /// Any interaction restarts the auto-hide timer (resetImmerse).
  let onInteraction: () -> Void
  let onShowEpisodes: () -> Void
  let onImportSubtitles: () -> Void
  let onShowSubtitleOffset: () -> Void
  let onShowKeybinds: () -> Void
  /// Opens the Watch Together panel; the button only shows while in a lobby.
  var onShowWatchTogether: (() -> Void)? = nil

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        LinearGradient(colors: [Color.black.opacity(0.75), Color.clear], startPoint: .top, endPoint: .bottom)
          .frame(height: 150)
        Spacer(minLength: 0)
        LinearGradient(colors: [Color.clear, Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
          .frame(height: 190)
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)

      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 0)
        if controller.isReady && !controller.isLoadingEpisode && controller.fillerPrompt == nil {
          centerControls
        }
        Spacer(minLength: 0)
        bottomBar
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 8)
    }
    .foregroundStyle(.white)
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(alignment: .center, spacing: 12) {
      iconButton("xmark", label: "Exit", size: 22) { controller.close() }
      if controller.canMinimize {
        // Leaves the player without stopping it: in-app miniplayer (Miniplayer.svelte).
        iconButton("chevron.down", label: "Minimize", size: 20) { controller.minimize() }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(controller.displayTitle)
          .font(.headline)
          .lineLimit(1)
        if let line = controller.episodeLine {
          Text(line)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let onShowWatchTogether, WatchTogetherClient.shared.isInLobby {
        W2GPlayerButton(unread: WatchTogetherClient.shared.unreadCount) {
          onInteraction()
          onShowWatchTogether()
        }
      }
      if controller.canOpenDetails {
        iconButton("eye", label: "Now Playing") { controller.openDetails() }
      }
      PlayerAirPlayButton()
        .frame(width: 40, height: 40)
        .accessibilityLabel("AirPlay")
      if controller.isPictureInPictureSupported {
        iconButton(controller.isPictureInPictureActive ? "pip.exit" : "pip.enter", label: "Popout Window") {
          controller.togglePictureInPicture()
        }
        .disabled(!controller.isPictureInPicturePossible && !controller.isPictureInPictureActive)
        .opacity(controller.isPictureInPicturePossible || controller.isPictureInPictureActive ? 1 : 0.4)
      }
    }
  }

  // MARK: - Middle

  private var playIcon: String {
    if controller.hasEnded { return "arrow.clockwise" }
    return controller.isPlaying ? "pause.fill" : "play.fill"
  }

  private var centerControls: some View {
    HStack(spacing: 34) {
      centerButton("gobackward", size: 28, label: "Rewind") { controller.rewind() }
      centerButton("backward.end.fill", size: 28, label: "Last") {
        Task { await controller.playPrevious() }
      }
      .opacity(controller.hasLast ? 1 : 0)
      .disabled(!controller.hasLast)
      centerButton(playIcon, size: 50, label: "Play/Pause") { controller.togglePlayPause() }
      centerButton("forward.end.fill", size: 28, label: "Next") {
        Task { await controller.playNext() }
      }
      .opacity(controller.hasNext ? 1 : 0)
      .disabled(!controller.hasNext)
      centerButton("goforward", size: 28, label: "Seek") { controller.forward() }
    }
  }

  private func centerButton(_ systemName: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
    Button {
      onInteraction()
      action()
    } label: {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .semibold))
        .frame(width: size + 30, height: size + 30)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.5), radius: 6)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  // MARK: - Bottom bar

  private var timeLabel: String {
    let total = controller.safeDuration
    let full = PlayerTime.full(for: total)
    let time = controller.displayTime
    return "\(PlayerTime.format(time, full: full)) / \(PlayerTime.format(total - time, full: full))"
  }

  private var bottomBar: some View {
    VStack(spacing: 4) {
      PlayerScrubber(controller: controller, onInteraction: onInteraction)
        .frame(height: 30)
      HStack(spacing: 6) {
        Text(timeLabel)
          .font(.system(size: 14, weight: .medium).monospacedDigit())
        if controller.playbackRate != 1 {
          Text(String(format: "x%.1f", Double(controller.playbackRate)))
            .font(.system(size: 14, weight: .medium).monospacedDigit())
            .padding(.leading, 8)
        }
        Spacer(minLength: 4)
        if controller.session.servers.count > 1 {
          serverMenu
        }
        if controller.audioTracks.count > 1 {
          audioMenu
        }
        subtitleMenu
        speedMenu
        if controller.canLoadEpisodes || !controller.episodeList.isEmpty {
          iconButton("list.bullet", label: "Episodes") { onShowEpisodes() }
        }
        moreMenu
      }
    }
  }

  private var serverMenu: some View {
    Menu {
      Section("Servers") {
        ForEach(controller.session.servers.indices, id: \.self) { index in
          Button {
            onInteraction()
            controller.switchServer(to: index)
          } label: {
            menuLabel(controller.serverName(index), selected: index == controller.activeServerIndex)
          }
        }
      }
    } label: {
      menuIcon("server.rack")
    }
    .accessibilityLabel("Servers")
  }

  private var audioMenu: some View {
    Menu {
      Section("Audio Tracks") {
        ForEach(controller.audioTracks) { track in
          Button {
            onInteraction()
            controller.selectAudio(track.id)
          } label: {
            menuLabel(track.name, selected: controller.selectedAudioTrack == track.id)
          }
        }
      }
    } label: {
      menuIcon("waveform")
    }
    .accessibilityLabel("Audio Tracks")
  }

  private var subtitleMenu: some View {
    Menu {
      Section("Subtitles") {
        Button {
          onInteraction()
          controller.selectSubtitle(.off)
        } label: {
          menuLabel("OFF", selected: controller.subtitleChoice == .off)
        }
        ForEach(controller.embeddedSubtitleTracks) { track in
          Button {
            onInteraction()
            controller.selectSubtitle(.embedded(track.id))
          } label: {
            menuLabel(track.name, selected: controller.subtitleChoice == .embedded(track.id))
          }
        }
        ForEach(controller.externalSubtitleTracks) { track in
          Button {
            onInteraction()
            controller.selectSubtitle(.external(track.id))
          } label: {
            menuLabel(track.name, selected: controller.subtitleChoice == .external(track.id))
          }
        }
      }
      Section {
        Button {
          onInteraction()
          onImportSubtitles()
        } label: {
          Label("Add Subtitles", systemImage: "doc.badge.plus")
        }
        Button {
          onInteraction()
          controller.pasteSubtitles()
        } label: {
          Label("Paste Subtitles", systemImage: "doc.on.clipboard")
        }
        Button {
          onInteraction()
          onShowSubtitleOffset()
        } label: {
          Label("Subtitle Offset", systemImage: "plus.forwardslash.minus")
        }
      }
    } label: {
      menuIcon(controller.subtitleChoice == .off ? "captions.bubble" : "captions.bubble.fill")
    }
    .accessibilityLabel("Subtitles")
  }

  private var speedMenu: some View {
    Menu {
      Section("Playback Speed") {
        ForEach(PlayerController.speedOptions, id: \.self) { rate in
          Button {
            onInteraction()
            controller.setRate(rate)
          } label: {
            menuLabel(PlayerController.rateLabel(rate), selected: abs(controller.playbackRate - rate) < 0.001)
          }
        }
      }
    } label: {
      menuIcon("speedometer")
    }
    .accessibilityLabel("Playback Speed")
  }

  private var moreMenu: some View {
    Menu {
      Button {
        onInteraction()
        controller.skip()
      } label: {
        Label("Skip Intro/90s", systemImage: "forward.end.alt")
      }
      Menu {
        ForEach(PlayerChapterSource.allCases) { source in
          Button {
            onInteraction()
            controller.setChapterSource(source)
          } label: {
            menuLabel(source.label, selected: controller.chapterSource == source)
          }
        }
      } label: {
        Label("Chapter Source", systemImage: "bookmark")
      }
      Menu {
        ForEach(PlayerExternalApp.allCases) { app in
          Button(app.name) {
            controller.openInExternalPlayer(app)
          }
        }
      } label: {
        Label("External Player", systemImage: "arrow.up.forward.app")
      }
      Button {
        onInteraction()
        controller.toggleVideoFill()
      } label: {
        menuLabel("Video Cover", selected: controller.videoFill)
      }
      Button {
        onInteraction()
        controller.toggleStats()
      } label: {
        Label("Toggle Stats", systemImage: "chart.bar")
      }
      Button {
        onInteraction()
        controller.takeScreenshot()
      } label: {
        Label("Save Screenshot to Clipboard", systemImage: "camera")
      }
      if controller.canOpenDetails {
        Button {
          controller.openDetails()
        } label: {
          Label("Now Playing", systemImage: "eye")
        }
      }
      if let download = controller.onDownloadEpisode {
        Button {
          onInteraction()
          download()
        } label: {
          Label("Download Episode", systemImage: "arrow.down.to.line")
        }
      }
      Button {
        onShowKeybinds()
      } label: {
        Label("Keybinds", systemImage: "keyboard")
      }
    } label: {
      menuIcon("ellipsis.circle")
    }
    .accessibilityLabel("More")
  }

  // MARK: - Helpers

  @ViewBuilder
  private func menuLabel(_ title: String, selected: Bool) -> some View {
    if selected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private func menuIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 19, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 40, height: 40)
      .contentShape(Rectangle())
  }

  private func iconButton(_ systemName: String, label: String, size: CGFloat = 19, action: @escaping () -> Void) -> some View {
    Button {
      onInteraction()
      action()
    } label: {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .semibold))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// Seekbar with buffered range, chapter marks, skippable chapters and a scrub preview (perfect-seekbar).
@MainActor
struct PlayerScrubber: View {
  let controller: PlayerController
  let onInteraction: () -> Void
  @State private var dragFraction: CGFloat?

  init(controller: PlayerController, onInteraction: @escaping () -> Void) {
    self.controller = controller
    self.onInteraction = onInteraction
  }

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let total = controller.safeDuration
      let progress: CGFloat = total > 0 ? CGFloat(min(max(controller.displayTime / total, 0), 1)) : 0
      let fraction = dragFraction ?? progress
      let buffered: CGFloat = total > 0 ? CGFloat(min(max(controller.bufferedTime / total, 0), 1)) : 0
      let accent: Color = controller.isEpisodeWatched ? Color.green.opacity(0.8) : Color.accentColor
      let segments = controller.scrubberSegments
      let knob: CGFloat = dragFraction == nil ? 12 : 18

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.22))
          .frame(width: width, height: 4)
        Capsule()
          .fill(Color.white.opacity(0.45))
          .frame(width: width * buffered, height: 4)
        ForEach(segments) { segment in
          if segment.skippable {
            Rectangle()
              .fill(Color.yellow.opacity(0.4))
              .frame(width: max(width * CGFloat(segment.end - segment.start), 1), height: 4)
              .offset(x: width * CGFloat(segment.start))
          }
        }
        Capsule()
          .fill(accent)
          .frame(width: width * fraction, height: 4)
        ForEach(segments) { segment in
          if segment.start > 0 {
            Rectangle()
              .fill(Color.black.opacity(0.8))
              .frame(width: 2, height: 6)
              .offset(x: width * CGFloat(segment.start) - 1)
          }
        }
        Circle()
          .fill(accent)
          .frame(width: knob, height: knob)
          .offset(x: width * fraction - knob / 2)
      }
      .frame(width: width, height: proxy.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let newFraction = min(max(value.location.x / width, 0), 1)
            if dragFraction == nil { controller.beginScrubbing() }
            dragFraction = newFraction
            onInteraction()
            controller.scrub(to: Double(newFraction) * total)
          }
          .onEnded { value in
            let newFraction = min(max(value.location.x / width, 0), 1)
            dragFraction = nil
            controller.endScrubbing(at: Double(newFraction) * total)
            onInteraction()
          }
      )
      .overlay(alignment: .topLeading) {
        if let dragFraction {
          let bubbleWidth: CGFloat = 168
          let x = min(max(width * dragFraction - bubbleWidth / 2, 0), max(width - bubbleWidth, 0))
          previewBubble(time: Double(dragFraction) * total)
            .frame(width: bubbleWidth)
            .offset(x: x, y: controller.scrubPreview == nil ? -58 : -150)
            .allowsHitTesting(false)
        }
      }
    }
  }

  private func previewBubble(time: Double) -> some View {
    VStack(spacing: 4) {
      if let image = controller.scrubPreview {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 156)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      Text(PlayerTime.format(time, full: PlayerTime.full(for: controller.safeDuration)))
        .font(.caption.monospacedDigit().weight(.semibold))
      if let chapter = controller.chapterTitle(at: time) {
        Text(chapter)
          .font(.caption2)
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white)
    .padding(6)
    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
  }
}
