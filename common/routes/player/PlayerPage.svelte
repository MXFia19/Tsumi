<script>
  import { settings } from '@/modules/settings.js'
  import { cache, caches } from '@/modules/cache.js'
  import { page, modal, playPage, goBack } from '@/modules/navigation.js'
  import { getAnimeProgress, setAnimeProgress } from '@/modules/anime/animeprogress.js'
  import { playAnime } from '@/modals/extension/ExtensionModal.svelte'
  import { nowPlaying, files as filesStore } from '@/components/MediaHandler.svelte'
  import { loadStream, stopStream } from '@/modules/streaming.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { episodesList } from '@/modules/episodes.js'
  import AnimeResolver from '@/modules/anime/animeresolver.js'
  import { durationMap, getMediaMaxEp } from '@/modules/anime/anime.js'
  import { writable } from 'simple-store-svelte'
  import { createEventDispatcher, onDestroy } from 'svelte'
  import Subtitles from '@/modules/subtitles.js'
  import { toTS, matchPhrase, videoRx, isValidNumber } from '@/modules/util.js'
  import { toast } from 'svelte-sonner'
  import { getChaptersAniSkip } from '@/modules/anime/anime.js'
  import { getChaptersIntroDB } from '@/modules/introdb/index.js'
  import { mediaCache } from '@/modules/cache.js'
  import Seekbar from 'perfect-seekbar'
  import { click } from '@/modules/click.js'
  import VideoDeband from 'video-deband'
  import { playbackSync } from '@/modules/sync/session.js'
  import { downloadsSupported, downloadFromPlayer, updateEntryOrQueue } from '@/modules/downloads/downloads.js'
  import { HoldSpeed, holdSpeedOf, holdSpeedLabel } from '@/modules/holdspeed.js'
  import { resumePosition, parseSubtitleOffset, rememberOffset, subtitleUrlOf, inEndChapters, hlsLevelOptions, CHAPTER_KINDS } from '@/modules/playerstate.js'
  import { audioTrackOptions, pickAudioTrack } from '@/modules/audiotracks.js'
  import { ArrowDownToLine, Gauge } from 'lucide-svelte'

  import { w2gEmitter, state } from '@/routes/w2g/WatchTogetherPage.svelte'
  import PlayerW2G from '@/routes/w2g/components/PlayerW2G.svelte'
  import { LocalActionTracker, formatSource } from '@/routes/w2g/components/sync.js'
  import { voiceDuck } from '@/routes/w2g/components/voice.js'
  import ManagerModal from '@/modals/manager/ManagerModal.svelte'
  import Keybinds, { loadWithDefaults, condition } from 'svelte-keybinds'
  import { SUPPORTS } from '@/modules/support.js'
  import 'rvfc-polyfill'
  import { IPC, ELECTRON } from '@/modules/bridge.js'
  import { X, Captions, CircleHelp, Contrast, FastForward, Keyboard, EllipsisVertical, SquareArrowOutUpRight, List, Eye, FilePlus2, ListMusic, ListVideo, Maximize, Minimize, Pause, PictureInPicture, PictureInPicture2, Play, Proportions, RefreshCcw, Rewind, RotateCcw, RotateCw, ScreenShare, SkipBack, SkipForward, Volume1, Volume2, VolumeX, SlidersVertical, SquarePen, Server } from 'lucide-svelte'
  import Debug from 'debug'
  // Chromecast (PC) and online subtitles: logic in modules/cast.js and modules/onlinesubs/.
  import CastButton from './CastButton.svelte'
  import CastOverlay from './CastOverlay.svelte'
  import OnlineSubtitles from './OnlineSubtitles.svelte'
  import { castState } from '@/modules/cast.js'
  import { Globe } from 'lucide-svelte'
  const debug = Debug('ui:player')

  const emit = createEventDispatcher()

  function closePlayer () {
    stopStream(video)
    if (pip) {
      try {
        document.exitPictureInPicture()
      } catch (e) {}
      pip = false
    }
    nowPlaying.set({})
    filesStore.set([])
    if ($page === page.PLAYER) {
      if (document.fullscreenElement) document.exitFullscreen()
      goBack()
    }
  }

  // ---- Watch Together (routes/w2g/PROTOCOL.md)
  // Local play / pause / seek are reported once the burst of media events settled. The events
  // caused by applying a lobby state are recognised by the tracker and never sent back.
  const w2gTracker = new LocalActionTracker()
  let w2gLoading = false
  let w2gLoadToken = 0
  let w2gLoadSteps = []
  let w2gSettleTimer = null
  /** mediaKey of the lobby title playing here, captured when the file starts */
  let w2gKey = ''

  w2gEmitter.on('playerupdate', applyW2GState)
  w2gEmitter.on('perform', performW2GRequest)
  w2gEmitter.on('setindex', (detail) => {
    // Only a file index of this batch: a lobby message never loads an arbitrary file object.
    if (Number.isInteger(detail) && detail >= 0 && detail < videos.length) playFile(detail)
  })

  export function playFile (file) {
    if (isValidNumber(file)) handleCurrent(videos?.[file])
    else handleCurrent(file)
  }

  /** Applies a lobby state: someone's action, host snap-back, auto-sync, resync, countdown. */
  function applyW2GState ({ time, paused: lobbyPaused }) {
    if (!video || !current || externalPlayback || w2gLoading || !isValidNumber(time)) return
    w2gTracker.expect({ time, paused: lobbyPaused }, Date.now())
    if (Math.abs((video.currentTime || 0) - time) > 0.25) seek(time - currentTime)
    paused = !!lobbyPaused
  }

  /** The host accepted a request: do it as a local action, which is then broadcast. */
  function performW2GRequest ({ kind, time }) {
    if (!video || !current || externalPlayback) return
    if (kind === 'pause') paused = true
    else if (kind === 'play') paused = false
    else if (kind === 'seek' && isValidNumber(time)) seek(time - currentTime)
  }

  /** @param {'play' | 'pause' | 'seeking' | 'seeked'} event */
  function w2gMediaEvent (event) {
    if (event !== 'seeking') saveAnimeProgress()
    if (!video) return
    w2gTracker.note(event, video.currentTime)
    if (event === 'seeked') reportW2GStatus(true)
    clearTimeout(w2gSettleTimer)
    w2gSettleTimer = setTimeout(settleW2G, 300)
  }

  function settleW2G () {
    w2gSettleTimer = null
    if (!video) return
    // Still dragging the seekbar or seeking: report the whole gesture once it is over.
    if (wasPaused != null || video.seeking) {
      w2gSettleTimer = setTimeout(settleW2G, 300)
      return
    }
    const change = w2gTracker.settle({ time: video.currentTime, paused: video.paused }, Date.now())
    // Loading a file (resume position, autoplay) is not a user action.
    if (!change || w2gLoading || externalPlayback || !state.value) return
    w2gEmitter.emit('player', { ...change, rate: video.playbackRate || 1 })
  }

  function w2gTimeupdate () {
    if (!video) return
    w2gTracker.observe({ time: video.currentTime, paused: video.paused, seeking: video.seeking })
    state.value?.updateLocalTime(video.currentTime)
  }

  function startW2GLoading () {
    w2gLoading = true
    w2gLoadToken++
    w2gLoadSteps = []
    // What we started last: the lobby media, or our own launch while watching on our own (v2.2).
    w2gKey = state.value?.launchedKey || ''
    w2gTracker.reset(null)
  }

  // handleLoadedMetadata() resumes and starts autoPlay(); loading ends when its steps are done.
  async function w2gLoadedMetadata () {
    const token = w2gLoadToken
    const steps = w2gLoadSteps
    w2gLoadSteps = []
    await Promise.allSettled(steps)
    finishW2GLoading(token)
  }

  function finishW2GLoading (token = w2gLoadToken) {
    if (!w2gLoading || token !== w2gLoadToken) return
    if (video?.seeking || w2gSettleTimer) {
      setTimeout(() => finishW2GLoading(token), 300)
      return
    }
    w2gLoading = false
    if (video) w2gTracker.reset({ time: video.currentTime, paused: video.paused })
    state.value?.playerReady()
  }

  $: w2gStatus = !current || externalPlayback ? 'idle' : w2gLoading ? 'loading' : paused ? 'paused' : buffering ? 'buffering' : 'playing'
  // Only the key captured when the file started: a file started before joining a lobby is not the lobby media.
  $: w2gMediaKey = w2gKey
  // status.source: extension / addon, then the server ("AnimePahe · Server 2").
  $: w2gSource = formatSource(current?.sourceName, streamServers[activeServerIndex]?.title || (streamServers.length > 1 ? `Server ${activeServerIndex + 1}` : ''))
  // status.nowPlaying: the client turns `episode` into "Episode 5" / "S2 E5" / "Movie".
  $: w2gNowPlaying = w2gNowPlayingOf(media, current)
  function w2gNowPlayingOf (media, current) {
    const fullMedia = media?.media || current?.media?.media
    if (!fullMedia && !current) return null
    return {
      mediaId: fullMedia?.id ?? null,
      title: (fullMedia && anilistClient.title(fullMedia)) || (current?.name ? AnimeResolver.cleanFileName(current.name) : ''),
      episode: media?.episode ?? current?.media?.episode,
      format: fullMedia?.format,
      episodes: fullMedia?.episodes
    }
  }
  $: reportW2GStatus(false, w2gStatus, w2gMediaKey, playbackRate, w2gSource, w2gNowPlaying, $state)
  function reportW2GStatus (force, status = w2gStatus, key = w2gMediaKey, rate = playbackRate, source = w2gSource, nowPlaying = w2gNowPlaying) {
    state.value?.setLocalStatus({
      state: status,
      time: video?.currentTime || 0,
      mediaKey: status === 'idle' ? '' : key,
      rate: rate || 1,
      source: status === 'idle' ? '' : source,
      nowPlaying: status === 'idle' ? null : nowPlaying
    }, { force })
  }

  export let miniplayer = false
  $: viewAnime = $modal[modal.ANIME_DETAILS]
  /** Typing in a text field (subtitle offset, chat...) never triggers the player shortcuts (arrows, space...). */
  function isTextEntry (target) {
    if (!(target instanceof HTMLElement)) return false
    if (target.isContentEditable || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement) return true
    return target instanceof HTMLInputElement && !['range', 'checkbox', 'radio', 'button', 'submit', 'reset', 'file', 'color', 'image'].includes(target.type)
  }
  $condition = (event) =>
    SUPPORTS.keybinds &&
      !isTextEntry(event?.target) &&
      $page === page.PLAYER &&
      ((!miniplayer &&
        (!$modal || !modal.length) &&
        !document.querySelector('.modal.show')) ||
        viewAnime)

  export let files = []
  export let playableFiles = []
  export let updateCurrent
  let streamServers = []
  // "Download Episode" of the More menu: episodes played from an extension (not a downloaded file).
  $: canDownload = downloadsSupported && !!current?.media?.media && !current?.offline
  let activeServerIndex = 0
  $: updateFiles(files)
  let video = null
  let container = null
  let current = null
  let subs = null
  let duration = 0.1
  let paused = true
  let muted = false
  let wasPaused = null
  let videos = []
  let immersed = false
  let buffering = false
  let immerseTimeout = null
  let bufferTimeout = null
  let subHeaders = null
  let pip = false
  // const presentationRequest = null
  // const presentationConnection = null
  // const canCast = false
  let isFullscreen = false
  let ended = false
  let gain = 0
  let volume = Number(cache.getEntry(caches.GENERAL, 'volume')) || 1
  let volumeBoosted = false
  let audioCtx = null
  let source = null
  let gainNode = null
  let playbackRate = 1
  $: cache.setEntry(caches.GENERAL, 'volume', String(volume || 0))
  // Watch Together voice: the video is lowered while someone speaks; `volume` (the user's choice) never changes.
  $: if (video) video.volume = Math.min(1, Math.max(0, (volume || 0) * $voiceDuck))
  // External player (Settings > Player, and More > External Player): the main process starts the user's player
  // (IPC external-player:launch) and tells when it closed (external-player:closed). `externalPlayback` is true while
  // an episode plays there; `externalSession` is { id, startTime, builtin } once it started (builtin: the stream also
  // stays loaded here, paused).
  let externalPlayback = false
  let externalSession = null
  $: externalAvailable = !!(SUPPORTS.externalPlayer && !SUPPORTS.isAndroid && $settings.playerPath && IPC?.invoke)
  $: externalEnabled = externalAvailable && !!$settings.enableExternal
  $: safeduration = externalPlayback
    ? (current?.media?.media?.duration ||
      (current?.media?.media?.format &&
        durationMap[current?.media?.media?.format]) ||
      24) * 60
    : isFinite(duration)
    ? duration
    : currentTime
  $: {
    if (hidden) setDiscordRPC($nowPlaying, true)
    else setDiscordRPC($nowPlaying, paused && $page !== page.PLAYER, $nowPlaying?.media || current?.media?.media)
  }

  window.addEventListener('fileEdit', () => {
    if (current) {
      debug(
        'Detected a user update to the parsed file(s), now updating the media...'
      )
      const index = videos.indexOf(current)
      updateCurrent({ detail: current })
      current = videos[index]
    }
  })

  function setupAudio () {
    if (!audioCtx) {
      audioCtx = new AudioContext()
      source = audioCtx.createMediaElementSource(video)
      gainNode = audioCtx.createGain()
      source.connect(gainNode)
      gainNode.connect(audioCtx.destination)
    }
  }

  /**
   * Key of the show playing for its remembered choices (subtitle track and offset, volume boost). The file's own
   * media first: nowPlaying ($nowPlaying, `media`) is updated asynchronously and can still be the previous episode's.
   */
  function showKey () {
    return `${current?.media?.media?.id || media?.media?.id || media?.title || media?.parseObject?.title || media?.parseObject?.file_name}`
  }

  function checkAudio () {
    const boost = cache.getEntry(caches.HISTORY, 'lastBoosted')?.[showKey()]
    volumeBoosted = boost?.boosted || false
    if (volumeBoosted) {
      setupAudio()
      gain = boost?.gain || 0
      // Same mapping as setGain(): up to 1 the element volume does it, above 1 the gain node (never both).
      if (gain > 1) {
        volume = 1
        gainNode.gain.value = gain
      } else {
        volume = gain
        gainNode.gain.value = 1
      }
    } else {
      // Not boosting: the gain node passes the sound as is (the element volume already applies `volume`).
      if (gainNode?.gain) gainNode.gain.value = 1
      gain = 0
    }
    if ('audioTracks' in HTMLVideoElement.prototype) {
      if (!video.audioTracks.length) {
        toast.error('Audio Codec Unsupported', {
          description:
            "This file's audio codec is not supported. Try a different source from another extension."
        })
      } else if (video.audioTracks.length > 1) {
        // The track remembered for the show, then the preferred language, then Japanese (audiotracks.js).
        const tracks = [...video.audioTracks]
        const index = pickAudioTrack(tracks.map(track => ({ name: track.label, lang: track.language })), { remembered: rememberedAudio(), preferred: $settings.audioLanguage })
        if (index !== -1 && !tracks[index].enabled) return selectAudio(tracks[index].id)
      }
    }
  }

  /** Name of a subtitle track in the menu, also what lastSubtitle remembers. */
  function trackLabel (track) {
    return (track?.language ||
      (!Object.values(subs?.headers || {}).some(
        (header) => header?.language === 'eng' || header?.language === 'en'
      )
        ? 'eng'
        : track?.type)) + (track?.name ? ' - ' + track.name : '')
  }

  function rememberSubtitle (choice) {
    cache.setEntry(caches.HISTORY, 'lastSubtitle', {
      ...(cache.getEntry(caches.HISTORY, 'lastSubtitle') || {}),
      [showKey()]: choice
    })
  }

  /** The remembered subtitle choice of the show was applied (once per episode). */
  let subtitlePreferenceDone = false
  /** The show's remembered choice is OFF (no automatic online subtitles then). */
  let subtitlesOff = false
  /**
   * Applies the remembered subtitle choice of the show (OFF, or a track name) as soon as the tracks it needs exist:
   * tracks arrive at any time (stream subtitle URL, online subtitles), so this runs on every header change until done.
   */
  function applySubtitlePreference () {
    if (subtitlePreferenceDone || !subs?.headers) return
    const wanted = cache.getEntry(caches.HISTORY, 'lastSubtitle')?.[showKey()]
    if (!wanted) {
      subtitlePreferenceDone = true
      return
    }
    const tracks = subs.headers.filter(Boolean)
    if (!tracks.length) return
    if (wanted === 'OFF') {
      subtitlePreferenceDone = true
      if (subs.current !== -1) subs.selectCaptions(-1)
      setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix (resize) because video metadata doesn't update for multiple frames
      return
    }
    for (const track of tracks) {
      const trackName = trackLabel(track)
      if (track?.number && matchPhrase(wanted, trackName, trackName?.length > 10 ? 3 : 2, true)) {
        subtitlePreferenceDone = true
        if (subs.current !== track.number) subs.selectCaptions(track.number)
        setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix (resize) because video metadata doesn't update for multiple frames
        return
      }
    }
  }

  // if ('PresentationRequest' in window) {
  //   const handleAvailability = aval => {
  //     canCast = !!aval
  //   }
  //   presentationRequest = new PresentationRequest(['build/cast.html'])
  //   presentationRequest.addEventListener('connectionavailable', e => initCast(e))
  //   navigator.presentation.defaultRequest = presentationRequest
  //   presentationRequest.getAvailability().then(aval => {
  //     aval.onchange = e => handleAvailability(e.target.value)
  //     handleAvailability(aval.value)
  //   })
  // }

  // document.fullscreenElement isn't reactive
  let orientationLockable = true // might as well stop trying to lock the orientation when the device doesn't support it.
  document.addEventListener('fullscreenchange', () => {
    isFullscreen = !!document.fullscreenElement
    if (document.fullscreenElement && orientationLockable) {
      if (SUPPORTS.isAndroid) window.AndroidFullScreen?.immersiveMode()
      screen.orientation.lock('landscape').then(
        (success) => debug(success),
        (failure) => {
          if (!failure?.toString()?.includes('NotSupportedError')) {
            debug(failure)
          } else {
            orientationLockable = false
          }
        }
      )
    } else if (orientationLockable) {
      if (SUPPORTS.isAndroid) {
        window.AndroidFullScreen?.showSystemUI()
        window.Capacitor.Plugins.StatusBar.setOverlaysWebView({
          overlay: true
        })
        window.Capacitor.Plugins.StatusBar.hide()
      }
      screen.orientation.unlock()
    }
  })

  function handleHeaders () {
    subHeaders = subs?.headers
    applySubtitlePreference()
  }

  /**
   * Adds the subtitle file of the stream response to `instance` (the Subtitles of the episode that asked for it: a
   * file arriving after the episode changed is dropped instead of being added to the next one).
   */
  async function loadExternalSubtitleUrl (instance, url, headers = {}) {
    if (!instance || !url) return
    try {
      const port = await ELECTRON.getProxyPort?.()
      const res = (port && Object.keys(headers).length > 0)
        ? await fetch(`http://localhost:${port}/proxy?url=${encodeURIComponent(url)}&headers=${encodeURIComponent(JSON.stringify(headers))}`)
        : await fetch(url)

      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const text = await res.text()
      if (instance !== subs || !instance.headers) return
      const ext = url.split(/[?#]/)[0].split('.').pop()?.toLowerCase() || 'vtt'
      const fileName = `Subtitles.${ext}`
      const file = new File([text], fileName, { type: 'text/plain' })
      await instance.addSingleSubtitleFile(file)
    } catch (err) {
      debug('Failed to fetch the subtitle of the stream', err)
    }
  }

  function updateFiles (files) {
    if (files?.length) {
      videos = files.filter((file) => videoRx.test(file.name))
      if (videos?.length) {
        if (subs) {
          subs.files = files || []
        }
      }
    } else {
      // Player closed: nothing of the last episode may keep running (stats, thumbnails, async loads...).
      resetEpisodeState()
      stopStream(video)
      buffering = true
      current = null
    }
  }

  /**
   * @type {VideoDeband}
   */
  let deband

  function loadDeband (load, video) {
    if (!video) return
    if (load && !deband) {
      try {
        deband = new VideoDeband(video)
        deband.canvas.classList.add('deband-canvas')
        video.before(deband.canvas)
      } catch (error) {
        // No WebGL 2 (old GPU, ANGLE on D3D9...): the constructor throws. Turn the setting off instead of failing
        // in the middle of a reactive update (which froze the app at start when the setting was saved on).
        debug('Video debanding unavailable', error)
        try { deband?.destroy() } catch (e) {}
        deband?.canvas?.remove()
        deband = null
        $settings.playerDeband = false
        toast.error('Video Debanding Unavailable', {
          description: 'Your graphics card or driver does not support it (WebGL 2 is needed). The setting was turned off.'
        })
      }
    } else if (!load && deband) {
      deband.destroy()
      deband.canvas.remove()
      deband = null
    }
  }
  $: loadDeband($settings.playerDeband, video)
  // Cross-device resume (AniList / MyAnimeList note) and Trakt scrobbling, see modules/sync/session.js.
  $: playbackSync.attach(video, current?.media)

  /** Incremented for every episode load and on close: the async steps of an older load see it changed and stop. */
  let loadToken = 0
  /** Incremented for every stream (re)load of the episode: server switch, retry, back from the external player. */
  let streamToken = 0
  /** Same episode reloaded (server switch, retry...): { time, paused, stream } applied on its loadedmetadata. */
  let pendingRestore = null
  /** Last position the video really played at (kept when a load fails, for the next server / retry). */
  let lastGoodTime = 0

  /** Everything tied to the episode playing back to its initial state: new episode, or player closed. */
  function resetEpisodeState () {
    loadToken++
    streamToken++
    holdSpeed.cancel()
    stopStats()
    stopThumbnails()
    clearUpNext()
    upNextDismissed = false
    clearTimeout(resumeOfferTimer)
    resumeOffer = null
    dismissStreamError()
    pendingRestore = null
    lastGoodTime = 0
    canPlay = false
    externalPlayback = false
    externalSession = null
    hlsLevels = []
    hlsLevel = -1
    hlsActiveLevel = -1
    hlsAudio = []
    hlsAudioTrack = -1
    buffer = 0
    currentTime = 0
    targetTime = 0
    chapters = []
    currentSkippable = null
    completed = false
    filler = null
    recap = null
    skipPrompt = false
    resolvePrompt = false
    subtitlePreferenceDone = false
    thumbnailData.thumbnails = []
    thumbnailData.interval = undefined
    if (subs) {
      subs.destroy()
      subs = null
    }
  }

  function handleCurrent (file) {
    // An unknown file (out of range index...) used to leave the spinner forever: keep what plays instead.
    if (!file) return
    paused = true
    video?.pause?.()
    resetEpisodeState()
    showBuffering()
    current = file
    subDelay = savedSubDelay()
    subDelayText = String(subDelay)
    subtitlesOff = cache.getEntry(caches.HISTORY, 'lastSubtitle')?.[showKey()] === 'OFF'
    startW2GLoading()
    setCurrent(file, loadToken)
  }

  function waitForVideo () {
    return new Promise((resolve) => {
      if (video) return resolve()
      const check = setInterval(() => {
        if (video) {
          clearInterval(check)
          resolve()
        }
      }, 50)
      setTimeout(() => {
        clearInterval(check)
        resolve()
      }, 3000)
    })
  }

  const isHlsUrl = (url) => !!url?.toLowerCase()?.includes('.m3u8')

  /** URL and headers of the stream playing: the server picked in the Servers menu, else the file's own. */
  function activeStream (file = current) {
    const server = activeServerIndex !== (file?.activeServerIndex || 0) ? streamServers[activeServerIndex] : null
    return server?.streamUrl
      ? { url: server.streamUrl, headers: server.headers || {} }
      : { url: file?.url, headers: file?.streamHeaders || {} }
  }

  /** "Watch Together plays here" was said once: the setting stays on for the episodes watched alone. */
  let w2gExternalNoticeShown = false

  async function setCurrent (file, token) {
    streamServers = file.streamServers || []
    activeServerIndex = file.activeServerIndex || 0
    stopStream(video)
    // Watch Together: always the built-in player. An episode in the external player leaves this member idle ("Not in
    // the player"), never ready (playerReady), so a host's queued item never starts.
    if (externalEnabled && state.value && !w2gExternalNoticeShown) {
      w2gExternalNoticeShown = true
      toast('Watch Together', { description: 'Episodes play in Tsumi during Watch Together (not in your external player) to stay in sync.', duration: 8_000 })
    }
    if (externalEnabled && !state.value) {
      const startTime = resumePosition(getEpisodeProgress(file), { threshold: $settings.playerAutocompleteThreshold }) || 0
      const launched = await launchExternal(file, token, startTime)
      if (token !== loadToken) return
      if (launched) {
        emit('current', current) // #handleCurrent in MediaHandler
        return
      }
    }
    await loadBuiltin(file, token)
    if (token === loadToken) emit('current', current) // #handleCurrent in MediaHandler
  }

  /** Plays the episode in the built-in player: stream, subtitles of the stream response. */
  async function loadBuiltin (file, token, restore = null) {
    const stream = activeStream(file)
    const started = await startStream(stream, restore)
    // Back from the external player the episode may already have its subtitles (and the tracks the user added).
    if (!started || token !== loadToken || !video || subs) return
    subs = new Subtitles(video, files, current, handleHeaders)
    // Subtitle file of the extension stream response
    const subtitleUrl = subtitleUrlOf(file.subtitle)
    if (subtitleUrl) loadExternalSubtitleUrl(subs, subtitleUrl, stream.headers)
  }

  /**
   * Loads a stream in the video (streaming.js: hls.js or the local proxy). `restore` ({ time, paused }) is applied
   * on its loadedmetadata instead of the first-load steps (resume, autoplay, filler prompt). False when a newer load
   * started meanwhile.
   */
  async function startStream ({ url, headers }, restore = null) {
    const stream = ++streamToken
    pendingRestore = restore ? { ...restore, stream } : null
    hlsLevels = []
    hlsLevel = -1
    hlsActiveLevel = -1
    hlsAudio = []
    hlsAudioTrack = -1
    dismissStreamError()
    showBuffering()
    stopStream(video)
    try {
      await waitForVideo()
      if (stream !== streamToken) return false
      // onError (streaming.js): its HLS recovery gave up. Ignored by a streaming.js without the option.
      await loadStream(video, url, {
        headers: headers || {},
        onError: () => {
          if (stream === streamToken) showStreamError()
        }
      })
    } catch (error) {
      if (stream !== streamToken) return false
      debug('Stream load failed, falling back to direct src:', error)
      if (video) video.src = url
    }
    if (stream !== streamToken || !video) return false
    watchHls(stream)
    if (!isHlsUrl(url)) video.load()
    return true
  }

  /** Position to come back to after a reload: the video's, or the last one it really played at (failed load). */
  function currentPosition () {
    if (video?.readyState >= 1 && isFinite(video.currentTime) && video.currentTime > 0) return video.currentTime
    return lastGoodTime
  }

  function trackPosition () {
    if (video?.readyState >= 1 && !video.seeking && video.currentTime > 0 && !pendingRestore) lastGoodTime = video.currentTime
  }

  async function switchServer (index) {
    if (index === activeServerIndex || !streamServers[index] || !current || externalPlayback) return
    // A previous switch still loading keeps its position: a failed server does not lose it.
    const restore = { time: pendingRestore?.time ?? currentPosition(), paused: pendingRestore?.paused ?? paused }
    activeServerIndex = index
    await startStream(activeStream(), restore)
  }

  /** Reloads the stream playing (same server) where it was: "Retry" of the playback error toasts. */
  function retryStream () {
    if (!current || externalPlayback) return
    startStream(activeStream(), { time: pendingRestore?.time ?? currentPosition(), paused: false })
  }

  // ---- HLS (hls.js instance streaming.js attaches to the video as video._hlsInstance): quality menu, fatal errors.
  /** quality menu entries ({ index, label }, best first), empty when the stream has a single quality */
  let hlsLevels = []
  /** level picked in the menu, -1 for automatic */
  let hlsLevel = -1
  /** level hls.js plays (shown next to "Auto") */
  let hlsActiveLevel = -1
  $: hlsActiveLabel = hlsLevels.find(level => level.index === hlsActiveLevel)?.label || ''
  /** audio menu entries ({ index, label }) of the HLS audio renditions (VF / VO...), empty with a single one */
  let hlsAudio = []
  /** audio rendition playing (index in hls.audioTracks) */
  let hlsAudioTrack = -1

  function watchHls (stream) {
    const hls = video?._hlsInstance
    const Hls = window.Hls
    if (!hls || !Hls?.Events) return
    const levels = hlsLevelOptions(hls.levels)
    hlsLevels = levels.length > 1 ? levels : []
    hlsActiveLevel = hls.currentLevel ?? -1
    hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
      if (stream === streamToken) hlsActiveLevel = data?.level ?? -1
    })
    // The audio renditions can arrive after the manifest, and change with a quality of another audio group.
    updateHlsAudio(hls)
    hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => {
      if (stream === streamToken) updateHlsAudio(hls)
    })
    hls.on(Hls.Events.AUDIO_TRACK_SWITCHED, (_event, data) => {
      if (stream === streamToken) hlsAudioTrack = data?.id ?? hls.audioTrack ?? -1
    })
    hls.on(Hls.Events.ERROR, (_event, data) => {
      if (!data?.fatal || stream !== streamToken) return
      // streaming.js may recover from it: only report an instance that gave up (destroyed, no replacement).
      setTimeout(() => {
        if (stream === streamToken && video && !hls.media && (!video._hlsInstance || video._hlsInstance === hls)) showStreamError()
      }, 1_500)
    })
  }

  /** Lists the HLS audio renditions and starts with the one remembered for the show or the preferred language. */
  function updateHlsAudio (hls) {
    const tracks = Array.isArray(hls.audioTracks) ? hls.audioTracks : []
    hlsAudio = tracks.length > 1 ? audioTrackOptions(tracks) : []
    hlsAudioTrack = hls.audioTrack ?? -1
    const index = pickAudioTrack(tracks, { remembered: rememberedAudio(), preferred: settings.value.audioLanguage })
    if (index !== -1 && index !== hls.audioTrack) {
      hls.audioTrack = index
      hlsAudioTrack = index
    }
  }

  function selectHlsAudio (index) {
    const hls = video?._hlsInstance
    const track = hls?.audioTracks?.[index]
    if (!track) return
    hls.audioTrack = index
    hlsAudioTrack = index
    rememberAudio({ name: track.name, lang: track.lang })
  }

  /** Audio track picked for the show ({ name, lang }), used by the next episodes (like lastSubtitle). */
  function rememberedAudio () {
    return cache.getEntry(caches.HISTORY, 'lastAudio')?.[showKey()] || null
  }
  function rememberAudio ({ name, lang }) {
    cache.setEntry(caches.HISTORY, 'lastAudio', {
      ...(cache.getEntry(caches.HISTORY, 'lastAudio') || {}),
      [showKey()]: { name: name || '', lang: lang || '' }
    })
  }

  function selectQuality (index) {
    const hls = video?._hlsInstance
    if (!hls) return
    hls.currentLevel = index // -1: automatic
    hlsLevel = index
  }

  /** id of the "Playback Error" toast shown for the stream playing */
  let streamErrorToast = null
  /** The stream stopped for good: streaming.js onError, hls.js gave up, or a 'streamerror' event on the video. */
  function showStreamError () {
    if (streamErrorToast != null || !current || externalPlayback) return
    buffering = false
    clearTimeout(bufferTimeout)
    streamErrorToast = toast.error('Playback Error', {
      description: 'The stream stopped. Retry, or pick another server.',
      duration: Infinity,
      action: {
        label: 'Retry',
        onClick: () => {
          streamErrorToast = null
          retryStream()
        }
      },
      onDismiss: () => {
        streamErrorToast = null
      }
    })
  }

  function dismissStreamError () {
    if (streamErrorToast != null) toast.dismiss(streamErrorToast)
    streamErrorToast = null
  }

  // ---- External player (electron main process: external-player:launch / external-player:closed)
  /** Title shown by the external player. */
  function externalTitle (file) {
    const fileMedia = file?.media
    const title = (fileMedia?.media && anilistClient.title(fileMedia.media)) || fileMedia?.parseObject?.anime_title || AnimeResolver.cleanFileName(file?.name || '') || 'Tsumi'
    if (fileMedia?.media?.format === 'MOVIE' || !isValidNumber(fileMedia?.episode)) return title
    return `${title} - Episode ${fileMedia.episode}`
  }

  /** IPC error -> a short sentence for the toast. */
  function externalError (error) {
    const message = String(error || '')
    if (/no handler registered/i.test(message)) return 'This version of Tsumi cannot start an external player.'
    return message.replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/i, '') || 'The external player could not be started.'
  }

  /**
   * Plays `file` (its active server) in the user's external player. False when it could not start: a toast says why
   * and the episode plays here instead.
   */
  async function launchExternal (file, token, startTime) {
    const { url, headers } = activeStream(file)
    if (!url || !IPC?.invoke) return false
    externalPlayback = true
    externalSession = null
    hideBuffering()
    let result
    try {
      // The main process starts the program picked in its own dialog (syncPlayerPath), never a path sent from here.
      result = await IPC.invoke('external-player:launch', {
        url,
        headers,
        title: externalTitle(file),
        subtitleUrl: subtitleUrlOf(file.subtitle) || undefined,
        startTime: Math.max(0, Math.floor(Number(startTime) || 0))
      })
    } catch (error) {
      result = { ok: false, error: error?.message || String(error) }
    }
    if (token !== loadToken) return false
    if (!result?.ok) {
      externalPlayback = false
      debug('External player failed:', result?.error)
      toast.error('External Player Failed', {
        description: `${externalError(result?.error)} Playing in Tsumi instead.`,
        duration: 10_000
      })
      return false
    }
    externalSession = { id: result.id ?? null, startTime: Number(startTime) || 0, builtin: false }
    return true
  }

  /** More > External Player: the episode playing here continues in the external player (paused here meanwhile). */
  async function openInExternalPlayer () {
    if (!current || externalPlayback || !externalAvailable) return
    const token = loadToken
    const builtin = video?.readyState >= 1
    const startTime = currentPosition()
    holdSpeed.cancel()
    paused = true
    if (await launchExternal(current, token, startTime) && externalSession) externalSession.builtin = builtin
  }

  /** Episode length (s) estimated from the media, while the video is not loaded here. */
  function mediaDuration () {
    return (current?.media?.media?.duration || (current?.media?.media?.format && durationMap[current.media.media.format]) || 24) * 60
  }

  /**
   * Leaves external mode: the episode continues here, paused when the external player was closed, playing for
   * "Play in Tsumi instead".
   */
  function leaveExternal (position, play = false) {
    const session = externalSession
    externalPlayback = false
    externalSession = null
    const time = position > 0 ? position : session?.startTime || 0
    if (session?.builtin && video?.readyState >= 1) {
      if (position > 0) seekTo(beforeEnd(position))
      if (play) paused = false
      return
    }
    loadBuiltin(current, loadToken, { time, paused: !play })
  }

  function playInTsumi () {
    if (externalPlayback && externalSession && current) leaveExternal(0, true)
  }

  // external-player:closed ({ id, code, position?, duration?, estimated? }, electron/src/main/externalPlayerArgs.js
  // closedPosition: mpv's own position, or an estimate from the time another player stayed open): the episode comes
  // back here, where it was (or where the external player started) when no position is given.
  IPC?.on?.('external-player:closed', (detail) => {
    if (!externalPlayback || !externalSession || !current) return
    if (detail?.id != null && externalSession.id != null && detail.id !== externalSession.id) return
    const length = Number(detail?.duration) > 0 ? Number(detail.duration) : mediaDuration()
    // An estimate runs past the end when the player was left paused: at most the whole episode.
    const position = Math.min(Number(detail?.position ?? detail?.time), length)
    const watched = Number.isFinite(position) && position > 0
    if (watched) {
      saveProgressAt(position, length)
      if (!completed && $settings.playerAutocomplete) checkCompletionByTime(position, length, true)
    }
    leaveExternal(watched ? position : 0)
    // (An episode watched to the end comes back just before its end, paused: Play next is offered, never forced.)
    if (watched && completed && hasNext) {
      toast('Episode watched', {
        description: 'The external player reached the end of the episode.',
        duration: 10_000,
        action: { label: 'Play next', onClick: () => (state.value ? tryPlayNext() : playNext()) }
      })
    }
  })

  /**
   * The main process keeps the program picked in its own dialog (Settings > Player, electron/src/main/dialog.js) and
   * starts only that one: Settings shows it. A path saved by an older version is unknown there and must be picked
   * again (an empty setting, from "Reset Location", stays empty).
   */
  async function syncPlayerPath () {
    if (!SUPPORTS.externalPlayer || SUPPORTS.isAndroid || !IPC?.invoke) return
    let path
    try {
      path = await IPC.invoke('external-player:path')
    } catch (error) {
      return // older main process
    }
    const shown = settings.value.playerPath
    if (typeof path !== 'string' || !shown || shown === path) return
    $settings.playerPath = path
    if (!path) {
      toast('External Player', {
        description: 'Select your external player again in Settings > Player: Tsumi now only starts a program picked there.',
        duration: 15_000
      })
    }
  }
  syncPlayerPath()

  export let media

  $: checkAvail(media, current)
  let hasNext = false
  let hasLast = false
  function checkAvail (media, current) {
    if (
      (media?.media?.nextAiringEpisode?.episode - 1 ||
        getMediaMaxEp(media?.media)) -
      (media?.zeroEpisode ? 1 : 0) >
      media?.episode ||
      (media?.media &&
        !media.media.nextAiringEpisode?.episode &&
        !media.media.airingSchedule?.nodes?.[0]?.episode &&
        !media.media.episodes)
    ) { hasNext = true } else hasNext = videos.indexOf(current) !== videos.length - 1
    if (
      media?.media &&
      (media?.episode > 1 || (media?.zeroEpisode && media?.episode === 1))
    ) { hasLast = true } else hasLast = videos.indexOf(current) > 0
  }

  /**
   * Name an episode's progress is saved under when it has no resolved media (animeprogress.js). Built from the file
   * only: nowPlaying can still describe the previous episode when the new one loads.
   */
  function progressName (file) {
    const parseObject = file?.media?.parseObject
    if (!parseObject?.anime_title) return file?.name
    const season = file.media.season || parseObject.anime_season
    const episode = file.media.episode ?? parseObject.episode_number
    return parseObject.anime_title + (season ? ` S${season}` : '') + (episode || episode === 0 ? ` E${episode}` : '')
  }

  /** Saved progress of an episode ({ currentTime, safeduration }), by media id and episode, or by name. */
  function getEpisodeProgress (file = current) {
    const fileMedia = file?.media
    if (fileMedia?.media?.id && isValidNumber(fileMedia.episode) && !fileMedia.failed) {
      return getAnimeProgress({ name: progressName(file), mediaId: fileMedia.media.id, episode: fileMedia.episode })
    }
    return getAnimeProgress({ name: progressName(file) })
  }

  function saveProgressAt (time, length) {
    const fileMedia = current?.media
    if (fileMedia?.media?.id && isValidNumber(fileMedia.episode) && !fileMedia.failed) {
      setAnimeProgress({ mediaId: fileMedia.media.id, episode: fileMedia.episode, currentTime: time, safeduration: length })
    } else {
      setAnimeProgress({ name: progressName(current), currentTime: time, safeduration: length })
    }
  }

  function saveAnimeProgress () {
    if (!video || !current || externalPlayback || buffering || video.readyState < 4) return
    saveProgressAt(video.currentTime, safeduration)
  }
  setInterval(() => {
    if (!paused) saveAnimeProgress()
  }, 10_000)

  function seekTo (time) {
    if (!video || !isFinite(time)) return
    currentTime = time
    targetTime = time
    video.currentTime = time
  }

  /**
   * Resumes the episode where it was left (a little before), unless it was finished: past the completion threshold
   * it starts over. Outside Watch Together a card offers "Start over".
   */
  function applyResume (token) {
    if (token !== loadToken || !video) return
    const resume = resumePosition(getEpisodeProgress(), {
      threshold: $settings.playerAutocompleteThreshold,
      duration: isFinite(video.duration) ? video.duration : 0
    })
    if (resume == null) return
    seekTo(resume)
    if (!state.value) showResumeOffer(resume)
  }

  /** "Resumed at 12:34 · Start over / Resume" card: { label } for 10 s after an automatic resume (as on iPhone). */
  let resumeOffer = null
  let resumeOfferTimer = null
  function showResumeOffer (time) {
    clearTimeout(resumeOfferTimer)
    const token = loadToken
    resumeOffer = { label: toTS(time, 3) }
    resumeOfferTimer = setTimeout(() => {
      if (token === loadToken) resumeOffer = null
    }, 10_000)
  }

  function answerResumeOffer (startOver) {
    clearTimeout(resumeOfferTimer)
    resumeOffer = null
    if (startOver) seekTo(0)
  }

  function cycleSubtitles () {
    if (current && subs?.headers) {
      const tracks = subs.headers.filter((header) => header)
      const index = tracks.indexOf(subs.headers[subs.current]) + 1
      subs.selectCaptions(
        index >= tracks.length ? -1 : subs.headers.indexOf(tracks[index])
      )
      setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
    }
  }

  // Subtitle offset in seconds (positive shows them earlier), remembered per show and given to every renderer of
  // the episode (Subtitles keeps it for the renderer it creates later).
  let subDelay = 0
  /** what the offset field shows (the user may be typing "-" or "1,") */
  let subDelayText = '0'
  $: subs?.setTimeOffset?.(subDelay)
  const SUB_DELAY_KEY = 'subtitleOffsets'
  // "Search online subtitles…" panel (OnlineSubtitles.svelte), and ±0.5 s offset steps.
  let onlineSubsOpen = false
  $: if (miniplayer) onlineSubsOpen = false

  // Kept in the history cache (cleared by Settings > reset), 200 shows at most (playerstate.js rememberOffset).
  function savedSubDelay () {
    return parseSubtitleOffset(cache.getEntry(caches.HISTORY, SUB_DELAY_KEY)?.[showKey()]?.offset) ?? 0
  }

  function rememberSubDelay (value) {
    if (!current) return
    cache.setEntry(caches.HISTORY, SUB_DELAY_KEY, rememberOffset(cache.getEntry(caches.HISTORY, SUB_DELAY_KEY), showKey(), value))
  }

  function typeSubDelay (text) {
    subDelayText = text
    const value = parseSubtitleOffset(text)
    if (value == null) return
    subDelay = value
    rememberSubDelay(value)
  }

  function stepDelay (step) {
    subDelay = Math.round((subDelay + step) * 10) / 10
    subDelayText = String(subDelay)
    rememberSubDelay(subDelay)
  }

  let currentTime = 0
  $: progress = (currentTime / safeduration) * 100
  $: targetTime = (!paused && currentTime) || targetTime
  function handleMouseDown ({ detail }) {
    if (wasPaused == null) {
      wasPaused = paused
      paused = true
    }
    targetTime = (detail / 100) * safeduration
  }
  function handleMouseUp () {
    paused = wasPaused
    wasPaused = null
    currentTime = targetTime
  }
  $: pagePause($page, $playPage, $modal)
  let pagePaused = 0
  function pagePause (_page, _playPage, _modal) {
    // Watch Together: a pause here would pause the whole lobby because one member opened another page.
    if (externalPlayback || $castState.active || state.value) return
    // Nothing loaded yet: nothing to pause or resume. (This tested a torrent `buffer` that stayed at 0 with streams,
    // so the episode kept playing invisibly behind the trailer, extension menu, notifications...)
    if (!video?.readyState && pagePaused) {
      pagePaused = 1
      return
    }
    const updateRequest = _modal[modal.UPDATE_PROMPT]
    const playerPage = _page === page.PLAYER || (!_playPage && updateRequest)
    const playPage = _playPage || updateRequest
    const viewDetails =
      Object.keys(_modal).length === 1 && _modal[modal.ANIME_DETAILS]
    const overlayCount = Object.keys(_modal).length
    if (!video?.ended) {
      if (
        (!playerPage || viewDetails || updateRequest) &&
        !paused &&
        playPage &&
        !pip
      ) {
        pagePaused = 2
        playPause()
      } else if (
        playerPage &&
        paused &&
        pagePaused === 2 &&
        !overlayCount &&
        playPage &&
        !pip
      ) {
        pagePaused = 1
        playPause()
      } else if (
        overlayCount &&
        ((!viewDetails && !updateRequest && !playerPage) || overlayCount > 1) &&
        !paused &&
        !playPage &&
        !pip
      ) {
        pagePaused = 2
        playPause()
      } else if (
        (!overlayCount || viewDetails || updateRequest) &&
        paused &&
        pagePaused === 2 &&
        !playPage &&
        !pip
      ) {
        pagePaused = 1
        playPause()
      } else if (
        (!playerPage || overlayCount) &&
        paused &&
        pagePaused &&
        pagePaused !== 2
      ) {
        pagePaused = 3
      }
    }
    if (!pagePaused) pagePaused = 1
  }
  /** Filler / recap prompt and "failed to identify" prompt of the episode loading (`token`). */
  async function promptFiller (token) {
    emit('duration', { current, duration })
    // The file's own media: nowPlaying (`media`) may still be the previous episode at this point.
    const fileMedia = current?.media
    let fillerEpisode = null
    try {
      if (fileMedia?.media?.idMal && isValidNumber(fileMedia.episode)) fillerEpisode = await episodesList.getSingleEpisode(fileMedia.media.idMal, fileMedia.episode)
    } catch (error) {
      debug('Filler lookup failed', error)
    }
    if (token !== loadToken) return
    filler = fillerEpisode?.filler && 'Filler'
    recap = fillerEpisode?.recap && 'Recap'
    resolvePrompt =
      current?.failed || current?.media?.failed || current?.parseObject?.failed
    skipPrompt = filler || recap
  }
  async function autoPlay (token) {
    await promptFiller(token)
    if (token !== loadToken || !video || externalPlayback) return
    if (
      (($page === page.PLAYER && modal.length === 0) || pip) &&
      !resolvePrompt &&
      !skipPrompt
    ) {
      if (!hidden) {
        video.play()?.catch?.(() => {})
        resetImmerse()
        setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
      }
    } else video.pause()
  }

  /**
   * One handler for loadedmetadata, in order. A reload of the same episode (server switch, retry, back from the
   * external player) restores its position and play state; a new episode resumes, prompts and autoplays.
   */
  function handleLoadedMetadata () {
    const token = loadToken
    hideBuffering()
    initThumbnails()
    findChapters()
    checkAudio()
    applySubtitlePreference()
    const restore = pendingRestore
    pendingRestore = null
    if (restore && restore.stream === streamToken) {
      if (restore.time > 0) seekTo(beforeEnd(restore.time))
      if (!restore.paused && !hidden) video.play()?.catch?.(() => {})
      else video.pause()
    } else {
      applyResume(token)
      w2gLoadSteps.push(autoPlay(token))
    }
    w2gLoadedMetadata()
  }

  /**
   * A position restored at the very end (back from an external player that reached it, a reload during the last
   * second) would fire `ended` and start the next episode on its own: a little before it instead.
   */
  function beforeEnd (time) {
    const length = videoLength()
    return length > 10 ? Math.min(time, length - 3) : time
  }

  function playPause () {
    if (hidden || externalPlayback) return
    paused = !paused
    resetImmerse()
    setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
  }
  let hidden = false
  let visibilityPaused = true
  const handleVisibility = (visible) => {
    if ($settings.playerPause && !pip && !$castState.active) {
      hidden = !visible
      if (!video?.ended) {
        if (hidden) {
          holdSpeed.cancel()
          visibilityPaused = paused
          paused = true
        } else if (!visibilityPaused) paused = false
      }
    }
  }
  ELECTRON.isMinimized().then((isMinimized) => {
    handleVisibility(!isMinimized)
    ELECTRON.onMinimize(handleVisibility)
  })
  /** End of the episode (or its credits): next episode with autoplay, the lobby's next queued item in Watch Together. True when something starts. */
  function tryPlayNext () {
    currentSkippable = null
    clearUpNext()
    // Watch Together: the host plays the next queued item ("Up next"), else nothing as before.
    if (state.value) return !externalPlayback && !!state.value.episodeEnded()
    if (!$settings.playerAutoplay || !hasNext) return false
    playNext()
    return true
  }
  function playNext () {
    if (hasNext) {
      const index = videos.indexOf(current)
      if (index + 1 < videos.length) {
        const target = (index + 1) % videos.length
        handleCurrent(videos[target])
        w2gEmitter.emit('index', { index: target })
      } else if (
        media?.media?.nextAiringEpisode?.episode - 1 ||
        (media?.media?.episodes || getMediaMaxEp(media?.media)) > media?.episode
      ) {
        playAnime(media.media, media.episode + 1)
      }
    }
  }
  function playLast () {
    if (hasLast) {
      const index = videos.indexOf(current)
      if (index > 0) {
        handleCurrent(videos[index - 1])
        w2gEmitter.emit('index', { index: index - 1 })
      } else if (
        media?.episode > 1 ||
        (media?.zeroEpisode && media?.episode === 1)
      ) {
        playAnime(media.media, media.episode - 1)
      }
    }
  }
  function rememberBoost () {
    cache.setEntry(caches.HISTORY, 'lastBoosted', {
      ...(cache.getEntry(caches.HISTORY, 'lastBoosted') || {}),
      [showKey()]: { boosted: volumeBoosted, gain }
    })
  }
  function setGain (event) {
    const value = parseFloat(event.target.value)
    if (value <= 1) {
      gainNode.gain.value = 1
      volume = value
    } else {
      volume = 1
      gainNode.gain.value = value
    }
    gain = value
    rememberBoost()
  }
  function toggleGain () {
    setupAudio()
    if (volumeBoosted) {
      volume = gain <= 1 ? gain : 1
      gain = 1
      if (audioCtx) gainNode.gain.value = 1
    } else setGain({ target: { value: volume } })
    volumeBoosted = !volumeBoosted
    rememberBoost()
  }
  function toggleMute () {
    muted = !muted
  }
  function toggleFullscreen () {
    if (!externalPlayback) {
      document.fullscreenElement
        ? document.exitFullscreen()
        : container.requestFullscreen()
    }
  }
  function skip () {
    if (!video || externalPlayback) return
    const current = findChapter(currentTime)
    if (current) {
      if (
        !isChapterSkippable(current) &&
        (current.end - current.start) / 1_000 > 100
      ) {
        currentTime = currentTime + 85
      } else {
        const endtime = current.end / 1_000
        // Last chapter: next episode (autoplay), or the lobby's next item in Watch Together (never a local playNext
        // there: every member would start the next episode on their own).
        if (
          ((safeduration - endtime) | 0) === 0 &&
          (state.value || (hasNext && settings.value.playerAutoplay)) &&
          tryPlayNext()
        ) return
        currentTime = endtime
        currentSkippable = null
      }
    } else if (currentTime < 10) {
      currentTime = 90
    } else if (safeduration - currentTime < 90) {
      currentTime = safeduration
    } else {
      currentTime = currentTime + 85
    }
    targetTime = currentTime
    video.currentTime = targetTime
  }
  function seek (time) {
    if (externalPlayback || !video) return
    currentTime = currentTime + time
    targetTime = currentTime
    video.currentTime = targetTime
  }
  function forward () {
    seek(settings.value.playerSeek)
  }
  function rewind () {
    seek(-settings.value.playerSeek)
  }
  function selectAudio (id) {
    if (id != null) {
      for (const track of video.audioTracks) {
        track.enabled = track.id === id
      }
      seek(-0.2) // stupid fix because video freezes up when changing tracks
    }
  }
  function selectVideo (id) {
    if (id != null) {
      for (const track of video.videoTracks) {
        track.selected = track.id === id
      }
      setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
    }
  }
  // function toggleCast () {
  //   if (video.readyState) {
  //     if (presentationConnection) {
  //       presentationConnection?.terminate()
  //     } else {
  //       presentationRequest.start()
  //     }
  //   }
  // }
  async function screenshot () {
    if ('clipboard' in navigator && video.readyState) {
      const canvas = document.createElement('canvas')
      const context = canvas.getContext('2d')
      canvas.width = video.videoWidth
      canvas.height = video.videoHeight
      context.drawImage(video, 0, 0)
      if (subs?.renderer) {
        subs.renderer.resize(video.videoWidth, video.videoHeight)
        await new Promise((resolve) => setTimeout(resolve, 500)) // this is hacky, but TLDR wait for canvas to update and re-render, in practice this will take at MOST 100ms, but just to be safe
        context.drawImage(
          subs.renderer._canvas,
          0,
          0,
          canvas.width,
          canvas.height
        )
        subs.renderer.resize(0, 0, 0, 0) // undo resize
      }
      const blob = await new Promise((resolve) => canvas.toBlob(resolve))
      await navigator.clipboard.write([
        new ClipboardItem({
          [blob.type]: blob
        })
      ])
      canvas.remove()
      toast.success('Screenshot', {
        description: 'Saved screenshot to clipboard.'
      })
    }
  }
  function updatePiPState (paused) {
    const element = /** @type {HTMLVideoElement | undefined} */ (
      document.pictureInPictureElement
    )
    if (!element || element.id) return
    if (paused) element.pause()
    else element.play()
  }
  $: updatePiPState(paused)
  async function togglePopout () {
    if (video && video.readyState) {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture()
        pip = false
      } else {
        try {
          await video.requestPictureInPicture()
          pip = true
        } catch (e) {
          console.error('PiP failed, falling back to miniplayer', e)
          if ($page === page.PLAYER) {
            resetImmerse()
            page.navigateTo(page.HOME)
          }
        }
      }
    }
  }
  // ---- Hold to speed up (modules/holdspeed.js): hold the Play/Pause key or the mouse button on the video.
  /** speed shown by the indicator while held, null otherwise */
  let holdSpeedShown = null
  /** the click that ends a mouse hold is not a play / pause */
  let holdClickIgnoredUntil = 0
  const holdSpeed = new HoldSpeed({
    // canPlay: metadata loaded (the old `src` test was only true in the rare fallback, so holding never worked).
    canHold: () => !!($settings.playerHoldSpeedUp && video && canPlay && !externalPlayback && !hidden && !$castState.active),
    // A temporary rate would drift from the lobby: off while following it (watching on our own nothing is synced).
    blocked: () => !!state.value?.isFollowing,
    speed: () => holdSpeedOf($settings.playerHoldSpeed),
    getRate: () => video?.playbackRate || 1,
    setRate: (rate) => { if (video) video.playbackRate = rate },
    isPaused: () => !video || video.paused,
    setPaused: (value) => {
      if (!video) return
      if (value) video.pause()
      else video.play()?.catch?.(() => {})
    },
    onChange: (speed) => { holdSpeedShown = speed },
    onBlocked: () => toast('Watch Together', { description: 'Hold to speed up is off while you watch in sync with the lobby.', duration: 2500 })
  })

  /** Play/Pause key: a tap plays / pauses when released, holding it plays faster. */
  function playPauseKey (event) {
    if (event instanceof KeyboardEvent && $settings.playerHoldSpeedUp) {
      if (event.repeat || holdSpeed.press(`key:${event.code}`)) return
    }
    playPause()
  }

  function holdKeyUp (event) {
    const result = holdSpeed.release(`key:${event.code}`)
    if (!result) return
    event.preventDefault()
    if (result === 'tap') playPause()
  }

  function holdPointerDown (event) {
    if (event.button !== 0 || event.pointerType === 'touch' || miniplayer || $page !== page.PLAYER || modal.length !== 0) return
    if (holdSpeed.press('pointer')) event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  // pointerup, pointercancel and lostpointercapture: the first one ends the press.
  function holdPointerUp () {
    if (holdSpeed.release('pointer') === 'hold') holdClickIgnoredUntil = Date.now() + 400
  }

  const cancelHold = () => holdSpeed.cancel()
  window.addEventListener('keyup', holdKeyUp, true)
  window.addEventListener('blur', cancelHold)
  onDestroy(() => {
    window.removeEventListener('keyup', holdKeyUp, true)
    window.removeEventListener('blur', cancelHold)
    holdSpeed.cancel()
  })

  let fitWidth = false
  let showKeybinds = false
  loadWithDefaults({
    KeyX: {
      fn: () => !viewAnime && screenshot(),
      id: 'screenshot_monitor',
      icon: ScreenShare,
      type: 'icon',
      desc: 'Save Screenshot to Clipboard'
    },
    KeyI: {
      fn: () => !viewAnime && toggleStats(),
      icon: List,
      id: 'list',
      type: 'icon',
      desc: 'Toggle Stats'
    },
    KeyO: {
      fn: () => {
        if (media?.media) modal.toggle(modal.ANIME_DETAILS, media.media)
      },
      icon: Eye,
      id: 'eye',
      type: 'icon',
      desc: 'Toggle Now Playing'
    },
    KeyH: {
      fn: () => {
        if (!viewAnime) {
          resolvePrompt = false
          modal.toggle(modal.FILE_MANAGER)
        }
      },
      icon: SquarePen,
      id: 'squarepen',
      type: 'icon',
      desc: 'Toggle File Manager'
    },
    Backquote: {
      fn: () => !viewAnime && (showKeybinds = !showKeybinds),
      id: 'help_outline',
      icon: CircleHelp,
      type: 'icon',
      desc: 'Toggle Keybinds'
    },
    Space: {
      fn: (e) => !viewAnime && playPauseKey(e),
      id: 'play_arrow',
      icon: Play,
      type: 'icon',
      desc: 'Play/Pause (Hold to Speed Up)'
    },
    KeyN: {
      fn: () => !viewAnime && playNext(),
      id: 'skip_next',
      icon: SkipForward,
      type: 'icon',
      desc: 'Next Episode'
    },
    KeyB: {
      fn: () => !viewAnime && playLast(),
      id: 'skip_previous',
      icon: SkipBack,
      type: 'icon',
      desc: 'Previous Episode'
    },
    KeyA: {
      fn: () =>
        !viewAnime && ($settings.playerDeband = !$settings.playerDeband),
      id: 'deblur',
      icon: Contrast,
      type: 'icon',
      desc: 'Toggle Video Debanding'
    },
    KeyM: {
      fn: () => !viewAnime && (muted = !muted),
      id: 'volume_off',
      icon: VolumeX,
      type: 'icon',
      desc: 'Toggle Mute'
    },
    KeyP: {
      fn: () => !viewAnime && togglePopout(),
      id: 'picture_in_picture',
      icon: PictureInPicture2,
      type: 'icon',
      desc: 'Toggle Picture in Picture'
    },
    KeyF: {
      fn: () => !viewAnime && toggleFullscreen(),
      id: 'fullscreen',
      icon: Maximize,
      type: 'icon',
      desc: 'Toggle Fullscreen'
    },
    KeyS: {
      fn: () => !viewAnime && skip(),
      id: '+90',
      desc: 'Skip Intro/90s'
    },
    KeyW: {
      fn: () => !viewAnime && (fitWidth = !fitWidth),
      id: 'fit_width',
      icon: Proportions,
      type: 'icon',
      desc: 'Toggle Video Cover'
    },
    // KeyD: {
    //   fn: () => !viewAnime && toggleCast(),
    //   id: 'cast',
    //   icon: Cast,
    //   type: 'icon',
    //   desc: 'Toggle Cast [broken]'
    // },
    KeyC: {
      fn: () => !viewAnime && cycleSubtitles(),
      id: 'subtitles',
      icon: Captions,
      type: 'icon',
      desc: 'Cycle Subtitles'
    },
    KeyV: {
      fn: () => !viewAnime && toggleGain(),
      id: 'toggle_gain',
      icon: SlidersVertical,
      type: 'icon',
      desc: 'Toggle Volume Limit Increase'
    },
    ArrowLeft: {
      fn: (e) => {
        if (viewAnime) return
        e.stopImmediatePropagation()
        e.preventDefault()
        rewind()
      },
      id: 'fast_rewind',
      icon: Rewind,
      type: 'icon',
      desc: 'Rewind'
    },
    ArrowRight: {
      fn: (e) => {
        if (viewAnime) return
        e.stopImmediatePropagation()
        e.preventDefault()
        forward()
      },
      id: 'fast_forward',
      icon: FastForward,
      type: 'icon',
      desc: 'Seek'
    },
    ArrowUp: {
      fn: (e) => {
        if (viewAnime) return
        e.stopImmediatePropagation()
        e.preventDefault()
        if (volumeBoosted) { setGain({ target: { value: Math.min(3, gain + 0.05) } }) } else volume = Math.min(1, volume + 0.05)
      },
      id: 'volume_up',
      icon: Volume2,
      type: 'icon',
      desc: 'Volume Up'
    },
    ArrowDown: {
      fn: (e) => {
        if (viewAnime) return
        e.stopImmediatePropagation()
        e.preventDefault()
        if (volumeBoosted) { setGain({ target: { value: Math.max(0, gain - 0.05) } }) } else volume = Math.max(0, volume - 0.05)
      },
      id: 'volume_down',
      icon: Volume1,
      type: 'icon',
      desc: 'Volume Down'
    },
    BracketLeft: {
      fn: () =>
        !viewAnime &&
          !externalPlayback &&
          (playbackRate = video.defaultPlaybackRate -= 0.1),
      id: 'history',
      icon: RotateCcw,
      type: 'icon',
      desc: 'Decrease Playback Rate'
    },
    BracketRight: {
      fn: () =>
        !viewAnime &&
          !externalPlayback &&
          (playbackRate = video.defaultPlaybackRate += 0.1),
      id: 'update',
      icon: RotateCw,
      type: 'icon',
      desc: 'Increase Playback Rate'
    },
    Backslash: {
      fn: () =>
        !viewAnime &&
          !externalPlayback &&
          (playbackRate = video.defaultPlaybackRate = 1),
      icon: RefreshCcw,
      id: 'schedule',
      type: 'icon',
      desc: 'Reset Playback Rate'
    }
  })

  function getBurnIn (noSubs) {
    const canvas = document.createElement('canvas')
    const context = canvas.getContext('2d')
    let loop = null
    canvas.width = video.videoWidth
    canvas.height = video.videoHeight
    if (!noSubs) subs.renderer.resize(video.videoWidth, video.videoHeight)
    const renderFrame = () => {
      context.drawImage(deband ? deband.canvas : video, 0, 0)
      if (!noSubs && canvas.width && canvas.height) {
        context.drawImage(
          subs.renderer?._canvas,
          0,
          0,
          canvas.width,
          canvas.height
        )
      }
      loop = video.requestVideoFrameCallback(renderFrame)
    }
    renderFrame()
    const destroy = () => {
      if (!noSubs) subs.renderer.resize()
      video.cancelVideoFrameCallback(loop)
      canvas.remove()
    }
    container.append(canvas)
    return { stream: canvas.captureStream(), destroy }
  }

  // function initCast (event) {
  //   // these quality settings are likely to make cast overheat, oh noes!
  //   let peer = new Peer({
  //     polite: true,
  //     quality: {
  //       audio: {
  //         stereo: 1,
  //         'sprop-stereo': 1,
  //         maxaveragebitrate: 510000,
  //         maxplaybackrate: 510000,
  //         cbr: 0,
  //         useinbandfec: 1,
  //         usedtx: 1,
  //         maxptime: 20,
  //         minptime: 10
  //       },
  //       video: {
  //         bitrate: 2000000,
  //         codecs: ['VP9', 'VP8', 'H264']
  //       }
  //     }
  //   })

  //   presentationConnection = event.connection
  //   presentationConnection.addEventListener('terminate', () => {
  //     presentationConnection = null
  //     peer = null
  //   })

  //   peer.signalingPort.onmessage = ({ data }) => {
  //     presentationConnection.send(data)
  //   }

  //   presentationConnection.addEventListener('message', ({ data }) => {
  //     peer.signalingPort.postMessage(data)
  //   })

  //   peer.dc.onopen = () => {
  //     if (peer && presentationConnection) {
  //       const tracks = []
  //       const videostream = video.captureStream()
  //       if (true) {
  //         // TODO: check if cast supports codecs
  //         const { stream, destroy } = getBurnIn(!subs?.renderer)
  //         tracks.push(stream.getVideoTracks()[0], videostream.getAudioTracks()[0])
  //         presentationConnection.addEventListener('terminate', destroy)
  //       } else {
  //         tracks.push(videostream.getVideoTracks()[0], videostream.getAudioTracks()[0])
  //       }
  //       for (const track of tracks) {
  //         peer.pc.addTrack(track, videostream)
  //       }
  //       paused = false // video pauses for some reason
  //     }
  //   }
  // }

  function immersePlayer () {
    if (safeduration - currentTime !== 0) {
      immersed = true
      immerseTimeout = undefined
    }
  }

  let immerseToken = 0
  function resetImmerse () {
    clearTimeout(immerseTimeout)
    const token = ++immerseToken
    const wasImmersed = immersed
    setTimeout(() => {
      if (token !== immerseToken || wasImmersed !== immersed) return
      immersed = false
      if (!paused || miniplayer) {
        immerseTimeout = setTimeout(
          () => {
            if (token === immerseToken) immersePlayer()
          },
          (paused ? 5 : 1.5) * 1_000
        )
      }
    })
  }

  function toggleImmerse () {
    if (immersed) resetImmerse()
    else {
      clearTimeout(immerseTimeout)
      immersed = !immersed
    }
  }

  /** The video has its metadata (something is loaded): hold to speed up, 16:9 placeholder off. */
  let canPlay = false
  function hideBuffering () {
    canPlay = (video?.readyState || 0) >= 1
    clearTimeout(bufferTimeout)
    bufferTimeout = null
    buffering = false
  }

  function showBuffering () {
    // One pending timer at a time: an overwritten one fired after hideBuffering and left the spinner on.
    clearTimeout(bufferTimeout)
    bufferTimeout = setTimeout(() => {
      bufferTimeout = null
      buffering = true
      resetImmerse()
    }, 150)
  }
  $: navigator.mediaSession?.setPositionState({
    duration: Math.max(0, safeduration || 0),
    playbackRate: 1,
    position: Math.max(0, Math.min(safeduration || 0, currentTime || 0))
  })

  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('play', playPause)
    navigator.mediaSession.setActionHandler('pause', playPause)
    navigator.mediaSession.setActionHandler('nexttrack', playNext)
    navigator.mediaSession.setActionHandler('previoustrack', playLast)
    navigator.mediaSession.setActionHandler('seekforward', forward)
    navigator.mediaSession.setActionHandler('seekbackward', rewind)
  }
  let filler = null
  let recap = null
  let skipPrompt = false
  function skipResponse (skip) {
    skipPrompt = false
    if (skip) playNext()
    else {
      video.play()
      setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
    }
  }
  let resolvePrompt = false
  function resolveResponse (resolve) {
    resolvePrompt = false
    if (resolve) modal.open(modal.FILE_MANAGER)
    else {
      video.play()
      setTimeout(() => subs?.renderer?.resize(), 200) // stupid fix because video metadata doesn't update for multiple frames
    }
  }
  // Stats overlay [I]: refreshed from video frame callbacks while on. stopStats() runs on every episode change and on
  // close (the overlay read current.name of a closed player and the error froze the UI).
  let stats = null
  let statsOn = false
  let statsCallback = null
  let statsTimer = null
  function toggleStats () {
    if (statsOn) return stopStats()
    if (!video) return
    statsOn = true
    statsCallback = video.requestVideoFrameCallback((now, metadata) => handleStats(now, metadata, metadata))
    if (paused) seek(-0.001) // stupid hack because the initial request doesn't trigger canvas to re-render, stats won't appear unless the current time changes.
  }
  function stopStats () {
    statsOn = false
    stats = null
    clearTimeout(statsTimer)
    if (statsCallback != null) video?.cancelVideoFrameCallback?.(statsCallback)
    statsCallback = null
  }
  function handleStats (now, metadata, lastmeta) {
    if (!statsOn || !video) return
    const msbf =
      (metadata.mediaTime - lastmeta.mediaTime) /
        (metadata.presentedFrames - lastmeta.presentedFrames)
    const fps = (1 / msbf).toFixed(3)
    stats = {
      fps,
      presented: metadata.presentedFrames,
      dropped: video.getVideoPlaybackQuality()?.droppedVideoFrames,
      processing: metadata.processingDuration + ' ms',
      viewport: video.clientWidth + 'x' + video.clientHeight,
      resolution: videoWidth + 'x' + videoHeight,
      buffer: getBufferHealth(metadata.mediaTime) + ' s',
      speed: video.playbackRate || 1
    }
    clearTimeout(statsTimer)
    statsTimer = setTimeout(() => {
      if (!statsOn || !video) return
      statsCallback = video.requestVideoFrameCallback((n, m) => handleStats(n, m, metadata))
    }, 200)
  }
  function getBufferHealth (time) {
    for (let index = video.buffered.length; index--;) {
      if (
        time < video.buffered.end(index) &&
        time >= video.buffered.start(index)
      ) {
        return (video.buffered.end(index) - time) | 0
      }
    }
    return 0
  }
  /** Seekbar buffered part, in percent: what is loaded ahead of the position. */
  let buffer = 0
  function updateBuffer () {
    if (!video || !isFinite(video.duration) || !(video.duration > 0)) {
      buffer = 0
      return
    }
    const time = video.currentTime
    let end = 0
    for (let index = 0; index < video.buffered.length; index++) {
      if (video.buffered.start(index) <= time + 0.5 && video.buffered.end(index) >= time) end = Math.max(end, video.buffered.end(index))
    }
    buffer = Math.min(100, (end / video.duration) * 100)
  }

  let chapters = []
  // Chapters: the file's own (embedded) when it has some, otherwise AniSkip for anime, then TheIntroDB (shows,
  // movies, and the anime episodes AniSkip does not know).
  async function findChapters () {
    const target = current
    const media = target?.media?.media
    if (chapters.length || !media) return
    const duration = videoLength()
    let found = await getChaptersAniSkip(target, duration).catch(() => [])
    if (!found?.length) found = await getChaptersIntroDB(media, target.media.episode, duration).catch(() => [])
    if (target === current && !chapters.length && found?.length) chapters = found
  }

  let currentSkippable = null
  $: currentSkippable && $settings.playerSkip && skip() // "Auto-Skip Intro/Outro" (PlayerTab.svelte)
  function checkSkippableChapters () {
    const current = findChapter(currentTime)
    if (current) {
      currentSkippable = isChapterSkippable(current)
    }
  }

  // ---- "Up next": while the credits / preview close the episode (AniSkip, TheIntroDB or file chapters) and autoplay
  // is on, a card counts down 10 s of playback to the next episode. Full player only (not the miniplayer or PiP), and
  // not in Watch Together, where the lobby queue handles the end (same as the iPhone player).
  const UP_NEXT_S = 10
  /** { label, remaining } while the card shows */
  let upNext = null
  /** "Cancel" was clicked: no card again for this episode */
  let upNextDismissed = false
  let upNextTimer = null

  /** Never an episode title or a file name (spoilers): "Episode 5". */
  function nextLabel () {
    const index = videos.indexOf(current)
    const next = index !== -1 && index + 1 < videos.length ? videos[index + 1] : null
    if (next) return isValidNumber(next.media?.episode) ? `Episode ${next.media.episode}` : 'Next episode'
    return isValidNumber(media?.episode) ? `Episode ${Number(media.episode) + 1}` : 'Next episode'
  }

  function canAdvance () {
    return !externalPlayback && !miniplayer && !pip && !state.value && $settings.playerAutoplay && hasNext
  }

  function checkUpNext () {
    if (!video) return
    const time = video.currentTime
    // Auto-skip already jumps over a skippable chapter (and to the next episode from the last one).
    const show = !upNextDismissed && !($settings.playerSkip && currentSkippable) && canAdvance() &&
      safeduration - time > 2 && inEndChapters(chapters, time, safeduration)
    if (show && !upNext) startUpNext()
    else if (!show && upNext) clearUpNext()
  }

  function startUpNext () {
    clearInterval(upNextTimer)
    const token = loadToken
    upNext = { label: nextLabel(), remaining: UP_NEXT_S }
    upNextTimer = setInterval(() => {
      if (token !== loadToken || !upNext) return clearUpNext()
      // Paused, buffering or hidden: the countdown waits.
      if (paused || buffering || hidden) return
      upNext = { ...upNext, remaining: upNext.remaining - 1 }
      if (upNext.remaining <= 0) playUpNext()
    }, 1_000)
  }

  function clearUpNext () {
    clearInterval(upNextTimer)
    upNextTimer = null
    upNext = null
  }

  function playUpNext () {
    clearUpNext()
    upNextDismissed = true
    tryPlayNext()
  }

  function dismissUpNext () {
    clearUpNext()
    upNextDismissed = true
  }
  const MAX_TOTAL_SKIP_TIME = 180
  const MAX_TRUSTED_SKIP_TIME = 20 * 60 // TheIntroDB chapters (trusted) are meant for skipping: movie credits run long.
  const skippableChaptersRx = CHAPTER_KINDS // modules/playerstate.js (also used by "Up next")
  function isChapterSkippable (chapter) {
    if ((chapter.end - chapter.start) / 1_000 > (chapter.trusted ? MAX_TRUSTED_SKIP_TIME : MAX_TOTAL_SKIP_TIME)) { return null } // Anything longer than 180s (3m) is likely invalid, skipping this chapter would be a mistake!
    for (const [name, regex] of skippableChaptersRx) {
      if (
        /** @type {RegExp} */ chapter.text &&
        regex.test(chapter.text.trim())
      ) {
        return name
      }
    }
    return null
  }
  function findChapter (time) {
    if (!chapters.length) return null
    for (const chapter of chapters) {
      if (time < chapter.end / 1_000 && time >= chapter.start / 1_000) { return chapter }
    }
  }
  function mergeMicroSkippable (_chapters) {
    const isSkippable = (chapter) =>
      chapter.text &&
        skippableChaptersRx.some(([_, rx]) => rx.test(chapter.text.trim()))
    const isShort = (chapter) => (chapter.end - chapter.start) / 1_000 < 10 // anything shorter than 10 seconds is just fluff... probably a mistake.
    const underMaxSkip = (chapter) =>
      (chapter.end - chapter.start) / 1_000 <= MAX_TOTAL_SKIP_TIME
    for (let i = 0; i < _chapters.length - 1; i++) {
      const cur = _chapters[i]
      const next = _chapters[i + 1]
      if (
        isSkippable(cur) &&
        isSkippable(next) &&
        underMaxSkip(cur) &&
        underMaxSkip(next)
      ) {
        if (isShort(cur) && !isShort(next)) {
          next.start = cur.start
          _chapters.splice(i, 1)
          i--
        } else if (!isShort(cur) && isShort(next)) {
          cur.end = next.end
          _chapters.splice(i + 1, 1)
          i--
        } else if (isShort(cur) && isShort(next)) {
          cur.end = next.end
          _chapters.splice(i + 1, 1)
          i--
        }
      }
    }
    return _chapters
  }

  // remaps chapters to what perfect-seekbar uses and adds potentially missing chapters
  function sanitiseChapters (_chapters, safeduration) {
    if (!_chapters?.length) return []
    const first = _chapters[0]
    for (const chapter of _chapters) {
      // Fix negative values
      if (typeof chapter.start === 'number' && chapter.start < 0) { chapter.start = -chapter.start } // Fixes negative start values, likely was a mistake and is actually correct if positive.
      if (typeof chapter.end === 'number' && chapter.end < 0) { chapter.end = -chapter.end } // Fixes negative end values, likely was a mistake and is actually correct if positive.
    }
    if (first.start !== 0 && _chapters.some((ch) => ch?.start === 0)) {
      // Fix incorrect order of chapters (when start === 0 is somewhere else)
      _chapters.sort((a, b) => (a?.start ?? 0) - (b?.start ?? 0))
    }
    const boundaryMatches = _chapters
      .map((ch, i) => ({ ch, i }))
      .filter(({ ch }) => ch.start === first.end)
    if (boundaryMatches.length > 0) {
      // Fix overlapping chapters where valid chapter end time matches a valid chapter start time.
      boundaryMatches.sort(
        (a, b) => a.ch.end - a.ch.start - (b.ch.end - b.ch.start)
      )
      const boundaryIndex = boundaryMatches[0].i
      if (boundaryIndex > 1) _chapters.splice(1, boundaryIndex - 1)
    }
    _chapters = _chapters.map((chapter, index, arr) => {
      if (chapter.start === chapter.end) {
        // Fix chapters with incorrect start/end times which causes an invisible seekbar, this happens when the start and end time are identical
        const nextChapter = arr[index + 1] // We now assume each chapter is a bookmark and use the next chapters start time and the current chapters end time.
        return {
          ...chapter,
          end: nextChapter ? nextChapter.start : safeduration * 1_000
        } // Use next chapter's start or ensure the entire safe duration of seekbar is visible.
      }
      return chapter
    })
    _chapters[_chapters.length - 1].end = safeduration * 1_000 // fix the final chapter so its duration actually reaches the end of the video...
    _chapters[0].start = 0

    mergeMicroSkippable(_chapters)
    if (JSON.stringify(chapters) !== JSON.stringify(_chapters)) { chapters = _chapters }

    const sanitised = []
    let chapterCounter = 1
    for (let { start, end, text } of _chapters) {
      if (start > safeduration * 1_000) continue
      if (end > safeduration * 1_000) end = safeduration * 1_000
      if (text && /^[\d:.\s]+$/.test(text)) {
        // Replace numerical/timestamp-like chapter names
        text = `Chapter ${chapterCounter}`
        chapterCounter++
      }
      sanitised.push({
        size: end / 10 / safeduration - start / 10 / safeduration,
        text
      })
    }
    return sanitised
  }

  const thumbCanvas = document.createElement('canvas')
  thumbCanvas.width = 200
  const thumbnailData = {
    thumbnails: [],
    canvas: thumbCanvas,
    context: thumbCanvas.getContext('2d'),
    interval: null
  }

  function getThumbnail (percent) {
    return (
      thumbnailData.thumbnails[
        Math.floor(((percent / 100) * safeduration) / thumbnailData.interval)
      ] || ' '
    )
  }
  function createThumbnail (vid = video) {
    if (vid?.readyState >= 2 && !$castState.active && thumbnailData.interval) {
      const index = Math.floor(vid.currentTime / thumbnailData.interval)
      if (!thumbnailData.thumbnails[index]) {
        thumbnailData.context.fillRect(0, 0, 200, thumbnailData.canvas.height)
        thumbnailData.context.drawImage(
          vid,
          0,
          0,
          200,
          thumbnailData.canvas.height
        )
        thumbnailData.thumbnails[index] =
          thumbnailData.canvas.toDataURL('image/jpeg')
      }
    }
  }
  let videoWidth, videoHeight
  /** Length of the loaded video: on loadedmetadata the bound `duration` (and safeduration) may not be updated yet. */
  function videoLength () {
    return video && isFinite(video.duration) && video.duration > 0 ? video.duration : safeduration
  }
  function initThumbnails () {
    const height = 200 / ((video?.videoWidth || videoWidth) / (video?.videoHeight || videoHeight))
    if (!isNaN(height) && isFinite(height)) {
      const length = videoLength()
      thumbnailData.interval = length / 300 < 5 ? 5 : length / 300
      thumbnailData.canvas.height = height
      generateThumbnails()
    }
  }

  // Seekbar thumbnails ahead of playback come from a hidden second video seeking through the file. Only for files
  // served locally (offline downloads): for a remote stream it would download the episode a second time through the
  // proxy and pile range requests on the host (it used to poll forever on a `buffer` that stayed at 0, with the raw
  // URL and no headers). Remote streams get thumbnails from the frames played (createThumbnail).
  // (the local server may prefix its paths with a token: http://localhost:<port>/<token>/downloads/...)
  const localDownloadRx = /^http:\/\/(localhost|127\.0\.0\.1):\d+\/(?:[^/?#]+\/)?downloads\//i
  /** running generator: { videoDraw } */
  let thumbnailProcess = null

  function stopThumbnails () {
    const process = thumbnailProcess
    thumbnailProcess = null
    if (!process) return
    const videoDraw = process.videoDraw
    videoDraw.onloadeddata = videoDraw.onseeked = videoDraw.onerror = null
    videoDraw.removeAttribute('src')
    videoDraw.load() // releases the connection
  }

  function generateThumbnails () {
    stopThumbnails()
    const source = video?.currentSrc || ''
    if (!localDownloadRx.test(source) || !thumbnailData.interval) return
    debug('Starting thumbnail generation...')
    const t0 = performance.now()
    const videoDraw = document.createElement('video')
    const process = { videoDraw }
    thumbnailProcess = process
    videoDraw.preload = 'auto'
    videoDraw.muted = true
    let index = 0
    const captureNext = () => {
      if (thumbnailProcess !== process) return
      while (thumbnailData.thumbnails[index]) index++
      const time = index * thumbnailData.interval
      if (!isFinite(time) || !isFinite(videoDraw.duration) || time >= videoDraw.duration) {
        debug('Thumbnail generation has successfully completed, took:', toTS((performance.now() - t0) / 1_000))
        stopThumbnails()
        return
      }
      videoDraw.currentTime = time
    }
    videoDraw.onloadeddata = captureNext
    videoDraw.onseeked = () => {
      if (thumbnailProcess !== process) return
      thumbnailData.context.fillRect(0, 0, 200, thumbnailData.canvas.height)
      thumbnailData.context.drawImage(videoDraw, 0, 0, 200, thumbnailData.canvas.height)
      thumbnailData.thumbnails[index] = thumbnailData.canvas.toDataURL('image/jpeg')
      index++
      captureNext()
    }
    videoDraw.onerror = (e) => {
      debug('Error loading video for thumbnail generation:', e)
      if (thumbnailProcess === process) stopThumbnails()
    }
    videoDraw.src = source
  }

  // const isWindows = navigator.appVersion.includes('Windows')
  // let innerWidth, innerHeight
  const menubarOffset = 0
  // $: calcMenubarOffset(innerWidth, innerHeight, videoWidth, videoHeight)
  // function calcMenubarOffset (innerWidth, innerHeight, videoWidth, videoHeight) {
  //   // outerheight resize and innerheight resize is mutual, additionally update on metadata and app state change
  //   if (videoWidth && videoHeight) {
  //     // so windows is very dumb, and calculates windowed mode as if it was window XP, with the old bars, but not when maximised
  //     const isMaximised = screen.availWidth === window.outerWidth && screen.availHeight === window.outerHeight
  //     const menubar = Math.max(0, isWindows && !isMaximised ? window.outerHeight - innerHeight - 8 : window.outerHeight - innerHeight)
  //     // element ratio calc
  //     const videoRatio = videoWidth / videoHeight
  //     const { offsetWidth, offsetHeight } = video
  //     const elementRatio = offsetWidth / offsetHeight
  //     // video is shorter than element && has space for menubar offset
  //     if (!document.fullscreenElement && menubar && elementRatio <= videoRatio && offsetHeight - offsetWidth / videoRatio > menubar) {
  //       menubarOffset = (menubar / 2) * -1
  //     } else {
  //       menubarOffset = 0
  //     }
  //   }
  // }

  const showOptions = writable(false)
  // One player menu at a time: opening a dropdown (servers, subtitles, audio...) or the More menu closes the others,
  // which otherwise stay open and overlap.
  function closePlayerMenus (except = null) {
    for (const open of document.querySelectorAll('.player .dropdown.show')) {
      if (open === except) continue
      open.classList.remove('show')
      for (const active of open.querySelectorAll('.active')) {
        if (!active.closest('.dropdown-menu')) active.classList.remove('active')
      }
    }
  }
  function toggleDropdown ({ target }) {
    const dropdown = target.closest('.dropdown')
    if (!dropdown) return
    if (!dropdown.classList.contains('show')) {
      closePlayerMenus(dropdown)
      showOptions.set(false)
    }
    target.classList.toggle('active')
    dropdown.classList.toggle('show')
  }

  let completed = false
  function checkCompletion () {
    if (!completed && $settings.playerAutocomplete) {
      checkCompletionByTime(currentTime, safeduration)
    }
  }

  /** @param {boolean} [external] position reported by the external player (it is not loaded here) */
  function checkCompletionByTime (currentTime, safeduration, external = false) {
    let threshold = $settings.playerAutocompleteThreshold / 100
    if (external && threshold > 0.7) threshold = 0.7 // accommodates skipping op/ed in external player.
    if (
      safeduration &&
      currentTime &&
      (video?.readyState || external) &&
      currentTime >= safeduration * threshold &&
      (media?.media?.episodes ||
        media?.media?.nextAiringEpisode?.episode >=
        (media.episodeRange?.last || media.episode))
    ) {
      debug(
        `Marking current episode as completed as it has met the ${$settings.playerAutocompleteThreshold}% threshold.`
      )
      completed = true
      const _media = media.episodeRange ? structuredClone(media) : media
      if (media.episodeRange) _media.episode = media.episodeRange.last
      updateEntryOrQueue(_media) // Helper.updateEntry, queued while offline
    }
  }

  // Playback errors keep the saved progress (they used to reset it to 0, losing the resume position of an episode
  // whose server failed) and offer "Retry", which reloads the stream where it stopped.
  function checkError ({ target }) {
    if (target !== video || !current) return
    hideBuffering()
    // video playback failed - show a message saying why
    switch (target.error?.code) {
      case target.error.MEDIA_ERR_ABORTED:
        debug('You aborted the video playback.')
        break
      case target.error.MEDIA_ERR_NETWORK:
        debug(
          'A network error caused the video download to fail part-way.',
          target.error
        )
        toast.error('Video Network Error', {
          description:
            'A network error caused the video download to fail part-way.',
          duration: Infinity,
          action: { label: 'Retry', onClick: retryStream }
        })
        break
      case target.error.MEDIA_ERR_DECODE:
        debug(
          'The video playback was aborted due to a corruption problem or because the video used features your browser did not support.',
          target.error
        )
        toast.error('Video Decode Error', {
          description:
            'The video playback was aborted due to a corruption problem.',
          duration: Infinity,
          action: { label: 'Retry', onClick: retryStream }
        })
        break
      case target.error.MEDIA_ERR_SRC_NOT_SUPPORTED:
        if (
          target.error.message !== 'MEDIA_ELEMENT_ERROR: Empty src attribute'
        ) {
          debug(
            'The video could not be loaded, either because the server or network failed or because the format is not supported.',
            target.error
          )
          toast.error('Video Codec Unsupported', {
            description:
              'The video could not be loaded, either because the server or network failed or because the format is not supported. Try another server, or a different source from another extension.',
            duration: 30_000,
            action: { label: 'Retry', onClick: retryStream }
          })
        }
        break
      default:
        debug('An unknown video playback error occurred.')
        break
    }
  }

  function handleSeekbarKey (e) {
    if (e.key === 'ArrowLeft') {
      e.stopPropagation()
      e.stopImmediatePropagation()
      e.preventDefault()
      rewind()
    } else if (e.key === 'ArrowRight') {
      e.stopPropagation()
      e.stopImmediatePropagation()
      e.preventDefault()
      forward()
    } else if (e.key === 'ArrowDown') {
      e.stopPropagation()
      e.stopImmediatePropagation()
      e.preventDefault()
      document.querySelector("[data-name='toggleFullscreen']")?.focus()
    }
  }

  let fileInput
  function handleFile (event) {
    const file = event.target.files[0]
    if (!file) return
    const dataTransfer = new DataTransfer()
    dataTransfer.items.add(file)
    window.dispatchEvent(
      new ClipboardEvent('paste', { clipboardData: dataTransfer })
    )
  }

  function setDiscordRPC (np = media, browsing, fullMedia = current?.media?.media) {
    if ((!np || Object.keys(np).length === 0) && !browsing && !fullMedia) return
    if (hidden) {
      IPC.emit('discord-clear')
      return
    }

    /** @type {any} */
    let activity
    if (!browsing) {
      const w2g = state.value?.code
      const playingMedia = $nowPlaying?.media ?? fullMedia
      if (isAdultMedia(playingMedia) && $settings.rpcHideAdult !== 'off') {
        // Adult content stays private: no presence at all, or a generic status without title, cover or links.
        if ($settings.rpcHideAdult === 'hidden') {
          IPC.emit('discord-clear')
          return
        }
        activity = {
          timestamps: { start: Date.now() },
          details: 'Watching Media on Tsumi',
          state: 'Watching something',
          assets: { large_image: 'icon', large_text: 'Tsumi — Media Streaming' },
          instance: true,
          type: 3,
          buttons: presenceButtons(null, w2g)
        }
        IPC.emit('discord', { activity })
        return
      }
      const currentParseObject = $nowPlaying?.parseObject || current?.media?.parseObject
      const cleanCurrentName = current?.name
        ? AnimeResolver.cleanFileName(current.name)
        : undefined
      let details =
        ($nowPlaying?.title && !String($nowPlaying.title).includes('undefined') ? $nowPlaying.title : undefined) ||
          (fullMedia ? anilistClient.title(fullMedia) : undefined) ||
          ($nowPlaying?.media ? anilistClient.title($nowPlaying.media) : undefined) ||
          currentParseObject?.title ||
          currentParseObject?.anime_title ||
          currentParseObject?.file_name ||
          cleanCurrentName ||
          'Watching Media'

      if (typeof details === 'string' && details.includes('undefined')) {
        details = details.replace(/undefined\s*-\s*/g, '').replace('undefined', '').trim()
      }

      if (!details) {
        return
      }
      const timeLeft = safeduration - targetTime
      const timestamps = !paused
        ? {
          start: Date.now() - (targetTime > 0 ? targetTime * 1_000 : 0),
          end: Date.now() + timeLeft * 1_000
          }
        : undefined
      activity = {
        details: details || 'Watching Media on Tsumi',
        state:
          details &&
            ((($nowPlaying?.media ?? fullMedia)?.format === 'MOVIE' && (($nowPlaying?.media ?? fullMedia)?.episodes ?? 0) <= 1)
              ? 'The Movie'
              : ($nowPlaying?.episode ?? current?.media?.episode)
              ? 'Episode: ' +
                ($nowPlaying?.episode ?? current?.media?.episode) +
                (($nowPlaying?.media?.episodes ?? fullMedia?.episodes) ? ' of ' + ($nowPlaying?.media?.episodes ?? fullMedia?.episodes) : '')
              : 'Streaming the Universe'),
        timestamps,
        party: {
          size:
            (($nowPlaying?.episode ?? current?.media?.episode) &&
              ($nowPlaying?.media?.episodes ?? fullMedia?.episodes) &&
              [($nowPlaying?.episode ?? current?.media?.episode), ($nowPlaying?.media?.episodes ?? fullMedia?.episodes)]) ||
              undefined
        },
        assets: {
          large_text: details || 'Watching on Tsumi',
          large_image:
            $nowPlaying?.media?.coverImage?.extraLarge ||
              $nowPlaying?.media?.coverImage?.large ||
              fullMedia?.coverImage?.extraLarge ||
              fullMedia?.coverImage?.large ||
              $nowPlaying?.thumbnail ||
              'icon'
        },
        instance: true,
        type: 3
      }
      // Discord allows two link buttons, and no buttons together with join secrets: during Watch Together
      // the join goes through a public https page that opens tsumi://w2g/CODE (it also works from phones).
      activity.buttons = presenceButtons($nowPlaying?.media ?? fullMedia, w2g)
      if (w2g) activity.party.id = w2g + 'p'
    } else {
      activity = {
        timestamps: { start: Date.now() },
        details: 'Watching Media on Tsumi',
        state: 'Browsing the library',
        assets: {
          large_image: 'icon',
          large_text: 'Tsumi — Media Streaming'
        },
        instance: true,
        type: 3,
        buttons: presenceButtons(null, state.value?.code)
      }
    }
    IPC.emit('discord', { activity })
  }

  const TSUMI_LINK = 'https://mxfia19.github.io/Tsumi/'

  /** Adult media (AniList isAdult or the Hentai genre), hidden from the presence by the rpcHideAdult setting. */
  function isAdultMedia (media) {
    return !!(media?.isAdult || media?.genres?.includes?.('Hentai'))
  }

  /**
   * Rich presence buttons (2 at most): the title page first (AniList, or TMDB for shows and movies), then
   * "Join Watch Together" in a lobby, otherwise MyAnimeList or the download page (rpcSecondButton setting).
   * @param {any} media
   * @param {string} [w2g] lobby code
   */
  function presenceButtons (media, w2g) {
    const buttons = []
    const isTmdb = media?.isTmdb || (typeof media?.id === 'string' && media.id.startsWith('tmdb-'))
    const isMovie = media?.format === 'MOVIE'
    if (w2g) buttons.push({ label: 'Join Watch Together', url: `${TSUMI_LINK}w2g/?c=${encodeURIComponent(w2g)}` })
    if (media?.id) {
      if (isTmdb) {
        const tmdbId = typeof media.id === 'string' ? media.id.replace(/^tmdb-(tv-|movie-)?/, '') : media.idTmdb
        if (tmdbId) buttons.push({ label: isMovie ? 'View Movie' : 'View Show', url: `https://www.themoviedb.org/${isMovie ? 'movie' : 'tv'}/${tmdbId}` })
      } else {
        buttons.push({ label: 'View on AniList', url: `https://anilist.co/anime/${media.id}` })
      }
    }
    if (!w2g && buttons.length < 2) {
      if ($settings.rpcSecondButton === 'mal' && media?.idMal) {
        buttons.push({ label: 'View on MyAnimeList', url: `https://myanimelist.net/anime/${media.idMal}` })
      } else {
        buttons.push({ label: 'Download Tsumi', url: TSUMI_LINK })
      }
    }
    return buttons.slice(0, 2)
  }
</script>

<!-- ratio-16-9 only acts on the miniplayer (height: auto): Miniplayer.svelte sizes its frame for 16:9 videos. -->
<div
  class='player w-full h-full d-flex flex-column overflow-hidden position-relative'
  class:pl-sm-30={!isFullscreen && !miniplayer}
  class:pl-md-80={!isFullscreen && !miniplayer}
  class:ratio-16-9={miniplayer || !canPlay || externalPlayback}
  class:pointer={miniplayer}
  class:rounded-top-10={miniplayer}
  class:miniplayer
  class:pip
  class:immersed
  class:buffering={($page === page.PLAYER || miniplayer) && buffering}
  class:fitWidth
  bind:this={container}
  role='none'
  on:mousemove={resetImmerse}
  on:touchmove={resetImmerse}
  on:keypress={resetImmerse}
  on:keydown={resetImmerse}
  on:mouseleave={immersePlayer}
>
  <div class='w-full h-full position-relative overflow-hidden d-flex flex-column'>
    {#if showKeybinds && !miniplayer}
      <div
        class='position-absolute bg-tp w-full h-full z-50 font-size-12 p-20 d-flex align-items-center justify-content-center pointer'
        on:pointerup|self={() => (showKeybinds = false)}
        tabindex='-1'
        role='button'
      >
        <Keybinds let:prop={item} autosave={true} clickable={true}>
          {#if item?.type}
            <div
              class='bind icon'
              title={item?.desc}
              style='pointer-events: all !important;'
            >
              {#if item?.icon}
                <svelte:component this={item.icon} size='2rem' />
              {/if}
            </div>
          {:else}
            <div
              class='bind font-weight-normal'
              title={item?.desc}
              style='pointer-events: all !important;'
            >
              {item?.id || ''}
            </div>
          {/if}
        </Keybinds>
      </div>
    {/if}
    <video
      crossorigin='anonymous'
      class='position-absolute h-full w-full'
      style={`margin-top: ${menubarOffset}px`}
      preload='auto'
      bind:videoHeight
      bind:videoWidth
      bind:this={video}
      bind:duration
      bind:currentTime
      bind:paused
      bind:ended
      bind:muted
      bind:playbackRate
      on:error={checkError}
      on:error={() => finishW2GLoading()}
      on:pause={() => w2gMediaEvent('pause')}
      on:pause={() => holdSpeed.interrupt()}
      on:play={() => w2gMediaEvent('play')}
      on:seeking={() => w2gMediaEvent('seeking')}
      on:seeked={() => w2gMediaEvent('seeked')}
      on:timeupdate={() => createThumbnail()}
      on:timeupdate={checkCompletion}
      on:timeupdate={checkSkippableChapters}
      on:timeupdate={checkUpNext}
      on:timeupdate={trackPosition}
      on:timeupdate={w2gTimeupdate}
      on:progress={updateBuffer}
      on:seeked={updateBuffer}
      on:streamerror={showStreamError}
      on:waiting={showBuffering}
      on:loadeddata={hideBuffering}
      on:pause={() => {
        immersed = false
      }}
      on:canplay={hideBuffering}
      on:playing={hideBuffering}
      on:ended={tryPlayNext}
      on:loadedmetadata={handleLoadedMetadata}
      on:enterpictureinpicture={() => (pip = true)}
      on:leavepictureinpicture={() => {
        pip = false
      }}><track kind='captions' src="" srclang='en' label='English' /></video
    >
    <CastOverlay {miniplayer} />
    <OnlineSubtitles bind:open={onlineSubsOpen} {subs} media={current?.media?.media || media?.media} episode={current?.media?.episode ?? media?.episode} automatic={!subtitlesOff} />
    {#if stats && !miniplayer}
      <div
        class='position-absolute top-0 bg-tp p-10 ml-20 mt-100 text-monospace rounded z-50'
      >
        <button
          class='close btn btn-square mt-5'
          type='button'
          use:click={toggleStats}
        >
          <X size='1.4rem' strokeWidth='3' />
        </button>
        <div>FPS: {stats.fps}</div>
        <div>Presented frames: {stats.presented}</div>
        <div>Dropped frames: {stats.dropped}</div>
        <div>Frame time: {stats.processing}</div>
        <div>Viewport: {stats.viewport}</div>
        <div>Resolution: {stats.resolution}</div>
        <div>Buffer health: {stats.buffer}</div>
        <div>Playback speed: x{stats.speed?.toFixed(1)}</div>
        <div>Name: {current?.name || ''}</div>
        {#if playableFiles?.length > 1}
          <div class='mt-10'>All files in this batch:</div>
          <div class='overflow-auto ml-10 mt-5' style='max-height: 200px;'>
            {#each playableFiles as file}
              <div
                class='ctrl rounded-10 pl-5 pr-5 pbf'
                title={file.name}
                use:click={() => playFile(file)}
              >
                {file.name || 'UNK'}
              </div>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
    <ManagerModal playing={current} files={playableFiles} {playFile} />
    <div class='top z-40 row d-title'>
      <span
        class='player-exit-btn pl-30 mr-15 d-flex align-items-center'
        title='Exit'
        use:click={closePlayer}
      >
        <X size='3rem' strokeWidth='2.5' />
      </span>
      <div class='stats col-4 d-title'>
        <div class='font-weight-bold overflow-hidden text-truncate font-scale-23'>
          {#if $nowPlaying?.title && !String($nowPlaying.title).includes('undefined')}
            {$nowPlaying?.title}
          {:else if $nowPlaying?.media?.title}
            <!-- useful when metadata is loading slowly... -->
            {anilistClient.title($nowPlaying?.media)}
          {:else if current}
            {AnimeResolver.cleanFileName(current.name).replace(/undefined\s*-\s*/g, '').replace('undefined', '').trim()}
          {/if}
          {#if $nowPlaying?.episodeTitle && !String($nowPlaying.episodeTitle).includes('undefined')}
            <span class='ml-2 text-muted font-scale-16'>- {$nowPlaying.episodeTitle}</span>
          {/if}
        </div>
        <div class='font-weight-normal overflow-hidden text-truncate text-muted font-scale-16'>
          {#if (media?.episode === 0 || media?.episode) && media?.media?.episodes !== 1 && media?.media?.format !== 'MOVIE' && (!media?.episodeTitle || !new RegExp(`(?<![\\d.])${media.episode}(?![\\d.])`).test(media.episodeTitle))}
            {@const maxEpisodes = getMediaMaxEp(media.media) - (media.zeroEpisode ? 1 : 0)}
            Episode {media.episodeRange ? `${media.episodeRange.first} ~ ${media.episodeRange.last}` : media.episode}
            {#if maxEpisodes && (Number(maxEpisodes) > 1)} of {maxEpisodes}{:else if !maxEpisodes && videos && (videos.length > 1)} of {videos.length}{/if} <!-- for when the media fails to resolve, we can predict that the file length is likely the episode count. -->
          {:else if current && (videos?.length > 1)}
            Episode {videos.indexOf(current) + 1} of {videos.length} <!-- fallback for when the media fails to resolve and we also fail to resolve the episode numbers, best to indicate what file we are currently on. -->
          {/if}
          {#if (media?.episode === 0 || media?.episode) && media?.media?.format !== 'MOVIE' && (media?.episodeTitle && media?.episodeTitle !== 'undefined' && !new RegExp(`(?<![\\d.])${media.episode}(?![\\d.])`).test(media.episodeTitle))}{' - '}{/if}
          {#if media?.episodeTitle && media.episodeTitle !== 'undefined'}{media.episodeTitle}{/if}
        </div>
      </div>
      <div class='d-flex justify-content-center bottom-0 col-4 d-title d-filler'>
        {#if resolvePrompt}
          <div
            class='position-absolute text-monospace rounded skipPrompt d-flex flex-column align-items-center text-center bg-dark-light p-20 z-50 mt-60'
            class:w-500={SUPPORTS.isAndroid}
          >
            <div class='skipFont'>
              Failed to <b>identify</b> the media from the file name, would you like
              to fix it?
            </div>
            <div class='d-flex justify-content-center mt-20'>
              <button
                class='btn btn-primary mx-2 mr-20 d-flex align-items-center justify-content-center'
                type='button'
                use:click={() => resolveResponse(true)}
              >
                <span>Yes</span>
              </button>
              <button
                class='btn btn-secondary mx-2 ml-20 d-flex align-items-center justify-content-center'
                type='button'
                use:click={() => resolveResponse(false)}
              >
                <span>No</span>
              </button>
            </div>
          </div>
        {:else if skipPrompt}
          <div
            class='position-absolute text-monospace rounded skipPrompt d-flex flex-column align-items-center text-center bg-dark-light p-20 z-50 mt-60'
            class:w-500={SUPPORTS.isAndroid}
          >
            <div class='skipFont'>
              This episode has been marked as a <b>{filler || recap}</b>, do you
              want to skip?
            </div>
            <div class='d-flex justify-content-center mt-20'>
              <button
                class='btn btn-primary mx-2 mr-20 d-flex align-items-center justify-content-center'
                type='button'
                use:click={() => skipResponse(true)}
              >
                <span>Yes</span>
              </button>
              <button
                class='btn btn-secondary mx-2 ml-20 d-flex align-items-center justify-content-center'
                type='button'
                use:click={() => skipResponse(false)}
              >
                <span>No</span>
              </button>
            </div>
          </div>
        {/if}
      </div>
    </div>
    <div
      class='middle d-flex align-items-center justify-content-center flex-grow-1 position-relative'
    >
      <div
        aria-hidden='true'
        class='w-full h-full position-absolute toggle-fullscreen'
        on:dblclick={toggleFullscreen}
        on:pointerdown={holdPointerDown}
        on:pointerup={holdPointerUp}
        on:pointercancel={holdPointerUp}
        on:lostpointercapture={holdPointerUp}
        on:click|self={() => {
          if (Date.now() < holdClickIgnoredUntil) return
          if ($page === page.PLAYER && modal.length === 0) {
            playPause()
          } else {
            page.navigateTo(page.PLAYER)
          }
        }}
      ></div>
      <div
        aria-hidden='true'
        class='w-full h-full position-absolute toggle-immerse d-none'
        on:dblclick={toggleFullscreen}
        on:click|self={toggleImmerse}
      ></div>
      <div
        class='w-full h-full position-absolute mobile-focus-target d-none'
        use:click={() => {
          page.navigateTo(page.PLAYER)
        }}
      ></div>
      <span
        aria-hidden='true'
        class='icon ctrl align-items-center justify-content-end w-150 mw-full mr-auto'
        class:hidden={externalPlayback}
        class:mb-50={!miniplayer}
        on:click={rewind}><Rewind size='3rem' /></span
      >
      <!-- player minimize button (z-11 to sit above fullscreen/immerse overlays) -->
      {#if miniplayer}
        <span
          class='position-absolute rounded-10 top-0 right-0 m-10 btn-shadow button z-11 player-close-btn'
          title='Exit'
          use:click={closePlayer}
        >
          <X size='1.9rem' strokeWidth='3' />
        </span>
      {/if}
      <div
        class='d-flex align-items-center position-relative'
        class:mb-50={!miniplayer}
        style='width: 100%;'
        title='Play/Pause'
      >
        {#if hasLast}
          <span
            class='icon ctrl position-absolute rounded-10 text-white'
            style={externalPlayback ? 'left: 5%' : 'left: 15%'}
            title='Last'
            data-name='playPause'
            use:click={playLast}
          >
            <SkipBack size='3rem' fill='currentColor' />
          </span>
        {/if}
        <span
          class='icon ctrl position-absolute rounded-10 text-white'
          data-name='playPause'
          style='left: 50%; margin-left: -3rem;'
          use:click={playPause}
        >
          {#if ended}
            <RotateCw size='3rem' />
          {:else if paused}
            <Play size='3rem' fill='currentColor' />
          {:else}
            <Pause size='3rem' fill='currentColor' />
          {/if}
        </span>
        {#if hasNext}
          <span
            class='icon ctrl position-absolute rounded-10 text-white'
            style={externalPlayback ? 'right: 5%' : 'right: 15%'}
            title='Next'
            data-name='playPause'
            use:click={playNext}
          >
            <SkipForward size='3rem' fill='currentColor' />
          </span>
        {/if}
      </div>
      <span
        aria-hidden='true'
        class='icon ctrl align-items-center w-150 mw-full ml-auto'
        class:hidden={externalPlayback}
        class:mb-50={!miniplayer}
        on:click={forward}><FastForward size='3rem' /></span
      >
      <div
        class='position-absolute bufferingDisplay'
        class:bufferingPos={SUPPORTS.isAndroid && !miniplayer}
      ></div>
      {#if holdSpeedShown && !miniplayer}
        <div class='hold-speed position-absolute d-flex align-items-center font-weight-bold font-scale-20 text-white'>
          {holdSpeedLabel(holdSpeedShown)}<FastForward size='1.6rem' fill='currentColor' class='ml-5' />
        </div>
      {/if}
      {#if externalPlayback && !miniplayer}
        <div class='external-card position-absolute d-flex flex-column align-items-center text-center rounded p-20 z-30'>
          <SquareArrowOutUpRight size='3rem' strokeWidth={2} />
          <div class='font-weight-bold font-size-18 mt-10'>{externalSession ? 'Playing in your external player' : 'Opening your external player…'}</div>
          {#if externalSession}
            <div class='text-muted font-size-14 mt-5'>The episode comes back here when you close it.</div>
            <button class='btn btn-secondary mt-15' type='button' use:click={playInTsumi}>Play in Tsumi instead</button>
          {/if}
        </div>
      {/if}
      {#if resumeOffer && !miniplayer && !externalPlayback}
        <div class='resume-offer position-absolute bottom-0 left-0 ml-20 mb-5 z-30 d-flex align-items-center rounded p-10'>
          <span class='font-weight-bold mr-15 text-nowrap'>Resumed at {resumeOffer.label}</span>
          <button class='btn font-weight-bold' type='button' use:click={() => answerResumeOffer(true)}>Start over</button>
          <button class='btn btn-primary ml-10 font-weight-bold' type='button' use:click={() => answerResumeOffer(false)}>Resume</button>
        </div>
      {/if}
      {#if upNext && !miniplayer}
        <div class='up-next position-absolute bottom-0 right-0 mr-20 mb-5 z-30 d-flex align-items-center rounded p-10'>
          <div class='d-flex flex-column mr-15 overflow-hidden'>
            <span class='font-size-12 text-muted font-weight-bold text-uppercase text-nowrap'>Up next in {upNext.remaining} s</span>
            <span class='font-weight-bold text-truncate'>{upNext.label}</span>
          </div>
          <button class='btn btn-primary d-flex align-items-center font-weight-bold' type='button' use:click={playUpNext}>
            <SkipForward size='1.6rem' fill='currentColor' /><span class='ml-5'>Play now</span>
          </button>
          <button class='btn ml-5 font-weight-bold' type='button' use:click={dismissUpNext}>Cancel</button>
        </div>
      {:else if currentSkippable}
        <button
          class='skip btn text-dark position-absolute bottom-0 right-0 mr-20 mb-5 font-weight-bold z-30 d-flex align-items-center justify-content-center'
          use:click={skip}
        >
          <FastForward size='1.8rem' fill='currentColor' /><span class='ml-5'
          >Skip {currentSkippable}</span
          >
        </button>
      {/if}
    </div>
    <div class='bottom d-flex z-40 flex-column px-20'>
      <div
        class='w-full d-flex align-items-center h-20 mb-5 seekbar'
        tabindex='-1'
        role='button'
        on:keydown={handleSeekbarKey}
      >
        <Seekbar
          accentColor={completed || (media?.media && ((($mediaCache[media.media.id] || media.media)?.mediaListEntry?.progress - (media?.zeroEpisode ? 1 : 0)) >= (media.episodeRange ? media.episodeRange.last : media.episode))) ? 'var(--completed-color-dim)' : 'var(--accent-color)'}
          class='font-size-20'
          length={safeduration}
          {buffer}
          bind:progress
          on:seeking={handleMouseDown}
          on:seeked={handleMouseUp}
          chapters={sanitiseChapters(chapters, safeduration)}
          {getThumbnail}
        />
      </div>
      <div class='d-flex'>
        <span
          class='icon ctrl m-5 text-white'
          title='Play/Pause [Space]'
          data-name='playPause'
          use:click={playPause}
        >
          {#if ended}
            <RotateCw size='2rem' />
          {:else if paused}
            <Play size='2rem' fill='currentColor' />
          {:else}
            <Pause size='2rem' fill='currentColor' />
          {/if}
        </span>
        {#if hasLast}
          <span
            class='icon ctrl m-5 d-btn text-white'
            title='Last [B]'
            use:click={playLast}
          >
            <SkipBack size='2rem' fill='currentColor' />
          </span>
        {/if}
        {#if hasNext}
          <span
            class='icon ctrl m-5 d-btn text-white'
            title='Next [N]'
            use:click={playNext}
          >
            <SkipForward size='2rem' fill='currentColor' />
          </span>
        {/if}
        <div class='d-none w-auto volume' class:d-flex={!externalPlayback}>
          <span
            class='icon ctrl m-5 text-white'
            title='Mute [M]'
            data-name='toggleMute'
            use:click={toggleMute}
          >
            {#if muted}
              <VolumeX size='2rem' fill='currentColor' />
            {:else}
              <Volume2 size='2rem' fill='currentColor' />
            {/if}
          </span>
          {#if !volumeBoosted}
            <input
              class='ctrl h-full custom-range'
              tabindex='-1'
              type='range'
              min='0'
              max='1'
              step='any'
              data-name='setVolume'
              bind:value={volume}
            />
          {:else}
            <input
              class='ctrl h-full custom-range'
              class:boost-color={gain > 1}
              tabindex='-1'
              type='range'
              min='0'
              max='3'
              step='any'
              data-name='setVolume'
              bind:value={gain}
              on:input={setGain}
            />
          {/if}
          {#if volume === 1 || volumeBoosted}
            <span
              class='icon ctrl boost p-0 mt-15 d-flex align-items-center justify-content-center text-white'
              class:boost-color={volumeBoosted}
              title='Increase Volume Limit [V]'
              data-name='toggleGain'
              use:click={toggleGain}
            >
              <SlidersVertical size='1.4rem' fill='currentColor' />
            </span>
          {/if}
        </div>
        <div class='ts font-scale-20' class:mr-auto={playbackRate === 1}>
          {toTS(targetTime, safeduration > 3600 ? 2 : 3)} / {toTS(
            safeduration - targetTime,
            safeduration > 3600 ? 2 : 3
          )}
        </div>
        {#if playbackRate !== 1}
          <div class='ts mr-auto font-scale-20'>x{playbackRate.toFixed(1)}</div>
        {/if}
        <input
          type='file'
          class='d-none'
          id='search-subtitle'
          accept='.srt,.vtt,.ass,.ssa,.sub,.txt'
          on:input|preventDefault|stopPropagation={handleFile}
          bind:this={fileInput}
        />
        {#if streamServers.length > 1}
          <div class='dropdown dropup with-arrow' use:click={toggleDropdown}>
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Servers'
            >
              <Server size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-0 mr-15 text-capitalize text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                {#each streamServers as server, i}
                  <input
                    name='server-radio-set'
                    type='radio'
                    id='server-{i}-radio'
                    value={i}
                    checked={i === activeServerIndex}
                  />
                  <label
                    for='server-{i}-radio'
                    use:click={() => switchServer(i)}
                    class='pb-5'
                  >
                    {server.title || `Server ${i + 1}`}
                  </label>
                {/each}
                <div class='mb-5 invisible'></div>
              </div>
            </div>
          </div>
        {/if}
        {#if hlsLevels.length > 1 && !externalPlayback}
          <div class='dropdown dropup with-arrow' use:click={toggleDropdown}>
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Quality'
            >
              <Gauge size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-0 mr-15 text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                <input
                  name='quality-radio-set'
                  type='radio'
                  id='quality-auto-radio'
                  value={-1}
                  checked={hlsLevel === -1}
                />
                <label
                  for='quality-auto-radio'
                  use:click={() => selectQuality(-1)}
                  class='pb-5'
                >
                  Auto{hlsLevel === -1 && hlsActiveLabel ? ` (${hlsActiveLabel})` : ''}
                </label>
                {#each hlsLevels as level (level.index)}
                  <input
                    name='quality-radio-set'
                    type='radio'
                    id='quality-{level.index}-radio'
                    value={level.index}
                    checked={hlsLevel === level.index}
                  />
                  <label
                    for='quality-{level.index}-radio'
                    use:click={() => selectQuality(level.index)}
                    class='pb-5'
                  >
                    {level.label}
                  </label>
                {/each}
                <div class='mb-5 invisible'></div>
              </div>
            </div>
          </div>
        {/if}
        <div
          class='dropdown dropleft with-arrow'
          use:click={() => {
            if (!$showOptions) closePlayerMenus()
            showOptions.set(!$showOptions)
          }}
        >
          <span
            class='icon text-white ctrl d-flex align-items-center h-full'
            title='More'
          ><EllipsisVertical size='2.5rem' strokeWidth={2.5} /></span
          >
          <div
            class='position-absolute hm-40 text-capitalize text-nowrap bg-dark rounded dr-arrow'
            style='margin-top: {(canDownload ? -3.5 : 0) + (externalPlayback ? -10.3 : externalAvailable ? -21 : -17.5)}rem !important; margin-left: {externalPlayback ? -9.8 : -11.4}rem !important; transition: opacity 0.1s ease-in;'
            class:hidden={!$showOptions}
          >
            <div
              role='button'
              aria-label='Add External Subtitles'
              class='pointer d-none align-items-center justify-content-center font-size-16 bd-highlight py-5 px-10 rounded-top option'
              class:d-flex={!externalPlayback}
              title='Add External Subtitles'
              use:click={() => {
                fileInput.click()
                showOptions.set(false)
              }}
            >
              <FilePlus2 size='2rem' strokeWidth={2.5} />
              <div class='ml-10'>Add Subtitles</div>
            </div>
            <div
              role='button'
              aria-label='Play the Current Video in an External Player'
              class='pointer d-none align-items-center justify-content-center font-size-16 bd-highlight py-5 px-10 option'
              class:d-flex={!externalPlayback && externalAvailable}
              title='Play the Current Video in an External Player'
              use:click={() => {
                showOptions.set(false)
                openInExternalPlayer()
              }}
            >
              <SquareArrowOutUpRight size='2rem' strokeWidth={2.5} />
              <div class='ml-10'>External Player</div>
            </div>
            {#if canDownload}
              <div
                role='button'
                aria-label='Download This Episode'
                class='pointer d-flex align-items-center justify-content-center font-size-16 bd-highlight py-5 px-10 option'
                title='Download this episode to watch it offline'
                use:click={() => {
                  downloadFromPlayer(current, streamServers[activeServerIndex])
                  showOptions.set(false)
                }}
              >
                <ArrowDownToLine size='2rem' strokeWidth={2.5} />
                <div class='ml-10'>Download Episode</div>
              </div>
            {/if}
            <div
              role='button'
              aria-label='Modify Existing Files or Change to a New File'
              class='pointer d-flex align-items-center justify-content-center font-size-16 bd-highlight py-5 px-10 rounded-bottom option'
              class:rounded-top={externalPlayback}
              title='Modify Existing Files or Change to a New File'
              use:click={() => {
                resolvePrompt = false
                modal.toggle(modal.FILE_MANAGER)
                showOptions.set(false)
              }}
            >
              <SquarePen size='2rem' strokeWidth={2.5} />
              <div class='ml-10'>File Manager</div>
            </div>
          </div>
        </div>
        <span
          class='icon text-white ctrl mr-5 d-flex align-items-center keybinds'
          title='Keybinds [`]'
          use:click={() => (showKeybinds = true)}
        >
          <Keyboard size='2.5rem' strokeWidth={2.5} />
        </span>
        {#if $playPage && media?.media}
          <span
            class='icon text-white ctrl mr-5 d-flex align-items-center'
            title='Now Playing [O]'
            use:click={() => modal.toggle(modal.ANIME_DETAILS, media.media)}
          >
            <Eye size='2.5rem' strokeWidth={2.5} />
          </span>
        {/if}
        {#if hlsAudio.length > 1 && !externalPlayback}
          <div class='dropdown dropup with-arrow' use:click={toggleDropdown}>
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Audio Tracks'
            >
              <ListMusic size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-0 mr-15 text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                {#each hlsAudio as track (track.index)}
                  <input
                    name='hls-audio-radio-set'
                    type='radio'
                    id='hls-audio-{track.index}-radio'
                    value={track.index}
                    checked={hlsAudioTrack === track.index}
                  />
                  <label
                    for='hls-audio-{track.index}-radio'
                    use:click={() => selectHlsAudio(track.index)}
                    class='pb-5'
                  >
                    {track.label}
                  </label>
                {/each}
                <div class='mb-5 invisible'></div>
              </div>
            </div>
          </div>
        {:else if 'audioTracks' in HTMLVideoElement.prototype && video?.audioTracks?.length > 1}
          <div class='dropdown dropup with-arrow' use:click={toggleDropdown}>
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Audio Tracks'
            >
              <ListMusic size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-0 mr-15 text-capitalize text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                {#each video.audioTracks as track}
                  <input
                    name='audio-radio-set'
                    type='radio'
                    id='audio-{track.id}-radio'
                    value={track.id}
                    checked={track.enabled}
                  />
                  <label
                    for='audio-{track.id}-radio'
                    use:click={() => {
                      selectAudio(track.id)
                      rememberAudio({ name: track.label, lang: track.language })
                    }}
                    class='pb-5'
                  >
                    {(track.language ||
                      (!Object.values(video.audioTracks).some(
                        (track) =>
                          track.language === 'eng' || track.language === 'en'
                      )
                        ? 'eng'
                        : track.label)) +
                      (track.label ? ' - ' + track.label : '')}
                  </label>
                {/each}
                <div class='mb-5 invisible'></div>
              </div>
            </div>
          </div>
        {/if}
        {#if 'videoTracks' in HTMLVideoElement.prototype && video?.videoTracks?.length > 1}
          <div class='dropdown dropup with-arrow' use:click={toggleDropdown}>
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Video Tracks'
            >
              <ListVideo size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-0 mr-15 text-capitalize text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                {#each video.videoTracks as track}
                  <input
                    name='video-radio-set'
                    type='radio'
                    id='video-{track.id}-radio'
                    value={track.id}
                    checked={track.selected}
                  />
                  <label
                    for='video-{track.id}-radio'
                    use:click={() => selectVideo(track.id)}
                    class='pb-5'
                  >
                    {(track.language ||
                      (!Object.values(video.videoTracks).some(
                        (track) =>
                          track.language === 'eng' || track.language === 'en'
                      )
                        ? 'eng'
                        : track.label)) +
                      (track.label ? ' - ' + track.label : '')}
                  </label>
                {/each}
                <div class='mb-5 invisible'></div>
              </div>
            </div>
          </div>
        {/if}
        {#if (subHeaders?.length || current) && !externalPlayback}
          <div
            class='subtitles dropdown dropup with-arrow'
            use:click={toggleDropdown}
          >
            <span
              class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
              title='Subtitles [C]'
            >
              <Captions size='2.5rem' strokeWidth={2.5} />
            </span>
            <div
              class='dropdown-menu dropdown-menu-right ctrl p-10 pb-5 mr-15 text-capitalize text-nowrap'
            >
              <div class='custom-radio overflow-y-auto overflow-x-hidden hm-400'>
                <input
                  name='subtitle-radio-set'
                  type='radio'
                  id='subtitle-off-radio'
                  value='off'
                  checked={subHeaders && subs?.current === -1}
                />
                <label
                  for='subtitle-off-radio'
                  use:click={() => {
                    subtitlePreferenceDone = true
                    subs?.selectCaptions(-1)
                    setTimeout(() => subs?.renderer?.resize(), 200)
                    rememberSubtitle('OFF')
                  }}
                  class='pb-5'
                >
                  OFF
                </label>
                <!-- stupid fix (resize) because video metadata doesn't update for multiple frames -->
                {#each subHeaders || [] as track}
                  {#if track}
                    {@const trackName = trackLabel(track)}
                    <input
                      name='subtitle-radio-set'
                      type='radio'
                      id='subtitle-{track.number}-radio'
                      value={track.number}
                      checked={track.number === subs.current}
                    />
                    <label
                      for='subtitle-{track.number}-radio'
                      use:click={() => {
                        subtitlePreferenceDone = true
                        subs?.selectCaptions(track.number)
                        setTimeout(() => subs?.renderer?.resize(), 200)
                        rememberSubtitle(trackName)
                      }}
                      class='pb-5'
                    >
                      <!-- stupid fix (resize) because video metadata doesn't update for multiple frames -->
                      {trackName}
                    </label>
                  {/if}
                {/each}
                <div
                  class='pb-5 pointer text-nowrap online-subs-entry'
                  title='Search online subtitles'
                  use:click={({ target }) => {
                    onlineSubsOpen = true
                    target.closest('.dropdown')?.classList.remove('show')
                  }}
                >
                  <Globe size='1.6rem' class='mr-5' />Search online subtitles…
                </div>
                <div class='mb-5 invisible'></div>
                <div class='subtitle-offset'>
                  <div
                    role='button'
                    aria-label='Add External Subtitles'
                    class='position-absolute not-reactive'
                    title='Add External Subtitles'
                    style='margin-left: 0.1rem !important; margin-top: 0.3rem !important'
                    use:click={(target) => {
                      fileInput.click()
                      toggleDropdown(target)
                    }}
                  >
                    <FilePlus2 size='2rem' strokeWidth={2.5} />
                  </div>
                  <!-- Offset in seconds, "1,5" or "1.5"; typing here never reaches the player shortcuts. -->
                  <input
                    type='text'
                    inputmode='decimal'
                    title='Subtitle Offset (seconds, remembered for this show)'
                    value={subDelayText}
                    on:input={({ currentTarget }) => typeSubDelay(currentTarget.value)}
                    on:change={() => (subDelayText = String(subDelay))}
                    on:click|stopPropagation
                    on:keydown|stopPropagation
                    class='form-control text-right form-control-sm not-reactive'
                  />
                </div>
                <div class='d-flex justify-content-between mt-5'>
                  <button type='button' class='btn btn-sm not-reactive' title='Show subtitles 0.5 s later' on:click|stopPropagation={() => stepDelay(-0.5)}>-0.5 s</button>
                  <button type='button' class='btn btn-sm not-reactive' title='Show subtitles 0.5 s earlier' on:click|stopPropagation={() => stepDelay(0.5)}>+0.5 s</button>
                </div>
              </div>
            </div>
          </div>
        {/if}
        <!-- {#if 'PresentationRequest' in window && canCast && current} -->
        <!--  <span class='icon text-white ctrl mr-5 d-flex align-items-center text-white' title='Cast Video [D]' data-name='toggleCast' use:click={toggleCast}> -->
        <!--    {#if presentationConnection} -->
        <!--      <Cast size='2.5rem' fill='currentColor' strokeWidth={0} /> -->
        <!--    {:else} -->
        <!--      <Cast size='2.5rem' strokeWidth={2.5} /> -->
        <!--    {/if} -->
        <!--  </span> -->
        <!-- {/if} -->
        <CastButton {video} {current} {media} {streamServers} {activeServerIndex} {subs} {subHeaders} delay={subDelay} disabled={externalPlayback} />
        {#if 'pictureInPictureEnabled' in document}
          <span
            class='icon text-white ctrl mr-5 d-none align-items-center'
            class:d-flex={!externalPlayback}
            title='Popout Window [P]'
            data-name='togglePopout'
            use:click={togglePopout}
          >
            {#if pip}
              <PictureInPicture size='2.5rem' strokeWidth={2.5} />
            {:else}
              <PictureInPicture2 size='2.5rem' strokeWidth={2.5} />
            {/if}
          </span>
        {/if}
        <span
          class='icon text-white ctrl mr-5 d-none align-items-center'
          class:d-flex={!externalPlayback}
          title='Fullscreen [F]'
          data-name='toggleFullscreen'
          use:click={toggleFullscreen}
        >
          {#if isFullscreen}
            <Minimize size='2.5rem' strokeWidth={2.5} />
          {:else}
            <Maximize size='2.5rem' strokeWidth={2.5} />
          {/if}
        </span>
      </div>
    </div>
    {#if $state && !miniplayer}
      <PlayerW2G client={$state} {immersed} />
    {/if}
  </div>
</div>

<style>
  :global(.deband-canvas) {
    max-width: 100%;
    max-height: 100%;
    width: 100% !important;
    height: 100% !important;
    top: 50%;
    left: 50%;
    position: absolute;
    transform: translate(-50%, -50%);
    pointer-events: none;
    object-fit: contain;
  }
  :global(.deband-canvas) ~ video {
    opacity: 0;
  }
  .fitWidth video,
  .fitWidth :global(.deband-canvas) {
    object-fit: cover !important;
  }
  .custom-range {
    color: var(--accent-color);
    --thumb-height: 0px;
    --track-height: 3px;
    --track-color: hsla(var(--white-color-hsl), 0.2);
    --brightness-hover: 120%;
    --brightness-down: 80%;
    --clip-edges: 2px;
    --target-height: max(var(--track-height), var(--thumb-height));
    position: relative;
    background: hsla(var(--white-color-hsl), 0);
    overflow: hidden;
    transition: all ease 100ms;
    appearance: none;
  }
  .custom-range:hover {
    --thumb-height: 12px;
  }

  .custom-range:active {
    cursor: grabbing;
  }
  .custom-range::-webkit-slider-runnable-track {
    height: var(--target-height);
    position: relative;
    background: linear-gradient(var(--track-color) 0 0) scroll no-repeat center /
      100% calc(var(--track-height));
  }

  .custom-range::-webkit-slider-thumb {
    position: relative;
    height: var(--thumb-height);
    width: var(--thumb-width, var(--thumb-height));
    -webkit-appearance: none;
    --thumb-radius: calc((var(--target-height) * 0.5) - 1px);
    --clip-top: calc((var(--target-height) - var(--track-height)) * 0.5);
    --clip-bottom: calc(var(--target-height) - var(--clip-top));
    --clip-further: calc(100% + 1px);
    --box-fill: calc(-100vmax - var(--thumb-width, var(--thumb-height))) 0 0
      100vmax currentColor;

    background: linear-gradient(currentColor 0 0) scroll no-repeat left center /
      50% calc(var(--track-height) + 1px);
    background-color: currentColor;
    box-shadow: var(--box-fill);
    border-radius: var(--thumb-width, var(--thumb-height));

    filter: brightness(100%);
    clip-path: polygon(
      100% -1px,
      var(--clip-edges) -1px,
      0 var(--clip-top),
      -100vmax var(--clip-top),
      -100vmax var(--clip-bottom),
      0 var(--clip-bottom),
      var(--clip-edges) 100%,
      var(--clip-further) var(--clip-further)
    );
  }

  .custom-range:hover::-webkit-slider-thumb {
    filter: brightness(var(--brightness-hover));
    cursor: grab;
  }

  .custom-range:active::-webkit-slider-thumb {
    filter: brightness(var(--brightness-down));
    cursor: grabbing;
  }

  .custom-range:focus {
    outline: none;
  }

  .bind {
    font-size: 1.8rem;
    font-weight: bold;
    display: flex;
    justify-content: center;
    align-items: center;
    height: 100%;
  }
  .stats {
    font-size: 2.3rem;
    padding-top: 1.5rem;
    white-space: nowrap;
    font-weight: 600;
  }
  .skipPrompt {
    margin-top: 10rem;
  }
  .skipFont {
    font-size: 1.8rem !important;
  }
  .miniplayer {
    height: auto !important;
    cursor: pointer !important;
  }
  .miniplayer .top,
  .miniplayer .bottom,
  .miniplayer .skip {
    display: none !important;
  }
  .miniplayer video {
    position: relative !important;
  }
  .bg-tp {
    background: hsla(var(--black-color-hsl), 0.73);
    backdrop-filter: blur(10px);
  }
  .bg-tp .close {
    position: absolute;
    top: 0;
    right: 0;
    cursor: pointer;
    color: inherit;
    padding: var(--alert-close-padding);
    line-height: var(--alert-close-line-height);
    font-size: var(--alert-close-font-size);
    background-color: transparent;
    border-color: transparent;
  }

  video {
    transition: margin-top 0.2s ease;
  }
  .player {
    user-select: none;
    background: var(--black-color);
  }

  .pip :global(canvas:not(.w-full)) {
    width: 1px !important;
    height: 1px !important;
  }

  .icon {
    font-size: 2.8rem;
    padding: 1.5rem;
    display: flex;
  }

  .immersed {
    cursor: none;
  }

  .immersed .middle .ctrl,
  .immersed .top,
  .immersed .bottom,
  .immersed .skip {
    pointer-events: none;
    opacity: 0;
  }
  .immersed .player-close-btn {
    pointer-events: none;
    opacity: 0;
  }

  .player-exit-btn {
    cursor: pointer;
    filter: drop-shadow(0 0 8px var(--black-color));
    z-index: 11;
    flex-shrink: 0;
  }
  .miniplayer .player-exit-btn {
    display: none;
  }

  .player-close-btn {
    display: flex !important;
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.2s ease;
    z-index: 11;
  }
  .miniplayer:hover .player-close-btn {
    opacity: 1;
  }
  @media (pointer: none), (pointer: coarse) {
    .player-close-btn {
      opacity: 1;
    }
  }
  /*:fullscreen .ctrl[data-name='toggleCast'] {*/
  /*  display: none !important;*/
  /*}*/

  .pip video {
    opacity: 0.1%;
  }

  .middle .bufferingDisplay {
    border: 4px solid hsla(var(--white-color-hsl), 0);
    border-top: 4px solid var(--white-color);
    border-radius: 50%;
    width: 40px;
    height: 40px;
    animation: spin 1s linear infinite;
    will-change: transform;
    opacity: 0;
    visibility: hidden;
    transition: 0.2s opacity ease 0s;
    filter: drop-shadow(0 0 8px var(--black-color));
  }

  .middle .bufferingPos {
    margin-bottom: 5rem;
  }

  .buffering .middle .bufferingDisplay {
    opacity: 1 !important;
    visibility: visible !important;
  }
  .pip .bufferingDisplay {
    display: none;
  }

  @keyframes spin {
    0% {
      transform: rotate(0deg);
    }

    100% {
      transform: rotate(360deg);
    }
  }

  .middle .ctrl {
    font-size: 4rem;
    z-index: 3;
    display: none;
  }
  :fullscreen {
    background: var(--black-color) !important;
  }

  @media (pointer: none), (pointer: coarse) {
    .middle .ctrl {
      display: flex;
    }
  }
  .miniplayer .middle {
    transition: background 0.2s ease;
    position: absolute !important;
    width: 100%;
    height: 100%;
  }
  .miniplayer .middle .ctrl[data-name="playPause"] {
    display: flex;
    font-size: 2.8rem;
  }
  .miniplayer .middle .ctrl[data-name="playPause"] {
    font-size: 5.625rem;
  }
  .miniplayer:hover .middle {
    background: hsla(var(--black-color-hsl), 0.4);
  }
  .middle .ctrl[data-name="playPause"] {
    font-size: 6.75rem;
  }

  .middle .ctrl,
  .bottom .ctrl:hover,
  .bottom .ts:hover,
  .bottom .hover .ts {
    filter: drop-shadow(0 0 8px var(--black-color));
  }
  .skip {
    transition: 0.2s opacity ease 0s;
    background: hsla(var(--white-color-hsl), 0.92);
  }
  .skip:hover {
    background-color: var(--lm-button-bg-color-hover);
  }

  .bottom {
    background: linear-gradient(
      to top,
      hsla(var(--black-color-hsl), 0.8),
      hsla(var(--black-color-hsl), 0.6) 25%,
      hsla(var(--black-color-hsl), 0.4) 50%,
      hsla(var(--black-color-hsl), 0.1) 75%,
      transparent
    );
    transition: 0.2s opacity ease 0s;
  }
  .top {
    background: linear-gradient(
      to bottom,
      hsla(var(--black-color-hsl), 0.8),
      hsla(var(--black-color-hsl), 0.4) 25%,
      hsla(var(--black-color-hsl), 0.2) 50%,
      hsla(var(--black-color-hsl), 0.1) 75%,
      transparent
    );
    transition: 0.2s opacity ease 0s;
  }
  .mr-50 {
    margin-right: 5rem !important;
  }
  .mb-50 {
    margin-bottom: 5rem !important;
  }
  .pbf:hover {
    background: var(--tertiary-color);
  }

  .ctrl {
    cursor: pointer;
  }

  .boost-color {
    color: var(--octonary-color) !important;
  }

  .bottom .volume:hover .boost,
  .bottom .volume:focus-within .boost {
    width: 3rem;
    height: 3rem;
  }

  .bottom .volume .boost {
    width: 0;
    height: 0;
    transition:
      width 0.1s ease,
      height 0.1s ease;
  }

  .bottom .volume:hover .custom-range,
  .bottom .volume:focus-within .custom-range {
    width: 5vw;
    display: inline-block;
    margin-right: 1.125rem;
  }

  .bottom .volume .custom-range {
    width: 0;
    transition: width 0.1s ease;
    height: 100%;
  }

  .mt-100 {
    margin-top: 10rem !important;
  }
  .h-20 {
    height: 2rem;
  }
  .rounded-10 {
    border-radius: 1rem;
  }

  .btn-shadow {
    filter: drop-shadow(0rem 0rem 0.5rem hsla(var(--black-color-hsl), 0.9));
  }

  .bottom .ts {
    color: hsla(var(--white-color-hsl), 0.92);
    white-space: nowrap;
    align-self: center;
    line-height: var(--base-line-height);
    padding: 0 1.56rem;
    font-weight: 600;
  }

  .seekbar {
    font-size: 2rem !important;
  }
  .miniplayer .mobile-focus-target {
    display: block !important;
  }
  .miniplayer .mobile-focus-target:focus-visible {
    background: hsla(209, 100%, 55%, 0.3);
  }

  @media (max-width: 30rem) {
    .d-btn {
      display: none !important;
    }
  }

  @media (max-width: 60rem) {
    .d-title {
      display: block !important;
      max-width: none !important;
      grid-row: unset !important;
      grid-column: unset !important;
    }
    .d-filler {
      display: flex !important;
    }
    .mt-60 {
      margin-top: 6rem !important;
    }
  }

  @media (pointer: none), (pointer: coarse) {
    .bottom .ctrl[data-name="playPause"],
    .bottom .volume,
    .bottom .keybinds {
      display: none !important;
    }
    @media (orientation: portrait) {
      .top {
        padding-top: max(
          var(--safe-area-top),
          env(safe-area-inset-top, 0)
        ) !important;
      }
    }
    .middle .ctrl {
      display: flex !important;
    }
    .miniplayer .middle .ctrl {
      display: none !important;
    }
    .toggle-immerse {
      display: block !important;
    }
    .toggle-fullscreen {
      display: none !important;
    }
  }

  /* "2× ▶▶" while the video is held (hold to speed up) */
  .hold-speed {
    top: 1rem;
    left: 50%;
    transform: translateX(-50%);
    z-index: 30;
    padding: 0.4rem 1.2rem;
    border-radius: 2rem;
    background: hsla(var(--black-color-hsl), 0.6);
    pointer-events: none;
    white-space: nowrap;
  }

  /* "Up next" card, "Resume from / Start over" and the external player card: stay visible when immersed */
  .up-next,
  .resume-offer,
  .external-card {
    background: hsla(var(--black-color-hsl), 0.8);
    backdrop-filter: blur(10px);
  }
  .up-next {
    max-width: min(45rem, calc(100% - 4rem));
  }
  .external-card {
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    max-width: 40rem;
  }
</style>
