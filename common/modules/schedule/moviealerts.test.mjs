// Movie release alerts, pure logic. Run with: node common/modules/schedule/moviealerts.test.mjs
import assert from 'node:assert/strict'
import { movieReleaseDays, canAlert, dueRelease, releaseMessage, upcomingReleases, startOfDay, ALERT_RETENTION_DAYS, STALE_THEATRICAL_DAYS } from './moviealerts.js'

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
  { iso_3166_1: 'US', release_dates: [{ type: 1, release_date: '2026-11-16T00:00:00.000Z' }, { type: 3, release_date: '2026-11-20T00:00:00.000Z' }, { type: 4, release_date: '2027-01-06T00:00:00.000Z' }] }
]
const at = (year, month, day, hour = 12) => new Date(year, month - 1, day, hour).getTime()
const days = { theatrical: '2026-11-18', digital: '2027-01-06' }

test('movieReleaseDays: theatrical in the regions, digital anywhere', () => {
  assert.deepEqual(movieReleaseDays(sunrise, ['FR', 'US']), days)
  assert.deepEqual(movieReleaseDays(sunrise, ['BE', 'FR']), days)
  assert.deepEqual(movieReleaseDays(sunrise, ['DE']), { theatrical: null, digital: '2027-01-06' })
  assert.deepEqual(movieReleaseDays([], ['FR']), { theatrical: null, digital: null })
})

test('movieReleaseDays: the wide release, not a limited one before it', () => {
  const limited = [{ iso_3166_1: 'US', release_dates: [{ type: 2, release_date: '2026-11-07T00:00:00.000Z' }, { type: 3, release_date: '2026-12-04T00:00:00.000Z' }] }]
  assert.deepEqual(movieReleaseDays(limited, ['US']), { theatrical: '2026-12-04', digital: null })
})

test('canAlert until the digital release day', () => {
  assert.equal(canAlert(days, at(2026, 11, 16)), true)
  assert.equal(canAlert(days, at(2027, 1, 6, 23)), true)
  assert.equal(canAlert(days, at(2027, 1, 7)), false)
  assert.equal(canAlert({ theatrical: null, digital: null }, at(2026, 11, 16)), true)
  assert.equal(canAlert(null), true)
})

test('canAlert: no digital day, in theaters for more than STALE_THEATRICAL_DAYS', () => {
  assert.equal(STALE_THEATRICAL_DAYS, 183)
  // Decades-old movie without a digital date on TMDB: no alert.
  assert.equal(canAlert({ theatrical: '2020-01-01', digital: null }, at(2026, 11, 16)), false)
  // 2026-05-17 is 183 days before 2026-11-16 (a DST change in between): still offered, one day more is not.
  assert.equal(canAlert({ theatrical: '2026-05-17', digital: null }, at(2026, 11, 16, 23)), true)
  assert.equal(canAlert({ theatrical: '2026-05-16', digital: null }, at(2026, 11, 16, 0)), false)
  // Upcoming or recent theatrical release, digital unknown: offered.
  assert.equal(canAlert({ theatrical: '2026-11-18', digital: null }, at(2026, 11, 16)), true)
  assert.equal(canAlert({ theatrical: '2026-09-01' }, at(2026, 11, 16)), true)
  // A digital day decides alone, even for an old theatrical release.
  assert.equal(canAlert({ theatrical: '2020-01-01', digital: '2027-01-06' }, at(2026, 11, 16)), true)
})

test('dueRelease: nothing before the theatrical day', () => {
  const alert = { addedAt: at(2026, 11, 16), notified: [] }
  assert.deepEqual(dueRelease(alert, days, at(2026, 11, 17, 23)), { notify: null, day: null, notified: [], done: false })
})

test('dueRelease: theatrical on its day, then digital, then done', () => {
  const alert = { addedAt: at(2026, 11, 16), notified: [] }
  const first = dueRelease(alert, days, at(2026, 11, 18, 0))
  assert.deepEqual(first, { notify: 'theatrical', day: '2026-11-18', notified: ['theatrical'], done: false })
  const again = dueRelease({ ...alert, notified: first.notified }, days, at(2026, 12, 1))
  assert.equal(again.notify, null)
  const digital = dueRelease({ ...alert, notified: first.notified }, days, at(2027, 1, 6, 8))
  assert.deepEqual(digital, { notify: 'digital', day: '2027-01-06', notified: ['theatrical', 'digital'], done: true })
})

test('dueRelease: only the digital release when both are due', () => {
  const alert = { addedAt: at(2026, 11, 16), notified: [] }
  assert.deepEqual(dueRelease(alert, days, at(2027, 2, 1)), { notify: 'digital', day: '2027-01-06', notified: ['theatrical', 'digital'], done: true })
})

test('dueRelease: a release already past when the alert was turned on never notifies', () => {
  const alert = { addedAt: at(2026, 12, 1), notified: [] }
  assert.equal(dueRelease(alert, days, at(2026, 12, 2)).notify, null)
  assert.equal(dueRelease(alert, days, at(2027, 1, 6)).notify, 'digital')
  // Turned on on the release day itself: still notified.
  assert.equal(dueRelease({ addedAt: at(2026, 11, 18, 20), notified: [] }, days, at(2026, 11, 18, 21)).notify, 'theatrical')
  // Already on digital: done at once.
  assert.equal(dueRelease({ addedAt: at(2027, 2, 1), notified: [] }, days, at(2027, 2, 2)).done, true)
})

test('dueRelease: unknown dates wait, old alerts are dropped', () => {
  const alert = { addedAt: at(2026, 11, 16), notified: [] }
  assert.deepEqual(dueRelease(alert, { theatrical: null, digital: null }, at(2026, 12, 1)), { notify: null, day: null, notified: [], done: false })
  assert.equal(dueRelease(alert, {}, at(2026, 11, 16) + (ALERT_RETENTION_DAYS + 1) * 86_400_000).done, true)
  assert.equal(dueRelease({ addedAt: at(2026, 11, 16), notified: ['bogus'] }, {}, at(2026, 11, 17)).notified.length, 0)
})

test('releaseMessage says today or since', () => {
  assert.equal(releaseMessage('theatrical', '2026-11-18', at(2026, 11, 18, 9)), 'Out in theaters today!')
  assert.equal(releaseMessage('theatrical', '2026-11-18', at(2026, 11, 20)), 'In theaters since Nov 18')
  assert.equal(releaseMessage('digital', '2027-01-06', at(2027, 1, 6)), 'Out on digital today!')
  assert.equal(releaseMessage('digital', '2027-01-06', at(2027, 1, 9)), 'On digital since Jan 6')
})

test('upcomingReleases lists the dates still to come', () => {
  assert.equal(upcomingReleases(days, at(2026, 11, 16)), 'In theaters Nov 18 · Digital Jan 6')
  assert.equal(upcomingReleases(days, at(2026, 11, 18, 22)), 'In theaters Nov 18 · Digital Jan 6')
  assert.equal(upcomingReleases(days, at(2026, 12, 1)), 'Digital Jan 6')
  assert.equal(upcomingReleases(days, at(2027, 2, 1)), '')
  assert.equal(upcomingReleases({}, at(2027, 2, 1)), '')
})

test('startOfDay is local midnight', () => {
  assert.equal(startOfDay(at(2026, 11, 18, 23)), new Date(2026, 10, 18).getTime())
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
