// Chromecast from the PC app, renderer side. The Electron main process (electron/src/main/cast/) finds the devices,
// talks the Cast protocol and serves the stream through a LAN proxy; this module drives it from the player.
//
// While casting, the player's <video> element becomes a remote control: its play / pause / currentTime / volume /
// playbackRate / paused / ended / duration properties are redirected to the Cast device (own properties shadowing
// the HTMLMediaElement ones), and the media events the player listens to (play, pause, timeupdate, seeked, waiting,
// playing, ended, volumechange...) are dispatched from the device status. The player keeps its own logic (seekbar,
// keybinds, progress saving, AniList completion, Watch Together) without knowing it is casting. The local element
// stays paused with its loading stopped and gets the device position back when casting stops.
import { writable } from 'simple-store-svelte'
import { toast } from 'svelte-sonner'
import Debug from 'debug'
import { trackToVtt, cueCount } from '@/modules/vtt.js'
import { SETTING_TO_ISO, normalizeLanguage } from '@/modules/onlinesubs/core.js'

const debug = Debug('ui:cast')

const ipc = typeof window !== 'undefined' ? window.IPC : null
export const castSupported = !!(ipc?.invoke && typeof window !== 'undefined' && window.electron)

/** @type {import('simple-store-svelte').Writable<any[]>} */
export const castDevices = writable([])
/** @type {import('simple-store-svelte').Writable<{ active: boolean, phase: string, device: any, playerState: string | null, idleReason: string | null }>} */
export const castState = writable({ active: false, phase: 'idle', device: null, playerState: null, idleReason: null })

const media = HTMLMediaElement.prototype
const nativeGet = (name, element) => Object.getOwnPropertyDescriptor(media, name).get.call(element)
const nativeSet = (name, element, value) => Object.getOwnPropertyDescriptor(media, name).set.call(element, value)
const OVERRIDDEN = ['currentTime', 'paused', 'ended', 'duration', 'readyState', 'seeking', 'volume', 'muted', 'playbackRate', 'play', 'pause']

export function castErrorMessage (error) {
  return String(error?.message || error || 'Unknown error').replace(/^Error invoking remote method '[^']+': (?:Error: )?/, '')
}

function sourceKey (source) {
  return source?.url || ''
}

/** Cast text track language (BCP 47) from a player track language ("eng", "en", "English"...). */
function trackLanguage (language) {
  const value = String(language || '').toLowerCase()
  return SETTING_TO_ISO[value] || normalizeLanguage(value) || undefined
}

function trackName (header) {
  return [header.language || 'Subtitles', header.name].filter(Boolean).join(' - ')
}

/** Subtitle tracks state used to know when the device needs new WebVTT files. */
function trackSignature (subs, delay) {
  const parts = [String(Number(delay) || 0)]
  for (const header of subs?.headers || []) {
    if (header) parts.push(`${header.number}:${header.header?.length || 0}:${subs.tracks?.[header.number]?.length ? 1 : 0}`)
  }
  return parts.join('|')
}

class CastController {
  video = null
  context = null
  attached = false
  active = false
  switching = false
  switchToken = 0
  device = null
  phase = 'idle'
  remote = { playerState: null, time: 0, at: 0, rate: 1, duration: null, volume: null, muted: false }
  intentPaused = true
  commandAt = 0
  ended = false
  pendingSeek = null
  seekTimer = null
  volumeTimer = null
  ticker = null
  trackIds = []
  activeTracks = []
  signature = ''
  reloadTimer = null
  boundSource = null
  starting = false
  listening = false

  listen () {
    if (this.listening || !castSupported) return
    this.listening = true
    ipc.on('cast:devices', list => castDevices.set(list || []))
    ipc.on('cast:status', status => this.onStatus(status))
  }

  async discover (on) {
    if (!castSupported) return
    this.listen()
    try {
      castDevices.set(await ipc.invoke('cast:discover', !!on) || [])
    } catch (error) {
      debug('Discovery failed', error)
    }
  }

  publish () {
    castState.set({
      active: this.active,
      phase: this.phase,
      device: this.device,
      playerState: this.remote.playerState,
      idleReason: this.ended ? 'FINISHED' : null
    })
  }

  // --- remote model -------------------------------------------------------------------------------------------

  currentTime () {
    if (this.pendingSeek != null) return this.pendingSeek
    let time = this.remote.time
    if (this.remote.playerState === 'PLAYING' && !this.switching) time += (performance.now() - this.remote.at) / 1000 * (this.remote.rate || 1)
    const duration = this.duration()
    return Math.max(0, isFinite(duration) && duration > 0 ? Math.min(time, duration) : time)
  }

  duration () {
    if (this.remote.duration > 0) return this.remote.duration
    return this.video ? nativeGet('duration', this.video) : NaN
  }

  emit (...names) {
    const video = this.video
    if (!video) return
    for (const name of names) video.dispatchEvent(new Event(name))
  }

  // --- the <video> element as a remote control -----------------------------------------------------------------

  attach () {
    const video = this.video
    if (!video || this.attached) return
    const self = this
    const define = (name, descriptor) => Object.defineProperty(video, name, { configurable: true, ...descriptor })
    // A new stream attached by the player (another episode or server): give the element back.
    const guard = () => {
      if (self.sameSource()) return true
      self.sourceLost()
      return false
    }
    define('currentTime', {
      get () { return guard() ? self.currentTime() : nativeGet('currentTime', video) },
      set (value) { if (guard()) self.seek(value); else nativeSet('currentTime', video, value) }
    })
    define('paused', { get () { return guard() ? self.intentPaused : nativeGet('paused', video) } })
    define('ended', { get () { return guard() ? self.ended : nativeGet('ended', video) } })
    define('duration', { get () { return guard() ? self.duration() : nativeGet('duration', video) } })
    define('readyState', { get () { return guard() ? 4 : nativeGet('readyState', video) } })
    define('seeking', { get () { return guard() ? self.pendingSeek != null : nativeGet('seeking', video) } })
    define('volume', {
      get () { return guard() ? (self.remote.volume ?? nativeGet('volume', video)) : nativeGet('volume', video) },
      set (value) { if (guard()) self.setVolume(value); else nativeSet('volume', video, value) }
    })
    define('muted', {
      get () { return guard() ? self.remote.muted : nativeGet('muted', video) },
      set (value) { if (guard()) self.setMuted(value); else nativeSet('muted', video, value) }
    })
    define('playbackRate', {
      get () { return guard() ? (self.remote.rate || 1) : nativeGet('playbackRate', video) },
      set (value) { if (guard()) self.setRate(value); else nativeSet('playbackRate', video, value) }
    })
    define('play', {
      writable: true,
      value () {
        if (!guard()) return media.play.call(video)
        self.play()
        return Promise.resolve()
      }
    })
    define('pause', {
      writable: true,
      value () {
        if (!guard()) return media.pause.call(video)
        self.pause()
      }
    })
    this.boundSource = { hls: video._hlsInstance || null, src: video.getAttribute('src') }
    this.attached = true
    clearInterval(this.ticker)
    this.ticker = setInterval(() => {
      if (this.attached && this.remote.playerState === 'PLAYING' && this.pendingSeek == null) this.emit('timeupdate')
    }, 250)
  }

  detach () {
    const video = this.video
    clearInterval(this.ticker)
    this.ticker = null
    if (!video || !this.attached) return
    this.attached = false
    for (const name of OVERRIDDEN) delete video[name]
  }

  sameSource () {
    const video = this.video
    return !!video && (video._hlsInstance || null) === this.boundSource?.hls && video.getAttribute('src') === this.boundSource?.src
  }

  /** The element was handed a new stream before the player told us (see `update`): cast the new one once ready. */
  sourceLost () {
    if (!this.attached) return
    debug('The player loaded another stream')
    this.switchSource()
  }

  /** Stops loading the local stream (hls.js stays attached so playback resumes without reloading). */
  freezeLocal () {
    const video = this.video
    media.pause.call(video)
    try { video._hlsInstance?.stopLoad?.() } catch {}
  }

  // --- commands ------------------------------------------------------------------------------------------------

  async command (payload) {
    try {
      const status = await ipc.invoke('cast:control', payload)
      this.onStatus(status)
      return status
    } catch (error) {
      debug('Cast command failed', payload, error)
      if (this.active && this.phase === 'casting') toast.error('Cast command failed', { description: castErrorMessage(error) })
      return null
    }
  }

  play () {
    // Svelte calls play() again when it reads the "play" event we dispatched: nothing to send then.
    const state = this.remote.playerState
    if (!this.intentPaused && !this.ended && (state === 'PLAYING' || state === 'BUFFERING')) return
    if (this.phase !== 'casting' || this.switching) {
      this.setIntent(false)
      return
    }
    if (this.ended || this.remote.playerState === 'IDLE') {
      // The media is over on the device: load it again (from the start when it ended).
      const time = this.ended ? 0 : this.currentTime()
      this.ended = false
      this.setIntent(false)
      this.reload(time, true)
      return
    }
    this.setIntent(false)
    this.command({ type: 'play' })
  }

  pause () {
    if (this.intentPaused && this.remote.playerState !== 'PLAYING') return
    this.setIntent(true)
    if (this.phase === 'casting' && !this.switching && this.remote.playerState !== 'IDLE') this.command({ type: 'pause' })
  }

  setIntent (paused) {
    this.commandAt = performance.now()
    if (this.intentPaused === paused) return
    this.intentPaused = paused
    this.emit(paused ? 'pause' : 'play')
  }

  seek (value) {
    const duration = this.duration()
    const time = Math.max(0, Math.min(Number(value) || 0, isFinite(duration) && duration > 0 ? duration : Infinity))
    // bind:currentTime writes back the time it just read from a timeupdate while paused: not a seek.
    if (this.pendingSeek == null && Math.abs(time - this.currentTime()) < 0.15) return
    this.pendingSeek = time
    this.remote.time = time
    this.remote.at = performance.now()
    if (this.ended && time < duration - 1) this.ended = false
    // Coalesce quick successive seeks (holding an arrow key, dragging) into one request.
    clearTimeout(this.seekTimer)
    this.seekTimer = setTimeout(async () => {
      const target = this.pendingSeek
      if (target == null) return
      if (this.phase === 'casting' && !this.switching && this.remote.playerState !== 'IDLE') await this.command({ type: 'seek', time: target })
      if (this.pendingSeek === target) this.pendingSeek = null
      this.emit('seeked', 'timeupdate')
    }, 250)
    queueMicrotask(() => this.emit('timeupdate'))
  }

  setVolume (value) {
    const level = Math.min(1, Math.max(0, Number(value)))
    if (!isFinite(level) || Math.abs(level - (this.remote.volume ?? -1)) < 0.005) return
    this.remote.volume = level
    clearTimeout(this.volumeTimer)
    this.volumeTimer = setTimeout(() => this.command({ type: 'volume', level }), 150)
  }

  setMuted (value) {
    const muted = !!value
    if (muted === this.remote.muted) return
    this.remote.muted = muted
    this.command({ type: 'muted', muted })
  }

  setRate (value) {
    const rate = Number(value) || 1
    if (Math.abs(rate - (this.remote.rate || 1)) < 0.01) return
    this.remote.rate = rate
    if (this.phase === 'casting') this.command({ type: 'rate', rate })
  }

  // --- requests to the main process ----------------------------------------------------------------------------

  buildTracks () {
    const subs = this.context?.subs
    const delay = Number(this.context?.delay) || 0
    const list = []
    for (const header of subs?.headers || []) {
      if (!header) continue
      const vtt = trackToVtt({ header: header.header, events: subs.tracks?.[header.number] }, delay)
      if (!cueCount(vtt)) continue
      list.push({ id: header.number + 1, name: trackName(header), language: trackLanguage(header.language), vtt })
    }
    this.trackIds = list.map(track => track.id)
    this.signature = trackSignature(subs, delay)
    this.activeTracks = this.selectedTracks()
    return list
  }

  selectedTracks () {
    const subs = this.context?.subs
    const current = Number(subs?.current)
    if (!subs?.headers?.[current] || current < 0) return []
    return this.trackIds.includes(current + 1) ? [current + 1] : []
  }

  request (startTime, autoplay) {
    const { source, metadata } = this.context
    const tracks = this.buildTracks()
    return {
      source: { url: source.url, headers: source.headers || {} },
      metadata,
      tracks,
      activeTrackIds: this.activeTracks,
      startTime,
      autoplay
    }
  }

  /**
   * Starts casting the player's stream to a device, at the current position.
   * @param {{ id: string, name: string }} device
   * @param {{ video: HTMLVideoElement, source: { url: string, headers?: any }, metadata: any, subs: any, delay: number }} context
   */
  async start (device, context) {
    if (!castSupported || !context?.video || !context.source?.url) return
    this.listen()
    const resumeFromCast = this.attached
    const startTime = resumeFromCast ? this.currentTime() : nativeGet('currentTime', context.video)
    const playing = resumeFromCast ? !this.intentPaused : !nativeGet('paused', context.video)
    if (resumeFromCast && context.video !== this.video) this.detach()
    this.context = context
    this.video = context.video
    this.device = device
    this.active = true
    this.switching = false
    this.ended = false
    this.phase = 'connecting'
    this.pendingSeek = null
    this.remote = { playerState: 'LOADING', time: startTime, at: performance.now(), rate: nativeGet('playbackRate', this.video), duration: null, volume: null, muted: false }
    this.intentPaused = !playing
    if (!this.attached) {
      this.attach()
      this.freezeLocal()
    }
    this.publish()
    this.emit('waiting')
    this.starting = true
    try {
      const status = await ipc.invoke('cast:start', { deviceId: device.id, ...this.request(startTime, playing) })
      this.starting = false
      const wantedPaused = this.intentPaused
      this.onStatus(status)
      this.reconcile(playing, wantedPaused)
    } catch (error) {
      this.starting = false
      debug('Cast start failed', error)
      if (!this.active || this.device !== device) return
      toast.error(`Could not cast to ${device.name}`, { description: castErrorMessage(error) })
      this.finish({ time: startTime, playing })
    }
  }

  /** Loads the media again on the device (new subtitle tracks, offset, or replay after the end). */
  async reload (startTime = this.currentTime(), autoplay = !this.intentPaused) {
    if (!this.active || this.switching || !this.context) return
    clearTimeout(this.reloadTimer)
    try {
      const status = await ipc.invoke('cast:load', this.request(startTime, autoplay))
      const wantedPaused = this.intentPaused
      this.onStatus(status)
      this.reconcile(autoplay, wantedPaused)
    } catch (error) {
      debug('Cast reload failed', error)
      toast.error('Could not update the Cast device', { description: castErrorMessage(error) })
    }
  }

  /** Player state changed (props of CastButton): source, subtitles, offset or metadata. */
  update (context) {
    if (!this.active || !context) return
    const previous = this.context
    this.context = context
    if (!context.source?.url || !context.video) {
      // The player was closed.
      this.stop({ resume: false })
      return
    }
    if (sourceKey(context.source) !== sourceKey(previous?.source) || context.video !== this.video) {
      this.switchSource()
      return
    }
    if (this.switching || !this.attached || this.phase !== 'casting') return
    if (trackSignature(context.subs, context.delay) !== this.signature) {
      clearTimeout(this.reloadTimer)
      this.reloadTimer = setTimeout(() => this.reload(), 1500)
      return
    }
    const selected = this.selectedTracks()
    if (selected.join() !== this.activeTracks.join()) {
      this.activeTracks = selected
      this.command({ type: 'tracks', activeTrackIds: selected })
    }
  }

  /**
   * The player loads another episode or server: hand the element back, let the player prepare the new stream
   * (silently), then cast it from where the player put it (saved progress included).
   */
  async switchSource () {
    // Already waiting for a stream: the latest context (from update) is used when it is ready.
    if (!this.active || this.switching) return
    const token = ++this.switchToken
    this.detach()
    this.switching = true
    this.ended = false
    this.phase = 'loading'
    this.publish()
    ipc.invoke('cast:control', { type: 'stopMedia' }).catch(() => {})
    const video = this.context?.video || this.video
    this.video = video
    if (!video) return
    const wasMuted = nativeGet('muted', video)
    nativeSet('muted', video, true)
    let wantsPlay = !this.intentPaused
    const onPlay = () => {
      wantsPlay = true
      media.pause.call(video)
    }
    video.addEventListener('play', onPlay)
    const ready = await new Promise(resolve => {
      let settled = false
      let timer = null
      const done = (value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        clearTimeout(limit)
        video.removeEventListener('loadedmetadata', onMeta)
        video.removeEventListener('seeked', onSeeked)
        resolve(value)
      }
      const onSeeked = () => { timer = setTimeout(() => done(true), 300) }
      // Metadata, then the resume seek of the player (loadAnimeProgress) or 2 s.
      const onMeta = () => {
        video.addEventListener('seeked', onSeeked)
        timer = setTimeout(() => done(true), 2000)
      }
      const limit = setTimeout(() => done(false), 60_000)
      if (nativeGet('readyState', video) >= 1 && this.context?.source?.url && video.getAttribute('src')) onMeta()
      else video.addEventListener('loadedmetadata', onMeta)
    })
    video.removeEventListener('play', onPlay)
    nativeSet('muted', video, wasMuted)
    if (token !== this.switchToken || !this.active) return
    if (!ready || !this.context?.source?.url) {
      toast.error('Casting stopped', { description: 'The next video did not load.' })
      this.stop({ resume: false })
      return
    }
    this.switching = false
    const startTime = nativeGet('currentTime', video)
    this.remote = { ...this.remote, playerState: 'LOADING', time: startTime, at: performance.now(), duration: null }
    this.intentPaused = !wantsPlay
    this.attach()
    this.freezeLocal()
    this.emit(wantsPlay ? 'play' : 'pause', 'durationchange', 'timeupdate', 'waiting')
    this.phase = 'loading'
    this.publish()
    try {
      const status = await ipc.invoke('cast:load', this.request(startTime, wantsPlay))
      const wantedPaused = this.intentPaused
      this.onStatus(status)
      this.reconcile(wantsPlay, wantedPaused)
    } catch (error) {
      debug('Casting the new source failed', error)
      if (token !== this.switchToken || !this.active) return
      toast.error('Could not cast this video', { description: castErrorMessage(error) })
      this.stop({ resume: true })
    }
  }

  /** Play / pause requested while the device was loading: apply it now that the media is loaded. */
  reconcile (autoplay, wantedPaused) {
    if (!this.active || this.switching || this.phase !== 'casting') return
    if (autoplay && wantedPaused) {
      this.setIntent(true)
      this.command({ type: 'pause' })
    } else if (!autoplay && !wantedPaused) {
      this.setIntent(false)
      this.command({ type: 'play' })
    }
  }

  /** "Stop casting": quits the receiver and resumes local playback at the device position. */
  async stop ({ resume = true } = {}) {
    if (!this.active) return
    const time = this.currentTime()
    const playing = resume && !this.intentPaused && !this.ended
    this.active = false
    try {
      await ipc.invoke('cast:stop')
    } catch (error) {
      debug('Cast stop failed', error)
    }
    this.finish({ time, playing, resume })
  }

  /** Gives the element back to the player at `time`. */
  finish ({ time, playing, resume = true }) {
    const video = this.video
    const bound = this.attached && this.sameSource()
    this.detach()
    clearTimeout(this.seekTimer)
    clearTimeout(this.volumeTimer)
    clearTimeout(this.reloadTimer)
    this.switchToken++
    this.active = false
    this.switching = false
    this.pendingSeek = null
    this.ended = false
    this.phase = 'idle'
    this.device = null
    this.remote = { playerState: null, time: 0, at: 0, rate: 1, duration: null, volume: null, muted: false }
    this.publish()
    this.discover(false)
    if (!video || !bound) return
    // Local playback continues from the device position (hls.js loading was stopped while casting).
    try {
      if (isFinite(time)) {
        video._hlsInstance?.startLoad?.(time)
        video.currentTime = time
      }
    } catch (error) {
      debug('Could not restore the local position', error)
    }
    if (resume && playing) video.play().catch(() => {})
    // The player state (paused, volume, rate, duration) follows the local element again.
    for (const name of ['durationchange', 'volumechange', 'ratechange', 'timeupdate', video.paused ? 'pause' : 'play']) video.dispatchEvent(new Event(name))
  }

  // --- status from the main process ----------------------------------------------------------------------------

  onStatus (status) {
    if (!status || !this.active) return
    if (status.device && this.device && status.device.id !== this.device.id) return
    if (status.phase === 'closed') {
      // A failed start is reported by start() itself.
      if (this.starting) return
      const time = this.currentTime()
      const reason = status.error || status.reason
      this.active = false
      if (reason && reason !== 'stopped') toast.warning('Casting ended', { description: reason })
      this.finish({ time, playing: false })
      return
    }
    if (status.phase === 'idle') return
    if (status.phase === 'connecting' || status.phase === 'loading') {
      if (this.phase !== status.phase) {
        this.phase = status.phase
        this.publish()
        this.emit('waiting')
      }
      return
    }
    if (this.switching) return
    this.phase = 'casting'
    const remote = this.remote
    const before = { volume: remote.volume, muted: remote.muted, rate: remote.rate, duration: remote.duration, state: remote.playerState }
    if (status.time != null && this.pendingSeek == null) {
      remote.time = status.time
      remote.at = performance.now() - (status.age || 0)
    }
    if (status.duration > 0) remote.duration = status.duration
    if (status.volume != null) remote.volume = status.volume
    remote.muted = !!status.muted
    remote.rate = status.rate || 1
    remote.playerState = status.playerState
    const recentCommand = performance.now() - this.commandAt < 1500
    switch (status.playerState) {
      case 'PLAYING':
        this.ended = false
        if (!recentCommand || !this.intentPaused) this.setIntentFromDevice(false)
        this.emit('playing')
        break
      case 'PAUSED':
        if (!recentCommand || this.intentPaused) this.setIntentFromDevice(true)
        this.emit('canplay')
        break
      case 'BUFFERING':
        this.emit('waiting')
        break
      case 'IDLE':
        this.onIdle(status.idleReason)
        break
    }
    if (before.duration !== remote.duration) this.emit('durationchange')
    if (before.volume !== remote.volume || before.muted !== remote.muted) this.emit('volumechange')
    if (before.rate !== remote.rate) this.emit('ratechange')
    this.emit('timeupdate')
    this.publish()
  }

  setIntentFromDevice (paused) {
    if (this.intentPaused === paused) return
    this.intentPaused = paused
    this.emit(paused ? 'pause' : 'play')
  }

  onIdle (reason) {
    if (reason === 'FINISHED') {
      if (this.ended) return
      this.ended = true
      const duration = this.duration()
      if (isFinite(duration) && duration > 0) {
        this.remote.time = duration
        this.remote.at = performance.now()
      }
      this.setIntentFromDevice(true)
      this.emit('timeupdate', 'ended')
    } else if (reason === 'ERROR') {
      toast.error('Casting failed', { description: 'The Cast device could not play this video.' })
      this.stop({ resume: true })
    } else if (reason === 'CANCELLED') {
      // Stopped from the TV remote, the Google Home app or another sender.
      const time = this.currentTime()
      ipc.invoke('cast:stop').catch(() => {})
      this.active = false
      toast('Casting stopped on the device')
      this.finish({ time, playing: false })
    }
    // INTERRUPTED: replaced by our own reload, a new status follows.
  }
}

export const cast = new CastController()
