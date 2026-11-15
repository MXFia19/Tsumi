// Trakt sign-in (PKCE) helpers. Run with: node electron/src/main/traktAuth.test.mjs
import assert from 'node:assert/strict'
import { base64url, codeChallenge, createPkce, authorizeUrl, parseCallback, callbackErrorMessage, oauthErrorCode, TRAKT_REDIRECT_URI } from './traktAuth.js'

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

test('codeChallenge matches the S256 example of RFC 7636 (appendix B)', () => {
  assert.equal(codeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
})

test('base64url has no padding and no + or /', () => {
  assert.equal(base64url(Buffer.from([0xfb, 0xff, 0xfe])), '-__-')
  assert.equal(base64url(Buffer.from('a')), 'YQ')
})

test('createPkce: verifier of 43 unreserved characters, matching challenge, fresh every time', () => {
  const first = createPkce()
  const second = createPkce()
  assert.match(first.verifier, /^[A-Za-z0-9\-._~]{43,128}$/)
  assert.equal(first.challenge, codeChallenge(first.verifier))
  assert.match(first.state, /^[A-Za-z0-9_-]{32}$/)
  assert.notEqual(first.verifier, second.verifier)
  assert.notEqual(first.state, second.state)
})

test('authorizeUrl: auth.trakt.tv with the PKCE parameters and the redirect page', () => {
  const url = new URL(authorizeUrl({ clientId: 'abc123', state: 'state-value', challenge: 'chal' }))
  assert.equal(url.origin + url.pathname, 'https://auth.trakt.tv/oauth/authorize')
  assert.equal(url.searchParams.get('response_type'), 'code')
  assert.equal(url.searchParams.get('client_id'), 'abc123')
  assert.equal(url.searchParams.get('redirect_uri'), TRAKT_REDIRECT_URI)
  assert.equal(url.searchParams.get('state'), 'state-value')
  assert.equal(url.searchParams.get('code_challenge'), 'chal')
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256')
  assert.equal(url.searchParams.has('client_secret'), false)
  assert.equal(TRAKT_REDIRECT_URI, 'https://mxfia19.github.io/Tsumi/trakt/')
})

test('parseCallback: remainder given by protocol.js and full links', () => {
  assert.deepEqual(parseCallback('callback?code=c0de&state=st4te'), { code: 'c0de', state: 'st4te', error: '' })
  assert.deepEqual(parseCallback('tsumi://trakt/callback?code=c0de&state=st4te'), { code: 'c0de', state: 'st4te', error: '' })
  // Windows can add a trailing slash; a fragment is ignored; percent-encoding is decoded.
  assert.deepEqual(parseCallback('callback?code=c0de&state=st4te/'), { code: 'c0de', state: 'st4te', error: '' })
  assert.deepEqual(parseCallback('callback?state=a%2Bb&code=x%2By#frag'), { code: 'x+y', state: 'a+b', error: '' })
  assert.deepEqual(parseCallback('callback?error=access_denied&state=st4te'), { code: '', state: 'st4te', error: 'access_denied' })
})

test('parseCallback: nothing usable', () => {
  assert.equal(parseCallback('callback'), null)
  assert.equal(parseCallback('callback?state=only'), null)
  assert.equal(parseCallback(''), null)
  assert.equal(parseCallback(/** @type {any} */ (undefined)), null)
})

test('error messages never echo arbitrary text', () => {
  assert.equal(callbackErrorMessage('access_denied'), 'Access was denied on Trakt.')
  assert.equal(callbackErrorMessage('server_error'), 'Trakt could not sign you in (server_error), try again.')
  assert.equal(callbackErrorMessage('<b>x</b>'), 'Trakt could not sign you in (bxb), try again.')
  assert.equal(oauthErrorCode({ error: 'invalid_grant', error_description: 'session not found' }), 'invalid_grant')
  assert.equal(oauthErrorCode(null), '')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
