// Search relevance scoring. Run with: node common/modules/search/relevance.test.mjs
// The Swift port (ios-native/Tsumi/Services/SearchRelevance.swift) follows the same rules: when a rule
// changes here, change it there too and keep these expectations.
import assert from 'node:assert/strict'
import { SCORE, normalizeTitle, maxEdits, prepare, editDistance, scoreTitle, scoreMedia, rankByRelevance, fuzzyMatches, isRelevanceSort, relevancePopularity, isExactTitleMatch } from './relevance.js'

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

const score = (query, title) => scoreTitle(prepare(query), prepare(title))
const media = (id, title, extra = {}) => ({ id, title: { romaji: title, english: extra.english ?? null, native: extra.native ?? null, userPreferred: title }, synonyms: extra.synonyms || [], popularity: extra.popularity ?? 0, isTmdb: extra.isTmdb })

test('normalizeTitle folds case, accents, punctuation and apostrophes', () => {
  assert.equal(normalizeTitle('Pokémon: The Movie'), 'pokemon the movie')
  assert.equal(normalizeTitle('  Re:ZERO -Starting Life in Another World-  '), 're zero starting life in another world')
  assert.equal(normalizeTitle("Frieren's Journey"), 'frierens journey')
  assert.equal(normalizeTitle('Frieren’s Journey'), 'frierens journey')
  assert.equal(normalizeTitle('Panty & Stocking'), 'panty and stocking')
  assert.equal(normalizeTitle('Steins;Gate'), 'steins gate')
  assert.equal(normalizeTitle('ＳＰＹ×ＦＡＭＩＬＹ'), 'spy family')
  assert.equal(normalizeTitle('Kiss×Sis'), 'kiss sis')
  assert.equal(normalizeTitle('ÇA ÈST ŒUVRE'), 'ca est œuvre')
  assert.equal(normalizeTitle('ΟΔΥΣΣΕΥΣ'), 'οδυσσευσ')
  assert.equal(normalizeTitle('進撃の巨人'), '進撃の巨人')
  assert.equal(normalizeTitle('がっこうぐらし'), 'かっこうくらし')
  assert.equal(normalizeTitle('!!!'), '')
  assert.equal(normalizeTitle(null), '')
})

test('maxEdits grows with the word length', () => {
  assert.equal(maxEdits(3), 0)
  assert.equal(maxEdits(4), 1)
  assert.equal(maxEdits(7), 1)
  assert.equal(maxEdits(8), 2)
})

test('editDistance is the optimal string alignment distance, capped', () => {
  const d = (a, b, max = 5) => editDistance(Array.from(a), Array.from(b), max)
  assert.equal(d('naruto', 'naruto'), 0)
  assert.equal(d('naurto', 'naruto'), 1) // swap
  assert.equal(d('narto', 'naruto'), 1) // missing letter
  assert.equal(d('nbruto', 'naruto'), 1) // substitution
  assert.equal(d('kitten', 'sitting'), 3)
  assert.equal(d('abc', 'abcdefgh', 2), 3) // length gap above the cap
  assert.equal(d('', 'abc', 5), 3)
  assert.equal(d('kitten', 'sitting', 1), 2)
})

test('tiers: exact > prefix > phrase > words > substring > fuzzy > compact fuzzy', () => {
  assert.equal(score('Naruto', 'NARUTO'), SCORE.EXACT)
  assert.equal(score('dragonball', 'Dragon Ball'), SCORE.EXACT)
  assert.equal(score('naruto', 'Naruto: Shippuden'), SCORE.PREFIX)
  assert.equal(score('naru', 'Naruto'), SCORE.PREFIX)
  assert.equal(score('naruto', 'Boruto: Naruto Next Generations'), SCORE.PHRASE)
  assert.equal(score('titan attack', 'Attack on Titan'), SCORE.WORDS)
  assert.equal(score('titan att', 'Attack on Titan'), SCORE.WORDS)
  assert.equal(score('ontitan', 'Attack on Titan'), SCORE.SUBSTRING)
  assert.equal(score('atack on titan', 'Attack on Titan'), SCORE.FUZZY)
  assert.equal(score('naurto', 'Naruto'), SCORE.FUZZY)
  assert.equal(score('atack on titn', 'Attack on Titan'), 45)
  assert.equal(score('atack on titn shingki', 'Attack on Titan Shingeki'), 40)
  assert.equal(score('kimetsunoyaba', 'Kimetsu no Yaiba'), SCORE.COMPACT_FUZZY)
  assert.equal(score('one piece', 'Bleach'), SCORE.NONE)
  assert.equal(score('', 'Bleach'), SCORE.NONE)
})

test('short words need exact or prefix matches', () => {
  assert.equal(score('aot', 'Attack on Titan'), SCORE.NONE)
  assert.equal(score('k on', 'K-On!'), SCORE.EXACT)
  assert.equal(score('bleahc', 'Bleach'), SCORE.FUZZY) // swapped letters: one edit
  assert.equal(score('blx', 'Bleach'), SCORE.NONE) // 3 letters: no edit budget
  assert.equal(score('x titan', 'Attack on Titan X'), SCORE.WORDS) // 1 letter: exact word
  assert.equal(score('t titan', 'Attack on Titan X'), SCORE.NONE) // 1 letter: no word prefix
  assert.equal(score('z', 'Zom 100'), SCORE.PREFIX)
})

test('native titles match by prefix and substring', () => {
  assert.equal(score('進撃', '進撃の巨人'), SCORE.PREFIX)
  assert.equal(score('巨人', '進撃の巨人'), SCORE.SUBSTRING)
})

test('scoreMedia takes the best title, synonyms score 5 less', () => {
  const titan = media(1, 'Shingeki no Kyojin', { english: 'Attack on Titan', native: '進撃の巨人', synonyms: ['AoT', 'SnK'] })
  assert.equal(scoreMedia('attack on titan', titan), SCORE.EXACT)
  assert.equal(scoreMedia('shingeki', titan), SCORE.PREFIX)
  assert.equal(scoreMedia('aot', titan), SCORE.EXACT - 5)
  assert.equal(scoreMedia('進撃', titan), SCORE.PREFIX)
  assert.equal(scoreMedia('bleach', titan), SCORE.NONE)
  assert.equal(scoreMedia('bleach', null), SCORE.NONE)
  assert.equal(scoreMedia('bleach', { id: 2 }), SCORE.NONE)
})

test('rankByRelevance: tier first, then popularity, then original order', () => {
  const list = [
    media(1, 'Boruto: Naruto Next Generations', { popularity: 300000 }),
    media(2, 'Naruto: Shippuuden', { popularity: 600000 }),
    media(3, 'Naruto', { popularity: 500000 }),
    media(4, 'Road of Naruto', { popularity: 10000 }),
    media(5, 'Naruto: Shippuuden Movie 1', { popularity: 50000 }),
    media(6, 'Something Else', { popularity: 900000 })
  ]
  assert.deepEqual(rankByRelevance('naruto', list).map(m => m.id), [3, 2, 5, 1, 4, 6])
  assert.deepEqual(rankByRelevance('naurto', list).map(m => m.id), [2, 3, 1, 5, 4, 6])
  // Same score and popularity keep the incoming order.
  assert.deepEqual(rankByRelevance('x', [media(7, 'A'), media(8, 'B')]).map(m => m.id), [7, 8])
  assert.deepEqual(rankByRelevance('naruto', [null, media(9, 'Naruto')]).map(m => m.id), [9])
})

test('relevancePopularity scales TMDB popularity', () => {
  assert.equal(relevancePopularity({ popularity: 12.5, isTmdb: true }), 12500)
  assert.equal(relevancePopularity({ popularity: 1200 }), 1200)
  assert.equal(relevancePopularity(null), 0)
})

test('fuzzyMatches finds typos and partial titles, best first, limited', () => {
  const list = [
    media(1, 'Sousou no Frieren', { english: "Frieren: Beyond Journey's End", popularity: 400000 }),
    media(2, 'Kusuriya no Hitorigoto', { english: 'The Apothecary Diaries', popularity: 300000 }),
    media(3, 'Frieren Specials', { popularity: 1000 })
  ]
  assert.deepEqual(fuzzyMatches('freiren', list).map(({ media }) => media.id), [1, 3])
  assert.deepEqual(fuzzyMatches('apothecary', list).map(({ media }) => media.id), [2])
  assert.deepEqual(fuzzyMatches('apothecray diares', list).map(({ media }) => media.id), [2])
  assert.deepEqual(fuzzyMatches('frieren', list, { limit: 1 }).map(({ media }) => media.id), [1]) // both prefixes: more popular first
  assert.deepEqual(fuzzyMatches('fr', list), []) // too short for local matches
  assert.deepEqual(fuzzyMatches('zzzzzz', list), [])
})

test('isRelevanceSort: a text query without an explicit sort', () => {
  assert.equal(isRelevanceSort({ search: 'naruto' }), true)
  assert.equal(isRelevanceSort({ search: 'naruto', sort: '' }), true)
  assert.equal(isRelevanceSort({ search: 'naruto', sort: 'SEARCH_MATCH' }), true)
  assert.equal(isRelevanceSort({ search: 'naruto', sort: ['SEARCH_MATCH'] }), true)
  assert.equal(isRelevanceSort({ search: 'naruto', sort: 'SCORE_DESC' }), false)
  assert.equal(isRelevanceSort({ search: 'naruto', sort: 'TRENDING_DESC' }), false)
  assert.equal(isRelevanceSort({ search: '  ' }), false)
  assert.equal(isRelevanceSort({}), false)
})

test('isExactTitleMatch: a title or synonym equal to the query', () => {
  const titan = media(1, 'Shingeki no Kyojin', { english: 'Attack on Titan', synonyms: ['AoT'] })
  assert.equal(isExactTitleMatch('Attack on Titan', titan), true)
  assert.equal(isExactTitleMatch('attack-on-titan', titan), true)
  assert.equal(isExactTitleMatch('AOT', titan), true)
  assert.equal(isExactTitleMatch('Attack on Titan 2', titan), false)
  assert.equal(isExactTitleMatch('Attack', titan), false)
  assert.equal(isExactTitleMatch('', titan), false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
