// WebVTT conversion. Run with: node common/modules/vtt.test.mjs
import assert from 'node:assert/strict'
import { parseTimestamp, formatTimestamp, assTextToVtt, srtTextToVtt, parseSrt, parseAssEvents, cuesToVtt, srtToVtt, trackToVtt, cueCount } from './vtt.js'

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

test('parseTimestamp reads ASS, SRT and short forms', () => {
  assert.equal(parseTimestamp('0:01:02.50'), 62.5)
  assert.equal(parseTimestamp('00:01:02,345'), 62.345)
  assert.equal(parseTimestamp('01:02.3'), 62.3)
  assert.equal(parseTimestamp('1:00:00.00'), 3600)
  assert.ok(Number.isNaN(parseTimestamp('nope')))
})

test('formatTimestamp writes HH:MM:SS.mmm', () => {
  assert.equal(formatTimestamp(62.345), '00:01:02.345')
  assert.equal(formatTimestamp(3725.0004), '01:02:05.000')
  assert.equal(formatTimestamp(-3), '00:00:00.000')
})

test('assTextToVtt strips overrides, keeps italics, line breaks and escapes', () => {
  assert.equal(assTextToVtt('{\\an8}{\\i1}Hello{\\i0}\\Nworld & <you>'), '<i>Hello</i>\nworld &amp; &lt;you&gt;')
  assert.equal(assTextToVtt('{\\b1}bold'), '<b>bold</b>')
  assert.equal(assTextToVtt('{\\pos(10,20)\\fs40}Sign'), 'Sign')
  assert.equal(assTextToVtt('{\\p1}m 0 0 l 100 0 100 100{\\p0}'), '')
  assert.equal(assTextToVtt('a\\hb'), `a${String.fromCharCode(0xa0)}b`)
  assert.equal(assTextToVtt('{\\i1}x{\\r}y'), '<i>x</i>y')
})

test('srtTextToVtt keeps basic tags and drops font tags', () => {
  assert.equal(srtTextToVtt('<font color="#ff0">Yellow</font> <i>it</i>'), 'Yellow <i>it</i>')
  assert.equal(srtTextToVtt('{\\an8}Top line'), 'Top line')
})

test('parseSrt handles BOM, CRLF, missing indexes and cue settings', () => {
  const srt = String.fromCharCode(0xfeff) + '1\r\n00:00:01,876 --> 00:00:05,422\r\n<i>ORIGINAL STORY</i>\r\nBY\r\n\r\n00:01:31,007 --> 00:01:34,302 X1:0\r\nSecond\r\n\r\n3\r\nbroken\r\n'
  const cues = parseSrt(srt)
  assert.equal(cues.length, 2)
  assert.deepEqual(cues[0], { start: 1.876, end: 5.422, text: '<i>ORIGINAL STORY</i>\nBY' })
  assert.equal(cues[1].start, 91.007)
})

test('parseAssEvents follows the Format line and keeps commas of the text', () => {
  const ass = [
    '[Script Info]',
    'Title: x',
    '[Events]',
    'Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text',
    'Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,ignored',
    'Dialogue: 0,0:00:02.00,0:00:04.50,Default,Frieren,0,0,0,,Well, well,{\\i1} well{\\i0}'
  ].join('\n')
  assert.deepEqual(parseAssEvents(ass), [{ start: 2, end: 4.5, text: 'Well, well,<i> well</i>' }])
})

test('parseAssEvents reads the player headers (no Format line, converted SRT)', () => {
  const header = '[Script Info]\nTitle: English (US)\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default, Roboto\n[Events]\n\nDialogue: 0,0:00:01.87,0:00:05.42,Default,,0,0,0,,{\\i1}Hi{\\i0}\\Nthere'
  assert.deepEqual(parseAssEvents(header), [{ start: 1.87, end: 5.42, text: '<i>Hi</i>\nthere' }])
})

test('cuesToVtt sorts, merges duplicate layers, applies the offset and drops negative cues', () => {
  const vtt = cuesToVtt([
    { start: 10, end: 12, text: 'B' },
    { start: 1, end: 3, text: 'A' },
    { start: 1, end: 3, text: 'A' },
    { start: 0, end: 0.5, text: 'gone' }
  ], 1)
  assert.equal(vtt, 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nA\n\n00:00:09.000 --> 00:00:11.000\nB\n')
  assert.equal(cueCount(vtt), 2)
})

test('srtToVtt converts a whole file', () => {
  assert.equal(srtToVtt('1\n00:00:01,000 --> 00:00:02,000\nHello\n'), 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n')
})

test('trackToVtt merges header dialogues and embedded events', () => {
  const vtt = trackToVtt({
    header: '[Events]\nDialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Header line',
    events: [{ Start: 1000, Duration: 1500, Text: 'Event line' }]
  })
  assert.equal(vtt, 'WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nEvent line\n\n00:00:05.000 --> 00:00:06.000\nHeader line\n')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
