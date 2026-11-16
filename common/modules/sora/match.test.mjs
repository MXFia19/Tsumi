// Sora search results matched to AniList / TMDB media. Run with: node common/modules/sora/match.test.mjs
import assert from 'node:assert/strict'
import { matchTargets, pickBestMatch, resultMedia } from './match.js'

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

const media = (id, romaji, extra = {}) => ({ id, title: { romaji, english: extra.english ?? null, native: null, userPreferred: romaji }, synonyms: extra.synonyms || [], popularity: extra.popularity ?? 0, isTmdb: extra.isTmdb })

test('matchTargets reads the module type', () => {
  assert.deepEqual(matchTargets({ type: 'anime' }), { anime: true, western: false })
  assert.deepEqual(matchTargets({ type: 'Movies' }), { anime: false, western: true })
  assert.deepEqual(matchTargets({ type: 'shows' }), { anime: false, western: true })
  assert.deepEqual(matchTargets({}), { anime: true, western: true })
  assert.deepEqual(matchTargets(null), { anime: true, western: true })
})

test('pickBestMatch takes the best title, then the most popular', () => {
  const candidates = [
    media(1, 'Frieren: Beyond Journey\'s End', { popularity: 10 }),
    media(2, 'Sousou no Frieren', { english: 'Frieren: Beyond Journey\'s End', popularity: 500 }),
    media(3, 'Frieren Season 2', { popularity: 900 })
  ]
  assert.equal(pickBestMatch(['Frieren: Beyond Journey\'s End'], candidates).id, 2)
  assert.equal(pickBestMatch(['Frieren Season 2'], candidates).id, 3)
})

test('pickBestMatch uses the aliases and refuses unrelated titles', () => {
  const candidates = [media(10, 'Kimetsu no Yaiba', { english: 'Demon Slayer' })]
  assert.equal(pickBestMatch(['Le Pourfendeur de démons', 'Demon Slayer'], candidates).id, 10)
  assert.equal(pickBestMatch(['One Piece'], candidates), null)
  assert.equal(pickBestMatch([], candidates), null)
  assert.equal(pickBestMatch(['Demon Slayer'], null), null)
})

test('resultMedia builds a card media without AniList data', () => {
  const m = resultMedia({ key: 'fsvid-1.0', manifest: { sourceName: 'Fsvid' } }, { title: ' Heartland ', href: 'https://example.org/x', image: 'https://example.org/x.jpg' })
  assert.equal(m.isSora, true)
  assert.equal(m.id, 'sora-fsvid-1.0-https://example.org/x')
  assert.equal(m.title.userPreferred, 'Heartland')
  assert.equal(m.coverImage.extraLarge, 'https://example.org/x.jpg')
  assert.deepEqual(m.sora, { extensionKey: 'fsvid-1.0', extensionName: 'Fsvid', href: 'https://example.org/x', title: 'Heartland', image: 'https://example.org/x.jpg' })
  assert.equal(resultMedia({ key: 'k' }, { title: 'T', href: 'h', image: 'javascript:alert(1)' }).coverImage.extraLarge, null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
