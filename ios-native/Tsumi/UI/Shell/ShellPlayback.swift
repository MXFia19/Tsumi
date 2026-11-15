import SwiftUI
import Observation

// Playback wiring: PlaybackRequestCoordinator.onReady → PlayerController (ExtensionResults.launchPlayer +
// PlayerPage.svelte hooks), episode switching from the search result that was played, else the extension flow
// (playNext / playLast / episode list / Watch Together setindex → playAnime), progress (animeprogress.js),
// list auto-complete (Helper.updateEntry),
// Watch Together sharing (session.js shareNowPlaying) and the play entry points of the shell
// (DetailsModal handlePlay for deep links and notifications, anime.js playMedia).

@MainActor
enum ShellPlayback {
  private static var generation = 0

  // MARK: - Entry points

  /// playAnime(media, episode, force).
  static func play(_ media: Media, episode: EpisodeRef, force: Bool = false) {
    PlaybackRequestCoordinator.shared.play(media: media, episode: episode, force: force)
  }

  /// playAnime(media, number): 0 stays 0 (zero episodes), like the JS number check.
  static func play(_ media: Media, number: Int) {
    play(media, episode: EpisodeRef(number: max(number, 0), season: nil, localEpisode: nil))
  }

  /// anime.js playMedia: start from the list progress (zero episode aware, completed → rewatch).
  static func playMedia(_ media: Media) async {
    if media.status == .notYetReleased && media.source == .anilist { return }
    let episode = await MediaListService.shared.startEpisode(for: media)
    play(media, number: episode)
  }

  /// tsumi://search/<id>: DetailsModal handlePlay(id) without episode, not direct.
  static func playFromLink(_ media: Media) async {
    if let progress = MediaListService.shared.entry(for: media)?.progress {
      play(media, number: progress != 0 ? progress + 1 : 0)
      return
    }
    await playMedia(media)
  }

  /// NotificationsModal play: handlePlay(id, episode, direct = true).
  static func playNotification(_ notification: MediaNotification) async {
    guard let media = await ShellNotificationMedia.resolve(notification, direct: true) else { return }
    if let episode = notification.episode, episode != 0 {
      play(media, number: episode)
      return
    }
    if let progress = MediaListService.shared.entry(for: media)?.progress, progress != 0 {
      play(media, number: progress + 1)
      return
    }
    await playMedia(media)
  }

  /// Watch Together 'media' → w2g-play → playAnime(cached media, episode).
  static func playRemote(_ media: Media, episode: EpisodeRef) {
    if let controller = PlayerPresentation.shared.controller {
      let session = controller.session
      let loading = controller.loadingEpisode
      let sameMedia = session.media.id == media.id
      let sameEpisode = session.episode.number == episode.number && session.episode.season == episode.season
      let loadingSame = loading.map { $0.number == episode.number && $0.season == episode.season } ?? false
      if sameMedia && (sameEpisode || loadingSame) { return }
    }
    Task { @MainActor in
      var resolved = MediaStore.shared.media(media.id)
      if resolved == nil, media.source == .anilist, let anilistId = media.anilistId {
        resolved = try? await AniListService.shared.media(id: anilistId)
      }
      ShellPlayback.play(resolved ?? media, episode: episode, force: false)
    }
  }

  /// Watch Together 'setindex' → the active player switches episode (not shared back).
  static func applyRemoteIndex(_ index: Int) {
    guard let controller = PlayerPresentation.shared.controller else { return }
    let current = controller.session.episode
    var switches = false
    if !controller.episodeList.isEmpty {
      if controller.episodeList.indices.contains(index) {
        let ref = controller.episodeList[index].ref
        switches = ref.number != current.number || ref.season != current.season
      }
    } else {
      switches = index != current.number
    }
    if switches {
      ShellState.shared.suppressShareUntil = Date().addingTimeInterval(20)
    }
    controller.applyRemoteIndex(index)
  }

  /// Watch Together toast; the lobby screen already shows its own banner when it is visible.
  static func showWatchTogetherNotice(_ title: String, _ message: String) {
    let lobbyVisible = AppRouter.shared.selectedTab == .watchTogether && ShellLayers.top == .root
    if lobbyVisible { return }
    ServiceMessages.shared.post(.info, title, message)
  }

  /// "Now Playing" entry and miniplayer tap: presents the player again (from Picture in Picture or the in-app
  /// miniplayer) once the root sheets are closed.
  static func restorePlayer() {
    let presentation = PlayerPresentation.shared
    guard let controller = presentation.controller else { return }
    ShellNavigation.clearRootSheets()
    // Stops PiP as a restore (sets restoringFromPiP before pip.stop()), so AVKit's stop is not taken for the
    // PiP window being closed and the player UI is presented here only once.
    controller.stopPictureInPictureForRestore()
    Task { @MainActor in
      await ShellPresentationTiming.waitUntilSettled(maxDepth: 0)
      if presentation.controller === controller {
        presentation.isPresented = true
      }
    }
  }

  /// playAnime(media, episode) from the player: default extension, else the extension picker
  /// (ExtensionModal.svelte), shown over the player. Used when the played result cannot give that episode.
  static func playWithExtensionFlow(_ media: Media, episode: EpisodeRef) {
    let coordinator = PlaybackRequestCoordinator.shared
    if episode.season != nil || episode.localEpisode != nil {
      coordinator.play(media: media, episode: episode)
    } else {
      coordinator.play(media: media, episodeNumber: episode.number)
    }
  }

  // MARK: - Player launch (PlaybackRequestCoordinator.onReady)

  /// launchPlayer: closes the dialogs and sheets, builds the session and presents the player.
  static func start(_ playback: ResolvedPlayback) {
    generation += 1
    let token = generation
    let source = PlaybackRequestCoordinator.shared.source(for: playback)
    let presentation = PlayerPresentation.shared
    let replacing = presentation.isPresented && presentation.controller != nil
    if replacing {
      ShellState.shared.replacingPlayer = true
      presentation.controller?.pause()
    }
    ShellNavigation.clearRootSheets()
    let loader = ShellEpisodeListLoader()
    loader.start(media: playback.media)
    let deadline = Date().addingTimeInterval(1.2)
    Task { @MainActor in
      if replacing {
        // Sheets over the player first, then the player itself, so the new one appears cleanly.
        await ShellPresentationTiming.waitUntilSettled(maxDepth: 1)
        guard token == ShellPlayback.generation else { return }
        presentation.dismiss()
      }
      await ShellPresentationTiming.waitUntilSettled(maxDepth: 0)
      while loader.result == nil && Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard token == ShellPlayback.generation else { return }
      let controller = ShellPlayback.makeController(playback, source: source, episodes: loader.result ?? [])
      if loader.result == nil {
        loader.onLoad = { [weak controller] list in
          controller?.setEpisodeList(list)
        }
      }
      ShellState.shared.replacingPlayer = false
      // PiP "restore" while a root sheet (details) is open: close it before presenting the player.
      presentation.restoreHandler = { ShellPlayback.restorePlayer() }
      presentation.present(controller)
    }
  }

  private static func makeController(_ playback: ResolvedPlayback, source: PlaybackSource?, episodes: [EpisodeInfo]) -> PlayerController {
    let media = playback.media
    let session = ShellPlayback.session(
      media: media,
      episode: playback.episode,
      servers: playback.servers,
      selectedServer: playback.selectedIndex,
      subtitleURL: playback.subtitleURL,
      episodes: episodes
    )
    let controller = PlayerController(session: session, episodeList: episodes)
    wire(controller, media: media, extensionKey: playback.extensionKey, source: source)
    controller.sourceName = ShellPlayback.extensionName(playback.extensionKey)
    return controller
  }

  /// PlaybackSession with everything the app already knows: the episode title, the saved position
  /// (loadAnimeProgress), the subtitle headers (the stream headers, like `streamHeaders`), the filler / recap
  /// flags and the zero episode from the episode list. Unknown flags stay nil so the player asks Jikan.
  static func session(
    media: Media,
    episode: EpisodeRef,
    servers: [StreamServer],
    selectedServer: Int,
    subtitleURL: URL?,
    episodes: [EpisodeInfo]
  ) -> PlaybackSession {
    let info = episodeInfo(in: episodes, for: episode)
    let server = servers.indices.contains(selectedServer) ? servers[selectedServer] : servers.first
    let headers = server?.headers ?? [:]
    let saved = AnimeProgressService.shared.record(mediaKey: media.id, episode: episode.number)?.currentTime
    let startTime: Double? = saved.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    return PlaybackSession(
      media: media,
      episode: episode,
      episodeTitle: info?.title,
      servers: servers,
      selectedServer: selectedServer,
      subtitleURL: subtitleURL,
      subtitleHeaders: subtitleURL != nil && !headers.isEmpty ? headers : nil,
      startTime: startTime,
      isFiller: info?.isFiller == true ? true : nil,
      isRecap: info?.isRecap == true ? true : nil,
      zeroEpisode: episodes.isEmpty ? nil : episodes.contains { $0.number == 0 }
    )
  }

  /// Every hook of the player (see PARITY/player.md "Wiring notes for the app step").
  private static func wire(_ controller: PlayerController, media: Media, extensionKey: String, source: PlaybackSource?) {
    // playNext / playLast / episode list / setindex: the same search result as the episode playing (a dub or
    // variant picked by hand is kept), no dialog over the player. When that fails: playAnime → default
    // extension or the picker, like PlayerPage.svelte.
    let memory = ShellPlaybackSourceMemory(source: source, extensionKey: extensionKey)
    controller.loadEpisode = { [weak controller] ref in
      let serverTitle = controller?.session.currentServer?.title
      let list = controller?.episodeList ?? []
      let current = MediaStore.shared.media(media.id) ?? media
      do {
        let resolved = try await ShellEpisodeResolver.resolve(
          media: current,
          episode: ref,
          source: memory.source,
          extensionKey: memory.extensionKey,
          preferredServerTitle: serverTitle
        )
        memory.source = resolved.source
        memory.extensionKey = resolved.source.extensionKey
        controller?.sourceName = ShellPlayback.extensionName(resolved.source.extensionKey)
        let playback = resolved.playback
        return ShellPlayback.session(
          media: current,
          episode: playback.episode,
          servers: playback.servers,
          selectedServer: playback.selectedIndex,
          subtitleURL: playback.subtitleURL,
          episodes: list
        )
      } catch {
        if PlaybackResolver.isCancellation(error) { throw error }
        ShellPlayback.playWithExtensionFlow(current, episode: ref)
        throw PlayerEpisodeHandedOff()
      }
    }
    // loadAnimeProgress (when the session has no startTime) / setAnimeProgress (mediaId + episode).
    controller.resumePosition = { media, episode in
      AnimeProgressService.shared.record(mediaKey: media.id, episode: episode.number)?.currentTime
    }
    // Cross-device resume (note of the list entry) and Trakt scrobbling: Services/PlaybackSyncService.swift.
    let sync = PlaybackSyncService.shared.attach(controller)
    controller.onProgress = { [weak controller] snapshot in
      AnimeProgressService.shared.set(mediaKey: snapshot.media.id, episode: snapshot.episode.number, currentTime: snapshot.currentTime, safeDuration: snapshot.duration)
      sync.progress(snapshot, playing: controller?.isPlaying ?? false)
    }
    controller.onPlaybackEnded = { _, _ in
      sync.ended()
    }
    // checkCompletion → Helper.updateEntry.
    controller.onAutocomplete = { media, episode in
      Task { @MainActor in
        await MediaListService.shared.updateAfterWatching(media, episode: episode.number)
      }
    }
    // shareNowPlaying (launchPlayer) for every started episode, except the ones a peer asked for.
    controller.onEpisodeStarted = { session in
      sync.started(session)
      if Date() < ShellState.shared.suppressShareUntil {
        ShellState.shared.suppressShareUntil = .distantPast
        return
      }
      WatchTogetherClient.shared.shareMedia(media: session.media, episode: session.episode)
    }
    controller.onClose = { [weak controller] in
      sync.closed()
      if let closed = controller?.session.media {
        ShellState.shared.lastWatched = MediaStore.shared.media(closed.id) ?? closed
      }
    }
    // Now Playing details (KeyO): details sheet over the player, which keeps playing (Svelte parity).
    controller.onOpenDetails = { media in
      ShellNavigation.openDetails(MediaStore.shared.media(media.id) ?? media)
    }
    // Watch Together (w2gEmitter 'player' / 'index', no autoplay during a session). v2: the action, its seek
    // distance and rate go with it (PROTOCOL.md `player.by/action/rate`); the lobby snaps a non-host back in
    // `host` mode instead of broadcasting. `onLocalStateChange` (v1) is left unset so nothing is sent twice.
    controller.onSyncAction = { action in
      let kind: W2GAction
      switch action.kind {
      case .play: kind = .play
      case .pause: kind = .pause
      case .seek: kind = .seek
      }
      WatchTogetherClient.shared.localPlayerAction(
        kind,
        time: action.time,
        paused: action.paused,
        delta: action.delta,
        rate: action.rate,
        automatic: action.automatic
      )
    }
    // The file finished loading: a non-host follows the host (PROTOCOL.md "Auto-sync").
    controller.onSyncReady = {
      WatchTogetherClient.shared.playerReady()
    }
    controller.onIndexChange = { index in
      WatchTogetherClient.shared.mediaIndexChanged(index)
    }
    controller.isWatchTogetherActive = {
      WatchTogetherClient.shared.isInLobby
    }
    // Watch Together v2.4: at the end of an episode the host plays the next queued item ("Up next").
    controller.onPlaybackEnded = { _, _ in
      WatchTogetherClient.shared.playbackEnded()
    }
  }

  /// Display name of an installed extension / addon (Watch Together `status.source`), the key when unknown.
  static func extensionName(_ key: String) -> String {
    ExtensionManager.shared.installed.first { $0.key == key }?.displayName ?? key
  }

  /// Episode of the episode list matching `ref` (same matching as PlayerController.currentEpisodeIndex).
  static func episodeInfo(in list: [EpisodeInfo], for ref: EpisodeRef) -> EpisodeInfo? {
    list.first { info in
      if let season = ref.season, let local = ref.localEpisode, let infoSeason = info.season, let infoLocal = info.localEpisode {
        return season == infoSeason && local == infoLocal
      }
      return info.number == ref.number
    }
  }

  /// Title of an episode in the episode list (same matching as PlayerController.currentEpisodeIndex).
  static func episodeTitle(in list: [EpisodeInfo], for ref: EpisodeRef) -> String? {
    episodeInfo(in: list, for: ref)?.title
  }
}

/// Search result used by one player for its next / previous episodes (updated when a fallback picks another).
@MainActor
final class ShellPlaybackSourceMemory {
  var source: PlaybackSource?
  var extensionKey: String

  init(source: PlaybackSource?, extensionKey: String) {
    self.source = source
    self.extensionKey = extensionKey
  }
}

/// Resolves another episode for the player without any dialog (DefaultLoadingModal steps).
@MainActor
enum ShellEpisodeResolver {
  /// From the remembered search result (exact series the user played); without one, the best result of the
  /// same extension. Throws when the extension is gone or the result does not list that episode, so the
  /// caller can open the extension flow instead of playing another episode.
  static func resolve(
    media: Media,
    episode: EpisodeRef,
    source: PlaybackSource?,
    extensionKey: String,
    preferredServerTitle: String?
  ) async throws -> (playback: ResolvedPlayback, source: PlaybackSource) {
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads()
    try Task.checkCancellation()
    let key = source?.extensionKey ?? extensionKey
    guard let ext = manager.enabledExtensions().first(where: { $0.key == key }) else {
      throw PlaybackResolutionError.defaultExtensionUnavailable
    }
    if let source {
      let found = try await PlaybackResolver.resolveSourceStream(ext, href: source.href, episode: episode, title: source.title, strict: true)
      return (pick(media: media, found: found, preferredServerTitle: preferredServerTitle), source)
    }
    let title = ExtensionContext.shared.displayTitle(media)
    let results = try await PlaybackResolver.scoredResults(ext, title: title, media: media)
    guard let best = results.first else { throw PlaybackResolutionError.noResults }
    let found = try await PlaybackResolver.resolveSourceStream(ext, href: best.href, episode: episode, title: best.title, strict: true)
    return (pick(media: media, found: found, preferredServerTitle: preferredServerTitle), found.source)
  }

  /// Server of the session memory, else the one playing now, else the first one.
  private static func pick(media: Media, found: PlaybackSourceStream, preferredServerTitle: String?) -> ResolvedPlayback {
    let stream = found.stream
    let index = stream.rememberedIndex(StreamSessionMemory.preferredServerTitle)
      ?? stream.rememberedIndex(preferredServerTitle)
      ?? 0
    return PlaybackResolver.playback(media: media, episode: found.episode, stream: stream, selectedIndex: index, extensionKey: found.source.extensionKey)
  }
}

/// Episode list of the player (EpisodeList.svelte data through MediaDetailsService).
@MainActor
final class ShellEpisodeListLoader {
  private(set) var result: [EpisodeInfo]?
  var onLoad: (([EpisodeInfo]) -> Void)?

  func start(media: Media) {
    Task { @MainActor in
      let list = await MediaDetailsService.shared.episodes(for: media)
      self.finish(list)
    }
  }

  private func finish(_ list: [EpisodeInfo]) {
    result = list
    let callback = onLoad
    onLoad = nil
    callback?(list)
  }
}

/// cache.requestMedia(notification.id) for the notification list and its play / view actions.
@MainActor
enum ShellNotificationMedia {
  static func resolve(_ notification: MediaNotification, direct: Bool) async -> Media? {
    if let stored = MediaStore.shared.media(notification.mediaKey) { return stored }
    guard notification.mediaKey.hasPrefix("al-"), notification.mediaId > 0 else { return nil }
    if direct {
      return try? await AniListService.shared.media(id: notification.mediaId)
    }
    return await AniListService.shared.requestMedia(id: notification.mediaId)
  }
}
