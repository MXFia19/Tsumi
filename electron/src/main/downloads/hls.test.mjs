// Offline downloads: HLS planning. Run with: node electron/src/main/downloads/hls.test.mjs
import assert from 'node:assert/strict'
import {
  parseAttributes, parseMasterPlaylist, pickVariant, pickAudioRendition, planMediaPlaylist, buildLocalMaster,
  drmReason, isMasterPlaylist, looksLikeHls, looksLikeDash
} from './hls.js'

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

const MASTER = `#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,URI="audio/ja.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud"
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
https://cdn.example.com/1080/index.m3u8?token=a,b
`

test('parseAttributes keeps quoted commas', () => {
  const attributes = parseAttributes('BANDWIDTH=1,CODECS="avc1,mp4a",RESOLUTION=1x2')
  assert.equal(attributes.CODECS, 'avc1,mp4a')
  assert.equal(attributes.RESOLUTION, '1x2')
})

test('master playlist variants and renditions resolve against the base URL', () => {
  assert.ok(isMasterPlaylist(MASTER))
  const master = parseMasterPlaylist(MASTER, 'https://host.test/show/master.m3u8')
  assert.equal(master.variants.length, 3)
  assert.equal(master.variants[0].uri, 'https://host.test/show/360/index.m3u8')
  assert.equal(master.variants[1].height, 720)
  assert.equal(master.variants[2].uri, 'https://cdn.example.com/1080/index.m3u8?token=a,b')
  assert.equal(master.media.length, 2)
  assert.ok(master.independentSegments)
})

test('pickVariant follows the quality setting', () => {
  const { variants } = parseMasterPlaylist(MASTER, 'https://host.test/')
  assert.equal(pickVariant(variants, 'highest').height, 1080)
  assert.equal(pickVariant(variants, 'lowest').height, 360)
  assert.equal(pickVariant(variants, '720').height, 720)
  assert.equal(pickVariant(variants, '1080').height, 1080)
  assert.equal(pickVariant(variants, '480').height, 360)
  // Every variant taller than the limit: the smallest one.
  assert.equal(pickVariant(variants.slice(1), '360').height, 720)
  // No resolution: bandwidth decides.
  const bare = [{ uri: 'a', bandwidth: 5, height: 0 }, { uri: 'b', bandwidth: 9, height: 0 }]
  assert.equal(pickVariant(bare, '720').uri, 'b')
  assert.equal(pickVariant(bare, 'lowest').uri, 'a')
  assert.equal(pickVariant([], 'highest'), null)
})

test('pickAudioRendition takes the default rendition of the variant group', () => {
  const master = parseMasterPlaylist(MASTER, 'https://host.test/')
  const audio = pickAudioRendition(master, master.variants[1])
  assert.equal(audio.name, 'Japanese')
  assert.equal(audio.uri, 'https://host.test/audio/ja.m3u8')
  assert.equal(pickAudioRendition(master, master.variants[0]), null)
})

test('media playlist: segments, AES-128 key, init segment and byte ranges become local files', () => {
  const text = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:12
#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/k1",IV=0x00000000000000000000000000000001
#EXTINF:6.0,
seg1.m4s
#EXTINF:6.0,
#EXT-X-BYTERANGE:1000@0
all.ts
#EXTINF:4.5,
#EXT-X-BYTERANGE:500
all.ts
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/k1"
#EXTINF:2,
https://cdn.test/seg-final.jpg?x=1
#EXT-X-ENDLIST
`
  const plan = planMediaPlaylist(text, 'https://host.test/v/index.m3u8', 'v')
  assert.equal(plan.drm, null)
  assert.equal(plan.segmentCount, 4)
  assert.ok(plan.endList)
  assert.equal(Math.round(plan.duration * 10), 185)
  const keys = plan.resources.filter(resource => resource.kind === 'key')
  assert.equal(keys.length, 1, 'the same key URI is downloaded once')
  const map = plan.resources.find(resource => resource.kind === 'map')
  assert.deepEqual(map.range, { start: 0, end: 719 })
  assert.equal(map.url, 'https://host.test/v/init.mp4')
  const segments = plan.resources.filter(resource => resource.kind === 'segment')
  assert.equal(segments[0].file, 'v-00000.m4s')
  assert.deepEqual(segments[1].range, { start: 0, end: 999 })
  assert.deepEqual(segments[2].range, { start: 1000, end: 1499 }, 'a range without offset continues the previous one')
  assert.equal(segments[3].file, 'v-00003.ts', 'unknown extensions are saved as .ts')
  assert.ok(!plan.playlist.includes('BYTERANGE'))
  assert.ok(plan.playlist.includes('#EXT-X-MAP:URI="v-init-0.mp4"'))
  assert.ok(plan.playlist.includes('URI="v-key-0.key",IV=0x00000000000000000000000000000001'))
  assert.ok(plan.playlist.includes('#EXT-X-MEDIA-SEQUENCE:12'), 'the media sequence (implicit IV) is kept')
  assert.ok(!plan.playlist.includes('https://'))
})

test('a playlist without ENDLIST gets one, DRM is reported', () => {
  const plan = planMediaPlaylist('#EXTM3U\n#EXTINF:5,\na.ts\n', 'https://h.test/', 'a')
  assert.ok(plan.playlist.trim().endsWith('#EXT-X-ENDLIST'))
  assert.equal(plan.resources[0].file, 'a-00000.ts')
  const drm = planMediaPlaylist('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x",KEYFORMAT="com.apple.streamingkeydelivery"\n#EXTINF:5,\na.ts\n', 'https://h.test/')
  assert.match(drm.drm, /DRM-protected/)
  assert.equal(drmReason({ METHOD: 'NONE' }), null)
  assert.equal(drmReason({ METHOD: 'AES-128' }), null)
  assert.match(drmReason({ METHOD: 'AES-128', KEYFORMAT: 'urn:uuid:edef8ba9' }), /DRM/)
})

test('local master joins video and audio playlists', () => {
  const master = buildLocalMaster({ variant: { bandwidth: 10, width: 1280, height: 720, codecs: 'avc1' }, audio: { name: 'Japanese', language: 'ja' }, independentSegments: true })
  assert.ok(master.includes('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"'))
  assert.ok(master.includes('RESOLUTION=1280x720'))
  assert.ok(master.trim().endsWith('video.m3u8'))
})

test('stream type detection', () => {
  assert.ok(looksLikeHls('https://a.test/x/master.m3u8?t=1'))
  assert.ok(looksLikeHls('https://a.test/x', 'application/vnd.apple.mpegurl'))
  assert.ok(!looksLikeHls('https://a.test/video.mp4'))
  assert.ok(looksLikeDash('https://a.test/manifest.mpd'))
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
