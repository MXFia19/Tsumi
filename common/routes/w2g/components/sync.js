/*
 * Watch Together v2: the pure part of the protocol (see ../PROTOCOL.md).
 * No DOM, no app imports: the client (w2g.js), the UI and the Node test
 * (sync.test.mjs) all use it, so the rules stay in one place.
 */

export const PROTOCOL_VERSION = 2

/** Heartbeat period: `status` every 3 s (PROTOCOL "Sync check"). */
export const HEARTBEAT_MS = 3_000
/** `ping` to every peer every 10 s. */
export const PING_MS = 10_000
/** A member without `status` for 10 s shows "No signal". */
export const NO_SIGNAL_MS = 10_000
/**
 * A paused or idle member has nothing new to report. If it only sends `status` on
 * changes, its pings (every 10 s) keep it alive for this long before "No signal".
 */
export const STATIC_SIGNAL_MS = 25_000
/** "In sync" when |drift| <= 1.5 s. */
export const IN_SYNC_S = 1.5
/** Auto-sync when |drift| > 2 s ... */
export const AUTO_SYNC_S = 2
/** ... for two consecutive host heartbeats ... */
export const AUTO_SYNC_STREAK = 2
/** ... at most once every 10 s. */
export const AUTO_SYNC_COOLDOWN_MS = 10_000
/** A host request prompt counts as declined after 15 s. */
export const REQUEST_TIMEOUT_MS = 15_000
/** Action notices over the video. */
export const NOTICE_MS = 3_000
/** Chat bubbles over the video. */
export const BUBBLE_MS = 5_000
/** Default length of "Start together". */
export const COUNTDOWN_DEFAULT_S = 3
/** A local seek smaller than this is a player fix-up (audio track switch...), not a user action. */
export const SEEK_THRESHOLD_S = 0.5
/** How long a remotely applied state is expected to come back as local player events. */
export const EXPECT_MS = 10_000

// v2.5 limits on what a peer may send (PROTOCOL.md "v2.5 additions"). Anything outside them is dropped.
/** Longest event, in UTF-16 code units of its JSON text, checked before JSON.parse. */
export const MAX_EVENT_CHARS = 256_000
/** P2PT chunk index `c` must be below this (chunks are 16000 units, see MAX_EVENT_CHARS). */
export const MAX_CHUNKS = 64
/** Messages being reassembled at once per peer... */
export const MAX_PENDING_MESSAGES = 4
/** ... each dropped when its last chunk did not come within this time ... */
export const CHUNK_TIMEOUT_MS = 30_000
/** ... and every peer together buffers at most this many units. */
export const MAX_BUFFERED_CHARS = 2_000_000
/** Media positions (seconds) are taken in 0…MAX_TIME_S (about 115 days). */
export const MAX_TIME_S = 1e7
/** Episode, season and local episode numbers are taken in 0…MAX_EPISODE. */
export const MAX_EPISODE = 1e6
/** `index` is a whole number in 0…MAX_INDEX. */
export const MAX_INDEX = 9_999
/** Longest member name shown (AniList names have 20 characters at most, MyAnimeList 16). */
export const MAX_NAME_LENGTH = 32
/** Longest chat message. */
export const MAX_MESSAGE_LENGTH = 2048
/** Longest SDP of a `voiceSignal`. */
export const MAX_SDP_LENGTH = 64_000
/** Longest media key. */
export const MAX_KEY_LENGTH = 200

export const MODES = /** @type {const} */ (['everyone', 'host'])
export const STATES = /** @type {const} */ (['playing', 'paused', 'buffering', 'loading', 'idle'])
export const ACTIONS = /** @type {const} */ (['play', 'pause', 'seek', 'sync'])
export const REQUEST_KINDS = /** @type {const} */ (['pause', 'play', 'seek'])
export const REACTIONS = /** @type {const} */ (['😂', '😮', '😍', '😢', '👏', '🔥', '👀', '❤️'])
/** Same emoji without the variation selector, as some keyboards send it. */
const REACTION_ALIASES = { '❤': '❤️' }

/** @param {unknown} value */
export function isFiniteNumber (value) {
  return typeof value === 'number' && Number.isFinite(value)
}

/** Ids are compared as strings (PROTOCOL "Identity"). */
export function sameId (a, b) {
  return a != null && b != null && String(a) === String(b)
}

/** @param {unknown} mode */
export function normalizeMode (mode) {
  return mode === 'host' ? 'host' : 'everyone'
}

/** @param {unknown} state @returns {typeof STATES[number] | null} */
export function normalizeState (state) {
  return STATES.includes(/** @type {any} */ (state)) ? /** @type {any} */ (state) : null
}

/** @param {unknown} rate */
export function normalizeRate (rate) {
  return isFiniteNumber(rate) && rate > 0 && rate <= 16 ? rate : 1
}

/**
 * Only the eight protocol emoji are allowed, anything else is dropped.
 * @param {unknown} emoji
 * @returns {string | null}
 */
export function normalizeReaction (emoji) {
  if (typeof emoji !== 'string') return null
  const trimmed = emoji.trim()
  if (REACTIONS.includes(/** @type {any} */ (trimmed))) return trimmed
  return REACTION_ALIASES[trimmed] ?? null
}

/**
 * Countdown length, a whole number of seconds in 1-10. Missing or invalid values use the default.
 * @param {unknown} seconds
 */
export function normalizeCountdownSeconds (seconds) {
  const value = Number(seconds)
  if (seconds == null || !Number.isFinite(value)) return COUNTDOWN_DEFAULT_S
  return Math.min(10, Math.max(1, Math.round(value)))
}

/**
 * Name shown for a participant: AniList / MAL name, else the typed display name, else a short id.
 * @param {{ id?: unknown, name?: unknown, displayName?: unknown } | null | undefined} user
 */
export function memberName (user) {
  if (typeof user?.name === 'string' && user.name.trim()) return user.name.trim().slice(0, MAX_NAME_LENGTH)
  if (typeof user?.displayName === 'string' && user.displayName.trim()) return user.displayName.trim().slice(0, MAX_NAME_LENGTH)
  if (user?.id != null) return `Guest ${String(user.id).slice(0, 4)}`
  return 'Anonymous'
}

/**
 * Name of another member: memberName, but a remote member can't pass for us ("You paused at…").
 * @param {{ id?: unknown, name?: unknown, displayName?: unknown } | null | undefined} user
 */
export function remoteName (user) {
  const name = memberName(user)
  return /^you$/i.test(name) ? `${name} (${user?.id != null ? String(user.id).slice(0, 4) : 'guest'})` : name
}

/**
 * Smallest userId among self and the connected peers (string comparison), used for host migration.
 * @param {Array<string | number | null | undefined>} ids
 * @returns {string | null}
 */
export function electHost (ids) {
  let best = null
  for (const id of ids) {
    if (id == null || id === '') continue
    const value = String(id)
    if (best === null || value < best) best = value
  }
  return best
}

/**
 * expected(M) = s.time + (playing ? (now - r) / 1000 * s.rate + rtt / 2000 : 0)
 * @param {{ state: string, time: number, rate?: number } | null | undefined} status last status of the member
 * @param {number} receivedAt local time (ms) when it was received
 * @param {number} now local time (ms)
 * @param {number} [rttMs] last round-trip time to the member
 * @returns {number | null}
 */
export function expectedTime (status, receivedAt, now, rttMs = 0) {
  if (!status || !isFiniteNumber(status.time)) return null
  if (status.state !== 'playing') return status.time
  const elapsed = Math.max(0, now - receivedAt) / 1000
  const latency = isFiniteNumber(rttMs) && rttMs > 0 ? rttMs / 2000 : 0
  return status.time + elapsed * normalizeRate(status.rate) + latency
}

/** Drift = expected(M) - localTime. Positive: the member is ahead. */
export function computeDrift (expected, localTime) {
  return expected - localTime
}

/**
 * "12:34", or "1:02:03" past an hour.
 * @param {number} seconds
 */
export function formatClock (seconds) {
  const total = Math.min(MAX_TIME_S, Math.max(0, Math.floor(Number(seconds) || 0)))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = String(total % 60).padStart(2, '0')
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, '0')}:${secs}` : `${minutes}:${secs}`
}

/**
 * "+1:30" / "-0:05"
 * @param {number} seconds
 */
export function formatDelta (seconds) {
  const rounded = Math.round(Number(seconds) || 0)
  return (rounded < 0 ? '-' : '+') + formatClock(Math.abs(rounded))
}

/**
 * Text of an action notice / system line.
 * @param {{ name: string, action: string, time?: number, delta?: number | null }} change
 * @returns {string | null} null for `sync`, which is never announced
 */
export function describeAction ({ name, action, time, delta }) {
  switch (action) {
    case 'pause':
      return `${name} paused at ${formatClock(time)}`
    case 'play':
      return `${name} resumed`
    case 'seek':
      return `${name} jumped to ${formatClock(time)}${isFiniteNumber(delta) ? ` (${formatDelta(delta)})` : ''}`
    default:
      return null
  }
}

/**
 * Chat line for a request.
 * @param {string} name
 * @param {{ kind: string, time?: number }} request
 */
export function describeRequest (name, { kind, time }) {
  if (kind === 'pause') return `${name} asked to pause`
  if (kind === 'play') return `${name} asked to resume`
  return `${name} asked to jump to ${formatClock(time)}`
}

/**
 * Action of a v1 `player` event, which has no `action` field.
 * @param {{ paused: boolean } | null | undefined} previous last known lobby state
 * @param {{ paused: boolean }} next
 */
export function inferAction (previous, next) {
  if (!previous || typeof previous.paused !== 'boolean' || Boolean(previous.paused) !== Boolean(next.paused)) {
    return next.paused ? 'pause' : 'play'
  }
  return 'seek'
}

/**
 * @typedef {{ mediaId: string | number | null, title: string, episode: string }} NowPlaying
 * @typedef {{ state: string, time: number, mediaKey?: string, rate?: number, source?: string, following?: boolean, nowPlaying?: NowPlaying | null }} Status
 * @typedef {{ status?: Status | null, receivedAt?: number, rtt?: number, protocol?: number, lastSeen?: number, joinedAt?: number }} MemberSignal
 * @typedef {Status & { at: number }} LocalStatus our own status, `at` = when `time` was read
 * @typedef {{ kind: 'old' | 'nosignal' | 'connecting' | 'idle' | 'loading' | 'buffering' | 'other' | 'own' | 'sync' | 'ahead' | 'behind' | 'playing' | 'paused' | 'speed', text: string, drift?: number }} Badge
 */

/** "1.25×" */
export function formatRate (rate) {
  return `${Math.round(normalizeRate(rate) * 100) / 100}×`
}

/** v2.5: two playback rates differ (a member at 1.25× drifts on its own, auto-sync can't fix it). */
export function differentRate (a, b) {
  return Math.abs(normalizeRate(a) - normalizeRate(b)) > 0.001
}

/**
 * Label of our own row.
 * @param {LocalStatus | null | undefined} local
 * @returns {Badge}
 */
export function selfBadge (local) {
  switch (local?.state) {
    case 'playing': return { kind: 'playing', text: 'Playing' }
    case 'paused': return { kind: 'paused', text: 'Paused' }
    case 'buffering': return { kind: 'buffering', text: 'Buffering' }
    case 'loading': return { kind: 'loading', text: 'Loading' }
    default: return { kind: 'idle', text: 'Not in the player' }
  }
}

/**
 * Sync badge of another member, compared with our own player.
 * @param {MemberSignal} member `protocol` is 1 when its `init` had no `protocol` (v1 client)
 * @param {LocalStatus | null | undefined} local
 * @param {number} now
 * @returns {Badge}
 */
export function syncBadge (member, local, now) {
  const status = member?.status
  if (!status) {
    if (member?.protocol === 1) return { kind: 'old', text: 'Old version' }
    // v2.3: a v2 member is "No signal" only once 10 s passed after its `init` without any status.
    if (isFiniteNumber(member?.joinedAt) && now - member.joinedAt < NO_SIGNAL_MS) return { kind: 'connecting', text: 'Connecting…' }
    return { kind: 'nosignal', text: 'No signal' }
  }

  if (now - (member.receivedAt ?? 0) > NO_SIGNAL_MS) {
    const isStatic = status.state === 'paused' || status.state === 'idle'
    const alive = isStatic && isFiniteNumber(member.lastSeen) && now - member.lastSeen <= STATIC_SIGNAL_MS
    if (!alive) return { kind: 'nosignal', text: 'No signal' }
  }

  if (status.state === 'idle') return { kind: 'idle', text: 'Not in the player' }
  // v2.2: an independent member has no drift.
  if (status.following === false) return { kind: 'own', text: 'Watching on their own' }
  if (status.state === 'loading') return { kind: 'loading', text: 'Loading' }
  if (status.state === 'buffering') return { kind: 'buffering', text: 'Buffering' }

  // We are not watching: nothing to compare with, show what the member does.
  if (!local || local.state === 'idle' || local.state === 'loading') {
    return status.state === 'playing' ? { kind: 'playing', text: 'Playing' } : { kind: 'paused', text: 'Paused' }
  }

  if ((status.mediaKey || '') !== (local.mediaKey || '')) return { kind: 'other', text: 'Other episode' }

  const drift = computeDrift(expectedTime(status, member.receivedAt ?? now, now, member.rtt), expectedTime(local, local.at, now, 0))
  // v2.5: another playback rate drifts by itself; auto-sync leaves it alone, the badge says why.
  if (differentRate(status.rate, local.rate)) return { kind: 'speed', text: `Different speed (${formatRate(status.rate)})`, drift }
  const samePlayState = (status.state === 'playing') === (local.state === 'playing')
  if (samePlayState && Math.abs(drift) <= IN_SYNC_S) return { kind: 'sync', text: 'In sync', drift }
  const amount = (Math.round(Math.abs(drift) * 10) / 10).toFixed(1)
  return drift >= 0 ? { kind: 'ahead', text: `+${amount} s ahead`, drift } : { kind: 'behind', text: `${amount} s behind`, drift }
}

/**
 * One auto-sync decision, made on each heartbeat received from the host.
 * A non-host whose drift against the host stays above 2 s while both play the same
 * mediaKey for two consecutive heartbeats seeks to expected(host), at most once every 10 s.
 * @param {{ streak?: number, lastSyncAt?: number } | null | undefined} memory result of the previous step
 * @param {{ enabled: boolean, isHost: boolean, hostStatus: Status | null | undefined, hostReceivedAt: number, hostRtt?: number, local: LocalStatus | null | undefined, now: number }} input
 * @returns {{ streak: number, lastSyncAt: number, seekTo: number | null }}
 */
export function autoSyncStep (memory, { enabled, isHost, hostStatus, hostReceivedAt, hostRtt, local, now }) {
  const lastSyncAt = isFiniteNumber(memory?.lastSyncAt) ? memory.lastSyncAt : -Infinity
  const idle = { streak: 0, lastSyncAt, seekTo: null }
  if (!enabled || isHost || !hostStatus || !local) return idle
  if (hostStatus.following === false) return idle
  if (hostStatus.state !== 'playing' || local.state !== 'playing') return idle
  if ((hostStatus.mediaKey || '') !== (local.mediaKey || '')) return idle
  // v2.5: at another playback rate the drift grows again right after each jump.
  if (differentRate(hostStatus.rate, local.rate)) return idle

  const expected = expectedTime(hostStatus, hostReceivedAt, now, hostRtt)
  const localTime = expectedTime(local, local.at, now, 0)
  if (expected === null || localTime === null || Math.abs(computeDrift(expected, localTime)) <= AUTO_SYNC_S) return idle

  const streak = (memory?.streak || 0) + 1
  if (streak >= AUTO_SYNC_STREAK && now - lastSyncAt >= AUTO_SYNC_COOLDOWN_MS) return { streak: 0, lastSyncAt: now, seekTo: expected }
  return { streak, lastSyncAt, seekTo: null }
}

/**
 * Where a non-host should be to follow the host: from its last `status`, else from its
 * last applied `player` event (v1 host). Returns null when nothing usable is known.
 * v2.5: the `player` event is only used for a host that sends no `status` at all (v1). A v2 host that is idle,
 * loading or silent has no position: snapping back to its last `player` event would jump to a stale time.
 * @param {{ status?: Status | null, receivedAt?: number, rtt?: number, lastPlayer?: { time: number, paused: boolean, rate?: number, at: number } | null }} host
 * @param {number} now
 * @returns {{ time: number, paused: boolean, mediaKey: string | null } | null}
 */
export function hostReference ({ status, receivedAt, rtt, lastPlayer }, now) {
  // A paused status stays true until the next one; a playing one is only extrapolated for a while.
  const fresh = status && (status.state === 'paused' || now - (receivedAt ?? 0) <= NO_SIGNAL_MS * 3)
  if (fresh && (status.state === 'playing' || status.state === 'paused' || status.state === 'buffering')) {
    return {
      time: expectedTime(status, receivedAt ?? now, now, rtt),
      // A buffering host still means to play.
      paused: status.state === 'paused',
      mediaKey: status.mediaKey ?? ''
    }
  }
  if (status) return null
  if (lastPlayer && isFiniteNumber(lastPlayer.time)) {
    const elapsed = lastPlayer.paused ? 0 : Math.max(0, now - lastPlayer.at) / 1000 * normalizeRate(lastPlayer.rate)
    return { time: lastPlayer.time + elapsed, paused: !!lastPlayer.paused, mediaKey: null }
  }
  return null
}

// ---------------------------------------------------------------- v2.1: source, presence, invite

/** Same member and kind announces at most once every 5 s. */
export const PRESENCE_DEBOUNCE_MS = 5_000
/** "is buffering…" once a buffering period lasts more than 8 s. */
export const BUFFERING_ANNOUNCE_MS = 8_000
/** "lost connection" once "No signal" (no status, no pong) lasted 10 s: 10 s + 10 s without either. */
export const LOST_ANNOUNCE_MS = NO_SIGNAL_MS + 10_000
const WATCHING_STATES = ['loading', 'playing', 'paused']

/**
 * `status.source`: extension / addon name, then the server label, joined with " · ".
 * @param {...unknown} parts
 */
export function formatSource (...parts) {
  return parts.map(part => (typeof part === 'string' ? part.trim() : '')).filter(Boolean).join(' · ').slice(0, 80)
}

/**
 * Splits a media key (w2g.js mediaKey: "mediaId:episode" or "mediaId:season:episode").
 * @param {unknown} key
 * @returns {{ mediaId: string, season: string | null, episode: string } | null}
 */
export function parseMediaKey (key) {
  if (typeof key !== 'string' || !key) return null
  const parts = key.split(':')
  if (parts.length === 2) return { mediaId: parts[0], season: null, episode: parts[1] }
  if (parts.length === 3) return { mediaId: parts[0], season: parts[1] || null, episode: parts[2] }
  return null
}

const validPart = value => value != null && value !== '' && value !== 'undefined' && value !== 'null'

/**
 * "Episode 5", or "S2 E5" when a season is known. Null when there is no episode number.
 * @param {{ season?: unknown, episode?: unknown }} parts
 */
export function formatEpisode ({ season, episode }) {
  if (!validPart(episode)) return null
  return validPart(season) ? `S${season} E${episode}` : `Episode ${episode}`
}

/**
 * Label of the `episode` of a `media` / `invite` payload: a number, or { number, season?, localEpisode? }.
 * @param {unknown} episode
 */
export function episodeLabelOf (episode) {
  if (episode && typeof episode === 'object') {
    const value = /** @type {any} */ (episode)
    return formatEpisode({ season: value.season, episode: value.localEpisode ?? value.number })
  }
  return formatEpisode({ episode })
}

/**
 * Label for "Alice switched to {label}": the episode of the new key, or "another title" when the media differs.
 * @param {string} previousKey
 * @param {string} nextKey
 */
export function switchLabel (previousKey, nextKey) {
  const next = parseMediaKey(nextKey)
  const previous = parseMediaKey(previousKey)
  if (!next || (previous && previous.mediaId !== next.mediaId)) return 'another title'
  return formatEpisode(next) ?? 'another title'
}

/**
 * @typedef {{ kind: 'started' | 'again' | 'stopped' | 'switched' | 'source' | 'buffering' | 'lost' | 'own' | 'back' | 'watching', label?: string, source?: string }} Announcement
 * @typedef {{ status: (Status & { source?: string }) | null, bufferingSince: number | null, bufferingAnnounced: boolean, lostAnnounced: boolean, lastAt: Record<string, number> }} Presence
 */

/** @returns {Presence} */
export function createPresence () {
  return { status: null, bufferingSince: null, bufferingAnnounced: false, lostAnnounced: false, lastAt: {} }
}

/**
 * @param {Presence} presence
 * @param {Announcement[]} found
 * @param {number} now
 * @returns {{ presence: Presence, announcements: Announcement[] }}
 */
function debounceAnnouncements (presence, found, now) {
  const lastAt = { ...presence.lastAt }
  const announcements = []
  for (const announcement of found) {
    if (now - (lastAt[announcement.kind] ?? -Infinity) < PRESENCE_DEBOUNCE_MS) continue
    lastAt[announcement.kind] = now
    announcements.push(announcement)
  }
  return { presence: { ...presence, lastAt }, announcements }
}

/**
 * Presence announcements caused by a `status` received from another member (never for ourselves).
 * @param {Presence | null | undefined} presence state of that member, null before its first status
 * @param {Status & { source?: string }} status
 * @param {number} now
 * @returns {{ presence: Presence, announcements: Announcement[] }}
 */
export function presenceOnStatus (presence, status, now) {
  const current = presence ?? createPresence()
  const previous = current.status
  /** @type {Announcement[]} */
  const found = []
  if (!previous) {
    // The first status after joining only says "started watching".
    if (WATCHING_STATES.includes(status.state)) found.push({ kind: 'started' })
  } else {
    if (status.state === 'idle' && previous.state !== 'idle') found.push({ kind: 'stopped' })
    if (previous.state === 'idle' && WATCHING_STATES.includes(status.state)) found.push({ kind: 'again' })
    const previousKey = previous.mediaKey || ''
    const nextKey = status.mediaKey || ''
    // v2.2: following on / off.
    const wasFollowing = previous.following !== false
    const following = status.following !== false
    if (wasFollowing && !following) found.push({ kind: 'own' })
    if (!wasFollowing && following) found.push({ kind: 'back' })
    if (status.state !== 'idle' && previousKey && nextKey && previousKey !== nextKey) {
      // An independent member "is watching {title · episode}" instead of "switched to".
      if (following) found.push({ kind: 'switched', label: switchLabel(previousKey, nextKey) })
      else found.push({ kind: 'watching', label: nowPlayingLabel(status.nowPlaying) || switchLabel(previousKey, nextKey) })
    }
    if (previousKey === nextKey && previous.source && status.source && previous.source !== status.source) {
      found.push({ kind: 'source', source: status.source })
    }
  }
  const buffering = status.state === 'buffering'
  const continued = buffering && previous?.state === 'buffering' && current.bufferingSince !== null
  const next = {
    ...current,
    status,
    lostAnnounced: false,
    bufferingSince: buffering ? (continued ? current.bufferingSince : now) : null,
    bufferingAnnounced: continued ? current.bufferingAnnounced : false
  }
  return debounceAnnouncements(next, found, now)
}

/**
 * Time-based announcements, checked about once a second: long buffering, lost connection.
 * @param {Presence | null | undefined} presence
 * @param {{ now: number, lastStatusAt?: number, lastPongAt?: number }} signal
 * @returns {{ presence: Presence | null | undefined, announcements: Announcement[] }}
 */
export function presenceOnTick (presence, { now, lastStatusAt, lastPongAt }) {
  if (!presence?.status) return { presence, announcements: [] }
  /** @type {Announcement[]} */
  const found = []
  let next = presence
  if (next.status.state === 'buffering' && next.bufferingSince !== null && !next.bufferingAnnounced && now - next.bufferingSince > BUFFERING_ANNOUNCE_MS) {
    next = { ...next, bufferingAnnounced: true }
    found.push({ kind: 'buffering' })
  }
  const lastSignal = Math.max(isFiniteNumber(lastStatusAt) ? lastStatusAt : -Infinity, isFiniteNumber(lastPongAt) ? lastPongAt : -Infinity)
  if (!next.lostAnnounced && now - lastSignal >= LOST_ANNOUNCE_MS) {
    next = { ...next, lostAnnounced: true }
    found.push({ kind: 'lost' })
  }
  if (!found.length) return { presence: next, announcements: [] }
  return debounceAnnouncements(next, found, now)
}

/**
 * @param {string} name
 * @param {Announcement} announcement
 */
export function describePresence (name, { kind, label, source }) {
  switch (kind) {
    case 'started': return `${name} started watching`
    case 'again': return `${name} is watching again`
    case 'stopped': return `${name} stopped watching`
    case 'switched': return `${name} switched to ${label || 'another title'}`
    case 'source': return `${name} changed source: ${source}`
    case 'buffering': return `${name} is buffering…`
    case 'lost': return `${name} lost connection`
    case 'own': return `${name} is watching on their own`
    case 'back': return `${name} is back in sync`
    case 'watching': return `${name} is watching ${label || 'another title'}`
    default: return null
  }
}

/**
 * v2.3 "Invite to watch" on a member row, from anywhere (the inviter does not need to be in the player).
 * There must be a media to offer (see offeredMedia); in `host` mode only the host invites. Eligible: a v2
 * member that is idle, on another key than the offered one, independent, or "No signal" (including no
 * `status` 10 s after its `init`).
 * @param {{ offeredKey: string | null | undefined, effectiveMode: string, isHost: boolean, now: number,
 *   member: { isSelf?: boolean, protocol?: number, badge?: Badge, status?: Status | null, joinedAt?: number } }} input
 */
export function canInvite ({ offeredKey, effectiveMode, isHost, now, member }) {
  if (!offeredKey || member.isSelf || !(member.protocol >= 2)) return false
  if (effectiveMode === 'host' && !isHost) return false
  const status = member.status
  if (!status) return isFiniteNumber(member.joinedAt) && now - member.joinedAt >= NO_SIGNAL_MS
  if (member.badge?.kind === 'nosignal') return true
  return status.state === 'idle' || status.following === false || (status.mediaKey || '') !== offeredKey
}

/**
 * Whether an `invite` is for us and allowed: anyone in `everyone` mode, the host only in `host` mode.
 * v2.5: with `toSession`, only that device of the account takes it. `senderId` / `hostId` are member keys when the
 * client uses them, then `selfKey` is ours.
 * @param {{ to: unknown, toSession?: string | null, selfId: string, sessionId?: string | null, senderId: string, selfKey?: string, hostId: string | null, effectiveMode: string }} input
 */
export function acceptsInvite ({ to, toSession, selfId, sessionId, senderId, selfKey, hostId, effectiveMode }) {
  if (!sameId(to, selfId) || sameId(senderId, selfKey ?? selfId)) return false
  if (toSession && sessionId && toSession !== sessionId) return false
  return effectiveMode !== 'host' || sameId(senderId, hostId)
}

/**
 * Where to seek once a joined invite is loaded: the host's expected position if the host is on the
 * same episode, else the inviter's time plus the elapsed time when it was playing.
 * @param {{ invite: { key: string, time: number, paused: boolean, receivedAt: number }, host: { time: number, paused: boolean, mediaKey: string | null } | null, now: number }} input
 * @returns {{ time: number, paused: boolean, from: 'host' | 'inviter' }}
 */
export function inviteTarget ({ invite, host, now }) {
  if (host && host.mediaKey !== null && host.mediaKey === invite.key && isFiniteNumber(host.time)) {
    return { time: host.time, paused: host.paused, from: 'host' }
  }
  const elapsed = invite.paused ? 0 : Math.max(0, now - invite.receivedAt) / 1000
  return { time: Math.max(0, invite.time + elapsed), paused: !!invite.paused, from: 'inviter' }
}

// ---------------------------------------------------------------- v2.2: independent watching

/**
 * `status.nowPlaying`, cleaned: `{ mediaId, title, episode }` or null.
 * @param {unknown} value
 * @returns {NowPlaying | null}
 */
export function normalizeNowPlaying (value) {
  if (!value || typeof value !== 'object') return null
  const raw = /** @type {any} */ (value)
  const text = item => (typeof item === 'string' ? item.trim().slice(0, 120) : '')
  const mediaId = typeof raw.mediaId === 'string' || isFiniteNumber(raw.mediaId) ? raw.mediaId : null
  return { mediaId, title: text(raw.title), episode: text(raw.episode) }
}

/** "Title · Episode 5" of a nowPlaying, empty when unknown. @param {NowPlaying | null | undefined} nowPlaying */
export function nowPlayingLabel (nowPlaying) {
  return [nowPlaying?.title, nowPlaying?.episode].filter(Boolean).join(' · ')
}

/**
 * `nowPlaying.episode`: "Movie" for a single-episode movie, else "Episode 5" / "S2 E5".
 * @param {{ episode: unknown, format?: string, episodes?: number }} input
 */
export function episodeLabelFor ({ episode, format, episodes }) {
  if (format === 'MOVIE' && !(episodes > 1)) return 'Movie'
  return episodeLabelOf(episode) ?? ''
}

/**
 * Host hand-off when the host stops following: the smallest userId among the connected v2 peers
 * whose last status does not say `following: false`. Null: nobody follows, the host stays.
 * @param {Array<{ userId: string, protocol?: number, following?: boolean }>} peers
 * @returns {string | null}
 */
export function pickFollowingHost (peers) {
  return electHost(peers.filter(peer => peer.protocol >= 2 && peer.following !== false).map(peer => peer.userId))
}

/**
 * Host migration (v2.2): independent members are skipped, unless nobody follows.
 * v2.5: a v1 client (`protocol` 1) is never elected (it would never claim the role), nor a member in `skip` (it was
 * elected and did not claim the role within TENTATIVE_HOST_MS).
 * @param {{ selfId: string, selfFollowing: boolean, peers: Array<{ userId: string, following?: boolean, protocol?: number }>, skip?: Iterable<string> }} input
 *   userId: the member key (see memberKey)
 * @returns {string | null}
 */
export function electFollowingHost ({ selfId, selfFollowing, peers, skip = [] }) {
  const skipped = new Set(skip)
  const eligible = peers.filter(peer => !(peer.protocol < 2) && !skipped.has(peer.userId))
  const following = [...(selfFollowing ? [selfId] : []), ...eligible.filter(peer => peer.following !== false).map(peer => peer.userId)]
  return electHost(following.length ? following : [selfId, ...eligible.map(peer => peer.userId)])
}

/**
 * What to do when "Watch on my own" is turned off: resync when we already play the lobby's
 * episode, otherwise offer "Rejoin" (nothing changes until it is used).
 * @param {{ localKey: string, lobbyKey: string | null | undefined }} input
 * @returns {'resync' | 'rejoin' | 'none'}
 */
export function followBackAction ({ localKey, lobbyKey }) {
  if (!lobbyKey) return 'none'
  return localKey && localKey === lobbyKey ? 'resync' : 'rejoin'
}

// ---------------------------------------------------------------- v2.3: join the current playback, invite from anywhere

/** A `media` (or `index`) received this soon after its sender's `init` is the lobby state sent to newcomers. */
export const INITIAL_STATE_MS = 5_000
/** States in which a member counts as watching the lobby media. */
export const WATCHING_LOBBY_STATES = ['playing', 'paused', 'buffering', 'loading']

/**
 * The reference member of the lobby playback, or null when the lobby is not watching. The host when its
 * last status is on the lobby key in a watching state; if the host is idle or independent (or has no
 * status), the following member on the lobby key with the smallest userId.
 * @param {{ lobbyKey: string | null | undefined, hostId: string | null, members: Array<{ userId: string, status?: Status | null }> }} input
 *   members: every member, ourselves included with our own status
 * @returns {string | null}
 */
export function lobbyReference ({ lobbyKey, hostId, members }) {
  if (!lobbyKey) return null
  const onLobby = member => !!member.status && member.status.following !== false &&
    member.status.mediaKey === lobbyKey && WATCHING_LOBBY_STATES.includes(member.status.state)
  const host = hostId == null ? null : members.find(member => sameId(member.userId, hostId))
  if (host) {
    if (onLobby(host)) return String(host.userId)
    const hostAway = !host.status || host.status.state === 'idle' || host.status.following === false
    if (!hostAway) return null
  }
  return electHost(members.filter(onLobby).map(member => member.userId))
}

/**
 * Whether to show the Join card: the lobby is watching (there is a reference other than us) and we are
 * not on the lobby media (idle, another key, or independent).
 * @param {{ reference: string | null, selfId: string, lobbyKey: string | null | undefined, local: { state: string, mediaKey?: string }, following: boolean }} input
 */
export function canJoinPlayback ({ reference, selfId, lobbyKey, local, following }) {
  if (!reference || !lobbyKey || sameId(reference, selfId)) return false
  return local.state === 'idle' || (local.mediaKey || '') !== lobbyKey || !following
}

/**
 * Media an invite offers: ours when we play one, else the lobby media while the lobby is watching.
 * @param {{ ownKey: string | null | undefined, ownActive: boolean, lobbyKey: string | null | undefined, lobbyWatching: boolean }} input
 * @returns {{ from: 'own' | 'lobby', key: string } | null}
 */
export function offeredMedia ({ ownKey, ownActive, lobbyKey, lobbyWatching }) {
  if (ownActive && ownKey) return { from: 'own', key: ownKey }
  if (lobbyWatching && lobbyKey) return { from: 'lobby', key: lobbyKey }
  return null
}

/**
 * Position sent in an invite: our own playback when it plays the offered media, else the reference's
 * expected time and state.
 * @param {{ offered: { from: 'own' | 'lobby' } | null, own: { time: number, paused: boolean } | null, reference: { time: number, paused: boolean } | null }} input
 * @returns {{ time: number, paused: boolean } | null}
 */
export function invitePosition ({ offered, own, reference }) {
  if (!offered) return null
  const source = offered.from === 'own' ? own : reference
  if (!source || !isFiniteNumber(source.time)) return null
  return { time: Math.max(0, source.time), paused: !!source.paused }
}

/**
 * A received `media` starts the player only for a following member already watching, and never for the
 * lobby state sent to newcomers: the others get the Join card (nothing starts on its own).
 * @param {{ following: boolean, localState: string, senderJoinedAt?: number, now: number }} input
 */
export function autoStartsMedia ({ following, localState, senderJoinedAt, now }) {
  if (!following || localState === 'idle') return false
  return !(isFiniteNumber(senderJoinedAt) && now - senderJoinedAt < INITIAL_STATE_MS)
}

/**
 * v2.4: a `countdown` is applied only by a member whose player is on the lobby media, or plays nothing.
 * @param {{ localKey: string | null | undefined, lobbyKey: string | null | undefined }} input
 */
export function appliesCountdown ({ localKey, lobbyKey }) {
  return !localKey || !lobbyKey || localKey === lobbyKey
}

// ---------------------------------------------------------------- v2.4: features, voice chat, shared queue

/** `init.features` sent by this client. */
export const FEATURES = /** @type {const} */ (['voice', 'queue'])

/**
 * `init.features`, cleaned: distinct short strings, an empty list when missing or malformed.
 * @param {unknown} value
 * @returns {string[]}
 */
export function normalizeFeatures (value) {
  if (!Array.isArray(value)) return []
  return [...new Set(value.filter(item => typeof item === 'string' && item.length > 0 && item.length <= 32))].slice(0, 16)
}

/** A transmitting microphone whose peak level reaches this is speaking... */
export const VOICE_SPEAKING_LEVEL = 0.05
/** ... until it stayed below for this long. */
export const VOICE_SPEAKING_HOLD_MS = 600
/** Ducking: the video plays at this fraction of its volume while someone speaks. */
export const VOICE_DUCK_LEVEL = 0.3
/** No trickle: the description is sent this long after the first candidate if gathering is not complete... */
export const VOICE_GATHER_AFTER_CANDIDATE_MS = 3_000
/** ... and after this long at most. */
export const VOICE_GATHER_MAX_MS = 8_000
/** A link not connected this long after the offer failed. */
export const VOICE_CONNECT_TIMEOUT_MS = 20_000
/** The offerer retries a failed link after this delay... */
export const VOICE_RETRY_MS = 3_000
/** ... at most this many times in a row. */
export const VOICE_MAX_RETRIES = 5
/** STUN servers of the audio links (same as the data channels, simple-peer's defaults). */
export const VOICE_ICE_SERVERS = ['stun:stun.l.google.com:19302', 'stun:global.stun.twilio.com:3478']

/**
 * `voice` payload, cleaned. `speaking` is false unless joined and not muted.
 * @param {unknown} payload
 * @returns {{ joined: boolean, muted: boolean, speaking: boolean }}
 */
export function normalizeVoice (payload) {
  const raw = /** @type {any} */ (payload) ?? {}
  const joined = raw.joined === true
  const muted = raw.muted === true
  return { joined, muted, speaking: joined && !muted && raw.speaking === true }
}

/**
 * Of two members in voice, the one with the smaller userId sends the offer.
 * @param {unknown} selfId
 * @param {unknown} otherId
 */
export function voiceOffers (selfId, otherId) {
  return String(selfId) < String(otherId)
}

/**
 * What to do with the audio link to one member.
 * @param {{ selfJoined: boolean, memberJoined: boolean, memberHasVoice: boolean, hasLink: boolean, selfOffers: boolean }} input
 * @returns {'offer' | 'wait' | 'close' | 'none'} offer: we create it; wait: the member will offer
 */
export function voiceLinkAction ({ selfJoined, memberJoined, memberHasVoice, hasLink, selfOffers }) {
  if (!(selfJoined && memberJoined && memberHasVoice)) return hasLink ? 'close' : 'none'
  if (hasLink) return 'none'
  return selfOffers ? 'offer' : 'wait'
}

/**
 * Whether an incoming `voiceSignal` offer is taken: both of us in voice, and the sender is the offerer.
 * @param {{ selfJoined: boolean, memberJoined: boolean, selfId: string, senderId: string }} input
 */
export function acceptsVoiceOffer ({ selfJoined, memberJoined, selfId, senderId }) {
  return selfJoined && memberJoined && voiceOffers(senderId, selfId)
}

/**
 * Delay before the offerer re-offers a failed link, null when it gave up.
 * @param {number} failures failed attempts in a row
 */
export function voiceRetryDelay (failures) {
  return failures <= VOICE_MAX_RETRIES ? VOICE_RETRY_MS : null
}

/**
 * The microphone sends sound: in voice, with a microphone, not muted, and the push-to-talk key held if it is on.
 * @param {{ joined: boolean, hasMic: boolean, muted: boolean, pushToTalk: boolean, held: boolean }} input
 */
export function voiceTransmitting ({ joined, hasMic, muted, pushToTalk, held }) {
  return joined && hasMic && !muted && (!pushToTalk || held)
}

/**
 * Speaking detection on our own microphone, called about every 100 ms.
 * @param {{ lastLoudAt?: number } | null | undefined} memory
 * @param {{ level: number | null | undefined, transmitting: boolean, now: number }} input level: peak amplitude 0-1
 * @returns {{ speaking: boolean, lastLoudAt: number }}
 */
export function speakingStep (memory, { level, transmitting, now }) {
  if (!transmitting) return { speaking: false, lastLoudAt: -Infinity }
  const lastLoudAt = isFiniteNumber(memory?.lastLoudAt) ? memory.lastLoudAt : -Infinity
  if (isFiniteNumber(level) && level >= VOICE_SPEAKING_LEVEL) return { speaking: true, lastLoudAt: now }
  return { speaking: now - lastLoudAt < VOICE_SPEAKING_HOLD_MS, lastLoudAt }
}

/**
 * Video volume factor: lowered while we are in voice and another member we hear is speaking.
 * @param {{ enabled: boolean, selfJoined: boolean, members: Array<{ joined: boolean, speaking: boolean, localMuted?: boolean, volume?: number }> }} input
 *   members: the other members
 */
export function duckLevel ({ enabled, selfJoined, members }) {
  if (!enabled || !selfJoined) return 1
  const heard = members.some(member => member.joined && member.speaking && !member.localMuted && (isFiniteNumber(member.volume) ? member.volume : 1) > 0)
  return heard ? VOICE_DUCK_LEVEL : 1
}

/** Queue limits. */
export const QUEUE_MAX_ITEMS = 50
export const QUEUE_MAX_PENDING = 20
/** Auto-advance: "Up next" waits this long before playing the first item. */
export const QUEUE_ADVANCE_S = 5
/** Length of the countdown the host starts once a queued item is loaded. */
export const QUEUE_COUNTDOWN_S = 5

/**
 * @typedef {{ id: string, media: any, episode: number | { number: number, season?: number, localEpisode?: number }, key: string, title: string, cover: string, addedBy: string, addedByName: string, votes: string[] }} QueueItem
 * @typedef {{ items: QueueItem[], pending: QueueItem[], policy: 'open' | 'approval', rev: number }} Queue
 */

/** @returns {Queue} */
export function emptyQueue () {
  return { items: [], pending: [], policy: 'open', rev: 0 }
}

const cleanText = (value, max) => (typeof value === 'string' ? value.trim().slice(0, max) : '')
const cleanId = value => ((typeof value === 'string' && value !== '') || isFiniteNumber(value) ? String(value).slice(0, 64) : null)

/**
 * Episode of a queue item: a number, or `{ number, season?, localEpisode? }`. Null when unusable.
 * @param {unknown} episode
 */
export function normalizeQueueEpisode (episode) {
  // v2.5: episode, season and local episode numbers are within 0…MAX_EPISODE.
  const valid = value => isFiniteNumber(value) && value >= 0 && value <= MAX_EPISODE
  if (valid(episode)) return episode
  if (typeof episode === 'string' && /^\d{1,7}$/.test(episode) && valid(Number(episode))) return Number(episode)
  if (episode && typeof episode === 'object' && !Array.isArray(episode)) {
    const raw = /** @type {any} */ (episode)
    const number = valid(raw.number) ? raw.number : valid(raw.localEpisode) ? raw.localEpisode : null
    if (number === null) return null
    /** @type {{ number: number, season?: number, localEpisode?: number }} */
    const out = { number }
    if (valid(raw.season)) out.season = raw.season
    if (valid(raw.localEpisode)) out.localEpisode = raw.localEpisode
    return out
  }
  return null
}

/**
 * A queue item, cleaned. Null without an id, a media with an id, an episode or a key.
 * @param {unknown} value
 * @returns {QueueItem | null}
 */
export function normalizeQueueItem (value) {
  if (!value || typeof value !== 'object') return null
  const raw = /** @type {any} */ (value)
  const id = cleanId(raw.id)
  const media = cleanMedia(raw.media)
  const episode = normalizeQueueEpisode(raw.episode)
  const key = cleanText(raw.key, 200)
  if (!id || !media || episode === null || !key) return null
  const votes = Array.isArray(raw.votes) ? [...new Set(raw.votes.map(cleanId).filter(Boolean))].slice(0, 64) : []
  return {
    id,
    media,
    episode,
    key,
    title: cleanText(raw.title, 120),
    cover: cleanText(raw.cover, 500),
    addedBy: cleanId(raw.addedBy) ?? '',
    addedByName: cleanText(raw.addedByName, 64),
    votes
  }
}

/**
 * `queue` payload, cleaned (items without a duplicate id, within the limits). Null when not an object.
 * @param {unknown} payload
 * @returns {Queue | null}
 */
export function normalizeQueue (payload) {
  if (!payload || typeof payload !== 'object') return null
  const raw = /** @type {any} */ (payload)
  const seen = new Set()
  const clean = (list, max) => (Array.isArray(list) ? list : []).map(normalizeQueueItem).filter(item => {
    if (!item || seen.has(item.id)) return false
    seen.add(item.id)
    return true
  }).slice(0, max)
  const items = clean(raw.items, QUEUE_MAX_ITEMS)
  const pending = clean(raw.pending, QUEUE_MAX_PENDING)
  // v2.5: `rev` is a whole number that every app can store (the iOS app crashed on 1e300).
  const rev = isFiniteNumber(raw.rev) ? Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, Math.trunc(raw.rev))) : 0
  return { items, pending, policy: raw.policy === 'approval' ? 'approval' : 'open', rev }
}

/**
 * Same title and episode, even when two apps wrote the key differently ("21:5" / "21::5").
 * @param {{ key?: string, media?: any, episode: unknown }} a
 * @param {{ key?: string, media?: any, episode: unknown }} b
 */
export function sameQueueEntry (a, b) {
  if (a.key && a.key === b.key) return true
  if (cleanId(a.media?.id) === null || String(a.media.id) !== String(b.media?.id)) return false
  const identity = value => {
    const episode = normalizeQueueEpisode(value)
    if (episode === null) return null
    return typeof episode === 'number' ? `:${episode}` : `${episode.season ?? ''}:${episode.localEpisode ?? episode.number}`
  }
  const left = identity(a.episode)
  return left !== null && left === identity(b.episode)
}

/**
 * One change of the queue, applied by the host. Returns the new queue (rev + 1), or null when nothing changed.
 * - add: `byHost` or an `open` policy adds to the items, else to the suggestions; same key or full: ignored.
 * - vote: adds / removes `by` on an item. remove: the host, or the member who added it.
 * - move: host only, by `delta` places. answer: host, accept (to the end of the items) or decline a suggestion.
 * - policy: host only.
 * @param {Queue | null | undefined} queue
 * @param {{ type: 'add', item: QueueItem, by: string, byName?: string, byHost: boolean }
 *   | { type: 'vote', id: string, by: string, up: boolean }
 *   | { type: 'remove', id: string, by: string, byHost: boolean }
 *   | { type: 'move', id: string, delta: number }
 *   | { type: 'answer', id: string, accepted: boolean }
 *   | { type: 'policy', policy: string }} change
 * @returns {Queue | null}
 */
export function queueReduce (queue, change) {
  const current = queue ?? emptyQueue()
  const done = next => ({ ...current, ...next, rev: current.rev + 1 })
  switch (change.type) {
    case 'add': {
      const item = normalizeQueueItem(change.item)
      if (!item) return null
      const all = [...current.items, ...current.pending]
      if (all.some(entry => entry.id === item.id || sameQueueEntry(entry, item))) return null
      const added = { ...item, addedBy: String(change.by), addedByName: cleanText(change.byName, 64) || item.addedByName, votes: [] }
      if (change.byHost || current.policy === 'open') {
        if (current.items.length >= QUEUE_MAX_ITEMS) return null
        return done({ items: [...current.items, added] })
      }
      if (current.pending.length >= QUEUE_MAX_PENDING) return null
      return done({ pending: [...current.pending, added] })
    }
    case 'vote': {
      const by = String(change.by)
      let changed = false
      const items = current.items.map(item => {
        if (item.id !== change.id) return item
        const has = item.votes.includes(by)
        if (has === !!change.up) return item
        changed = true
        return { ...item, votes: change.up ? [...item.votes, by] : item.votes.filter(id => id !== by) }
      })
      return changed ? done({ items }) : null
    }
    case 'remove': {
      const allowed = item => item.id === change.id && (change.byHost || sameId(item.addedBy, change.by))
      const items = current.items.filter(item => !allowed(item))
      const pending = current.pending.filter(item => !allowed(item))
      if (items.length === current.items.length && pending.length === current.pending.length) return null
      return done({ items, pending })
    }
    case 'move': {
      const index = current.items.findIndex(item => item.id === change.id)
      if (index < 0 || !isFiniteNumber(change.delta)) return null
      const target = Math.max(0, Math.min(current.items.length - 1, index + Math.trunc(change.delta)))
      if (target === index) return null
      const items = [...current.items]
      const [item] = items.splice(index, 1)
      items.splice(target, 0, item)
      return done({ items })
    }
    case 'answer': {
      const item = current.pending.find(entry => entry.id === change.id)
      if (!item) return null
      const pending = current.pending.filter(entry => entry.id !== change.id)
      if (!change.accepted || current.items.length >= QUEUE_MAX_ITEMS) return done({ pending })
      return done({ pending, items: [...current.items, item] })
    }
    case 'policy': {
      const policy = change.policy === 'approval' ? 'approval' : 'open'
      return policy === current.policy ? null : done({ policy })
    }
    default:
      return null
  }
}

/**
 * What a new `queue` adds to the chat, compared with the previous one (none for the first one).
 * @param {Queue | null | undefined} previous
 * @param {Queue} next
 * @param {{ selfId: string, cancelled?: Set<string> | string[] }} options cancelled: ids of our own suggestions we removed
 * @returns {Array<{ kind: 'added' | 'suggested' | 'declined', item: QueueItem }>}
 */
export function queueChanges (previous, next, { selfId, cancelled = [] }) {
  if (!previous) return []
  const ignored = new Set(cancelled)
  const before = new Set(previous.items.map(item => item.id))
  const beforePending = new Set(previous.pending.map(item => item.id))
  const nowIds = new Set([...next.items, ...next.pending].map(item => item.id))
  /** @type {Array<{ kind: 'added' | 'suggested' | 'declined', item: QueueItem }>} */
  const changes = []
  for (const item of next.items) if (!before.has(item.id)) changes.push({ kind: 'added', item })
  for (const item of next.pending) if (!beforePending.has(item.id) && !before.has(item.id)) changes.push({ kind: 'suggested', item })
  for (const item of previous.pending) {
    if (!nowIds.has(item.id) && sameId(item.addedBy, selfId) && !ignored.has(item.id)) changes.push({ kind: 'declined', item })
  }
  return changes
}

/**
 * "Title · Episode 5" of a queue item ("Title · Movie" for a movie).
 * @param {{ title?: string, episode: unknown, media?: any }} item
 */
export function queueItemLabel (item) {
  const episode = episodeLabelFor({ episode: item.episode, format: item.media?.format, episodes: item.media?.episodes })
  return [item.title || 'a title', episode].filter(Boolean).join(' · ')
}

/**
 * Chat line of a queue change.
 * @param {{ kind: 'added' | 'suggested' | 'declined', item: QueueItem }} change
 * @param {string} selfId
 */
export function describeQueueChange ({ kind, item }, selfId) {
  const label = queueItemLabel(item)
  const name = sameId(item.addedBy, selfId) ? 'You' : (item.addedByName || 'Someone')
  if (kind === 'added') return `${name} added ${label} to Up next`
  if (kind === 'suggested') return `${name} suggested ${label}`
  return `The host declined your suggestion: ${label}`
}

/**
 * The episode after `episode`; null past the known episode count (a movie has none).
 * @param {unknown} episode a number or { number, season?, localEpisode? }
 * @param {unknown} [episodes] episode count of the title, when known
 */
export function nextEpisodeOf (episode, episodes) {
  const value = normalizeQueueEpisode(episode)
  if (value === null) return null
  if (typeof value === 'number') {
    const next = value + 1
    return isFiniteNumber(episodes) && episodes > 0 && next > episodes ? null : next
  }
  /** @type {{ number: number, season?: number, localEpisode?: number }} */
  const next = { ...value, number: value.number + 1 }
  if (isFiniteNumber(value.localEpisode)) next.localEpisode = value.localEpisode + 1
  return next
}

/**
 * "Add next episode": the episode after the last queued (or suggested) episode of the lobby title, else after the
 * lobby media. Null without a lobby media or past the last episode.
 * @param {{ lobby: { media: any, episode: unknown } | null | undefined, queue: Queue | null | undefined }} input
 * @returns {{ media: any, episode: number | { number: number, season?: number, localEpisode?: number } } | null}
 */
export function nextEpisodeTarget ({ lobby, queue }) {
  if (!lobby?.media || cleanId(lobby.media.id) === null) return null
  const mediaId = String(lobby.media.id)
  const numberOf = episode => {
    const value = normalizeQueueEpisode(episode)
    return value === null ? -Infinity : typeof value === 'number' ? value : value.number
  }
  let base = lobby.episode
  for (const item of [...(queue?.items ?? []), ...(queue?.pending ?? [])]) {
    if (String(item.media?.id) === mediaId && numberOf(item.episode) > numberOf(base)) base = item.episode
  }
  const episodes = lobby.media.format === 'MOVIE' && !(lobby.media.episodes > 1) ? 1 : lobby.media.episodes
  const episode = nextEpisodeOf(base, episodes)
  return episode === null ? null : { media: lobby.media, episode }
}

/**
 * Whether a `queue` is taken from this sender: the current host, or anyone while no host is known or it is provisional.
 * @param {{ senderId: string, hostId: string | null, tentative: boolean }} input
 */
export function acceptsQueue ({ senderId, hostId, tentative }) {
  return hostId == null || tentative || sameId(senderId, hostId)
}

// ---------------------------------------------------------------- v2.5: transport limits, validation, identity

/**
 * Reassembles P2PT messages (`{ id, msg, c, last }` frames, PROTOCOL.md "Transport") per peer, within limits.
 * P2PT's own handler keeps the chunks of every message in one table shared by all peers, at whatever index a peer
 * picks: a single frame with `c: 4294967294` makes its `join('')` walk billions of holes and freezes the app.
 */
export class ChunkAssembler {
  /** @type {Map<string, { peerId: string, parts: string[], size: number, at: number }>} */
  #messages = new Map()
  #buffered = 0
  #limits

  /** @param {{ maxChunks?: number, maxChars?: number, maxPending?: number, timeoutMs?: number, maxBuffered?: number }} [limits] */
  constructor (limits = {}) {
    this.#limits = { maxChunks: MAX_CHUNKS, maxChars: MAX_EVENT_CHARS, maxPending: MAX_PENDING_MESSAGES, timeoutMs: CHUNK_TIMEOUT_MS, maxBuffered: MAX_BUFFERED_CHARS, ...limits }
  }

  /** Units buffered in partial messages. */
  get buffered () {
    return this.#buffered
  }

  /** Partial messages. */
  get pending () {
    return this.#messages.size
  }

  /**
   * One frame from a peer.
   * @param {string} peerId
   * @param {unknown} frame the parsed frame
   * @param {number} now
   * @returns {string | false} the whole message once its last chunk came; false before that, and when a limit is
   *   broken (the message is then dropped)
   */
  add (peerId, frame, now) {
    this.#expire(now)
    const { maxChunks, maxChars, maxPending, maxBuffered } = this.#limits
    const data = frame && typeof frame === 'object' ? /** @type {any} */ (frame) : null
    const id = !data ? null : typeof data.id === 'string' ? data.id : isFiniteNumber(data.id) ? String(data.id) : null
    if (id === null || id.length > 64) return false
    const key = `${peerId}\u0000${id}`
    const index = data.c ?? 0
    if (!Number.isInteger(index) || index < 0 || index >= maxChunks || typeof data.msg !== 'string') {
      this.#drop(key)
      return false
    }
    let entry = this.#messages.get(key)
    if (!entry) {
      // Too many messages in progress from this peer: its oldest one goes.
      let oldest = null
      let count = 0
      for (const [other, item] of this.#messages) {
        if (item.peerId !== peerId) continue
        count++
        if (!oldest || item.at < this.#messages.get(oldest).at) oldest = other
      }
      if (count >= maxPending && oldest) this.#drop(oldest)
      entry = { peerId, parts: [], size: 0, at: now }
      this.#messages.set(key, entry)
    }
    const growth = data.msg.length - (entry.parts[index]?.length ?? 0)
    if (entry.size + growth > maxChars || this.#buffered + growth > maxBuffered) {
      this.#drop(key)
      return false
    }
    entry.parts[index] = data.msg
    entry.size += growth
    this.#buffered += growth
    if (!data.last) return false
    // Complete: every chunk up to the last one, none after it.
    const parts = entry.parts
    this.#drop(key)
    if (parts.length !== index + 1) return false
    for (let chunk = 0; chunk <= index; chunk++) if (typeof parts[chunk] !== 'string') return false
    return parts.join('')
  }

  /** A peer left: its partial messages go. */
  forget (peerId) {
    for (const [key, entry] of this.#messages) if (entry.peerId === peerId) this.#drop(key)
  }

  clear () {
    this.#messages.clear()
    this.#buffered = 0
  }

  #drop (key) {
    const entry = this.#messages.get(key)
    if (!entry) return
    this.#buffered -= entry.size
    this.#messages.delete(key)
  }

  #expire (now) {
    for (const [key, entry] of this.#messages) if (now - entry.at > this.#limits.timeoutMs) this.#drop(key)
  }
}

/** Ids a peer could use to reach Object.prototype through a lookup table. */
const RESERVED_IDS = new Set(['__proto__', 'constructor', 'prototype'])

/**
 * A wire id (`userId`, `hostId`, request, item and offer ids): a non-empty string of at most 64 characters or a
 * finite number, as a string. Null otherwise.
 * @param {unknown} value
 */
export function wireId (value) {
  if (isFiniteNumber(value)) return String(value)
  return typeof value === 'string' && value.length > 0 && value.length <= 64 ? value : null
}

/**
 * v2.5 `init.sessionId` (also `host.hostSession`, `invite.toSession`): 4 to 64 letters, digits, `-` or `_`.
 * @param {unknown} value
 */
export function cleanSessionId (value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{4,64}$/.test(value) ? value : null
}

/**
 * A media position in 0…MAX_TIME_S, null otherwise.
 * @param {unknown} value
 */
export function cleanTime (value) {
  return isFiniteNumber(value) && value >= 0 && value <= MAX_TIME_S ? value : null
}

/**
 * An http(s) URL of at most `max` characters, '' otherwise.
 * @param {unknown} value
 */
export function cleanUrl (value, max = 1000) {
  if (typeof value !== 'string') return ''
  const url = value.trim()
  return url.length <= max && /^https?:\/\/\S+$/i.test(url) ? url : ''
}

/**
 * A media key (`media.key`, `status.mediaKey`...): '' when missing or longer than MAX_KEY_LENGTH.
 * @param {unknown} value
 */
export function cleanKey (value) {
  if (isFiniteNumber(value)) return String(value)
  return typeof value === 'string' && value.length <= MAX_KEY_LENGTH ? value : ''
}

const MEDIA_NUMBERS = ['idMal', 'idTmdb', 'episodes', 'seasonYear', 'duration', 'averageScore']
const MEDIA_TEXTS = ['format', 'status', 'season']
const MEDIA_TITLES = ['romaji', 'english', 'native', 'userPreferred']
const MEDIA_COVERS = ['extraLarge', 'large', 'medium']

/**
 * The shared media shape (session.js SHARED_MEDIA_FIELDS) rebuilt from what a peer sent: the known fields with the
 * right types, http(s) URLs only. Null without a usable id (AniList number, or a short text id like "tmdb-123").
 * @param {unknown} value
 * @returns {Record<string, any> | null}
 */
export function cleanMedia (value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const raw = /** @type {any} */ (value)
  let id = null
  if (isFiniteNumber(raw.id)) id = raw.id
  else if (typeof raw.id === 'string' && /^[A-Za-z0-9:._-]{1,64}$/.test(raw.id) && !RESERVED_IDS.has(raw.id)) id = raw.id
  if (id === null) return null
  /** @type {Record<string, any>} */
  const media = { id }
  for (const field of MEDIA_NUMBERS) if (isFiniteNumber(raw[field])) media[field] = raw[field]
  if (typeof raw.isTmdb === 'boolean') media.isTmdb = raw.isTmdb
  for (const field of MEDIA_TEXTS) if (typeof raw[field] === 'string' && /^[A-Za-z_]{1,32}$/.test(raw[field])) media[field] = raw[field]
  if (raw.title && typeof raw.title === 'object') {
    /** @type {Record<string, string>} */
    const title = {}
    for (const field of MEDIA_TITLES) if (typeof raw.title[field] === 'string') title[field] = raw.title[field].slice(0, 300)
    media.title = title
  }
  if (raw.coverImage && typeof raw.coverImage === 'object') {
    /** @type {Record<string, string>} */
    const cover = {}
    for (const field of MEDIA_COVERS) {
      const url = cleanUrl(raw.coverImage[field])
      if (url) cover[field] = url
    }
    if (typeof raw.coverImage.color === 'string' && /^#[0-9a-f]{3,8}$/i.test(raw.coverImage.color)) cover.color = raw.coverImage.color
    media.coverImage = cover
  }
  const banner = cleanUrl(raw.bannerImage)
  if (banner) media.bannerImage = banner
  if (Array.isArray(raw.genres)) media.genres = raw.genres.filter(genre => typeof genre === 'string' && genre.length <= 64).slice(0, 32)
  return media
}

/** @param {unknown} value @returns {any} */
const plainObject = value => (value && typeof value === 'object' && !Array.isArray(value) ? value : null)

/**
 * Episode of a `media` / `invite`: a valid episode, `undefined` when none was sent (older apps may omit it for a
 * movie), null when it is malformed (the event is dropped).
 */
function eventEpisode (value) {
  if (value == null) return undefined
  return normalizeQueueEpisode(value)
}

/** One cleaner per event type: the payload reduced to what the clients use, or null to drop the event. */
const EVENT_CLEANERS = {
  init (payload) {
    const raw = plainObject(payload)
    const id = raw && (isFiniteNumber(raw.id) ? raw.id : wireId(raw.id))
    if (id == null) return null
    /** @type {Record<string, any>} */
    const user = { id }
    const name = cleanText(raw.name, MAX_NAME_LENGTH)
    if (name) user.name = name
    const displayName = cleanText(raw.displayName, MAX_NAME_LENGTH)
    if (displayName) user.displayName = displayName
    const medium = cleanUrl(raw.avatar?.medium)
    const large = cleanUrl(raw.avatar?.large)
    if (medium || large) user.avatar = medium && large ? { medium, large } : medium ? { medium } : { large }
    const picture = cleanUrl(raw.picture)
    if (picture) user.picture = picture
    if (typeof raw.client === 'string' && raw.client.length <= 32) user.client = raw.client
    if (isFiniteNumber(raw.protocol) && raw.protocol >= 1 && raw.protocol <= 99) user.protocol = raw.protocol
    user.features = normalizeFeatures(raw.features)
    const sessionId = cleanSessionId(raw.sessionId)
    if (sessionId) user.sessionId = sessionId
    return user
  },
  media (payload) {
    const raw = plainObject(payload)
    const media = raw && cleanMedia(raw.media)
    const episode = raw && eventEpisode(raw.episode)
    if (!media || episode === null) return null
    return { media, episode, key: cleanKey(raw.key) }
  },
  index (payload) {
    const raw = plainObject(payload)
    if (!raw || !Number.isInteger(raw.index) || raw.index < 0 || raw.index > MAX_INDEX) return null
    /** @type {{ index: number, kind?: 'file' | 'episode', mediaKey?: string }} */
    const out = { index: raw.index }
    if (raw.kind === 'file' || raw.kind === 'episode') out.kind = raw.kind
    const mediaKey = cleanKey(raw.mediaKey)
    if (mediaKey) out.mediaKey = mediaKey
    return out
  },
  player (payload) {
    const raw = plainObject(payload)
    const time = raw && cleanTime(raw.time)
    if (time == null) return null
    /** @type {Record<string, any>} */
    const out = { time, paused: !!raw.paused }
    const by = wireId(raw.by)
    if (by) out.by = by
    if (ACTIONS.includes(raw.action)) out.action = raw.action
    if (isFiniteNumber(raw.rate)) out.rate = normalizeRate(raw.rate)
    const mediaKey = cleanKey(raw.mediaKey)
    if (mediaKey) out.mediaKey = mediaKey
    return out
  },
  message (payload) {
    return typeof payload === 'string' && payload ? payload.slice(0, MAX_MESSAGE_LENGTH) : null
  },
  host (payload) {
    const raw = plainObject(payload)
    const hostId = raw && wireId(raw.hostId)
    if (!hostId) return null
    /** @type {{ hostId: string, mode: 'everyone' | 'host', hostSession?: string }} */
    const out = { hostId, mode: normalizeMode(raw.mode) }
    const hostSession = cleanSessionId(raw.hostSession)
    if (hostSession) out.hostSession = hostSession
    return out
  },
  status (payload) {
    const raw = plainObject(payload)
    const state = raw && normalizeState(raw.state)
    const time = raw && cleanTime(raw.time)
    if (!state || time == null) return null
    return {
      state,
      time,
      mediaKey: cleanKey(raw.mediaKey),
      rate: normalizeRate(raw.rate),
      sentAt: isFiniteNumber(raw.sentAt) ? raw.sentAt : undefined,
      source: formatSource(raw.source),
      following: raw.following !== false,
      nowPlaying: normalizeNowPlaying(raw.nowPlaying)
    }
  },
  ping (payload) {
    const raw = plainObject(payload)
    if (!raw || !isFiniteNumber(raw.sentAt)) return null
    const id = wireId(raw.id)
    return id ? { id, sentAt: raw.sentAt } : { sentAt: raw.sentAt }
  },
  pong (payload) {
    return EVENT_CLEANERS.ping(payload)
  },
  request (payload) {
    const raw = plainObject(payload)
    const id = raw && wireId(raw.id)
    if (!id || !REQUEST_KINDS.includes(raw.kind)) return null
    if (raw.kind !== 'seek') return { id, kind: raw.kind }
    const time = cleanTime(raw.time)
    return time === null ? null : { id, kind: raw.kind, time }
  },
  requestReply (payload) {
    const raw = plainObject(payload)
    const id = raw && wireId(raw.id)
    if (!id) return null
    /** @type {{ id: string, accepted: boolean, by?: string }} */
    const out = { id, accepted: !!raw.accepted }
    const by = wireId(raw.by)
    if (by) out.by = by
    return out
  },
  kick (payload) {
    const userId = wireId(plainObject(payload)?.userId)
    return userId ? { userId } : null
  },
  reaction (payload) {
    const emoji = normalizeReaction(plainObject(payload)?.emoji)
    return emoji ? { emoji } : null
  },
  countdown (payload) {
    const raw = plainObject(payload)
    const time = raw && cleanTime(raw.time)
    if (time == null) return null
    /** @type {{ time: number, seconds: number, startAt?: number, mediaKey?: string }} */
    const out = { time, seconds: normalizeCountdownSeconds(raw.seconds) }
    if (isFiniteNumber(raw.startAt)) out.startAt = raw.startAt
    const mediaKey = cleanKey(raw.mediaKey)
    if (mediaKey) out.mediaKey = mediaKey
    return out
  },
  invite (payload) {
    const raw = plainObject(payload)
    const to = raw && wireId(raw.to)
    const media = raw && cleanMedia(raw.media)
    const time = raw && cleanTime(raw.time)
    const episode = raw && eventEpisode(raw.episode)
    if (!to || !media || time == null || episode === null) return null
    /** @type {Record<string, any>} */
    const out = { to, media, episode, key: cleanKey(raw.key), time, paused: !!raw.paused }
    const by = wireId(raw.by)
    if (by) out.by = by
    const toSession = cleanSessionId(raw.toSession)
    if (toSession) out.toSession = toSession
    return out
  },
  voice (payload) {
    return normalizeVoice(plainObject(payload))
  },
  voiceSignal (payload) {
    const raw = plainObject(payload)
    const id = raw && wireId(raw.id)
    const sdp = raw && plainObject(raw.sdp)
    if (!id || !sdp || (sdp.type !== 'offer' && sdp.type !== 'answer')) return null
    if (typeof sdp.sdp !== 'string' || !sdp.sdp || sdp.sdp.length > MAX_SDP_LENGTH) return null
    return { id, sdp: { type: sdp.type, sdp: sdp.sdp } }
  },
  queue (payload) {
    return normalizeQueue(plainObject(payload))
  },
  queueAdd (payload) {
    const item = normalizeQueueItem(plainObject(payload)?.item)
    return item ? { item } : null
  },
  queueVote (payload) {
    const raw = plainObject(payload)
    const id = raw && wireId(raw.id)
    return id ? { id, up: raw.up === true } : null
  },
  queueRemove (payload) {
    const id = wireId(plainObject(payload)?.id)
    return id ? { id } : null
  }
}

/**
 * v2.5 validation of every incoming event (PROTOCOL.md "Limits and validation"): the payload cleaned to the types,
 * ranges and lengths the clients use, or null to drop the event. Unknown types give null too (they are ignored).
 * @param {unknown} type
 * @param {unknown} payload
 * @returns {any}
 */
export function validateEvent (type, payload) {
  if (typeof type !== 'string' || !Object.prototype.hasOwnProperty.call(EVENT_CLEANERS, type)) return null
  return EVENT_CLEANERS[type](payload) ?? null
}

/** Events a member makes by hand: limited to a burst of RATE_BURST, then RATE_PER_S per second, per member. */
export const USER_EVENTS = /** @type {const} */ (['message', 'reaction', 'request', 'invite', 'queueAdd', 'queueVote', 'queueRemove'])
export const RATE_BURST = 20
export const RATE_PER_S = 5

/**
 * Token bucket of one member for USER_EVENTS.
 * @param {{ tokens: number, at: number } | null | undefined} bucket
 * @param {number} now
 * @returns {{ tokens: number, at: number, allowed: boolean }}
 */
export function rateStep (bucket, now) {
  const refilled = bucket ? bucket.tokens + Math.max(0, now - bucket.at) / 1000 * RATE_PER_S : RATE_BURST
  const tokens = Math.min(RATE_BURST, refilled)
  if (tokens < 1) return { tokens, at: now, allowed: false }
  return { tokens: tokens - 1, at: now, allowed: true }
}

/**
 * v2.5 member key: who a member is on this device. Two devices of one account share a `userId`, but each sends its
 * own `init.sessionId`. An older client sends none: its key is its `userId`. The separator sorts below the
 * characters of the ids (digits, hex, letters), so keys sort like their userIds and elections stay the same.
 * @param {unknown} userId
 * @param {string | null | undefined} [sessionId]
 */
export function memberKey (userId, sessionId) {
  const id = String(userId)
  return sessionId ? `${id}#${sessionId}` : id
}

/**
 * The two ids compared between two members to pick the voice offerer: their keys when both send a session id,
 * else their userIds (what an older client compares).
 * @param {{ userId: string, sessionId?: string | null }} self
 * @param {{ userId: string, sessionId?: string | null }} other
 * @returns {[string, string]}
 */
export function pairIds (self, other) {
  if (self.sessionId && other.sessionId) return [memberKey(self.userId, self.sessionId), memberKey(other.userId, other.sessionId)]
  return [String(self.userId), String(other.userId)]
}

/**
 * Member key of the host a `host` event names. With `hostSession` (v2.5), that device. Without (older sender): the
 * sender when it names its own userId, else the smallest key with that userId (ourselves included), else the userId.
 * @param {{ hostId: string, hostSession?: string | null, sender?: { key: string, userId: string } | null, members: Array<{ key: string, userId: string }> }} input
 */
export function resolveHostKey ({ hostId, hostSession, sender, members }) {
  if (hostSession) return memberKey(hostId, hostSession)
  if (sender && sameId(sender.userId, hostId)) return sender.key
  return electHost(members.filter(member => sameId(member.userId, hostId)).map(member => member.key)) ?? String(hostId)
}

/** A tentative host that did not claim the role this long after the election is skipped, and the election runs again. */
export const TENTATIVE_HOST_MS = 10_000

/** Round-trip samples above this are dropped (a pong held up by a suspended app or a frozen window)... */
export const MAX_RTT_MS = 5_000
/** ... the others are smoothed, with this weight for the new sample. */
export const RTT_SMOOTHING = 0.3

/**
 * v2.5 RTT of a member after a `pong`. The sample is dropped when negative, above MAX_RTT_MS, or for a ping sent
 * before `resumedAt` (the app was suspended in between); otherwise it is smoothed with the previous value.
 * @param {number | null | undefined} previous
 * @param {{ sentAt: number, now: number, resumedAt?: number }} pong
 * @returns {number | null} the new RTT, null to keep the previous one
 */
export function nextRtt (previous, { sentAt, now, resumedAt = -Infinity }) {
  const sample = now - sentAt
  if (!isFiniteNumber(sample) || sample < 0 || sample > MAX_RTT_MS || sentAt < resumedAt) return null
  return isFiniteNumber(previous) ? previous + (sample - previous) * RTT_SMOOTHING : sample
}

/**
 * Lobby code in a typed code, an invite link (tsumi://w2g/CODE, …/w2g/?c=CODE) or any text: the first run of exactly
 * 16 hex characters, in lower case (codes are generated in lower case, and P2PT's swarm id is case sensitive).
 * @param {unknown} text
 * @returns {string | null}
 */
export function parseLobbyCode (text) {
  if (typeof text !== 'string') return null
  const match = text.match(/(?:^|[^a-f0-9])([a-f0-9]{16})(?![a-f0-9])/i)
  return match ? match[1].toLowerCase() : null
}

/**
 * v2.5 ICE servers of the data channels and audio links: the STUN servers, plus the optional TURN server of the
 * settings (`w2gTurnUrl`, `w2gTurnUsername`, `w2gTurnCredential`) for networks where direct links fail (CGNAT,
 * strict firewalls). The URL may list several `turn:` / `turns:` URLs separated by commas or spaces.
 * @param {{ url?: unknown, username?: unknown, credential?: unknown }} [turn]
 * @returns {Array<{ urls: string | string[], username?: string, credential?: string }>}
 */
export function iceServers ({ url, username, credential } = {}) {
  /** @type {Array<{ urls: string | string[], username?: string, credential?: string }>} */
  const servers = [{ urls: [...VOICE_ICE_SERVERS] }]
  const urls = (typeof url === 'string' ? url.split(/[\s,]+/) : []).filter(item => item.length <= 500 && /^turns?:\S+$/i.test(item))
  if (urls.length) {
    servers.push({
      urls,
      username: typeof username === 'string' ? username.trim() : '',
      credential: typeof credential === 'string' ? credential : ''
    })
  }
  return servers
}

/**
 * v2.5 meaning of an `index`: "file" (position in the desktop player's file list) or "episode" (position in the iOS
 * player's episode list). Without `kind`, what the sender's app meant: "episode" for the iOS app, "file" otherwise.
 * @param {{ kind?: unknown } | null | undefined} payload
 * @param {string | undefined} client `init.client` of the sender
 * @returns {'file' | 'episode'}
 */
export function indexKind (payload, client) {
  if (payload?.kind === 'file' || payload?.kind === 'episode') return payload.kind
  return client === 'tsumi-ios' ? 'episode' : 'file'
}

/**
 * v2.5: a `player`, `countdown` or `index` sent from another episode than ours is not applied. No check when the
 * sender sent no `mediaKey` (older app) or our player plays nothing.
 * @param {string | null | undefined} sentKey
 * @param {string | null | undefined} localKey
 */
export function sameEpisode (sentKey, localKey) {
  return !sentKey || !localKey || sentKey === localKey
}

/**
 * Turns the burst of media events of one local change (pause + seek + play while dragging
 * the seekbar...) into one action.
 * @param {{ time: number, paused: boolean } | null} from settled state before the burst
 * @param {{ time: number, paused: boolean }} to state once the burst settled
 * @param {number | null} seekTo position reached by the last seek of the burst, null without seek
 * @returns {'play' | 'pause' | 'seek' | null}
 */
export function classifyLocalChange (from, to, seekTo) {
  if (!to) return null
  if (seekTo !== null && isFiniteNumber(seekTo)) {
    if (!from || Math.abs(seekTo - from.time) > SEEK_THRESHOLD_S) return 'seek'
  }
  if (!from || Boolean(from.paused) !== Boolean(to.paused)) return to.paused ? 'pause' : 'play'
  return null
}

/**
 * Tells local user actions apart from the echo of remote changes applied to the player.
 * Feed it the player's media events; it has no timers, the caller debounces `settle`.
 */
export class LocalActionTracker {
  /** @type {{ time: number, paused: boolean } | null} last settled state */
  stable = null
  /** @type {{ from: { time: number, paused: boolean } | null, seekTo: number | null } | null} */
  burst = null
  /** @type {{ time: number, paused: boolean, at: number } | null} remote state being applied */
  expected = null

  /** Forget everything, e.g. when another file is loaded. */
  reset (state = null) {
    this.stable = state ? { time: state.time, paused: !!state.paused } : null
    this.burst = null
    this.expected = null
  }

  /** On timeupdate: remember the position while nothing is going on. */
  observe ({ time, paused, seeking }) {
    if (this.burst || seeking || !isFiniteNumber(time)) return
    this.stable = { time, paused: !!paused }
  }

  /** A remote state is about to be applied: its media events must not be reported. */
  expect ({ time, paused }, now) {
    this.expected = { time, paused: !!paused, at: now }
  }

  /**
   * A media event happened.
   * @param {'play' | 'pause' | 'seeking' | 'seeked'} event
   * @param {number} [time] video time, needed for 'seeked'
   */
  note (event, time) {
    if (!this.burst) this.burst = { from: this.stable, seekTo: null }
    if (event === 'seeked' && isFiniteNumber(time)) this.burst.seekTo = time
  }

  get busy () {
    return !!this.burst
  }

  /**
   * The burst is over: returns the local action to report, or null.
   * @param {{ time: number, paused: boolean }} state
   * @param {number} now
   * @returns {{ action: 'play' | 'pause' | 'seek', time: number, paused: boolean, delta: number | null } | null}
   */
  settle ({ time, paused }, now) {
    const burst = this.burst
    this.burst = null
    const to = { time, paused: !!paused }
    this.stable = to
    if (!burst) return null

    const expected = this.expected
    this.expected = null
    if (expected && now - expected.at <= EXPECT_MS && expected.paused === to.paused) {
      const elapsed = expected.paused ? 0 : (now - expected.at) / 1000
      if (Math.abs(to.time - expected.time) <= IN_SYNC_S + elapsed * 2) return null
    }

    const action = classifyLocalChange(burst.from, to, burst.seekTo)
    if (!action) return null
    const delta = action === 'seek' && burst.from && burst.seekTo !== null ? burst.seekTo - burst.from.time : null
    return { action, time: to.time, paused: to.paused, delta }
  }
}
