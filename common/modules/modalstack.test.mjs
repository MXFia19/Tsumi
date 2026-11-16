// Modal layer stack, pure logic. Run with: node common/modules/modalstack.test.mjs
import assert from 'node:assert/strict'
import { pickTop, addLayer, removeLayer } from './modalstack.js'

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

/** Minimal element: contains() follows the children given. */
function node (name, children = []) {
  const element = { name }
  element.contains = (other) => other === element || children.some(child => child === other || child.contains?.(other))
  return element
}

test('the top layer is the lowest priority, then the last opened', () => {
  const list = []
  assert.equal(pickTop(list), null)
  const details = addLayer(list, { node: node('details'), priority: 9, restore: null, close () {} })
  assert.equal(pickTop(list), details)
  const notifications = addLayer(list, { node: node('notifications'), priority: 5, restore: null, close () {} })
  assert.equal(pickTop(list), notifications)
  // Opened later but drawn below (a trailer opening in the same update as its details).
  addLayer(list, { node: node('trailer'), priority: 8, restore: null, close () {} })
  assert.equal(pickTop(list), notifications)
  const other = addLayer(list, { node: node('other'), priority: 5, restore: null, close () {} })
  assert.equal(pickTop(list), other)
})

test('removing a layer gives its focus target back', () => {
  const list = []
  const button = { name: 'card' }
  const layer = addLayer(list, { node: node('details'), priority: 9, restore: button, close () {} })
  assert.equal(removeLayer(list, layer), button)
  assert.equal(list.length, 0)
  assert.equal(removeLayer(list, layer), null)
})

test('a layer opened from inside a closing layer takes over its focus target', () => {
  const list = []
  const bell = { name: 'bell' }
  const item = { name: 'notification item' }
  const notifications = addLayer(list, { node: node('notifications', [item]), priority: 5, restore: bell, close () {} })
  const details = addLayer(list, { node: node('details'), priority: 9, restore: item, close () {} })
  removeLayer(list, notifications)
  assert.equal(details.restore, bell)
  assert.equal(pickTop(list), details)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
