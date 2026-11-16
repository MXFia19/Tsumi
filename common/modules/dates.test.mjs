// Date-only parser. Run with: node common/modules/dates.test.mjs
// Runs west of UTC, where new Date('YYYY-MM-DD') (UTC midnight) is the previous local day.
import assert from 'node:assert/strict'
process.env.TZ = 'America/New_York'
const { parseDateOnly, toLocalDate, fuzzyDateString, localFuzzyDate, dateOnlyValue, localDateTimeString } = await import('./dates.js')

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

test('the time zone of the test is west of UTC (new Date(date-only) is the day before)', () => {
  assert.equal(new Date('2024-05-10').getDate(), 9)
})

test('parseDateOnly reads MyAnimeList / TMDB dates as written', () => {
  assert.deepEqual(parseDateOnly('2024-05-10'), { year: 2024, month: 5, day: 10 })
  assert.deepEqual(parseDateOnly('2024-01-01'), { year: 2024, month: 1, day: 1 })
  assert.deepEqual(parseDateOnly(' 2024-12-31 '), { year: 2024, month: 12, day: 31 })
})

test('parseDateOnly keeps the calendar day of Jikan timestamps', () => {
  assert.deepEqual(parseDateOnly('2023-09-29T00:00:00+00:00'), { year: 2023, month: 9, day: 29 })
  assert.deepEqual(parseDateOnly('2024-05-10 23:59:59'), { year: 2024, month: 5, day: 10 })
})

test('parseDateOnly keeps partial MyAnimeList dates partial', () => {
  assert.deepEqual(parseDateOnly('2017-03'), { year: 2017, month: 3, day: null })
  assert.deepEqual(parseDateOnly('2017'), { year: 2017, month: null, day: null })
})

test('parseDateOnly rejects what is not a date', () => {
  for (const value of [null, undefined, '', 'soon', '2024-13-01', '2024-02-30', '2023-02-29', '2024-00-10', '20240510', '2024-05-10x', 'Sep 29, 2023']) {
    assert.equal(parseDateOnly(value), null, String(value))
  }
  assert.deepEqual(parseDateOnly('2024-02-29'), { year: 2024, month: 2, day: 29 })
})

test('parseDateOnly reads a Date in local time', () => {
  assert.deepEqual(parseDateOnly(new Date(2024, 4, 10, 23, 30)), { year: 2024, month: 5, day: 10 })
  assert.equal(parseDateOnly(new Date('nope')), null)
})

test('toLocalDate is local midnight of the same day', () => {
  const date = toLocalDate('2024-05-10')
  assert.equal(date.getFullYear(), 2024)
  assert.equal(date.getMonth(), 4)
  assert.equal(date.getDate(), 10)
  assert.equal(date.getHours(), 0)
  assert.equal(toLocalDate('2017-03').getDate(), 1)
  assert.equal(toLocalDate('bad'), null)
  assert.equal(toLocalDate(null), null)
})

test('fuzzyDateString writes complete dates only', () => {
  assert.equal(fuzzyDateString({ year: 2024, month: 5, day: 9 }), '2024-05-09')
  assert.equal(fuzzyDateString({ year: 2024, month: 5, day: null }), null)
  assert.equal(fuzzyDateString(undefined), null)
})

test('a MyAnimeList date round-trips unchanged', () => {
  const parsed = parseDateOnly('2024-05-10')
  assert.equal(fuzzyDateString(parsed), '2024-05-10')
})

test('localDateTimeString keeps the day of Jikan and Kitsu air dates', () => {
  assert.equal(localDateTimeString('2023-09-29T00:00:00+00:00'), '2023-09-29T00:00:00')
  assert.equal(localDateTimeString('2016-04-03'), '2016-04-03T00:00:00')
  assert.equal(new Date(localDateTimeString('2023-09-29T00:00:00+00:00')).getDate(), 29)
  assert.equal(new Date('2023-09-29T00:00:00+00:00').getDate(), 28) // what it was
  assert.equal(localDateTimeString(null), null)
  assert.equal(localDateTimeString(undefined), null)
  assert.equal(localDateTimeString('2017-03'), '2017-03')
  assert.equal(localDateTimeString('soon'), 'soon')
})

test('localFuzzyDate is the local day', () => {
  assert.deepEqual(localFuzzyDate(new Date(2024, 0, 31, 23, 59)), { year: 2024, month: 1, day: 31 })
})

test('dateOnlyValue sorts dates, missing ones last', () => {
  assert.equal(dateOnlyValue('2024-05-10'), 20240510)
  assert.equal(dateOnlyValue({ year: 2024, month: 5, day: 10 }), 20240510)
  assert.equal(dateOnlyValue('2017-03'), 20170300)
  assert.equal(dateOnlyValue(null), 0)
  assert.equal(dateOnlyValue('nope'), 0)
  const sorted = ['2023-01-02', null, '2024-05-10', '2023-12-31'].sort((a, b) => dateOnlyValue(b) - dateOnlyValue(a))
  assert.deepEqual(sorted, ['2024-05-10', '2023-12-31', '2023-01-02', null])
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
