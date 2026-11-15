// Session token helpers. Run with: node common/modules/auth/token.test.mjs
import assert from 'node:assert/strict'
import { bareToken, sameToken, decodeTokenExpiry, tokenExpiryState, daysLeft, profileExpiry, isAniListAuthError, isMutationBody, EXPIRY_WARNING_DAYS } from './token.js'

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

const base64url = value => Buffer.from(JSON.stringify(value)).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const jwt = payload => `${base64url({ typ: 'JWT', alg: 'RS256' })}.${base64url(payload)}.signature`
const DAY = 24 * 60 * 60

test('bareToken and sameToken ignore the Bearer prefix', () => {
  assert.equal(bareToken('Bearer abc'), 'abc')
  assert.equal(bareToken('abc'), 'abc')
  assert.equal(bareToken(null), '')
  assert.equal(sameToken('Bearer abc', 'abc'), true)
  assert.equal(sameToken('abc', 'abd'), false)
  assert.equal(sameToken('', ''), false)
})

test('decodeTokenExpiry reads the JWT exp claim', () => {
  assert.equal(decodeTokenExpiry(jwt({ aud: '35971', exp: 1893456000 })), 1893456000)
  assert.equal(decodeTokenExpiry('Bearer ' + jwt({ exp: 1700000000.5 })), 1700000000.5)
  assert.equal(decodeTokenExpiry(jwt({ sub: '1' })), null)
  assert.equal(decodeTokenExpiry(jwt({ exp: 'soon' })), null)
  assert.equal(decodeTokenExpiry('not-a-jwt'), null)
  assert.equal(decodeTokenExpiry('a.!!!.c'), null)
  assert.equal(decodeTokenExpiry(''), null)
  // Payload with characters that need base64url decoding.
  assert.equal(decodeTokenExpiry(jwt({ name: '~~~???>>>', exp: 42 })), 42)
})

test('tokenExpiryState: expired, expiring within the warning window, valid, unknown', () => {
  const now = 1_000_000_000
  assert.equal(tokenExpiryState(null, now), 'unknown')
  assert.equal(tokenExpiryState(now - 1, now), 'expired')
  assert.equal(tokenExpiryState(now, now), 'expired')
  assert.equal(tokenExpiryState(now + DAY, now), 'expiring')
  assert.equal(tokenExpiryState(now + EXPIRY_WARNING_DAYS * DAY, now), 'expiring')
  assert.equal(tokenExpiryState(now + EXPIRY_WARNING_DAYS * DAY + 1, now), 'valid')
})

test('daysLeft rounds up and is at least 1', () => {
  const now = 1_000_000_000
  assert.equal(daysLeft(now + 10, now), 1)
  assert.equal(daysLeft(now + DAY + 1, now), 2)
  assert.equal(daysLeft(now + 3 * DAY, now), 3)
})

test('profileExpiry: saved expires_in first, then the token exp', () => {
  assert.equal(profileExpiry({ token: jwt({ exp: 100 }), expires_in: 200 }), 200)
  assert.equal(profileExpiry({ token: jwt({ exp: 100 }) }), 100)
  assert.equal(profileExpiry({ token: 'opaque' }), null)
  assert.equal(profileExpiry(null), null)
})

test('isAniListAuthError: 401 or an Invalid token error', () => {
  assert.equal(isAniListAuthError(401, null), true)
  assert.equal(isAniListAuthError(400, { errors: [{ message: 'Invalid token', status: 400 }] }), true)
  assert.equal(isAniListAuthError(200, { errors: [{ message: 'Unauthorized.', status: 401 }] }), true)
  assert.equal(isAniListAuthError(400, { errors: [{ message: 'Validation error', status: 400 }] }), false)
  assert.equal(isAniListAuthError(404, { errors: [{ message: 'Not Found.', status: 404 }] }), false)
  assert.equal(isAniListAuthError(200, { data: {} }), false)
})

test('isMutationBody detects mutations', () => {
  assert.equal(isMutationBody(JSON.stringify({ query: 'mutation($id:Int){DeleteMediaListEntry(id:$id){deleted}}' })), true)
  assert.equal(isMutationBody(JSON.stringify({ query: 'query{Viewer{id}}' })), false)
  assert.equal(isMutationBody(undefined), false)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
