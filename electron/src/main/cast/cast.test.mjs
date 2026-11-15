// Chromecast pure logic (DNS codec, Cast v2 framing, HLS rewriting). Run with: node electron/src/main/cast/cast.test.mjs
import assert from 'node:assert/strict'
import { encodeQuery, decodePacket, decodeName, TYPE } from './dns.js'
import { encodeCastMessage, decodeCastMessage, FrameParser, frame } from './castv2.js'
import { isPlaylistStart, rewritePlaylist, variantUrls, segmentFormat, fileContentType, resolveUri } from './hls.js'
import { deviceFromRecords, CAST_SERVICE } from './mdns.js'

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

// --- DNS helpers to build answers like a Cast device (with name compression) ---
function name (text) {
  const parts = []
  for (const label of text.split('.')) {
    const bytes = Buffer.from(label)
    parts.push(Buffer.from([bytes.length]), bytes)
  }
  parts.push(Buffer.from([0]))
  return Buffer.concat(parts)
}
function record (owner, type, klass, ttl, rdata) {
  const fixed = Buffer.alloc(10)
  fixed.writeUInt16BE(type, 0)
  fixed.writeUInt16BE(klass, 2)
  fixed.writeUInt32BE(ttl, 4)
  fixed.writeUInt16BE(rdata.length, 8)
  return Buffer.concat([owner, fixed, rdata])
}
function header (id, flags, qd, an, ns, ar) {
  const buf = Buffer.alloc(12)
  ;[id, flags, qd, an, ns, ar].forEach((value, i) => buf.writeUInt16BE(value, i * 2))
  return buf
}

test('encodeQuery writes a PTR question for the Cast service', () => {
  const packet = encodeQuery([{ name: CAST_SERVICE, type: TYPE.PTR }])
  const decoded = decodePacket(packet)
  assert.equal(decoded.isResponse, false)
  assert.deepEqual(decoded.questions, [{ name: '_googlecast._tcp.local', type: TYPE.PTR, class: 1 }])
  assert.equal(packet.readUInt16BE(packet.length - 2), 1) // class IN, QU bit off (legacy unicast query)
})

test('encodeQuery sets the unicast-response bit when asked', () => {
  const packet = encodeQuery([{ name: 'a.local', type: TYPE.A, unicastResponse: true }])
  assert.equal(packet.readUInt16BE(packet.length - 2), 0x8001)
})

test('decodePacket reads PTR / SRV / TXT / A records with compressed names', () => {
  const service = name('_googlecast._tcp.local')
  // Instance name = "Chromecast-abc" + pointer to the service name at offset 12.
  const instanceLabel = Buffer.from('Chromecast-abc')
  const instance = Buffer.concat([Buffer.from([instanceLabel.length]), instanceLabel, Buffer.from([0xc0, 12])])
  const instancePointer = Buffer.from([0xc0, 12 + service.length + 10])
  const target = name('abc.local')
  const txtEntries = ['id=1234abcd', 'fn=Living Room TV', 'md=Chromecast', 'rs=']
  const txt = Buffer.concat(txtEntries.map(entry => Buffer.concat([Buffer.from([Buffer.byteLength(entry)]), Buffer.from(entry)])))
  const ptr = record(service, TYPE.PTR, 1, 120, instance)
  const srvData = Buffer.concat([Buffer.from([0, 0, 0, 0, 0x1f, 0x49]), target])
  const srv = record(instancePointer, TYPE.SRV, 0x8001, 120, srvData)
  const txtRecord = record(instancePointer, TYPE.TXT, 0x8001, 4500, txt)
  const a = record(target, TYPE.A, 0x8001, 120, Buffer.from([192, 168, 1, 42]))
  const packet = Buffer.concat([header(0, 0x8400, 0, 1, 0, 3), ptr, srv, txtRecord, a])
  const decoded = decodePacket(packet)
  assert.equal(decoded.isResponse, true)
  assert.equal(decoded.answers[0].data, 'Chromecast-abc._googlecast._tcp.local')
  const [srvRecord, txtDecoded, aRecord] = decoded.additionals
  assert.equal(srvRecord.name, 'Chromecast-abc._googlecast._tcp.local')
  assert.equal(srvRecord.flush, true)
  assert.deepEqual(srvRecord.data, { priority: 0, weight: 0, port: 8009, target: 'abc.local' })
  assert.equal(txtDecoded.data.data.fn, 'Living Room TV')
  assert.equal(txtDecoded.data.data.rs, '')
  assert.equal(aRecord.data, '192.168.1.42')
  const device = deviceFromRecords(srvRecord.name, srvRecord.data, txtDecoded.data.data, aRecord.data)
  assert.deepEqual(device, { id: '1234abcd', name: 'Living Room TV', model: 'Chromecast', status: '', host: '192.168.1.42', port: 8009 })
})

test('decodeName rejects compression loops and truncated messages', () => {
  assert.throws(() => decodeName(Buffer.from([0xc0, 0]), 0), /loop/)
  assert.throws(() => decodePacket(Buffer.alloc(5)), /too short/)
  assert.throws(() => decodePacket(Buffer.concat([header(0, 0x8400, 0, 1, 0, 0), Buffer.from([3, 97])])))
})

test('deviceFromRecords falls back to the instance name and needs an address', () => {
  assert.equal(deviceFromRecords('x._googlecast._tcp.local', { port: 8009 }, {}, null), null)
  const device = deviceFromRecords('Google-Nest-Hub-0123456789abcdef0123456789abcdef._googlecast._tcp.local', { port: 8009 }, {}, '10.0.0.2')
  assert.equal(device.name, 'Google-Nest-Hub')
})

// --- Cast v2 ---
test('CastMessage round trip (string payload)', () => {
  const message = { source: 'sender-0', destination: 'receiver-0', namespace: 'urn:x-cast:com.google.cast.receiver', data: { type: 'GET_STATUS', requestId: 1 } }
  const decoded = decodeCastMessage(encodeCastMessage(message))
  assert.equal(decoded.source, 'sender-0')
  assert.equal(decoded.destination, 'receiver-0')
  assert.equal(decoded.namespace, message.namespace)
  assert.equal(decoded.payloadType, 0)
  assert.deepEqual(decoded.data, message.data)
})

test('CastMessage encodes long payloads with multi-byte varints and binary payloads', () => {
  const long = { type: 'LOAD', media: { contentId: 'x'.repeat(5000) } }
  assert.deepEqual(decodeCastMessage(encodeCastMessage({ source: 'a', destination: 'b', namespace: 'n', data: long })).data, long)
  const binary = decodeCastMessage(encodeCastMessage({ source: 'a', destination: 'b', namespace: 'n', data: Buffer.from([1, 2, 3]) }))
  assert.equal(binary.payloadType, 1)
  assert.deepEqual([...binary.data], [1, 2, 3])
})

test('CastMessage matches the reference protobuf bytes', () => {
  // protoc --encode of { protocol_version: 0, source_id: "s", destination_id: "d", namespace: "n", payload_type: STRING, payload_utf8: "{}" }
  const expected = Buffer.from('0800120173 1a0164 22016e 2800 32027b7d'.replace(/\s/g, ''), 'hex')
  assert.deepEqual(encodeCastMessage({ source: 's', destination: 'd', namespace: 'n', data: '{}' }), expected)
})

test('FrameParser splits and joins length-prefixed frames', () => {
  const a = frame({ source: 's', destination: 'd', namespace: 'n', data: { a: 1 } })
  const b = frame({ source: 's', destination: 'd', namespace: 'n', data: { b: 2 } })
  const all = Buffer.concat([a, b])
  const parser = new FrameParser()
  assert.equal(parser.push(all.subarray(0, 3)).length, 0)
  const first = parser.push(all.subarray(3, a.length + 5))
  assert.equal(first.length, 1)
  assert.deepEqual(decodeCastMessage(first[0]).data, { a: 1 })
  const second = parser.push(all.subarray(a.length + 5))
  assert.deepEqual(decodeCastMessage(second[0]).data, { b: 2 })
})

// --- HLS ---
const proxy = (url) => `http://192.168.1.10:5000/tok/p/${Buffer.from(url).toString('base64url')}`
const unproxy = (url) => Buffer.from(url.split('/p/')[1], 'base64url').toString()

test('isPlaylistStart detects M3U8 bytes (BOM, whitespace)', () => {
  assert.equal(isPlaylistStart(Buffer.from('#EXTM3U\n#EXT-X-VERSION:3')), true)
  assert.equal(isPlaylistStart(Buffer.from(String.fromCharCode(0xfeff) + '  #EXTM3U')), true)
  assert.equal(isPlaylistStart(Buffer.from([0x47, 0x40, 0x11])), false)
  assert.equal(isPlaylistStart(null), false)
})

test('rewritePlaylist proxies variants, segments, keys, maps and media renditions', () => {
  const master = [
    '#EXTM3U',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Japanese",URI="audio/jp.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,AUDIO="aac"',
    '720/index.m3u8?token=a b',
    '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=86000,URI="iframe.m3u8"',
    '',
    'https://other.cdn/1080.m3u8'
  ].join('\r\n')
  const out = rewritePlaylist(master, 'https://cdn.example/show/master.m3u8', proxy).split('\n')
  assert.equal(unproxy(out[1].match(/URI="([^"]+)"/)[1]), 'https://cdn.example/show/audio/jp.m3u8')
  assert.equal(out[2], '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,AUDIO="aac"')
  assert.equal(unproxy(out[3]), 'https://cdn.example/show/720/index.m3u8?token=a%20b')
  assert.equal(unproxy(out[4].match(/URI="([^"]+)"/)[1]), 'https://cdn.example/show/iframe.m3u8')
  assert.equal(out[5], '')
  assert.equal(unproxy(out[6]), 'https://other.cdn/1080.m3u8')
})

test('rewritePlaylist keeps data: and skd: keys, handles absolute paths and unquoted URIs', () => {
  const media = [
    '#EXTM3U',
    '#EXT-X-KEY:METHOD=AES-128,URI="/keys/k1.bin",IV=0x1234',
    '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm",KEYFORMAT="com.apple.streamingkeydelivery"',
    '#EXT-X-MAP:URI=init.mp4',
    '#EXTINF:6.0,',
    'seg-1.ts',
    '#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAAA"',
    '#EXT-X-ENDLIST'
  ].join('\n')
  const out = rewritePlaylist(media, 'https://cdn.example/a/b/index.m3u8', proxy).split('\n')
  assert.equal(unproxy(out[1].match(/URI="([^"]+)"/)[1]), 'https://cdn.example/keys/k1.bin')
  assert.match(out[1], /,IV=0x1234$/)
  assert.equal(out[2], '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm",KEYFORMAT="com.apple.streamingkeydelivery"')
  assert.equal(unproxy(out[3].match(/URI="([^"]+)"/)[1]), 'https://cdn.example/a/b/init.mp4')
  assert.equal(unproxy(out[5]), 'https://cdn.example/a/b/seg-1.ts')
  assert.equal(out[6], '#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAAA"')
  assert.equal(out[7], '#EXT-X-ENDLIST')
})

test('variantUrls lists the variants of a master playlist', () => {
  const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n#comment\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhttps://x.y/high.m3u8\n'
  assert.deepEqual(variantUrls(master, 'https://a.b/c/master.m3u8'), ['https://a.b/c/low.m3u8', 'https://x.y/high.m3u8'])
  assert.deepEqual(variantUrls('#EXTM3U\n#EXTINF:4,\nseg.ts', 'https://a.b/'), [])
})

test('segmentFormat picks fMP4, TS or raw audio for the receiver', () => {
  assert.deepEqual(segmentFormat('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\nseg1.m4s'), { segment: 'fmp4', video: 'fmp4' })
  assert.deepEqual(segmentFormat('#EXTM3U\n#EXTINF:4,\nseg1.m4s?x=1'), { segment: 'fmp4', video: 'fmp4' })
  assert.deepEqual(segmentFormat('#EXTM3U\n#EXTINF:4,\nseg1.ts'), { segment: 'ts', video: 'mpeg2_ts' })
  assert.deepEqual(segmentFormat('#EXTM3U\n#EXTINF:4,\nseg1.jpg'), { segment: 'ts', video: 'mpeg2_ts' })
  assert.deepEqual(segmentFormat('#EXTM3U\n#EXTINF:4,\naudio1.aac'), { segment: 'aac', video: null })
})

test('fileContentType trusts video types, else the extension', () => {
  assert.equal(fileContentType('video/webm; codecs=vp9', 'https://a/b'), 'video/webm')
  assert.equal(fileContentType('application/octet-stream', 'https://a/b/movie.mkv?x=1'), 'video/x-matroska')
  assert.equal(fileContentType('', 'https://a/b/file'), 'video/mp4')
})

test('resolveUri only keeps http(s) URLs', () => {
  assert.equal(resolveUri('../x.ts', 'https://a.b/c/d/e.m3u8'), 'https://a.b/c/x.ts')
  assert.equal(resolveUri('skd://key', 'https://a.b/'), null)
  assert.equal(resolveUri('', 'https://a.b/'), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
