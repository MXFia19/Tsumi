// Year in Review pure statistics. Run with: node common/modules/yearreview/stats.test.mjs
import assert from 'node:assert/strict'
import {
  yearBounds, parseProgress, activityKind, fuzzyToTime, dayKey, formatDay, formatShortDay, hoursValue, formatNumber,
  episodeMinutes, plural, mediaNeedingPrior, priorFromActivities, computeYearStats, computeLocalStats, availableYears, bannerYear
} from './stats.js'

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

/** Local time in epoch seconds. */
const t = (year, month, day, hour = 12, minute = 0) => Math.floor(new Date(year, month - 1, day, hour, minute).getTime() / 1000)
let nextId = 1
const act = (mediaId, status, progress, createdAt) => ({ id: nextId++, mediaId, status, progress, createdAt })

const media = {
  1: { id: 1, title: 'Frieren', format: 'TV', episodes: 28, duration: 24, genres: ['Adventure', 'Drama', 'Fantasy'], studios: ['Madhouse'] },
  2: { id: 2, title: 'Dungeon Meshi', format: 'TV', episodes: 24, duration: 25, genres: ['Adventure', 'Comedy', 'Fantasy'], studios: ['Trigger'] },
  3: { id: 3, title: 'Your Name', format: 'MOVIE', episodes: 1, duration: 107, genres: ['Drama', 'Romance'], studios: ['CoMix Wave'] },
  4: { id: 4, title: 'Bocchi', format: 'TV', episodes: 12, duration: 23, genres: ['Comedy', 'Music'], studios: ['CloverWorks'] },
  5: { id: 5, title: 'Long show', format: 'TV', episodes: 50, duration: null, genres: ['Action'], studios: [] }
}

test('yearBounds covers the local calendar year', () => {
  const { start, end } = yearBounds(2025)
  assert.equal(start, t(2025, 1, 1, 0))
  assert.equal(end, t(2026, 1, 1, 0))
})

test('parseProgress reads single episodes and ranges', () => {
  assert.deepEqual(parseProgress('5'), { from: 5, to: 5 })
  assert.deepEqual(parseProgress('1 - 12'), { from: 1, to: 12 })
  assert.deepEqual(parseProgress('3-4'), { from: 3, to: 4 })
  assert.deepEqual(parseProgress(7), { from: 7, to: 7 })
  assert.equal(parseProgress(null), null)
  assert.equal(parseProgress(''), null)
  assert.equal(parseProgress('abc'), null)
  assert.equal(parseProgress('1 - 999999'), null)
})

test('activityKind maps the AniList ListActivity statuses', () => {
  assert.equal(activityKind('watched episode'), 'watch')
  assert.equal(activityKind('Watched Episode'), 'watch')
  assert.equal(activityKind('rewatched episode'), 'rewatch')
  assert.equal(activityKind('completed'), 'complete')
  assert.equal(activityKind('rewatched'), 'rewatched')
  assert.equal(activityKind('dropped'), 'drop')
  assert.equal(activityKind('paused watching'), 'pause')
  assert.equal(activityKind('plans to watch'), 'plan')
  assert.equal(activityKind('read chapter'), 'other')
  assert.equal(activityKind(undefined), 'other')
})

test('date helpers', () => {
  assert.equal(fuzzyToTime({ year: 2025, month: 3, day: 14 }), t(2025, 3, 14, 12))
  assert.equal(fuzzyToTime({ year: 2025 }), t(2025, 1, 1, 12))
  assert.equal(fuzzyToTime({ year: null }), null)
  assert.equal(dayKey(t(2025, 3, 4, 23, 59)), '2025-03-04')
  assert.equal(formatDay('2025-03-15'), 'Saturday, March 15')
  assert.equal(formatShortDay('2025-12-01'), 'Dec 1')
  assert.equal(hoursValue(90), 1.5)
  assert.equal(hoursValue(60 * 123.4), 123)
  assert.equal(formatNumber(1234567), '1,234,567')
  assert.equal(formatNumber(1.5), '1.5')
  assert.equal(formatNumber(12), '12')
  assert.equal(formatNumber(1234.56), '1,234.6')
  assert.equal(formatNumber(undefined), '0')
  assert.equal(plural(1, 'episode'), '1 episode')
  assert.equal(plural(1200, 'episode'), '1,200 episodes')
  assert.equal(plural(3, 'anime'), '3 anime')
  assert.equal(episodeMinutes({ duration: 0, format: 'MOVIE' }), 90)
  assert.equal(episodeMinutes({ format: 'TV' }), 24)
})

test('watched episode ranges add up, overlaps are counted once', () => {
  const activities = [
    act(1, 'watched episode', '1 - 3', t(2025, 1, 10)),
    act(1, 'watched episode', '4', t(2025, 1, 11)),
    act(1, 'watched episode', '3 - 6', t(2025, 1, 12)) // 3 and 4 already counted
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.episodes, 6)
  assert.equal(stats.minutes, 6 * 24)
  assert.equal(stats.titles, 1)
  assert.equal(stats.started, 1)
  assert.deepEqual(stats.topAnime, [{ mediaId: 1, episodes: 6, minutes: 144 }])
})

test('a completion adds the episodes left after the last progress (last episode is not in an activity)', () => {
  const activities = [
    act(4, 'watched episode', '1 - 11', t(2025, 2, 1)),
    act(4, 'completed', null, t(2025, 2, 2))
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.episodes, 12)
  assert.equal(stats.completed, 1)
  assert.equal(stats.months[1], 12)
})

test('a completion without progress this year uses the prior progress, then the start date', () => {
  const activities = [act(2, 'completed', null, t(2025, 1, 5))]
  // Prior progress known: 20 of 24 watched before the year.
  assert.equal(computeYearStats({ year: 2025, activities, media, entries: [], prior: { 2: 20 } }).episodes, 4)
  // Started before the year, no prior: only the last episode.
  const before = [{ mediaId: 2, status: 'COMPLETED', score: 0, startedAt: { year: 2024, month: 12, day: 1 }, completedAt: { year: 2025, month: 1, day: 5 } }]
  assert.equal(computeYearStats({ year: 2025, activities, media, entries: before }).episodes, 1)
  // Started this year (or no start date): the whole title, and it counts as started.
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.episodes, 24)
  assert.equal(stats.started, 1)
})

test('movies count once with their duration', () => {
  const stats = computeYearStats({ year: 2025, activities: [act(3, 'completed', null, t(2025, 6, 1))], media, entries: [] })
  assert.equal(stats.episodes, 1)
  assert.equal(stats.minutes, 107)
})

test('entries completed this year without a completion activity become a completion', () => {
  const entries = [{ mediaId: 4, status: 'COMPLETED', score: 8, startedAt: { year: 2025, month: 4, day: 1 }, completedAt: { year: 2025, month: 4, day: 3 }, updatedAt: t(2025, 4, 3) }]
  const stats = computeYearStats({ year: 2025, activities: [], media, entries })
  assert.equal(stats.episodes, 12)
  assert.equal(stats.completed, 1)
  assert.equal(stats.months[3], 12)
  assert.equal(stats.averageScore, 8)
  // With watch activities but no completion activity: only the episodes left.
  const withWatch = computeYearStats({ year: 2025, activities: [act(4, 'watched episode', '1 - 11', t(2025, 4, 2))], media, entries })
  assert.equal(withWatch.episodes, 12)
})

test('rewatches are counted in their own cycle', () => {
  const activities = [
    act(4, 'rewatched episode', '1 - 6', t(2025, 5, 1)),
    act(4, 'rewatched episode', '7 - 11', t(2025, 5, 2)),
    act(4, 'rewatched', null, t(2025, 5, 3)),
    act(4, 'rewatched episode', '1 - 2', t(2025, 8, 1)) // second rewatch
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.episodes, 14)
  assert.equal(stats.rewatchEpisodes, 14)
  assert.equal(stats.started, 0)
})

test('started / completed / dropped sets combine activities and list entries', () => {
  const activities = [
    act(1, 'watched episode', '1 - 2', t(2025, 3, 1)),
    act(5, 'watched episode', '10 - 12', t(2025, 3, 2)),
    act(5, 'dropped', null, t(2025, 3, 3)),
    act(2, 'plans to watch', null, t(2025, 3, 4))
  ]
  const entries = [
    { mediaId: 3, status: 'COMPLETED', score: 9.5, completedAt: { year: 2024, month: 12, day: 30 } }, // last year
    { mediaId: 4, status: 'DROPPED', score: 0, startedAt: { year: 2025, month: 2, day: 1 }, updatedAt: t(2025, 2, 2) }
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries })
  assert.equal(stats.started, 2) // 1 (episode 1), 4 (start date)
  assert.equal(stats.completed, 0)
  assert.equal(stats.dropped, 1)
  assert.deepEqual(stats.droppedIds, [5])
  assert.equal(stats.minutes, 2 * 24 + 3 * 24) // long show has no duration: 24 min
})

test('activities outside the year are ignored', () => {
  const activities = [act(1, 'watched episode', '1 - 5', t(2024, 12, 31, 23, 59)), act(1, 'watched episode', '6', t(2026, 1, 1, 0, 1))]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.episodes, 0)
  assert.equal(stats.hasData, false)
  assert.equal(stats.bingeDay, null)
  assert.equal(stats.first, null)
})

test('months, binge day, streak, first and last anime', () => {
  const activities = [
    act(2, 'watched episode', '1', t(2025, 1, 2)),
    act(1, 'watched episode', '1 - 8', t(2025, 3, 14, 10)),
    act(2, 'watched episode', '2 - 3', t(2025, 3, 14, 20)),
    act(2, 'watched episode', '4', t(2025, 3, 15)),
    act(2, 'watched episode', '5', t(2025, 3, 16)),
    act(4, 'watched episode', '1', t(2025, 12, 31, 22))
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.equal(stats.months[0], 1)
  assert.equal(stats.months[2], 12)
  assert.equal(stats.months[11], 1)
  assert.deepEqual(stats.bingeDay.date, '2025-03-14')
  assert.equal(stats.bingeDay.episodes, 10)
  assert.deepEqual(stats.bingeDay.mediaIds, [1, 2])
  assert.equal(stats.bingeDay.minutes, 8 * 24 + 2 * 25)
  assert.deepEqual(stats.longestStreak, { days: 3, start: '2025-03-14', end: '2025-03-16' })
  assert.equal(stats.activeDays, 5)
  assert.equal(stats.first.mediaId, 2)
  assert.equal(stats.last.mediaId, 4)
})

test('binge day ties keep the earliest day', () => {
  const activities = [act(1, 'watched episode', '1 - 2', t(2025, 2, 1)), act(1, 'watched episode', '3 - 4', t(2025, 2, 5))]
  assert.equal(computeYearStats({ year: 2025, activities, media, entries: [] }).bingeDay.date, '2025-02-01')
})

test('top anime, genres and studios are ranked', () => {
  const activities = [
    act(1, 'watched episode', '1 - 10', t(2025, 1, 1)),
    act(2, 'watched episode', '1 - 10', t(2025, 1, 2)),
    act(4, 'watched episode', '1 - 3', t(2025, 1, 3)),
    act(3, 'completed', null, t(2025, 1, 4))
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries: [] })
  assert.deepEqual(stats.topAnime.map(item => item.mediaId), [2, 1, 4, 3]) // same episodes: more minutes first
  assert.deepEqual(stats.genres.slice(0, 3).map(item => item.name), ['Adventure', 'Fantasy', 'Drama']) // Drama: 347 min, Comedy: 319 min
  assert.equal(stats.genres[0].count, 2)
  assert.equal(stats.genres[0].episodes, 20)
  assert.equal(stats.studios[0].name, 'Trigger')
  assert.equal(stats.studios.length, 4)
})

test('average score and top rated use the titles of the year only', () => {
  const activities = [act(1, 'watched episode', '1 - 3', t(2025, 1, 1)), act(2, 'watched episode', '1 - 5', t(2025, 1, 2))]
  const entries = [
    { mediaId: 1, status: 'CURRENT', score: 9 },
    { mediaId: 2, status: 'CURRENT', score: 9 },
    { mediaId: 3, status: 'COMPLETED', score: 4, completedAt: { year: 2020, month: 1, day: 1 } },
    { mediaId: 4, status: 'PLANNING', score: 0 }
  ]
  const stats = computeYearStats({ year: 2025, activities, media, entries })
  assert.equal(stats.averageScore, 9)
  assert.equal(stats.scoredCount, 2)
  assert.deepEqual(stats.topRated, { mediaId: 2, score: 9 }) // tie: more episodes
  assert.equal(computeYearStats({ year: 2025, activities: [], media, entries }).averageScore, null)
})

test('mediaNeedingPrior lists completions without earlier progress this year', () => {
  const activities = [
    act(1, 'watched episode', '1 - 27', t(2025, 1, 1)),
    act(1, 'completed', null, t(2025, 1, 2)),
    act(2, 'completed', null, t(2025, 1, 3)),
    act(3, 'completed', null, t(2025, 1, 4)), // movie
    act(5, 'completed', null, t(2025, 1, 5))
  ]
  const entries = [{ mediaId: 5, status: 'COMPLETED', createdAt: t(2025, 1, 1) }] // added this year
  assert.deepEqual(mediaNeedingPrior({ year: 2025, activities, media, entries }), [2])
})

test('priorFromActivities keeps the newest usable activity per title', () => {
  const prior = priorFromActivities([
    { mediaId: 2, status: 'paused watching', progress: null },
    { mediaId: 2, status: 'watched episode', progress: '15 - 18' },
    { mediaId: 2, status: 'watched episode', progress: '1 - 14' },
    { mediaId: 1, status: 'plans to watch', progress: null },
    { mediaId: 4, status: 'completed', progress: null }
  ], media)
  assert.deepEqual(prior, { 2: 18, 1: 0, 4: 12 })
})

test('computeLocalStats sums local history of the year', () => {
  const ms = (year, month, day) => new Date(year, month - 1, day, 12).getTime()
  const records = [
    { key: 'tmdb-1', episode: 1, currentTime: 2700, duration: 3000, updatedAt: ms(2025, 2, 1) },
    { key: 'tmdb-1', episode: 2, currentTime: 600, duration: 3000, updatedAt: ms(2025, 2, 2) },
    { key: 'tmdb-2', episode: 1, currentTime: 7200, duration: 7000, updatedAt: ms(2025, 5, 1) },
    { key: 'tmdb-3', episode: 1, currentTime: 100, duration: 1000, updatedAt: ms(2024, 5, 1) },
    { key: 'tmdb-4', episode: 1, currentTime: 100, duration: 0, updatedAt: ms(2025, 5, 1) }
  ]
  const stats = computeLocalStats(records, 2025)
  assert.equal(stats.titles, 2)
  assert.equal(stats.episodes, 2)
  assert.equal(stats.minutes, Math.round((2700 + 600 + 7000) / 60))
  assert.deepEqual(stats.top.map(item => item.key), ['tmdb-2', 'tmdb-1'])
  assert.equal(computeLocalStats(records, 2023).hasData, false)
})

test('availableYears offers the current year and the years of the list', () => {
  const now = new Date(2026, 5, 1)
  const entries = [
    { startedAt: { year: 2021 }, completedAt: { year: 2022 } },
    { createdAt: t(2019, 6, 1), updatedAt: 0 },
    { startedAt: { year: 1990 } },
    { completedAt: { year: 2030 } }
  ]
  assert.deepEqual(availableYears(entries, now, [2024]), [2026, 2024, 2022, 2021, 2019])
  assert.deepEqual(availableYears([], now), [2026])
})

test('bannerYear: December shows this year, January last year', () => {
  assert.equal(bannerYear(new Date(2025, 11, 5)), 2025)
  assert.equal(bannerYear(new Date(2026, 0, 20)), 2025)
  assert.equal(bannerYear(new Date(2026, 5, 20)), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
