// Upcoming movies of the schedule, pure logic. Run with: node common/modules/schedule/movies.test.mjs
import assert from 'node:assert/strict'
import { releaseKinds, localeRegion, releaseRegions, releaseDate, releaseDay, movieReleaseNodes, THEATRICAL_TYPES, DIGITAL_TYPES } from './movies.js'

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

// The Hunger Games: Sunrise on the Reaping (TMDB 1300968), as listed in November 2026.
const sunrise = [
  { iso_3166_1: 'FR', release_dates: [{ type: 3, release_date: '2026-11-18T00:00:00.000Z' }] },
  { iso_3166_1: 'GB', release_dates: [{ type: 1, release_date: '2026-10-28T00:00:00.000Z' }, { type: 3, release_date: '2026-11-18T00:00:00.000Z' }] },
  { iso_3166_1: 'US', release_dates: [{ type: 1, release_date: '2026-11-16T00:00:00.000Z' }, { type: 3, release_date: '2026-11-20T00:00:00.000Z' }, { type: 4, release_date: '2027-01-06T00:00:00.000Z' }] }
]
const now = new Date(2026, 10, 16, 18, 0).getTime() // 16 Nov 2026, 18:00 local

test('releaseKinds maps the Release filter', () => {
  assert.deepEqual(releaseKinds(''), { episodes: true, theatrical: true, digital: true })
  assert.deepEqual(releaseKinds(undefined), { episodes: true, theatrical: true, digital: true })
  assert.deepEqual(releaseKinds('episodes'), { episodes: true, theatrical: false, digital: false })
  assert.deepEqual(releaseKinds('movies'), { episodes: false, theatrical: true, digital: true })
  assert.deepEqual(releaseKinds('theatrical'), { episodes: false, theatrical: true, digital: false })
  assert.deepEqual(releaseKinds('digital'), { episodes: false, theatrical: false, digital: true })
})

test('localeRegion reads the country of a locale', () => {
  assert.equal(localeRegion('fr-FR'), 'FR')
  assert.equal(localeRegion('en_us'), 'US')
  assert.equal(localeRegion('zh-Hans-CN'), 'CN')
  assert.equal(localeRegion('en'), null)
  assert.equal(localeRegion(''), null)
  assert.equal(localeRegion(undefined), null)
})

test('releaseRegions orders the named country, the main country of the language, then the US', () => {
  assert.deepEqual(releaseRegions(['fr', 'fr-BE', 'en-US']), ['BE', 'FR', 'US'])
  assert.deepEqual(releaseRegions(['fr-FR']), ['FR', 'US'])
  assert.deepEqual(releaseRegions(['en-GB']), ['GB', 'US'])
  assert.deepEqual(releaseRegions(['de-AT', 'de']), ['AT', 'DE', 'US'])
  assert.deepEqual(releaseRegions(['fr']), ['FR', 'US'])
  assert.deepEqual(releaseRegions(['xx']), ['US'])
  assert.deepEqual(releaseRegions(undefined), ['US'])
})

test('releaseDate prefers the region, then the US, then anywhere when allowed', () => {
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, 'FR'), '2026-11-18')
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, 'US'), '2026-11-20')
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, 'DE'), '2026-11-20')
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, null), '2026-11-20')
  assert.equal(releaseDate(sunrise, DIGITAL_TYPES, 'FR'), '2027-01-06')
  const onlyJapan = [{ iso_3166_1: 'JP', release_dates: [{ type: 4, release_date: '2026-12-01T00:00:00.000Z' }, { type: 3, release_date: '2026-11-01T00:00:00.000Z' }] }]
  assert.equal(releaseDate(onlyJapan, DIGITAL_TYPES, 'FR'), null)
  assert.equal(releaseDate(onlyJapan, DIGITAL_TYPES, 'FR', true), '2026-12-01')
  assert.equal(releaseDate(onlyJapan, THEATRICAL_TYPES, 'JP'), '2026-11-01')
  assert.equal(releaseDate(null, DIGITAL_TYPES, 'FR', true), null)
  // Region lists: Belgium has no dates for this movie, France does.
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, ['BE', 'FR', 'US']), '2026-11-18')
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, ['BE', 'US']), '2026-11-20')
  assert.equal(releaseDate(sunrise, THEATRICAL_TYPES, ['BE']), null)
  assert.equal(releaseDate([{ iso_3166_1: 'US', release_dates: [{ type: 3, release_date: 'soon' }] }], THEATRICAL_TYPES, 'US'), null)
})

test('releaseDay is local midnight', () => {
  const day = releaseDay('2026-11-18T00:00:00.000Z')
  assert.equal(day.getFullYear(), 2026)
  assert.equal(day.getMonth(), 10)
  assert.equal(day.getDate(), 18)
  assert.equal(day.getHours(), 0)
})

test('movieReleaseNodes lists the theatrical and digital releases to come', () => {
  const nodes = movieReleaseNodes(sunrise, { regions: ['FR', 'US'], now })
  assert.deepEqual(nodes.map(n => [n.release, n.label, n.episode]), [['theatrical', 'In theaters', 1], ['digital', 'On digital', 1]])
  assert.equal(nodes[0].airingAt, Math.floor(new Date(2026, 10, 18).getTime() / 1000))
  assert.equal(nodes[1].airingAt, Math.floor(new Date(2027, 0, 6).getTime() / 1000))
})

test('movieReleaseNodes follows the filter and the window', () => {
  assert.deepEqual(movieReleaseNodes(sunrise, { regions: ['FR', 'US'], now, digital: false }).map(n => n.release), ['theatrical'])
  assert.deepEqual(movieReleaseNodes(sunrise, { regions: ['FR', 'US'], now, theatrical: false }).map(n => n.release), ['digital'])
  // Digital release 51 days away: outside a 30 day window.
  assert.deepEqual(movieReleaseNodes(sunrise, { regions: ['FR', 'US'], now, days: 30 }).map(n => n.release), ['theatrical'])
  // Once in theaters, only the digital release is left.
  const later = new Date(2026, 10, 25).getTime()
  assert.deepEqual(movieReleaseNodes(sunrise, { regions: ['FR', 'US'], now: later }).map(n => n.release), ['digital'])
  assert.deepEqual(movieReleaseNodes([], { regions: ['FR', 'US'], now }), [])
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
