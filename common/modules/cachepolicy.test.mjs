// Cache and retry policy. Run with: node common/modules/cachepolicy.test.mjs
import assert from 'node:assert/strict'
import { HOUR, DAY, WEEK, MINUTE, SECOND, TTL, jitter, expiresIn, mappingTtl, tmdbDetailsTtl, tmdbSeasonTtl, staleKeys, staleMappingKeys, retryAfterMs, retryDelay, STALE_GRACE } from './cachepolicy.js'

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

const now = new Date(2026, 10, 16, 12, 0).getTime() // 16 Nov 2026, 12:00 local
const headers = (value) => ({ get: (name) => name.toLowerCase() === 'retry-after' ? value : null })

test('jitter and expiresIn stay inside the range', () => {
  assert.equal(jitter(10, 20, () => 0), 10)
  assert.equal(jitter(10, 20, () => 1), 20)
  assert.equal(jitter(10, undefined, () => 0.5), 10)
  assert.equal(expiresIn(TTL.anilistUserLists, now, () => 0.3), now + 14 * MINUTE)
  const expiry = expiresIn(TTL.anilistSearch, now)
  assert.ok(expiry >= now + 75 * MINUTE && expiry <= now + 100 * MINUTE)
})

test('mappings: minutes while airing, weeks once finished', () => {
  assert.ok(mappingTtl({ status: 'RELEASING' }, now) <= 90 * MINUTE)
  assert.ok(mappingTtl({ status: 'FINISHED', endDate: { year: 2026, month: 11 } }, now) <= 90 * MINUTE)
  assert.ok(mappingTtl({ status: 'FINISHED', endDate: { year: 2026, month: 9 } }, now) >= 14 * DAY)
  assert.ok(mappingTtl({ status: 'FINISHED', endDate: { year: null }, seasonYear: 2020 }, now) >= 14 * DAY)
  assert.ok(mappingTtl(null, now) <= 90 * MINUTE)
})

test('TMDB details: hours while a show airs, weeks once it ended', () => {
  assert.equal(tmdbDetailsTtl(null, now), 0)
  assert.equal(tmdbDetailsTtl({ mediaType: 'tv', status: 'FINISHED' }, now), 3 * WEEK)
  assert.equal(tmdbDetailsTtl({ mediaType: 'tv', status: 'RELEASING' }, now), 12 * HOUR)
  assert.equal(tmdbDetailsTtl({ mediaType: 'tv', status: 'RELEASING', next_episode_to_air: { air_date: '2026-11-17' } }, now), 3 * HOUR)
  assert.equal(tmdbDetailsTtl({ mediaType: 'tv', status: 'RELEASING', next_episode_to_air: { air_date: '2026-12-20' } }, now), 12 * HOUR)
  assert.equal(tmdbDetailsTtl({ mediaType: 'tv', status: 'NOT_YET_RELEASED' }, now), DAY)
})

test('TMDB movie details: a day around the release, weeks once it has been out', () => {
  assert.equal(tmdbDetailsTtl({ mediaType: 'movie', releaseDate: new Date(2026, 10, 20) }, now), DAY)
  assert.equal(tmdbDetailsTtl({ mediaType: 'movie', releaseDate: new Date(2026, 9, 1) }, now), DAY)
  assert.equal(tmdbDetailsTtl({ mediaType: 'movie', releaseDate: '2024-01-12' }, now), 3 * WEEK)
  assert.equal(tmdbDetailsTtl({ mediaType: 'movie' }, now), DAY)
})

test('TMDB seasons: hours while episodes are recent or upcoming, weeks after', () => {
  assert.equal(tmdbSeasonTtl([], now), 6 * HOUR)
  assert.equal(tmdbSeasonTtl([{ airdate: new Date(2024, 0, 1) }, { airdate: new Date(2024, 0, 8) }], now), 3 * WEEK)
  assert.equal(tmdbSeasonTtl([{ airdate: new Date(2026, 10, 10) }], now), 6 * HOUR)
  assert.equal(tmdbSeasonTtl([{ airdate: new Date(2024, 0, 1) }, { airdate: null }], now), 6 * HOUR)
  assert.equal(tmdbSeasonTtl([{ airdate: '2026-12-01' }], now), 6 * HOUR)
})

test('staleKeys drops entries expired past the grace period, keeps recent stale ones', () => {
  const entries = {
    fresh: { data: 1, expiry: now + HOUR, cachedAt: now },
    staleRecent: { data: 1, expiry: now - DAY, cachedAt: now - 2 * DAY },
    staleOld: { data: 1, expiry: now - STALE_GRACE - DAY, cachedAt: now - 30 * DAY },
    empty: null,
    noExpiry: { data: 1 }
  }
  assert.deepEqual(staleKeys(entries, { now }).sort(), ['empty', 'staleOld'])
})

test('staleKeys evicts the oldest entries above the limit', () => {
  const entries = {}
  for (let i = 0; i < 10; i++) entries[`k${i}`] = { data: i, expiry: now + HOUR, cachedAt: now - i * MINUTE }
  assert.deepEqual(staleKeys(entries, { now, limit: 7 }).sort(), ['k7', 'k8', 'k9'])
  assert.deepEqual(staleKeys(entries, { now, limit: 20 }), [])
  assert.deepEqual(staleKeys(entries, { now, limit: 7, keys: ['k0', 'k9'] }), [])
})

test('staleMappingKeys limits each source separately', () => {
  const entries = {}
  for (let i = 0; i < 5; i++) {
    entries[`tmdb-details-tv-${i}`] = { data: i, expiry: now + HOUR, cachedAt: now - i }
    entries[`ani-${i}`] = { data: i, expiry: now + HOUR, cachedAt: now - i }
  }
  entries['other-key'] = { data: 1, expiry: now - STALE_GRACE - 1 }
  const dropped = staleMappingKeys(entries, { now, limits: [['tmdb-', 2], ['ani-', 4]] }).sort()
  assert.deepEqual(dropped, ['ani-4', 'other-key', 'tmdb-details-tv-2', 'tmdb-details-tv-3', 'tmdb-details-tv-4'])
})

test('retryAfterMs reads seconds and HTTP dates', () => {
  assert.equal(retryAfterMs('30', now), 30 * SECOND)
  assert.equal(retryAfterMs('0', now), 0)
  assert.equal(retryAfterMs(new Date(now + 5000).toUTCString(), now), 5000)
  assert.equal(retryAfterMs(null, now), null)
  assert.equal(retryAfterMs('', now), null)
  assert.equal(retryAfterMs('soon', now), null)
  assert.equal(retryAfterMs('-5', now), null)
})

test('retryDelay adds Retry-After as a number (not "30" + 1 = "301")', () => {
  assert.equal(retryDelay({ status: 429, headers: headers('30') }, 0, { now }), 31 * SECOND)
  assert.equal(retryDelay({ status: 429, headers: headers('30') }, 0, { max: 10 * SECOND, now }), 10 * SECOND)
})

test('retryDelay backs off exponentially and gives up', () => {
  const error = { status: 500, headers: headers(null) }
  assert.equal(retryDelay(error, 0, { base: SECOND, now }), SECOND)
  assert.equal(retryDelay(error, 1, { base: SECOND, now }), 2 * SECOND)
  assert.equal(retryDelay(error, 2, { base: SECOND, now }), 4 * SECOND)
  assert.equal(retryDelay(error, 3, { base: SECOND, now }), null)
  assert.equal(retryDelay(new TypeError('Failed to fetch'), 0, { base: 5 * SECOND, now }), 5 * SECOND)
  assert.equal(retryDelay(error, 0, { retries: 0, now }), null)
  assert.equal(retryDelay(error, 5, { retries: 10, base: SECOND, max: 8 * SECOND, now }), 8 * SECOND)
  assert.equal(retryDelay(error, undefined, { base: SECOND, now }), SECOND)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
