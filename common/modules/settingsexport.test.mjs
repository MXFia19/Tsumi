// Settings export and device info without private values. Run with: node common/modules/settingsexport.test.mjs
import assert from 'node:assert/strict'
import { exportableSettings, redactedSettings, withDeviceSettingsKept, DEVICE_SETTINGS } from './settingsexport.js'

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

const settings = {
  volume: 1,
  w2gTurnUrl: 'turns:turn.example.org:5349',
  w2gTurnUsername: 'someone',
  w2gTurnCredential: 'not-a-real-secret',
  extensions: {
    'Torrent-1.0.0': { url: 'https://addon.example.org/c2VjcmV0LWNvbmZpZw/manifest.json', enabled: true, manifest: { name: 'Torrent', version: '1.0.0' } },
    'Anime-2.1': { url: 'stremio://modules.example.net/private-token/anime.json', enabled: false, manifest: { sourceName: 'Anime', version: '2.1' } },
    broken: null
  },
  defaultExtension: 'Torrent-1.0.0',
  starredExtension: 'Anime-2.1'
}
const text = (value) => JSON.stringify(value)

test('export leaves out the TURN login and the extensions', () => {
  const exported = exportableSettings(settings)
  for (const key of DEVICE_SETTINGS) assert.equal(Object.hasOwn(exported, key), false, key)
  assert.equal(exported.volume, 1)
  assert.equal(exported.w2gTurnUrl, 'turns:turn.example.org:5349')
  assert.doesNotMatch(text(exported), /not-a-real-secret|someone|c2VjcmV0|private-token/)
  assert.equal(settings.w2gTurnCredential, 'not-a-real-secret') // the device's settings are untouched
  assert.deepEqual(exportableSettings(null), {})
})

test('device info hides the TURN login and keeps the extensions by name and host', () => {
  const info = redactedSettings(settings)
  assert.equal(info.w2gTurnUsername, '(hidden)')
  assert.equal(info.w2gTurnCredential, '(hidden)')
  assert.deepEqual(info.extensions['Torrent-1.0.0'], { host: 'addon.example.org', enabled: true, name: 'Torrent', version: '1.0.0' })
  assert.deepEqual(info.extensions['Anime-2.1'], { host: 'modules.example.net', enabled: false, name: 'Anime', version: '2.1' })
  assert.equal(info.extensions.broken.host, 'invalid address')
  assert.equal(info.defaultExtension, 'Torrent-1.0.0')
  assert.doesNotMatch(text(info), /not-a-real-secret|someone|c2VjcmV0|private-token|manifest\.json/)
  assert.equal(settings.extensions['Torrent-1.0.0'].url.includes('c2VjcmV0'), true) // untouched
  // Empty values stay empty (nothing to hide).
  assert.equal(redactedSettings({ w2gTurnCredential: '' }).w2gTurnCredential, '')
})

test('import keeps the device settings the export left out', () => {
  const imported = { volume: 0.5, w2gTurnUrl: '' }
  const merged = withDeviceSettingsKept(imported, settings)
  assert.equal(merged.volume, 0.5)
  assert.equal(merged.w2gTurnUrl, '')
  assert.equal(merged.w2gTurnCredential, 'not-a-real-secret')
  assert.deepEqual(merged.extensions, settings.extensions)
  assert.equal(merged.defaultExtension, 'Torrent-1.0.0')
  // An older export that has them still replaces them.
  assert.deepEqual(withDeviceSettingsKept({ extensions: {}, defaultExtension: null }, settings), { extensions: {}, defaultExtension: null, w2gTurnUsername: 'someone', w2gTurnCredential: 'not-a-real-secret', starredExtension: 'Anime-2.1' })
  assert.deepEqual(withDeviceSettingsKept({ volume: 1 }, null), { volume: 1 })
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
