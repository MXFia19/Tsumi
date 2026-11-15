// Offline downloads: naming helpers. Run with: node electron/src/main/downloads/naming.test.mjs
import assert from 'node:assert/strict'
import { sanitizeName, episodeLabel, downloadId, subtitleExtension, videoExtension, totalFromContentRange, httpErrorMessage } from './naming.js'

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

test('sanitizeName removes reserved characters, names and trailing dots', () => {
  assert.equal(sanitizeName('Re:Zero - Starting Life in Another World?'), 'Re Zero - Starting Life in Another World')
  assert.equal(sanitizeName('Fate/stay night: UBW...'), 'Fate stay night UBW')
  assert.equal(sanitizeName('CON'), '_CON')
  assert.equal(sanitizeName('   '), 'Untitled')
  assert.ok(sanitizeName('x'.repeat(200)).length <= 80)
})

test('episodeLabel and downloadId', () => {
  assert.equal(episodeLabel({ number: 5 }), 'Episode 05')
  assert.equal(episodeLabel({ number: 120 }), 'Episode 120')
  assert.equal(episodeLabel({ number: 14, season: 2, localEpisode: 3 }), 'S02E03')
  assert.equal(downloadId(21, { number: 5 }), '21-s0-e5')
  assert.equal(downloadId('tmdb:tv/1399', { number: 14, season: 2, localEpisode: 3 }), 'tmdb_tv_1399-s2-e3')
})

test('subtitle and video extensions', () => {
  assert.equal(subtitleExtension('https://a.test/sub.ass?x=1'), 'ass')
  assert.equal(subtitleExtension('https://a.test/sub', 'text/vtt'), 'vtt')
  assert.equal(subtitleExtension('https://a.test/sub', '', 'WEBVTT\n\n00:00.000 --> 00:01.000\nHi'), 'vtt')
  assert.equal(subtitleExtension('https://a.test/sub', '', '[Script Info]\nTitle: x'), 'ass')
  assert.equal(subtitleExtension('https://a.test/sub', '', '1\n00:00:00,000 --> 00:00:01,000\nHi'), 'srt')
  assert.equal(videoExtension('https://a.test/v', 'video/x-matroska'), 'mkv')
  assert.equal(videoExtension('https://a.test/v.webm?t=1'), 'webm')
  assert.equal(videoExtension('https://a.test/v', 'application/octet-stream'), 'mp4')
})

test('content range and HTTP messages', () => {
  assert.equal(totalFromContentRange('bytes 100-199/12345'), 12345)
  assert.equal(totalFromContentRange('bytes 100-199/*'), null)
  assert.match(httpErrorMessage(403), /expired/)
  assert.match(httpErrorMessage(500), /HTTP 500/)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
