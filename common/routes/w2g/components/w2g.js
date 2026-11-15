import { EventEmitter } from 'events'

import P2PT from 'p2pt'

import Event, { EventTypes, SYSTEM_MESSAGE } from '@/routes/w2g/components/events.js'
import {
  PROTOCOL_VERSION, HEARTBEAT_MS, PING_MS, REQUEST_TIMEOUT_MS, IN_SYNC_S, ACTIONS, REQUEST_KINDS,
  isFiniteNumber, sameId, normalizeMode, normalizeState, normalizeRate, normalizeReaction, normalizeCountdownSeconds,
  memberName, expectedTime, syncBadge, selfBadge, autoSyncStep, hostReference, inferAction,
  describeAction, describeRequest, presenceOnStatus, presenceOnTick, describePresence, canInvite, acceptsInvite,
  inviteTarget, formatSource, normalizeNowPlaying, episodeLabelFor, pickFollowingHost, electFollowingHost,
  followBackAction, episodeLabelOf, lobbyReference, canJoinPlayback, offeredMedia, invitePosition, autoStartsMedia,
  appliesCountdown, FEATURES, normalizeFeatures, normalizeVoice, voiceOffers, voiceLinkAction, acceptsVoiceOffer, duckLevel,
  emptyQueue, normalizeQueue, queueReduce, queueChanges, sameQueueEntry, describeQueueChange, queueItemLabel, nextEpisodeTarget, acceptsQueue,
  QUEUE_ADVANCE_S, QUEUE_COUNTDOWN_S
} from '@/routes/w2g/components/sync.js'
import { VoiceEngine, voiceDuck } from '@/routes/w2g/components/voice.js'
import Helper from '@/modules/helper.js'
import { settings } from '@/modules/settings.js'
import { SUPPORTS } from '@/modules/support.js'
import { generateRandomHexCode } from '@/modules/util.js'
import { writable } from 'simple-store-svelte'
import Debug from 'debug'
const debug = Debug('ui:w2g')

/**
 * @typedef {import('@/modules/al.d.ts').Viewer | { id: string, displayName?: string }} W2GUser
 * @typedef {Record<string, { user: W2GUser, peer?: import('p2pt').Peer<any>, userId?: string, protocol?: number, client?: string, features?: string[] }>} PeerList
 * @typedef {{ media: object, episode: number | { number: number, season?: number, localEpisode?: number }, key: string }} SharedMedia
 * @typedef {{ message: string, user: W2GUser | null, type: 'incoming' | 'outgoing' | 'system', date: Date, emoji?: string }} ChatEntry
 * @typedef {{ status?: import('./sync.js').Status & { sentAt?: number, source?: string }, receivedAt?: number, rtt?: number, pongAt?: number, joinedAt?: number }} Signal
 * @typedef {{ id: string, kind: 'pause' | 'play' | 'seek', time?: number, userId: string, name: string, expiresAt: number }} HostRequest
 * @typedef {{ from: string, name: string, media: any, episode: SharedMedia['episode'], key: string, time: number, paused: boolean, receivedAt: number }} Invite
 * @typedef {{ joined: boolean, muted: boolean, speaking: boolean, link?: 'connecting' | 'connected' | null, localMuted?: boolean, volume?: number }} MemberVoice
 * @typedef {{ userId: string, user: W2GUser, name: string, isSelf: boolean, isHost: boolean, badge: import('./sync.js').Badge, protocol?: number, client?: string, rtt?: number, source?: string, canInvite?: boolean, voice?: MemberVoice, hasVoice?: boolean }} MemberView
 * @typedef {{ joined: boolean, starting: boolean, hasMic: boolean, muted: boolean, pushToTalk: boolean, held: boolean, transmitting: boolean, speaking: boolean, error: string | null }} VoiceView
 */

/** v2.4 `voice` payload while not in voice. */
const VOICE_OFF = { joined: false, muted: true, speaking: false }

/** A joined invite seeks once its episode is loaded, if that happens within 2 minutes. */
const JOIN_TTL_MS = 120_000
/** v2.3: the one-time "join the current playback" prompt is for a lobby already watching when we arrive. */
const FIRST_JOIN_WINDOW_MS = 20_000
/** v2.3 "Invite everyone not watching": one invite every 200 ms. */
const INVITE_ALL_GAP_MS = 200

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
 * - 'invite' (Invite) / 'inviteRemoved' (from): someone invites us to watch, the prompt was answered
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
  local = { state: 'idle', time: 0, mediaKey: '', rate: 1, source: '', at: Date.now() }
  /** @type {import('simple-store-svelte').Writable<import('./sync.js').LocalStatus>} same as `local`, updated on state changes only */
  localStatus = writable({ ...this.local })
  /** @type {import('simple-store-svelte').Writable<HostRequest[]>} requests waiting for the host's answer */
  requests = writable([])
  /** @type {import('simple-store-svelte').Writable<Invite[]>} invites to watch, one per sender, until joined or dismissed */
  invites = writable([])
  /** @type {import('simple-store-svelte').Writable<boolean>} v2.2: false while watching on our own ("Watch on my own") */
  following = writable(settings.value.w2gWatchOnMyOwn !== true)
  /** @type {import('simple-store-svelte').Writable<SharedMedia | null>} lobby media offered by "Rejoin" after following again */
  rejoinOffer = writable(null)
  /** @type {import('simple-store-svelte').Writable<{ time: number, seconds: number, endsAt: number, by: string } | null>} */
  countdown = writable(null)
  /** @type {import('simple-store-svelte').Writable<VoiceView>} v2.4 our voice state */
  voice = writable({ joined: false, starting: false, hasMic: false, muted: false, pushToTalk: false, held: false, transmitting: false, speaking: false, error: null })
  /** @type {import('simple-store-svelte').Writable<Record<string, { joined: boolean, muted: boolean, speaking: boolean }>>} last `voice` per userId */
  voiceStates = writable({})
  /** @type {import('simple-store-svelte').Writable<Record<string, 'connecting' | 'connected'>>} audio link per userId */
  voiceLinks = writable({})
  /** @type {import('simple-store-svelte').Writable<import('./sync.js').Queue>} v2.4 "Up next", owned by the host */
  queue = writable(emptyQueue())
  /** @type {import('simple-store-svelte').Writable<{ item: import('./sync.js').QueueItem, endsAt: number } | null>} host: auto-advance countdown */
  advance = writable(null)

  /** @type {VoiceEngine} */
  #voice
  #lastVoicePayload = VOICE_OFF
  /** A `queue` was received (or we created the lobby): changes are announced from then on. */
  #queueKnown = false
  /** @type {Set<string>} our own suggestions we removed (not "declined") */
  #queueCancelled = new Set()
  #advanceTimer = null
  /** @type {{ key: string, at: number } | null} host: a queued item was started, count down once it is loaded */
  #pendingQueueStart = null
  #unsubscribeSettings = null

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
  /** @type {Map<string, import('./sync.js').Presence>} presence announcements state per userId */
  #presence = new Map()
  /** @type {SharedMedia | null} what we started last (lobby media, our own launch, joined invite) */
  #launched = null
  /** @type {{ key: string, at: number } | null} "Rejoin" used: sync to the host once that episode is loaded */
  #pendingRejoin = null
  /** @type {(Invite & { joinedAt: number }) | null} joined invite, seeks once its episode is loaded */
  #pendingJoin = null
  #countdownTimer = null
  #heartbeat = null
  #pinger = null
  #presenceTicker = null
  #destroyed = false
  /** @type {number | null} when the first peer introduced itself (start of the first-join window) */
  #firstPeerAt = null
  /** v2.3: the first-connection Join prompt was shown (or its window passed); never for the lobby creator */
  #joinPrompted = false
  /** @type {Set<ReturnType<typeof setTimeout>>} */
  #inviteTimers = new Set()

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
    return this.effectiveMode === 'host' && !this.isHost && this.isFollowing
  }

  /** v2.2: false while watching on our own. */
  get isFollowing () {
    return this.following.value
  }

  /** mediaKey of what we started last, captured by the player when a file starts. */
  get launchedKey () {
    // Not the lobby media as a fallback: a lobby media received but not started (v2.3 newcomer) is not ours.
    return this.#launched?.key || ''
  }

  /** "Start together" is for the host, or for anyone in `everyone` mode. */
  get canCountdown () {
    return this.isFollowing && (this.isHost || this.effectiveMode === 'everyone')
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
    this.#joinPrompted = !code
    this.#queueKnown = !code

    // v2.4 voice chat: the engine does the audio, the lobby decides who to link with.
    this.#voice = new VoiceEngine({ wantsOffer: userId => this.#voice.joined && voiceOffers(this.selfId, userId) && this.#memberInVoice(userId) })
    this.#voice.on('state', () => this.#onVoiceEngineState())
    this.#voice.on('signal', ({ userId, payload }) => this.#sendToUser(userId, new Event(EventTypes.VoiceSignalEvent, payload)))
    this.#voice.on('links', () => {
      this.voiceLinks.value = this.#voice.linkStates()
      this.#updateDuck()
    })
    // Push-to-talk and ducking settings apply at once.
    this.#unsubscribeSettings = settings.subscribe(() => {
      if (this.#destroyed) return
      this.#voice.refresh()
      this.#updateDuck()
    })

    debug(`W2GClient: ${this.code}, ${this.isHost}`)

    this.#p2pt = new P2PT(W2GClient.#signalingServers, this.code)

    this.#wireEvents()
    this.#p2pt.start()
    this.#heartbeat = setInterval(() => this.#sendStatus(), HEARTBEAT_MS)
    this.#pinger = setInterval(() => this.#pingAll(), PING_MS)
    this.#presenceTicker = setInterval(() => this.#tickPresence(), 1000)
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
    if (this.media?.key === key || this.media?.localKey === key) {
      this.#launched = { media: this.media.media, episode: this.media.episode, key: this.media.key }
      return
    }
    this.#launched = { media, episode, key }
    // Watching on our own: never drag the others.
    if (!this.isFollowing) return
    this.media = { media, episode, key, localKey: key }
    this.#sendToPeers(new Event(EventTypes.MediaEvent, { media, episode, key }))
  }

  /** @param {{ index: number }} index */
  mediaIndexChanged (index) {
    debug(`mediaIndexChanged: ${JSON.stringify(this.index)} ${JSON.stringify(index)}`)
    if (!this.isFollowing) return
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
    // Watching on our own: not broadcast, never snapped back.
    if (!this.isFollowing) return false

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
   * @param {{ state: string, time: number, mediaKey?: string, rate?: number, source?: string,
   *   nowPlaying?: { mediaId?: unknown, title?: string, episode?: unknown, format?: string, episodes?: number } | null }} status
   *   source: "Extension · Server" the stream comes from, empty when unknown;
   *   nowPlaying: what the player has open, the episode label is built here
   * @param {{ force?: boolean }} [options] force: send even without a state change (seek done)
   */
  setLocalStatus ({ state, time, mediaKey, rate, source, nowPlaying }, { force = false } = {}) {
    const key = mediaKey ? String(mediaKey) : ''
    const launched = this.#launched?.key === key ? this.#launched : null
    const playerState = normalizeState(state) || 'idle'
    const next = {
      state: playerState,
      time: isFiniteNumber(time) ? time : 0,
      mediaKey: key,
      rate: normalizeRate(rate),
      source: formatSource(source),
      nowPlaying: playerState !== 'idle' && nowPlaying
        ? normalizeNowPlaying({
          mediaId: nowPlaying.mediaId ?? launched?.media?.id ?? null,
          title: nowPlaying.title,
          // The shared episode knows the season ("S2 E5").
          episode: episodeLabelFor({ episode: launched?.episode ?? nowPlaying.episode, format: nowPlaying.format, episodes: nowPlaying.episodes })
        })
        : null,
      at: Date.now()
    }
    const previous = this.local
    this.local = next
    const changed = previous.state !== next.state || previous.mediaKey !== next.mediaKey || previous.rate !== next.rate ||
      previous.source !== next.source || JSON.stringify(previous.nowPlaying ?? null) !== JSON.stringify(next.nowPlaying)
    // Started the lobby episode ourselves: no need to offer "Rejoin" anymore.
    if (next.mediaKey && this.rejoinOffer.value?.key === next.mediaKey) this.rejoinOffer.value = null
    if (changed) this.localStatus.value = { ...next }
    if (changed || force) this.#sendStatus()
  }

  /** Cheap position update from the player's timeupdate. */
  updateLocalTime (time) {
    if (!isFiniteNumber(time)) return
    this.local.time = time
    this.local.at = Date.now()
  }

  /**
   * The player finished loading a file. After joining an invite: seek to the host if it is on the
   * same episode, else to the inviter. Otherwise follow the host if it watches the same thing.
   */
  playerReady () {
    const now = Date.now()
    // v2.4: a queued item the host started is loaded: the existing countdown starts everyone together.
    const queued = this.#pendingQueueStart
    if (queued && now - queued.at > JOIN_TTL_MS) this.#pendingQueueStart = null
    else if (queued && queued.key === this.local.mediaKey) {
      this.#pendingQueueStart = null
      // Once the player reported its loaded state (position, play / pause).
      const timer = setTimeout(() => {
        this.#inviteTimers.delete(timer)
        if (!this.#destroyed && this.isHost && this.local.mediaKey === queued.key) this.startTogether(QUEUE_COUNTDOWN_S)
      }, 300)
      this.#inviteTimers.add(timer)
      return
    }
    const join = this.#pendingJoin
    if (join && now - join.joinedAt > JOIN_TTL_MS) this.#pendingJoin = null
    else if (join && join.key === this.local.mediaKey) {
      this.#pendingJoin = null
      if (join.kind === 'lobby') {
        // v2.3 Join: the reference's expected time and play / pause state, read now that we are loaded.
        const reference = this.#lobbyReferenceId()
        const target = sameId(reference, this.selfId) ? null : this.#memberPosition(reference, now)
        if (target) this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: reference })
        return
      }
      const target = inviteTarget({ invite: join, host: this.isHost ? null : this.#hostTarget(now), now })
      this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: target.from === 'host' ? this.hostId : join.from })
      return
    }
    if (!this.isFollowing) return
    const rejoin = this.#pendingRejoin
    if (rejoin && (now - rejoin.at > JOIN_TTL_MS || rejoin.key === this.local.mediaKey)) {
      this.#pendingRejoin = null
      // "Rejoin" then syncs, whatever the auto-sync setting.
      if (rejoin.key === this.local.mediaKey) {
        this.#syncToHost(now)
        return
      }
    }
    if (this.isHost || this.hostId == null) return
    if (this.effectiveMode !== 'host' && settings.value.w2gAutoSync === false) return
    const target = this.#hostTarget(Date.now())
    if (!target || target.mediaKey === null || target.mediaKey !== this.local.mediaKey) return
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostId })
  }

  /** Manual "Resync": jump to the host's expected position and state now. */
  resync () {
    if (this.isHost || !this.isFollowing) return false
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
    if (!this.isHost || !this.isFollowing) return false
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

  /**
   * "Invite to watch": ask a member to play what we play, at our position.
   * Anyone in `everyone` mode, the host only in `host` mode.
   */
  invite (userId) {
    const target = String(userId)
    if (target === this.selfId || !this.#hasUser(target)) return false
    if (this.effectiveMode === 'host' && !this.isHost) return false
    // v2.3: our own media when we play one, else the lobby media while the lobby is watching.
    const offer = this.#offer(Date.now())
    if (!offer?.position) return false
    const { media, position } = offer
    this.#sendToPeers(new Event(EventTypes.InviteEvent, { to: target, media: media.media, episode: media.episode, key: media.key, time: position.time, paused: position.paused, by: this.selfId }))
    this.#system(`You invited ${this.nameOf(target)}`)
    return true
  }

  /** v2.3 host tool "Invite everyone not watching": one invite per eligible member, 200 ms apart. */
  inviteAllNotWatching () {
    if (!this.isHost) return 0
    const targets = this.describeMembers().filter(member => member.canInvite).map(member => member.userId)
    targets.forEach((userId, index) => {
      const timer = setTimeout(() => {
        this.#inviteTimers.delete(timer)
        if (!this.#destroyed) this.invite(userId)
      }, index * INVITE_ALL_GAP_MS)
      this.#inviteTimers.add(timer)
    })
    return targets.length
  }

  /**
   * v2.3: the Join card, while the lobby is watching and we are not on its media.
   * @returns {{ key: string, media: any, episode: SharedMedia['episode'], referenceId: string, name: string } | null}
   */
  joinOffer () {
    const media = this.media
    const reference = this.#lobbyReferenceId()
    if (!canJoinPlayback({ reference, selfId: this.selfId, lobbyKey: media?.key, local: this.local, following: this.isFollowing })) return null
    return { key: media.key, media: media.media, episode: media.episode, referenceId: reference, name: this.nameOf(reference) }
  }

  /**
   * v2.3 Join: play the lobby media like a received `media` (even with an unchanged key), then once
   * loaded seek to the reference and take its play / pause state. Follows the lobby again if needed.
   */
  joinPlayback () {
    const media = this.media
    if (!media) return false
    if (!this.isFollowing) {
      settings.update(current => ({ ...current, w2gWatchOnMyOwn: false }))
      this.following.value = true
      this.#autoSync = null
      this.#system('You follow the lobby again')
    }
    this.rejoinOffer.value = null
    this.#pendingRejoin = null
    this.#launched = { media: media.media, episode: media.episode, key: media.key }
    this.#pendingJoin = { kind: 'lobby', key: media.key, joinedAt: Date.now() }
    this.#sendStatus()
    this.emit('joinableRemoved')
    this.emit('media', media)
    return true
  }

  /** Join an invite: play its episode like a received `media`, even when the key did not change, then seek. */
  joinInvite (from) {
    const invite = this.invites.value.find(item => item.from === from)
    if (!invite) return false
    this.#removeInvite(from)
    const shared = { media: invite.media, episode: invite.episode, key: invite.key, localKey: mediaKey(invite) }
    // Following: it becomes the lobby media like a received `media`. On our own: only played here.
    if (this.isFollowing) this.media = shared
    this.#launched = { media: invite.media, episode: invite.episode, key: invite.key }
    this.#pendingJoin = { ...invite, joinedAt: Date.now() }
    this.emit('media', shared)
    return true
  }

  /**
   * v2.2 "Watch on my own" toggle, remembered for the next lobby. Off: a host hands the role to the
   * smallest following v2 peer first. On again: resync if we play the lobby episode, else offer "Rejoin".
   * @param {boolean} value true to follow the lobby
   */
  setFollowing (value) {
    const next = !!value
    if (next === this.isFollowing) return false
    settings.update(current => ({ ...current, w2gWatchOnMyOwn: !next }))
    if (!next) {
      if (this.isHost) {
        const target = pickFollowingHost(this.#peerSummaries())
        if (target) this.transferHost(target)
      }
      this.#cancelCountdown()
      this.following.value = false
      this.rejoinOffer.value = null
      this.#pendingRejoin = null
      this.#sendStatus()
      this.#system('You are watching on your own')
      return true
    }
    this.following.value = true
    this.#autoSync = null
    this.#sendStatus()
    this.#system('You follow the lobby again')
    const action = followBackAction({ localKey: this.local.state === 'idle' ? '' : this.local.mediaKey, lobbyKey: this.media?.key })
    if (action === 'resync') this.#syncToHost(Date.now())
    else if (action === 'rejoin') this.rejoinOffer.value = { media: this.media.media, episode: this.media.episode, key: this.media.key }
    return true
  }

  /** "Rejoin {title · episode}": start the lobby media like a received `media`, then sync. */
  rejoin () {
    const media = this.media
    if (!media || !this.isFollowing) return false
    this.rejoinOffer.value = null
    this.#launched = { media: media.media, episode: media.episode, key: media.key }
    this.#pendingRejoin = { key: media.key, at: Date.now() }
    this.emit('media', media)
    return true
  }

  /** Label of a shared media's episode, for prompts. */
  episodeLabel (episode) {
    return episodeLabelOf(episode) ?? ''
  }

  /** Dismiss an invite prompt. */
  dismissInvite (from) {
    return this.#removeInvite(from)
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
      badge: this.isFollowing || this.local.state === 'idle' ? selfBadge(this.local) : { kind: 'own', text: 'Watching on your own' },
      protocol: PROTOCOL_VERSION,
      source: this.local.source,
      nowPlaying: this.local.nowPlaying ?? null,
      following: this.isFollowing,
      hasVoice: true,
      voice: { ...this.#voice.payload, link: null }
    }]
    const voiceStates = this.voiceStates.value
    const links = this.voiceLinks.value
    const seen = new Set([this.selfId])
    const invite = {
      offeredKey: this.#offered().offered?.key ?? null,
      effectiveMode: this.effectiveMode,
      isHost: this.isHost,
      now
    }
    for (const entry of Object.values(this.peers.value)) {
      const userId = entry.userId
      if (!entry.peer || !userId || seen.has(userId) || this.#banned.has(userId)) continue
      seen.add(userId)
      const signal = { ...(signals[userId] || {}), protocol: entry.protocol, lastSeen: this.#lastSeen.get(userId) }
      const badge = syncBadge(signal, this.local, now)
      list.push({
        userId,
        user: entry.user,
        name: memberName(entry.user),
        isSelf: false,
        isHost: sameId(hostId, userId),
        badge,
        protocol: entry.protocol,
        client: entry.client,
        rtt: signal.rtt,
        source: signal.status?.source || '',
        nowPlaying: signal.status?.nowPlaying ?? null,
        following: signal.status?.following !== false,
        canInvite: canInvite({ ...invite, member: { isSelf: false, protocol: entry.protocol, badge, status: signal.status, joinedAt: signal.joinedAt } }),
        hasVoice: !!entry.features?.includes('voice'),
        voice: { ...(voiceStates[userId] ?? VOICE_OFF), link: links[userId] ?? null, localMuted: this.#voice.mixOf(userId).muted, volume: this.#voice.mixOf(userId).volume }
      })
    }
    return list.sort((a, b) => (Number(b.isHost) - Number(a.isHost)) || (Number(b.isSelf) - Number(a.isSelf)) || a.name.localeCompare(b.name))
  }

  // ---------------------------------------------------------------- v2.4 voice chat

  /** We are in voice. */
  get voiceJoined () {
    return this.#voice.joined
  }

  /** "Join voice": opens the microphone (or listens only without one), then links with the members in voice. */
  async joinVoice () {
    if (this.#destroyed) return false
    await this.#voice.join()
    if (!this.#voice.joined) return false
    this.#system(this.#voice.hasMic ? 'You joined voice' : 'You joined voice (listening only)')
    return true
  }

  leaveVoice () {
    if (!this.#voice.joined && !this.voice.value.starting) return false
    this.#voice.leave()
    this.#system('You left voice')
    return true
  }

  setVoiceMuted (muted) {
    this.#voice.setMuted(muted)
  }

  /** Push-to-talk key held (true) or released. */
  setPushToTalkHeld (held) {
    this.#voice.setHeld(held)
  }

  /**
   * Local mute / volume (0-1) of a member's voice, only for us.
   * @param {string} userId
   * @param {{ muted?: boolean, volume?: number }} mix
   */
  setMemberVoice (userId, mix) {
    this.#voice.setMix(String(userId), mix)
  }

  // ---------------------------------------------------------------- v2.4 shared queue

  /** The queue exists: we are the host, or the host's app supports it. */
  get queueAvailable () {
    return this.isHost || (this.hostId != null && this.#hasFeature(this.hostId, 'queue'))
  }

  /**
   * "Add to Watch Together queue": the host adds it at once, a member sends it to the host (a suggestion when the host
   * asks for approval).
   * @param {{ media: any, episode: SharedMedia['episode'], title?: string, cover?: string }} entry media: the shared media shape (session.js pickMedia)
   * @returns {'added' | 'suggested' | 'duplicate' | null} null when there is no queue
   */
  addToQueue ({ media, episode, title, cover }) {
    if (!media?.id || episode == null || !this.queueAvailable) return null
    const key = mediaKey({ media, episode })
    if ([...this.queue.value.items, ...this.queue.value.pending].some(item => sameQueueEntry(item, { key, media, episode }))) return 'duplicate'
    const item = {
      id: generateRandomHexCode(12),
      media,
      episode,
      key,
      title: (title || media.title?.userPreferred || media.title?.english || media.title?.romaji || '').slice(0, 120),
      cover: (cover || media.coverImage?.medium || media.coverImage?.extraLarge || '').slice(0, 500),
      addedBy: this.selfId,
      addedByName: memberName(this.self)
    }
    if (this.isHost) return this.#hostQueueChange({ type: 'add', item, by: this.selfId, byName: memberName(this.self), byHost: true }) ? 'added' : 'duplicate'
    if (!this.#sendToUser(this.hostId, new Event(EventTypes.QueueAddEvent, { item }))) return null
    return this.queue.value.policy === 'approval' ? 'suggested' : 'added'
  }

  /** "Add next episode": the episode after the lobby media (or after the last queued one of that title). */
  nextEpisodeOffer () {
    return nextEpisodeTarget({ lobby: this.media, queue: this.queue.value })
  }

  /** @param {string} [title] display title of the lobby media */
  addNextEpisode (title) {
    const target = this.nextEpisodeOffer()
    if (!target) return null
    return this.addToQueue({ media: target.media, episode: target.episode, title })
  }

  /** Up-vote toggle on an item. */
  voteQueueItem (id) {
    const item = this.queue.value.items.find(entry => entry.id === id)
    if (!item || !this.queueAvailable) return false
    const up = !item.votes.includes(this.selfId)
    if (this.isHost) return this.#hostQueueChange({ type: 'vote', id, by: this.selfId, up })
    this.#sendToUser(this.hostId, new Event(EventTypes.QueueVoteEvent, { id, up }))
    return true
  }

  /** The host removes any item; a member removes its own item or suggestion. */
  removeQueueItem (id) {
    if (this.isHost) return this.#hostQueueChange({ type: 'remove', id, by: this.selfId, byHost: true })
    const item = [...this.queue.value.items, ...this.queue.value.pending].find(entry => entry.id === id)
    if (!item || !sameId(item.addedBy, this.selfId)) return false
    this.#queueCancelled.add(id)
    this.#sendToUser(this.hostId, new Event(EventTypes.QueueRemoveEvent, { id }))
    return true
  }

  /** Host: move an item up (-1) or down (+1). */
  moveQueueItem (id, delta) {
    return this.isHost && this.#hostQueueChange({ type: 'move', id, delta })
  }

  /** Host: accept or decline a suggestion. */
  answerSuggestion (id, accepted) {
    return this.isHost && this.#hostQueueChange({ type: 'answer', id, accepted: !!accepted })
  }

  /** Host: "Members need approval". @param {'open' | 'approval'} policy */
  setQueuePolicy (policy) {
    return this.isHost && this.#hostQueueChange({ type: 'policy', policy })
  }

  /** Host "Play now": the item becomes the lobby media and starts here; a countdown follows once it is loaded. */
  playQueueItem (id) {
    if (!this.isHost || !this.isFollowing) return false
    const item = this.queue.value.items.find(entry => entry.id === id)
    if (!item) return false
    this.cancelAdvance()
    this.#hostQueueChange({ type: 'remove', id, by: this.selfId, byHost: true })
    const shared = { media: item.media, episode: item.episode, key: item.key }
    this.media = { ...shared, localKey: mediaKey(item) }
    this.#launched = { ...shared }
    this.rejoinOffer.value = null
    this.#pendingRejoin = null
    this.#pendingJoin = null
    this.#pendingQueueStart = { key: item.key, at: Date.now() }
    this.#sendToPeers(new Event(EventTypes.MediaEvent, shared))
    this.#system(`You started ${queueItemLabel(item)} from Up next`)
    this.emit('media', this.media)
    return true
  }

  /**
   * The player reached the end of the episode. Host with a queued item: "Up next" counts down 5 s, then plays it.
   * @returns {boolean} true when an auto-advance started
   */
  episodeEnded () {
    const item = this.isHost && this.isFollowing ? this.queue.value.items[0] : null
    if (!item || this.advance.value) return false
    this.advance.value = { item, endsAt: Date.now() + QUEUE_ADVANCE_S * 1000 }
    this.#advanceTimer = setTimeout(() => {
      this.#advanceTimer = null
      this.advanceNow()
    }, QUEUE_ADVANCE_S * 1000)
    return true
  }

  /** "Play now" of the auto-advance prompt (also when its countdown ends). */
  advanceNow () {
    const advance = this.advance.value
    this.cancelAdvance()
    if (advance) this.playQueueItem(advance.item.id)
  }

  cancelAdvance () {
    clearTimeout(this.#advanceTimer)
    this.#advanceTimer = null
    if (this.advance.value) this.advance.value = null
  }

  destroy () {
    debug('destroy')
    if (this.#destroyed) return
    this.#destroyed = true
    clearInterval(this.#heartbeat)
    clearInterval(this.#pinger)
    clearInterval(this.#presenceTicker)
    for (const timer of this.#inviteTimers) clearTimeout(timer)
    this.#inviteTimers.clear()
    this.#presence.clear()
    clearTimeout(this.#advanceTimer)
    this.#unsubscribeSettings?.()
    this.#voice.destroy()
    voiceDuck.value = 1
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
    return { ...this.self, client: SUPPORTS.isAndroid ? 'tsumi-android' : 'tsumi-desktop', protocol: PROTOCOL_VERSION, features: [...FEATURES] }
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
      // v2.4: late joiners get the current queue.
      this.#sendEvent(peer, new Event(EventTypes.QueueEvent, this.queue.value))
    }
    this.#sendStatus(peer)
    this.#sendEvent(peer, new Event(EventTypes.VoiceEvent, this.#voice.payload))
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
    this.#presence.delete(userId)
    this.#forgetVoice(userId)
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
        this.#onMedia(userId, payload)
        break
      case EventTypes.MediaIndexEvent: {
        if (payload?.index == null) break
        if (this.index?.index !== payload.index) {
          this.index = payload
          if (this.#appliesLobbyState(userId) && this.local.mediaKey === this.media?.key) this.emit('index', payload.index)
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
      case EventTypes.InviteEvent:
        this.#onInvite(userId, payload)
        break
      case EventTypes.VoiceEvent:
        this.#onVoice(userId, payload)
        break
      case EventTypes.VoiceSignalEvent:
        this.#onVoiceSignal(userId, payload)
        break
      case EventTypes.QueueEvent:
        this.#onQueue(userId, payload)
        break
      case EventTypes.QueueAddEvent:
        if (this.isHost) this.#hostQueueChange({ type: 'add', item: payload?.item, by: userId, byName: this.nameOf(userId), byHost: false })
        break
      case EventTypes.QueueVoteEvent:
        if (this.isHost && payload?.id != null) this.#hostQueueChange({ type: 'vote', id: String(payload.id), by: userId, up: payload.up === true })
        break
      case EventTypes.QueueRemoveEvent:
        if (this.isHost && payload?.id != null) this.#hostQueueChange({ type: 'remove', id: String(payload.id), by: userId, byHost: false })
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
        client: typeof payload.client === 'string' ? payload.client : undefined,
        // v2.4: what the client can do ("voice", "queue").
        features: normalizeFeatures(payload.features)
      }
      return peers
    })
    this.#lastSeen.set(userId, Date.now())
    if (this.#firstPeerAt === null) this.#firstPeerAt = Date.now()
    if (!known) {
      this.signals.update(signals => {
        signals[userId] = { ...(signals[userId] || {}), joinedAt: Date.now() }
        return signals
      })
      this.#system(`${memberName(payload)} joined`)
    }
  }

  #onMedia (senderId, shared) {
    if (!shared?.media?.id) return
    const localKey = mediaKey(shared)
    // Keep the sender's key so every client of the lobby compares the same string.
    const key = typeof shared.key === 'string' && shared.key ? shared.key : localKey
    if (key === this.media?.key) return
    this.media = { ...shared, key, localKey }
    // Watching on our own: remember the lobby media for "Rejoin", but do not start it.
    if (!this.isFollowing) {
      if (this.rejoinOffer.value) this.rejoinOffer.value = { media: shared.media, episode: shared.episode, key }
      return
    }
    // v2.3: nothing starts on its own for a newcomer (the lobby state sent after init) or an idle member:
    // they get the Join card. A follower already watching moves on to the new title.
    if (!this.#appliesLobbyState(senderId)) return
    this.#launched = { media: shared.media, episode: shared.episode, key }
    this.emit('media', this.media)
  }

  /** v2.3: a lobby `media` / `index` starts our player only when following, watching, and not the newcomer state. */
  #appliesLobbyState (senderId) {
    return autoStartsMedia({ following: this.isFollowing, localState: this.local.state, senderJoinedAt: this.signals.value[senderId]?.joinedAt, now: Date.now() })
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
    // Watching on our own: keep track of the lobby, but do not apply nor announce over the video.
    // v2.3: neither when our player is on another media (e.g. the sync sent to a newcomer).
    const otherMedia = !!this.local.mediaKey && !!this.media?.key && this.local.mediaKey !== this.media.key
    const following = this.isFollowing && !otherMedia
    if (following) {
      this.#cancelCountdown()
      this.emit('player', { time: payload.time, paused, action, by, rate })
    }

    if (action === 'sync') return
    const delta = following && action === 'seek' && isFiniteNumber(reference) ? payload.time - reference : null
    const text = describeAction({ name: this.nameOf(by), action, time: payload.time, delta })
    if (!text) return
    this.#system(text)
    if (following) this.emit('notice', { text, by, action })
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
      sentAt: isFiniteNumber(payload.sentAt) ? payload.sentAt : undefined,
      // v2.1 / v2.2 optional fields (absent: no source, following).
      source: formatSource(payload.source),
      following: payload.following !== false,
      nowPlaying: normalizeNowPlaying(payload.nowPlaying)
    }
    this.signals.update(signals => {
      signals[userId] = { ...(signals[userId] || {}), status, receivedAt: now }
      return signals
    })
    if (!sameId(userId, this.selfId) && !this.#banned.has(userId)) {
      const { presence, announcements } = presenceOnStatus(this.#presence.get(userId), status, now)
      this.#presence.set(userId, presence)
      this.#announce(userId, announcements)
    }
    if (sameId(userId, this.hostId) && !this.isHost) this.#checkAutoSync(now)
    this.#checkFirstJoin(now)
  }

  #onPong (userId, payload) {
    if (!isFiniteNumber(payload?.sentAt)) return
    const rtt = Date.now() - payload.sentAt
    if (rtt < 0 || rtt > 60_000) return
    this.signals.update(signals => {
      signals[userId] = { ...(signals[userId] || {}), rtt, pongAt: Date.now() }
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
    // Watching on our own: not applied. v2.4: nor on another episode than the lobby's.
    if (this.isFollowing && appliesCountdown({ localKey: this.local.mediaKey, lobbyKey: this.media?.key })) this.#runCountdown({ time: payload.time, seconds, endsAt, by: senderId })
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
        this.cancelAdvance()
        this.#pendingQueueStart = null
      }
      // v2.4: a new host takes over its copy of the queue and shares it at once.
      if (sameId(next.hostId, this.selfId) && !next.tentative) {
        this.#queueKnown = true
        this.#sendToPeers(new Event(EventTypes.QueueEvent, this.queue.value))
      }
    }
    if (previous.mode !== next.mode) this.#system(next.mode === 'host' ? 'Only the host controls playback now' : 'Everyone can control playback now')
  }

  /** The host left: the smallest userId among us and the connected peers takes over. */
  #migrateHost () {
    // Independent members are skipped, unless nobody follows.
    const elected = electFollowingHost({ selfId: this.selfId, selfFollowing: this.isFollowing, peers: this.#peerSummaries() })
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
      enabled: settings.value.w2gAutoSync !== false && this.isFollowing,
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
      sentAt: now,
      source: this.local.source || '',
      following: this.isFollowing,
      nowPlaying: this.local.state === 'idle' ? null : (this.local.nowPlaying ?? null)
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
    this.#presence.delete(userId)
    this.#forgetVoice(userId)
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

  /** Connected peers with their protocol and last `following`, for hand-off and election. */
  #peerSummaries () {
    const signals = this.signals.value
    const seen = new Map()
    for (const entry of Object.values(this.peers.value)) {
      if (!entry.peer || !entry.userId || this.#banned.has(entry.userId) || seen.has(entry.userId)) continue
      seen.set(entry.userId, { userId: entry.userId, protocol: entry.protocol, following: signals[entry.userId]?.status?.following })
    }
    return [...seen.values()]
  }

  /** Jump to the host's expected position now (resync after following again, "Rejoin"). */
  #syncToHost (now) {
    const target = this.#hostTarget(now)
    if (!target || (target.mediaKey !== null && target.mediaKey !== this.local.mediaKey)) return false
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostId })
    return true
  }

  /** Presence lines (v2.1 / v2.2): a system line plus a 3 s notice over the video. */
  #announce (userId, announcements) {
    for (const announcement of announcements) {
      const text = describePresence(this.nameOf(userId), announcement)
      if (!text) continue
      this.#system(text)
      this.emit('notice', { text, by: userId, presence: announcement.kind })
    }
  }

  /** Time-based presence: long buffering, lost connection. */
  /** v2.3: once, when we arrive in a lobby that is already watching, an app-wide Join prompt. */
  #checkFirstJoin (now) {
    if (this.#joinPrompted || this.#firstPeerAt === null) return
    if (now - this.#firstPeerAt > FIRST_JOIN_WINDOW_MS) {
      this.#joinPrompted = true
      return
    }
    const offer = this.joinOffer()
    if (!offer) return
    this.#joinPrompted = true
    this.emit('joinable', offer)
  }

  /** Members (ourselves included) with their last status, for the lobby reference. */
  #statusMembers () {
    const signals = this.signals.value
    const members = [{ userId: this.selfId, status: { ...this.local, following: this.isFollowing } }]
    for (const { userId, protocol } of this.#peerSummaries()) {
      if (protocol >= 2 || signals[userId]?.status) members.push({ userId, status: signals[userId]?.status ?? null })
    }
    return members
  }

  /** v2.3 reference member of the lobby playback, null when the lobby is not watching. */
  #lobbyReferenceId () {
    return lobbyReference({ lobbyKey: this.media?.key, hostId: this.hostId, members: this.#statusMembers() })
  }

  /** Expected position of a member: ours, or extrapolated from its last status. */
  #memberPosition (userId, now) {
    if (userId == null) return null
    if (sameId(userId, this.selfId)) {
      const time = this.#localTime(now)
      return time === null ? null : { time, paused: this.local.state !== 'playing' && this.local.state !== 'buffering' }
    }
    const signal = this.signals.value[userId]
    return hostReference({ status: signal?.status, receivedAt: signal?.receivedAt, rtt: signal?.rtt }, now)
  }

  /** v2.3 media an invite offers, and the lobby reference. */
  #offered () {
    const ownActive = this.local.state !== 'idle' && !!this.#launched && this.#launched.key === this.local.mediaKey
    const reference = this.#lobbyReferenceId()
    const offered = offeredMedia({ ownKey: this.#launched?.key, ownActive, lobbyKey: this.media?.key, lobbyWatching: reference !== null })
    return { offered, reference }
  }

  /** v2.3 offer for an invite: media plus the position to send. */
  #offer (now) {
    const { offered, reference } = this.#offered()
    if (!offered) return null
    const media = offered.from === 'own' ? this.#launched : this.media
    const position = invitePosition({ offered, own: this.#memberPosition(this.selfId, now), reference: this.#memberPosition(reference, now) })
    return { offered, media, position }
  }

  #tickPresence () {
    if (this.#destroyed) return
    const now = Date.now()
    const signals = this.signals.value
    for (const [userId, presence] of this.#presence) {
      const signal = signals[userId]
      const result = presenceOnTick(presence, { now, lastStatusAt: signal?.receivedAt, lastPongAt: signal?.pongAt })
      if (result.presence) this.#presence.set(userId, result.presence)
      this.#announce(userId, result.announcements)
    }
  }

  #onInvite (senderId, payload) {
    if (!acceptsInvite({ to: payload?.to, selfId: this.selfId, senderId, hostId: this.hostId, effectiveMode: this.effectiveMode })) return
    if (!payload.media?.id || !isFiniteNumber(payload.time)) return
    const key = typeof payload.key === 'string' && payload.key ? payload.key : mediaKey(payload)
    /** @type {Invite} */
    const invite = {
      from: senderId,
      name: this.nameOf(senderId),
      media: payload.media,
      episode: payload.episode,
      key,
      time: Math.max(0, payload.time),
      paused: !!payload.paused,
      receivedAt: Date.now()
    }
    // A new invite from the same sender replaces the previous one.
    this.invites.update(list => [...list.filter(item => item.from !== senderId), invite])
    this.#system(`${invite.name} invited you to watch`)
    this.emit('invite', invite)
  }

  #removeInvite (from) {
    if (!this.invites.value.some(item => item.from === from)) return false
    this.invites.update(list => list.filter(item => item.from !== from))
    this.emit('inviteRemoved', from)
    return true
  }

  // ---------------------------------------------------------------- v2.4 voice and queue internals

  #hasFeature (userId, feature) {
    return Object.values(this.peers.value).some(entry => entry.peer && sameId(entry.userId, userId) && entry.features?.includes(feature))
  }

  /** Sends an event to one member (its first open channel). */
  #sendToUser (userId, event) {
    if (userId == null) return false
    for (const [peerId, entry] of Object.entries(this.peers.value)) {
      const channel = this.#channels.get(peerId)
      if (!entry.peer || !channel || !sameId(entry.userId, userId) || this.#bannedPeers.has(peerId)) continue
      this.#sendEvent(channel, event)
      return true
    }
    return false
  }

  #memberInVoice (userId) {
    return !!this.voiceStates.value[userId]?.joined && this.#hasFeature(userId, 'voice') && this.#hasUser(userId)
  }

  /** Our voice state changed: stores, `voice` to everyone when it differs, links, ducking. */
  #onVoiceEngineState () {
    const engine = this.#voice
    const payload = engine.payload
    this.voice.value = {
      joined: engine.joined,
      starting: engine.starting,
      hasMic: engine.hasMic,
      muted: engine.muted,
      pushToTalk: engine.pushToTalk,
      held: engine.held,
      transmitting: engine.transmitting,
      speaking: payload.speaking,
      error: engine.error
    }
    const previous = this.#lastVoicePayload
    if (previous.joined !== payload.joined || previous.muted !== payload.muted || previous.speaking !== payload.speaking) {
      this.#lastVoicePayload = payload
      this.#sendToPeers(new Event(EventTypes.VoiceEvent, payload))
    }
    this.peers.update(peers => peers)
    this.#syncVoiceLinks()
    this.#updateDuck()
  }

  #onVoice (userId, payload) {
    if (sameId(userId, this.selfId)) return
    const state = normalizeVoice(payload)
    const previous = this.voiceStates.value[userId]
    this.voiceStates.update(states => {
      states[userId] = state
      return states
    })
    if (state.joined !== !!previous?.joined && (previous || state.joined)) {
      this.#system(`${this.nameOf(userId)} ${state.joined ? 'joined' : 'left'} voice`)
    }
    this.#syncVoiceLinks()
    this.#updateDuck()
  }

  #onVoiceSignal (userId, payload) {
    if (payload?.sdp?.type === 'offer' && !acceptsVoiceOffer({ selfJoined: this.#voice.joined, memberJoined: this.#memberInVoice(userId), selfId: this.selfId, senderId: userId })) return
    this.#voice.signal(userId, payload)
  }

  /** Creates the links we offer and closes the ones nobody needs anymore. */
  #syncVoiceLinks () {
    const members = new Set(this.#peerSummaries().map(peer => peer.userId))
    for (const userId of members) {
      const action = voiceLinkAction({
        selfJoined: this.#voice.joined,
        memberJoined: !!this.voiceStates.value[userId]?.joined,
        memberHasVoice: this.#hasFeature(userId, 'voice'),
        hasLink: this.#voice.hasLink(userId),
        selfOffers: voiceOffers(this.selfId, userId)
      })
      if (action === 'offer') this.#voice.connect(userId)
      else if (action === 'close') this.#voice.close(userId)
    }
    for (const userId of Object.keys(this.#voice.linkStates())) if (!members.has(userId)) this.#voice.close(userId)
  }

  /** Lowers the video while a member we hear speaks (setting `w2gVoiceDucking`). */
  #updateDuck () {
    if (this.#destroyed) return
    const states = this.voiceStates.value
    const members = this.#peerSummaries().map(({ userId }) => {
      const mix = this.#voice.mixOf(userId)
      return { ...(states[userId] ?? VOICE_OFF), localMuted: mix.muted, volume: mix.volume }
    })
    voiceDuck.value = duckLevel({ enabled: settings.value.w2gVoiceDucking !== false, selfJoined: this.#voice.joined, members })
  }

  /** A member left the lobby or was kicked: no more voice with it. */
  #forgetVoice (userId) {
    this.#voice.forget(userId)
    if (this.voiceStates.value[userId]) {
      this.voiceStates.update(states => {
        delete states[userId]
        return states
      })
    }
    this.#updateDuck()
  }

  #onQueue (senderId, payload) {
    if (this.isHost || !acceptsQueue({ senderId, hostId: this.hostId, tentative: this.lobby.value.tentative })) return
    const next = normalizeQueue(payload)
    if (next) this.#applyQueue(next)
  }

  /**
   * Host: one change of the queue, then `queue` to everyone.
   * @param {Parameters<typeof queueReduce>[1]} change
   */
  #hostQueueChange (change) {
    if (!this.isHost) return false
    const next = queueReduce(this.queue.value, change)
    if (!next) return false
    this.#applyQueue(next)
    this.#sendToPeers(new Event(EventTypes.QueueEvent, next))
    return true
  }

  /** New queue (ours as host, or the host's): chat lines for what changed, host prompt for suggestions. */
  #applyQueue (next) {
    const previous = this.#queueKnown ? this.queue.value : null
    this.#queueKnown = true
    this.queue.value = next
    for (const change of queueChanges(previous, next, { selfId: this.selfId, cancelled: this.#queueCancelled })) {
      const text = describeQueueChange(change, this.selfId)
      this.#system(text)
      if (change.kind === 'suggested' && this.isHost) this.emit('notice', { text, by: change.item.addedBy })
    }
    const advance = this.advance.value
    if (advance && !next.items.some(item => item.id === advance.item.id)) this.cancelAdvance()
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
