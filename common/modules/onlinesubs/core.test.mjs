// Online subtitles pure logic. Run with: node common/modules/onlinesubs/core.test.mjs
import assert from 'node:assert/strict'
import {
  normalizeLanguage, preferredLanguage, languageName, subtitlesUrl, queryKey, episodeCandidates, tmdbSeasonEpisode,
  parseSubtitleList, groupByLanguage, pickAutomatic, trackLabel, episodeNumber
} from './core.js'

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

test('normalizeLanguage keeps the primary subtag and maps aliases', () => {
  assert.equal(normalizeLanguage('pt-BR'), 'pt')
  assert.equal(normalizeLanguage('EN'), 'en')
  assert.equal(normalizeLanguage('nb'), 'no')
  assert.equal(normalizeLanguage(''), '')
  assert.equal(normalizeLanguage('English'), '')
})

test('preferredLanguage maps the app setting, English for None', () => {
  assert.equal(preferredLanguage('eng'), 'en')
  assert.equal(preferredLanguage('fre'), 'fr')
  assert.equal(preferredLanguage('lat'), 'es')
  assert.equal(preferredLanguage('idn'), 'id')
  assert.equal(preferredLanguage(''), 'en')
  assert.equal(preferredLanguage(undefined), 'en')
})

test('languageName uses English names', () => {
  assert.equal(languageName('fr'), 'French')
  assert.equal(languageName('pt'), 'Portuguese')
  assert.equal(languageName('und'), 'Unknown')
  assert.equal(languageName(''), 'Unknown')
})

test('subtitlesUrl builds tv and movie queries', () => {
  assert.equal(subtitlesUrl({ type: 'tv', tmdb: 209867, season: 1, episode: 1 }), 'https://subs.wing.st/subtitles?type=tv&tmdb=209867&season=1&episode=1')
  assert.equal(subtitlesUrl({ type: 'movie', tmdb: 603 }), 'https://subs.wing.st/subtitles?type=movie&tmdb=603')
  assert.equal(queryKey({ type: 'tv', tmdb: 1, season: 2, episode: 3 }), 'tv:1:2:3')
  assert.equal(queryKey({ type: 'movie', tmdb: 9 }), 'movie:9')
})

test('episodeCandidates: TVDB numbering, then absolute, then animap, then the episode itself', () => {
  // One Piece 1000 (ani.zip: S21E109, absolute 1000)
  assert.deepEqual(episodeCandidates({ episode: 1000, aniEpisode: { seasonNumber: 21, episodeNumber: 109, absoluteEpisodeNumber: 1000 } }), [
    { season: 21, episode: 109 }, { season: 1, episode: 1000 }
  ])
  // Attack on Titan Season 2 episode 1 (S2E1, absolute 26)
  assert.deepEqual(episodeCandidates({ episode: 1, aniEpisode: { seasonNumber: 2, episodeNumber: 1, absoluteEpisodeNumber: 26 } }), [
    { season: 2, episode: 1 }, { season: 1, episode: 26 }, { season: 1, episode: 1 }
  ])
  // No ani.zip data: animap TVDB season + offset
  assert.deepEqual(episodeCandidates({ episode: 3, tvdbSeason: 2, tvdbOffset: 12 }), [{ season: 2, episode: 15 }, { season: 1, episode: 3 }])
  assert.deepEqual(episodeCandidates({ episode: 0 }), [])
})

test('tmdbSeasonEpisode maps absolute numbers across seasons (specials ignored)', () => {
  const seasons = [{ season_number: 0, episode_count: 5 }, { season_number: 2, episode_count: 12 }, { season_number: 1, episode_count: 10 }]
  assert.deepEqual(tmdbSeasonEpisode(seasons, 1), { season: 1, episode: 1 })
  assert.deepEqual(tmdbSeasonEpisode(seasons, 10), { season: 1, episode: 10 })
  assert.deepEqual(tmdbSeasonEpisode(seasons, 11), { season: 2, episode: 1 })
  assert.equal(tmdbSeasonEpisode(seasons, 23), null)
  assert.equal(tmdbSeasonEpisode(seasons, 0), null)
  assert.deepEqual(tmdbSeasonEpisode([{ seasonNumber: 1, episodeCount: 3 }], 2), { season: 1, episode: 2 })
})

test('parseSubtitleList drops invalid URLs and duplicate releases', () => {
  const list = parseSubtitleList({
    total: 5,
    subtitles: [
      { id: 'a', language: 'en', url: 'https://subs.wing.st/sub/a', type: 'srt', display: 'Show.S01E01.srt', source: 'shegu' },
      { id: 'b', language: 'en', url: 'https://subs.wing.st/sub/b', type: 'srt', display: 'show.s01e01.SRT', source: 'shegu' },
      { id: 'c', language: 'pt-BR', url: 'https://subs.wing.st/sub/c', type: 'srt', display: 'Portuguese (1)', source: 'opensubs' },
      { id: 'd', language: 'fr', url: 'http://insecure/sub', type: 'srt', display: 'x' },
      { id: 'e', language: '', url: 'https://subs.wing.st/sub/e', display: '' }
    ]
  })
  assert.deepEqual(list.map(item => item.id), ['a', 'c', 'e'])
  assert.equal(list[1].language, 'pt')
  assert.equal(list[2].language, 'und')
  assert.equal(list[2].name, 'Subtitles')
  assert.equal(list[2].format, 'srt')
  assert.deepEqual(parseSubtitleList(null), [])
})

test('groupByLanguage puts the preferred language, then English, then the others by name', () => {
  const list = [
    { language: 'pt', name: '1' }, { language: 'en', name: '2' }, { language: 'ar', name: '3' }, { language: 'fr', name: '4' }, { language: 'fr', name: '5' }
  ]
  const groups = groupByLanguage(list, 'fr')
  assert.deepEqual(groups.map(group => group.language), ['fr', 'en', 'ar', 'pt'])
  assert.equal(groups[0].items.length, 2)
  assert.equal(groups[0].name, 'French')
  assert.deepEqual(groupByLanguage(list, 'en').map(group => group.language), ['en', 'ar', 'fr', 'pt'])
})

test('pickAutomatic takes the first SRT of the preferred language', () => {
  const list = [{ language: 'en', format: 'vtt', id: 1 }, { language: 'fr', format: 'srt', id: 2 }, { language: 'en', format: 'srt', id: 3 }]
  assert.equal(pickAutomatic(list, 'en').id, 3)
  assert.equal(pickAutomatic(list, 'de'), null)
})

test('trackLabel names the track after the language and the release', () => {
  assert.equal(trackLabel({ language: 'en', name: 'Frieren.S01E01.WEBRip.srt' }), 'English - Frieren.S01E01.WEBRip')
  assert.equal(trackLabel({ language: 'fr', name: '' }), 'French')
})

test('episodeNumber keeps episode 0, 1 when missing or invalid', () => {
  assert.equal(episodeNumber(0), 0)
  assert.equal(episodeNumber('0'), 0)
  assert.equal(episodeNumber(12), 12)
  assert.equal(episodeNumber('12'), 12)
  assert.equal(episodeNumber(undefined), 1)
  assert.equal(episodeNumber(null), 1)
  assert.equal(episodeNumber(''), 1)
  assert.equal(episodeNumber('abc'), 1)
  assert.equal(episodeNumber(-3), 1)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
