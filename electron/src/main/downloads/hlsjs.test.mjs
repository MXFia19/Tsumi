// Pinned hls.js of the player. Run with: node electron/src/main/downloads/hlsjs.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { HLS_JS_URL, HLS_JS_SHA384, isPinnedHlsJs } from './hlsjs.js'

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

test('isPinnedHlsJs refuses anything but the pinned file', () => {
  assert.equal(isPinnedHlsJs(null), false)
  assert.equal(isPinnedHlsJs(Buffer.alloc(0)), false)
  assert.equal(isPinnedHlsJs(Buffer.from('window.Hls = function () {}')), false)
  assert.equal(isPinnedHlsJs('a'.repeat(400_000)), false)
})

test('the renderer pins the same file and hash (common/modules/streaming.js)', () => {
  const streaming = readFileSync(new URL('../../../../common/modules/streaming.js', import.meta.url), 'utf8')
  assert.ok(streaming.includes(`'${HLS_JS_URL}'`), 'HLS_JS_URL differs')
  assert.ok(streaming.includes(`'sha384-${HLS_JS_SHA384}'`), 'HLS_JS_INTEGRITY differs')
  assert.match(HLS_JS_URL, /^https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js@\d+\.\d+\.\d+\/dist\/hls\.min\.js$/)
  assert.equal(Buffer.from(HLS_JS_SHA384, 'base64').length, 48)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
