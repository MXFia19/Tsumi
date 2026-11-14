// Watch Together v2 pure logic. Run with: node common/routes/w2g/components/sync.test.mjs
import assert from 'node:assert/strict'
import {
  expectedTime, computeDrift, syncBadge, selfBadge, electHost, autoSyncStep, hostReference,
  normalizeReaction, normalizeCountdownSeconds, normalizeMode, memberName, describeAction, describeRequest,
  formatClock, formatDelta, inferAction, classifyLocalChange, LocalActionTracker, sameId,
  AUTO_SYNC_COOLDOWN_MS, REACTIONS,
  formatSource, parseMediaKey, formatEpisode, episodeLabelOf, switchLabel, createPresence, presenceOnStatus, presenceOnTick,
  describePresence, canInvite, acceptsInvite, inviteTarget, PRESENCE_DEBOUNCE_MS, LOST_ANNOUNCE_MS,
  normalizeNowPlaying, nowPlayingLabel, episodeLabelFor, pickFollowingHost, electFollowingHost, followBackAction
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

const invitable = (over = {}, member = {}) => ({
  selfWatching: true,
  hasMedia: true,
  effectiveMode: 'everyone',
  isHost: false,
  now: 100_000,
  member: { isSelf: false, protocol: 2, badge: { kind: 'idle' }, status: { state: 'idle' }, receivedAt: 99_000, ...member },
  ...over
})

test('canInvite: idle, other episode or 10 s without signal', () => {
  assert.equal(canInvite(invitable()), true)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'other' }, status: { state: 'playing' } })), true)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'sync' }, status: { state: 'playing' } })), false)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'nosignal' }, status: { state: 'playing' }, receivedAt: 80_000 })), true)
  // Just joined, no status yet: wait 10 s.
  assert.equal(canInvite(invitable({}, { badge: { kind: 'nosignal' }, status: null, joinedAt: 95_000 })), false)
  assert.equal(canInvite(invitable({}, { badge: { kind: 'nosignal' }, status: null, joinedAt: 90_000 })), true)
})

test('canInvite: needs us in the player with a media, a v2 member, and the host role in host mode', () => {
  assert.equal(canInvite(invitable({ selfWatching: false })), false)
  assert.equal(canInvite(invitable({ hasMedia: false })), false)
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
  assert.equal(canInvite(invitable({}, { badge: { kind: 'own' }, status: { state: 'playing', following: false } })), true)
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

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exitCode = 1
