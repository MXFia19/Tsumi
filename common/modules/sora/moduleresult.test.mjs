// Module results opened as they are, pure logic. Run with: node common/modules/sora/moduleresult.test.mjs
import assert from 'node:assert/strict'
import { linksResults, moduleEpisodes, moduleDetails, episodeLabel, playableMedia, episodeFor } from './moduleresult.js'

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

test('linksResults: on unless turned off', () => {
  assert.equal(linksResults(undefined), true)
  assert.equal(linksResults({ enabled: true }), true)
  assert.equal(linksResults({ linkResults: true }), true)
  assert.equal(linksResults({ linkResults: false }), false)
})

test('moduleEpisodes: links once, numbers kept or given by place', () => {
  const raw = JSON.stringify([
    { href: 'https://v.example/1', number: 1 },
    { href: 'https://v.example/1', number: 1 },
    { href: ' https://v.example/2 ', number: '2', title: 'Second' },
    { href: '', number: 3 },
    { number: 4 },
    { href: 'https://v.example/x', number: 'abc' }
  ])
  assert.deepEqual(moduleEpisodes(raw), [
    { href: 'https://v.example/1', number: 1, title: '' },
    { href: 'https://v.example/2', number: 2, title: 'Second' },
    { href: 'https://v.example/x', number: 3, title: '' }
  ])
  assert.deepEqual(moduleEpisodes('not json'), [])
  assert.deepEqual(moduleEpisodes({ href: 'x' }), [])
  assert.deepEqual(moduleEpisodes(null), [])
})

test('moduleDetails: description and air date, placeholders dropped', () => {
  assert.deepEqual(moduleDetails([{ description: ' A stream ', airdate: '2026-11-17', aliases: 'x' }]), { description: 'A stream', airdate: '2026-11-17' })
  assert.deepEqual(moduleDetails(JSON.stringify({ description: 'Text', airdate: 'N/A' })), { description: 'Text', airdate: '' })
  assert.deepEqual(moduleDetails('broken'), { description: '', airdate: '' })
  assert.deepEqual(moduleDetails(null), { description: '', airdate: '' })
})

test('episodeLabel', () => {
  assert.equal(episodeLabel({ number: 1, title: '' }, 1), 'Play')
  assert.equal(episodeLabel({ number: 3, title: '' }, 5), 'Episode 3')
  assert.equal(episodeLabel({ number: 3, title: 'The Return' }, 5), 'Episode 3 - The Return')
  assert.equal(episodeLabel({ number: 3, title: 'Episode 3' }, 5), 'Episode 3')
})

test('playableMedia: highest whole episode number', () => {
  const media = { id: 'sora-a-b', isSora: true }
  assert.equal(playableMedia(media, [{ number: 1 }, { number: 12 }, { number: 2.5 }]).episodes, 12)
  assert.equal(playableMedia(media, [{ number: 0 }]).episodes, null)
  assert.equal(playableMedia(media, []).episodes, null)
  assert.equal(playableMedia(media, [{ number: 1 }]).isSora, true)
})

test('episodeFor: exact number only', () => {
  const episodes = [{ number: 1, href: 'a' }, { number: 2, href: 'b' }]
  assert.equal(episodeFor(episodes, 2).href, 'b')
  assert.equal(episodeFor(episodes, '1').href, 'a')
  assert.equal(episodeFor(episodes, 3), null)
  assert.equal(episodeFor([{ number: 5, href: 'only' }], 4), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
