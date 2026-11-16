import SwiftUI
import Observation

/// State of the compact "default extension" dialog (DefaultLoadingModal.svelte).
@MainActor
@Observable
final class DefaultLoadingModel {
  let media: Media
  let episode: EpisodeRef
  var statusText = "Connecting to extension..."

  init(media: Media, episode: EpisodeRef) {
    self.media = media
    self.episode = episode
  }

  var title: String { ExtensionContext.shared.displayTitle(media) }
}

/// State of the extension results sheet (ExtensionModal.svelte + ExtensionResults.svelte).
@MainActor
@Observable
final class ExtensionPickerModel {
  let media: Media
  let episode: EpisodeRef
  /// The default extension failed: banner + reason (search.defaultFailed / failReason).
  let defaultFailed: Bool
  let failReason: String?

  /// Some extensions are still searching (the groups already found are shown meanwhile).
  var loading = true
  /// Results per extension, starred first then in the order of the settings, added as they come.
  var groups: [ExtensionResultGroup] = []
  /// Extensions still searching (names).
  var pendingNames: [String] = []
  /// Extensions that failed or did not answer in time (names).
  var failedNames: [String] = []
  var playingResultID: String?
  var expandedGroups: Set<String> = []
  /// Error toast of selectResult ("No episodes found for this title", "Stream failed: ...").
  var errorMessage: String?
  /// Server selector opened on top of the results.
  var serverChoice: PlaybackServerChoice?
  var hasEnabledExtensions = true

  @ObservationIgnored var onPlayback: ((ResolvedPlayback) -> Void)?
  /// Result behind the playback passed to `onPlayback` (kept for the next / previous episode).
  @ObservationIgnored private(set) var lastSource: PlaybackSource?
  /// Result behind `serverChoice`.
  @ObservationIgnored private var serverChoiceSource: (id: UUID, source: PlaybackSource)?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var selectTask: Task<Void, Never>?
  @ObservationIgnored private var started = false

  init(media: Media, episode: EpisodeRef, defaultFailed: Bool = false, failReason: String? = nil) {
    self.media = media
    self.episode = episode
    self.defaultFailed = defaultFailed
    self.failReason = failReason
  }

  var title: String { ExtensionContext.shared.displayTitle(media) }

  /// Starts the search once (the view calls it on appear).
  func start() {
    guard !started else { return }
    started = true
    searchTask = Task { [weak self] in await self?.searchExtensions() }
  }

  /// Longest wait for one extension's search: a stuck or very slow extension no longer holds the results back.
  static let searchDeadline: TimeInterval = 40

  /// searchExtensions: every enabled extension at once; each group is shown as soon as its extension answers,
  /// starred first, then in the order of the settings.
  func searchExtensions() async {
    loading = true
    groups = []
    pendingNames = []
    failedNames = []
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads()
    let title = self.title
    let media = self.media
    let enabled = manager.enabledExtensionsStarredFirst()
    hasEnabledExtensions = !enabled.isEmpty
    guard !title.isEmpty, !enabled.isEmpty else {
      loading = false
      return
    }
    let starred = manager.starredKey
    let deadline = Self.searchDeadline
    var order: [String: Int] = [:]
    for (index, ext) in enabled.enumerated() where order[ext.key] == nil {
      order[ext.key] = index
    }
    var pending = enabled.map { (key: $0.key, name: $0.displayName) }
    pendingNames = pending.map { $0.name }
    await withTaskGroup(of: (key: String, group: ExtensionResultGroup?, failed: Bool).self) { group in
      for ext in enabled {
        group.addTask {
          do {
            let found = try await PlaybackResolver.withDeadline(deadline) {
              try await PlaybackResolver.resultGroup(ext, title: title, media: media, starredKey: starred)
            }
            return (key: ext.key, group: found, failed: false)
          } catch {
            #if DEBUG
            print("[Extensions] Extension \(ext.key) search failed: \(error.localizedDescription)")
            #endif
            return (key: ext.key, group: nil, failed: !PlaybackResolver.isCancellation(error))
          }
        }
      }
      for await answer in group {
        let name = pending.first { $0.key == answer.key }?.name
        pending.removeAll { $0.key == answer.key }
        pendingNames = pending.map { $0.name }
        if let found = answer.group {
          insert(found, order: order)
        } else if answer.failed, let name {
          failedNames.append(name)
        }
      }
    }
    pendingNames = []
    loading = false
  }

  /// Keeps `groups` starred first, then in the order of the settings, whatever order the answers come in.
  private func insert(_ group: ExtensionResultGroup, order: [String: Int]) {
    func rank(_ item: ExtensionResultGroup) -> (Int, Int) {
      (item.isStarred ? 0 : 1, order[item.extensionKey] ?? Int.max)
    }
    let index = groups.firstIndex { rank($0) > rank(group) } ?? groups.count
    groups.insert(group, at: index)
  }

  func isExpanded(_ key: String) -> Bool { expandedGroups.contains(key) }

  func toggleGroup(_ key: String) {
    if expandedGroups.contains(key) { expandedGroups.remove(key) } else { expandedGroups.insert(key) }
  }

  /// selectResult: episodes -> stream -> server choice or playback.
  func select(_ result: ExtensionSearchResult) {
    guard playingResultID == nil else { return }
    guard let ext = ExtensionManager.shared.loadedExtension(result.extensionKey) else {
      errorMessage = "Stream failed: Extension \(result.extensionKey) not loaded"
      return
    }
    playingResultID = result.id
    errorMessage = nil
    let media = self.media
    let episode = self.episode
    selectTask = Task { [weak self] in
      do {
        let found = try await PlaybackResolver.resolveSourceStream(ext, href: result.href, episode: episode, title: result.title)
        guard let self, !Task.isCancelled else { return }
        self.playingResultID = nil
        switch PlaybackResolver.nextStep(media: media, episode: found.episode, stream: found.stream, extensionKey: ext.key) {
        case .ready(let playback):
          self.lastSource = found.source
          self.onPlayback?(playback)
        case .chooseServer(let choice):
          self.serverChoiceSource = (id: choice.id, source: found.source)
          self.serverChoice = choice
        }
      } catch {
        guard let self else { return }
        self.playingResultID = nil
        if PlaybackResolver.isCancellation(error) { return }
        self.errorMessage = PlaybackResolver.manualFailureMessage(error)
      }
    }
  }

  /// Server picked in the selector opened from the results.
  func chooseServer(_ choice: PlaybackServerChoice, index: Int) {
    lastSource = serverChoiceSource?.id == choice.id ? serverChoiceSource?.source : nil
    serverChoice = nil
    onPlayback?(choice.playback(selecting: index))
  }

  func cancel() {
    searchTask?.cancel()
    selectTask?.cancel()
  }
}

/// What the coordinator currently shows.
struct PlaybackRequestPresentation: Identifiable {
  enum Kind {
    case loading(DefaultLoadingModel)
    case picker(ExtensionPickerModel)
    case server(PlaybackServerChoice)
  }

  let id = UUID()
  let kind: Kind
}

/// Entry point of playback (playAnime in ExtensionModal.svelte): with a default extension it
/// auto-plays (DefaultLoadingView), falling back to the results sheet (ExtensionPickerView) with a
/// "Default extension failed" banner; several servers open the server selector. The resolved
/// stream is published in `ready` and passed to `onReady`; the app hands it to the player, and
/// `source(for:)` tells which search result it came from (used for the next / previous episode).
///
/// The shell presents `presentation` (ShellPlaybackDialogHost on the top layer); call
/// `PlaybackRequestCoordinator.shared.play(media:episode:force:)`.
@MainActor
@Observable
final class PlaybackRequestCoordinator {
  static let shared = PlaybackRequestCoordinator()

  /// Sheet currently shown (loading dialog, results, or server selector).
  var presentation: PlaybackRequestPresentation?
  /// Last resolved playback (also sent to `onReady`). The app can clear it with `consumeReady()`.
  private(set) var ready: ResolvedPlayback?

  /// Called on the main actor when a playback is ready (open the player, share with Watch Together...).
  @ObservationIgnored var onReady: ((ResolvedPlayback) -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var activePicker: ExtensionPickerModel?
  /// Search result of the last delivered playback.
  @ObservationIgnored private var deliveredSource: (id: UUID, source: PlaybackSource)?
  /// Search result behind a server selector opened by the default flow.
  @ObservationIgnored private var serverChoiceSources: [UUID: PlaybackSource] = [:]

  private init() {}

  /// playAnime(media, episode, force): `force` skips the default extension and shows every result.
  func play(media: Media, episode: EpisodeRef, force: Bool = false) {
    // A downloaded episode plays from disk (also offline); force (long press) still opens the extensions.
    if !force && DownloadCenter.shared.playIfDownloaded(media: media, episode: episode) { return }
    cancelRunningWork()
    if AppSettings.shared.values.defaultExtension != nil && !force {
      let model = DefaultLoadingModel(media: media, episode: episode)
      presentation = PlaybackRequestPresentation(kind: .loading(model))
      task = Task { [weak self] in await self?.autoPlay(model) }
    } else {
      openPicker(media: media, episode: episode, defaultFailed: false, failReason: nil)
    }
  }

  /// playAnime(media, number): absolute episode number (NaN in the Svelte app became 1; episode 0 is kept).
  func play(media: Media, episodeNumber: Int, force: Bool = false) {
    let number = episodeNumber < 0 ? 1 : episodeNumber
    play(media: media, episode: EpisodeRef(number: number, season: nil, localEpisode: nil), force: force)
  }

  /// Search result the playback was resolved from (nil when unknown).
  func source(for playback: ResolvedPlayback) -> PlaybackSource? {
    guard let deliveredSource, deliveredSource.id == playback.id else { return nil }
    return deliveredSource.source
  }

  /// Returns and clears the last resolved playback.
  func consumeReady() -> ResolvedPlayback? {
    let value = ready
    ready = nil
    return value
  }

  /// Closes whatever is shown and stops the running resolution.
  func dismiss() {
    cancelRunningWork()
    presentation = nil
  }

  /// Called when a sheet goes away: if nothing replaced it, the user closed it, so stop the work.
  func sheetDidDismiss() {
    if presentation == nil { cancelRunningWork() }
  }

  // MARK: Flow

  private func autoPlay(_ model: DefaultLoadingModel) async {
    do {
      let resolved = try await PlaybackResolver.resolveWithDefaultSource(media: model.media, episode: model.episode) { [weak model] status in
        model?.statusText = status
      }
      guard !Task.isCancelled, isShowing(model) else { return }
      switch PlaybackResolver.nextStep(media: model.media, episode: resolved.episode, stream: resolved.stream, extensionKey: resolved.source.extensionKey) {
      case .ready(let playback):
        deliver(playback, source: resolved.source)
      case .chooseServer(let choice):
        serverChoiceSources = [choice.id: resolved.source]
        presentation = PlaybackRequestPresentation(kind: .server(choice))
      }
    } catch {
      guard isShowing(model), !PlaybackResolver.isCancellation(error) else { return }
      #if DEBUG
      print("[Extensions] Default extension auto-play failed: \(error.localizedDescription)")
      #endif
      openPicker(media: model.media, episode: model.episode, defaultFailed: true, failReason: PlaybackResolver.failureReason(error))
    }
  }

  private func openPicker(media: Media, episode: EpisodeRef, defaultFailed: Bool, failReason: String?) {
    let model = ExtensionPickerModel(media: media, episode: episode, defaultFailed: defaultFailed, failReason: failReason)
    model.onPlayback = { [weak self, weak model] playback in
      guard let self, let model, self.activePicker === model, self.presentation != nil else { return }
      self.deliver(playback, source: model.lastSource)
    }
    activePicker = model
    presentation = PlaybackRequestPresentation(kind: .picker(model))
  }

  /// Server picked in the selector opened by the default flow (ServerSelectorModal onSelect).
  func chooseServer(_ choice: PlaybackServerChoice, index: Int) {
    deliver(choice.playback(selecting: index), source: serverChoiceSources[choice.id])
  }

  /// launchPlayer: close the dialogs and publish the playback.
  func deliver(_ playback: ResolvedPlayback) {
    deliver(playback, source: nil)
  }

  /// launchPlayer, remembering the search result the playback came from.
  func deliver(_ playback: ResolvedPlayback, source: PlaybackSource?) {
    cancelRunningWork()
    presentation = nil
    serverChoiceSources = [:]
    deliveredSource = source.map { (id: playback.id, source: $0) }
    ready = playback
    onReady?(playback)
  }

  private func isShowing(_ model: DefaultLoadingModel) -> Bool {
    if let presentation, case .loading(let current) = presentation.kind { return current === model }
    return false
  }

  private func cancelRunningWork() {
    task?.cancel()
    task = nil
    activePicker?.cancel()
    activePicker = nil
  }
}

/// Sheet content for one presentation.
@MainActor
struct PlaybackRequestSheetView: View {
  let presentation: PlaybackRequestPresentation

  var body: some View {
    // `.id`: every request gets fresh views, so a sheet opened again never shows the state (title, header
    // image, expanded groups) of the previous request.
    switch presentation.kind {
    case .loading(let model):
      DefaultLoadingView(model: model)
        .id(presentation.id)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    case .picker(let model):
      ExtensionPickerView(model: model, onClose: { PlaybackRequestCoordinator.shared.dismiss() })
        .id(presentation.id)
        .presentationDetents([.large])
    case .server(let choice):
      ServerPickerView(
        servers: choice.servers,
        onSelect: { index in PlaybackRequestCoordinator.shared.chooseServer(choice, index: index) },
        onBack: { PlaybackRequestCoordinator.shared.dismiss() }
      )
      .id(presentation.id)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
  }
}
