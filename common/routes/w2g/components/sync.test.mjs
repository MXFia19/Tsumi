// Watch Together v2 pure logic. Run with: node common/routes/w2g/components/sync.test.mjs
import assert from 'node:assert/strict'
import {
  expectedTime, computeDrift, syncBadge, selfBadge, electHost, autoSyncStep, hostReference,
  normalizeReaction, normalizeCountdownSeconds, normalizeMode, memberName, describeAction, describeRequest,
  formatClock, formatDelta, inferAction, classifyLocalChange, LocalActionTracker, sameId,
  AUTO_SYNC_COOLDOWN_MS, REACTIONS
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

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exitCode = 1
