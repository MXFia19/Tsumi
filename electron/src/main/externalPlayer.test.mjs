// External player command line. Run with: node electron/src/main/externalPlayer.test.mjs
import assert from 'node:assert/strict'
import { playerKind, playerArgs, cleanTitle, startSeconds } from './externalPlayerArgs.js'

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

test('playerKind recognizes mpv and VLC by their executable name', () => {
  assert.equal(playerKind('C:\\Program Files\\mpv\\mpv.exe'), 'mpv')
  assert.equal(playerKind('C:\\Tools\\mpv.net\\mpvnet.exe'), 'mpv')
  assert.equal(playerKind('/usr/bin/mpv'), 'mpv')
  assert.equal(playerKind('C:\\Program Files\\VideoLAN\\VLC\\vlc.exe'), 'vlc')
  assert.equal(playerKind('/Applications/VLC.app/Contents/MacOS/VLC'), 'vlc')
  assert.equal(playerKind('C:\\Program Files\\MPC-HC\\mpc-hc64.exe'), 'other')
  assert.equal(playerKind(''), 'other')
})

test('playerArgs: mpv gets title, start, subtitles and the URL after --', () => {
  assert.deepEqual(playerArgs('mpv', { url: 'http://localhost:1/t/proxy?url=x', title: 'Frieren - Episode 3', subtitle: 'https://s.example/a.vtt', startTime: 83.4567 }), [
    '--force-media-title=Frieren - Episode 3',
    '--start=83.457',
    '--sub-file=https://s.example/a.vtt',
    '--',
    'http://localhost:1/t/proxy?url=x'
  ])
  assert.deepEqual(playerArgs('mpv', { url: 'https://v.example/a.mp4' }), ['--', 'https://v.example/a.mp4'])
})

test('playerArgs: VLC gets a new instance, title, start time and a local subtitle file', () => {
  assert.deepEqual(playerArgs('vlc', { url: 'https://v.example/a.m3u8', title: 'A', subtitle: 'C:\\Temp\\s.srt', startTime: 12 }), [
    '--no-one-instance', '--meta-title=A', '--start-time=12', '--sub-file=C:\\Temp\\s.srt', 'https://v.example/a.m3u8'
  ])
})

test('playerArgs: any other player gets the URL only', () => {
  assert.deepEqual(playerArgs('other', { url: 'https://v.example/a.mp4', title: 'A', subtitle: 'x', startTime: 50 }), ['https://v.example/a.mp4'])
})

test('cleanTitle and startSeconds keep arguments safe', () => {
  assert.equal(cleanTitle('A\nB\u0000C\tD'), 'A B C D')
  assert.equal(cleanTitle(undefined), '')
  assert.equal(cleanTitle('x'.repeat(300)).length, 200)
  assert.equal(startSeconds(0), null)
  assert.equal(startSeconds(-5), null)
  assert.equal(startSeconds('12.5'), 12.5)
  assert.equal(startSeconds('abc'), null)
  assert.equal(startSeconds(Infinity), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
