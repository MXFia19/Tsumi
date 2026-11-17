// Player pure helpers. Run with: node common/modules/playerstate.test.mjs
import assert from 'node:assert/strict'
import { chapterKind, rememberOffset, resumePosition, parseSubtitleOffset, subtitleUrlOf, inEndChapters, upNextRemaining, hlsLevelOptions, episodeRangeOf, isTmdbMedia } from './playerstate.js'

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

test('chapterKind reads AniSkip, IntroDB and file chapter names', () => {
  assert.equal(chapterKind('OP'), 'Opening')
  assert.equal(chapterKind('ED'), 'Ending')
  assert.equal(chapterKind('Credits'), 'Credits')
  assert.equal(chapterKind('Preview'), 'Preview')
  assert.equal(chapterKind('Recap'), 'Recap')
  assert.equal(chapterKind(' Intro '), 'Intro')
  assert.equal(chapterKind('Episode'), null)
  assert.equal(chapterKind(''), null)
  assert.equal(chapterKind(undefined), null)
})

test('resumePosition resumes 5 s before the saved time', () => {
  assert.equal(resumePosition({ currentTime: 600, safeduration: 1440 }), 595)
  assert.equal(resumePosition({ currentTime: 12, safeduration: 1440 }), 7)
})

test('resumePosition starts over when nothing useful is saved', () => {
  assert.equal(resumePosition(null), null)
  assert.equal(resumePosition({}), null)
  assert.equal(resumePosition({ currentTime: 9, safeduration: 1440 }), null)
  assert.equal(resumePosition({ currentTime: NaN, safeduration: 1440 }), null)
})

test('resumePosition ignores an episode past the completion threshold', () => {
  // 85 % of 1440 s = 1224 s
  assert.equal(resumePosition({ currentTime: 1300, safeduration: 1440 }), null)
  assert.equal(resumePosition({ currentTime: 1224, safeduration: 1440 }), null)
  assert.equal(resumePosition({ currentTime: 1200, safeduration: 1440 }), 1195)
  assert.equal(resumePosition({ currentTime: 1300, safeduration: 1440 }, { threshold: 95 }), 1295)
  // the loaded video length wins over the saved one
  assert.equal(resumePosition({ currentTime: 1300, safeduration: 3000 }, { duration: 1440 }), null)
  // the threshold is clamped to 50-97 %
  assert.equal(resumePosition({ currentTime: 1420, safeduration: 1440 }, { threshold: 100 }), null) // 97 % = 1396.8 s
  assert.equal(resumePosition({ currentTime: 1390, safeduration: 1440 }, { threshold: 100 }), 1385)
  assert.equal(resumePosition({ currentTime: 700, safeduration: 1440 }, { threshold: 10 }), 695) // 50 % = 720 s
  assert.equal(resumePosition({ currentTime: 730, safeduration: 1440 }, { threshold: 10 }), null)
})

test('rememberOffset keeps the 200 most recent shows and forgets 0', () => {
  let entries = rememberOffset(null, '21', 1.5, 1000)
  assert.deepEqual(entries, { 21: { offset: 1.5, at: 1000 } })
  entries = rememberOffset(entries, '21', 0, 2000)
  assert.deepEqual(entries, {})
  entries = {}
  for (let i = 0; i < 205; i++) entries = rememberOffset(entries, String(i), 1, i)
  assert.equal(Object.keys(entries).length, 200)
  assert.equal(entries['0'], undefined)
  assert.equal(entries['4'], undefined)
  assert.deepEqual(entries['5'], { offset: 1, at: 5 })
  // setting an old show again makes it recent
  entries = rememberOffset(entries, '5', 2, 1000)
  entries = rememberOffset(entries, 'new', 1, 1001)
  assert.deepEqual(entries['5'], { offset: 2, at: 1000 })
  assert.equal(entries['6'], undefined)
})

test('parseSubtitleOffset accepts a decimal comma and signs', () => {
  assert.equal(parseSubtitleOffset('1,5'), 1.5)
  assert.equal(parseSubtitleOffset('-0,25'), -0.25)
  assert.equal(parseSubtitleOffset('+2'), 2)
  assert.equal(parseSubtitleOffset(' 0.5 '), 0.5)
  assert.equal(parseSubtitleOffset('.5'), 0.5)
  assert.equal(parseSubtitleOffset('3.'), 3)
  assert.equal(parseSubtitleOffset(-1.2), -1.2)
  assert.equal(parseSubtitleOffset(''), 0)
  assert.equal(parseSubtitleOffset(null), 0)
  assert.equal(parseSubtitleOffset('-'), null)
  assert.equal(parseSubtitleOffset('abc'), null)
  assert.equal(parseSubtitleOffset('1,5,2'), null)
  assert.equal(parseSubtitleOffset('99999'), 3600)
})

test('subtitleUrlOf reads strings, arrays and objects', () => {
  assert.equal(subtitleUrlOf('https://example.com/a.vtt'), 'https://example.com/a.vtt')
  assert.equal(subtitleUrlOf(['', { url: 'https://example.com/b.srt' }]), 'https://example.com/b.srt')
  assert.equal(subtitleUrlOf({ file: 'http://example.com/c.vtt', label: 'English' }), 'http://example.com/c.vtt')
  assert.equal(subtitleUrlOf('data:text/vtt;base64,V0VCVlRU'), 'data:text/vtt;base64,V0VCVlRU')
  assert.equal(subtitleUrlOf('javascript:alert(1)'), null)
  assert.equal(subtitleUrlOf('file:///C:/x.srt'), null)
  assert.equal(subtitleUrlOf(null), null)
  assert.equal(subtitleUrlOf([]), null)
  assert.equal(subtitleUrlOf(42), null)
})

// AniSkip-like chapters of a 24 min episode, in milliseconds.
const chapters = [
  { start: 0, end: 90000, text: 'Intro' },
  { start: 90000, end: 180000, text: 'OP' },
  { start: 180000, end: 1260000, text: 'Episode' },
  { start: 1260000, end: 1350000, text: 'ED' },
  { start: 1350000, end: 1440000, text: 'Preview' }
]

test('inEndChapters is true during the ending and the preview only', () => {
  assert.equal(inEndChapters(chapters, 100, 1440), false)
  assert.equal(inEndChapters(chapters, 600, 1440), false)
  assert.equal(inEndChapters(chapters, 1300, 1440), true)
  assert.equal(inEndChapters(chapters, 1400, 1440), true)
  assert.equal(inEndChapters([], 1400, 1440), false)
  assert.equal(inEndChapters(chapters, 1500, 1440), false)
})

test('inEndChapters is false when content follows the credits', () => {
  const postCredits = [
    { start: 0, end: 1200000, text: 'Episode' },
    { start: 1200000, end: 1290000, text: 'Credits' },
    { start: 1290000, end: 1440000, text: 'Episode' }
  ]
  assert.equal(inEndChapters(postCredits, 1250, 1440), false)
  // an "Ending" chapter in the first half is not the end of the episode
  const early = [{ start: 0, end: 300000, text: 'ED' }, { start: 300000, end: 1440000, text: 'Credits' }]
  assert.equal(inEndChapters(early, 100, 1440), false)
})

test('upNextRemaining counts the video time left before the next episode', () => {
  // Card shown at 1300 s: the next episode starts at 1310 s.
  assert.equal(upNextRemaining(1310, 1300, 1440), 10)
  assert.equal(upNextRemaining(1310, 1300.2, 1440), 10)
  assert.equal(upNextRemaining(1310, 1301, 1440), 9)
  assert.equal(upNextRemaining(1310, 1309.9, 1440), 1)
  assert.equal(upNextRemaining(1310, 1310, 1440), 0)
  // Seeked past it: never negative.
  assert.equal(upNextRemaining(1310, 1320, 1440), 0)
  // Never more than what is left of the episode.
  assert.equal(upNextRemaining(1445, 1435, 1440), 5)
  assert.equal(upNextRemaining(1310, 1300), 10)
  assert.equal(upNextRemaining(1310, NaN, 1440), 0)
})

test('hlsLevelOptions lists the best quality first', () => {
  const options = hlsLevelOptions([{ height: 360, bitrate: 800000 }, { height: 1080, bitrate: 5000000 }, { height: 720, bitrate: 2500000 }])
  assert.deepEqual(options, [{ index: 1, label: '1080p' }, { index: 2, label: '720p' }, { index: 0, label: '360p' }])
  const twins = hlsLevelOptions([{ height: 720, bitrate: 1500000 }, { height: 720, bitrate: 3000000 }, { bitrate: 64000 }])
  assert.deepEqual(twins.map(o => o.label), ['720p (3000 kbps)', '720p (1500 kbps)', '64 kbps'])
  assert.deepEqual(hlsLevelOptions(null), [])
})

test('episodeRangeOf finds merged episodes only', () => {
  assert.deepEqual(episodeRangeOf(2880, 24, 1), { first: 1, last: 2 })
  assert.deepEqual(episodeRangeOf(2880, 24, 2), { first: 3, last: 4 })
  assert.equal(episodeRangeOf(1800, 24, 1), null) // a long episode, within 6 minutes
  assert.equal(episodeRangeOf(100, 24, 1), null)
  assert.equal(episodeRangeOf(2880, 0, 1), null)
  assert.equal(episodeRangeOf(2880, 24, 0), null)
})

test('isTmdbMedia', () => {
  assert.equal(isTmdbMedia({ id: 'tmdb-1399' }), true)
  assert.equal(isTmdbMedia({ id: 21, isTmdb: true }), true)
  assert.equal(isTmdbMedia({ id: 21 }), false)
  assert.equal(isTmdbMedia(null), false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
