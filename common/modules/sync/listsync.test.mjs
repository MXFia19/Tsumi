// Synced profile updates. Run with: node common/modules/sync/listsync.test.mjs
import assert from 'node:assert/strict'
import { automaticSync } from './listsync.js'

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

test('a title missing from the other profile is added (a rewatch here is a first watch there)', () => {
  assert.deepEqual(automaticSync(null, 'CURRENT', 3), { status: 'CURRENT' })
  assert.deepEqual(automaticSync(undefined, 'REPEATING', 3), { status: 'CURRENT' })
  assert.deepEqual(automaticSync(null, 'COMPLETED', 12), { status: 'COMPLETED' })
})

test('the progress of the other profile is never lowered', () => {
  assert.equal(automaticSync({ status: 'CURRENT', progress: 8 }, 'CURRENT', 5), null)
  assert.equal(automaticSync({ status: 'CURRENT', progress: 5 }, 'CURRENT', 5), null)
  assert.deepEqual(automaticSync({ status: 'CURRENT', progress: 4 }, 'CURRENT', 5), { status: 'CURRENT' })
  assert.deepEqual(automaticSync({ status: 'PLANNING', progress: 0 }, 'CURRENT', 1), { status: 'CURRENT' })
  assert.deepEqual(automaticSync({ status: 'PLANNING' }, 'CURRENT', 1), { status: 'CURRENT' })
})

test('a completed entry is not set back to watching', () => {
  assert.equal(automaticSync({ status: 'COMPLETED', progress: 12, repeat: 1 }, 'REPEATING', 3), null)
  assert.equal(automaticSync({ status: 'COMPLETED', progress: 2 }, 'CURRENT', 3), null)
})

test('a rewatch on the other profile stays a rewatch, its count only grows on completion', () => {
  assert.deepEqual(automaticSync({ status: 'REPEATING', progress: 2, repeat: 1 }, 'CURRENT', 3), { status: 'REPEATING' })
  assert.equal(automaticSync({ status: 'REPEATING', progress: 3, repeat: 1 }, 'CURRENT', 3), null)
  assert.deepEqual(automaticSync({ status: 'REPEATING', progress: 11, repeat: 1 }, 'COMPLETED', 12), { status: 'COMPLETED', repeat: 2 })
  assert.deepEqual(automaticSync({ status: 'REPEATING', progress: 11 }, 'COMPLETED', 12), { status: 'COMPLETED' })
  assert.deepEqual(automaticSync({ status: 'CURRENT', progress: 11, repeat: 4 }, 'COMPLETED', 12), { status: 'COMPLETED' })
})

test('completing sends no rewatch count for a first watch', () => {
  assert.deepEqual(automaticSync({ status: 'CURRENT', progress: 11 }, 'COMPLETED', 12), { status: 'COMPLETED' })
  assert.equal(automaticSync({ status: 'COMPLETED', progress: 12 }, 'COMPLETED', 12), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
