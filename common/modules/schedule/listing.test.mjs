// Schedule page entries, pure logic. Run with: node common/modules/schedule/listing.test.mjs
import assert from 'node:assert/strict'
import { scheduleKey, schedulePageEntries, compareTimes } from './listing.js'

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

const anime = (id, at) => ({ id, format: 'TV', at })
const show = (id, at) => ({ id: `tmdb-${id}`, format: 'TV', at })
const movie = (id, at) => ({ id: `tmdb-${id}`, format: 'MOVIE', at })
const time = (media) => media.at ?? null
const ids = (list) => list.map(media => media.id)

test('scheduleKey keeps TMDB shows and movies apart', () => {
  assert.equal(scheduleKey(show(5, 1)), 'TV:tmdb-5')
  assert.equal(scheduleKey(movie(5, 1)), 'MOVIE:tmdb-5')
  assert.notEqual(scheduleKey(show(5, 1)), scheduleKey(movie(5, 1)))
})

test('one page: sorted by time, duplicates and entries with nothing to come left out', () => {
  const page = [movie(1, 300), anime(10, 100), show(2, 200), movie(1, 300), movie(3, null), null]
  assert.deepEqual(ids(schedulePageEntries(page, { time })), [10, 'tmdb-2', 'tmdb-1'])
})

test('later pages of the same load skip what an earlier page listed', () => {
  const seen = new Set()
  const first = schedulePageEntries([movie(1, 500), movie(2, 900), show(3, 100)], { time, seen })
  assert.deepEqual(ids(first), ['tmdb-3', 'tmdb-1', 'tmdb-2'])
  // Page 2 of another discover query lists movie 2 again, and an earlier movie 4.
  const second = schedulePageEntries([movie(2, 900), movie(4, 200), show(3, 100), show(5, 50)], { time, seen })
  assert.deepEqual(ids(second), ['tmdb-5', 'tmdb-4'])
  // An entry with nothing to come does not block a later copy that has a date.
  const third = schedulePageEntries([movie(6, null)], { time, seen })
  assert.deepEqual(ids(third), [])
  assert.deepEqual(ids(schedulePageEntries([movie(6, 700)], { time, seen })), ['tmdb-6'])
})

test('excluded formats also hide the TMDB shows and movies', () => {
  const page = [anime(10, 100), show(2, 200), movie(1, 300)]
  assert.deepEqual(ids(schedulePageEntries(page, { time, formatNot: ['MOVIE'] })), [10, 'tmdb-2'])
  assert.deepEqual(ids(schedulePageEntries(page, { time, formatNot: ['TV'] })), ['tmdb-1'])
  assert.deepEqual(ids(schedulePageEntries(page, { time, formatNot: ['TV', 'MOVIE'] })), [])
  // An excluded entry is not marked as listed.
  const seen = new Set()
  schedulePageEntries(page, { time, seen, formatNot: ['MOVIE'] })
  assert.equal(seen.has('MOVIE:tmdb-1'), false)
  assert.deepEqual(ids(schedulePageEntries(page, { time, formatNot: undefined })), [10, 'tmdb-2', 'tmdb-1'])
})

test('compareTimes puts missing or invalid times last', () => {
  assert.equal(compareTimes(1, 2), -1)
  assert.equal(compareTimes(2, 1), 1)
  assert.equal(compareTimes(2, 2), 0)
  assert.equal(compareTimes(1, Infinity), -1)
  assert.equal(compareTimes(NaN, 1), 1)
  assert.equal(compareTimes(undefined, 1), 1)
  assert.equal(compareTimes(null, undefined), 0)
  assert.deepEqual([undefined, 3, NaN, 1, Infinity, 2].sort(compareTimes).slice(0, 3), [1, 2, 3])
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
