// Right-click menu entries. Run with: node electron/src/main/contextMenuTemplate.test.mjs
import assert from 'node:assert/strict'
import { contextMenuEntries, isWebLink } from './contextMenuTemplate.js'

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

const PAGE = 'file:///C:/Program%20Files/Tsumi/resources/app.asar/build/app.html'
const labels = entries => entries.map(entry => entry.type === 'separator' ? '-' : entry.role || entry.label)

test('nothing to offer: no menu', () => {
  assert.deepEqual(contextMenuEntries({ pageURL: PAGE, mediaType: 'none', selectionText: '' }), [])
  assert.deepEqual(contextMenuEntries({ pageURL: PAGE, selectionText: '   ' }), [])
})

test('text field: cut / copy / paste / select all with the edit flags', () => {
  const entries = contextMenuEntries({ pageURL: PAGE, isEditable: true, editFlags: { canCut: false, canCopy: false, canPaste: true, canSelectAll: true } })
  assert.deepEqual(labels(entries), ['cut', 'copy', 'paste', 'selectAll'])
  assert.equal(entries[0].enabled, false)
  assert.equal(entries[2].enabled, true)
})

test('misspelled word: suggestions first', () => {
  const entries = contextMenuEntries({ pageURL: PAGE, isEditable: true, editFlags: {}, misspelledWord: 'animw', dictionarySuggestions: ['anime', 'animal'] })
  assert.deepEqual(labels(entries), ['anime', 'animal', '-', 'cut', 'copy', 'paste', 'selectAll'])
  assert.equal(entries[0].action, 'replaceMisspelling')
  assert.equal(entries[0].value, 'anime')
})

test('selected text: copy only', () => {
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE, selectionText: 'Frieren', editFlags: { canCopy: true } })), ['copy'])
})

test('web link: copy / open, app anchors and other schemes are ignored', () => {
  const entries = contextMenuEntries({ pageURL: PAGE, linkURL: 'https://anilist.co/anime/1' })
  assert.deepEqual(labels(entries), ['Copy Link', 'Open Link in Browser'])
  assert.equal(entries[1].value, 'https://anilist.co/anime/1')
  assert.equal(isWebLink(PAGE + '#', PAGE), false)
  assert.equal(isWebLink('http://localhost:5000/app.html#top', 'http://localhost:5000/app.html'), false)
  assert.equal(isWebLink('javascript:void(0)', PAGE), false)
  assert.equal(isWebLink('tsumi://w2g/abc', PAGE), false)
  assert.equal(isWebLink('', PAGE), false)
  assert.equal(isWebLink('not a url', PAGE), false)
})

test('image: copy image and its address (web addresses only)', () => {
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE, mediaType: 'image', hasImageContents: true, srcURL: 'https://s4.anilist.co/cover.jpg' })), ['Copy Image', 'Copy Image Address'])
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE, mediaType: 'image', hasImageContents: true, srcURL: 'data:image/png;base64,AAAA' })), ['Copy Image'])
})

test('link around an image with a selection: groups separated', () => {
  const entries = contextMenuEntries({ pageURL: PAGE, selectionText: 'x', linkURL: 'https://myanimelist.net/', mediaType: 'image', hasImageContents: true, srcURL: 'https://a/b.png' })
  assert.deepEqual(labels(entries), ['copy', '-', 'Copy Link', 'Open Link in Browser', '-', 'Copy Image', 'Copy Image Address'])
})

test('Inspect only when allowed, last', () => {
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE }, { inspect: true })), ['Inspect'])
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE, selectionText: 'x' }, { inspect: true })), ['copy', '-', 'Inspect'])
  assert.deepEqual(labels(contextMenuEntries({ pageURL: PAGE, selectionText: 'x' })), ['copy'])
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
