// Stream URL kind (HLS or file), pure logic. Run with: node common/modules/streamkind.test.mjs
import assert from 'node:assert/strict'
import { streamKindFromUrl, isPlaylistResponse } from './streamkind.js'

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

test('streamKindFromUrl', () => {
  assert.equal(streamKindFromUrl('https://cdn.example.org/a/master.m3u8?x=1'), 'hls')
  assert.equal(streamKindFromUrl('https://cdn.example.org/a/index.M3U8'), 'hls')
  assert.equal(streamKindFromUrl('https://cdn.example.org/video.mp4?token=abc'), 'file')
  assert.equal(streamKindFromUrl('https://cdn.example.org/episode.mkv'), 'file')
  assert.equal(streamKindFromUrl('https://cdn.example.org/hls/master'), 'unknown')
  assert.equal(streamKindFromUrl('https://cdn.example.org/playlist?id=5&type=hls'), 'unknown')
  // A query that mentions a file does not make the path a file.
  assert.equal(streamKindFromUrl('https://cdn.example.org/play?file=x.mp4'), 'unknown')
  assert.equal(streamKindFromUrl(''), 'unknown')
})

test('isPlaylistResponse', () => {
  assert.equal(isPlaylistResponse('application/vnd.apple.mpegurl', ''), true)
  assert.equal(isPlaylistResponse('audio/x-mpegURL', ''), true)
  assert.equal(isPlaylistResponse('text/plain', '#EXTM3U\n#EXT-X-VERSION:3'), true)
  assert.equal(isPlaylistResponse('application/octet-stream', String.fromCharCode(0xfeff) + '\n#EXTM3U'), true)
  assert.equal(isPlaylistResponse('video/mp4', '\u0000\u0000\u0000 ftypisom'), false)
  assert.equal(isPlaylistResponse(null, '<html>'), false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
