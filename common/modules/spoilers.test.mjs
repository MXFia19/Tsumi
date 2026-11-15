// Spoiler protection rules. Run with: node common/modules/spoilers.test.mjs
import assert from 'node:assert/strict'
import { SPOILER_LEVELS, SPOILER_STATUSES, DEFAULT_SPOILER_STATUS, SPOILER_ITEMS, SPOILER_TEXT, spoilerLevel, levelHides, spoilerListStatus, isProtected, isUnwatched, hidesMedia, hidesEpisode, hidesTag, hidesEpisodeThumbnail, spoilerText } from './spoilers.js'

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

const watching = (progress) => ({ mediaListEntry: { status: 'CURRENT', progress } })
const on = (spoilers, spoilerStatus = DEFAULT_SPOILER_STATUS) => ({ spoilers, spoilerStatus })

test('levels and statuses', () => {
  assert.deepEqual(SPOILER_LEVELS.map(([, value]) => value), ['off', 'minimal', 'moderate', 'strict', 'hermit'])
  assert.ok(!SPOILER_STATUSES.some(([, value]) => value === 'COMPLETED'))
  assert.deepEqual(DEFAULT_SPOILER_STATUS, ['CURRENT', 'REPEATING'])
})

test('spoilerLevel defaults to off', () => {
  assert.equal(spoilerLevel(undefined), 'off')
  assert.equal(spoilerLevel({}), 'off')
  assert.equal(spoilerLevel({ spoilers: 'nonsense' }), 'off')
  assert.equal(spoilerLevel({ spoilers: 'toString' }), 'off')
  assert.equal(spoilerLevel({ spoilers: 'strict' }), 'strict')
})

test('each level includes the levels below it', () => {
  const hidden = (level) => Object.keys(SPOILER_ITEMS).filter(item => levelHides(item, { spoilers: level })).sort()
  assert.deepEqual(hidden('off'), [])
  assert.deepEqual(hidden('minimal'), ['episodeImage'])
  assert.deepEqual(hidden('moderate'), ['episodeDescription', 'episodeImage', 'mediaSpoilerTags', 'reviews'])
  assert.deepEqual(hidden('strict'), ['episodeDescription', 'episodeImage', 'episodeTitle', 'generalSpoilerTags', 'mediaSpoilerTags', 'rating', 'reviews', 'synopsis'])
  assert.deepEqual(hidden('hermit'), Object.keys(SPOILER_ITEMS).sort())
  assert.equal(levelHides('unknown', { spoilers: 'hermit' }), false)
})

test('protection follows the selected list statuses', () => {
  assert.equal(spoilerListStatus(null), 'NOTONLIST')
  assert.equal(spoilerListStatus({ mediaListEntry: null }), 'NOTONLIST')
  assert.equal(isProtected(watching(3), on('off')), false)
  assert.equal(isProtected(watching(3), on('minimal')), true)
  assert.equal(isProtected({ mediaListEntry: { status: 'REPEATING', progress: 1 } }, on('minimal')), true)
  assert.equal(isProtected({ mediaListEntry: { status: 'PLANNING', progress: 0 } }, on('minimal')), false)
  assert.equal(isProtected({}, on('minimal')), false)
  assert.equal(isProtected({}, on('minimal', ['NOTONLIST'])), true)
  assert.equal(isProtected(watching(3), { spoilers: 'strict' }), false)
  assert.equal(isProtected(watching(3), { spoilers: 'strict', spoilerStatus: 'CURRENT' }), false)
})

test('episodes after the progress are unwatched', () => {
  assert.equal(isUnwatched(watching(3), 3), false)
  assert.equal(isUnwatched(watching(3), 4), true)
  assert.equal(isUnwatched(watching(3), '4'), true)
  assert.equal(isUnwatched({}, 1), true)
  assert.equal(isUnwatched(watching(3), undefined), false)
  assert.equal(isUnwatched(watching(3), false), false)
  assert.equal(isUnwatched(watching(3), ''), false)
  assert.equal(isUnwatched(watching(3), [4, 5]), false)
})

test('series content is hidden by level for protected titles', () => {
  const media = watching(5)
  assert.equal(hidesMedia('synopsis', media, on('moderate')), false)
  assert.equal(hidesMedia('synopsis', media, on('strict')), true)
  assert.equal(hidesMedia('reviews', media, on('moderate')), true)
  assert.equal(hidesMedia('rating', media, on('moderate')), false)
  assert.equal(hidesMedia('duration', media, on('strict')), false)
  assert.equal(hidesMedia('duration', media, on('hermit')), true)
  assert.equal(hidesMedia('synopsis', { mediaListEntry: { status: 'DROPPED', progress: 2 } }, on('hermit')), false)
})

test('episode content is hidden after the progress only', () => {
  const media = watching(5)
  assert.equal(hidesEpisode('episodeImage', media, 5, on('minimal')), false)
  assert.equal(hidesEpisode('episodeImage', media, 6, on('minimal')), true)
  assert.equal(hidesEpisode('episodeDescription', media, 6, on('minimal')), false)
  assert.equal(hidesEpisode('episodeDescription', media, 6, on('moderate')), true)
  assert.equal(hidesEpisode('episodeTitle', media, 6, on('moderate')), false)
  assert.equal(hidesEpisode('episodeTitle', media, 6, on('strict')), true)
  assert.equal(hidesEpisode('duration', media, 6, on('hermit')), true)
  assert.equal(hidesEpisode('episodeTitle', media, 6, on('off')), false)
})

test('spoiler tags', () => {
  const media = watching(1)
  const general = { name: 'Twist', isGeneralSpoiler: true }
  const specific = { name: 'Death', isMediaSpoiler: true }
  const plain = { name: 'Action' }
  assert.equal(hidesTag(plain, media, on('hermit')), false)
  assert.equal(hidesTag(specific, media, on('minimal')), false)
  assert.equal(hidesTag(specific, media, on('moderate')), true)
  assert.equal(hidesTag(general, media, on('moderate')), false)
  assert.equal(hidesTag(general, media, on('strict')), true)
  assert.equal(hidesTag(general, {}, on('strict')), false)
  assert.equal(hidesTag(undefined, media, on('strict')), false)
})

test('episode card thumbnails keep the rule of protection off', () => {
  const off = on('off')
  assert.equal(hidesEpisodeThumbnail(watching(2), 3, off), true)
  assert.equal(hidesEpisodeThumbnail(watching(3), 3, off), false)
  assert.equal(hidesEpisodeThumbnail({ mediaListEntry: { status: 'PLANNING', progress: 0 } }, 1, off), true)
  assert.equal(hidesEpisodeThumbnail({ mediaListEntry: { status: 'DROPPED', progress: 0 } }, 1, off), false)
  assert.equal(hidesEpisodeThumbnail({}, 1, off), false)
  assert.equal(hidesEpisodeThumbnail(watching(2), false, off), false)
  // Protection adds its own statuses.
  assert.equal(hidesEpisodeThumbnail({ mediaListEntry: { status: 'DROPPED', progress: 0 } }, 1, on('minimal', ['DROPPED'])), true)
  assert.equal(hidesEpisodeThumbnail({}, 1, on('minimal', ['NOTONLIST'])), true)
  assert.equal(hidesEpisodeThumbnail({}, 1, on('off', ['NOTONLIST'])), false)
})

test('spoilerText', () => {
  assert.equal(spoilerText('Episode title', false), 'Episode title')
  assert.equal(spoilerText('Episode title', true), SPOILER_TEXT)
  assert.equal(spoilerText('', true), '')
  assert.equal(spoilerText(null, true), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
