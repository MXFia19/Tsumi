// Watch Together v2 pure logic. Run with: node common/routes/w2g/components/sync.test.mjs
import assert from 'node:assert/strict'
import {
  expectedTime, computeDrift, syncBadge, selfBadge, electHost, autoSyncStep, hostReference,
  normalizeReaction, normalizeCountdownSeconds, normalizeMode, memberName, describeAction, describeRequest,
  formatClock, formatDelta, inferAction, classifyLocalChange, LocalActionTracker, sameId,
  AUTO_SYNC_COOLDOWN_MS, REACTIONS,
  formatSource, parseMediaKey, formatEpisode, episodeLabelOf, switchLabel, createPresence, presenceOnStatus, presenceOnTick,
  describePresence, canInvite, acceptsInvite, inviteTarget, PRESENCE_DEBOUNCE_MS, LOST_ANNOUNCE_MS,
  normalizeNowPlaying, nowPlayingLabel, episodeLabelFor, pickFollowingHost, electFollowingHost, followBackAction,
  lobbyReference, canJoinPlayback, offeredMedia, invitePosition, autoStartsMedia,
  appliesCountdown, normalizeFeatures, normalizeVoice, voiceOffers, voiceLinkAction, acceptsVoiceOffer, voiceRetryDelay,
  voiceTransmitting, speakingStep, duckLevel, VOICE_DUCK_LEVEL, VOICE_SPEAKING_HOLD_MS, VOICE_MAX_RETRIES,
  emptyQueue, normalizeQueueEpisode, normalizeQueueItem, normalizeQueue, queueReduce, queueChanges, queueItemLabel,
  describeQueueChange, nextEpisodeOf, nextEpisodeTarget, acceptsQueue, QUEUE_MAX_ITEMS, QUEUE_MAX_PENDING, sameQueueEntry
} from './sync.js'

let passed = 0
let failed = 0
function test (name, fn) {
  try {
    fn()
    passed++
    console.log(`ok - ${name}`)
  } catch (error) {
    failed++
    console.error(`FAIL - ${name}\n${error?.stack || error}`)
  }
}

const near = (actual, expected, epsilon = 1e-9) => assert.ok(Math.abs(actual - expected) < epsilon, `${actual} != ${expected}`)

test('expectedTime extrapolates a playing status with rate and half the RTT', () => {
  const status = { state: 'playing', time: 100, rate: 1.5 }
  near(expectedTime(status, 1_000, 3_000, 200), 100 + 2 * 1.5 + 0.1)
  near(expectedTime(status, 1_000, 1_000), 100)
})

test('expectedTime does not move a paused / buffering status', () => {
  assert.equal(expectedTime({ state: 'paused', time: 42, rate: 1 }, 0, 60_000, 500), 42)
  assert.equal(expectedTime({ state: 'buffering', time: 42, rate: 1 }, 0, 60_000, 500), 42)
  assert.equal(expectedTime(null, 0, 0), null)
  assert.equal(expectedTime({ state: 'playing', time: NaN }, 0, 0), null)
})

test('expectedTime falls back to rate 1 and ignores a negative clock gap', () => {
  near(expectedTime({ state: 'playing', time: 10 }, 5_000, 6_000), 11)
  near(expectedTime({ state: 'playing', time: 10, rate: 0 }, 5_000, 6_000), 11)
  near(expectedTime({ state: 'playing', time: 10 }, 7_000, 6_000), 10)
})

test('computeDrift is expected minus local', () => {
  assert.equal(computeDrift(12, 10), 2)
  assert.equal(computeDrift(8, 10), -2)
})

const local = (over = {}) => ({ state: 'playing', time: 100, mediaKey: '1:1', rate: 1, at: 10_000, ...over })
const member = (over = {}, status = {}) => ({ status: { state: 'playing', time: 100, mediaKey: '1:1', rate: 1, ...status }, receivedAt: 10_000, rtt: 0, protocol: 2, lastSeen: 10_000, ...over })

test('syncBadge: in sync within 1.5 s and same play state', () => {
  assert.deepEqual(syncBadge(member({}, { time: 101.4 }), local(), 10_000), { kind: 'sync', text: 'In sync', drift: 101.4 - 100 })
  assert.equal(syncBadge(member({}, { state: 'paused', time: 99 }), local({ state: 'paused' }), 10_000).text, 'In sync')
})

test('syncBadge: ahead / behind rounded to 0.1 s', () => {
  assert.equal(syncBadge(member({}, { time: 103.26 }), local(), 10_000).text, '+3.3 s ahead')
  assert.equal(syncBadge(member({}, { time: 95.94 }), local(), 10_000).text, '4.1 s behind')
})

test('syncBadge: same time but different play state is not in sync', () => {
  const badge = syncBadge(member({}, { state: 'paused', time: 100 }), local(), 10_000)
  assert.equal(badge.kind, 'ahead')
  assert.equal(badge.text, '+0.0 s ahead')
})

test('syncBadge: both clocks advance, rtt counts for half', () => {
  // member status received at 10 s says 100, local read at 12 s says 102, now 13 s, rtt 400 ms
  const badge = syncBadge(member({ rtt: 400 }), local({ time: 102, at: 12_000 }), 13_000)
  near(badge.drift, (100 + 3 + 0.2) - 103)
  assert.equal(badge.text, 'In sync')
})

test('syncBadge: states, other episode, no signal, old version', () => {
  assert.equal(syncBadge(member({}, { state: 'buffering' }), local(), 10_000).text, 'Buffering')
  assert.equal(syncBadge(member({}, { state: 'loading' }), local(), 10_000).text, 'Loading')
  assert.equal(syncBadge(member({}, { state: 'idle' }), local(), 10_000).text, 'Not in the player')
  assert.equal(syncBadge(member({}, { mediaKey: '1:2' }), local(), 10_000).text, 'Other episode')
  assert.equal(syncBadge(member(), local(), 20_001).text, 'No signal')
  assert.equal(syncBadge({ protocol: 2 }, local(), 0).text, 'No signal')
  assert.equal(syncBadge({}, local(), 0).text, 'No signal')
  assert.equal(syncBadge({ protocol: 1 }, local(), 0).text, 'Old version')
})

test('syncBadge: a paused member kept alive by pings is not "No signal"', () => {
  const paused = member({ lastSeen: 30_000 }, { state: 'paused' })
  assert.equal(syncBadge(paused, local({ state: 'paused', at: 40_000 }), 40_000).text, 'In sync')
  assert.equal(syncBadge({ ...paused, lastSeen: 10_000 }, local({ state: 'paused', at: 40_000 }), 40_000).text, 'No signal')
  // A playing member must keep sending status.
  assert.equal(syncBadge(member({ lastSeen: 30_000 }), local({ at: 40_000 }), 40_000).text, 'No signal')
})

test('syncBadge: when we are not in the player, show what the member does', () => {
  assert.equal(syncBadge(member(), local({ state: 'idle', mediaKey: '' }), 10_000).text, 'Playing')
  assert.equal(syncBadge(member({}, { state: 'paused' }), null, 10_000).text, 'Paused')
})

test('selfBadge', () => {
  assert.equal(selfBadge(local()).text, 'Playing')
  assert.equal(selfBadge(local({ state: 'paused' })).text, 'Paused')
  assert.equal(selfBadge(null).text, 'Not in the player')
})

test('electHost picks the smallest id by string comparison', () => {
  assert.equal(electHost(['b3', 'a9', 'c1']), 'a9')
  assert.equal(electHost([9, 10, 100]), '10')
  assert.equal(electHost(['5', null, undefined, '']), '5')
  assert.equal(electHost([]), null)
})

test('sameId compares as strings', () => {
  assert.ok(sameId(12, '12'))
  assert.ok(!sameId(null, 'null'))
  assert.ok(!sameId('a', 'b'))
})

const syncInput = (over = {}) => ({
  enabled: true,
  isHost: false,
  hostStatus: { state: 'playing', time: 110, mediaKey: '1:1', rate: 1 },
  hostReceivedAt: 10_000,
  hostRtt: 0,
  local: local({ time: 100, at: 10_000 }),
  now: 10_000,
  ...over
})

test('autoSyncStep needs two consecutive drifting heartbeats', () => {
  const first = autoSyncStep(null, syncInput())
  assert.equal(first.seekTo, null)
  assert.equal(first.streak, 1)
  const second = autoSyncStep(first, syncInput({ now: 13_000, hostReceivedAt: 13_000, hostStatus: { state: 'playing', time: 113, mediaKey: '1:1', rate: 1 }, local: local({ time: 103, at: 13_000 }) }))
  assert.equal(second.seekTo, 113)
  assert.equal(second.lastSyncAt, 13_000)
  assert.equal(second.streak, 0)
})

test('autoSyncStep: a heartbeat in sync resets the streak', () => {
  const first = autoSyncStep(null, syncInput())
  const ok = autoSyncStep(first, syncInput({ hostStatus: { state: 'playing', time: 101, mediaKey: '1:1' } }))
  assert.equal(ok.streak, 0)
  const again = autoSyncStep(ok, syncInput())
  assert.equal(again.seekTo, null)
})

test('autoSyncStep: at most once every 10 s', () => {
  const memory = { streak: 5, lastSyncAt: 5_000 }
  const blocked = autoSyncStep(memory, syncInput({ now: 5_000 + AUTO_SYNC_COOLDOWN_MS - 1 }))
  assert.equal(blocked.seekTo, null)
  assert.equal(blocked.streak, 6)
  const allowed = autoSyncStep(blocked, syncInput({ now: 5_000 + AUTO_SYNC_COOLDOWN_MS, hostReceivedAt: 5_000 + AUTO_SYNC_COOLDOWN_MS, local: local({ time: 100, at: 5_000 + AUTO_SYNC_COOLDOWN_MS }) }))
  assert.equal(allowed.seekTo, 110)
})

test('autoSyncStep: not for the host, not when disabled, paused, other episode or no host status', () => {
  const primed = { streak: 3, lastSyncAt: -Infinity }
  assert.equal(autoSyncStep(primed, syncInput({ isHost: true })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ enabled: false })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ hostStatus: null })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ hostStatus: { state: 'paused', time: 110, mediaKey: '1:1' } })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ local: local({ state: 'paused' }) })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ hostStatus: { state: 'playing', time: 110, mediaKey: '1:2' } })).seekTo, null)
  assert.equal(autoSyncStep(primed, syncInput({ hostStatus: { state: 'playing', time: 102, mediaKey: '1:1' } })).seekTo, null)
})

test('hostReference uses the status, else the last host player event', () => {
  const fromStatus = hostReference({ status: { state: 'playing', time: 50, mediaKey: 'k', rate: 1 }, receivedAt: 0, rtt: 0 }, 2_000)
  assert.deepEqual(fromStatus, { time: 52, paused: false, mediaKey: 'k' })
  const buffering = hostReference({ status: { state: 'buffering', time: 50, mediaKey: 'k' }, receivedAt: 0 }, 2_000)
  assert.deepEqual(buffering, { time: 50, paused: false, mediaKey: 'k' })
  const oldPaused = hostReference({ status: { state: 'paused', time: 50, mediaKey: 'k' }, receivedAt: 0 }, 10 * 60_000)
  assert.deepEqual(oldPaused, { time: 50, paused: true, mediaKey: 'k' })
  const fromPlayer = hostReference({ status: null, lastPlayer: { time: 20, paused: false, at: 1_000 } }, 4_000)
  assert.deepEqual(fromPlayer, { time: 23, paused: false, mediaKey: null })
  assert.equal(hostReference({ status: { state: 'idle', time: 0 }, receivedAt: 0 }, 0), null)
})

test('normalizeReaction keeps only the eight protocol emoji', () => {
  for (const emoji of REACTIONS) assert.equal(normalizeReaction(emoji), emoji)
  assert.equal(normalizeReaction('❤'), '❤️')
  assert.equal(normalizeReaction('💩'), null)
  assert.equal(normalizeReaction('😂😂'), null)
  assert.equal(normalizeReaction(42), null)
  assert.equal(REACTIONS.length, 8)
})

test('normalizeCountdownSeconds clamps to 1-10', () => {
  assert.equal(normalizeCountdownSeconds(3), 3)
  assert.equal(normalizeCountdownSeconds(0), 1)
  assert.equal(normalizeCountdownSeconds(60), 10)
  assert.equal(normalizeCountdownSeconds(2.6), 3)
  assert.equal(normalizeCountdownSeconds(undefined), 3)
  assert.equal(normalizeCountdownSeconds('x'), 3)
})

test('normalizeMode defaults to everyone', () => {
  assert.equal(normalizeMode('host'), 'host')
  assert.equal(normalizeMode('admin'), 'everyone')
  assert.equal(normalizeMode(undefined), 'everyone')
})

test('memberName: name, then display name, then short id', () => {
  assert.equal(memberName({ id: 1, name: 'Alice' }), 'Alice')
  assert.equal(memberName({ id: 'abcdef0123456789', displayName: ' Bob ' }), 'Bob')
  assert.equal(memberName({ id: 'abcdef0123456789' }), 'Guest abcd')
  assert.equal(memberName(null), 'Anonymous')
})

test('formatClock / formatDelta', () => {
  assert.equal(formatClock(754), '12:34')
  assert.equal(formatClock(65.9), '1:05')
  assert.equal(formatClock(3723), '1:02:03')
  assert.equal(formatClock(-3), '0:00')
  assert.equal(formatDelta(90), '+1:30')
  assert.equal(formatDelta(-5.4), '-0:05')
})

test('describeAction matches the protocol wording', () => {
  assert.equal(describeAction({ name: 'Alice', action: 'pause', time: 754 }), 'Alice paused at 12:34')
  assert.equal(describeAction({ name: 'Alice', action: 'play', time: 754 }), 'Alice resumed')
  assert.equal(describeAction({ name: 'Alice', action: 'seek', time: 754, delta: 90 }), 'Alice jumped to 12:34 (+1:30)')
  assert.equal(describeAction({ name: 'You', action: 'seek', time: 754 }), 'You jumped to 12:34')
  assert.equal(describeAction({ name: 'Alice', action: 'sync', time: 754 }), null)
  assert.equal(describeRequest('Bob', { kind: 'seek', time: 61 }), 'Bob asked to jump to 1:01')
  assert.equal(describeRequest('Bob', { kind: 'pause' }), 'Bob asked to pause')
})

test('inferAction for v1 player events', () => {
  assert.equal(inferAction({ paused: false }, { paused: true }), 'pause')
  assert.equal(inferAction({ paused: true }, { paused: false }), 'play')
  assert.equal(inferAction({ paused: true }, { paused: true }), 'seek')
  assert.equal(inferAction(null, { paused: true }), 'pause')
})

test('classifyLocalChange', () => {
  assert.equal(classifyLocalChange({ time: 10, paused: false }, { time: 10.3, paused: true }, null), 'pause')
  assert.equal(classifyLocalChange({ time: 10, paused: true }, { time: 10, paused: false }, null), 'play')
  assert.equal(classifyLocalChange({ time: 10, paused: false }, { time: 70.2, paused: false }, 70), 'seek')
  // Small fix-up seeks (audio track switch) are not user actions.
  assert.equal(classifyLocalChange({ time: 10, paused: false }, { time: 9.9, paused: false }, 9.8), null)
  assert.equal(classifyLocalChange({ time: 10, paused: false }, { time: 10, paused: false }, null), null)
})

test('LocalActionTracker: a seekbar drag (pause, seek, play) is one seek', () => {
  const tracker = new LocalActionTracker()
  tracker.observe({ time: 100, paused: false, seeking: false })
  tracker.note('pause')
  tracker.note('seeking')
  tracker.observe({ time: 300, paused: true, seeking: true })
  tracker.note('seeked', 300)
  tracker.note('play')
  const change = tracker.settle({ time: 300.2, paused: false }, 1_000)
  assert.deepEqual(change, { action: 'seek', time: 300.2, paused: false, delta: 200 })
})

test('LocalActionTracker: the echo of a remote change is not reported', () => {
  const tracker = new LocalActionTracker()
  tracker.observe({ time: 100, paused: false, seeking: false })
  tracker.expect({ time: 40, paused: true }, 1_000)
  tracker.note('pause')
  tracker.note('seeking')
  tracker.note('seeked', 40)
  // Even when the seek took a while to finish.
  assert.equal(tracker.settle({ time: 40, paused: true }, 5_000), null)
  // The next real action is reported again.
  tracker.note('play')
  assert.equal(tracker.settle({ time: 40.1, paused: false }, 6_000)?.action, 'play')
})

test('LocalActionTracker: a user action that differs from the expected remote state is reported', () => {
  const tracker = new LocalActionTracker()
  tracker.observe({ time: 10, paused: true, seeking: false })
  tracker.expect({ time: 10, paused: false }, 0)
  tracker.note('play')
  tracker.note('pause')
  assert.deepEqual(tracker.settle({ time: 10.1, paused: true }, 300), null) // play + pause = no net change
  tracker.expect({ time: 10, paused: false }, 0)
  tracker.note('seeking')
  tracker.note('seeked', 200)
  assert.equal(tracker.settle({ time: 200, paused: true }, 400)?.action, 'seek')
})

test('LocalActionTracker: an expectation older than 10 s is ignored', () => {
  const tracker = new LocalActionTracker()
  tracker.observe({ time: 10, paused: false, seeking: false })
  tracker.expect({ time: 10, paused: true }, 0)
  tracker.note('pause')
  assert.equal(tracker.settle({ time: 10, paused: true }, 20_000)?.action, 'pause')
})

// ---------------------------------------------------------------- v2.1

test('formatSource joins extension and server with " · " and drops empty parts', () => {
  assert.equal(formatSource('AnimePahe', 'Server 2'), 'AnimePahe · Server 2')
  assert.equal(formatSource('AnimePahe', ''), 'AnimePahe')
  assert.equal(formatSource(undefined, ' Server 2 '), 'Server 2')
  assert.equal(formatSource(), '')
})

test('parseMediaKey / labels', () => {
  assert.deepEqual(parseMediaKey('123:5'), { mediaId: '123', season: null, episode: '5' })
  assert.deepEqual(parseMediaKey('tmdb-9:2:5'), { mediaId: 'tmdb-9', season: '2', episode: '5' })
  assert.deepEqual(parseMediaKey('tmdb-9::5'), { mediaId: 'tmdb-9', season: null, episode: '5' })
  assert.equal(parseMediaKey(''), null)
  assert.equal(formatEpisode({ episode: 5 }), 'Episode 5')
  assert.equal(formatEpisode({ season: 2, episode: 5 }), 'S2 E5')
  assert.equal(formatEpisode({ episode: undefined }), null)
  assert.equal(episodeLabelOf(7), 'Episode 7')
  assert.equal(episodeLabelOf({ number: 30, season: 2, localEpisode: 5 }), 'S2 E5')
  assert.equal(episodeLabelOf({ number: 30 }), 'Episode 30')
  assert.equal(switchLabel('123:4', '123:5'), 'Episode 5')
  assert.equal(switchLabel('tmdb-9:2:4', 'tmdb-9:2:5'), 'S2 E5')
  assert.equal(switchLabel('123:4', '456:1'), 'another title')
})

const st = (state, over = {}) => ({ state, time: 10, mediaKey: '123:4', rate: 1, source: 'AnimePahe · Server 1', ...over })
const kinds = result => result.announcements.map(a => a.kind)

test('presence: the first status only announces "started watching"', () => {
  assert.deepEqual(kinds(presenceOnStatus(null, st('playing'), 0)), ['started'])
  assert.deepEqual(kinds(presenceOnStatus(null, st('loading'), 0)), ['started'])
  assert.deepEqual(kinds(presenceOnStatus(null, st('idle', { mediaKey: '' }), 0)), [])
  assert.deepEqual(kinds(presenceOnStatus(createPresence(), st('buffering'), 0)), [])
})

test('presence: stopped watching / watching again', () => {
  let p = presenceOnStatus(null, st('playing'), 0).presence
  let r = presenceOnStatus(p, st('idle', { mediaKey: '' }), 1_000)
  assert.deepEqual(kinds(r), ['stopped'])
  r = presenceOnStatus(r.presence, st('loading'), 2_000)
  assert.deepEqual(kinds(r), ['again'])
  // Heartbeats with nothing new announce nothing.
  p = presenceOnStatus(r.presence, st('playing'), 3_000).presence
  assert.deepEqual(kinds(presenceOnStatus(p, st('playing', { time: 13 }), 6_000)), [])
})

test('presence: switched episode / title, only while not idle', () => {
  const p = presenceOnStatus(null, st('playing'), 0).presence
  const r = presenceOnStatus(p, st('loading', { mediaKey: '123:5' }), 1_000)
  assert.deepEqual(r.announcements, [{ kind: 'switched', label: 'Episode 5' }])
  assert.deepEqual(presenceOnStatus(p, st('loading', { mediaKey: '456:1' }), 1_000).announcements, [{ kind: 'switched', label: 'another title' }])
  // Back from idle (empty key) is "watching again", not a switch.
  const idle = presenceOnStatus(p, st('idle', { mediaKey: '' }), 1_000).presence
  assert.deepEqual(kinds(presenceOnStatus(idle, st('loading', { mediaKey: '123:9' }), 9_000)), ['again'])
})

test('presence: source change needs the same key and two non-empty values', () => {
  const p = presenceOnStatus(null, st('playing'), 0).presence
  assert.deepEqual(presenceOnStatus(p, st('playing', { source: 'AnimePahe · Server 2' }), 1_000).announcements, [{ kind: 'source', source: 'AnimePahe · Server 2' }])
  assert.deepEqual(kinds(presenceOnStatus(p, st('playing', { source: '' }), 1_000)), [])
  assert.deepEqual(kinds(presenceOnStatus(p, st('loading', { mediaKey: '123:5', source: 'Other' }), 1_000)), ['switched'])
})

test('presence: the same member and kind announces at most once every 5 s', () => {
  let p = presenceOnStatus(null, st('playing'), 0).presence
  let r = presenceOnStatus(p, st('idle', { mediaKey: '' }), 1_000)
  assert.deepEqual(kinds(r), ['stopped'])
  p = presenceOnStatus(r.presence, st('playing'), 2_000).presence
  r = presenceOnStatus(p, st('idle', { mediaKey: '' }), 3_000)
  assert.deepEqual(kinds(r), [])
  p = presenceOnStatus(r.presence, st('playing'), 3_500).presence
  r = presenceOnStatus(p, st('idle', { mediaKey: '' }), 1_000 + PRESENCE_DEBOUNCE_MS)
  assert.deepEqual(kinds(r), ['stopped'])
})

test('presence: buffering over 8 s announces once per buffering period', () => {
  let p = presenceOnStatus(null, st('playing'), 0).presence
  p = presenceOnStatus(p, st('buffering'), 10_000).presence
  p = presenceOnStatus(p, st('buffering'), 13_000).presence // heartbeat keeps the period
  let r = presenceOnTick(p, { now: 18_000, lastStatusAt: 16_000 })
  assert.deepEqual(kinds(r), [])
  r = presenceOnTick(r.presence, { now: 18_001, lastStatusAt: 16_000 })
  assert.deepEqual(kinds(r), ['buffering'])
  r = presenceOnTick(r.presence, { now: 19_000, lastStatusAt: 19_000 })
  assert.deepEqual(kinds(r), [])
  // A new period after playing again announces again (after the debounce).
  p = presenceOnStatus(r.presence, st('playing'), 20_000).presence
  p = presenceOnStatus(p, st('buffering'), 30_000).presence
  assert.deepEqual(kinds(presenceOnTick(p, { now: 38_500, lastStatusAt: 38_000 })), ['buffering'])
})

test('presence: lost connection once until a status arrives again', () => {
  let p = presenceOnStatus(null, st('paused'), 0).presence
  assert.deepEqual(kinds(presenceOnTick(p, { now: LOST_ANNOUNCE_MS - 1, lastStatusAt: 0, lastPongAt: 0 })), [])
  // A pong keeps it alive.
  assert.deepEqual(kinds(presenceOnTick(p, { now: LOST_ANNOUNCE_MS, lastStatusAt: 0, lastPongAt: 5_000 })), [])
  let r = presenceOnTick(p, { now: LOST_ANNOUNCE_MS, lastStatusAt: 0, lastPongAt: 0 })
  assert.deepEqual(kinds(r), ['lost'])
  r = presenceOnTick(r.presence, { now: LOST_ANNOUNCE_MS + 60_000, lastStatusAt: 0 })
  assert.deepEqual(kinds(r), [])
  p = presenceOnStatus(r.presence, st('paused'), LOST_ANNOUNCE_MS + 61_000).presence
  assert.deepEqual(kinds(presenceOnTick(p, { now: 2 * LOST_ANNOUNCE_MS + 61_000, lastStatusAt: LOST_ANNOUNCE_MS + 61_000 })), ['lost'])
  // Nothing before the first status.
  assert.deepEqual(kinds(presenceOnTick(null, { now: 100_000 })), [])
})

test('describePresence wording', () => {
  assert.equal(describePresence('Alice', { kind: 'stopped' }), 'Alice stopped watching')
  assert.equal(describePresence('Alice', { kind: 'again' }), 'Alice is watching again')
  assert.equal(describePresence('Alice', { kind: 'started' }), 'Alice started watching')
  assert.equal(describePresence('Alice', { kind: 'switched', label: 'S2 E5' }), 'Alice switched to S2 E5')
  assert.equal(describePresence('Alice', { kind: 'source', source: 'AnimePahe · Server 2' }), 'Alice changed source: AnimePahe · Server 2')
  assert.equal(describePresence('Alice', { kind: 'buffering' }), 'Alice is buffering…')
  assert.equal(describePresence('Alice', { kind: 'lost' }), 'Alice lost connection')
})

// v2.3 rules: an offered media key, no "inviter in the player" requirement.
const invitable = (over = {}, member = {}) => ({
  offeredKey: '123:5',
  effectiveMode: 'everyone',
  isHost: false,
  now: 100_000,
  member: { isSelf: false, protocol: 2, badge: { kind: 'idle' }, status: { state: 'idle', mediaKey: '' }, ...member },
  ...over
})

test('canInvite: idle, another key, independent or no signal', () => {
  assert.equal(canInvite(invitable()), true)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'other' }, status: { state: 'playing', mediaKey: '123:4' } })), true)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'sync' }, status: { state: 'playing', mediaKey: '123:5' } })), false)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'paused' }, status: { state: 'paused', mediaKey: '123:5' } })), false)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'nosignal' }, status: { state: 'playing', mediaKey: '123:5' } })), true)
  // No status yet: only 10 s after its init.
  assert.equal(canInvite(invitable({}, { badge: { kind: 'connecting' }, status: null, joinedAt: 95_000 })), false)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'nosignal' }, status: null, joinedAt: 90_000 })), true)
})

test('canInvite: needs a media to offer, a v2 member, and the host role in host mode', () => {
  assert.equal(canInvite(invitable({ offeredKey: null })), false)
  assert.equal(canInvite(invitable({}, { protocol: 1, badge: { kind: 'old' }, status: null })), false)
  assert.equal(canInvite(invitable({}, { isSelf: true })), false)
  assert.equal(canInvite(invitable({ effectiveMode: 'host' })), false)
  assert.equal(canInvite(invitable({ effectiveMode: 'host', isHost: true })), true)
})

test('acceptsInvite', () => {
  const base = { to: 'b', selfId: 'b', senderId: 'a', hostId: 'h', effectiveMode: 'everyone' }
  assert.equal(acceptsInvite(base), true)
  assert.equal(acceptsInvite({ ...base, to: 'c' }), false)
  assert.equal(acceptsInvite({ ...base, effectiveMode: 'host' }), false)
  assert.equal(acceptsInvite({ ...base, effectiveMode: 'host', senderId: 'h' }), true)
  assert.equal(acceptsInvite({ ...base, to: 7, selfId: '7' }), true)
})

test('inviteTarget: host on the same episode, else the inviter plus elapsed time', () => {
  const invite = { key: '123:5', time: 100, paused: false, receivedAt: 10_000 }
  assert.deepEqual(inviteTarget({ invite, host: null, now: 25_000 }), { time: 115, paused: false, from: 'inviter' })
  assert.deepEqual(inviteTarget({ invite: { ...invite, paused: true }, host: null, now: 25_000 }), { time: 100, paused: true, from: 'inviter' })
  assert.deepEqual(inviteTarget({ invite, host: { time: 300, paused: true, mediaKey: '123:5' }, now: 25_000 }), { time: 300, paused: true, from: 'host' })
  assert.deepEqual(inviteTarget({ invite, host: { time: 300, paused: true, mediaKey: '123:6' }, now: 25_000 }).from, 'inviter')
})

// ---------------------------------------------------------------- v2.2

test('nowPlaying: normalize, label, episode label', () => {
  assert.deepEqual(normalizeNowPlaying({ mediaId: 21, title: ' One Piece ', episode: 'Episode 5', extra: 1 }), { mediaId: 21, title: 'One Piece', episode: 'Episode 5' })
  assert.deepEqual(normalizeNowPlaying({ mediaId: {}, title: 3 }), { mediaId: null, title: '', episode: '' })
  assert.equal(normalizeNowPlaying(null), null)
  assert.equal(nowPlayingLabel({ title: 'One Piece', episode: 'Episode 5' }), 'One Piece · Episode 5')
  assert.equal(nowPlayingLabel({ title: 'Your Name', episode: '' }), 'Your Name')
  assert.equal(nowPlayingLabel(null), '')
  assert.equal(episodeLabelFor({ episode: 1, format: 'MOVIE', episodes: 1 }), 'Movie')
  assert.equal(episodeLabelFor({ episode: 2, format: 'MOVIE', episodes: 3 }), 'Episode 2')
  assert.equal(episodeLabelFor({ episode: { number: 30, season: 2, localEpisode: 5 }, format: 'TV' }), 'S2 E5')
})

test('syncBadge: an independent member watches on their own, no drift', () => {
  const badge = syncBadge(member({}, { following: false, time: 500 }), local(), 10_000)
  assert.deepEqual(badge, { kind: 'own', text: 'Watching on their own' })
  assert.equal(syncBadge(member({}, { following: false, state: 'idle' }), local(), 10_000).text, 'Not in the player')
  assert.equal(syncBadge(member({}, { following: true, time: 100 }), local(), 10_000).text, 'In sync')
})

test('autoSyncStep: never against a host that does not follow', () => {
  const primed = { streak: 3, lastSyncAt: -Infinity }
  assert.equal(autoSyncStep(primed, syncInput({ hostStatus: { state: 'playing', time: 110, mediaKey: '1:1', following: false } })).seekTo, null)
})

test('canInvite: an independent member can be invited', () => {
  assert.equal(canInvite(invitable({}, { badge: { kind: 'own' }, status: { state: 'playing', following: false, mediaKey: '123:5' } })), true)
})

test('presence: following off / on, and "is watching" replaces "switched to"', () => {
  const p = presenceOnStatus(null, st('playing'), 0).presence
  let r = presenceOnStatus(p, st('playing', { following: false }), 1_000)
  assert.deepEqual(kinds(r), ['own'])
  r = presenceOnStatus(r.presence, st('loading', { following: false, mediaKey: '456:1', nowPlaying: { mediaId: 456, title: 'Frieren', episode: 'Episode 1' } }), 2_000)
  assert.deepEqual(r.announcements, [{ kind: 'watching', label: 'Frieren · Episode 1' }])
  r = presenceOnStatus(r.presence, st('playing', { following: true, mediaKey: '456:1' }), 3_000)
  assert.deepEqual(kinds(r), ['back'])
  // A missing `following` means true (v2.1 clients).
  assert.deepEqual(kinds(presenceOnStatus(p, st('playing', { following: undefined }), 1_000)), [])
  assert.equal(describePresence('Alice', { kind: 'own' }), 'Alice is watching on their own')
  assert.equal(describePresence('Alice', { kind: 'back' }), 'Alice is back in sync')
  assert.equal(describePresence('Alice', { kind: 'watching', label: 'Frieren · Episode 1' }), 'Alice is watching Frieren · Episode 1')
})

test('host hand-off goes to the smallest following v2 peer', () => {
  assert.equal(pickFollowingHost([{ userId: 'c', protocol: 2 }, { userId: 'b', protocol: 2, following: false }, { userId: 'a', protocol: 1 }, { userId: 'd', protocol: 2, following: true }]), 'c')
  assert.equal(pickFollowingHost([{ userId: 'b', protocol: 2, following: false }]), null)
  assert.equal(pickFollowingHost([]), null)
})

test('host election skips independent members unless nobody follows', () => {
  assert.equal(electFollowingHost({ selfId: 'z', selfFollowing: true, peers: [{ userId: 'a', following: false }, { userId: 'm' }] }), 'm')
  assert.equal(electFollowingHost({ selfId: 'b', selfFollowing: false, peers: [{ userId: 'c' }] }), 'c')
  assert.equal(electFollowingHost({ selfId: 'b', selfFollowing: false, peers: [{ userId: 'a', following: false }] }), 'a')
})

test('followBackAction: resync on the lobby episode, else offer rejoin', () => {
  assert.equal(followBackAction({ localKey: '1:5', lobbyKey: '1:5' }), 'resync')
  assert.equal(followBackAction({ localKey: '1:4', lobbyKey: '1:5' }), 'rejoin')
  assert.equal(followBackAction({ localKey: '', lobbyKey: '1:5' }), 'rejoin')
  assert.equal(followBackAction({ localKey: '1:4', lobbyKey: null }), 'none')
})

// ---------------------------------------------------------------- v2.3

test('syncBadge: a v2 member without status is "No signal" only 10 s after its init', () => {
  assert.equal(syncBadge({ protocol: 2, joinedAt: 5_000 }, local(), 14_000).kind, 'connecting')
  assert.equal(syncBadge({ protocol: 2, joinedAt: 5_000 }, local(), 15_000).text, 'No signal')
  assert.equal(syncBadge({ protocol: 1, joinedAt: 5_000 }, local(), 6_000).text, 'Old version')
})

const on = (state, over = {}) => ({ state, time: 10, mediaKey: '123:5', ...over })

test('lobbyReference: the host when it watches the lobby media', () => {
  const members = [{ userId: 'h', status: on('playing') }, { userId: 'a', status: on('playing') }]
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members }), 'h')
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members: [{ userId: 'h', status: on('loading') }] }), 'h')
  assert.equal(lobbyReference({ lobbyKey: null, hostId: 'h', members }), null)
})

test('lobbyReference: host idle, independent or without status: the smallest following member', () => {
  const others = [{ userId: 'c', status: on('paused') }, { userId: 'b', status: on('playing') }, { userId: 'a', status: on('playing', { following: false }) }]
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members: [{ userId: 'h', status: on('idle', { mediaKey: '' }) }, ...others] }), 'b')
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members: [{ userId: 'h', status: on('playing', { following: false }) }, ...others] }), 'b')
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members: [{ userId: 'h' }, ...others] }), 'b')
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: null, members: others }), 'b')
  // Nobody following on the lobby key: not watching.
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members: [{ userId: 'h', status: on('idle') }, { userId: 'a', status: on('playing', { mediaKey: '9:1' }) }] }), null)
})

test('lobbyReference: a host watching something else means the lobby is not watching', () => {
  const members = [{ userId: 'h', status: on('playing', { mediaKey: '9:1' }) }, { userId: 'a', status: on('playing') }]
  assert.equal(lobbyReference({ lobbyKey: '123:5', hostId: 'h', members }), null)
})

test('canJoinPlayback: idle, other key or independent, while someone else is the reference', () => {
  const base = { reference: 'h', selfId: 'me', lobbyKey: '123:5', local: { state: 'idle', mediaKey: '' }, following: true }
  assert.equal(canJoinPlayback(base), true)
  assert.equal(canJoinPlayback({ ...base, local: { state: 'playing', mediaKey: '9:1' } }), true)
  assert.equal(canJoinPlayback({ ...base, local: { state: 'playing', mediaKey: '123:5' } }), false)
  assert.equal(canJoinPlayback({ ...base, local: { state: 'playing', mediaKey: '123:5' }, following: false }), true)
  assert.equal(canJoinPlayback({ ...base, reference: null }), false)
  assert.equal(canJoinPlayback({ ...base, reference: 'me' }), false)
})

test('offeredMedia: ours when playing one, else the watched lobby media', () => {
  assert.deepEqual(offeredMedia({ ownKey: '9:1', ownActive: true, lobbyKey: '123:5', lobbyWatching: true }), { from: 'own', key: '9:1' })
  assert.deepEqual(offeredMedia({ ownKey: '9:1', ownActive: false, lobbyKey: '123:5', lobbyWatching: true }), { from: 'lobby', key: '123:5' })
  assert.equal(offeredMedia({ ownKey: null, ownActive: false, lobbyKey: '123:5', lobbyWatching: false }), null)
})

test('invitePosition: our playback for our media, else the reference', () => {
  const own = { time: 50, paused: false }
  const reference = { time: 300, paused: true }
  assert.deepEqual(invitePosition({ offered: { from: 'own' }, own, reference }), { time: 50, paused: false })
  assert.deepEqual(invitePosition({ offered: { from: 'lobby' }, own, reference }), { time: 300, paused: true })
  assert.equal(invitePosition({ offered: { from: 'lobby' }, own, reference: null }), null)
  assert.equal(invitePosition({ offered: null, own, reference }), null)
})

test('autoStartsMedia: never for newcomers or idle members, only for followers already watching', () => {
  assert.equal(autoStartsMedia({ following: true, localState: 'playing', senderJoinedAt: 0, now: 60_000 }), true)
  // The lobby state the host sends right after init.
  assert.equal(autoStartsMedia({ following: true, localState: 'playing', senderJoinedAt: 58_000, now: 60_000 }), false)
  assert.equal(autoStartsMedia({ following: true, localState: 'idle', senderJoinedAt: 0, now: 60_000 }), false)
  assert.equal(autoStartsMedia({ following: false, localState: 'playing', senderJoinedAt: 0, now: 60_000 }), false)
})

// ---------------------------------------------------------------- v2.4

test('appliesCountdown: only on the lobby media, or while playing nothing', () => {
  assert.equal(appliesCountdown({ localKey: '1:5', lobbyKey: '1:5' }), true)
  assert.equal(appliesCountdown({ localKey: '', lobbyKey: '1:5' }), true)
  assert.equal(appliesCountdown({ localKey: '1:4', lobbyKey: null }), true)
  assert.equal(appliesCountdown({ localKey: '1:4', lobbyKey: '1:5' }), false)
})

test('normalizeFeatures keeps distinct short strings', () => {
  assert.deepEqual(normalizeFeatures(['voice', 'queue', 'voice', 3, '', 'x'.repeat(40)]), ['voice', 'queue'])
  assert.deepEqual(normalizeFeatures(undefined), [])
  assert.deepEqual(normalizeFeatures('voice'), [])
})

test('normalizeVoice: speaking only when joined and not muted', () => {
  assert.deepEqual(normalizeVoice({ joined: true, muted: false, speaking: true }), { joined: true, muted: false, speaking: true })
  assert.deepEqual(normalizeVoice({ joined: true, muted: true, speaking: true }), { joined: true, muted: true, speaking: false })
  assert.deepEqual(normalizeVoice({ joined: false, speaking: true }), { joined: false, muted: false, speaking: false })
  assert.deepEqual(normalizeVoice(null), { joined: false, muted: false, speaking: false })
  assert.deepEqual(normalizeVoice({ joined: 'yes' }), { joined: false, muted: false, speaking: false })
})

test('voiceOffers: the smaller userId offers (string comparison)', () => {
  assert.equal(voiceOffers('123', '45'), true)
  assert.equal(voiceOffers('45', '123'), false)
  assert.equal(voiceOffers(7, 'a1'), true)
})

test('voiceLinkAction', () => {
  const base = { selfJoined: true, memberJoined: true, memberHasVoice: true, hasLink: false, selfOffers: true }
  assert.equal(voiceLinkAction(base), 'offer')
  assert.equal(voiceLinkAction({ ...base, selfOffers: false }), 'wait')
  assert.equal(voiceLinkAction({ ...base, hasLink: true }), 'none')
  assert.equal(voiceLinkAction({ ...base, memberJoined: false, hasLink: true }), 'close')
  assert.equal(voiceLinkAction({ ...base, selfJoined: false, hasLink: true }), 'close')
  assert.equal(voiceLinkAction({ ...base, memberHasVoice: false }), 'none')
})

test('acceptsVoiceOffer: both in voice and the sender is the offerer', () => {
  assert.equal(acceptsVoiceOffer({ selfJoined: true, memberJoined: true, selfId: 'b', senderId: 'a' }), true)
  assert.equal(acceptsVoiceOffer({ selfJoined: true, memberJoined: true, selfId: 'a', senderId: 'b' }), false)
  assert.equal(acceptsVoiceOffer({ selfJoined: false, memberJoined: true, selfId: 'b', senderId: 'a' }), false)
  assert.equal(acceptsVoiceOffer({ selfJoined: true, memberJoined: false, selfId: 'b', senderId: 'a' }), false)
})

test('voiceRetryDelay: five retries in a row, then gives up', () => {
  assert.equal(voiceRetryDelay(1), 3_000)
  assert.equal(voiceRetryDelay(VOICE_MAX_RETRIES), 3_000)
  assert.equal(voiceRetryDelay(VOICE_MAX_RETRIES + 1), null)
})

test('voiceTransmitting: push-to-talk needs the key held', () => {
  const base = { joined: true, hasMic: true, muted: false, pushToTalk: false, held: false }
  assert.equal(voiceTransmitting(base), true)
  assert.equal(voiceTransmitting({ ...base, muted: true }), false)
  assert.equal(voiceTransmitting({ ...base, hasMic: false }), false)
  assert.equal(voiceTransmitting({ ...base, joined: false }), false)
  assert.equal(voiceTransmitting({ ...base, pushToTalk: true }), false)
  assert.equal(voiceTransmitting({ ...base, pushToTalk: true, held: true }), true)
})

test('speakingStep: on at once, off after 600 ms of silence, never while not transmitting', () => {
  let step = speakingStep(null, { level: 0.2, transmitting: true, now: 1_000 })
  assert.equal(step.speaking, true)
  step = speakingStep(step, { level: 0.01, transmitting: true, now: 1_000 + VOICE_SPEAKING_HOLD_MS - 1 })
  assert.equal(step.speaking, true)
  step = speakingStep(step, { level: 0.01, transmitting: true, now: 1_000 + VOICE_SPEAKING_HOLD_MS })
  assert.equal(step.speaking, false)
  step = speakingStep({ lastLoudAt: 900 }, { level: 0.5, transmitting: false, now: 1_000 })
  assert.equal(step.speaking, false)
  assert.equal(speakingStep(null, { level: null, transmitting: true, now: 0 }).speaking, false)
})

test('duckLevel: only in voice, for a member we hear speaking', () => {
  const speaker = { joined: true, speaking: true }
  assert.equal(duckLevel({ enabled: true, selfJoined: true, members: [speaker] }), VOICE_DUCK_LEVEL)
  assert.equal(duckLevel({ enabled: false, selfJoined: true, members: [speaker] }), 1)
  assert.equal(duckLevel({ enabled: true, selfJoined: false, members: [speaker] }), 1)
  assert.equal(duckLevel({ enabled: true, selfJoined: true, members: [{ ...speaker, localMuted: true }] }), 1)
  assert.equal(duckLevel({ enabled: true, selfJoined: true, members: [{ ...speaker, volume: 0 }] }), 1)
  assert.equal(duckLevel({ enabled: true, selfJoined: true, members: [{ joined: true, speaking: false }] }), 1)
})

const qMedia = (id = 21, over = {}) => ({ id, title: { userPreferred: 'One Piece' }, format: 'TV', episodes: 1100, ...over })
const qItem = (id, over = {}) => ({ id, media: qMedia(), episode: 5, key: `21:${id}`, title: 'One Piece', cover: '', addedBy: 'a', addedByName: 'Alice', votes: [], ...over })

test('normalizeQueueEpisode / normalizeQueueItem', () => {
  assert.equal(normalizeQueueEpisode(5), 5)
  assert.equal(normalizeQueueEpisode('7'), 7)
  assert.deepEqual(normalizeQueueEpisode({ number: 13, season: 2, localEpisode: 1, extra: true }), { number: 13, season: 2, localEpisode: 1 })
  assert.equal(normalizeQueueEpisode({ season: 2 }), null)
  assert.equal(normalizeQueueEpisode('x'), null)
  const item = normalizeQueueItem({ ...qItem('q1'), votes: ['b', 'b', 3], title: '  T  ' })
  assert.deepEqual(item.votes, ['b', '3'])
  assert.equal(item.title, 'T')
  assert.equal(normalizeQueueItem({ ...qItem('q1'), media: { title: 'no id' } }), null)
  assert.equal(normalizeQueueItem({ ...qItem('q1'), key: '' }), null)
  assert.equal(normalizeQueueItem({ ...qItem(''), id: '' }), null)
  assert.equal(normalizeQueueItem({ ...qItem('q1'), episode: null }), null)
})

test('normalizeQueue drops duplicate ids and bad items, defaults the policy', () => {
  const queue = normalizeQueue({ items: [qItem('a'), qItem('a'), { id: 'x' }], pending: [qItem('b')], policy: 'weird', rev: 4 })
  assert.deepEqual(queue.items.map(item => item.id), ['a'])
  assert.deepEqual(queue.pending.map(item => item.id), ['b'])
  assert.equal(queue.policy, 'open')
  assert.equal(queue.rev, 4)
  assert.equal(normalizeQueue('nope'), null)
  const many = normalizeQueue({ items: Array.from({ length: QUEUE_MAX_ITEMS + 5 }, (_, index) => qItem(`i${index}`)), policy: 'approval' })
  assert.equal(many.items.length, QUEUE_MAX_ITEMS)
  assert.equal(many.policy, 'approval')
})

test('queueReduce add: open policy, approval policy, host bypass, duplicates', () => {
  let queue = queueReduce(emptyQueue(), { type: 'add', item: qItem('a', { addedBy: 'spoofed' }), by: 'b', byName: 'Bob', byHost: false })
  assert.equal(queue.items.length, 1)
  assert.equal(queue.items[0].addedBy, 'b')
  assert.equal(queue.items[0].addedByName, 'Bob')
  assert.equal(queue.rev, 1)
  // Same key again: ignored.
  assert.equal(queueReduce(queue, { type: 'add', item: qItem('z', { key: '21:a' }), by: 'c', byHost: false }), null)
  queue = queueReduce(queue, { type: 'policy', policy: 'approval' })
  assert.equal(queue.policy, 'approval')
  queue = queueReduce(queue, { type: 'add', item: qItem('b', { episode: 6 }), by: 'c', byHost: false })
  assert.deepEqual(queue.pending.map(item => item.id), ['b'])
  // A suggestion with the same key is a duplicate too.
  assert.equal(queueReduce(queue, { type: 'add', item: qItem('y', { key: '21:b' }), by: 'd', byHost: false }), null)
  queue = queueReduce(queue, { type: 'add', item: qItem('c', { episode: 7 }), by: 'host', byHost: true })
  assert.deepEqual(queue.items.map(item => item.id), ['a', 'c'])
  assert.equal(queueReduce(queue, { type: 'policy', policy: 'approval' }), null)
})

test('queueReduce add respects the limits', () => {
  const full = { ...emptyQueue(), items: Array.from({ length: QUEUE_MAX_ITEMS }, (_, index) => qItem(`i${index}`)) }
  assert.equal(queueReduce(full, { type: 'add', item: qItem('new', { episode: 99 }), by: 'b', byHost: true }), null)
  const fullPending = { ...emptyQueue(), policy: 'approval', pending: Array.from({ length: QUEUE_MAX_PENDING }, (_, index) => qItem(`p${index}`)) }
  assert.equal(queueReduce(fullPending, { type: 'add', item: qItem('new', { episode: 99 }), by: 'b', byHost: false }), null)
})

test('queueReduce vote toggles one vote per member', () => {
  let queue = { ...emptyQueue(), items: [qItem('a')] }
  queue = queueReduce(queue, { type: 'vote', id: 'a', by: 'b', up: true })
  assert.deepEqual(queue.items[0].votes, ['b'])
  assert.equal(queueReduce(queue, { type: 'vote', id: 'a', by: 'b', up: true }), null)
  queue = queueReduce(queue, { type: 'vote', id: 'a', by: 'b', up: false })
  assert.deepEqual(queue.items[0].votes, [])
  assert.equal(queueReduce(queue, { type: 'vote', id: 'missing', by: 'b', up: true }), null)
})

test('queueReduce remove: host or the member who added it', () => {
  const queue = { ...emptyQueue(), items: [qItem('a', { addedBy: 'b' })], pending: [qItem('p', { addedBy: 'c' })] }
  assert.equal(queueReduce(queue, { type: 'remove', id: 'a', by: 'c', byHost: false }), null)
  assert.equal(queueReduce(queue, { type: 'remove', id: 'a', by: 'b', byHost: false }).items.length, 0)
  assert.equal(queueReduce(queue, { type: 'remove', id: 'a', by: 'host', byHost: true }).items.length, 0)
  assert.equal(queueReduce(queue, { type: 'remove', id: 'p', by: 'c', byHost: false }).pending.length, 0)
})

test('queueReduce move clamps, answer accepts to the end or declines', () => {
  let queue = { ...emptyQueue(), items: [qItem('a'), qItem('b'), qItem('c')], pending: [qItem('p'), qItem('q')] }
  assert.deepEqual(queueReduce(queue, { type: 'move', id: 'c', delta: -1 }).items.map(item => item.id), ['a', 'c', 'b'])
  assert.deepEqual(queueReduce(queue, { type: 'move', id: 'a', delta: 10 }).items.map(item => item.id), ['b', 'c', 'a'])
  assert.equal(queueReduce(queue, { type: 'move', id: 'a', delta: -1 }), null)
  queue = queueReduce(queue, { type: 'answer', id: 'p', accepted: true })
  assert.deepEqual(queue.items.map(item => item.id), ['a', 'b', 'c', 'p'])
  assert.deepEqual(queue.pending.map(item => item.id), ['q'])
  queue = queueReduce(queue, { type: 'answer', id: 'q', accepted: false })
  assert.equal(queue.pending.length, 0)
  assert.equal(queue.items.length, 4)
  assert.equal(queueReduce(queue, { type: 'answer', id: 'q', accepted: true }), null)
})

test('queueChanges: added, suggested, declined (not our own cancellations), nothing for the first queue', () => {
  const previous = { ...emptyQueue(), items: [qItem('a')], pending: [qItem('mine', { addedBy: 'me' }), qItem('cancel', { addedBy: 'me' }), qItem('acc', { addedBy: 'me' })] }
  const next = { ...emptyQueue(), items: [qItem('a'), qItem('b'), qItem('acc', { addedBy: 'me' })], pending: [qItem('s')] }
  const changes = queueChanges(previous, next, { selfId: 'me', cancelled: ['cancel'] })
  assert.deepEqual(changes.map(change => `${change.kind}:${change.item.id}`), ['added:b', 'added:acc', 'suggested:s', 'declined:mine'])
  assert.deepEqual(queueChanges(null, next, { selfId: 'me' }), [])
})

test('queue labels and chat lines', () => {
  assert.equal(queueItemLabel(qItem('a')), 'One Piece · Episode 5')
  assert.equal(queueItemLabel(qItem('m', { media: qMedia(5, { format: 'MOVIE', episodes: 1 }), episode: 1, title: 'Your Name' })), 'Your Name · Movie')
  assert.equal(queueItemLabel(qItem('s', { episode: { number: 14, season: 2, localEpisode: 2 } })), 'One Piece · S2 E2')
  assert.equal(describeQueueChange({ kind: 'added', item: qItem('a') }, 'me'), 'Alice added One Piece · Episode 5 to Up next')
  assert.equal(describeQueueChange({ kind: 'added', item: qItem('a', { addedBy: 'me' }) }, 'me'), 'You added One Piece · Episode 5 to Up next')
  assert.equal(describeQueueChange({ kind: 'suggested', item: qItem('a') }, 'me'), 'Alice suggested One Piece · Episode 5')
  assert.equal(describeQueueChange({ kind: 'declined', item: qItem('a') }, 'me'), 'The host declined your suggestion: One Piece · Episode 5')
})

test('nextEpisodeOf / nextEpisodeTarget', () => {
  assert.equal(nextEpisodeOf(5, 12), 6)
  assert.equal(nextEpisodeOf(12, 12), null)
  assert.equal(nextEpisodeOf(12, null), 13)
  assert.deepEqual(nextEpisodeOf({ number: 14, season: 2, localEpisode: 2 }), { number: 15, season: 2, localEpisode: 3 })
  const lobby = { media: qMedia(), episode: 5 }
  assert.deepEqual(nextEpisodeTarget({ lobby, queue: emptyQueue() }).episode, 6)
  const queue = { ...emptyQueue(), items: [qItem('a', { episode: 8 }), qItem('b', { media: qMedia(99), episode: 20 })], pending: [qItem('p', { episode: 7 })] }
  assert.deepEqual(nextEpisodeTarget({ lobby, queue }).episode, 9)
  assert.equal(nextEpisodeTarget({ lobby: { media: qMedia(5, { format: 'MOVIE', episodes: 1 }), episode: 1 }, queue: emptyQueue() }), null)
  assert.equal(nextEpisodeTarget({ lobby: null, queue: emptyQueue() }), null)
})

test('sameQueueEntry: same key, or same media id and episode written differently by each app', () => {
  assert.equal(sameQueueEntry(qItem('a', { key: '21:5' }), qItem('b', { key: '21::5', episode: { number: 5 } })), true)
  assert.equal(sameQueueEntry(qItem('a', { key: 'x' }), qItem('b', { key: 'y', episode: 6 })), false)
  assert.equal(sameQueueEntry(qItem('a', { key: 'x', episode: { number: 14, season: 2, localEpisode: 2 } }), qItem('b', { key: 'y', episode: { number: 14, season: 2, localEpisode: 2 } })), true)
  assert.equal(sameQueueEntry(qItem('a', { key: 'x', episode: { number: 2, season: 1, localEpisode: 2 } }), qItem('b', { key: 'y', episode: { number: 14, season: 2, localEpisode: 2 } })), false)
  assert.equal(sameQueueEntry(qItem('a', { key: 'x' }), qItem('b', { key: 'y', media: qMedia(99) })), false)
  // The host ignores a duplicate added from another app.
  const queue = queueReduce(emptyQueue(), { type: 'add', item: qItem('a', { key: '21:5' }), by: 'b', byHost: false })
  assert.equal(queueReduce(queue, { type: 'add', item: qItem('b', { key: '21::5', episode: { number: 5 } }), by: 'c', byHost: false }), null)
})

test('acceptsQueue: from the host, or anyone without a confirmed host', () => {
  assert.equal(acceptsQueue({ senderId: 'h', hostId: 'h', tentative: false }), true)
  assert.equal(acceptsQueue({ senderId: 'x', hostId: 'h', tentative: false }), false)
  assert.equal(acceptsQueue({ senderId: 'x', hostId: 'h', tentative: true }), true)
  assert.equal(acceptsQueue({ senderId: 'x', hostId: null, tentative: false }), true)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exitCode = 1
