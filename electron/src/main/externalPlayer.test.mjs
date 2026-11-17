// External player command line and closing position. Run with: node electron/src/main/externalPlayer.test.mjs
import assert from 'node:assert/strict'
import { playerKind, playerArgs, cleanTitle, startSeconds, readMpvMessages, closedPosition, MIN_ESTIMATED_S } from './externalPlayerArgs.js'

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

test('playerArgs: mpv gets its JSON IPC server before the URL', () => {
  assert.deepEqual(playerArgs('mpv', { url: 'https://v.example/a.mp4', ipcPath: '\\\\.\\pipe\\tsumi-mpv-1' }), [
    '--input-ipc-server=\\\\.\\pipe\\tsumi-mpv-1', '--', 'https://v.example/a.mp4'
  ])
  // Only mpv speaks it.
  assert.deepEqual(playerArgs('vlc', { url: 'https://v.example/a.mp4', ipcPath: 'x' }), ['--no-one-instance', 'https://v.example/a.mp4'])
  assert.deepEqual(playerArgs('other', { url: 'https://v.example/a.mp4', ipcPath: 'x' }), ['https://v.example/a.mp4'])
})

test('readMpvMessages keeps the last position, the length and the end of the file', () => {
  const state = { position: null, duration: null, ended: false }
  let rest = readMpvMessages(state, '{"error":"success","request_id":0}\n{"event":"property-change","id":2,"name":"duration","data":1420.5}\n{"event":"property-change","id":1,"name":"time-pos","data":83.2}\n{"event":"property-')
  assert.equal(state.duration, 1420.5)
  assert.equal(state.position, 83.2)
  assert.equal(rest, '{"event":"property-')
  // The rest of a message split across two reads.
  rest = readMpvMessages(state, rest + 'change","id":1,"name":"time-pos","data":600}\n')
  assert.equal(state.position, 600)
  assert.equal(rest, '')
  // Unavailable when the file closes: the last position stays.
  readMpvMessages(state, '{"event":"property-change","id":1,"name":"time-pos"}\n{"event":"property-change","id":1,"name":"time-pos","data":null}\n')
  assert.equal(state.position, 600)
  assert.equal(state.ended, false)
  readMpvMessages(state, '{"event":"end-file","reason":"quit"}\n')
  assert.equal(state.ended, false)
  readMpvMessages(state, 'not json\n{"event":"end-file","reason":"eof","playlist_entry_id":1}\n')
  assert.equal(state.ended, true)
  // Never a buffer that grows without a newline.
  assert.equal(readMpvMessages(state, 'x'.repeat(70_000)), '')
})

test('closedPosition: what mpv reported over IPC', () => {
  assert.deepEqual(closedPosition({ connected: true, position: 612.4, duration: 1420, ended: false }, { startTime: 100, elapsed: 900 }), { position: 612.4, duration: 1420 })
  // The end of the file: the whole episode.
  assert.deepEqual(closedPosition({ connected: true, position: 1415, duration: 1420, ended: true }, { elapsed: 5 }), { position: 1420, duration: 1420 })
  // Connected but it never played (stream error): nothing, never an estimate.
  assert.deepEqual(closedPosition({ connected: true, position: null, duration: null, ended: false }, { startTime: 100, elapsed: 60 }), {})
  assert.deepEqual(closedPosition({ connected: true, position: 0, duration: 1420 }, { elapsed: 60 }), {})
  assert.deepEqual(closedPosition({ connected: true, position: 30 }, {}), { position: 30 })
})

test('closedPosition: other players get an estimate from the time they stayed open', () => {
  assert.deepEqual(closedPosition({ connected: false }, { startTime: 120, elapsed: 600.25 }), { position: 720.25, estimated: true })
  assert.deepEqual(closedPosition({}, { elapsed: 300 }), { position: 300, estimated: true })
  // Closed at once (failed, or handed over to a player already running): no position.
  assert.deepEqual(closedPosition({}, { startTime: 120, elapsed: MIN_ESTIMATED_S - 1 }), {})
  assert.deepEqual(closedPosition({}, { startTime: 120 }), {})
  assert.deepEqual(closedPosition(undefined, { elapsed: NaN }), {})
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
