// Settings import check, pure logic. Run with: node common/modules/settingsimport.test.mjs
import assert from 'node:assert/strict'
import { validateImportedSettings, matchesDefault } from './settingsimport.js'

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

const defaults = {
  volume: 1,
  adult: 'none',
  playerAutoplay: true,
  releasesNotify: [],
  spoilerStatus: ['CURRENT', 'REPEATING'],
  customSections: [['Anime - Romance', ['Romance'], [], [], []]],
  extensions: {},
  font: undefined,
  defaultExtension: null
}

test('keeps the settings shaped like their default', () => {
  const imported = { volume: 0.5, adult: 'hentai', playerAutoplay: false, releasesNotify: ['CURRENT'], customSections: [['Mine', [], [], [], []]], extensions: { a: {} }, font: { name: 'x' }, defaultExtension: 'key' }
  const { settings, ignored } = validateImportedSettings(imported, defaults)
  assert.deepEqual(settings, imported)
  assert.deepEqual(ignored, [])
})

test('leaves out unknown keys and wrong types', () => {
  const { settings, ignored } = validateImportedSettings({ volume: '1', adult: 'none', unknown: 1, playerAutoplay: 'yes', spoilerStatus: [1], customSections: [[1]], extensions: [] }, defaults)
  assert.deepEqual(settings, { adult: 'none' })
  assert.deepEqual(ignored.sort(), ['customSections', 'extensions', 'playerAutoplay', 'spoilerStatus', 'unknown', 'volume'])
})

test('home sections are accepted although they are not in the defaults', () => {
  const homeSections = [['Continue Watching', 'UPDATED_TIME_DESC', []]]
  assert.deepEqual(validateImportedSettings({ homeSections }, defaults).settings, { homeSections })
  assert.throws(() => validateImportedSettings({ homeSections: ['Continue Watching'] }, defaults))
})

test('numbers must be finite, prototype keys are not settings', () => {
  assert.equal(matchesDefault(Infinity, 1), false)
  assert.equal(matchesDefault(NaN, 1), false)
  const { ignored } = validateImportedSettings(JSON.parse('{"volume": 1, "toString": "x", "__proto__": {"volume": 2}}'), defaults)
  assert.deepEqual(ignored.sort(), ['__proto__', 'toString'])
})

test('rejects data that is not settings', () => {
  assert.throws(() => validateImportedSettings(null, defaults))
  assert.throws(() => validateImportedSettings([1, 2], defaults))
  assert.throws(() => validateImportedSettings('settings', defaults))
  assert.throws(() => validateImportedSettings({ other: true }, defaults))
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
