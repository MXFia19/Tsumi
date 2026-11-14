import { EventEmitter } from 'events'

import P2PT from 'p2pt'

import Event, { EventTypes, SYSTEM_MESSAGE } from '@/routes/w2g/components/events.js'
import {
  PROTOCOL_VERSION, HEARTBEAT_MS, PING_MS, REQUEST_TIMEOUT_MS, IN_SYNC_S, ACTIONS, REQUEST_KINDS,
  isFiniteNumber, sameId, normalizeMode, normalizeState, normalizeRate, normalizeReaction, normalizeCountdownSeconds,
  memberName, electHost, expectedTime, syncBadge, selfBadge, autoSyncStep, hostReference, inferAction,
  describeAction, describeRequest
} from '@/routes/w2g/components/sync.js'
import Helper from '@/modules/helper.js'
import { settings } from '@/modules/settings.js'
import { SUPPORTS } from '@/modules/support.js'
import { generateRandomHexCode } from '@/modules/util.js'
import { writable } from 'simple-store-svelte'
import Debug from 'debug'
const debug = Debug('ui:w2g')

/**
 * @typedef {import('@/modules/al.d.ts').Viewer | { id: string, displayName?: string }} W2GUser
 * @typedef {Record<string, { user: W2GUser, peer?: import('p2pt').Peer<any>, userId?: string, protocol?: number, client?: string }>} PeerList
 * @typedef {{ media: object, episode: number | { number: number, season?: number, localEpisode?: number }, key: string }} SharedMedia
 * @typedef {{ message: string, user: W2GUser | null, type: 'incoming' | 'outgoing' | 'system', date: Date, emoji?: string }} ChatEntry
 * @typedef {{ status?: import('./sync.js').Status & { sentAt?: number }, receivedAt?: number, rtt?: number }} Signal
 * @typedef {{ id: string, kind: 'pause' | 'play' | 'seek', time?: number, userId: string, name: string, expiresAt: number }} HostRequest
 * @typedef {{ userId: string, user: W2GUser, name: string, isSelf: boolean, isHost: boolean, badge: import('./sync.js').Badge, protocol?: number, client?: string, rtt?: number }} MemberView
 */

const MAX_MESSAGES = 200
const MAX_MESSAGE_LENGTH = 2048
/** Ids of the events that are sent all the time, kept out of the debug log. */
const QUIET_EVENTS = new Set([EventTypes.StatusEvent, EventTypes.PingEvent, EventTypes.PongEvent])

/** Id of an anonymous participant, kept for the whole app session. */
const anonymousId = generateRandomHexCode(16)

/** Unique id of a title + episode, used to avoid re-sharing what everyone already plays. */
function mediaKey ({ media, episode }) {
  const ep = typeof episode === 'object' && episode !== null
    ? `${episode.season ?? ''}:${episode.localEpisode ?? episode.number}`
    : String(episode)
  return `${media?.id}:${ep}`
}

/**
 * Watch Together lobby: participants find each other through public WebSocket
 * signaling servers (P2PT), then talk directly over WebRTC. Nothing but small
 * JSON events (who is here, what is playing, play/pause/time, chat...) is exchanged.
 * The protocol is described in ../PROTOCOL.md.
 *
 * Events emitted for the app:
 * - 'media' (SharedMedia), 'index' (number): start the same title / file
 * - 'player' ({ time, paused, action, by, rate }): apply this state to the player, silently when action is 'sync'
 * - 'perform' ({ kind, time }): the host accepted a request, do it as a local action
 * - 'notice' ({ text, by, action }): someone else's action, shown over the video
 * - 'info' ({ text }): local feedback (request answered, nothing to sync with...)
 * - 'blocked' ({ action, time, paused }): a local action was undone because only the host controls playback
 * - 'chat' ({ userId, name, user, message }): incoming chat message
 * - 'reaction' ({ emoji, userId, name, isSelf })
 * - 'countdown' ({ time, seconds, endsAt, by })
 * - 'request' (HostRequest): someone asks the host for a change
 * - 'kicked': the host removed us from the lobby
 */
export class W2GClient extends EventEmitter {
  static #signalingServers = [
    'wss://tracker.openwebtorrent.com',
    'wss://tracker.webtorrent.dev',
    'wss://tracker.files.fm:7073/announce'
  ]

  /** Last playback state of the lobby, as sent or received. */
  player = {
    paused: true,
    time: 0
  }

  /** @type {{ index: number }} position in the player's file list */
  index = { index: 0 }
  /** @type {(SharedMedia & { localKey?: string }) | null} what the lobby is currently watching */
  media = null
  #p2pt
  code
  /** @type {import('simple-store-svelte').Writable<ChatEntry[]>} */
  messages = writable([])

  /** @type {W2GUser} */
  self
  /** @type {import('simple-store-svelte').Writable<PeerList>} participants that sent `init`, keyed by transport id (self by its id) */
  peers

  /** @type {import('simple-store-svelte').Writable<{ hostId: string | null, mode: 'everyone' | 'host', tentative: boolean }>} */
  lobby = writable({ hostId: null, mode: 'everyone', tentative: false })
  /** @type {import('simple-store-svelte').Writable<Record<string, Signal>>} last status / RTT per userId */
  signals = writable({})
  /** @type {import('./sync.js').LocalStatus} our own player, `time` read at `at` */
  local = { state: 'idle', time: 0, mediaKey: '', rate: 1, at: Date.now() }
  /** @type {import('simple-store-svelte').Writable<import('./sync.js').LocalStatus>} same as `local`, updated on state changes only */
  localStatus = writable({ ...this.local })
  /** @type {import('simple-store-svelte').Writable<HostRequest[]>} requests waiting for the host's answer */
  requests = writable([])
  /** @type {import('simple-store-svelte').Writable<{ time: number, seconds: number, endsAt: number, by: string } | null>} */
  countdown = writable(null)

  /** @type {Map<string, import('p2pt').Peer<any>>} open data channels by transport id */
  #channels = new Map()
  /** @type {Set<string>} kicked userIds, ignored for the rest of the session */
  #banned = new Set()
  /** @type {Set<string>} transport ids of the kicked users' channels, ignored while they close */
  #bannedPeers = new Set()
  /** @type {Map<string, number>} last message time per userId */
  #lastSeen = new Map()
  /** @type {{ streak: number, lastSyncAt: number } | null} */
  #autoSync = null
  /** @type {{ time: number, paused: boolean, rate: number, at: number } | null} last applied `player` event of the host */
  #lastHostPlayer = null
  /** @type {Map<string, ReturnType<typeof setTimeout>>} */
  #requestTimers = new Map()
  /** @type {Map<string, string>} request id -> requester userId */
  #requestOwners = new Map()
  /** @type {Set<string>} ids of our own pending requests */
  #myRequests = new Set()
  #countdownTimer = null
  #heartbeat = null
  #pinger = null
  #destroyed = false

  get inviteLink () {
    return `tsumi://w2g/${this.code}`
  }

  get selfId () {
    return String(this.self.id)
  }

  get hostId () {
    return this.lobby.value.hostId
  }

  get mode () {
    return this.lobby.value.mode
  }

  get isHost () {
    return sameId(this.hostId, this.selfId)
  }

  /** While no host is known, everyone controls playback. */
  get effectiveMode () {
    return this.hostId == null ? 'everyone' : this.mode
  }

  /** Only the host controls playback and we are not the host. */
  get controlLocked () {
    return this.effectiveMode === 'host' && !this.isHost
  }

  /** "Start together" is for the host, or for anyone in `everyone` mode. */
  get canCountdown () {
    return this.isHost || this.effectiveMode === 'everyone'
  }

  /**
   * @param {string} [code] lobby code, omit to create a new lobby
   * @param {{ displayName?: string }} [options] displayName: name shown for an anonymous user
   */
  constructor (code, { displayName } = {}) {
    super()
    const viewer = Helper.getUser()
    this.self = viewer ? { ...viewer } : { id: anonymousId }
    if (!viewer && displayName?.trim()) this.self.displayName = displayName.trim().slice(0, 32)
    this.peers = writable({ [this.selfId]: { user: this.self, userId: this.selfId, protocol: PROTOCOL_VERSION } })

    this.code = code ?? generateRandomHexCode(16)
    // The lobby creator is the first host.
    if (!code) this.lobby.value = { hostId: this.selfId, mode: 'everyone', tentative: false }

    debug(`W2GClient: ${this.code}, ${this.isHost}`)

    this.#p2pt = new P2PT(W2GClient.#signalingServers, this.code)

    this.#wireEvents()
    this.#p2pt.start()
    this.#heartbeat = setInterval(() => this.#sendStatus(), HEARTBEAT_MS)
    this.#pinger = setInterval(() => this.#pingAll(), PING_MS)
  }

  // ---------------------------------------------------------------- public API

  /**
   * A title/episode was started locally: share it so the others start it too.
   * @param {{ media: object, episode: SharedMedia['episode'] }} shared
   */
  shareMedia ({ media, episode }) {
    const key = mediaKey({ media, episode })
    debug(`shareMedia: ${this.media?.key} -> ${key}`)
    // localKey: our own key for a media received from another client, which may format it differently.
    if (this.media?.key === key || this.media?.localKey === key) return
    this.media = { media, episode, key, localKey: key }
    this.#sendToPeers(new Event(EventTypes.MediaEvent, { media, episode, key }))
  }

  /** @param {{ index: number }} index */
  mediaIndexChanged (index) {
    debug(`mediaIndexChanged: ${JSON.stringify(this.index)} ${JSON.stringify(index)}`)
    if (this.index?.index !== index?.index) {
      this.index = index
      this.#sendToPeers(new Event(EventTypes.MediaIndexEvent, index))
    }
  }

  /** @deprecated v1 helper, kept for callers: true when the state differs from the last known one. */
  _playerStateChanged (state) {
    if (!state) return false
    if (this.player.paused !== state.paused || this.player.time !== state.time) {
      this.player = { time: state.time, paused: state.paused }
      return true
    }
    return false
  }

  /**
   * A local play / pause / seek happened in the player. In `host` mode a non-host is
   * snapped back to the host instead of broadcasting.
   * @param {{ time: number, paused: boolean, action?: 'play' | 'pause' | 'seek', delta?: number | null, rate?: number }} state
   * @returns {boolean} true when it was broadcast
   */
  playerStateChanged (state) {
    debug(`playerStateChanged: ${JSON.stringify(state)}`)
    if (!state || !isFiniteNumber(state.time)) return false
    const paused = !!state.paused
    const action = ['play', 'pause', 'seek'].includes(state.action) ? state.action : inferAction(this.player, { paused })
    this.#cancelCountdown()

    if (this.controlLocked) {
      const target = this.#hostTarget(Date.now())
      if (target && (target.mediaKey === null || target.mediaKey === this.local.mediaKey)) {
        this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostId })
      }
      this.emit('blocked', { action, time: state.time, paused })
      return false
    }

    this.player = { time: state.time, paused }
    const rate = normalizeRate(state.rate)
    this.#sendToPeers(new Event(EventTypes.PlayerStateEvent, { time: state.time, paused, by: this.selfId, action, rate }))
    const text = describeAction({ name: 'You', action, time: state.time, delta: state.delta })
    if (text) this.#system(text)
    return true
  }

  /**
   * Our player state, sent as `status` right away when it changed (or when `force`), and every 3 s.
   * @param {{ state: string, time: number, mediaKey?: string, rate?: number }} status
   * @param {{ force?: boolean }} [options] force: send even without a state change (seek done)
   */
  setLocalStatus ({ state, time, mediaKey, rate }, { force = false } = {}) {
    const next = {
      state: normalizeState(state) || 'idle',
      time: isFiniteNumber(time) ? time : 0,
      mediaKey: mediaKey ? String(mediaKey) : '',
      rate: normalizeRate(rate),
      at: Date.now()
    }
    const previous = this.local
    this.local = next
    const changed = previous.state !== next.state || previous.mediaKey !== next.mediaKey || previous.rate !== next.rate
    if (changed) this.localStatus.value = { ...next }
    if (changed || force) this.#sendStatus()
  }

  /** Cheap position update from the player's timeupdate. */
  updateLocalTime (time) {
    if (!isFiniteNumber(time)) return
    this.local.time = time
    this.local.at = Date.now()
  }

  /** The player finished loading a file: follow the host if it watches the same thing. */
  playerReady () {
    if (this.isHost || this.hostId == null) return
    if (this.effectiveMode !== 'host' && settings.value.w2gAutoSync === false) return
    const target = this.#hostTarget(Date.now())
    if (!target || target.mediaKey === null || target.mediaKey !== this.local.mediaKey) return
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostId })
  }

  /** Manual "Resync": jump to the host's expected position and state now. */
  resync () {
    if (this.isHost) return false
    const target = this.#hostTarget(Date.now())
    if (!target) {
      this.emit('info', { text: 'Nothing to sync with yet' })
      return false
    }
    if (target.mediaKey !== null && target.mediaKey !== this.local.mediaKey) {
      this.emit('info', { text: 'The host is on another episode' })
      return false
    }
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostId })
    return true
  }

  /** Host: send our position to everyone as a silent correction. */
  resyncEveryone () {
    if (!this.isHost) return false
    const time = this.#localTime(Date.now())
    if (time === null) {
      this.emit('info', { text: 'Start playing to resync everyone' })
      return false
    }
    const paused = this.local.state !== 'playing' && this.local.state !== 'buffering'
    this.player = { time, paused }
    this.#sendToPeers(new Event(EventTypes.PlayerStateEvent, { time, paused, by: this.selfId, action: 'sync', rate: this.local.rate }))
    this.emit('info', { text: 'Everyone was resynced' })
    return true
  }

  /** "Start together": everyone seeks to our position, pauses, counts down, then plays. */
  startTogether (seconds) {
    if (!this.canCountdown) return false
    const startAt = Date.now()
    const time = this.#localTime(startAt) ?? this.player.time ?? 0
    const value = normalizeCountdownSeconds(seconds)
    this.#sendToPeers(new Event(EventTypes.CountdownEvent, { time, seconds: value, startAt }))
    this.#runCountdown({ time, seconds: value, endsAt: startAt + value * 1000, by: this.selfId })
    this.#system('You started a countdown')
    return true
  }

  /** Host: control mode toggle. @param {'everyone' | 'host'} mode */
  setMode (mode) {
    const next = normalizeMode(mode)
    if (!this.isHost || next === this.mode) return false
    this.#setLobby({ hostId: this.selfId, mode: next, tentative: false })
    this.#sendToPeers(new Event(EventTypes.HostEvent, { hostId: this.selfId, mode: next }))
    return true
  }

  /** Host: give the host role to someone else. */
  transferHost (userId) {
    const target = String(userId)
    if (!this.isHost || target === this.selfId || !this.#hasUser(target)) return false
    // A v1 client would not know it is host: it could not change the mode, kick or answer requests.
    const protocol = Object.values(this.peers.value).find(entry => entry.peer && entry.userId === target)?.protocol ?? 1
    if (protocol < PROTOCOL_VERSION) return false
    const mode = this.mode
    this.#sendToPeers(new Event(EventTypes.HostEvent, { hostId: target, mode }))
    this.#setLobby({ hostId: target, mode, tentative: false })
    return true
  }

  /** Host: remove someone from the lobby. */
  kick (userId) {
    const target = String(userId)
    if (!this.isHost || target === this.selfId) return false
    this.#sendToPeers(new Event(EventTypes.KickEvent, { userId: target }))
    this.#ban(target)
    return true
  }

  /**
   * Non-host: ask the host for a change.
   * @param {'pause' | 'play' | 'seek'} kind
   * @param {number} [time] for 'seek'
   */
  request (kind, time) {
    if (!REQUEST_KINDS.includes(kind) || this.isHost) return false
    const payload = { id: generateRandomHexCode(12), kind }
    if (kind === 'seek') {
      if (!isFiniteNumber(time)) return false
      payload.time = time
    }
    this.#myRequests.add(payload.id)
    this.#sendToPeers(new Event(EventTypes.RequestEvent, payload))
    this.#system(describeRequest('You', payload))
    return true
  }

  /**
   * Host: answer a request. When accepted, the player does it as a local action, which sends `player`.
   * @param {string} id
   * @param {boolean} accepted
   */
  answerRequest (id, accepted, timedOut = false) {
    const request = this.requests.value.find(item => item.id === id)
    clearTimeout(this.#requestTimers.get(id))
    this.#requestTimers.delete(id)
    if (!request) return false
    this.requests.update(list => list.filter(item => item.id !== id))
    if (!this.isHost) return false
    this.#sendToPeers(new Event(EventTypes.RequestReplyEvent, { id, accepted: !!accepted, by: this.selfId }))
    this.#system(`You ${accepted ? 'accepted' : timedOut ? 'did not answer' : 'declined'} ${request.name}'s request`)
    if (accepted) this.emit('perform', { kind: request.kind, time: request.time })
    return true
  }

  /** @param {string} emoji one of the protocol reactions */
  react (emoji) {
    const value = normalizeReaction(emoji)
    if (!value) return false
    this.#sendToPeers(new Event(EventTypes.ReactionEvent, { emoji: value }))
    this.#showReaction(this.selfId, value)
    return true
  }

  message (message) {
    debug(`message: ${message}`)
    const text = String(message).slice(0, MAX_MESSAGE_LENGTH)
    this.#push({ message: text, user: this.self, type: 'outgoing', date: new Date() })
    this.#sendToPeers(new Event(EventTypes.MessageEvent, text))
  }

  /** Anonymous user: name shown to the others instead of the id. */
  setDisplayName (name) {
    if (Helper.getUser()) return
    const value = String(name ?? '').trim().slice(0, 32)
    if ((this.self.displayName || '') === value) return
    if (value) this.self.displayName = value
    else delete this.self.displayName
    this.peers.update(peers => peers)
    this.#sendToPeers(new Event(EventTypes.SessionInitEvent, this.#initPayload()))
  }

  /** Display name of a participant ("You" for ourselves). */
  nameOf (userId) {
    if (sameId(userId, this.selfId)) return 'You'
    return memberName(this.#userOf(userId) ?? { id: userId })
  }

  /** The host's expected play / pause state, for "Request pause" vs "Request play". */
  hostPaused () {
    return this.#hostTarget(Date.now())?.paused ?? this.player.paused
  }

  /**
   * Member list with host crown and sync badges, host first then us.
   * @param {number} [now]
   * @returns {MemberView[]}
   */
  describeMembers (now = Date.now()) {
    const signals = this.signals.value
    const hostId = this.hostId
    /** @type {MemberView[]} */
    const list = [{
      userId: this.selfId,
      user: this.self,
      name: memberName(this.self),
      isSelf: true,
      isHost: sameId(hostId, this.selfId),
      badge: selfBadge(this.local),
      protocol: PROTOCOL_VERSION
    }]
    const seen = new Set([this.selfId])
    for (const entry of Object.values(this.peers.value)) {
      const userId = entry.userId
      if (!entry.peer || !userId || seen.has(userId) || this.#banned.has(userId)) continue
      seen.add(userId)
      const signal = { ...(signals[userId] || {}), protocol: entry.protocol, lastSeen: this.#lastSeen.get(userId) }
      list.push({
        userId,
        user: entry.user,
        name: memberName(entry.user),
        isSelf: false,
        isHost: sameId(hostId, userId),
        badge: syncBadge(signal, this.local, now),
        protocol: entry.protocol,
        client: entry.client,
        rtt: signal.rtt
      })
    }
    return list.sort((a, b) => (Number(b.isHost) - Number(a.isHost)) || (Number(b.isSelf) - Number(a.isSelf)) || a.name.localeCompare(b.name))
  }

  destroy () {
    debug('destroy')
    if (this.#destroyed) return
    this.#destroyed = true
    clearInterval(this.#heartbeat)
    clearInterval(this.#pinger)
    clearTimeout(this.#countdownTimer)
    for (const timer of this.#requestTimers.values()) clearTimeout(timer)
    this.#requestTimers.clear()
    this.#p2pt?.destroy()
    this.removeAllListeners()
    this.#p2pt = null
    this.#channels.clear()
    this.peers.value = {}
  }

  // ---------------------------------------------------------------- transport

  #wireEvents () {
    this.#p2pt.on('peerconnect', this.#onPeerconnect.bind(this))
    this.#p2pt.on('msg', this.#onMsg.bind(this))
    this.#p2pt.on('peerclose', this.#onPeerclose.bind(this))
  }

  #initPayload () {
    return { ...this.self, client: SUPPORTS.isAndroid ? 'tsumi-android' : 'tsumi-desktop', protocol: PROTOCOL_VERSION }
  }

  /**
   * @param {import('p2pt').Peer} peer
   * @param {import('./events.js').default} event
   */
  #sendEvent (peer, event) {
    if (!this.#p2pt || !peer) return
    if (!QUIET_EVENTS.has(event.type)) debug(`#sendEvent: ${peer.id} ${JSON.stringify(event)}`)
    // P2PT keeps a resolver for every sent message until the peer answers with the same id,
    // which never happens here. Use our own id and drop the resolver: otherwise the table grows
    // with every heartbeat, and an incoming message whose random id matches an entry is swallowed.
    const msgId = 1_000_000 + Math.floor(Math.random() * 1_000_000_000)
    try {
      this.#p2pt.send(peer, JSON.stringify(event), msgId)?.catch?.(error => debug('send failed', error))
    } catch (error) {
      debug('send failed', error)
    }
    delete this.#p2pt?.responseWaiting?.[peer.id]?.[msgId]
  }

  /** @param {import('./events.js').default} event */
  #sendToPeers (event) {
    if (!this.#p2pt) return
    for (const [peerId, peer] of this.#channels) {
      const userId = this.peers.value[peerId]?.userId
      if ((userId && this.#banned.has(userId)) || this.#bannedPeers.has(peerId)) continue
      this.#sendEvent(peer, event)
    }
  }

  /**
   * Brings a newly connected participant up to date. Should be called only on 'peerconnect'.
   * @param {import('p2pt').Peer} peer
   */
  #sendInitialSessionState (peer) {
    if (this.media) {
      const { media, episode, key } = this.media
      this.#sendEvent(peer, new Event(EventTypes.MediaEvent, { media, episode, key }))
    }
    this.#sendEvent(peer, new Event(EventTypes.MediaIndexEvent, this.index))
    const now = Date.now()
    const time = this.#localTime(now)
    const state = time !== null
      ? { time, paused: this.local.state !== 'playing' && this.local.state !== 'buffering' }
      : this.player
    this.#sendEvent(peer, new Event(EventTypes.PlayerStateEvent, { ...state, by: this.selfId, action: 'sync', rate: this.local.rate }))
  }

  #onPeerconnect (peer) {
    if (this.#destroyed) return
    debug(`#onPeerconnect: ${peer.id}`)
    this.#channels.set(peer.id, peer)
    this.#sendEvent(peer, new Event(EventTypes.SessionInitEvent, this.#initPayload()))
    if (this.isHost) {
      this.#sendEvent(peer, new Event(EventTypes.HostEvent, { hostId: this.selfId, mode: this.mode }))
      this.#sendInitialSessionState(peer)
    }
    this.#sendStatus(peer)
    this.#ping(peer)
  }

  #onPeerclose (peer) {
    if (this.#destroyed) return
    debug(`#onPeerclose: ${peer.id}`)
    this.#channels.delete(peer.id)
    const entry = this.peers.value[peer.id]
    if (!entry) return
    this.peers.update(peers => {
      delete peers[peer.id]
      return peers
    })
    const userId = entry.userId
    if (!userId || this.#hasUser(userId)) return
    this.signals.update(signals => {
      delete signals[userId]
      return signals
    })
    this.#lastSeen.delete(userId)
    if (!this.#banned.has(userId)) this.#system(`${memberName(entry.user)} left`)
    if (sameId(userId, this.hostId)) this.#migrateHost()
  }

  /** Closes every data channel of a transport peer. */
  #closePeer (peerId) {
    const channels = this.#p2pt?.peers?.[peerId] || {}
    for (const channel of [...Object.values(channels), this.#channels.get(peerId)]) {
      try {
        channel?.destroy?.()
      } catch (error) {
        debug('close failed', error)
      }
    }
  }

  /**
   * @param {import('p2pt').Peer} peer
   * @param {Event | string} data
   */
  #onMsg (peer, data) {
    if (this.#destroyed) return
    try {
      data = typeof data === 'string' ? JSON.parse(data) : data
    } catch (error) {
      debug('Ignoring malformed message', error)
      return
    }
    if (!data || typeof data !== 'object' || typeof data.type !== 'string') return
    if (!QUIET_EVENTS.has(data.type)) debug(`#onMsg: ${peer.id} ${JSON.stringify(data)}`)

    const userId = this.#userIdOf(peer)
    if (this.#banned.has(userId) || this.#bannedPeers.has(peer.id)) {
      this.#closePeer(peer.id)
      return
    }
    this.#lastSeen.set(userId, Date.now())
    const payload = data.payload

    switch (data.type) {
      case EventTypes.SessionInitEvent:
        this.#onInit(peer, payload)
        break
      case EventTypes.MediaEvent:
        this.#onMedia(payload)
        break
      case EventTypes.MediaIndexEvent: {
        if (payload?.index == null) break
        if (this.index?.index !== payload.index) {
          this.index = payload
          this.emit('index', payload.index)
        }
        break
      }
      case EventTypes.PlayerStateEvent:
        this.#onPlayer(userId, payload)
        break
      case EventTypes.MessageEvent:
        this.#onMessage(peer, userId, payload)
        break
      case EventTypes.HostEvent:
        this.#onHost(peer, userId, payload)
        break
      case EventTypes.StatusEvent:
        this.#onStatus(userId, payload)
        break
      case EventTypes.PingEvent:
        if (payload != null) this.#sendEvent(peer, new Event(EventTypes.PongEvent, payload))
        break
      case EventTypes.PongEvent:
        this.#onPong(userId, payload)
        break
      case EventTypes.RequestEvent:
        this.#onRequest(userId, payload)
        break
      case EventTypes.RequestReplyEvent:
        this.#onRequestReply(userId, payload)
        break
      case EventTypes.KickEvent:
        this.#onKick(userId, payload)
        break
      case EventTypes.ReactionEvent: {
        const emoji = normalizeReaction(payload?.emoji)
        if (emoji) this.#showReaction(userId, emoji)
        break
      }
      case EventTypes.CountdownEvent:
        this.#onCountdown(userId, payload)
        break
      default:
        debug('Ignoring unknown message type', data)
    }
  }

  // ---------------------------------------------------------------- incoming events

  #onInit (peer, payload) {
    if (!payload || payload.id == null || payload.id === '') return
    const userId = String(payload.id)
    if (this.#banned.has(userId)) {
      this.#bannedPeers.add(peer.id)
      this.#closePeer(peer.id)
      return
    }
    const known = this.#hasUser(userId)
    this.peers.update(peers => {
      peers[peer.id] = {
        peer,
        user: payload,
        userId,
        // A v1 client sends no `protocol`.
        protocol: isFiniteNumber(payload.protocol) ? payload.protocol : 1,
        client: typeof payload.client === 'string' ? payload.client : undefined
      }
      return peers
    })
    this.#lastSeen.set(userId, Date.now())
    if (!known) this.#system(`${memberName(payload)} joined`)
  }

  #onMedia (shared) {
    if (!shared?.media?.id) return
    const localKey = mediaKey(shared)
    // Keep the sender's key so every client of the lobby compares the same string.
    const key = typeof shared.key === 'string' && shared.key ? shared.key : localKey
    if (key === this.media?.key) return
    this.media = { ...shared, key, localKey }
    this.emit('media', this.media)
  }

  #onPlayer (senderId, payload) {
    if (!isFiniteNumber(payload?.time)) return
    const paused = !!payload.paused
    const by = payload.by != null && payload.by !== '' ? String(payload.by) : senderId
    if (this.effectiveMode === 'host' && !sameId(by, this.hostId)) {
      debug(`Ignoring player event of ${by}: only the host controls playback`)
      return
    }
    const now = Date.now()
    const hasAction = ACTIONS.includes(payload.action)
    let action = hasAction ? payload.action : inferAction(this.player, { paused })
    const reference = this.#localTime(now) ?? this.player.time
    // v1 clients echo every state they apply: a "seek" that moves nothing is not announced.
    if (!hasAction && action === 'seek' && isFiniteNumber(reference) && Math.abs(payload.time - reference) < IN_SYNC_S) action = 'sync'
    const rate = normalizeRate(payload.rate)

    this.player = { time: payload.time, paused }
    if (sameId(by, this.hostId)) this.#lastHostPlayer = { time: payload.time, paused, rate, at: now }
    this.#cancelCountdown()
    this.emit('player', { time: payload.time, paused, action, by, rate })

    if (action === 'sync') return
    const delta = action === 'seek' && isFiniteNumber(reference) ? payload.time - reference : null
    const text = describeAction({ name: this.nameOf(by), action, time: payload.time, delta })
    if (!text) return
    this.#system(text)
    this.emit('notice', { text, by, action })
  }

  #onMessage (peer, userId, payload) {
    if (typeof payload !== 'string' || !payload) return
    const message = payload.slice(0, MAX_MESSAGE_LENGTH)
    // A message can arrive before the sender introduced itself.
    const user = this.peers.value[peer.id]?.user || { id: peer.id }
    this.#push({ message, user, type: 'incoming', date: new Date() })
    this.emit('chat', { userId, name: memberName(user), user, message })
  }

  #onHost (peer, senderId, payload) {
    if (payload?.hostId == null || payload.hostId === '') return
    const hostId = String(payload.hostId)
    const mode = normalizeMode(payload.mode)
    const { hostId: current, tentative } = this.lobby.value
    // Accept `host` only from the current host, or from anyone while no host is known.
    if (current != null && !tentative && !sameId(senderId, current)) {
      // Two hosts (after a split): the smallest userId keeps the role.
      const rivalClaim = this.isHost && sameId(hostId, senderId)
      if (!(rivalClaim && senderId < this.selfId)) {
        if (this.isHost) this.#sendEvent(peer, new Event(EventTypes.HostEvent, { hostId: this.selfId, mode: this.mode }))
        return
      }
    }
    this.#setLobby({ hostId, mode, tentative: false })
  }

  #onStatus (userId, payload) {
    const state = normalizeState(payload?.state)
    if (!state || !isFiniteNumber(payload.time)) return
    const now = Date.now()
    const status = {
      state,
      time: payload.time,
      mediaKey: payload.mediaKey == null ? '' : String(payload.mediaKey),
      rate: normalizeRate(payload.rate),
      sentAt: isFiniteNumber(payload.sentAt) ? payload.sentAt : undefined
    }
    this.signals.update(signals => {
      signals[userId] = { ...(signals[userId] || {}), status, receivedAt: now }
      return signals
    })
    if (sameId(userId, this.hostId) && !this.isHost) this.#checkAutoSync(now)
  }

  #onPong (userId, payload) {
    if (!isFiniteNumber(payload?.sentAt)) return
    const rtt = Date.now() - payload.sentAt
    if (rtt < 0 || rtt > 60_000) return
    this.signals.update(signals => {
      signals[userId] = { ...(signals[userId] || {}), rtt }
      return signals
    })
  }

  #onRequest (userId, payload) {
    const kind = payload?.kind
    if (!REQUEST_KINDS.includes(kind) || payload.id == null || payload.id === '') return
    if (kind === 'seek' && !isFiniteNumber(payload.time)) return
    const id = String(payload.id)
    const name = this.nameOf(userId)
    this.#requestOwners.set(id, userId)
    this.#system(describeRequest(name, { kind, time: payload.time }))
    if (!this.isHost || this.#requestTimers.has(id)) return
    /** @type {HostRequest} */
    const request = { id, kind, time: kind === 'seek' ? payload.time : undefined, userId, name, expiresAt: Date.now() + REQUEST_TIMEOUT_MS }
    this.requests.update(list => [...list.filter(item => item.id !== id), request])
    // No answer within 15 s counts as declined.
    this.#requestTimers.set(id, setTimeout(() => this.answerRequest(id, false, true), REQUEST_TIMEOUT_MS))
    this.emit('request', request)
  }

  #onRequestReply (senderId, payload) {
    if (!sameId(senderId, this.hostId) || payload?.id == null) return
    const id = String(payload.id)
    const mine = this.#myRequests.delete(id)
    const owner = this.#requestOwners.get(id)
    this.#requestOwners.delete(id)
    const whose = mine ? 'your' : owner ? `${this.nameOf(owner)}'s` : 'a'
    const text = `${this.nameOf(senderId)} ${payload.accepted ? 'accepted' : 'declined'} ${whose} request`
    this.#system(text)
    if (mine) this.emit('info', { text })
  }

  #onKick (senderId, payload) {
    if (!sameId(senderId, this.hostId) || payload?.userId == null) return
    const target = String(payload.userId)
    if (target === this.selfId) {
      this.emit('kicked')
      return
    }
    this.#ban(target)
  }

  #onCountdown (senderId, payload) {
    if (!sameId(senderId, this.hostId) && this.effectiveMode !== 'everyone') return
    if (!isFiniteNumber(payload?.time) || payload.time < 0) return
    const seconds = normalizeCountdownSeconds(payload.seconds)
    // startAt is on the sender's clock: count from the reception, minus half the trip.
    const rtt = this.signals.value[senderId]?.rtt
    const endsAt = Date.now() + seconds * 1000 - (isFiniteNumber(rtt) ? rtt / 2 : 0)
    this.#runCountdown({ time: payload.time, seconds, endsAt, by: senderId })
    this.#system(`${this.nameOf(senderId)} started a countdown`)
  }

  // ---------------------------------------------------------------- host, sync, helpers

  /** @param {{ hostId: string | null, mode: 'everyone' | 'host', tentative: boolean }} next */
  #setLobby (next) {
    const previous = this.lobby.value
    this.lobby.value = next
    const hostChanged = !sameId(previous.hostId, next.hostId)
    if (hostChanged) {
      this.#autoSync = null
      this.#lastHostPlayer = null
      if (next.hostId != null) this.#system(sameId(next.hostId, this.selfId) ? 'You are now the host' : `${this.nameOf(next.hostId)} is now the host`)
      if (sameId(previous.hostId, this.selfId)) {
        // No longer host: pending requests go to the new host.
        for (const timer of this.#requestTimers.values()) clearTimeout(timer)
        this.#requestTimers.clear()
        this.requests.value = []
      }
    }
    if (previous.mode !== next.mode) this.#system(next.mode === 'host' ? 'Only the host controls playback now' : 'Everyone can control playback now')
  }

  /** The host left: the smallest userId among us and the connected peers takes over. */
  #migrateHost () {
    const elected = electHost([this.selfId, ...this.#connectedUserIds()])
    if (elected === this.selfId) {
      this.#setLobby({ hostId: this.selfId, mode: this.mode, tentative: false })
      this.#sendToPeers(new Event(EventTypes.HostEvent, { hostId: this.selfId, mode: this.mode }))
    } else {
      // Until the elected client confirms with `host`, accept a claim from anyone.
      this.#setLobby({ hostId: elected, mode: this.mode, tentative: true })
    }
  }

  #checkAutoSync (now) {
    const host = this.signals.value[this.hostId]
    const result = autoSyncStep(this.#autoSync, {
      enabled: settings.value.w2gAutoSync !== false,
      isHost: this.isHost,
      hostStatus: host?.status,
      hostReceivedAt: host?.receivedAt,
      hostRtt: host?.rtt,
      local: this.local,
      now
    })
    this.#autoSync = result
    if (result.seekTo === null) return
    debug(`auto-sync to ${result.seekTo}`)
    this.#applyLocally({ time: result.seekTo, paused: false, action: 'sync', by: this.hostId })
  }

  /** Applies a state to our player without broadcasting or announcing it. */
  #applyLocally ({ time, paused, action, by }) {
    this.player = { time, paused }
    this.emit('player', { time, paused, action, by, rate: 1 })
  }

  #hostTarget (now) {
    if (this.hostId == null || this.isHost) return null
    const host = this.signals.value[this.hostId]
    return hostReference({ status: host?.status, receivedAt: host?.receivedAt, rtt: host?.rtt, lastPlayer: this.#lastHostPlayer }, now)
  }

  /** Our position now, null when we are not watching. */
  #localTime (now) {
    if (this.local.state === 'idle' || this.local.state === 'loading') return null
    return expectedTime(this.local, this.local.at, now)
  }

  #runCountdown ({ time, seconds, endsAt, by }) {
    this.#cancelCountdown()
    this.#applyLocally({ time, paused: true, action: 'sync', by })
    const countdown = { time, seconds, endsAt, by }
    this.countdown.value = countdown
    this.emit('countdown', countdown)
    this.#countdownTimer = setTimeout(() => {
      this.#countdownTimer = null
      this.countdown.value = null
      this.#applyLocally({ time, paused: false, action: 'sync', by })
    }, Math.max(0, endsAt - Date.now()))
  }

  #cancelCountdown () {
    if (!this.#countdownTimer) return
    clearTimeout(this.#countdownTimer)
    this.#countdownTimer = null
    this.countdown.value = null
  }

  #sendStatus (peer) {
    const now = Date.now()
    const event = new Event(EventTypes.StatusEvent, {
      state: this.local.state,
      time: Math.max(0, expectedTime(this.local, this.local.at, now) ?? 0),
      mediaKey: this.local.mediaKey,
      rate: this.local.rate,
      sentAt: now
    })
    if (peer) this.#sendEvent(peer, event)
    else this.#sendToPeers(event)
  }

  #pingAll () {
    for (const peer of this.#channels.values()) this.#ping(peer)
  }

  #ping (peer) {
    this.#sendEvent(peer, new Event(EventTypes.PingEvent, { id: generateRandomHexCode(8), sentAt: Date.now() }))
  }

  #ban (userId) {
    if (this.#banned.has(userId)) return
    const user = this.#userOf(userId)
    this.#banned.add(userId)
    for (const [peerId, entry] of Object.entries(this.peers.value)) {
      if (!entry.peer || entry.userId !== userId) continue
      this.#bannedPeers.add(peerId)
      this.#closePeer(peerId)
    }
    this.peers.update(peers => {
      for (const [peerId, entry] of Object.entries(peers)) if (entry.peer && entry.userId === userId) delete peers[peerId]
      return peers
    })
    this.signals.update(signals => {
      delete signals[userId]
      return signals
    })
    this.#system(`${memberName(user ?? { id: userId })} was removed from the lobby`)
  }

  #showReaction (userId, emoji) {
    const isSelf = sameId(userId, this.selfId)
    const name = this.nameOf(userId)
    this.#system(`${name} reacted ${emoji}`, { emoji })
    this.emit('reaction', { emoji, userId, name, isSelf })
  }

  #userIdOf (peer) {
    return this.peers.value[peer.id]?.userId ?? String(peer.id)
  }

  #userOf (userId) {
    if (sameId(userId, this.selfId)) return this.self
    for (const entry of Object.values(this.peers.value)) if (entry.peer && sameId(entry.userId, userId)) return entry.user
    return null
  }

  #hasUser (userId) {
    return Object.values(this.peers.value).some(entry => entry.peer && sameId(entry.userId, userId))
  }

  #connectedUserIds () {
    const ids = new Set()
    for (const entry of Object.values(this.peers.value)) if (entry.peer && entry.userId && !this.#banned.has(entry.userId)) ids.add(entry.userId)
    return [...ids]
  }

  /** @param {ChatEntry} entry */
  #push (entry) {
    this.messages.update(messages => {
      const next = [...messages, entry]
      return next.length > MAX_MESSAGES ? next.slice(-MAX_MESSAGES) : next
    })
  }

  /** Local chat line (joins, leaves, actions, requests). */
  #system (message, extra = {}) {
    this.#push({ message, user: null, type: SYSTEM_MESSAGE, date: new Date(), ...extra })
  }
}
