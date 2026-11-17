// List update queue rules. Run with: node common/modules/sync/pendingupdates.test.mjs
import assert from 'node:assert/strict'
import { MAX_ATTEMPTS, accountKey, profileAccount, keptUpdates, sameUpdate, withUpdate, accountUpdates, sendOutcome, isOutage } from './pendingupdates.js'

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

const aniProfile = { token: 'a', viewer: { data: { Viewer: { id: 7, name: 'A', avatar: { large: 'a.png' } } } } }
const malProfile = { token: 'm', viewer: { data: { Viewer: { id: 7, name: 'M', picture: 'm.png' } } } }

test('accountKey / profileAccount: service and viewer id (the two services can share an id)', () => {
  assert.equal(accountKey('anilist', 7), 'anilist:7')
  assert.equal(accountKey('mal', '7'), 'mal:7')
  assert.equal(accountKey('anilist', undefined), null)
  assert.equal(accountKey('anilist', ''), null)
  assert.equal(profileAccount(aniProfile), 'anilist:7')
  assert.equal(profileAccount(malProfile), 'mal:7')
  assert.equal(profileAccount({ viewer: { data: { Viewer: { error: 'invalid_token' } } } }), null)
  assert.equal(profileAccount(null), null)
})

test('keptUpdates keeps the signed-in accounts, drops logged-out ones and invalid entries', () => {
  const stored = [
    { account: 'anilist:7', mediaId: 1, episode: 2, at: 1 },
    { account: 'mal:9', mediaId: 2, episode: 1, at: 2 },
    { account: 'anilist:3', mediaId: 3, episode: 1, at: 3 }, // logged out
    null,
    { account: 'anilist:7', episode: 1, at: 4 } // no media
  ]
  assert.deepEqual(keptUpdates(stored, 'anilist:7', ['anilist:7', 'mal:9']), [stored[0], stored[1]])
  assert.deepEqual(keptUpdates(stored, null, []), [])
  assert.deepEqual(keptUpdates(null, 'anilist:7', ['anilist:7']), [])
  assert.deepEqual(keptUpdates({}, 'anilist:7', ['anilist:7']), [])
})

test('keptUpdates gives entries of older versions (no account) to the current account', () => {
  const legacy = { mediaId: 5, episode: 3, at: 10, attempts: 2 }
  assert.deepEqual(keptUpdates([legacy], 'mal:9', ['mal:9']), [{ ...legacy, account: 'mal:9' }])
  assert.deepEqual(keptUpdates([legacy], null, [null, 'mal:9']), []) // signed out: nobody to send them to
})

test('withUpdate replaces older updates of the same media and account only', () => {
  const queue = [
    { account: 'anilist:7', mediaId: 1, episode: 2, at: 1 },
    { account: 'anilist:7', mediaId: 1, episode: 5, at: 2 },
    { account: 'mal:7', mediaId: 1, episode: 1, at: 3 },
    { account: 'anilist:7', mediaId: 2, episode: 1, at: 4 }
  ]
  const update = { account: 'anilist:7', mediaId: 1, episode: 3, at: 5 }
  assert.deepEqual(withUpdate(queue, update), [queue[1], queue[2], queue[3], update])
  assert.deepEqual(withUpdate([], update), [update])
})

test('accountUpdates: the account\'s updates, oldest first', () => {
  const queue = [
    { account: 'anilist:7', mediaId: 1, at: 30 },
    { account: 'mal:9', mediaId: 2, at: 10 },
    { account: 'anilist:7', mediaId: 3, at: 20 }
  ]
  assert.deepEqual(accountUpdates(queue, 'anilist:7').map(entry => entry.mediaId), [3, 1])
  assert.deepEqual(accountUpdates(queue, null), [])
  assert.equal(queue[0].mediaId, 1) // not sorted in place
})

test('sameUpdate compares account, media, episode and time', () => {
  const entry = { account: 'anilist:7', mediaId: 1, episode: 2, at: 1 }
  assert.equal(sameUpdate(entry, { ...entry, attempts: 3 }), true)
  assert.equal(sameUpdate(entry, { ...entry, account: 'mal:7' }), false)
  assert.equal(sameUpdate(entry, { ...entry, at: 2 }), false)
})

test('sendOutcome: done, counted retries, then dropped', () => {
  assert.deepEqual(sendOutcome({ attempts: 3 }, { status: 'updated' }), { action: 'done', attempts: 3 })
  assert.deepEqual(sendOutcome({}, { status: 'skipped', reason: 'not an AniList media' }), { action: 'done', attempts: 0 })
  assert.deepEqual(sendOutcome({}, { status: 'unchanged' }), { action: 'done', attempts: 0 })
  assert.deepEqual(sendOutcome({}, { status: 'failed' }), { action: 'retry', attempts: 1 })
  assert.deepEqual(sendOutcome({ attempts: 4 }, { status: 'deferred' }), { action: 'retry', attempts: 5 })
  assert.deepEqual(sendOutcome({ attempts: MAX_ATTEMPTS - 1 }, { status: 'failed' }), { action: 'drop', attempts: MAX_ATTEMPTS })
  assert.deepEqual(sendOutcome({ attempts: 4 }, { status: 'failed' }, { maxAttempts: 5 }), { action: 'drop', attempts: 5 })
  assert.deepEqual(sendOutcome({}, undefined), { action: 'done', attempts: 0 })
})

test('sendOutcome: failures during an outage are not counted', () => {
  assert.deepEqual(sendOutcome({ attempts: MAX_ATTEMPTS - 1 }, { status: 'failed' }, { outage: true }), { action: 'retry', attempts: MAX_ATTEMPTS - 1 })
  assert.deepEqual(sendOutcome({ attempts: 2 }, { status: 'updated' }, { outage: true }), { action: 'done', attempts: 2 })
})

test('isOutage: no network and AniList down', () => {
  assert.equal(isOutage('offline'), true)
  assert.equal(isOutage('offline_anilist'), true)
  assert.equal(isOutage('online'), false)
  assert.equal(isOutage(undefined), false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
