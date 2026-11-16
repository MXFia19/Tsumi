// SRT / WebVTT / MicroDVD -> ASS conversion. Run with: node common/modules/subconvert.test.mjs
import assert from 'node:assert/strict'
import { parseCueTimeMs, assTime, cueTextToAss, srtToAss, microDvdToAss, convertSubText } from './subconvert.js'

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

/** "Dialogue: 0,start,end,..." -> [start, end] */
const times = (line) => line.split(',').slice(1, 3)

test('parseCueTimeMs reads SRT, WebVTT and short forms', () => {
  assert.equal(parseCueTimeMs('00:00:01,500'), 1500)
  assert.equal(parseCueTimeMs('00:00:01.500'), 1500)
  assert.equal(parseCueTimeMs('00:01.500'), 1500)
  assert.equal(parseCueTimeMs('01:02:03,004'), 3723004)
  assert.equal(parseCueTimeMs('0:00:02.5'), 2500)
  assert.equal(parseCueTimeMs('00:00:02'), 2000)
  assert.ok(Number.isNaN(parseCueTimeMs('nope')))
})

test('assTime writes 2-digit centiseconds (libass reads the fraction as centiseconds)', () => {
  assert.equal(assTime(1500), '0:00:01.50')
  assert.equal(assTime(1505), '0:00:01.50')
  assert.equal(assTime(62999), '0:01:02.99')
  assert.equal(assTime(3723004), '1:02:03.00')
  assert.equal(assTime(-5), '0:00:00.00')
  assert.equal(assTime(NaN), '0:00:00.00')
})

test('SRT cues reach libass with H:MM:SS.cc times', () => {
  const srt = '1\r\n00:00:01,500 --> 00:00:04,250\r\nHello\r\n\r\n2\r\n00:00:05,000 --> 00:00:06,999\r\nSecond line\r\ntwo rows\r\n'
  const lines = srtToAss(srt)
  assert.equal(lines.length, 2)
  assert.deepEqual(times(lines[0]), ['0:00:01.50', '0:00:04.25'])
  assert.equal(lines[0], 'Dialogue: 0,0:00:01.50,0:00:04.25,Default,,0,0,0,,Hello')
  assert.deepEqual(times(lines[1]), ['0:00:05.00', '0:00:06.99'])
  assert.ok(lines[1].endsWith(',Second line\\Ntwo rows'))
})

test('every converted cue keeps start before end (3-digit fractions used to be read as 10x)', () => {
  // 0:00:01.500 was read by libass as 1 s + 500 cs = 6 s, after the 0:00:04.250 end: the line was dropped.
  const [line] = srtToAss('00:00:01,500 --> 00:00:04,250\nText')
  const [start, end] = times(line).map(t => {
    const [h, m, s] = t.split(':')
    const [sec, cs] = s.split('.')
    assert.equal(cs.length, 2)
    return ((Number(h) * 60 + Number(m)) * 60 + Number(sec)) * 100 + Number(cs)
  })
  assert.ok(start < end)
})

test('WebVTT: header, cue ids, settings, MM:SS times and tags', () => {
  const vtt = 'WEBVTT\n\nNOTE a comment\n\nintro\n00:01.000 --> 00:02.500 align:start position:10%\n<i>Hi</i> &amp; <c.yellow>bye</c>\n\n01:00:00.120 --> 01:00:01.000\n<b>Bold</b>\n'
  const lines = srtToAss(vtt)
  assert.equal(lines.length, 2)
  assert.equal(lines[0], 'Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\i1}Hi{\\i0} & bye')
  assert.deepEqual(times(lines[1]), ['1:00:00.12', '1:00:01.00'])
  assert.ok(lines[1].endsWith(',{\\b1}Bold{\\b0}'))
})

test('cueTextToAss drops unknown tags and decodes entities', () => {
  assert.equal(cueTextToAss('<font color="#fff">A</font> &lt;3&gt;'), 'A <3>')
  assert.equal(cueTextToAss('a&nbsp;b\n\n'), 'a\\hb')
  assert.equal(cueTextToAss('<u>u</u><s>s</s>'), '{\\u1}u{\\u0}{\\s1}s{\\s0}')
})

test('MicroDVD: every line is read (newline split), the frame rate line is used and hidden', () => {
  const sub = '{1}{1}25\r\n{25}{50}First|line\r\n{75}{100}Second\r\n'
  const lines = microDvdToAss(sub)
  assert.equal(lines.length, 2)
  assert.equal(lines[0], 'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,First\\Nline')
  assert.deepEqual(times(lines[1]), ['0:00:03.00', '0:00:04.00'])
})

test('MicroDVD without a frame rate uses 23.976 fps', () => {
  const lines = microDvdToAss('{0}{24}One\n{48}{72}Two')
  assert.equal(lines.length, 2)
  assert.deepEqual(times(lines[0]), ['0:00:00.00', '0:00:01.00'])
})

test('convertSubText picks the converter from the type, then from the content', () => {
  const ass = '[Script Info]\nTitle: x\n'
  assert.equal(convertSubText(ass, 'ass'), ass)
  assert.equal(convertSubText(ass, 'ssa'), ass)
  assert.equal(convertSubText(ass, 'subtitle'), ass) // pasted text has no extension
  assert.equal(convertSubText('00:00:01,000 --> 00:00:02,000\nA', 'txt').length, 1)
  assert.equal(convertSubText('{1}{25}A', 'txt').length, 1)
  assert.equal(convertSubText('just text', 'txt'), undefined)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
