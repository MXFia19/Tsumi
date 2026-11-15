// Hold to speed up. Run with: node common/modules/holdspeed.test.mjs
import assert from 'node:assert/strict'
import { HoldSpeed, holdSpeedOf, holdSpeedLabel } from './holdspeed.js'

let passed = 0
let failed = 0
async function test (name, fn) {
  try {
    await fn()
    passed++
    console.log(`ok - ${name}`)
  } catch (error) {
    failed++
    console.error(`FAIL - ${name}\n${error?.stack || error}`)
  }
}

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const DELAY = 20

function fakePlayer (overrides = {}) {
  const player = {
    rate: 1,
    paused: false,
    can: true,
    isBlocked: false,
    blockedCount: 0,
    shown: [],
    canHold: () => player.can,
    blocked: () => player.isBlocked,
    speed: () => 2,
    getRate: () => player.rate,
    setRate: rate => { player.rate = rate },
    isPaused: () => player.paused,
    setPaused: value => { player.paused = value },
    onChange: speed => { player.shown.push(speed) },
    onBlocked: () => { player.blockedCount++ },
    ...overrides
  }
  return player
}

await test('holdSpeedOf keeps the offered speeds and falls back to 2', () => {
  assert.equal(holdSpeedOf(1.5), 1.5)
  assert.equal(holdSpeedOf('3'), 3)
  assert.equal(holdSpeedOf(2), 2)
  assert.equal(holdSpeedOf(7), 2)
  assert.equal(holdSpeedOf(undefined), 2)
  assert.equal(holdSpeedLabel(2), '2×')
  assert.equal(holdSpeedLabel(1.5), '1.5×')
})

await test('a short press is a tap and never changes the rate', async () => {
  const player = fakePlayer()
  const hold = new HoldSpeed(player)
  assert.equal(hold.press('key:Space', DELAY), true)
  assert.equal(hold.release('key:Space'), 'tap')
  await wait(DELAY * 2)
  assert.equal(player.rate, 1)
  assert.deepEqual(player.shown, [])
  assert.equal(hold.active, false)
})

await test('holding plays faster and the release restores the previous rate', async () => {
  const player = fakePlayer({ rate: 1.2 })
  const hold = new HoldSpeed(player)
  hold.press('pointer', DELAY)
  await wait(DELAY * 2)
  assert.equal(hold.active, true)
  assert.equal(player.rate, 2)
  assert.equal(hold.release('pointer'), 'hold')
  assert.equal(player.rate, 1.2)
  assert.deepEqual(player.shown, [2, null])
  assert.equal(player.paused, false)
})

await test('holding while paused plays, the release pauses again', async () => {
  const player = fakePlayer({ paused: true })
  const hold = new HoldSpeed(player)
  hold.press('key:Space', DELAY)
  await wait(DELAY * 2)
  assert.equal(player.paused, false)
  assert.equal(hold.release('key:Space'), 'hold')
  assert.equal(player.paused, true)
  assert.equal(player.rate, 1)
})

await test('another source does not release, a second press is refused', async () => {
  const player = fakePlayer()
  const hold = new HoldSpeed(player)
  assert.equal(hold.press('pointer', DELAY), true)
  assert.equal(hold.press('key:Space', DELAY), false)
  assert.equal(hold.release('key:Space'), null)
  assert.equal(hold.release('pointer'), 'tap')
  assert.equal(hold.release('pointer'), null)
})

await test('not possible (setting off, no video): press returns false', () => {
  const player = fakePlayer({ can: false })
  const hold = new HoldSpeed(player)
  assert.equal(hold.press('key:Space', DELAY), false)
  assert.equal(hold.source, null)
})

await test('in a synced lobby the hold is refused once, the release does nothing', async () => {
  const player = fakePlayer({ isBlocked: true })
  const hold = new HoldSpeed(player)
  hold.press('key:Space', DELAY)
  await wait(DELAY * 2)
  assert.equal(player.blockedCount, 1)
  assert.equal(player.rate, 1)
  assert.equal(hold.release('key:Space'), 'hold')
  assert.equal(player.rate, 1)
  assert.deepEqual(player.shown, [])
})

await test('a rate chosen while held is kept', async () => {
  const player = fakePlayer()
  const hold = new HoldSpeed(player)
  hold.press('key:Space', DELAY)
  await wait(DELAY * 2)
  player.rate = 1.1
  hold.release('key:Space')
  assert.equal(player.rate, 1.1)
})

await test('cancel ends the hold without a tap, interrupt keeps the pause', async () => {
  const player = fakePlayer({ paused: true })
  const hold = new HoldSpeed(player)
  hold.press('key:Space', DELAY)
  await wait(DELAY * 2)
  hold.cancel()
  assert.equal(player.rate, 1)
  assert.equal(player.paused, true)
  assert.equal(hold.release('key:Space'), null)

  const other = fakePlayer()
  const hold2 = new HoldSpeed(other)
  hold2.press('pointer', DELAY)
  await wait(DELAY * 2)
  other.paused = true
  hold2.interrupt()
  assert.equal(other.rate, 1)
  assert.equal(hold2.active, false)
  assert.equal(hold2.release('pointer'), 'hold')
  assert.equal(other.paused, true)

  const pending = fakePlayer()
  const hold3 = new HoldSpeed(pending)
  hold3.press('pointer', DELAY)
  hold3.cancel()
  await wait(DELAY * 2)
  assert.equal(pending.rate, 1)
  assert.equal(hold3.active, false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
