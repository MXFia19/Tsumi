// List request error text, pure logic. Run with: node common/modules/requesterror.test.mjs
import assert from 'node:assert/strict'
import { requestErrorText } from './requesterror.js'

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

const codes = { 401: 'Unauthorized', 429: 'Too Many Requests', 500: 'Internal Server Error' }

test('AniList GraphQL errors', () => {
  assert.equal(requestErrorText({ data: null, errors: [{ message: 'Session expired', status: 401 }] }, codes), '401 - Unauthorized: Session expired')
  assert.equal(requestErrorText({ errors: [{ message: 'validation' }, { message: 'validation' }, { message: 'other' }] }, codes), 'validation, other')
  assert.equal(requestErrorText({ errors: [{ message: ['Title', 'Detail'] }] }, codes), 'Title Detail')
  assert.equal(requestErrorText({ errors: [{}] }, codes), 'Unknown error.')
})

test('HTTP responses and thrown errors', () => {
  assert.equal(requestErrorText({ status: 429, statusText: 'Too Many Requests', ok: false }, codes), '429 - Too Many Requests')
  assert.equal(requestErrorText({ status: 418, statusText: 'I am a teapot' }, codes), '418 - I am a teapot')
  assert.equal(requestErrorText(new Error('AniList API is temporarily disabled or network is offline'), codes), 'AniList API is temporarily disabled or network is offline')
  assert.equal(requestErrorText(new TypeError('Failed to fetch')), 'Failed to fetch')
})

test('MyAnimeList errors and empty answers', () => {
  assert.equal(requestErrorText({ error: 'invalid_token', message: 'token is invalid' }, codes), 'token is invalid')
  assert.equal(requestErrorText({ error: 'not_found' }, codes), 'not_found')
  assert.equal(requestErrorText(null, codes), 'No response from the server.')
  assert.equal(requestErrorText({}, codes), 'The server answered without the change.')
  assert.equal(requestErrorText('offline'), 'offline')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
