// Navigation keys. Run with: node common/modules/navkeys.test.mjs
import assert from 'node:assert/strict'
import { navigationKeyDirection, isTypingTarget } from './navkeys.js'

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

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
