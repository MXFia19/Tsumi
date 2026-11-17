// Main process security helpers. Run with: node electron/src/main/security.test.mjs
import assert from 'node:assert/strict'
import { isExternalUrl, isWebUrl, isAppUrl, isLoopbackHost, protocolParams, isYouTubeId, redact } from './security.js'

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

test('isExternalUrl allows http(s) and mailto only', () => {
  assert.equal(isExternalUrl('https://anilist.co/anime/1'), true)
  assert.equal(isExternalUrl('http://example.com'), true)
  assert.equal(isExternalUrl('mailto:someone@example.com'), true)
  assert.equal(isExternalUrl('file:///C:/Windows/System32/calc.exe'), false)
  assert.equal(isExternalUrl('\\\\server\\share\\run.exe'), false)
  assert.equal(isExternalUrl('ms-settings:privacy'), false)
  assert.equal(isExternalUrl('search-ms:query=x'), false)
  assert.equal(isExternalUrl('javascript:alert(1)'), false)
  assert.equal(isExternalUrl('tsumi://anime/1'), false)
  assert.equal(isExternalUrl(''), false)
  assert.equal(isExternalUrl(undefined), false)
  assert.equal(isExternalUrl({ href: 'https://x' }), false)
})

test('isWebUrl allows http(s) only', () => {
  assert.equal(isWebUrl('https://cdn.example.com/a.m3u8'), true)
  assert.equal(isWebUrl('mailto:a@b.c'), false)
  assert.equal(isWebUrl('data:text/plain,hi'), false)
  assert.equal(isWebUrl('not a url'), false)
})

test('isAppUrl: the app page only, query and hash ignored, Windows drive letters without case', () => {
  const app = 'file:///C:/Program%20Files/Tsumi/resources/app.asar/build/app.html'
  assert.equal(isAppUrl(app, app), true)
  assert.equal(isAppUrl(`${app}#/settings`, app), true)
  assert.equal(isAppUrl('file:///c:/Program%20Files/Tsumi/resources/app.asar/build/app.html', app), true)
  assert.equal(isAppUrl('file:///C:/Program%20Files/Tsumi/resources/app.asar/build/other.html', app), false)
  assert.equal(isAppUrl('file:///C:/Users/me/evil.html', app), false)
  assert.equal(isAppUrl('https://evil.example/app.html', app), false)
  const dev = 'http://localhost:5000/app.html'
  assert.equal(isAppUrl('http://localhost:5000/app.html?x=1', dev), true)
  assert.equal(isAppUrl('http://localhost:5001/app.html', dev), false)
  assert.equal(isAppUrl('http://127.0.0.1:5000/app.html', dev), false)
  assert.equal(isAppUrl('', dev), false)
})

test('isLoopbackHost accepts localhost names on the port only (DNS rebinding)', () => {
  assert.equal(isLoopbackHost('localhost:4321', 4321), true)
  assert.equal(isLoopbackHost('127.0.0.1:4321', 4321), true)
  assert.equal(isLoopbackHost('[::1]:4321', 4321), true)
  assert.equal(isLoopbackHost('LOCALHOST:4321', 4321), true)
  assert.equal(isLoopbackHost('localhost:4322', 4321), false)
  assert.equal(isLoopbackHost('evil.example:4321', 4321), false)
  assert.equal(isLoopbackHost('localhost', 4321), false)
  assert.equal(isLoopbackHost(undefined, 4321), false)
  assert.equal(isLoopbackHost('localhost:4321', null), false)
})

test('protocolParams reads AniList fragments and MyAnimeList queries', () => {
  const al = protocolParams('access_token=eyJ0eXAi.abc-def_ghi&token_type=Bearer&expires_in=31536000')
  assert.equal(al.get('access_token'), 'eyJ0eXAi.abc-def_ghi')
  assert.equal(protocolParams('#access_token=tok&token_type=Bearer/').get('token_type'), 'Bearer')
  assert.equal(protocolParams('/#access_token=tok/').get('access_token'), 'tok')
  const mal = protocolParams('?code=def502abc&state=Ab-_.~9/')
  assert.equal(mal.get('code'), 'def502abc')
  assert.equal(mal.get('state'), 'Ab-_.~9')
  assert.equal(protocolParams('/?code=x&state=a%2Fb').get('state'), 'a/b')
  assert.equal(protocolParams('?code=a+b&state=s').get('code'), 'a+b')
})

test('protocolParams: a denied or empty sign-in has no credentials (no TypeError)', () => {
  const denied = protocolParams('?error=access_denied&message=The+user+denied&state=xyz')
  assert.equal(denied.get('code'), null)
  assert.equal(denied.get('error'), 'access_denied')
  assert.equal(protocolParams('').get('access_token'), null)
  assert.equal(protocolParams(undefined).get('access_token'), null)
})

test('isYouTubeId accepts 11 characters of [A-Za-z0-9_-] only', () => {
  assert.equal(isYouTubeId('dQw4w9WgXcQ'), true)
  assert.equal(isYouTubeId('a-b_c1234XY'), true)
  assert.equal(isYouTubeId("x'onload='1"), false)
  assert.equal(isYouTubeId('dQw4w9WgXc'), false)
  assert.equal(isYouTubeId('dQw4w9WgXcQQ'), false)
  assert.equal(isYouTubeId('<script>xx>'), false)
  assert.equal(isYouTubeId(undefined), false)
})

test('redact removes tokens and URL queries, keeps hosts and paths', () => {
  assert.equal(redact('Authorization: Bearer abc.DEF-123_x'), 'Authorization: Bearer [redacted]')
  assert.equal(redact('token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N'), 'token [redacted]')
  assert.equal(redact('refresh_token=abc123&x=1'), 'refresh_token=[redacted]&x=1')
  assert.equal(redact('{"access_token":"secret","user":"me"}'), '{"access_token":"[redacted]","user":"me"}')
  assert.equal(redact('GET https://cdn.example.com/hls/index.m3u8?token=abc&exp=1 failed'), 'GET https://cdn.example.com/hls/index.m3u8?[redacted] failed')
  assert.equal(redact('http://localhost:1234/abcd/proxy?url=https%3A%2F%2Fx&headers=%7B%7D'), 'http://localhost:1234/abcd/proxy?[redacted]')
  assert.equal(redact('see https://anilist.co/anime/1'), 'see https://anilist.co/anime/1')
  assert.equal(redact('https://addon.example/eyJkZWJyaWQiOiJrZXkifQ/manifest.json'), 'https://addon.example/[redacted]/manifest.json')
  assert.equal(redact('stremio://addon.example/realdebrid=KEY|sort=x/manifest.json'), 'stremio://addon.example/[redacted]/manifest.json')
  assert.equal(redact('https://addon.example/manifest.json'), 'https://addon.example/manifest.json')
  assert.equal(redact(''), '')
  assert.equal(redact(undefined), undefined)
})

test('redact removes the string values of JSON keys that name a secret', () => {
  assert.equal(
    redact('{"w2gTurnUrl":"turn:relay.example:3478","w2gTurnUsername":"me","w2gTurnCredential":"s3cr\\"et","volume":1}'),
    '{"w2gTurnUrl":"turn:relay.example:3478","w2gTurnUsername":"me","w2gTurnCredential":"[redacted]","volume":1}'
  )
  assert.equal(redact('{"password": "hunter2", "apiKey":"k-1", "clientSecret":"x", "refreshToken":"r"}'), '{"password": "[redacted]", "apiKey":"[redacted]", "clientSecret":"[redacted]", "refreshToken":"[redacted]"}')
  // JSON put in a string (a logged object that held a JSON text).
  assert.equal(redact('"{\\"debridKey\\":\\"abc\\",\\"name\\":\\"x\\"}"'), '"{\\"debridKey\\":\\"[redacted]\\",\\"name\\":\\"x\\"}"')
  // Objects, numbers and other keys stay.
  assert.equal(redact('{"keybinds":{"a":"b"},"tokenExpiry":123,"title":"Key Visual"}'), '{"keybinds":{"a":"b"},"tokenExpiry":123,"title":"Key Visual"}')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
