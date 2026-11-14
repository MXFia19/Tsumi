import SwiftUI
import Observation

// Playback wiring: PlaybackRequestCoordinator.onReady → PlayerController (ExtensionResults.launchPlayer +
// PlayerPage.svelte hooks), episode switching with the same extension (playNext / playLast / episode list /
// Watch Together setindex), progress (animeprogress.js), list auto-complete (Helper.updateEntry),
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

  /// "Now Playing" entry while the player is minimized to Picture in Picture.
  static func restorePlayer() {
    let presentation = PlayerPresentation.shared
    guard let controller = presentation.controller else { return }
    ShellNavigation.clearRootSheets()
    if controller.isPictureInPictureActive {
      controller.togglePictureInPicture()
    }
    Task { @MainActor in
      await ShellPresentationTiming.waitUntilSettled(maxDepth: 0)
      if presentation.controller === controller {
        presentation.isPresented = true
      }
    }
  }

  // MARK: - Player launch (PlaybackRequestCoordinator.onReady)

  /// launchPlayer: closes the dialogs and sheets, builds the session and presents the player.
  static func start(_ playback: ResolvedPlayback) {
    generation += 1
    let token = generation
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
      let controller = ShellPlayback.makeController(playback, episodes: loader.result ?? [])
      if loader.result == nil {
        loader.onLoad = { [weak controller] list in
          controller?.setEpisodeList(list)
        }
      }
      ShellState.shared.replacingPlayer = false
      presentation.present(controller)
    }
  }

  private static func makeController(_ playback: ResolvedPlayback, episodes: [EpisodeInfo]) -> PlayerController {
    let media = playback.media
    let session = PlaybackSession(
      media: media,
      episode: playback.episode,
      episodeTitle: episodeTitle(in: episodes, for: playback.episode),
      servers: playback.servers,
      selectedServer: playback.selectedIndex,
      subtitleURL: playback.subtitleURL
    )
    let controller = PlayerController(session: session, episodeList: episodes)
    wire(controller, media: media, extensionKey: playback.extensionKey)
    return controller
  }

  /// Every hook of the player (see PARITY/player.md "Wiring notes for the app step").
  private static func wire(_ controller: PlayerController, media: Media, extensionKey: String) {
    // playNext / playLast / episode list / setindex: same extension, no dialog over the player.
    controller.loadEpisode = { [weak controller] ref in
      let serverTitle = controller?.session.currentServer?.title
      let list = controller?.episodeList ?? []
      let current = MediaStore.shared.media(media.id) ?? media
      let resolved = try await ShellEpisodeResolver.resolve(media: current, episode: ref, extensionKey: extensionKey, preferredServerTitle: serverTitle)
      return PlaybackSession(
        media: current,
        episode: ref,
        episodeTitle: ShellPlayback.episodeTitle(in: list, for: ref),
        servers: resolved.servers,
        selectedServer: resolved.selectedIndex,
        subtitleURL: resolved.subtitleURL
      )
    }
    // loadAnimeProgress / setAnimeProgress (mediaId + episode).
    controller.resumePosition = { media, episode in
      AnimeProgressService.shared.record(mediaKey: media.id, episode: episode.number)?.currentTime
    }
    controller.onProgress = { snapshot in
      AnimeProgressService.shared.set(mediaKey: snapshot.media.id, episode: snapshot.episode.number, currentTime: snapshot.currentTime, safeDuration: snapshot.duration)
    }
    // checkCompletion → Helper.updateEntry.
    controller.onAutocomplete = { media, episode in
      Task { @MainActor in
        await MediaListService.shared.updateAfterWatching(media, episode: episode.number)
      }
    }
    // shareNowPlaying (launchPlayer) for every started episode, except the ones a peer asked for.
    controller.onEpisodeStarted = { session in
      if Date() < ShellState.shared.suppressShareUntil {
        ShellState.shared.suppressShareUntil = .distantPast
        return
      }
      WatchTogetherClient.shared.shareMedia(media: session.media, episode: session.episode)
    }
    controller.onClose = { [weak controller] in
      if let closed = controller?.session.media {
        ShellState.shared.lastWatched = MediaStore.shared.media(closed.id) ?? closed
      }
    }
    // Now Playing details (KeyO): details sheet over the player, which pauses it (pagePause).
    controller.onOpenDetails = { media in
      ShellNavigation.openDetails(MediaStore.shared.media(media.id) ?? media)
    }
    // Watch Together (w2gEmitter 'player' / 'index', no autoplay during a session).
    controller.onLocalStateChange = { state in
      WatchTogetherClient.shared.playerStateChanged(paused: state.paused, time: state.time)
    }
    controller.onIndexChange = { index in
      WatchTogetherClient.shared.mediaIndexChanged(index)
    }
    controller.isWatchTogetherActive = {
      WatchTogetherClient.shared.isInLobby
    }
  }

  /// Title of an episode in the episode list (same matching as PlayerController.currentEpisodeIndex).
  static func episodeTitle(in list: [EpisodeInfo], for ref: EpisodeRef) -> String? {
    let match = list.first { info in
      if let season = ref.season, let local = ref.localEpisode, let infoSeason = info.season, let infoLocal = info.localEpisode {
        return season == infoSeason && local == infoLocal
      }
      return info.number == ref.number
    }
    return match?.title
  }
}

/// Resolves another episode with the extension of the current playback (DefaultLoadingModal steps).
@MainActor
enum ShellEpisodeResolver {
  static func resolve(media: Media, episode: EpisodeRef, extensionKey: String, preferredServerTitle: String?) async throws -> ResolvedPlayback {
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads()
    try Task.checkCancellation()
    guard let ext = manager.enabledExtensions().first(where: { $0.key == extensionKey }) else {
      // The extension was disabled or removed meanwhile: default extension flow.
      let found = try await PlaybackResolver.resolveWithDefault(media: media, episode: episode, onStatus: { _ in })
      return pick(media: media, episode: episode, stream: found.stream, extensionKey: found.extensionKey, preferredServerTitle: preferredServerTitle)
    }
    let title = ExtensionContext.shared.displayTitle(media)
    let results = try await PlaybackResolver.scoredResults(ext, title: title, media: media)
    guard let best = results.first else { throw PlaybackResolutionError.noResults }
    let stream = try await PlaybackResolver.resolveStream(ext, href: best.href, episode: episode)
    return pick(media: media, episode: episode, stream: stream, extensionKey: ext.key, preferredServerTitle: preferredServerTitle)
  }

  /// Server of the session memory, else the one playing now, else the first one.
  private static func pick(media: Media, episode: EpisodeRef, stream: ExtensionStream, extensionKey: String, preferredServerTitle: String?) -> ResolvedPlayback {
    let index = stream.rememberedIndex(StreamSessionMemory.preferredServerTitle)
      ?? stream.rememberedIndex(preferredServerTitle)
      ?? 0
    return PlaybackResolver.playback(media: media, episode: episode, stream: stream, selectedIndex: index, extensionKey: extensionKey)
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
