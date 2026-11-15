import { toast } from 'svelte-sonner'
import { settings } from '@/modules/settings.js'
import { IPC } from '@/modules/bridge.js'
import { isValidNumber } from '@/modules/util.js'
import { getAnimeProgress } from '@/modules/anime/animeprogress.js'
import { formatClock, shouldOffer, needsWrite, PERIODIC_WRITE_MS, PAUSE_WRITE_DELAY_MS } from '@/modules/sync/position.js'
import { DEVICE_NAME, noteService, fetchNotePosition, saveNotePosition } from '@/modules/sync/remote.js'
import { traktConnected, traktTarget, getTraktPlayback, matchesTarget, scrobble } from '@/modules/sync/trakt.js'
import Debug from 'debug'
const debug = Debug('ui:sync')

/*
 * Playback side of the sync: follows the <video> of PlayerPage.svelte and
 * - writes the position in the note of the list entry (on pause, when leaving the player or the app, every 2 minutes
 *   while playing; removed once the episode reaches the auto-complete threshold),
 * - scrobbles to Trakt (start / pause / stop),
 * - offers "Resume at 12:34 (from iPhone)" when another device played this episode more recently.
 * PlayerPage only calls `playbackSync.attach(video, current?.media)`.
 */

const TRAKT_START_DELAY_MS = 1_500
const TRAKT_PAUSE_DELAY_MS = 2_000
const QUIT_TIMEOUT_MS = 2_500

/**
 * @typedef {object} SyncItem
 * @property {any} media
 * @property {number} episode
 * @property {string} key
 * @property {any} local local progress record when the episode was opened
 * @property {number} time last known position (s)
 * @property {number} duration (s)
 * @property {boolean} playing
 * @property {boolean} finished auto-complete threshold reached (note line removed, no more writes)
 * @property {{ episode: number, time: number } | null} written
 * @property {number} writtenAt
 * @property {any} pauseTimer
 * @property {Promise<any> | null} trakt target, null when not scrobbled
 * @property {'idle' | 'start' | 'pause' | 'stop'} traktState
 * @property {any} traktTimer
 * @property {(() => void) | null} metadataReady
 * @property {Promise<void>} metadata
 * @property {{ time?: number, percent?: number } | null} resume asked from the details ("Resume at ...")
 */

/** @type {{ mediaId: any, episode: number, time?: number, percent?: number } | null} */
let pendingResume = null

/**
 * The details asked to resume an episode at a position: applied when that episode is opened in the player.
 * @param {{ mediaId: any, episode: number, time?: number, percent?: number }} resume
 */
export function requestResume (resume) {
  pendingResume = { ...resume, at: Date.now() }
}

class PlaybackSync {
  /** @type {HTMLVideoElement | null} */
  video = null
  /** @type {SyncItem | null} */
  item = null

  constructor () {
    this.onTimeUpdate = this.onTimeUpdate.bind(this)
    this.onPlay = this.onPlay.bind(this)
    this.onPause = this.onPause.bind(this)
    this.onSeeked = this.onSeeked.bind(this)
    this.onEnded = this.onEnded.bind(this)
    this.onMetadata = this.onMetadata.bind(this)
    document.addEventListener('visibilitychange', () => {
      // The app goes to the background (minimized / hidden to the tray).
      if (document.hidden && this.item) this.writeNote(this.item)
    })
    if (typeof IPC?.on === 'function') {
      // Sent by the main process before the app quits (electron/src/main/trakt.js beforeQuit).
      IPC.on('app-before-quit', () => {
        const done = () => IPC.emit('app-before-quit:done')
        Promise.race([this.leave(), new Promise(resolve => setTimeout(resolve, QUIT_TIMEOUT_MS))]).then(done, done)
      })
    }
  }

  /**
   * Called by PlayerPage whenever the video element or the playing file changes.
   * @param {HTMLVideoElement | null} video
   * @param {any} fileMedia `current.media` of PlayerPage: { media, episode, failed, ... }
   */
  attach (video, fileMedia) {
    if (video !== this.video) {
      this.listen(this.video, false)
      this.video = video || null
      this.listen(this.video, true)
    }
    const media = fileMedia?.media
    const episode = Number(fileMedia?.episode)
    const valid = media?.id != null && !fileMedia?.failed && isValidNumber(fileMedia?.episode)
    const key = valid ? `${media.id}:${episode}` : null
    if (key === (this.item?.key ?? null)) {
      if (this.item && media) this.item.media = media
      return
    }
    this.leave()
    if (key) this.begin(media, episode, key)
  }

  /**
   * @param {HTMLVideoElement | null} video
   * @param {boolean} add
   */
  listen (video, add) {
    if (!video) return
    const method = add ? 'addEventListener' : 'removeEventListener'
    video[method]('timeupdate', this.onTimeUpdate)
    video[method]('play', this.onPlay)
    video[method]('pause', this.onPause)
    video[method]('seeked', this.onSeeked)
    video[method]('ended', this.onEnded)
    video[method]('loadedmetadata', this.onMetadata)
    video[method]('durationchange', this.onMetadata)
  }

  /**
   * @param {any} media
   * @param {number} episode
   * @param {string} key
   */
  begin (media, episode, key) {
    /** @type {(() => void) | null} */
    let metadataReady = null
    const metadata = new Promise(resolve => { metadataReady = resolve })
    const resume = pendingResume && pendingResume.mediaId === media.id && pendingResume.episode === episode && Date.now() - pendingResume.at < 5 * 60_000 ? pendingResume : null
    if (resume) pendingResume = null
    const scrobbles = traktConnected() && settings.value.traktScrobble
    /** @type {SyncItem} */
    const item = {
      media,
      episode,
      key,
      local: getAnimeProgress({ mediaId: media.id, episode }),
      time: 0,
      duration: 0,
      playing: false,
      finished: false,
      written: null,
      writtenAt: Date.now(),
      pauseTimer: null,
      trakt: scrobbles || (traktConnected() && media.isTmdb) ? traktTarget(media, episode).catch(() => null) : null,
      traktState: 'idle',
      traktTimer: null,
      metadataReady,
      metadata,
      resume
    }
    if (!scrobbles) item.traktState = 'stop' // resume offers only
    this.item = item
    if (this.video && this.video.readyState >= 1) this.onMetadata()
    this.checkRemote(item).catch(error => debug('Remote position check failed', error))
  }

  /**
   * The player closes or moves to another episode: last note write and Trakt stop.
   * @returns {Promise<any>}
   */
  leave () {
    const item = this.item
    if (!item) return Promise.resolve()
    this.item = null
    clearTimeout(item.pauseTimer)
    clearTimeout(item.traktTimer)
    item.metadataReady?.()
    const tasks = [this.writeNote(item)]
    if (item.traktState === 'start' || item.traktState === 'pause') tasks.push(this.sendTrakt(item, 'stop'))
    return Promise.all(tasks)
  }

  onMetadata () {
    const item = this.item
    const video = this.video
    if (!item || !video) return
    if (isFinite(video.duration) && video.duration > 0) {
      item.duration = video.duration
      item.metadataReady?.()
    }
  }

  onTimeUpdate () {
    const item = this.item
    const video = this.video
    if (!item || !video || video.readyState < 1 || !isFinite(video.currentTime)) return
    item.time = video.currentTime
    if (isFinite(video.duration) && video.duration > 0) item.duration = video.duration
    if (!item.finished && item.duration > 0 && item.time / item.duration * 100 >= (settings.value.playerAutocompleteThreshold || 85)) {
      this.finish(item)
      return
    }
    if (!video.paused && Date.now() - item.writtenAt >= PERIODIC_WRITE_MS) this.writeNote(item)
  }

  onPlay () {
    const item = this.item
    if (!item) return
    item.playing = true
    clearTimeout(item.pauseTimer)
    this.queueTrakt(item, 'start', TRAKT_START_DELAY_MS)
  }

  onPause () {
    const item = this.item
    const video = this.video
    if (!item || !video || video.ended || video.readyState < 1) return
    item.playing = false
    item.time = video.currentTime
    clearTimeout(item.pauseTimer)
    item.pauseTimer = setTimeout(() => this.writeNote(item), PAUSE_WRITE_DELAY_MS)
    this.queueTrakt(item, 'pause', TRAKT_PAUSE_DELAY_MS)
  }

  onSeeked () {
    const item = this.item
    const video = this.video
    if (!item || !video || video.readyState < 1) return
    item.time = video.currentTime
    // A new start tells Trakt where playback is now (its "watching" status expires with the remaining time).
    if (!video.paused && item.traktState === 'start') this.queueTrakt(item, 'start', TRAKT_START_DELAY_MS, true)
  }

  onEnded () {
    const item = this.item
    if (!item) return
    item.time = item.duration || item.time
    this.finish(item)
    clearTimeout(item.traktTimer)
    if (item.traktState === 'start' || item.traktState === 'pause') this.sendTrakt(item, 'stop', 100)
  }

  /**
   * The auto-complete threshold is reached: the episode counts as watched, the note line goes away.
   * @param {SyncItem} item
   */
  finish (item) {
    if (item.finished) return
    item.finished = true
    clearTimeout(item.pauseTimer)
    if (noteService(item.media)) saveNotePosition(item.media, null, { upToEpisode: item.episode })
  }

  /**
   * @param {SyncItem} item
   * @returns {Promise<any>}
   */
  writeNote (item) {
    clearTimeout(item.pauseTimer)
    if (item.finished || !(item.time > 0) || !noteService(item.media)) return Promise.resolve()
    const position = { episode: item.episode, time: item.time, duration: item.duration || undefined, device: DEVICE_NAME, at: Date.now() }
    if (!needsWrite(item.written, position)) return Promise.resolve()
    item.written = position
    item.writtenAt = Date.now()
    return saveNotePosition(item.media, position)
  }

  /**
   * @param {SyncItem} item
   * @param {'start' | 'pause'} action
   * @param {number} delay
   * @param {boolean} [force] send a start again (new position)
   */
  queueTrakt (item, action, delay, force = false) {
    if (!item.trakt || item.traktState === 'stop') return
    clearTimeout(item.traktTimer)
    if (item.traktState === action && !force) return
    item.traktTimer = setTimeout(() => this.sendTrakt(item, action), delay)
  }

  /**
   * @param {SyncItem} item
   * @param {'start' | 'pause' | 'stop'} action
   * @param {number} [progress]
   */
  async sendTrakt (item, action, progress) {
    if (!item.trakt) return
    const percent = progress ?? (item.duration > 0 ? item.time / item.duration * 100 : 0)
    const previous = item.traktState
    item.traktState = action
    const target = await item.trakt
    if (!target || previous === 'stop') return
    await scrobble(action, target, percent)
  }

  /**
   * "Resume at 12:34 (from iPhone)": the note (anime) or Trakt (shows and movies) has a newer position for this
   * episode than this device.
   * @param {SyncItem} item
   */
  async checkRemote (item) {
    await Promise.race([item.metadata, new Promise(resolve => setTimeout(resolve, 20_000))])
    // Nothing loaded in the video (external player, failed stream): no offer.
    if (this.item !== item || !this.video || this.video.readyState < 1) return
    if (item.resume) return this.applyResume(item, item.resume)
    /** @type {{ time: number, device: string, at: number, episode: number } | null} */
    let remote = null
    if (noteService(item.media)) {
      const res = await fetchNotePosition(item.media)
      remote = res?.position || null
    } else if (traktConnected() && item.trakt) {
      const target = await item.trakt
      const found = target && (await getTraktPlayback(true)).find(entry => matchesTarget(entry, target))
      if (found && item.duration > 0) {
        remote = { episode: item.episode, time: found.progress / 100 * item.duration, device: 'Trakt', at: Date.parse(found.paused_at) }
      }
    }
    if (this.item !== item || !this.video || !remote) return
    if (!shouldOffer(remote, item.local, item.episode)) return
    if (Math.abs(this.video.currentTime - remote.time) < 15) return
    const target = remote.time
    toast(`Resume at ${formatClock(target)} (from ${remote.device})`, {
      description: `Continue ${item.media?.format === 'MOVIE' ? 'the movie' : `episode ${item.episode}`} where you left off on ${remote.device === 'Trakt' ? 'another device' : remote.device}.`,
      duration: 15_000,
      action: {
        label: 'Resume',
        onClick: () => {
          if (this.item === item && this.video) this.video.currentTime = Math.max(target - 2, 0)
        }
      }
    })
  }

  /**
   * @param {SyncItem} item
   * @param {{ time?: number, percent?: number }} resume
   */
  applyResume (item, resume) {
    const video = this.video
    if (!video) return
    const target = resume.time > 0 ? resume.time : resume.percent > 0 && item.duration > 0 ? resume.percent / 100 * item.duration : 0
    // PlayerPage resumes the local position (set by the details) on loadedmetadata: only correct it when needed.
    setTimeout(() => {
      if (this.item === item && target > 0 && Math.abs(video.currentTime - target) > 3) video.currentTime = Math.max(target - 2, 0)
    }, 500)
  }
}

export const playbackSync = new PlaybackSync()
