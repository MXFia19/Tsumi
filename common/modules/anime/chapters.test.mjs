// AniSkip chapters. Run with: node common/modules/anime/chapters.test.mjs
import assert from 'node:assert/strict'
import { constructChapters } from './chapters.js'

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

const skip = (skipType, startTime, endTime, episodeLength = 1420) => ({ skipType, interval: { startTime, endTime }, episodeLength })
const simple = (chapters) => chapters.map(({ start, end, text }) => [start, end, text])

test('opening and ending give intro, episode and preview chapters', () => {
  const chapters = constructChapters([skip('op', 90, 180), skip('ed', 1300, 1390)], 1420)
  assert.deepEqual(simple(chapters), [
    [0, 90_000, 'Intro'],
    [90_000, 180_000, 'OP'],
    [180_000, 1_300_000, 'Episode'],
    [1_300_000, 1_390_000, 'ED'],
    [1_390_000, 1_420_000, 'Preview']
  ])
})

test('results come back sorted by start whatever the AniSkip order', () => {
  // AniSkip answers [ED, OP, recap]: sorting objects with a - b left them in that order.
  const chapters = constructChapters([skip('ed', 1300, 1390), skip('op', 90, 180), skip('recap', 0, 60)], 1420)
  assert.deepEqual(simple(chapters), [
    [0, 60_000, 'Recap'],
    [60_000, 90_000, 'Episode'],
    [90_000, 180_000, 'OP'],
    [180_000, 1_300_000, 'Episode'],
    [1_300_000, 1_390_000, 'ED'],
    [1_390_000, 1_420_000, 'Preview']
  ])
  for (let i = 1; i < chapters.length; i++) assert.equal(chapters[i].start, chapters[i - 1].end)
})

test('a recap before the opening starts the episode', () => {
  const chapters = constructChapters([skip('op', 120, 210), skip('recap', 30, 100)], 1420)
  assert.deepEqual(simple(chapters).slice(0, 4), [
    [0, 30_000, 'Episode'],
    [30_000, 100_000, 'Recap'],
    [100_000, 120_000, 'Episode'],
    [120_000, 210_000, 'OP']
  ])
})

test('skip times are shifted by the length difference of the video', () => {
  // Submitted on a 1420 s release, this one is 10 s longer (extra logo at the start).
  const chapters = constructChapters([skip('op', 90, 180, 1420)], 1430)
  assert.deepEqual(simple(chapters).slice(0, 2), [[0, 100_000, 'Intro'], [100_000, 190_000, 'OP']])
})

test('an ending close to the end gets no preview chapter', () => {
  const chapters = constructChapters([skip('op', 0, 90), skip('ed', 1330, 1418)], 1420)
  assert.deepEqual(simple(chapters).at(-1), [1_330_000, 1_418_000, 'ED'])
  assert.equal(chapters[0].text, 'OP')
})

test('overlapping skip times leave no backwards chapter', () => {
  const chapters = constructChapters([skip('recap', 0, 100), skip('op', 90, 180)], 1420)
  for (const chapter of chapters) assert.ok(chapter.end > chapter.start, JSON.stringify(chapter))
})

test('no results or no duration give no chapters', () => {
  assert.deepEqual(constructChapters([], 1420), [])
  assert.deepEqual(constructChapters([skip('op', 90, 180)], 0), [])
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
