import { EventEmitter } from 'events'
import { writable } from 'simple-store-svelte'
import {
  VOICE_ICE_SERVERS, VOICE_GATHER_AFTER_CANDIDATE_MS, VOICE_GATHER_MAX_MS, VOICE_CONNECT_TIMEOUT_MS,
  voiceRetryDelay, speakingStep, voiceTransmitting
} from '@/routes/w2g/components/sync.js'
import { generateRandomHexCode } from '@/modules/util.js'
import { IPC } from '@/modules/bridge.js'
import { settings } from '@/modules/settings.js'
import Debug from 'debug'
const debug = Debug('ui:w2g-voice')

/**
 * Video volume factor while someone speaks (PROTOCOL.md v2.4 "Ducking"): 1, or VOICE_DUCK_LEVEL.
 * The player multiplies its own volume by it, the user's volume setting is never changed.
 * @type {import('simple-store-svelte').Writable<number>}
 */
export const voiceDuck = writable(1)

/** How often our microphone level is read for the speaking indicator. */
const LEVEL_MS = 100

/**
 * Microphone permission, granted by the Electron main process only while we are in voice
 * (electron/src/main/voice.js). Elsewhere there is nothing to ask.
 * @param {boolean} enabled
 */
async function allowMicrophone (enabled) {
  try {
    if (typeof IPC?.invoke !== 'function') return true
    return (await IPC.invoke('w2g:voice', enabled)) !== false
  } catch (error) {
    debug('microphone permission', error)
    return true
  }
}

/** Waits until ICE gathering completes, 3 s after the first candidate, or 8 s at most (no trickle). */
function gathered (pc) {
  return new Promise(resolve => {
    if (pc.iceGatheringState === 'complete') return resolve()
    let candidateTimer = null
    const done = () => {
      clearTimeout(candidateTimer)
      clearTimeout(maxTimer)
      pc.removeEventListener('icegatheringstatechange', onState)
      pc.removeEventListener('icecandidate', onCandidate)
      resolve()
    }
    const onState = () => { if (pc.iceGatheringState === 'complete') done() }
    const onCandidate = ({ candidate }) => {
      if (!candidate) return done()
      if (!candidateTimer) candidateTimer = setTimeout(done, VOICE_GATHER_AFTER_CANDIDATE_MS)
    }
    const maxTimer = setTimeout(done, VOICE_GATHER_MAX_MS)
    pc.addEventListener('icegatheringstatechange', onState)
    pc.addEventListener('icecandidate', onCandidate)
  })
}

/**
 * One audio link with a member: a dedicated RTCPeerConnection (the data channels of P2PT use simple-peer's lite
 * build, which has no media support), signaled through `voiceSignal` events.
 */
class VoiceLink {
  /** @type {'connecting' | 'connected'} */
  state = 'connecting'
  closed = false
  /** offer id, echoed by the answer */
  id
  /** @type {HTMLAudioElement} */
  audio
  /** @type {RTCPeerConnection} */
  pc
  #connectTimer = null

  /**
   * @param {string} userId
   * @param {string} id
   * @param {{ onConnected: () => void, onFailed: () => void }} handlers
   */
  constructor (userId, id, { onConnected, onFailed }) {
    this.userId = userId
    this.id = id
    this.pc = new RTCPeerConnection({ iceServers: [{ urls: VOICE_ICE_SERVERS }] })
    this.audio = new Audio()
    this.audio.autoplay = true
    this.pc.ontrack = ({ track, streams }) => {
      if (this.closed) return
      this.audio.srcObject = streams?.[0] ?? new MediaStream([track])
      this.audio.play()?.catch?.(error => debug('remote audio play', error))
    }
    this.pc.oniceconnectionstatechange = () => {
      const state = this.pc.iceConnectionState
      if (state === 'connected' || state === 'completed') {
        clearTimeout(this.#connectTimer)
        if (this.state !== 'connected') {
          this.state = 'connected'
          onConnected()
        }
      } else if (state === 'failed' || state === 'closed') {
        onFailed()
      }
    }
    this.#connectTimer = setTimeout(() => { if (this.state !== 'connected') onFailed() }, VOICE_CONNECT_TIMEOUT_MS)
  }

  /** Our microphone on the audio transceiver, or receive only without one. */
  attach (track, stream) {
    if (track) this.pc.addTrack(track, stream)
    else if (!this.pc.getTransceivers().some(transceiver => transceiver.receiver.track?.kind === 'audio')) this.pc.addTransceiver('audio', { direction: 'recvonly' })
  }

  /** @param {{ muted: boolean, volume: number }} mix */
  applyMix (mix) {
    this.audio.muted = !!mix.muted
    this.audio.volume = Math.min(1, Math.max(0, mix.volume))
  }

  close () {
    if (this.closed) return
    this.closed = true
    clearTimeout(this.#connectTimer)
    this.pc.ontrack = null
    this.pc.oniceconnectionstatechange = null
    try {
      this.pc.close()
    } catch (error) {
      debug('close', error)
    }
    this.audio.pause()
    this.audio.srcObject = null
  }
}

/**
 * Watch Together voice chat (PROTOCOL.md v2.4): our microphone (echo cancellation, noise suppression, auto gain),
 * one audio link per member in voice, playback with per-member mute and volume, speaking detection.
 * W2GClient decides who to link with; this class only handles the audio.
 *
 * Events: 'state' (our voice state changed), 'signal' ({ userId, payload }: send a `voiceSignal` to that member),
 * 'links' (a link connected, failed or closed).
 */
export class VoiceEngine extends EventEmitter {
  joined = false
  /** the microphone is being opened */
  starting = false
  hasMic = false
  /** our mute toggle */
  muted = false
  /** push-to-talk key held */
  held = false
  speaking = false
  /** @type {string | null} */
  error = null
  /** @type {MediaStream | null} */
  #stream = null
  /** @type {MediaStreamTrack | null} */
  #track = null
  #audioContext = null
  #analyser = null
  #levelBuffer = null
  #levelTimer = null
  #speakingMemory = null
  /** @type {Map<string, VoiceLink>} */
  #links = new Map()
  /** @type {Map<string, { muted: boolean, volume: number }>} local mute / volume per userId, kept for the lobby */
  #mix = new Map()
  /** @type {Map<string, number>} failed attempts in a row, per userId */
  #failures = new Map()
  /** @type {Map<string, ReturnType<typeof setTimeout>>} */
  #retryTimers = new Map()
  #wantsOffer

  /** @param {{ wantsOffer: (userId: string) => boolean }} options wantsOffer: we should be offering to that member now */
  constructor ({ wantsOffer }) {
    super()
    this.#wantsOffer = wantsOffer
  }

  get pushToTalk () {
    return settings.value.w2gPushToTalk === true
  }

  /** Our microphone sends sound right now. */
  get transmitting () {
    return voiceTransmitting({ joined: this.joined, hasMic: this.hasMic, muted: this.muted, pushToTalk: this.pushToTalk, held: this.held })
  }

  /** `voice` payload. */
  get payload () {
    return { joined: this.joined, muted: !this.transmitting, speaking: this.joined && this.transmitting && this.speaking }
  }

  /** Opens the microphone. Without one (denied or missing) we still join and listen. */
  async join () {
    if (this.joined || this.starting) return
    this.starting = true
    this.error = null
    this.emit('state')
    let stream = null
    try {
      await allowMicrophone(true)
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: false
      })
    } catch (error) {
      debug('microphone unavailable', error)
      this.error = 'Microphone unavailable: you can listen, not talk'
    }
    if (!this.starting) {
      // Left while the microphone was opening.
      for (const track of stream?.getTracks() ?? []) track.stop()
      return
    }
    this.starting = false
    this.joined = true
    this.#stream = stream
    this.#track = stream?.getAudioTracks()[0] ?? null
    this.hasMic = !!this.#track
    this.#startLevelMeter()
    this.#applyTransmit()
    this.emit('state')
  }

  leave () {
    if (!this.joined && !this.starting) return
    this.starting = false
    this.joined = false
    this.speaking = false
    this.held = false
    for (const userId of [...this.#links.keys()]) this.close(userId)
    for (const timer of this.#retryTimers.values()) clearTimeout(timer)
    this.#retryTimers.clear()
    this.#failures.clear()
    clearInterval(this.#levelTimer)
    this.#levelTimer = null
    this.#analyser = null
    this.#audioContext?.close?.().catch?.(() => {})
    this.#audioContext = null
    for (const track of this.#stream?.getTracks() ?? []) track.stop()
    this.#stream = null
    this.#track = null
    this.hasMic = false
    allowMicrophone(false)
    this.emit('state')
  }

  setMuted (muted) {
    if (this.muted === !!muted) return
    this.muted = !!muted
    this.#applyTransmit()
    this.emit('state')
  }

  /** Push-to-talk key pressed / released. */
  setHeld (held) {
    if (this.held === !!held) return
    this.held = !!held
    this.#applyTransmit()
    this.emit('state')
  }

  /** Push-to-talk switched on or off in the settings. */
  refresh () {
    this.#applyTransmit()
    this.emit('state')
  }

  /** @param {string} userId */
  mixOf (userId) {
    return this.#mix.get(userId) ?? { muted: false, volume: 1 }
  }

  /** Local mute / volume of a member (0-1), only for us. */
  setMix (userId, { muted, volume }) {
    const current = this.mixOf(userId)
    const next = { muted: muted ?? current.muted, volume: Math.min(1, Math.max(0, volume ?? current.volume)) }
    this.#mix.set(userId, next)
    this.#links.get(userId)?.applyMix(next)
    this.emit('links')
  }

  /** @returns {Record<string, 'connecting' | 'connected'>} */
  linkStates () {
    return Object.fromEntries([...this.#links].map(([userId, link]) => [userId, link.state]))
  }

  hasLink (userId) {
    return this.#links.has(userId)
  }

  /** We are the offerer: create the link and send the offer. */
  async connect (userId) {
    if (!this.joined || this.#links.has(userId)) return
    clearTimeout(this.#retryTimers.get(userId))
    this.#retryTimers.delete(userId)
    const link = this.#createLink(userId, generateRandomHexCode(12))
    try {
      link.attach(this.#track, this.#stream)
      await link.pc.setLocalDescription(await link.pc.createOffer())
      await gathered(link.pc)
      if (link.closed) return
      this.emit('signal', { userId, payload: { id: link.id, sdp: { type: 'offer', sdp: link.pc.localDescription.sdp } } })
    } catch (error) {
      debug('offer failed', error)
      this.#failed(userId, link)
    }
  }

  /**
   * A `voiceSignal` from a member. Offers are only passed here once accepted (acceptsVoiceOffer).
   * @param {string} userId
   * @param {{ id?: unknown, sdp?: { type?: unknown, sdp?: unknown } }} payload
   */
  async signal (userId, payload) {
    const type = payload?.sdp?.type
    const sdp = payload?.sdp?.sdp
    const id = payload?.id != null ? String(payload.id) : ''
    if (!this.joined || typeof sdp !== 'string' || !sdp || !id) return
    if (type === 'offer') {
      // A new offer replaces the link we had with that member.
      this.close(userId)
      const link = this.#createLink(userId, id)
      try {
        await link.pc.setRemoteDescription({ type: 'offer', sdp })
        link.attach(this.#track, this.#stream)
        await link.pc.setLocalDescription(await link.pc.createAnswer())
        await gathered(link.pc)
        if (link.closed) return
        this.emit('signal', { userId, payload: { id, sdp: { type: 'answer', sdp: link.pc.localDescription.sdp } } })
      } catch (error) {
        debug('answer failed', error)
        this.#failed(userId, link)
      }
    } else if (type === 'answer') {
      const link = this.#links.get(userId)
      if (!link || link.id !== id || link.pc.signalingState !== 'have-local-offer') return
      try {
        await link.pc.setRemoteDescription({ type: 'answer', sdp })
      } catch (error) {
        debug('remote answer failed', error)
        this.#failed(userId, link)
      }
    }
  }

  /** Closes the link with a member (left voice, left the lobby, kicked). */
  close (userId) {
    const link = this.#links.get(userId)
    clearTimeout(this.#retryTimers.get(userId))
    this.#retryTimers.delete(userId)
    if (!link) return
    this.#links.delete(userId)
    link.close()
    this.emit('links')
  }

  /** Forget a member that left the lobby (its mix too). */
  forget (userId) {
    this.close(userId)
    this.#failures.delete(userId)
    this.#mix.delete(userId)
  }

  destroy () {
    this.leave()
    this.removeAllListeners()
  }

  #createLink (userId, id) {
    const link = new VoiceLink(userId, id, {
      onConnected: () => {
        this.#failures.delete(userId)
        this.emit('links')
      },
      onFailed: () => this.#failed(userId, link)
    })
    link.applyMix(this.mixOf(userId))
    this.#links.set(userId, link)
    this.emit('links')
    return link
  }

  /** A link failed: close it; the offerer tries again after 3 s, at most 5 times in a row. */
  #failed (userId, link) {
    if (link.closed) return
    if (this.#links.get(userId) === link) this.#links.delete(userId)
    link.close()
    this.emit('links')
    if (!this.joined || !this.#wantsOffer(userId)) return
    const failures = (this.#failures.get(userId) ?? 0) + 1
    this.#failures.set(userId, failures)
    const delay = voiceRetryDelay(failures)
    if (delay === null) return
    clearTimeout(this.#retryTimers.get(userId))
    this.#retryTimers.set(userId, setTimeout(() => {
      this.#retryTimers.delete(userId)
      if (this.joined && this.#wantsOffer(userId)) this.connect(userId)
    }, delay))
  }

  #applyTransmit () {
    if (this.#track) this.#track.enabled = this.transmitting
    if (!this.transmitting && this.speaking) this.speaking = false
  }

  /** Peak level of the processed microphone every 100 ms, for `speaking`. */
  #startLevelMeter () {
    clearInterval(this.#levelTimer)
    if (!this.#stream) return
    try {
      this.#audioContext = new AudioContext()
      const source = this.#audioContext.createMediaStreamSource(this.#stream)
      this.#analyser = this.#audioContext.createAnalyser()
      this.#analyser.fftSize = 4096
      source.connect(this.#analyser)
      this.#levelBuffer = new Float32Array(this.#analyser.fftSize)
    } catch (error) {
      debug('level meter unavailable', error)
      return
    }
    this.#levelTimer = setInterval(() => this.#readLevel(), LEVEL_MS)
  }

  #readLevel () {
    if (!this.#analyser || !this.joined) return
    if (this.#audioContext?.state === 'suspended') this.#audioContext.resume().catch(() => {})
    this.#analyser.getFloatTimeDomainData(this.#levelBuffer)
    let peak = 0
    for (const sample of this.#levelBuffer) {
      const value = Math.abs(sample)
      if (value > peak) peak = value
    }
    this.#speakingMemory = speakingStep(this.#speakingMemory, { level: peak, transmitting: this.transmitting, now: Date.now() })
    if (this.#speakingMemory.speaking !== this.speaking) {
      this.speaking = this.#speakingMemory.speaking
      this.emit('state')
    }
  }
}

/** Key code shown to the user: "KeyT" → "T", "Space" → "Space". */
export function keyLabel (code) {
  if (typeof code !== 'string' || !code) return 'T'
  if (/^Key[A-Z]$/.test(code)) return code.slice(3)
  if (/^Digit\d$/.test(code)) return code.slice(5)
  return code.replace(/(Left|Right)$/, ' $1')
}

/** True when a key event is typed into a text field (push-to-talk ignores it there). */
function typing (event) {
  const target = /** @type {HTMLElement | null} */ (event.target)
  if (!target) return false
  if (target.isContentEditable) return true
  const tag = target.tagName
  return tag === 'TEXTAREA' || (tag === 'INPUT' && !['checkbox', 'radio', 'range', 'button'].includes(/** @type {HTMLInputElement} */ (target).type))
}

/**
 * Push-to-talk key (setting `w2gPushToTalkKey`, T by default): held = transmitting. Listens on the window in the
 * capture phase so the key does not also trigger a player shortcut while it is used to talk.
 * @param {() => { voiceJoined: boolean, setPushToTalkHeld: (held: boolean) => void } | null} getClient
 */
export function installPushToTalk (getClient) {
  const matches = event => {
    const client = getClient()
    if (!client?.voiceJoined || settings.value.w2gPushToTalk !== true) return null
    return event.code === (settings.value.w2gPushToTalkKey || 'KeyT') ? client : null
  }
  window.addEventListener('keydown', event => {
    if (typing(event)) return
    const client = matches(event)
    if (!client) return
    event.preventDefault()
    event.stopImmediatePropagation()
    if (!event.repeat) client.setPushToTalkHeld(true)
  }, true)
  window.addEventListener('keyup', event => {
    const client = matches(event)
    if (!client) return
    event.preventDefault()
    event.stopImmediatePropagation()
    client.setPushToTalkHeld(false)
  }, true)
  window.addEventListener('blur', () => getClient()?.setPushToTalkHeld(false))
}
