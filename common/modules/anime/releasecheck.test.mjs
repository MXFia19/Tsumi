// Release feed check time. Run with: node common/modules/anime/releasecheck.test.mjs
import assert from 'node:assert/strict'
import { releaseCheckTime } from './releasecheck.js'

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

const at = (iso) => Math.floor(new Date(iso).getTime() / 1000)
const now = at('2026-11-17T12:00:00Z')

test('the second after the newest date seen, not the device time', () => {
  const entries = [
    { episode: { airedAt: '2026-11-17T09:00:00Z', addedAt: '2026-11-17T09:20:00Z' } },
    { episode: { airedAt: '2026-11-17T10:00:00Z', addedAt: '2026-11-17T10:05:00Z' } }
  ]
  assert.equal(releaseCheckTime(entries, at('2026-11-17T08:00:00Z'), now), at('2026-11-17T10:05:00Z') + 1)
})

test('an episode listed after the check but added before it is still new at the next check', () => {
  const checked = releaseCheckTime([{ episode: { airedAt: '2026-11-17T10:00:00Z', addedAt: '2026-11-17T10:05:00Z' } }], 100, now)
  const late = at('2026-11-17T11:30:00Z') // added to the feed at 11:30, listed after the 12:00 check
  assert.ok(late >= checked)
})

test('never earlier than the stored time (older versions stored the device time)', () => {
  const stored = at('2026-11-17T11:59:00Z')
  assert.equal(releaseCheckTime([{ episode: { airedAt: '2026-11-17T10:00:00Z', addedAt: '2026-11-17T10:05:00Z' } }], stored, now), stored)
})

test('no dated entry: the stored time, or the device time before the first check', () => {
  assert.equal(releaseCheckTime([], 0, now), now)
  assert.equal(releaseCheckTime(undefined, 1, now), now)
  assert.equal(releaseCheckTime([{ episode: {} }, {}], 500, now), 500)
  assert.equal(releaseCheckTime([{ episode: { airedAt: 'not a date', addedAt: null } }], 0, now), now)
})

test('the first check starts from the newest entry', () => {
  assert.equal(releaseCheckTime([{ episode: { airedAt: '2026-11-17T10:00:00Z' } }], 1, now), at('2026-11-17T10:00:00Z') + 1)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
