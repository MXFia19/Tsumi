// Offline downloads: renderer helpers. Run with: node common/modules/downloads/resolve.test.mjs
import assert from 'node:assert/strict'
import { titleScore, bestResult, matchEpisode, normalizeSubtitles, preferredSubtitle, pickServerIndex, nextEpisodeNumbers, formatBytes } from './resolve.js'

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

test('titleScore and bestResult', () => {
  assert.equal(titleScore('Frieren', 'Frieren'), 100)
  assert.equal(titleScore('Frieren', 'Frieren: Beyond Journey\'s End'), 90)
  const best = bestResult([{ title: 'Something else' }, { title: 'Frieren (Dub)' }, { title: 'Frieren' }], 'Frieren')
  assert.equal(best.title, 'Frieren')
  assert.equal(bestResult([], 'x'), null)
})

test('matchEpisode never falls back to another episode', () => {
  const list = [{ number: 1, href: 'a' }, { number: 2, href: 'b' }]
  assert.equal(matchEpisode(list, { number: 2 }).href, 'b')
  assert.equal(matchEpisode(list, 2).href, 'b')
  assert.equal(matchEpisode(list, { number: 3 }), null)
  assert.equal(matchEpisode([{ number: 1, href: 'movie' }], { number: 1 }).href, 'movie')
  assert.equal(matchEpisode([{ number: 1, href: 'movie' }], { number: 4 }).href, 'movie', 'a single entry is the episode (movies)')
})

test('matchEpisode with seasons: explicit, href, inferred and unique local number', () => {
  const explicit = [{ season: 1, number: 1, href: 's1e1' }, { season: 2, number: 1, href: 's2e1' }]
  assert.equal(matchEpisode(explicit, { number: 13, season: 2, localEpisode: 1 }).href, 's2e1')
  const hrefs = [{ number: 1, href: '/show/1/1' }, { number: 1, href: '/show/2/1' }]
  assert.equal(matchEpisode(hrefs, { number: 13, season: 2, localEpisode: 1 }).href, '/show/2/1')
  const inferred = [{ number: 1, href: 'x1' }, { number: 2, href: 'x2' }, { number: 1, href: 'y1' }, { number: 2, href: 'y2' }]
  assert.equal(matchEpisode(inferred, { number: 4, season: 2, localEpisode: 2 }).href, 'y2')
  const unique = [{ number: 7, href: 'only7' }, { number: 8, href: 'only8' }]
  assert.equal(matchEpisode(unique, { number: 20, season: 3, localEpisode: 8 }).href, 'only8')
})

test('normalizeSubtitles accepts strings, objects and arrays, without duplicates', () => {
  assert.deepEqual(normalizeSubtitles('https://s.test/a.vtt'), [{ url: 'https://s.test/a.vtt', lang: '', label: '' }])
  const list = normalizeSubtitles([
    'https://s.test/a.vtt',
    { file: 'https://s.test/b.srt', label: 'French' },
    { url: 'https://s.test/c.ass', lang: 'en' },
    { url: 'https://s.test/a.vtt' },
    null,
    { nothing: true }
  ])
  assert.equal(list.length, 3)
  assert.equal(list[1].label, 'French')
  assert.equal(list[2].lang, 'en')
  assert.deepEqual(normalizeSubtitles(null), [])
})

test('preferredSubtitle: setting language, then French, then first', () => {
  const list = [{ url: '1', lang: '', label: 'Arabic' }, { url: '2', lang: 'fr', label: '' }, { url: '3', lang: 'eng', label: 'English' }]
  assert.equal(preferredSubtitle(list, 'eng').url, '3')
  assert.equal(preferredSubtitle(list, 'jpn').url, '2')
  assert.equal(preferredSubtitle([{ url: 'x', lang: '' }], 'eng').url, 'x')
  assert.equal(preferredSubtitle([], 'eng'), null)
})

test('pickServerIndex keeps the server downloaded before, then the session choice', () => {
  const servers = [{ title: 'SUB' }, { title: 'DUB' }, {}]
  assert.equal(pickServerIndex(servers, 'DUB', 'SUB'), 1)
  assert.equal(pickServerIndex(servers, 'Missing', 'SUB'), 0)
  assert.equal(pickServerIndex(servers, null, 'Server 3'), 2)
  assert.equal(pickServerIndex([], 'x'), 0)
})

test('nextEpisodeNumbers stops at the last released episode', () => {
  assert.deepEqual(nextEpisodeNumbers({ progress: 3, released: 12, count: 3 }), [4, 5, 6])
  assert.deepEqual(nextEpisodeNumbers({ progress: 10, released: 12, count: 5 }), [11, 12])
  assert.deepEqual(nextEpisodeNumbers({ progress: 12, released: 12, count: 5 }), [])
  assert.deepEqual(nextEpisodeNumbers({ progress: 0, released: 2, count: 5, zeroEpisode: true }), [0, 1, 2])
})

test('formatBytes', () => {
  assert.equal(formatBytes(512), '512 B')
  assert.equal(formatBytes(1536), '1.5 KB')
  assert.equal(formatBytes(1024 ** 3 * 2.25), '2.3 GB')
  assert.equal(formatBytes(1024 ** 2 * 250), '250 MB')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
