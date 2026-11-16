// TheIntroDB pure logic. Run with: node common/modules/introdb/core.test.mjs
import assert from 'node:assert/strict'
import { introDbUrl, introDbChapters, animeQuery, INTRODB_API } from './core.js'

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

const strip = (chapters) => chapters.map(({ start, end, text }) => [start, end, text])

test('introDbUrl builds movie, TMDB episode and TVDB episode requests', () => {
  assert.equal(introDbUrl({ tmdb: 603 }), `${INTRODB_API}/media?tmdb_id=603`)
  assert.equal(introDbUrl({ tmdb: 603 }, 8160.4), `${INTRODB_API}/media?tmdb_id=603&duration_ms=8160400`)
  assert.equal(introDbUrl({ tmdb: 1399, season: 2, episode: 3 }), `${INTRODB_API}/media?tmdb_id=1399&season=2&episode=3`)
  assert.equal(introDbUrl({ tvdb: 424536, tmdb: 209867, season: 1, episode: 1, tvdbEpisode: 9350138 }, 1500),
    `${INTRODB_API}/media?tvdb_id=424536&season=1&episode=1&tvdb_episode_id=9350138&duration_ms=1500000`)
  assert.equal(introDbUrl({ tmdb: 1399, season: 0, episode: 1 }), `${INTRODB_API}/media?tmdb_id=1399&season=0&episode=1`)
})

test('introDbUrl refuses incomplete queries', () => {
  assert.equal(introDbUrl({}), null)
  assert.equal(introDbUrl(null), null)
  assert.equal(introDbUrl({ tmdb: 1399, season: 1 }), null)
  assert.equal(introDbUrl({ tmdb: 1399, episode: 2 }), null)
  assert.equal(introDbUrl({ tmdb: 1399, season: 1, episode: 0 }), null)
  assert.equal(introDbUrl({ tmdb: 'abc' }), null)
})

test('introDbChapters fills the gaps and the open ends (TV episode)', () => {
  const json = { type: 'tv', intro: [{ start_ms: 435985, end_ms: 535607 }], credits: [{ start_ms: 3629912, end_ms: null }] }
  assert.deepEqual(strip(introDbChapters(json, 3700)), [
    [0, 435985, 'Episode'],
    [435985, 535607, 'Intro'],
    [535607, 3629912, 'Episode'],
    [3629912, 3700000, 'Credits']
  ])
  assert.ok(introDbChapters(json, 3700).filter(c => c.text !== 'Episode').every(c => c.trusted))
})

test('introDbChapters handles a null start, "no recap" markers and movies', () => {
  const json = { type: 'movie', intro: [{ start_ms: null, end_ms: 40000 }], recap: [{ start_ms: 0, end_ms: 0 }], credits: [{ start_ms: 7726802, end_ms: null }] }
  assert.deepEqual(strip(introDbChapters(json, 8160)), [
    [0, 40000, 'Intro'],
    [40000, 7726802, 'Movie'],
    [7726802, 8160000, 'Credits']
  ])
})

test('introDbChapters cuts overlaps and drops segments inside others', () => {
  // Re:Zero S1E1: the preview starts before the credits and runs to the end.
  const json = { type: 'tv', intro: [{ start_ms: 123373, end_ms: 215416 }], credits: [{ start_ms: 1435000, end_ms: 1524985 }], preview: [{ start_ms: 1432000, end_ms: null }] }
  assert.deepEqual(strip(introDbChapters(json, 1530)), [
    [0, 123373, 'Episode'],
    [123373, 215416, 'Intro'],
    [215416, 1432000, 'Episode'],
    [1432000, 1530000, 'Preview']
  ])
  const partial = { intro: [{ start_ms: 1000, end_ms: 60000 }], recap: [{ start_ms: 50000, end_ms: 90000 }] }
  assert.deepEqual(strip(introDbChapters(partial, 600)), [
    [0, 1000, 'Episode'],
    [1000, 60000, 'Intro'],
    [60000, 90000, 'Recap'],
    [90000, 600000, 'Episode']
  ])
})

test('introDbChapters absorbs gaps shorter than a second and clamps to the video', () => {
  const json = { intro: [{ start_ms: 500, end_ms: 80000 }], credits: [{ start_ms: 1300000, end_ms: 1499600 }], preview: [{ start_ms: 1600000, end_ms: 1700000 }] }
  assert.deepEqual(strip(introDbChapters(json, 1500)), [
    [0, 80000, 'Intro'],
    [80000, 1300000, 'Episode'],
    [1300000, 1500000, 'Credits']
  ])
})

test('introDbChapters returns nothing for empty answers or an unknown duration', () => {
  assert.deepEqual(introDbChapters(null, 1400), [])
  assert.deepEqual(introDbChapters({ type: 'tv' }, 1400), [])
  assert.deepEqual(introDbChapters({ intro: [{ start_ms: 0, end_ms: 0 }] }, 1400), [])
  assert.deepEqual(introDbChapters({ intro: [{ start_ms: 1000, end_ms: 9000 }] }, 0), [])
  assert.deepEqual(introDbChapters({ intro: [{ start_ms: 'x', end_ms: 9000 }] }, 1400), [])
})

test('animeQuery uses the TVDB numbering of ani.zip, the TMDB id for movies', () => {
  const mappings = {
    mappings: { type: 'TV', thetvdb_id: 424536, themoviedb_id: '209867' },
    episodes: { 1: { seasonNumber: 1, episodeNumber: 1, tvdbShowId: 424536, tvdbId: 9350138 }, 30: { seasonNumber: 2, episodeNumber: 2, tvdbShowId: 424536 } }
  }
  assert.deepEqual(animeQuery(mappings, 1, false), { tvdb: 424536, season: 1, episode: 1, tvdbEpisode: 9350138 })
  assert.deepEqual(animeQuery(mappings, 30, false), { tvdb: 424536, season: 2, episode: 2, tvdbEpisode: undefined })
  assert.equal(animeQuery(mappings, 99, false), null)
  assert.equal(animeQuery(null, 1, false), null)
  assert.deepEqual(animeQuery({ mappings: { type: 'MOVIE', themoviedb_id: '372058' } }, 1, false), { tmdb: 372058 })
  assert.deepEqual(animeQuery({ mappings: { type: 'TV', themoviedb_id: '372058' } }, 1, true), { tmdb: 372058 })
  assert.equal(animeQuery({ mappings: { type: 'MOVIE' } }, 1, true), null)
})

test('animeQuery keeps episode 0 (prologue) instead of using episode 1', () => {
  const mappings = {
    mappings: { type: 'TV', thetvdb_id: 424536 },
    episodes: { 1: { seasonNumber: 1, episodeNumber: 1, tvdbShowId: 424536 } }
  }
  assert.equal(animeQuery(mappings, 0, false), null)
  assert.deepEqual(animeQuery(mappings, undefined, false), { tvdb: 424536, season: 1, episode: 1, tvdbEpisode: undefined })
  assert.deepEqual(animeQuery(mappings, '1', false), { tvdb: 424536, season: 1, episode: 1, tvdbEpisode: undefined })
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
