// persist.json store. Run with: node electron/src/main/store.test.mjs
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import Store, { writeAtomic } from './store.js'

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

const dir = mkdtempSync(join(tmpdir(), 'tsumi-store-'))

test('set writes the whole file through a temporary file that does not stay', () => {
  const store = new Store(dir, 'persist.json', { angle: 'default' })
  assert.equal(store.get('angle'), 'default')
  store.set('windowState', { isMaximized: true })
  store.set('rendererCrashes', [1, 2])
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'persist.json'), 'utf8')), { angle: 'default', windowState: { isMaximized: true }, rendererCrashes: [1, 2] })
  assert.equal(existsSync(join(dir, 'persist.json.tmp')), false)
  assert.deepEqual(new Store(dir, 'persist.json', { angle: 'default' }).get('rendererCrashes'), [1, 2])
})

test('a damaged file gives the defaults', () => {
  writeFileSync(join(dir, 'broken.json'), '{"angle": "d3d')
  assert.deepEqual(new Store(dir, 'broken.json', { angle: 'default' }).data, { angle: 'default' })
})

test('a failed write keeps the old file and does not throw', () => {
  writeAtomic(join(dir, 'kept.json'), '{"a":1}')
  // The temporary file name is taken by a folder: the write fails, the old file stays as it was.
  mkdirSync(join(dir, 'kept.json.tmp'))
  const warn = console.warn
  console.warn = () => {}
  try {
    writeAtomic(join(dir, 'kept.json'), '{"a":2}')
  } finally {
    console.warn = warn
  }
  assert.equal(readFileSync(join(dir, 'kept.json'), 'utf8'), '{"a":1}')
})

rmSync(dir, { recursive: true, force: true })
console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
