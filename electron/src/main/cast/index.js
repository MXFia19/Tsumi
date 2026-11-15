import { ipcMain } from 'electron'
import Debug from 'debug'
import CastDiscovery from './mdns.js'
import CastSession from './session.js'
import CastProxy from './proxy.js'

const debug = Debug('electron:cast')

// Subtitles on the TV: white text with a black outline, no box (close to the app's own subtitle style).
const TEXT_TRACK_STYLE = {
  backgroundColor: '#00000000',
  foregroundColor: '#FFFFFFFF',
  edgeType: 'OUTLINE',
  edgeColor: '#000000FF',
  fontScale: 1
}

/**
 * Chromecast support of the PC app (renderer side: common/modules/cast.js).
 * IPC: 'cast:discover' (bool) -> devices, 'cast:start' / 'cast:load' (load request) -> status,
 * 'cast:control' ({ type, ... }) -> status, 'cast:stop' -> status. Pushes 'cast:devices' and 'cast:status'.
 */
export default class CastManager {
  discovery = new CastDiscovery()
  proxy = new CastProxy()
  /** @type {CastSession | null} */
  session = null
  device = null
  phase = 'idle'
  error = null
  reason = null
  poll = null

  /** @param {import('electron').BrowserWindow} window */
  constructor (window) {
    this.window = window
    this.discovery.on('devices', devices => this.send('cast:devices', devices))
    ipcMain.handle('cast:discover', (event, on) => {
      if (on) this.discovery.start()
      else if (!this.session) this.discovery.stop()
      return this.discovery.list()
    })
    ipcMain.handle('cast:start', (event, request) => this.start(request))
    ipcMain.handle('cast:load', (event, request) => this.reload(request))
    ipcMain.handle('cast:control', (event, command) => this.control(command))
    ipcMain.handle('cast:stop', () => this.stop())
    ipcMain.handle('cast:status', () => this.status())
  }

  send (channel, data) {
    if (!this.window.isDestroyed()) this.window.webContents.send(channel, data)
  }

  status () {
    const media = this.session?.media
    const volume = this.session?.receiver?.volume
    return {
      phase: this.phase,
      device: this.device ? { id: this.device.id, name: this.device.name, model: this.device.model } : null,
      playerState: media?.playerState || null,
      idleReason: media?.idleReason || null,
      time: media?.currentTime ?? null,
      // Time since the device reported `time` (the renderer extrapolates from it).
      age: media?.receivedAt ? Date.now() - media.receivedAt : 0,
      rate: media?.playbackRate || 1,
      duration: this.session?.duration ?? null,
      volume: volume?.level ?? null,
      muted: !!volume?.muted,
      activeTrackIds: media?.activeTrackIds || [],
      mediaSessionId: this.session?.mediaSessionId ?? null,
      error: this.error,
      reason: this.reason
    }
  }

  publish () {
    this.send('cast:status', this.status())
  }

  setPhase (phase) {
    this.phase = phase
    this.publish()
  }

  async start (request) {
    const device = this.discovery.get(request?.deviceId)
    if (!device) throw new Error('This Cast device is no longer available.')
    if (this.session) await this.stop(true)
    this.error = null
    this.reason = null
    this.device = device
    this.setPhase('connecting')
    const session = new CastSession(device)
    this.session = session
    session.on('media', () => {
      if (this.session === session) this.publish()
    })
    session.on('receiver', () => {
      if (this.session === session) this.publish()
    })
    session.on('close', reason => {
      if (this.session !== session) return
      debug('Session closed:', reason)
      this.session = null
      this.reason = reason
      clearInterval(this.poll)
      this.proxy.stop().catch(() => {})
      this.setPhase('closed')
    })
    try {
      await session.connect()
      await this.load(request)
    } catch (error) {
      debug('Cast start failed', error?.message)
      this.error = error?.message || String(error)
      if (this.session === session) {
        this.session = null
        clearInterval(this.poll)
        session.stop().catch(() => {})
        await this.proxy.stop().catch(() => {})
        this.setPhase('closed')
      }
      throw new Error(this.error)
    }
    return this.status()
  }

  /** Loads (or reloads) media on the connected device: new source, new subtitle tracks or a new position. */
  async load (request) {
    const session = this.session
    if (!session) throw new Error('Not connected to a Cast device.')
    const source = request?.source
    if (!source?.url || !/^https?:/i.test(source.url)) throw new Error('This video cannot be cast.')
    this.setPhase('loading')
    const host = session.localAddress
    if (!host) throw new Error('Could not find the network address used by the Cast device.')
    await this.proxy.start(host)
    let probe
    try {
      probe = await this.proxy.probe(source)
    } catch (error) {
      throw new Error(`Could not open the video for casting: ${error?.message || error}`)
    }
    const contentUrl = this.proxy.setSource(source)
    const textTracks = (request.tracks || []).filter(track => Number.isInteger(track.id) && track.id > 0)
    const trackUrls = this.proxy.setTextTracks(textTracks)
    const tracks = textTracks.map(track => ({
      trackId: track.id,
      type: 'TEXT',
      subtype: 'SUBTITLES',
      trackContentId: trackUrls[track.id],
      trackContentType: 'text/vtt',
      name: String(track.name || `Subtitles ${track.id}`),
      ...(track.language ? { language: track.language } : {})
    }))
    const metadata = request.metadata || {}
    await session.load({
      contentUrl,
      contentType: probe.kind === 'hls' ? 'application/x-mpegurl' : probe.contentType,
      hls: probe.kind === 'hls' ? probe : null,
      metadata: {
        metadataType: 0,
        title: metadata.title || 'Tsumi',
        ...(metadata.subtitle ? { subtitle: metadata.subtitle } : {}),
        images: metadata.image ? [{ url: metadata.image }] : []
      },
      tracks,
      textTrackStyle: TEXT_TRACK_STYLE,
      activeTrackIds: (request.activeTrackIds || []).filter(id => tracks.some(track => track.trackId === id)),
      currentTime: request.startTime || 0,
      autoplay: request.autoplay !== false
    })
    this.startPolling(session)
    this.setPhase('casting')
    return this.status()
  }

  /** 'cast:load' from the renderer: a failed reload keeps the connection (the previous media may still play). */
  async reload (request) {
    try {
      return await this.load(request)
    } catch (error) {
      if (this.session) this.setPhase('casting')
      throw error
    }
  }

  /** The device only reports on changes: ask for the position regularly so the seekbar stays exact. */
  startPolling (session) {
    clearInterval(this.poll)
    this.poll = setInterval(() => {
      if (this.session !== session || session.closed) return clearInterval(this.poll)
      const state = session.media?.playerState
      if (state === 'PLAYING' || state === 'BUFFERING') session.refresh().catch(() => {})
    }, 3000)
  }

  async control (command) {
    const session = this.session
    if (!session) throw new Error('Not connected to a Cast device.')
    switch (command?.type) {
      case 'play': await session.play(); break
      case 'pause': await session.pause(); break
      case 'seek': await session.seek(command.time); break
      case 'rate': await session.setRate(command.rate); break
      case 'tracks': await session.setTracks(command.activeTrackIds); break
      case 'volume': await session.setVolume({ level: command.level }); break
      case 'muted': await session.setVolume({ muted: command.muted }); break
      case 'stopMedia': await session.stopMedia(); break
      case 'refresh': await session.refresh(); break
      default: throw new Error(`Unknown cast command ${command?.type}`)
    }
    return this.status()
  }

  async stop (replacing = false) {
    const session = this.session
    const last = this.status()
    this.session = null
    clearInterval(this.poll)
    if (session) await session.stop()
    await this.proxy.stop().catch(() => {})
    if (!replacing) {
      this.reason = 'stopped'
      this.setPhase('idle')
      this.device = null
    }
    return last
  }

  destroy () {
    this.discovery.stop()
    this.stop().catch(() => {})
  }
}
