import { EventEmitter } from 'events'

import P2PT from 'p2pt'

import Event, { EventTypes, SYSTEM_MESSAGE } from '@/routes/w2g/components/events.js'
import {
  PROTOCOL_VERSION, HEARTBEAT_MS, PING_MS, REQUEST_TIMEOUT_MS, IN_SYNC_S,
  isFiniteNumber, sameId, normalizeMode, normalizeState, normalizeRate, normalizeReaction, normalizeCountdownSeconds,
  memberName, remoteName, expectedTime, syncBadge, selfBadge, autoSyncStep, hostReference, inferAction,
  describeAction, describeRequest, presenceOnStatus, presenceOnTick, describePresence, canInvite, acceptsInvite,
  inviteTarget, formatSource, normalizeNowPlaying, episodeLabelFor, pickFollowingHost, electFollowingHost,
  followBackAction, episodeLabelOf, lobbyReference, canJoinPlayback, offeredMedia, invitePosition, autoStartsMedia,
  appliesCountdown, FEATURES, voiceOffers, voiceLinkAction, acceptsVoiceOffer, duckLevel,
  emptyQueue, queueReduce, queueChanges, sameQueueEntry, describeQueueChange, queueItemLabel, nextEpisodeTarget, acceptsQueue,
  QUEUE_ADVANCE_S, QUEUE_COUNTDOWN_S,
  ChunkAssembler, validateEvent, rateClass, rateStep, RATE_LIMITS, memberKey, shadowKey, pairIds, resolveHostKey, nextRtt,
  iceServers, indexKind, sameEpisode, mediaKey, sameMediaKey, isInitialState, cleanUrl,
  MAX_EVENT_CHARS, MAX_INDEX, MAX_MESSAGE_LENGTH, MAX_NAME_LENGTH, TENTATIVE_HOST_MS
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
 * @typedef {{ user: W2GUser, peer?: import('p2pt').Peer<any>, userId: string, sessionId?: string | null, key: string, protocol?: number, client?: string, features?: string[], shadow?: boolean }} PeerEntry
 *   userId: `init.id` as a string (the wire identity); key: memberKey(userId, sessionId), who it is on this device;
 *   shadow: v2.6, another channel already owned that member key, this one is keyed sync.js shadowKey (no authority)
 * @typedef {Record<string, PeerEntry>} PeerList
 * @typedef {{ media: object, episode: number | { number: number, season?: number, localEpisode?: number }, key: string }} SharedMedia
 * @typedef {{ message: string, user: W2GUser | null, type: 'incoming' | 'outgoing' | 'system', date: Date, emoji?: string }} ChatEntry
 * @typedef {{ status?: import('./sync.js').Status & { sentAt?: number, source?: string }, receivedAt?: number, rtt?: number, pongAt?: number, joinedAt?: number }} Signal
 * @typedef {{ id: string, kind: 'pause' | 'play' | 'seek', time?: number, userId: string, name: string, expiresAt: number }} HostRequest
 * @typedef {{ from: string, name: string, media: any, episode: SharedMedia['episode'], key: string, time: number, paused: boolean, receivedAt: number }} Invite
 * @typedef {{ joined: boolean, muted: boolean, speaking: boolean, link?: 'connecting' | 'connected' | null, localMuted?: boolean, volume?: number }} MemberVoice
 * @typedef {{ userId: string, wireId: string, user: W2GUser, name: string, isSelf: boolean, isHost: boolean, badge: import('./sync.js').Badge, protocol?: number, client?: string, shadow?: boolean, rtt?: number, source?: string, canInvite?: boolean, voice?: MemberVoice, hasVoice?: boolean }} MemberView
 *   userId: the member key, what kick / transferHost / invite / setMemberVoice take; wireId: its `init.id`
 * @typedef {{ joined: boolean, starting: boolean, hasMic: boolean, muted: boolean, pushToTalk: boolean, held: boolean, transmitting: boolean, speaking: boolean, error: string | null }} VoiceView
 * @typedef {{ peer: import('p2pt').Peer<any>, key: string, userId: string, client?: string }} Sender transport peer of an event
 */

/** v2.4 `voice` payload while not in voice. */
const VOICE_OFF = { joined: false, muted: true, speaking: false }

/** A joined invite seeks once its episode is loaded, if that happens within 2 minutes. */
const JOIN_TTL_MS = 120_000
/** v2.3: the one-time "join the current playback" prompt is for a lobby already watching when we arrive. */
const FIRST_JOIN_WINDOW_MS = 20_000
/** v2.3 "Invite everyone not watching": one invite every 200 ms. */
const INVITE_ALL_GAP_MS = 200
/** Two presence ticks (every second) further apart than this: the app was frozen or asleep in between. */
const SUSPENDED_GAP_MS = 5_000

const MAX_MESSAGES = 200
/** Ids of the events that are sent all the time, kept out of the debug log. */
const QUIET_EVENTS = new Set([EventTypes.StatusEvent, EventTypes.PingEvent, EventTypes.PongEvent])

/** Id of an anonymous participant, kept for the whole app session. */
const anonymousId = generateRandomHexCode(16)

/**
 * Watch Together lobby: participants find each other through public WebSocket
 * signaling servers (P2PT), then talk directly over WebRTC. Nothing but small
 * JSON events (who is here, what is playing, play/pause/time, chat...) is exchanged.
 * The protocol is described in ../PROTOCOL.md.
 *
 * Members are told apart by their key (sync.js memberKey): their `init.id` plus the `init.sessionId` of their lobby
 * instance, so two devices of one account are two members. Events name members by `init.id` on the wire.
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
 * - 'destroyed': we left the lobby (prompts shown for it can go)
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
  /** v2.5 `init.sessionId`: random id of this lobby instance, tells our devices apart when they share an account. */
  sessionId = generateRandomHexCode(16)
  /** @type {import('simple-store-svelte').Writable<ChatEntry[]>} */
  messages = writable([])

  /** @type {W2GUser} */
  self
  /** @type {import('simple-store-svelte').Writable<PeerList>} participants that sent `init`, keyed by transport id (self by its key) */
  peers

  /**
   * hostId: `init.id` of the host (wire); hostKey: its member key.
   * @type {import('simple-store-svelte').Writable<{ hostId: string | null, hostKey: string | null, mode: 'everyone' | 'host', tentative: boolean }>}
   */
  lobby = writable({ hostId: null, hostKey: null, mode: 'everyone', tentative: false })
  /** @type {import('simple-store-svelte').Writable<Record<string, Signal>>} last status / RTT per member key */
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
  /** @type {import('simple-store-svelte').Writable<Record<string, { joined: boolean, muted: boolean, speaking: boolean }>>} last `voice` per member key */
  voiceStates = writable({})
  /** @type {import('simple-store-svelte').Writable<Record<string, 'connecting' | 'connected'>>} audio link per member key */
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
  /** @type {Set<string>} kicked userIds (accounts), ignored for the rest of the session */
  #banned = new Set()
  /** @type {Set<string>} transport ids of the kicked users' channels, ignored while they close */
  #bannedPeers = new Set()
  /** @type {Map<string, number>} last message time per member key */
  #lastSeen = new Map()
  /** @type {{ streak: number, lastSyncAt: number } | null} */
  #autoSync = null
  /** @type {{ time: number, paused: boolean, rate: number, at: number } | null} last applied `player` event of the host */
  #lastHostPlayer = null
  /** @type {Map<string, ReturnType<typeof setTimeout>>} */
  #requestTimers = new Map()
  /** @type {Map<string, string>} request id -> requester member key */
  #requestOwners = new Map()
  /** @type {Set<string>} ids of our own pending requests */
  #myRequests = new Set()
  /** @type {Map<string, import('./sync.js').Presence>} presence announcements state per member key */
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
  /** v2.5: P2PT messages reassembled with limits, per peer (see #guardTransport). */
  #chunks = new ChunkAssembler()
  /** @type {string | null} transport id of the frame P2PT is parsing */
  #chunkPeer = null
  /**
   * v2.5 / v2.6 rate limits (sync.js RATE_LIMITS), per data channel (transport id) then bucket: sending `init` again
   * does not reset them.
   * @type {Map<string, Map<string, { tokens: number, at: number, allowed: boolean }>>}
   */
  #rates = new Map()
  /** v2.5: the app was frozen until then (pongs of older pings are no RTT samples). */
  #resumedAt = -Infinity
  #lastTickAt = 0
  /** v2.5: a tentative host that does not claim the role is skipped. */
  #tentativeTimer = null
  /** @type {Set<string>} member keys elected that never claimed the role, until a host is confirmed */
  #electionSkip = new Set()
  #onOnline = () => this.#p2pt?.requestMorePeers?.()

  get inviteLink () {
    return `tsumi://w2g/${this.code}`
  }

  /** Our `init.id`, as the others name us in events. */
  get selfId () {
    return String(this.self.id)
  }

  /** Our member key (v2.5): our id plus our session id. */
  get selfKey () {
    return memberKey(this.selfId, this.sessionId)
  }

  get hostId () {
    return this.lobby.value.hostId
  }

  /** Member key of the host. */
  get hostKey () {
    return this.lobby.value.hostKey
  }

  get mode () {
    return this.lobby.value.mode
  }

  get isHost () {
    return this.hostKey != null && this.hostKey === this.selfKey
  }

  /** While no host is known, everyone controls playback. */
  get effectiveMode () {
    return this.hostKey == null ? 'everyone' : this.mode
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
    if (!viewer && displayName?.trim()) this.self.displayName = displayName.trim().slice(0, MAX_NAME_LENGTH)
    this.peers = writable({ [this.selfKey]: { user: this.self, userId: this.selfId, sessionId: this.sessionId, key: this.selfKey, protocol: PROTOCOL_VERSION } })

    this.code = code ?? generateRandomHexCode(16)
    // The lobby creator is the first host.
    if (!code) this.lobby.value = { hostId: this.selfId, hostKey: this.selfKey, mode: 'everyone', tentative: false }
    this.#joinPrompted = !code
    this.#queueKnown = !code

    // v2.4 voice chat: the engine does the audio, the lobby decides who to link with.
    this.#voice = new VoiceEngine({
      wantsOffer: key => this.#voice.joined && this.#selfOffers(key) && this.#memberInVoice(key),
      iceServers: () => this.#iceServers()
    })
    this.#voice.on('state', () => this.#onVoiceEngineState())
    this.#voice.on('signal', ({ userId, payload }) => this.#sendToMember(userId, new Event(EventTypes.VoiceSignalEvent, payload)))
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
    // v2.5: the optional TURN server of the settings, for the data channels too (bittorrent-tracker passes
    // `_rtcConfig` to every simple-peer it creates).
    this.#p2pt._rtcConfig = { iceServers: this.#iceServers() }
    this.#guardTransport()

    this.#wireEvents()
    this.#p2pt.start()
    this.#heartbeat = setInterval(() => this.#sendStatus(), HEARTBEAT_MS)
    this.#pinger = setInterval(() => this.#pingAll(), PING_MS)
    this.#presenceTicker = setInterval(() => this.#tickPresence(), 1000)
    // v2.5: back online (network change, sleep): announce again instead of waiting for the next interval.
    if (typeof window !== 'undefined') window.addEventListener('online', this.#onOnline)
  }

  // ---------------------------------------------------------------- public API

  /**
   * A title/episode was started locally: share it so the others start it too.
   * @param {{ media: object, episode: SharedMedia['episode'] }} shared
   */
  shareMedia ({ media, episode }) {
    const key = mediaKey({ media, episode })
    debug(`shareMedia: ${this.media?.key} -> ${key}`)
    // localKey: our own key for a media received from another client, which may use other ids. v2.6: keys are compared
    // canonically ("21:5" and an older app's "21::5" are one episode), or the players reload each other forever.
    if (this.media && (sameMediaKey(this.media.key, key) || sameMediaKey(this.media.localKey, key))) {
      this.#launched = { media: this.media.media, episode: this.media.episode, key: this.media.key }
      return
    }
    this.#launched = { media, episode, key }
    // Watching on our own: never drag the others. v2.6: nor in `host` mode as a non-host (the others drop it anyway):
    // the lobby media stays the host's, so the Join card and "Add next episode" still point at it.
    if (!this.isFollowing || this.controlLocked) return
    this.#setMedia({ media, episode, key, localKey: key })
    this.#sendToPeers(new Event(EventTypes.MediaEvent, { media, episode, key }))
  }

  /** @param {{ index: number }} index position in the player's file list */
  mediaIndexChanged (index) {
    debug(`mediaIndexChanged: ${JSON.stringify(this.index)} ${JSON.stringify(index)}`)
    const value = index?.index
    if (!this.isFollowing || !Number.isInteger(value) || value < 0 || value > MAX_INDEX) return
    if (this.index?.index !== value) {
      this.index = { index: value }
      // v2.5: `kind` says it is a file position; `mediaKey` what we played when it changed.
      this.#sendToPeers(new Event(EventTypes.MediaIndexEvent, { index: value, kind: 'file', mediaKey: this.local.mediaKey || undefined }))
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
      if (target && (target.mediaKey === null || sameMediaKey(target.mediaKey, this.local.mediaKey))) {
        this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostKey })
      }
      this.emit('blocked', { action, time: state.time, paused })
      return false
    }

    this.player = { time: state.time, paused }
    const rate = normalizeRate(state.rate)
    // v2.5 `mediaKey`: the others only apply it on the same episode.
    this.#sendToPeers(new Event(EventTypes.PlayerStateEvent, { time: state.time, paused, by: this.selfId, action, rate, mediaKey: this.local.mediaKey || undefined }))
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
    const launched = key && this.#launched && sameMediaKey(this.#launched.key, key) ? this.#launched : null
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
    if (next.mediaKey && this.rejoinOffer.value && sameMediaKey(this.rejoinOffer.value.key, next.mediaKey)) this.rejoinOffer.value = null
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
    else if (queued && this.#onLocalKey(queued.key)) {
      this.#pendingQueueStart = null
      // Once the player reported its loaded state (position, play / pause).
      const timer = setTimeout(() => {
        this.#inviteTimers.delete(timer)
        if (!this.#destroyed && this.isHost && this.#onLocalKey(queued.key)) this.startTogether(QUEUE_COUNTDOWN_S)
      }, 300)
      this.#inviteTimers.add(timer)
      return
    }
    const join = this.#pendingJoin
    if (join && now - join.joinedAt > JOIN_TTL_MS) this.#pendingJoin = null
    else if (join && this.#onLocalKey(join.key)) {
      this.#pendingJoin = null
      if (join.kind === 'lobby') {
        // v2.3 Join: the reference's expected time and play / pause state, read now that we are loaded.
        const reference = this.#lobbyReferenceId()
        const target = reference === this.selfKey ? null : this.#memberPosition(reference, now)
        if (target) this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: reference })
        return
      }
      const target = inviteTarget({ invite: join, host: this.isHost ? null : this.#hostTarget(now), now })
      this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: target.from === 'host' ? this.hostKey : join.from })
      return
    }
    if (!this.isFollowing) return
    const rejoin = this.#pendingRejoin
    const rejoined = !!rejoin && this.#onLocalKey(rejoin.key)
    if (rejoin && (now - rejoin.at > JOIN_TTL_MS || rejoined)) {
      this.#pendingRejoin = null
      // "Rejoin" then syncs, whatever the auto-sync setting.
      if (rejoined) {
        this.#syncToHost(now)
        return
      }
    }
    if (this.isHost || this.hostKey == null) return
    if (this.effectiveMode !== 'host' && settings.value.w2gAutoSync === false) return
    const target = this.#hostTarget(Date.now())
    if (!target || target.mediaKey === null || !this.#onLocalKey(target.mediaKey)) return
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostKey })
  }

  /** Manual "Resync": jump to the host's expected position and state now. */
  resync () {
    if (this.isHost || !this.isFollowing) return false
    const target = this.#hostTarget(Date.now())
    if (!target) {
      this.emit('info', { text: 'Nothing to sync with yet' })
      return false
    }
    if (target.mediaKey !== null && !sameMediaKey(target.mediaKey, this.local.mediaKey)) {
      this.emit('info', { text: 'The host is on another episode' })
      return false
    }
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostKey })
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
    this.#sendToPeers(new Event(EventTypes.PlayerStateEvent, { time, paused, by: this.selfId, action: 'sync', rate: this.local.rate, mediaKey: this.local.mediaKey || undefined }))
    this.emit('info', { text: 'Everyone was resynced' })
    return true
  }

  /**
   * "Invite to watch": ask a member to play what we play, at our position.
   * Anyone in `everyone` mode, the host only in `host` mode.
   * @param {string} key member key
   */
  invite (key) {
    const target = this.#memberOf(String(key))
    if (!target?.peer) return false
    if (this.effectiveMode === 'host' && !this.isHost) return false
    // v2.3: our own media when we play one, else the lobby media while the lobby is watching.
    const offer = this.#offer(Date.now())
    if (!offer?.position) return false
    const { media, position } = offer
    // v2.5 `toSession`: only that device of the account takes it.
    this.#sendToPeers(new Event(EventTypes.InviteEvent, { to: target.userId, toSession: target.sessionId || undefined, media: media.media, episode: media.episode, key: media.key, time: position.time, paused: position.paused, by: this.selfId }))
    this.#system(`You invited ${this.nameOf(target.key)}`)
    return true
  }

  /** v2.3 host tool "Invite everyone not watching": one invite per eligible member, 200 ms apart. */
  inviteAllNotWatching () {
    if (!this.isHost) return 0
    const targets = this.describeMembers().filter(member => member.canInvite).map(member => member.userId)
    targets.forEach((key, index) => {
      const timer = setTimeout(() => {
        this.#inviteTimers.delete(timer)
        if (!this.#destroyed) this.invite(key)
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
    if (!canJoinPlayback({ reference, selfId: this.selfKey, lobbyKey: media?.key, local: this.local, following: this.isFollowing })) return null
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
    this.#play(media, { pending: true })
    return true
  }

  /** Join an invite: play its episode like a received `media`, even when the key did not change, then seek. */
  joinInvite (from) {
    const invite = this.invites.value.find(item => item.from === from)
    if (!invite) return false
    this.#removeInvite(from)
    const shared = { media: invite.media, episode: invite.episode, key: invite.key, localKey: mediaKey(invite) }
    // Following: it becomes the lobby media like a received `media`. On our own: only played here.
    if (this.isFollowing) this.#setMedia(shared)
    this.#launched = { media: invite.media, episode: invite.episode, key: invite.key }
    this.#pendingJoin = { ...invite, joinedAt: Date.now() }
    this.#play(shared, { pending: true })
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
        const target = pickFollowingHost(this.#electionPeers())
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
    this.#play(media, { pending: true })
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
    this.#sendToPeers(new Event(EventTypes.CountdownEvent, { time, seconds: value, startAt, mediaKey: this.local.mediaKey || undefined }))
    this.#runCountdown({ time, seconds: value, endsAt: startAt + value * 1000, by: this.selfKey })
    this.#system('You started a countdown')
    return true
  }

  /** Host: control mode toggle. @param {'everyone' | 'host'} mode */
  setMode (mode) {
    const next = normalizeMode(mode)
    if (!this.isHost || next === this.mode) return false
    this.#setLobby({ hostId: this.selfId, hostKey: this.selfKey, mode: next, tentative: false })
    this.#sendToPeers(this.#hostEvent(this.selfKey, next))
    return true
  }

  /**
   * Host: give the host role to someone else.
   * @param {string} key member key
   */
  transferHost (key) {
    const target = this.#memberOf(String(key))
    // v2.6: never to a channel that copied another member's ids (see sync.js shadowKey).
    if (!this.isHost || !target?.peer || target.shadow) return false
    // A v1 client would not know it is host: it could not change the mode, kick or answer requests.
    if ((target.protocol ?? 1) < PROTOCOL_VERSION) return false
    const mode = this.mode
    this.#sendToPeers(this.#hostEvent(target.key, mode))
    this.#setLobby({ hostId: target.userId, hostKey: target.key, mode, tentative: false })
    return true
  }

  /**
   * Host: remove someone from the lobby (every device of that account: kicks name accounts).
   * @param {string} key member key
   */
  kick (key) {
    const target = this.#memberOf(String(key))
    // Not ourselves, nor another device of our own account (the others would ban us with it).
    if (!this.isHost || !target?.peer || sameId(target.userId, this.selfId)) return false
    this.#sendToPeers(new Event(EventTypes.KickEvent, { userId: target.userId }))
    this.#ban(target.userId)
    return true
  }

  /**
   * Non-host: ask the host for a change.
   * @param {'pause' | 'play' | 'seek'} kind
   * @param {number} [time] for 'seek'
   */
  request (kind, time) {
    if (!['pause', 'play', 'seek'].includes(kind) || this.isHost) return false
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
    this.#showReaction(this.selfKey, value)
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
    const value = String(name ?? '').trim().slice(0, MAX_NAME_LENGTH)
    if ((this.self.displayName || '') === value) return
    if (value) this.self.displayName = value
    else delete this.self.displayName
    this.peers.update(peers => peers)
    this.#sendToPeers(new Event(EventTypes.SessionInitEvent, this.#initPayload()))
  }

  /**
   * Display name of a participant ("You" for ourselves).
   * @param {string | null | undefined} id member key, or `init.id`
   */
  nameOf (id) {
    if (id == null) return remoteName(null)
    if (id === this.selfKey || sameId(id, this.selfId)) return 'You'
    const entry = this.#memberOf(String(id)) ?? this.#memberByUserId(id)
    return remoteName(entry?.user ?? { id })
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
    const hostKey = this.hostKey
    /** @type {MemberView[]} */
    const list = [{
      userId: this.selfKey,
      wireId: this.selfId,
      user: this.self,
      name: memberName(this.self),
      isSelf: true,
      isHost: this.isHost,
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
    const seen = new Set([this.selfKey])
    const invite = {
      offeredKey: this.#offered().offered?.key ?? null,
      effectiveMode: this.effectiveMode,
      isHost: this.isHost,
      now
    }
    for (const entry of Object.values(this.peers.value)) {
      const key = entry.key
      if (!entry.peer || !key || seen.has(key) || this.#banned.has(entry.userId)) continue
      seen.add(key)
      const signal = { ...(signals[key] || {}), protocol: entry.protocol, lastSeen: this.#lastSeen.get(key) }
      const badge = syncBadge(signal, this.local, now)
      list.push({
        userId: key,
        wireId: entry.userId,
        user: entry.user,
        name: remoteName(entry.user),
        isSelf: false,
        isHost: key === hostKey,
        badge,
        protocol: entry.protocol,
        client: entry.client,
        shadow: !!entry.shadow,
        rtt: signal.rtt,
        source: signal.status?.source || '',
        nowPlaying: signal.status?.nowPlaying ?? null,
        following: signal.status?.following !== false,
        canInvite: canInvite({ ...invite, member: { isSelf: false, protocol: entry.protocol, badge, status: signal.status, joinedAt: signal.joinedAt } }),
        hasVoice: !!entry.features?.includes('voice'),
        voice: { ...(voiceStates[key] ?? VOICE_OFF), link: links[key] ?? null, localMuted: this.#voice.mixOf(key).muted, volume: this.#voice.mixOf(key).volume }
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
   * @param {string} key member key
   * @param {{ muted?: boolean, volume?: number }} mix
   */
  setMemberVoice (key, mix) {
    this.#voice.setMix(String(key), mix)
  }

  // ---------------------------------------------------------------- v2.4 shared queue

  /** The queue exists: we are the host, or the host's app supports it. */
  get queueAvailable () {
    return this.isHost || (this.hostKey != null && this.#hasFeature(this.hostKey, 'queue'))
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
      // v2.6: an http(s) URL of at most 500 characters, or none (a cut URL would be a broken one).
      cover: cleanUrl(cover || media.coverImage?.medium || media.coverImage?.extraLarge || '', 500),
      addedBy: this.selfId,
      addedByName: memberName(this.self)
    }
    if (this.isHost) return this.#hostQueueChange({ type: 'add', item, by: this.selfId, byName: memberName(this.self), byHost: true }) ? 'added' : 'duplicate'
    if (!this.#sendToMember(this.hostKey, new Event(EventTypes.QueueAddEvent, { item }))) return null
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
    this.#sendToMember(this.hostKey, new Event(EventTypes.QueueVoteEvent, { id, up }))
    return true
  }

  /** The host removes any item; a member removes its own item or suggestion. */
  removeQueueItem (id) {
    if (this.isHost) return this.#hostQueueChange({ type: 'remove', id, by: this.selfId, byHost: true })
    const item = [...this.queue.value.items, ...this.queue.value.pending].find(entry => entry.id === id)
    if (!item || !sameId(item.addedBy, this.selfId)) return false
    this.#queueCancelled.add(id)
    this.#sendToMember(this.hostKey, new Event(EventTypes.QueueRemoveEvent, { id }))
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
    this.#setMedia({ ...shared, localKey: mediaKey(item) })
    this.#launched = { ...shared }
    this.rejoinOffer.value = null
    this.#pendingRejoin = null
    this.#pendingJoin = null
    this.#pendingQueueStart = { key: item.key, at: Date.now() }
    this.#sendToPeers(new Event(EventTypes.MediaEvent, shared))
    this.#system(`You started ${queueItemLabel(item)} from Up next`)
    this.#play(this.media, { pending: true })
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
    clearTimeout(this.#tentativeTimer)
    if (typeof window !== 'undefined') window.removeEventListener('online', this.#onOnline)
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
    this.#chunks.clear()
    // The app dismisses the prompts of this lobby (invite and Join toasts).
    this.emit('destroyed')
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

  /**
   * v2.5: P2PT reassembles chunked messages in one table shared by every peer, at whatever chunk index a peer sends,
   * without any limit (one frame with `c: 4294967294` freezes the app). Its handler is replaced at runtime by
   * ChunkAssembler: bounded index, size limit per message and in total, per peer, with a timeout.
   */
  #guardTransport () {
    const p2pt = this.#p2pt
    // P2PT emits 'data' (peer, frame) right before parsing that frame and calling _chunkHandler(frame), which gets no
    // peer: remember whose frame it is.
    p2pt.on('data', peer => { this.#chunkPeer = peer?.id ?? null })
    p2pt._chunkHandler = data => {
      const peerId = this.#chunkPeer
      this.#chunkPeer = null
      if (peerId == null || this.#destroyed) return false
      return this.#chunks.add(peerId, data, Date.now())
    }
    // The assembler forgets a message once it returned it.
    p2pt._destroyChunks = () => {}
  }

  /** ICE servers of new links: STUN, plus the optional TURN server of the settings. */
  #iceServers () {
    const value = settings.value
    return iceServers({ url: value.w2gTurnUrl, username: value.w2gTurnUsername, credential: value.w2gTurnCredential })
  }

  /** v2.5 minimal `init`: who we are for the others, not the whole AniList / MyAnimeList viewer. */
  #initPayload () {
    const self = /** @type {any} */ (this.self)
    /** @type {Record<string, any>} */
    const payload = { id: self.id }
    if (typeof self.name === 'string' && self.name) payload.name = self.name
    if (self.displayName) payload.displayName = self.displayName
    if (self.avatar?.medium || self.avatar?.large) payload.avatar = { medium: self.avatar.medium, large: self.avatar.large }
    if (typeof self.picture === 'string' && self.picture) payload.picture = self.picture
    return {
      ...payload,
      client: SUPPORTS.isAndroid ? 'tsumi-android' : 'tsumi-desktop',
      protocol: PROTOCOL_VERSION,
      features: [...FEATURES],
      sessionId: this.sessionId
    }
  }

  /**
   * `host` naming a member: its `init.id`, plus its session id when it has one (v2.5 `hostSession`).
   * @param {string} key member key
   * @param {'everyone' | 'host'} mode
   */
  #hostEvent (key, mode) {
    const member = this.#memberOf(key)
    return new Event(EventTypes.HostEvent, { hostId: member?.userId ?? key, mode, hostSession: member?.sessionId || undefined })
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
    this.#sendEvent(peer, new Event(EventTypes.MediaIndexEvent, { index: this.index.index, kind: 'file' }))
    const now = Date.now()
    const time = this.#localTime(now)
    const state = time !== null
      ? { time, paused: this.local.state !== 'playing' && this.local.state !== 'buffering' }
      : this.player
    this.#sendEvent(peer, new Event(EventTypes.PlayerStateEvent, { ...state, by: this.selfId, action: 'sync', rate: this.local.rate, mediaKey: this.local.mediaKey || undefined }))
  }

  #onPeerconnect (peer) {
    if (this.#destroyed) return
    debug(`#onPeerconnect: ${peer.id}`)
    this.#channels.set(peer.id, peer)
    this.#sendEvent(peer, new Event(EventTypes.SessionInitEvent, this.#initPayload()))
    if (this.isHost) {
      this.#sendEvent(peer, this.#hostEvent(this.selfKey, this.mode))
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
    this.#chunks.forget(peer.id)
    this.#channels.delete(peer.id)
    this.#rates.delete(peer.id)
    const entry = this.peers.value[peer.id]
    if (!entry) return
    this.peers.update(peers => {
      delete peers[peer.id]
      return peers
    })
    const key = entry.key
    if (!key || this.#hasMember(key)) return
    this.#forgetMember(key)
    if (!this.#banned.has(entry.userId)) this.#system(`${remoteName(entry.user)} left`)
    if (key === this.hostKey) this.#migrateHost()
  }

  /** A member left: its signals, voice, invites and requests go. */
  #forgetMember (key) {
    this.signals.update(signals => {
      delete signals[key]
      return signals
    })
    this.#lastSeen.delete(key)
    this.#presence.delete(key)
    this.#forgetVoice(key)
    // v2.5: its invite prompt and its requests can't be answered anymore.
    this.#removeInvite(key)
    const requests = this.requests.value.filter(request => request.userId === key)
    if (requests.length) {
      for (const request of requests) {
        clearTimeout(this.#requestTimers.get(request.id))
        this.#requestTimers.delete(request.id)
      }
      this.requests.update(list => list.filter(request => request.userId !== key))
    }
    for (const [id, owner] of this.#requestOwners) if (owner === key) this.#requestOwners.delete(id)
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
    if (this.#destroyed || !peer) return
    if (this.#bannedPeers.has(peer.id)) {
      this.#closePeer(peer.id)
      return
    }
    // v2.5: P2PT emits 'peerconnect' once, when the first channel of a peer opens. If that channel failed and a backup
    // one opened instead, it never comes: a message on a channel we never saw introduces the peer now (else the
    // link is one-way: we would never send it anything).
    if (!this.#channels.has(peer.id) && this.#p2pt?.peers?.[peer.id]) this.#onPeerconnect(peer)
    if (typeof data === 'string') {
      // v2.5: nothing longer than MAX_EVENT_CHARS is parsed.
      if (data.length > MAX_EVENT_CHARS) return
      try {
        data = JSON.parse(data)
      } catch (error) {
        debug('Ignoring malformed message', error)
        return
      }
    }
    if (!data || typeof data !== 'object' || typeof data.type !== 'string') return
    const type = data.type
    // v2.5: one validation layer, every payload is cleaned (types, ranges, lengths) or the event is dropped.
    const payload = validateEvent(type, data.payload)
    if (payload === null) {
      debug('Ignoring invalid or unknown message', type)
      return
    }
    if (!QUIET_EVENTS.has(type)) debug(`#onMsg: ${peer.id} ${JSON.stringify(data)}`)

    const entry = this.peers.value[peer.id]
    /** @type {Sender} */
    const sender = { peer, key: entry?.key ?? String(peer.id), userId: entry?.userId ?? String(peer.id), client: entry?.client }
    if (this.#banned.has(sender.userId)) {
      this.#closePeer(peer.id)
      return
    }
    const now = Date.now()
    this.#lastSeen.set(sender.key, now)
    // v2.5: chat, reactions, requests, invites and queue changes: a burst, then a few per second. v2.6: `init`, `ping`
    // and voice offers too, and per data channel (sending `init` with new ids does not reset them).
    const rate = rateClass(type, payload)
    if (rate) {
      let buckets = this.#rates.get(peer.id)
      if (!buckets) this.#rates.set(peer.id, (buckets = new Map()))
      const bucket = rateStep(buckets.get(rate), now, RATE_LIMITS[rate])
      buckets.set(rate, bucket)
      if (!bucket.allowed) {
        debug('Rate limited', sender.key, type)
        return
      }
    }

    switch (type) {
      case EventTypes.SessionInitEvent:
        this.#onInit(peer, payload)
        break
      case EventTypes.MediaEvent:
        this.#onMedia(sender, payload)
        break
      case EventTypes.MediaIndexEvent:
        this.#onIndex(sender, payload)
        break
      case EventTypes.PlayerStateEvent:
        this.#onPlayer(sender, payload)
        break
      case EventTypes.MessageEvent:
        this.#onMessage(sender, payload)
        break
      case EventTypes.HostEvent:
        this.#onHost(sender, payload)
        break
      case EventTypes.StatusEvent:
        this.#onStatus(sender.key, payload)
        break
      case EventTypes.PingEvent:
        this.#sendEvent(peer, new Event(EventTypes.PongEvent, payload))
        break
      case EventTypes.PongEvent:
        this.#onPong(sender.key, payload)
        break
      case EventTypes.RequestEvent:
        this.#onRequest(sender.key, payload)
        break
      case EventTypes.RequestReplyEvent:
        this.#onRequestReply(sender.key, payload)
        break
      case EventTypes.KickEvent:
        this.#onKick(sender.key, payload)
        break
      case EventTypes.ReactionEvent:
        this.#showReaction(sender.key, payload.emoji)
        break
      case EventTypes.CountdownEvent:
        this.#onCountdown(sender.key, payload)
        break
      case EventTypes.InviteEvent:
        this.#onInvite(sender.key, payload)
        break
      case EventTypes.VoiceEvent:
        this.#onVoice(sender.key, payload)
        break
      case EventTypes.VoiceSignalEvent:
        this.#onVoiceSignal(sender.key, payload)
        break
      case EventTypes.QueueEvent:
        this.#onQueue(sender.key, payload)
        break
      case EventTypes.QueueAddEvent:
        if (this.isHost) this.#hostQueueChange({ type: 'add', item: payload.item, by: sender.userId, byName: this.nameOf(sender.key), byHost: false })
        break
      case EventTypes.QueueVoteEvent:
        if (this.isHost) this.#hostQueueChange({ type: 'vote', id: payload.id, by: sender.userId, up: payload.up })
        break
      case EventTypes.QueueRemoveEvent:
        if (this.isHost) this.#hostQueueChange({ type: 'remove', id: payload.id, by: sender.userId, byHost: false })
        break
      default:
        debug('Ignoring unknown message type', data)
    }
  }

  // ---------------------------------------------------------------- incoming events

  /**
   * @param {import('p2pt').Peer} peer
   * @param {Record<string, any>} user the cleaned `init` (sync.js validateEvent)
   */
  #onInit (peer, user) {
    const userId = String(user.id)
    const sessionId = user.sessionId ?? null
    const claimed = memberKey(userId, sessionId)
    if (this.#banned.has(userId)) {
      this.#bannedPeers.add(peer.id)
      this.#closePeer(peer.id)
      return
    }
    // Our own instance (a channel back to ourselves, or someone copying our session id).
    if (claimed === this.selfKey) return
    const previous = this.peers.value[peer.id]
    // v2.6: a channel keeps the identity of its first `init` (an app never changes its id or session id in a lobby):
    // a later `init` may only update the name, never make it another member.
    if (previous && (previous.userId !== userId || (previous.sessionId ?? null) !== sessionId)) {
      debug('Ignoring an init that changes the identity of', peer.id)
      return
    }
    // v2.6: a member key belongs to the first open channel that claimed it. Another channel with the same ids is a
    // separate member without authority (sync.js shadowKey): it can't take the host's role by copying its ids.
    const owned = !previous && Object.entries(this.peers.value).some(([peerId, entry]) => peerId !== peer.id && entry.peer && entry.key === claimed)
    const shadow = previous ? !!previous.shadow : owned
    const key = previous?.key ?? (shadow ? shadowKey(claimed, peer.id) : claimed)
    const known = this.#hasMember(key)
    this.peers.update(peers => {
      peers[peer.id] = {
        peer,
        user,
        userId,
        sessionId,
        key,
        shadow,
        // A v1 client sends no `protocol`.
        protocol: isFiniteNumber(user.protocol) ? user.protocol : 1,
        client: user.client,
        // v2.4: what the client can do ("voice", "queue").
        features: user.features
      }
      return peers
    })
    const now = Date.now()
    this.#lastSeen.set(key, now)
    if (this.#firstPeerAt === null) this.#firstPeerAt = now
    if (!known) {
      this.signals.update(signals => {
        signals[key] = { ...(signals[key] || {}), joinedAt: now }
        return signals
      })
      this.#system(`${remoteName(user)} joined`)
    }
  }

  /**
   * @param {Sender} sender
   * @param {{ media: any, episode: any, key: string }} shared
   */
  #onMedia (sender, shared) {
    // v2.5: in `host` mode only the host changes the lobby media.
    if (this.effectiveMode === 'host' && sender.key !== this.hostKey) return
    const localKey = mediaKey(shared)
    // Keep the sender's key so every client of the lobby (older apps too) compares the same string. v2.6: an episode
    // we already share, written another way ("21::5" for "21:5"), is no change: re-applying it made two players
    // reload each other forever.
    const key = shared.key || localKey
    if (this.media && sameMediaKey(key, this.media.key)) return
    this.#setMedia({ ...shared, key, localKey })
    // Watching on our own: remember the lobby media for "Rejoin", but do not start it.
    if (!this.isFollowing) {
      if (this.rejoinOffer.value) this.rejoinOffer.value = { media: shared.media, episode: shared.episode, key }
      return
    }
    // v2.3: nothing starts on its own for a newcomer (the lobby state sent after init) or an idle member:
    // they get the Join card. A follower already watching moves on to the new title.
    if (!this.#appliesLobbyState(sender.key)) return
    this.#launched = { media: shared.media, episode: shared.episode, key }
    this.#play(this.media)
  }

  /**
   * @param {Sender} sender
   * @param {{ index: number, kind?: 'file' | 'episode', mediaKey?: string }} payload
   */
  #onIndex (sender, payload) {
    // v2.5: only the host in `host` mode; an episode-list position (iOS) means nothing in our file list; and not
    // from another episode than ours.
    if (this.effectiveMode === 'host' && sender.key !== this.hostKey) return
    if (indexKind(payload, sender.client) !== 'file') return
    if (!sameEpisode(payload.mediaKey, this.local.mediaKey)) return
    if (this.index?.index === payload.index) return
    this.index = { index: payload.index }
    if (this.#appliesLobbyState(sender.key) && !!this.media && sameMediaKey(this.local.mediaKey, this.media.key)) this.emit('index', payload.index)
  }

  /** v2.3: a lobby `media` / `index` starts our player only when following, watching, and not the newcomer state. */
  #appliesLobbyState (senderKey) {
    return autoStartsMedia({ following: this.isFollowing, localState: this.local.state, senderJoinedAt: this.#joinedAt(senderKey), now: Date.now() })
  }

  /** When a member's `init` was received (start of its INITIAL_STATE_MS window). */
  #joinedAt (key) {
    const signals = this.signals.value
    return Object.hasOwn(signals, key) ? signals[key].joinedAt : undefined
  }

  /** Our player is on that media key (canonical comparison: "21::5" of an older app is "21:5"). */
  #onLocalKey (key) {
    return sameMediaKey(key ?? '', this.local.mediaKey ?? '')
  }

  /**
   * Starts a shared media in our player ('media', then w2g-play in the app). v2.6: not when our player already plays
   * or loads that episode (it would load it again); with `pending` (Join, invite, Rejoin, Play now waiting for the
   * episode to load), the pending step runs at once if it is loaded, else when the player reports it ready.
   * @param {SharedMedia & { localKey?: string }} shared
   * @param {{ pending?: boolean }} [options]
   */
  #play (shared, { pending = false } = {}) {
    const local = this.local
    const playing = local.state !== 'idle' && !!local.mediaKey && (this.#onLocalKey(shared.key) || (!!shared.localKey && this.#onLocalKey(shared.localKey)))
    if (!playing) {
      this.emit('media', shared)
      return
    }
    debug(`#play: already on ${local.mediaKey}`)
    if (pending && local.state !== 'loading') this.playerReady()
  }

  /**
   * @param {Sender} sender
   * @param {{ time: number, paused: boolean, by?: string, action?: string, rate?: number, mediaKey?: string }} payload
   */
  #onPlayer (sender, payload) {
    // v2.5: in `host` mode only what comes from the host's own channel is applied: `by` is just a name.
    if (this.effectiveMode === 'host' && sender.key !== this.hostKey) {
      debug(`Ignoring player event of ${sender.key}: only the host controls playback`)
      return
    }
    // Who is named: the sender (v1 senders omit `by`), or the member it acts for.
    const by = payload.by != null && !sameId(payload.by, sender.userId) ? payload.by : sender.key
    const { time, paused } = payload
    const now = Date.now()
    const hasAction = !!payload.action
    let action = hasAction ? payload.action : inferAction(this.player, { paused })
    const reference = this.#localTime(now) ?? this.player.time
    // v1 clients echo every state they apply: a "seek" that moves nothing is not announced.
    if (!hasAction && action === 'seek' && isFiniteNumber(reference) && Math.abs(time - reference) < IN_SYNC_S) action = 'sync'
    const rate = normalizeRate(payload.rate)

    this.player = { time, paused }
    if (sender.key === this.hostKey) this.#lastHostPlayer = { time, paused, rate, at: now }
    // Watching on our own: keep track of the lobby, but do not apply nor announce over the video. Neither from
    // another episode: v2.5 senders say which one (`mediaKey`); for older ones, our player on another media than
    // the lobby's (e.g. the sync sent to a newcomer).
    const otherMedia = payload.mediaKey
      ? !sameEpisode(payload.mediaKey, this.local.mediaKey)
      : !!this.local.mediaKey && !!this.media?.key && !sameMediaKey(this.local.mediaKey, this.media.key)
    // v2.6: nor the lobby state a member sends right after its `init` (the host's `player` sync to a newcomer), as for
    // `media` and `index`: remembered, not applied (same rule as the iOS app).
    const initial = isInitialState({ senderJoinedAt: this.#joinedAt(sender.key), now })
    const following = this.isFollowing && !otherMedia && !initial
    if (following) {
      this.#cancelCountdown()
      this.emit('player', { time, paused, action, by, rate })
    }

    if (action === 'sync') return
    const delta = following && action === 'seek' && isFiniteNumber(reference) ? time - reference : null
    const text = describeAction({ name: this.nameOf(by), action, time, delta })
    if (!text) return
    this.#system(text)
    if (following) this.emit('notice', { text, by, action })
  }

  /**
   * @param {Sender} sender
   * @param {string} message
   */
  #onMessage (sender, message) {
    // A message can arrive before the sender introduced itself.
    const user = this.peers.value[sender.peer.id]?.user || { id: sender.peer.id }
    this.#push({ message, user, type: 'incoming', date: new Date() })
    this.emit('chat', { userId: sender.key, name: remoteName(user), user, message })
  }

  /**
   * @param {Sender} sender
   * @param {{ hostId: string, mode: 'everyone' | 'host', hostSession?: string }} payload
   */
  #onHost (sender, payload) {
    const hostKey = resolveHostKey({ hostId: payload.hostId, hostSession: payload.hostSession, sender, members: this.#identities() })
    const next = { hostId: payload.hostId, hostKey, mode: payload.mode, tentative: false }
    const { hostKey: current, tentative } = this.lobby.value
    // Accept `host` only from the current host, or from anyone while no host is known.
    if (current != null && !tentative && sender.key !== current) {
      // Two hosts (after a split or a reconnect): the smallest key keeps the role.
      const rivalClaim = this.isHost && hostKey === sender.key
      if (!(rivalClaim && sender.key < this.selfKey)) {
        if (this.isHost) this.#sendEvent(sender.peer, this.#hostEvent(this.selfKey, this.mode))
        return
      }
      // v2.5: we yield. The members who follow us only take `host` from us: pass the winner on, or they would keep
      // a host that no longer acts as one.
      this.#setLobby(next)
      this.#sendToPeers(this.#hostEvent(hostKey, next.mode))
      return
    }
    this.#setLobby(next)
  }

  #onStatus (key, status) {
    const now = Date.now()
    this.signals.update(signals => {
      signals[key] = { ...(signals[key] || {}), status, receivedAt: now }
      return signals
    })
    if (key !== this.selfKey) {
      const { presence, announcements } = presenceOnStatus(this.#presence.get(key), status, now)
      this.#presence.set(key, presence)
      this.#announce(key, announcements)
    }
    if (key === this.hostKey && !this.isHost) this.#checkAutoSync(now)
    this.#checkFirstJoin(now)
  }

  #onPong (key, payload) {
    const now = Date.now()
    // v2.5: smoothed, without samples above 5 s or from pings sent before the app was frozen.
    const rtt = nextRtt(this.signals.value[key]?.rtt, { sentAt: payload.sentAt, now, resumedAt: this.#resumedAt })
    this.signals.update(signals => {
      signals[key] = { ...(signals[key] || {}), ...(rtt === null ? {} : { rtt }), pongAt: now }
      return signals
    })
  }

  #onRequest (key, payload) {
    const { id, kind } = payload
    const name = this.nameOf(key)
    this.#requestOwners.set(id, key)
    this.#system(describeRequest(name, { kind, time: payload.time }))
    if (!this.isHost || this.#requestTimers.has(id)) return
    /** @type {HostRequest} */
    const request = { id, kind, time: kind === 'seek' ? payload.time : undefined, userId: key, name, expiresAt: Date.now() + REQUEST_TIMEOUT_MS }
    this.requests.update(list => [...list.filter(item => item.id !== id), request])
    // No answer within 15 s counts as declined.
    this.#requestTimers.set(id, setTimeout(() => this.answerRequest(id, false, true), REQUEST_TIMEOUT_MS))
    this.emit('request', request)
  }

  #onRequestReply (key, payload) {
    if (key !== this.hostKey) return
    const id = payload.id
    const mine = this.#myRequests.delete(id)
    const owner = this.#requestOwners.get(id)
    this.#requestOwners.delete(id)
    const whose = mine ? 'your' : owner ? `${this.nameOf(owner)}'s` : 'a'
    const text = `${this.nameOf(key)} ${payload.accepted ? 'accepted' : 'declined'} ${whose} request`
    this.#system(text)
    if (mine) this.emit('info', { text })
  }

  #onKick (key, payload) {
    if (key !== this.hostKey) return
    const target = payload.userId
    if (sameId(target, this.selfId)) {
      this.emit('kicked')
      return
    }
    this.#ban(target)
  }

  #onCountdown (key, payload) {
    if (key !== this.hostKey && this.effectiveMode !== 'everyone') return
    const seconds = payload.seconds
    // startAt is on the sender's clock: count from the reception, minus half the trip.
    const rtt = this.signals.value[key]?.rtt
    const endsAt = Date.now() + seconds * 1000 - (isFiniteNumber(rtt) ? rtt / 2 : 0)
    // Watching on our own: not applied. v2.4: nor on another episode than the lobby's; v2.5: nor than the sender's.
    const applies = appliesCountdown({ localKey: this.local.mediaKey, lobbyKey: this.media?.key }) && sameEpisode(payload.mediaKey, this.local.mediaKey)
    if (this.isFollowing && applies) this.#runCountdown({ time: payload.time, seconds, endsAt, by: key })
    this.#system(`${this.nameOf(key)} started a countdown`)
  }

  // ---------------------------------------------------------------- host, sync, helpers

  /** @param {{ hostId: string | null, hostKey: string | null, mode: 'everyone' | 'host', tentative: boolean }} next */
  #setLobby (next) {
    const previous = this.lobby.value
    this.lobby.value = next
    if (!next.tentative) {
      // A host is confirmed: the next election starts over.
      clearTimeout(this.#tentativeTimer)
      this.#tentativeTimer = null
      this.#electionSkip.clear()
    }
    const hostChanged = previous.hostKey !== next.hostKey
    if (hostChanged) {
      this.#autoSync = null
      this.#lastHostPlayer = null
      if (next.hostKey != null) this.#system(next.hostKey === this.selfKey ? 'You are now the host' : `${this.nameOf(next.hostKey)} is now the host`)
      if (previous.hostKey === this.selfKey) {
        // No longer host: pending requests go to the new host.
        for (const timer of this.#requestTimers.values()) clearTimeout(timer)
        this.#requestTimers.clear()
        this.requests.value = []
        this.cancelAdvance()
        this.#pendingQueueStart = null
      }
      // v2.4: a new host takes over its copy of the queue and shares it at once.
      if (next.hostKey === this.selfKey && !next.tentative) {
        this.#queueKnown = true
        this.#sendToPeers(new Event(EventTypes.QueueEvent, this.queue.value))
      }
    }
    if (previous.mode !== next.mode) this.#system(next.mode === 'host' ? 'Only the host controls playback now' : 'Everyone can control playback now')
  }

  /**
   * The host left: the smallest member key among us and the connected v2 peers takes over. v2.5: a v1 client is never
   * elected, and an elected member that does not claim the role within TENTATIVE_HOST_MS is skipped.
   */
  #migrateHost () {
    clearTimeout(this.#tentativeTimer)
    this.#tentativeTimer = null
    // Independent members are skipped, unless nobody follows.
    const elected = electFollowingHost({ selfId: this.selfKey, selfFollowing: this.isFollowing, peers: this.#electionPeers(), skip: this.#electionSkip }) ?? this.selfKey
    if (elected === this.selfKey) {
      this.#setLobby({ hostId: this.selfId, hostKey: this.selfKey, mode: this.mode, tentative: false })
      this.#sendToPeers(this.#hostEvent(this.selfKey, this.mode))
      return
    }
    // Until the elected client confirms with `host`, accept a claim from anyone.
    this.#setLobby({ hostId: this.#memberOf(elected)?.userId ?? elected, hostKey: elected, mode: this.mode, tentative: true })
    this.#tentativeTimer = setTimeout(() => {
      this.#tentativeTimer = null
      const { hostKey, tentative } = this.lobby.value
      if (this.#destroyed || !tentative || hostKey !== elected) return
      this.#electionSkip.add(elected)
      this.#migrateHost()
    }, TENTATIVE_HOST_MS)
  }

  #checkAutoSync (now) {
    const host = this.signals.value[this.hostKey]
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
    this.#applyLocally({ time: result.seekTo, paused: false, action: 'sync', by: this.hostKey })
  }

  /** Applies a state to our player without broadcasting or announcing it. */
  #applyLocally ({ time, paused, action, by }) {
    this.player = { time, paused }
    this.emit('player', { time, paused, action, by, rate: 1 })
  }

  #hostTarget (now) {
    if (this.hostKey == null || this.isHost) return null
    const host = this.signals.value[this.hostKey]
    // v2.5: the last `player` event only stands for the position of a v1 host, which sends no `status`.
    const protocol = this.#memberOf(this.hostKey)?.protocol
    const lastPlayer = protocol != null && protocol < PROTOCOL_VERSION ? this.#lastHostPlayer : null
    return hostReference({ status: host?.status, receivedAt: host?.receivedAt, rtt: host?.rtt, lastPlayer }, now)
  }

  /** The lobby media changes: the host's last `player` event was about the previous one. */
  #setMedia (media) {
    if (!sameMediaKey(media?.key ?? '', this.media?.key ?? '')) this.#lastHostPlayer = null
    this.media = media
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

  /** Kicks name accounts: every device of that userId is removed. */
  #ban (userId) {
    if (this.#banned.has(userId)) return
    const user = this.#memberByUserId(userId)?.user
    this.#banned.add(userId)
    const keys = new Set()
    for (const [peerId, entry] of Object.entries(this.peers.value)) {
      if (!entry.peer || entry.userId !== userId) continue
      keys.add(entry.key)
      this.#bannedPeers.add(peerId)
      this.#closePeer(peerId)
    }
    this.peers.update(peers => {
      for (const [peerId, entry] of Object.entries(peers)) if (entry.peer && entry.userId === userId) delete peers[peerId]
      return peers
    })
    for (const key of keys) this.#forgetMember(key)
    this.#system(`${remoteName(user ?? { id: userId })} was removed from the lobby`)
  }

  #showReaction (key, emoji) {
    const isSelf = key === this.selfKey
    const name = this.nameOf(key)
    this.#system(`${name} reacted ${emoji}`, { emoji })
    this.emit('reaction', { emoji, userId: key, name, isSelf })
  }

  /**
   * A member by key: ourselves, or a connected peer that introduced itself.
   * @param {string | null | undefined} key
   * @returns {PeerEntry | null}
   */
  #memberOf (key) {
    if (key == null) return null
    if (key === this.selfKey) return { user: this.self, userId: this.selfId, sessionId: this.sessionId, key: this.selfKey, protocol: PROTOCOL_VERSION }
    for (const entry of Object.values(this.peers.value)) if (entry.peer && entry.key === key) return entry
    return null
  }

  /** The first connected member with that `init.id` (names of older events, which only carry the id). */
  #memberByUserId (userId) {
    for (const entry of Object.values(this.peers.value)) if (entry.peer && sameId(entry.userId, userId)) return entry
    return null
  }

  #hasMember (key) {
    return Object.values(this.peers.value).some(entry => entry.peer && entry.key === key)
  }

  /** Every member we know, ourselves included: key and `init.id` (v2.6: not the channels that copied another's ids). */
  #identities () {
    const list = [{ key: this.selfKey, userId: this.selfId }]
    for (const entry of Object.values(this.peers.value)) if (entry.peer && entry.key && !entry.shadow) list.push({ key: entry.key, userId: entry.userId })
    return list
  }

  /** Connected peers with their protocol and last `following`, one per member. */
  #peerSummaries () {
    const signals = this.signals.value
    const seen = new Map()
    for (const entry of Object.values(this.peers.value)) {
      if (!entry.peer || !entry.key || this.#banned.has(entry.userId) || seen.has(entry.key)) continue
      seen.set(entry.key, { key: entry.key, userId: entry.userId, sessionId: entry.sessionId, protocol: entry.protocol, following: signals[entry.key]?.status?.following, shadow: !!entry.shadow })
    }
    return [...seen.values()]
  }

  /** Candidates of a host election or hand-off, named by member key. v2.6: never a channel that copied another's ids. */
  #electionPeers () {
    return this.#peerSummaries().filter(peer => !peer.shadow).map(({ key, protocol, following }) => ({ userId: key, protocol, following }))
  }

  /** Jump to the host's expected position now (resync after following again, "Rejoin"). */
  #syncToHost (now) {
    const target = this.#hostTarget(now)
    if (!target || (target.mediaKey !== null && !this.#onLocalKey(target.mediaKey))) return false
    this.#applyLocally({ time: target.time, paused: target.paused, action: 'sync', by: this.hostKey })
    return true
  }

  /** Presence lines (v2.1 / v2.2): a system line plus a 3 s notice over the video. */
  #announce (key, announcements) {
    for (const announcement of announcements) {
      const text = describePresence(this.nameOf(key), announcement)
      if (!text) continue
      this.#system(text)
      this.emit('notice', { text, by: key, presence: announcement.kind })
    }
  }

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
    const members = [{ userId: this.selfKey, status: { ...this.local, following: this.isFollowing } }]
    for (const { key, protocol } of this.#peerSummaries()) {
      if (protocol >= 2 || signals[key]?.status) members.push({ userId: key, status: signals[key]?.status ?? null })
    }
    return members
  }

  /** v2.3 reference member of the lobby playback (member key), null when the lobby is not watching. */
  #lobbyReferenceId () {
    return lobbyReference({ lobbyKey: this.media?.key, hostId: this.hostKey, members: this.#statusMembers() })
  }

  /** Expected position of a member: ours, or extrapolated from its last status. */
  #memberPosition (key, now) {
    if (key == null) return null
    if (key === this.selfKey) {
      const time = this.#localTime(now)
      return time === null ? null : { time, paused: this.local.state !== 'playing' && this.local.state !== 'buffering' }
    }
    const signal = this.signals.value[key]
    return hostReference({ status: signal?.status, receivedAt: signal?.receivedAt, rtt: signal?.rtt }, now)
  }

  /** v2.3 media an invite offers, and the lobby reference. */
  #offered () {
    const ownActive = this.local.state !== 'idle' && !!this.#launched && !!this.local.mediaKey && this.#onLocalKey(this.#launched.key)
    const reference = this.#lobbyReferenceId()
    const offered = offeredMedia({ ownKey: this.#launched?.key, ownActive, lobbyKey: this.media?.key, lobbyWatching: reference !== null })
    return { offered, reference }
  }

  /** v2.3 offer for an invite: media plus the position to send. */
  #offer (now) {
    const { offered, reference } = this.#offered()
    if (!offered) return null
    const media = offered.from === 'own' ? this.#launched : this.media
    const position = invitePosition({ offered, own: this.#memberPosition(this.selfKey, now), reference: this.#memberPosition(reference, now) })
    return { offered, media, position }
  }

  /** Time-based presence: long buffering, lost connection. */
  #tickPresence () {
    if (this.#destroyed) return
    const now = Date.now()
    // v2.5: ticks far apart: the app was frozen (sleep, throttled window). Pongs of the pings sent before are no
    // round-trip samples.
    if (this.#lastTickAt && now - this.#lastTickAt > SUSPENDED_GAP_MS) this.#resumedAt = now
    this.#lastTickAt = now
    const signals = this.signals.value
    for (const [key, presence] of this.#presence) {
      const signal = signals[key]
      const result = presenceOnTick(presence, { now, lastStatusAt: signal?.receivedAt, lastPongAt: signal?.pongAt })
      if (result.presence) this.#presence.set(key, result.presence)
      this.#announce(key, result.announcements)
    }
  }

  #onInvite (key, payload) {
    if (!acceptsInvite({ to: payload.to, toSession: payload.toSession, selfId: this.selfId, sessionId: this.sessionId, senderId: key, selfKey: this.selfKey, hostId: this.hostKey, effectiveMode: this.effectiveMode })) return
    const invitationKey = payload.key || mediaKey(payload)
    /** @type {Invite} */
    const invite = {
      from: key,
      name: this.nameOf(key),
      media: payload.media,
      episode: payload.episode,
      key: invitationKey,
      time: payload.time,
      paused: payload.paused,
      receivedAt: Date.now()
    }
    // A new invite from the same sender replaces the previous one.
    this.invites.update(list => [...list.filter(item => item.from !== key), invite])
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

  #hasFeature (key, feature) {
    return Object.values(this.peers.value).some(entry => entry.peer && entry.key === key && entry.features?.includes(feature))
  }

  /** Sends an event to one member (its first open channel). */
  #sendToMember (key, event) {
    if (key == null) return false
    for (const [peerId, entry] of Object.entries(this.peers.value)) {
      const channel = this.#channels.get(peerId)
      if (!entry.peer || !channel || entry.key !== key || this.#bannedPeers.has(peerId)) continue
      this.#sendEvent(channel, event)
      return true
    }
    return false
  }

  /** Of us and that member, we offer the audio link (both sides compare the same ids, see sync.js pairIds). */
  #selfOffers (key) {
    const member = this.#memberOf(key)
    if (!member || key === this.selfKey) return false
    const [self, other] = pairIds({ userId: this.selfId, sessionId: this.sessionId }, member)
    return voiceOffers(self, other)
  }

  #memberInVoice (key) {
    return !!this.voiceStates.value[key]?.joined && this.#hasFeature(key, 'voice') && this.#hasMember(key)
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

  #onVoice (key, state) {
    if (key === this.selfKey) return
    const previous = this.voiceStates.value[key]
    this.voiceStates.update(states => {
      states[key] = state
      return states
    })
    if (state.joined !== !!previous?.joined && (previous || state.joined)) {
      this.#system(`${this.nameOf(key)} ${state.joined ? 'joined' : 'left'} voice`)
      // Joined again: a link that gave up before can be tried at once.
      if (state.joined) this.#voice.resetRetries(key)
    }
    this.#syncVoiceLinks()
    this.#updateDuck()
  }

  #onVoiceSignal (key, payload) {
    if (payload.sdp.type === 'offer') {
      const member = this.#memberOf(key)
      if (!member) return
      const [self, sender] = pairIds({ userId: this.selfId, sessionId: this.sessionId }, member)
      if (!acceptsVoiceOffer({ selfJoined: this.#voice.joined, memberJoined: this.#memberInVoice(key), selfId: self, senderId: sender })) return
    }
    this.#voice.signal(key, payload)
  }

  /** Creates the links we offer and closes the ones nobody needs anymore. */
  #syncVoiceLinks () {
    const members = new Set(this.#peerSummaries().map(peer => peer.key))
    for (const key of members) {
      const action = voiceLinkAction({
        selfJoined: this.#voice.joined,
        memberJoined: !!this.voiceStates.value[key]?.joined,
        memberHasVoice: this.#hasFeature(key, 'voice'),
        hasLink: this.#voice.hasLink(key),
        selfOffers: this.#selfOffers(key)
      })
      if (action === 'offer') this.#voice.connect(key)
      else if (action === 'close') this.#voice.close(key)
    }
    for (const key of Object.keys(this.#voice.linkStates())) if (!members.has(key)) this.#voice.close(key)
  }

  /** Lowers the video while a member we hear speaks (setting `w2gVoiceDucking`). */
  #updateDuck () {
    if (this.#destroyed) return
    const states = this.voiceStates.value
    const members = this.#peerSummaries().map(({ key }) => {
      const mix = this.#voice.mixOf(key)
      return { ...(states[key] ?? VOICE_OFF), localMuted: mix.muted, volume: mix.volume }
    })
    voiceDuck.value = duckLevel({ enabled: settings.value.w2gVoiceDucking !== false, selfJoined: this.#voice.joined, members })
  }

  /** A member left the lobby or was kicked: no more voice with it. */
  #forgetVoice (key) {
    this.#voice.forget(key)
    if (this.voiceStates.value[key]) {
      this.voiceStates.update(states => {
        delete states[key]
        return states
      })
    }
    this.#updateDuck()
  }

  #onQueue (key, payload) {
    if (this.isHost || !acceptsQueue({ senderId: key, hostId: this.hostKey, tentative: this.lobby.value.tentative })) return
    this.#applyQueue(payload)
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
