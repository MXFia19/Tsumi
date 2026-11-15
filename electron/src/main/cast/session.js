import { EventEmitter } from 'node:events'
import Debug from 'debug'
import { CastChannel, NS } from './castv2.js'

const debug = Debug('electron:cast:session')

/** Google's Default Media Receiver: plays HLS / MP4 / WebM with WebVTT text tracks, no registration needed. */
export const DEFAULT_MEDIA_RECEIVER = 'CC1AD845'

const LOAD_ERRORS = {
  LOAD_FAILED: 'The Cast device could not play this video.',
  LOAD_CANCELLED: 'Loading was cancelled on the Cast device.',
  INVALID_REQUEST: 'The Cast device rejected the video.',
  INVALID_PLAYER_STATE: 'The Cast device is not ready to play.'
}

export function loadErrorMessage (response) {
  const base = LOAD_ERRORS[response?.type] || 'The Cast device could not play this video.'
  const detail = response?.reason || response?.detailedErrorCode
  return detail ? `${base} (${detail})` : base
}

/**
 * A Default Media Receiver session on one device: connects, launches (or joins) the receiver app, loads media and
 * forwards the media commands. Emits 'media' (last MEDIA_STATUS entry or null), 'receiver' (RECEIVER_STATUS) and
 * 'close' (reason) once.
 */
export default class CastSession extends EventEmitter {
  channel = new CastChannel()
  transportId = null
  sessionId = null
  mediaSessionId = null
  /** @type {any} last media status, with `receivedAt` */
  media = null
  receiver = null
  duration = null
  loading = false
  closed = false

  constructor (device) {
    super()
    this.device = device
  }

  get localAddress () {
    return this.channel.localAddress
  }

  async connect () {
    this.channel.on('message', message => this.onMessage(message))
    this.channel.on('close', reason => this.close(reason))
    await this.channel.connect(this.device.host, this.device.port)
    this.channel.send(NS.CONNECTION, { type: 'CONNECT' })
    const status = await this.channel.request(NS.RECEIVER, { type: 'GET_STATUS' })
    this.onReceiverStatus(status?.status)
    let app = this.findApp(this.receiver)
    if (!app) {
      const waiting = this.waitForApp(30_000)
      const response = await this.channel.request(NS.RECEIVER, { type: 'LAUNCH', appId: DEFAULT_MEDIA_RECEIVER }, 'receiver-0', 30_000)
      if (response?.type === 'LAUNCH_ERROR') throw new Error(`The Cast device could not start the media player${response.reason ? ` (${response.reason})` : ''}.`)
      this.onReceiverStatus(response?.status)
      app = this.findApp(this.receiver) || await waiting
    }
    this.transportId = app.transportId
    this.sessionId = app.sessionId
    this.channel.send(NS.CONNECTION, { type: 'CONNECT', userAgent: 'Tsumi' }, this.transportId)
    debug(`Joined ${DEFAULT_MEDIA_RECEIVER} on ${this.device.name} (${this.sessionId})`)
  }

  findApp (status) {
    return status?.applications?.find(app => app.appId === DEFAULT_MEDIA_RECEIVER && app.transportId) || null
  }

  waitForApp (timeout) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.off('receiver', check)
        reject(new Error('The Cast device did not start the media player.'))
      }, timeout)
      const check = (status) => {
        const app = this.findApp(status)
        if (!app) return
        clearTimeout(timer)
        this.off('receiver', check)
        resolve(app)
      }
      this.on('receiver', check)
    })
  }

  onMessage ({ namespace, data, source }) {
    if (!data || typeof data !== 'object') return
    if (namespace === NS.RECEIVER && data.type === 'RECEIVER_STATUS') {
      this.onReceiverStatus(data.status)
      // Our receiver app was closed (from the TV remote, the Google Home app or another sender launching an app).
      if (this.sessionId && !(data.status?.applications || []).some(app => app.sessionId === this.sessionId)) {
        this.close('The Cast session was ended on the device.')
      }
    } else if (namespace === NS.MEDIA && data.type === 'MEDIA_STATUS') {
      if (!this.loading) this.onMediaStatus(data.status)
    } else if (namespace === NS.CONNECTION && data.type === 'CLOSE' && source === this.transportId) {
      this.close('The Cast session was ended on the device.')
    }
  }

  onReceiverStatus (status) {
    if (!status) return
    this.receiver = status
    this.emit('receiver', status)
  }

  onMediaStatus (list) {
    const status = Array.isArray(list) ? list.find(entry => entry.mediaSessionId === this.mediaSessionId) || list[0] : null
    if (!status) {
      if (this.media) {
        this.media = { ...this.media, playerState: 'IDLE', idleReason: this.media.idleReason || 'CANCELLED', receivedAt: Date.now() }
        this.emit('media', this.media)
      }
      return
    }
    // Statuses of a media this session replaced (track or source reload) are not ours any more.
    if (this.mediaSessionId && status.mediaSessionId !== this.mediaSessionId) {
      if (status.playerState === 'IDLE') return
      this.mediaSessionId = status.mediaSessionId
    }
    if (status.media?.duration > 0) this.duration = status.media.duration
    this.media = { ...this.media, ...status, receivedAt: Date.now() }
    if (status.playerState !== 'IDLE') delete this.media.idleReason
    this.emit('media', this.media)
  }

  async load ({ contentUrl, contentType, hls, metadata, tracks, activeTrackIds, currentTime, autoplay, textTrackStyle }) {
    const media = { contentId: contentUrl, contentUrl, contentType, streamType: 'BUFFERED', metadata, tracks, textTrackStyle }
    if (hls) {
      media.hlsSegmentFormat = hls.segment
      if (hls.video) media.hlsVideoSegmentFormat = hls.video
    }
    this.loading = true
    try {
      const response = await this.channel.request(NS.MEDIA, {
        type: 'LOAD',
        sessionId: this.sessionId,
        media,
        autoplay: !!autoplay,
        currentTime: Math.max(0, Number(currentTime) || 0),
        activeTrackIds: activeTrackIds || []
      }, this.transportId, 60_000)
      if (response?.type !== 'MEDIA_STATUS') throw new Error(loadErrorMessage(response))
      const status = response.status?.[0]
      if (status) {
        this.mediaSessionId = status.mediaSessionId
        this.duration = status.media?.duration > 0 ? status.media.duration : null
      }
      this.loading = false
      this.media = null
      this.onMediaStatus(response.status)
      return this.media
    } finally {
      this.loading = false
    }
  }

  async command (type, extra = {}) {
    if (!this.mediaSessionId) throw new Error('Nothing is playing on the Cast device.')
    const response = await this.channel.request(NS.MEDIA, { type, mediaSessionId: this.mediaSessionId, ...extra }, this.transportId)
    if (response?.type && response.type !== 'MEDIA_STATUS') throw new Error(loadErrorMessage(response))
    return response
  }

  play () { return this.command('PLAY') }
  pause () { return this.command('PAUSE') }
  seek (time) { return this.command('SEEK', { currentTime: Math.max(0, Number(time) || 0) }) }
  setRate (rate) { return this.command('SET_PLAYBACK_RATE', { playbackRate: Number(rate) || 1 }) }
  setTracks (activeTrackIds) { return this.command('EDIT_TRACKS_INFO', { activeTrackIds: activeTrackIds || [] }) }
  stopMedia () { return this.command('STOP') }

  async refresh () {
    if (!this.transportId || this.closed) return
    // The answer also arrives as a message (onMessage), which updates the status.
    await this.channel.request(NS.MEDIA, { type: 'GET_STATUS' }, this.transportId, 5000)
  }

  /** Device volume (receiver), or the stream volume when the device volume is fixed. */
  async setVolume ({ level, muted }) {
    const volume = {}
    if (level != null) volume.level = Math.min(1, Math.max(0, Number(level) || 0))
    if (muted != null) volume.muted = !!muted
    if (this.receiver?.volume?.controlType === 'fixed' && this.mediaSessionId) {
      return this.command('SET_VOLUME', { volume })
    }
    return this.channel.request(NS.RECEIVER, { type: 'SET_VOLUME', volume })
  }

  /** Quits the receiver app on the device and closes the connection. */
  async stop () {
    if (this.closed) return
    try {
      if (this.sessionId) await this.channel.request(NS.RECEIVER, { type: 'STOP', sessionId: this.sessionId }, 'receiver-0', 4000)
    } catch (error) {
      debug('STOP failed', error.message)
    }
    this.close('stopped')
  }

  close (reason = 'closed') {
    if (this.closed) return
    this.closed = true
    this.channel.close(reason)
    this.emit('close', reason)
  }
}
