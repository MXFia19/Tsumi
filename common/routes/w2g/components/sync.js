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
  if (typeof user?.name === 'string' && user.name.trim()) return user.name.trim()
  if (typeof user?.displayName === 'string' && user.displayName.trim()) return user.displayName.trim().slice(0, 32)
  if (user?.id != null) return `Guest ${String(user.id).slice(0, 4)}`
  return 'Anonymous'
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
  const total = Math.max(0, Math.floor(Number(seconds) || 0))
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
 * @typedef {{ status?: Status | null, receivedAt?: number, rtt?: number, protocol?: number, lastSeen?: number }} MemberSignal
 * @typedef {Status & { at: number }} LocalStatus our own status, `at` = when `time` was read
 * @typedef {{ kind: 'old' | 'nosignal' | 'idle' | 'loading' | 'buffering' | 'other' | 'own' | 'sync' | 'ahead' | 'behind' | 'playing' | 'paused', text: string, drift?: number }} Badge
 */

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
  if (!status) return member?.protocol === 1 ? { kind: 'old', text: 'Old version' } : { kind: 'nosignal', text: 'No signal' }

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
 * Whether a member row shows "Invite to watch": the member is idle, on another episode or without
 * signal for 10 s; we are in the player with a media; in `host` mode only the host invites.
 * @param {{ selfWatching: boolean, hasMedia: boolean, effectiveMode: string, isHost: boolean, now: number,
 *   member: { isSelf?: boolean, protocol?: number, badge?: Badge, status?: Status | null, receivedAt?: number, joinedAt?: number } }} input
 */
export function canInvite ({ selfWatching, hasMedia, effectiveMode, isHost, now, member }) {
  if (!selfWatching || !hasMedia || member.isSelf || !(member.protocol >= 2)) return false
  if (effectiveMode === 'host' && !isHost) return false
  const kind = member.badge?.kind
  // Independent members (v2.2) can be invited too.
  if (member.status?.state === 'idle' || kind === 'idle' || kind === 'other' || kind === 'own') return true
  if (kind !== 'nosignal') return false
  const since = member.status ? member.receivedAt : member.joinedAt
  return isFiniteNumber(since) && now - since >= NO_SIGNAL_MS
}

/**
 * Whether an `invite` is for us and allowed: anyone in `everyone` mode, the host only in `host` mode.
 * @param {{ to: unknown, selfId: string, senderId: string, hostId: string | null, effectiveMode: string }} input
 */
export function acceptsInvite ({ to, selfId, senderId, hostId, effectiveMode }) {
  if (!sameId(to, selfId) || sameId(senderId, selfId)) return false
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
 * @param {{ selfId: string, selfFollowing: boolean, peers: Array<{ userId: string, following?: boolean }> }} input
 * @returns {string | null}
 */
export function electFollowingHost ({ selfId, selfFollowing, peers }) {
  const following = [...(selfFollowing ? [selfId] : []), ...peers.filter(peer => peer.following !== false).map(peer => peer.userId)]
  return electHost(following.length ? following : [selfId, ...peers.map(peer => peer.userId)])
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
