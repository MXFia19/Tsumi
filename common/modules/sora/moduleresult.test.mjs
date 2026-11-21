// Module results opened as they are, pure logic. Run with: node common/modules/sora/moduleresult.test.mjs
import assert from 'node:assert/strict'
import { linksResults, moduleEpisodes, moduleDetails, episodeLabel, playableMedia, episodeFor, moduleSeasons, seasonLabel, startSeason, episodeName } from './moduleresult.js'

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

test('linksResults: on unless turned off', () => {
  assert.equal(linksResults(undefined), true)
  assert.equal(linksResults({ enabled: true }), true)
  assert.equal(linksResults({ linkResults: true }), true)
  assert.equal(linksResults({ linkResults: false }), false)
})

test('moduleEpisodes: links once, the module numbers when all different whole numbers', () => {
  const raw = JSON.stringify([
    { href: 'https://v.example/1', number: 1 },
    { href: 'https://v.example/1', number: 1 },
    { href: ' https://v.example/2 ', number: '2', title: 'Second' },
    { href: '', number: 3 },
    { number: 4 },
    { href: 'https://v.example/5', number: 5 }
  ])
  assert.deepEqual(moduleEpisodes(raw), [
    { href: 'https://v.example/1', number: 1, title: '', season: null, seasonTitle: null, seasonEpisode: 1 },
    { href: 'https://v.example/2', number: 2, title: 'Second', season: null, seasonTitle: null, seasonEpisode: 2 },
    { href: 'https://v.example/5', number: 5, title: '', season: null, seasonTitle: null, seasonEpisode: 5 }
  ])
})

test('moduleEpisodes: numbered by place when a number is missing, repeated or not whole', () => {
  const numbers = (list) => moduleEpisodes(list).map(episode => episode.number)
  // Seasons starting again at 1.
  assert.deepEqual(numbers([{ href: 'a', number: 1 }, { href: 'b', number: 2 }, { href: 'c', number: 1 }]), [1, 2, 3])
  assert.deepEqual(numbers([{ href: 'a', number: 'abc' }, { href: 'b', number: 7 }]), [1, 2])
  assert.deepEqual(numbers([{ href: 'a' }]), [1])
  assert.deepEqual(numbers([{ href: 'a', number: 1.5 }, { href: 'b', number: 2 }]), [1, 2])
  assert.deepEqual(numbers([{ href: 'a', number: 0 }, { href: 'b', number: 1 }]), [0, 1])
  assert.deepEqual(numbers([{ href: 'a', number: null }, { href: 'b', number: 4 }]), [1, 2])
  assert.deepEqual(moduleEpisodes('not json'), [])
  assert.deepEqual(moduleEpisodes({ href: 'x' }), [])
  assert.deepEqual(moduleEpisodes(null), [])
})

test('moduleDetails: description and air date, placeholders dropped', () => {
  assert.deepEqual(moduleDetails([{ description: ' A stream ', airdate: '2026-11-17', aliases: 'x' }]), { description: 'A stream', airdate: '2026-11-17' })
  assert.deepEqual(moduleDetails(JSON.stringify({ description: 'Text', airdate: 'N/A' })), { description: 'Text', airdate: '' })
  assert.deepEqual(moduleDetails('broken'), { description: '', airdate: '' })
  assert.deepEqual(moduleDetails(null), { description: '', airdate: '' })
})

test('episodeLabel', () => {
  assert.equal(episodeLabel({ number: 1, title: '' }, 1), 'Play')
  assert.equal(episodeLabel({ number: 3, title: '' }, 5), 'Episode 3')
  assert.equal(episodeLabel({ number: 3, title: 'The Return' }, 5), 'Episode 3 - The Return')
  assert.equal(episodeLabel({ number: 3, title: 'Episode 3' }, 5), 'Episode 3')
})

test('playableMedia: highest whole episode number', () => {
  const media = { id: 'sora-a-b', isSora: true }
  assert.equal(playableMedia(media, [{ number: 1 }, { number: 12 }, { number: 2.5 }]).episodes, 12)
  assert.equal(playableMedia(media, [{ number: 0 }]).episodes, null)
  assert.equal(playableMedia(media, []).episodes, null)
  assert.equal(playableMedia(media, [{ number: 1 }]).isSora, true)
})

test('episodeFor: exact number only', () => {
  const episodes = [{ number: 1, href: 'a' }, { number: 2, href: 'b' }]
  assert.equal(episodeFor(episodes, 2).href, 'b')
  assert.equal(episodeFor(episodes, '1').href, 'a')
  assert.equal(episodeFor(episodes, 3), null)
  assert.equal(episodeFor([{ number: 5, href: 'only' }], 4), null)
})

test('moduleEpisodes: seasons where the numbers start again, played by their place in the list', () => {
  const list = [1, 2, 3, 1, 2, 0, 1].map((number, index) => ({ href: `h${index}`, number }))
  const episodes = moduleEpisodes(list)
  assert.deepEqual(episodes.map(episode => episode.number), [1, 2, 3, 4, 5, 6, 7])
  assert.deepEqual(episodes.map(episode => episode.season), [1, 1, 1, 2, 2, 3, 3])
  assert.deepEqual(episodes.map(episode => episode.seasonEpisode), [1, 2, 3, 1, 2, 0, 1])
  assert.equal(episodeLabel(episodes[3], episodes.length), 'Episode 1')
})

test('moduleEpisodes: seasons given by the module win', () => {
  const episodes = moduleEpisodes([
    { href: 'a', number: 1, season: 1 },
    { href: 'b', number: 2, season: '1' },
    { href: 'c', number: 3, season: 2 },
    { href: 'd', number: 4, season: 2 },
    { href: 'e', number: 1, season: 0 }
  ])
  assert.deepEqual(episodes.map(episode => episode.season), [1, 1, 2, 2, 0])
  assert.deepEqual(episodes.map(episode => episode.seasonEpisode), [1, 2, 3, 4, 1])
  // The numbers repeat (1 twice): played by place.
  assert.deepEqual(episodes.map(episode => episode.number), [1, 2, 3, 4, 5])
  // One season given for all: no season picker.
  assert.deepEqual(moduleEpisodes([{ href: 'a', number: 1, season: 2 }, { href: 'b', number: 2, season: 2 }]).map(episode => episode.season), [null, null])
})

test('moduleEpisodes: no seasons for lists numbered downwards or without a restart at 0 / 1', () => {
  const seasons = (numbers) => moduleEpisodes(numbers.map((number, index) => ({ href: `h${index}`, number }))).map(episode => episode.season)
  // Newest first: would start a season at every episode.
  assert.deepEqual(seasons([5, 4, 3, 2, 1]), [null, null, null, null, null])
  assert.deepEqual(seasons([3, 2, 1, 3, 2, 1]), [null, null, null, null, null, null])
  // A number out of order is not a new season.
  assert.deepEqual(seasons([1, 2, 4, 3, 5]), [null, null, null, null, null])
  // No numbers.
  assert.deepEqual(seasons([undefined, undefined]), [null, null])
  // Missing numbers do not break a season.
  assert.deepEqual(seasons([1, 2, undefined, 1, 2, 3]), [1, 1, 1, 2, 2, 2])
})

test('moduleEpisodes: season names of the module, in its order', () => {
  const tab = (seasonTitle, count, extra = {}) => Array.from({ length: count }, (_, index) => ({ href: `${seasonTitle}/${index}`, number: index + 1, title: `Épisode ${index + 1}`, seasonTitle, ...extra }))
  const episodes = moduleEpisodes([
    ...tab('Saison 1', 3, { season: 1 }),
    ...tab("Saison 1 Director's Cut", 2),
    ...tab('Films', 2, { season: 0 }),
    ...tab('Saison 2', 2, { season: 2 }),
    ...tab('Kai', 1)
  ])
  assert.deepEqual(episodes.map(episode => episode.season), [1, 1, 1, 2, 2, 3, 3, 4, 4, 5])
  assert.deepEqual(episodes.map(episode => episode.number), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  const groups = moduleSeasons(episodes)
  assert.deepEqual(groups.map(group => seasonLabel(group.season, group.title)), ['Saison 1', "Saison 1 Director's Cut", 'Films', 'Saison 2', 'Kai'])
  assert.deepEqual(groups[1].episodes.map(episode => episode.seasonEpisode), [1, 2])
  // seasonName is read too; a single name, or a name missing on an episode: no named seasons.
  assert.equal(moduleEpisodes([{ href: 'a', number: 1, seasonName: 'A' }, { href: 'b', number: 1, seasonName: 'B' }])[1].seasonTitle, 'B')
  assert.deepEqual(moduleEpisodes([{ href: 'a', number: 1, seasonTitle: 'A' }, { href: 'b', number: 2, seasonTitle: 'A' }]).map(episode => episode.season), [null, null])
  assert.deepEqual(moduleEpisodes([{ href: 'a', number: 1, seasonTitle: 'A' }, { href: 'b', number: 2 }]).map(episode => episode.seasonTitle), [null, null])
})

test('episodeLabel: a title that only says "Episode N" gives the number', () => {
  assert.equal(episodeLabel({ number: 13, seasonEpisode: 13, title: 'Épisode 12.5' }, 30), 'Episode 12.5')
  assert.equal(episodeLabel({ number: 14, seasonEpisode: 14, title: 'Épisode 13' }, 30), 'Episode 13')
  assert.equal(episodeLabel({ number: 1, seasonEpisode: 1, title: 'Memory Snow' }, 2), 'Episode 1 - Memory Snow')
  assert.equal(episodeLabel({ number: 2, seasonEpisode: 2, title: 'Episodes' }, 2), 'Episode 2 - Episodes')
  assert.equal(episodeLabel({ number: 24, seasonEpisode: 24, title: 'Épisode SP' }, 24), 'Episode SP')
  assert.equal(episodeLabel({ number: 1, seasonEpisode: 1, title: 'Épisode 0' }, 13), 'Episode 0')
  assert.equal(episodeLabel({ number: 3, seasonEpisode: 3, title: 'Episode3' }, 5), 'Episode 3')
})

test('moduleSeasons / seasonLabel / startSeason', () => {
  const episodes = moduleEpisodes([
    { href: 'e', number: 1, season: 0 },
    { href: 'a', number: 1, season: 2 },
    { href: 'b', number: 1, season: 1 },
    { href: 'c', number: 2, season: 1 }
  ])
  const groups = moduleSeasons(episodes)
  assert.deepEqual(groups.map(group => group.season), [1, 2, 0])
  assert.deepEqual(groups[0].episodes.map(episode => episode.href), ['b', 'c'])
  assert.equal(seasonLabel(2), 'Season 2')
  assert.equal(seasonLabel(0), 'Specials')
  assert.equal(episodeName({ number: 7, season: 2, seasonEpisode: 1 }), 'S2E1')
  assert.equal(episodeName({ number: 9, season: 0, seasonEpisode: 1 }), 'special 1')
  assert.equal(episodeName({ number: 3, season: null, seasonEpisode: 3 }), 'episode 3')
  assert.equal(episodeName({ number: 4 }), 'episode 4')
  assert.equal(episodeName({ number: 14, title: 'Épisode 13', season: 1, seasonTitle: 'Saison 1', seasonEpisode: 14 }), 'Saison 1 · episode 13')
  const flat = moduleSeasons(moduleEpisodes([{ href: 'x', number: 1 }, { href: 'y', number: 2 }]))
  assert.deepEqual(flat.map(group => [group.season, group.episodes.length]), [[null, 2]])
  assert.deepEqual(moduleSeasons([]), [])
  // Opens on the last season with an episode started, else the first.
  const startedNumbers = (numbers) => (number) => numbers.includes(number)
  const byHref = Object.fromEntries(episodes.map(episode => [episode.href, episode.number]))
  assert.equal(startSeason(groups, startedNumbers([])), 1)
  assert.equal(startSeason(groups, startedNumbers([byHref.b, byHref.a])), 2)
  assert.equal(startSeason(flat, () => false), null)
  assert.equal(startSeason([], () => false), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
