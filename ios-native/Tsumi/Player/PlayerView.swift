import SwiftUI
import UniformTypeIdentifiers

/// Full screen player UI (PlayerPage.svelte). Present it full screen (fullScreenCover) with a
/// PlayerController; `PlayerPresentation` does that and handles Picture in Picture minimize/restore.
@MainActor
struct PlayerView: View {
  let controller: PlayerController

  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>?
  @State private var showEpisodes = false
  @State private var showImporter = false
  @State private var showSubtitleOffset = false
  @State private var showKeybinds = false
  @State private var seekFeedback: PlayerSeekFeedback?
  @State private var feedbackTask: Task<Void, Never>?
  /// Watch Together side panel (W2GPlayerPanel).
  @State private var showWatchTogether = false
  @FocusState private var keyboardFocused: Bool

  init(controller: PlayerController) {
    self.controller = controller
  }

  var body: some View {
    ZStack {
      videoLayers
      controlLayers
      watchTogetherLayer
      promptLayers
      panelLayers
    }
    .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    .animation(.easeInOut(duration: 0.2), value: controller.notice)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showEpisodes) {
      PlayerEpisodeListSheet(controller: controller)
    }
    .fileImporter(isPresented: $showImporter, allowedContentTypes: PlayerSubtitleParser.importTypes) { result in
      if case .success(let url) = result {
        controller.importSubtitleFile(at: url)
      }
    }
    .onDrop(of: [UTType.data], isTargeted: nil) { providers in
      // Subtitle files or text dropped on the player (clipboard.js drop handler).
      controller.importDroppedSubtitles(providers)
    }
    .focusable()
    .focusEffectDisabled()
    .focused($keyboardFocused)
    .onKeyPress(phases: [.down, .repeat]) { press in
      handleKey(press)
    }
    .onAppear {
      PlayerOrientation.lockLandscape()
      controller.viewDidAppear()
      keyboardFocused = true
      scheduleHide()
    }
    .onDisappear {
      hideTask?.cancel()
      feedbackTask?.cancel()
      WatchTogetherClient.shared.setPlayerPanelOpen(false)
      PlayerOrientation.unlock()
      controller.viewDidDisappear()
    }
    .onChange(of: controller.isPlaying) { _, playing in
      if playing {
        scheduleHide()
      } else {
        hideTask?.cancel()
        controlsVisible = true
      }
    }
    .onChange(of: isCovered) { _, covered in
      if !covered { restoreKeyboardFocus() }
    }
    .onChange(of: showWatchTogether) { _, open in
      WatchTogetherClient.shared.setPlayerPanelOpen(open)
      if open {
        // The panel covers the trailing side: the controls come back when it closes.
        hideTask?.cancel()
        controlsVisible = false
      } else {
        revealControls()
      }
    }
    .onChange(of: WatchTogetherClient.shared.isInLobby) { _, inLobby in
      if !inLobby { showWatchTogether = false }
    }
  }

  /// A sheet, dialog or panel is shown over the player: the hardware keyboard focus is given back to the
  /// player when the last one closes (episode list, Files importer, details, extension dialogs, panels).
  private var isCovered: Bool {
    showEpisodes || showImporter || showSubtitleOffset || showKeybinds || showWatchTogether
      || controller.isExternalOverlayPresented || PlaybackRequestCoordinator.shared.presentation != nil
  }

  private func restoreKeyboardFocus() {
    Task { @MainActor in
      // Let the dismissal hand the focus back to this window first.
      try? await Task.sleep(nanoseconds: 200_000_000)
      if !isCovered { keyboardFocused = true }
    }
  }

  /// Video, external subtitles and the tap/double-tap/pinch layer.
  @ViewBuilder
  private var videoLayers: some View {
    Color.black
      .ignoresSafeArea()

    PlayerVideoSurface(controller: controller)
      .ignoresSafeArea()

    PlayerSubtitleCanvas(controller: controller, raised: controlsVisible)

    gestureLayer
      .ignoresSafeArea()

    if let feedback = seekFeedback {
      PlayerSeekFeedbackView(feedback: feedback)
        .allowsHitTesting(false)
    }

    if showSpinner {
      ProgressView()
        .controlSize(.large)
        .tint(.white)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var controlLayers: some View {
    PlayerControlsOverlay(
      controller: controller,
      onInteraction: { revealControls() },
      onShowEpisodes: { showEpisodes = true },
      onImportSubtitles: { showImporter = true },
      onShowSubtitleOffset: { showSubtitleOffset = true },
      onShowKeybinds: { showKeybinds = true },
      onShowWatchTogether: { showWatchTogether = true }
    )
    .opacity(controlsVisible ? 1 : 0)
    .allowsHitTesting(controlsVisible)

    // Hidden with the controls, like `.immersed .skip` in PlayerPage.svelte.
    if let name = controller.currentSkippable, controlsVisible {
      skipButton(name)
    }
  }

  /// Watch Together (only while in a lobby): notices, chat bubbles, reactions, countdown, host requests, panel.
  @ViewBuilder
  private var watchTogetherLayer: some View {
    let client = WatchTogetherClient.shared
    if client.isInLobby {
      W2GPlayerLayer(client: client, panelOpen: $showWatchTogether, controlsVisible: controlsVisible)
    }
  }

  /// Filler prompt, playback error and episode loading.
  @ViewBuilder
  private var promptLayers: some View {
    if let label = controller.fillerPrompt {
      PlayerFillerPrompt(label: label) { skip in
        controller.answerFillerPrompt(skip: skip)
      }
    }

    if let failure = controller.failure {
      PlayerErrorView(
        failure: failure,
        canTryNextServer: controller.canTryNextServer,
        serverName: controller.serverName(controller.activeServerIndex),
        onReload: { controller.retry() },
        onNextServer: { controller.tryNextServer() },
        onClose: { controller.close() }
      )
    }

    if let episode = controller.loadingEpisode {
      PlayerEpisodeLoadingView(episode: episode)
    }

    // Cross-device resume: "Resume at 12:34 (from PC)".
    PlayerResumeOfferView(controller: controller)
  }

  /// Stats, notices, subtitle offset and keybind help.
  @ViewBuilder
  private var panelLayers: some View {
    if let stats = controller.stats {
      VStack {
        HStack {
          PlayerStatsView(lines: stats) { controller.toggleStats() }
          Spacer(minLength: 0)
        }
        Spacer(minLength: 0)
      }
      .padding(.top, 70)
      .padding(.leading, 20)
    }

    if let notice = controller.notice {
      VStack {
        PlayerNoticeBanner(notice: notice) { controller.dismissNotice() }
          .padding(.top, 12)
        Spacer(minLength: 0)
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    }

    if showSubtitleOffset {
      PlayerSubtitleOffsetPanel(
        delay: controller.subtitleDelay,
        onChange: { controller.setSubtitleDelay($0) },
        onClose: { showSubtitleOffset = false }
      )
    }

    if showKeybinds {
      PlayerKeybindsOverlay { showKeybinds = false }
    }
  }

  private var showSpinner: Bool {
    guard controller.failure == nil, controller.loadingEpisode == nil, controller.fillerPrompt == nil else { return false }
    return controller.isBuffering || controller.phase == .loading
  }

  // MARK: - Gestures

  /// Single tap toggles the controls (toggleImmerse on touch screens); double tap on the left/right half
  /// seeks back/forward by `playerSeek`; pinch toggles the video cover.
  private var gestureLayer: some View {
    HStack(spacing: 0) {
      tapZone(forward: false)
      tapZone(forward: true)
    }
    .simultaneousGesture(
      MagnifyGesture()
        .onEnded { value in
          if value.magnification > 1.15 {
            controller.setVideoFill(true)
          } else if value.magnification < 0.87 {
            controller.setVideoFill(false)
          }
        }
    )
  }

  private func tapZone(forward: Bool) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .gesture(
        TapGesture(count: 2)
          .onEnded { doubleTapSeek(forward: forward) }
          .exclusively(before: TapGesture(count: 1).onEnded { toggleControls() })
      )
  }

  private func doubleTapSeek(forward: Bool) {
    guard controller.isReady else { return }
    let step = AppSettings.shared.values.playerSeek
    if forward {
      controller.forward()
    } else {
      controller.rewind()
    }
    var amount = step
    if let current = seekFeedback, current.forward == forward {
      amount += current.amount
    }
    seekFeedback = PlayerSeekFeedback(forward: forward, amount: amount)
    feedbackTask?.cancel()
    feedbackTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 800_000_000)
      guard !Task.isCancelled else { return }
      seekFeedback = nil
    }
  }

  private func skipButton(_ name: String) -> some View {
    VStack {
      Spacer(minLength: 0)
      HStack {
        Spacer(minLength: 0)
        Button {
          revealControls()
          controller.skip()
        } label: {
          Label("Skip \(name)", systemImage: "forward.fill")
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
      }
      .padding(.trailing, 24)
      .padding(.bottom, 104)
    }
  }

  // MARK: - Controls visibility (immerse)

  private func toggleControls() {
    // A tap on the video closes the Watch Together panel first.
    if showWatchTogether {
      showWatchTogether = false
      return
    }
    controlsVisible.toggle()
    if controlsVisible {
      scheduleHide()
    } else {
      hideTask?.cancel()
    }
  }

  private func revealControls() {
    if !controlsVisible { controlsVisible = true }
    scheduleHide()
  }

  /// Hides the controls 3 s after the last interaction while playing (never while paused).
  private func scheduleHide() {
    hideTask?.cancel()
    guard controller.isPlaying else { return }
    hideTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled else { return }
      if controller.isPlaying && !controller.isScrubbing && !showSubtitleOffset && !showKeybinds && !showWatchTogether {
        controlsVisible = false
      }
    }
  }

  // MARK: - Keyboard (hardware keyboard on iPad, svelte-keybinds)

  /// Held keys repeat for seeking, volume and speed (svelte-keybinds runs on every keydown, repeats included).
  private static func repeats(_ press: KeyPress) -> Bool {
    if press.key == .leftArrow || press.key == .rightArrow || press.key == .upArrow || press.key == .downArrow {
      return true
    }
    return press.characters == "[" || press.characters == "]"
  }

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    // The Watch Together panel has a text field: its keys are not player shortcuts.
    if showWatchTogether {
      if press.key == .escape {
        showWatchTogether = false
        return .handled
      }
      return .ignored
    }
    if press.phase == .repeat && !PlayerView.repeats(press) {
      // Swallowed so a held Space or letter does not toggle again and again.
      return .handled
    }
    if press.key == .escape {
      if showKeybinds {
        showKeybinds = false
        return .handled
      }
      if showSubtitleOffset {
        showSubtitleOffset = false
        return .handled
      }
      return .ignored
    }
    revealControls()
    if press.key == .space {
      controller.togglePlayPause()
      return .handled
    }
    if press.key == .leftArrow {
      controller.rewind()
      return .handled
    }
    if press.key == .rightArrow {
      controller.forward()
      return .handled
    }
    if press.key == .upArrow {
      controller.adjustVolume(by: 0.05)
      return .handled
    }
    if press.key == .downArrow {
      controller.adjustVolume(by: -0.05)
      return .handled
    }
    switch press.characters.lowercased() {
    case "n":
      Task { await controller.playNext() }
    case "b":
      Task { await controller.playPrevious() }
    case "m":
      controller.toggleMute()
    case "p":
      controller.togglePictureInPicture()
    case "s":
      controller.skip()
    case "w":
      controller.toggleVideoFill()
    case "c":
      controller.cycleSubtitles()
    case "i":
      controller.toggleStats()
    case "o":
      controller.openDetails()
    case "h":
      showEpisodes.toggle()
    case "x":
      controller.takeScreenshot()
    case "`":
      showKeybinds.toggle()
    case "[":
      controller.adjustRate(by: -0.1)
    case "]":
      controller.adjustRate(by: 0.1)
    case "\\":
      controller.setRate(1)
    default:
      return .ignored
    }
    return .handled
  }
}
