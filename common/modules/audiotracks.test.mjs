// Audio tracks of the PC player, pure logic. Run with: node common/modules/audiotracks.test.mjs
import assert from 'node:assert/strict'
import { audioTrackLabel, audioTrackOptions, pickAudioTrack, audioLanguageCode } from './audiotracks.js'

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

// A movie stream with French and original audio (EXT-X-MEDIA TYPE=AUDIO renditions as hls.js lists them).
const vfvo = [{ name: 'VF', lang: 'fr' }, { name: 'VO', lang: 'en' }]

test('audioLanguageCode reads 2 and 3 letter codes', () => {
  assert.equal(audioLanguageCode('fre'), 'fr')
  assert.equal(audioLanguageCode('fra'), 'fr')
  assert.equal(audioLanguageCode('fr-FR'), 'fr')
  assert.equal(audioLanguageCode('jpn'), 'ja')
  assert.equal(audioLanguageCode('ja'), 'ja')
  assert.equal(audioLanguageCode(''), '')
  assert.equal(audioLanguageCode(undefined), '')
})

test('audioTrackLabel adds the language the name does not say', () => {
  assert.equal(audioTrackLabel({ name: 'VF', lang: 'fr' }, 0), 'VF (French)')
  assert.equal(audioTrackLabel({ name: 'English', lang: 'en' }, 0), 'English')
  assert.equal(audioTrackLabel({ name: 'Main (en)', lang: 'en' }, 0), 'Main (en)')
  assert.equal(audioTrackLabel({ name: '', lang: 'jpn' }, 0), 'Japanese')
  assert.equal(audioTrackLabel({ name: 'Audio 2' }, 1), 'Audio 2')
  assert.equal(audioTrackLabel({}, 1), 'Track 2')
})

test('audioTrackOptions keeps the stream order', () => {
  assert.deepEqual(audioTrackOptions(vfvo), [{ index: 0, label: 'VF (French)' }, { index: 1, label: 'VO (English)' }])
  assert.deepEqual(audioTrackOptions(null), [])
})

test('pickAudioTrack: remembered track first', () => {
  assert.equal(pickAudioTrack(vfvo, { remembered: { name: 'VO', lang: 'en' }, preferred: 'fre' }), 1)
  // Same language under another name (another server).
  assert.equal(pickAudioTrack([{ name: 'Français', lang: 'fre' }, { name: 'Anglais', lang: 'eng' }], { remembered: { name: 'VO', lang: 'en' } }), 1)
  // Tracks without language: same name.
  assert.equal(pickAudioTrack([{ name: 'VF' }, { name: 'VOSTFR' }], { remembered: { name: 'vostfr' } }), 1)
})

test('pickAudioTrack: then the preferred language, then Japanese, else the default', () => {
  assert.equal(pickAudioTrack(vfvo, { preferred: 'fre' }), 0)
  assert.equal(pickAudioTrack(vfvo, { preferred: 'eng' }), 1)
  assert.equal(pickAudioTrack([{ name: 'English', lang: 'en' }, { name: 'Japanese', lang: 'ja' }], { preferred: 'fre' }), 1)
  assert.equal(pickAudioTrack(vfvo, { preferred: 'jpn' }), -1)
  assert.equal(pickAudioTrack(vfvo, { remembered: { name: 'VA', lang: 'de' }, preferred: 'ger' }), -1)
  assert.equal(pickAudioTrack([{ name: 'VF', lang: 'fr' }], { preferred: 'fre' }), -1)
  assert.equal(pickAudioTrack(null), -1)
})

test('pickAudioTrack: Latin American Spanish before Spain', () => {
  const spanish = [{ name: 'Castellano', lang: 'es-ES' }, { name: 'Latino', lang: 'es-419' }, { name: 'English', lang: 'en' }]
  assert.equal(pickAudioTrack(spanish, { preferred: 'lat' }), 1)
  assert.equal(pickAudioTrack(spanish, { preferred: 'spa' }), 0)
  assert.equal(pickAudioTrack([{ name: 'Castellano', lang: 'es' }, { name: 'English', lang: 'en' }], { preferred: 'lat' }), 0)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
