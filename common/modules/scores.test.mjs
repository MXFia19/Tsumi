// Score conversion. Run with: node common/modules/scores.test.mjs
import assert from 'node:assert/strict'
import { normalizeScore, toAniListRawScore, fromAniListRawScore, toMalScore } from './scores.js'

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

test('normalizeScore keeps the 0-10 scale', () => {
  assert.equal(normalizeScore(8), 8)
  assert.equal(normalizeScore('7.5'), 7.5)
  assert.equal(normalizeScore(0), 0)
  assert.equal(normalizeScore(null), 0)
  assert.equal(normalizeScore(undefined), 0)
  assert.equal(normalizeScore(NaN), 0)
  assert.equal(normalizeScore(-3), 0)
  assert.equal(normalizeScore(80), 10)
})

test('toAniListRawScore turns a 0-10 score into scoreRaw (0-100)', () => {
  assert.equal(toAniListRawScore(8), 80)
  assert.equal(toAniListRawScore(7.5), 75)
  assert.equal(toAniListRawScore(0), 0)
  assert.equal(toAniListRawScore(undefined), 0)
  assert.equal(toAniListRawScore(10), 100)
})

test('a score of the wrong scale never goes past 100 (was 80 * 10 = 800)', () => {
  assert.equal(toAniListRawScore(80), 100)
})

test('fromAniListRawScore is the inverse of toAniListRawScore', () => {
  for (const score of [0, 1, 5, 7.5, 8, 10]) assert.equal(fromAniListRawScore(toAniListRawScore(score)), score)
  assert.equal(fromAniListRawScore(85), 8.5)
  assert.equal(fromAniListRawScore(null), 0)
  assert.equal(fromAniListRawScore(250), 10)
})

test('toMalScore is an integer 0-10', () => {
  assert.equal(toMalScore(8), 8)
  assert.equal(toMalScore(7.5), 8)
  assert.equal(toMalScore(7.4), 7)
  assert.equal(toMalScore(null), 0)
  assert.equal(toMalScore(12), 10)
})

test('a progress update round-trips the cached score unchanged', () => {
  // Cached AniList entries are POINT_10 (score(format: POINT_10)); a progress update must not change the score.
  const cached = 9
  assert.equal(fromAniListRawScore(toAniListRawScore(cached)), cached)
  assert.equal(toMalScore(cached), cached)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
