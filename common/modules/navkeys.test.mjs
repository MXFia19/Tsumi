// Navigation keys. Run with: node common/modules/navkeys.test.mjs
import assert from 'node:assert/strict'
import { navigationKeyDirection, isTypingTarget, arrowKeyStaysInControl } from './navkeys.js'

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

test('Alt+Left / Alt+Right go back / forward', () => {
  assert.equal(navigationKeyDirection({ key: 'ArrowLeft', altKey: true }), 'back')
  assert.equal(navigationKeyDirection({ key: 'ArrowRight', altKey: true }), 'forward')
})

test('BrowserBack / BrowserForward keys, with or without modifiers', () => {
  assert.equal(navigationKeyDirection({ key: 'BrowserBack' }), 'back')
  assert.equal(navigationKeyDirection({ key: 'BrowserForward', shiftKey: true }), 'forward')
})

test('plain arrows (player seek, D-pad) and other chords are not navigation', () => {
  assert.equal(navigationKeyDirection({ key: 'ArrowLeft' }), null)
  assert.equal(navigationKeyDirection({ key: 'ArrowRight', altKey: true, ctrlKey: true }), null)
  assert.equal(navigationKeyDirection({ key: 'ArrowLeft', altKey: true, shiftKey: true }), null)
  assert.equal(navigationKeyDirection({ key: 'ArrowUp', altKey: true }), null)
  assert.equal(navigationKeyDirection({ key: 'ArrowLeft', altKey: true, repeat: true }), null)
  assert.equal(navigationKeyDirection(null), null)
})

test('text fields keep their keys, buttons and checkboxes do not', () => {
  assert.equal(isTypingTarget({ tagName: 'INPUT', type: 'text' }), true)
  assert.equal(isTypingTarget({ tagName: 'INPUT', type: 'search' }), true)
  assert.equal(isTypingTarget({ tagName: 'INPUT' }), true)
  assert.equal(isTypingTarget({ tagName: 'TEXTAREA' }), true)
  assert.equal(isTypingTarget({ tagName: 'SELECT' }), true)
  assert.equal(isTypingTarget({ tagName: 'DIV', isContentEditable: true }), true)
  assert.equal(isTypingTarget({ tagName: 'INPUT', type: 'checkbox' }), false)
  assert.equal(isTypingTarget({ tagName: 'INPUT', type: 'range' }), false)
  assert.equal(isTypingTarget({ tagName: 'BUTTON' }), false)
  assert.equal(isTypingTarget({ tagName: 'BODY' }), false)
  assert.equal(isTypingTarget(null), false)
})

test('a field clicked or tabbed into keeps ←/→, and ↑/↓ when they change its value', () => {
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown']) {
    assert.equal(arrowKeyStaysInControl({ tagName: 'SELECT' }, key), true)
    assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'range' }, key), true)
    assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'number' }, key), true)
    assert.equal(arrowKeyStaysInControl({ tagName: 'TEXTAREA', value: '', selectionStart: 0, selectionEnd: 0 }, key, false), true)
    assert.equal(arrowKeyStaysInControl({ tagName: 'DIV', isContentEditable: true }, key), true)
    assert.equal(arrowKeyStaysInControl({ tagName: 'BUTTON' }, key), false)
    assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'checkbox' }, key), false)
    assert.equal(arrowKeyStaysInControl({ tagName: 'DIV' }, key), false)
  }
  // One-line text fields: ←/→ move the caret (even at the end), ↑/↓ navigate.
  const search = { tagName: 'INPUT', type: 'search', value: 'abc', selectionStart: 3, selectionEnd: 3 }
  assert.equal(arrowKeyStaysInControl(search, 'ArrowLeft'), true)
  assert.equal(arrowKeyStaysInControl(search, 'ArrowRight'), true)
  assert.equal(arrowKeyStaysInControl(search, 'ArrowUp'), false)
  assert.equal(arrowKeyStaysInControl(search, 'ArrowDown'), false)
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT' }, 'ArrowDown'), false)
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'password' }, 'ArrowLeft'), true)
  assert.equal(arrowKeyStaysInControl(null, 'ArrowLeft'), false)
})

test('a field reached with the D-pad: ↑/↓ navigate, a select navigates, a range keeps ←/→', () => {
  const text = { tagName: 'INPUT', type: 'text', value: 'abc', selectionStart: 1, selectionEnd: 1 }
  assert.equal(arrowKeyStaysInControl(text, 'ArrowUp', true), false)
  assert.equal(arrowKeyStaysInControl(text, 'ArrowDown', true), false)
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown']) {
    assert.equal(arrowKeyStaysInControl({ tagName: 'SELECT' }, key, true), false)
  }
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'range' }, 'ArrowLeft', true), true)
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'range' }, 'ArrowRight', true), true)
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'range' }, 'ArrowUp', true), false)
})

test('a field reached with the D-pad: ←/→ move the caret, then leave at the start / end', () => {
  const at = (start, end = start) => ({ tagName: 'INPUT', type: 'search', value: 'abc', selectionStart: start, selectionEnd: end })
  assert.equal(arrowKeyStaysInControl(at(1), 'ArrowLeft', true), true)
  assert.equal(arrowKeyStaysInControl(at(1), 'ArrowRight', true), true)
  assert.equal(arrowKeyStaysInControl(at(0), 'ArrowLeft', true), false)
  assert.equal(arrowKeyStaysInControl(at(0), 'ArrowRight', true), true)
  assert.equal(arrowKeyStaysInControl(at(3), 'ArrowRight', true), false)
  assert.equal(arrowKeyStaysInControl(at(3), 'ArrowLeft', true), true)
  assert.equal(arrowKeyStaysInControl(at(0, 3), 'ArrowRight', true), true) // collapses the selection
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'url', value: '', selectionStart: 0, selectionEnd: 0 }, 'ArrowRight', true), false)
  // number fields have no caret API (selectionStart is null): they keep ←/→
  assert.equal(arrowKeyStaysInControl({ tagName: 'INPUT', type: 'number', value: '12', selectionStart: null, selectionEnd: null }, 'ArrowLeft', true), true)
  const throwing = { tagName: 'INPUT', type: 'email', value: 'a', get selectionStart () { throw new Error('InvalidStateError') } }
  assert.equal(arrowKeyStaysInControl(throwing, 'ArrowRight', true), true)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
