// Custom home sections, pure logic. Run with: node common/modules/homesections.test.mjs
import assert from 'node:assert/strict'
import { uniqueSectionTitle, renameHomeSection, removeHomeSection } from './homesections.js'

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

test('unique titles', () => {
  assert.equal(uniqueSectionTitle('Isekai', ['Romance']), 'Isekai')
  assert.equal(uniqueSectionTitle('  Isekai  ', []), 'Isekai')
  assert.equal(uniqueSectionTitle('New Section', ['New Section']), 'New Section 2')
  assert.equal(uniqueSectionTitle('New Section', ['New Section', 'New Section 2', 'New Section 3']), 'New Section 4')
  assert.equal(uniqueSectionTitle('', ['New Section']), 'New Section 2')
  assert.equal(uniqueSectionTitle(undefined, []), 'New Section')
  assert.equal(uniqueSectionTitle('Planning List', new Set(['Planning List'])), 'Planning List 2')
})

test('renaming keeps the section on Home, with its sort and format', () => {
  const home = [['Continue Watching', 'UPDATED_TIME_DESC', []], ['Anime - Romance', 'TRENDING_DESC', ['TV']]]
  assert.deepEqual(renameHomeSection(home, 'Anime - Romance', 'Romance'), [['Continue Watching', 'UPDATED_TIME_DESC', []], ['Romance', 'TRENDING_DESC', ['TV']]])
  assert.deepEqual(renameHomeSection(home, 'Missing', 'Other'), home)
  assert.deepEqual(renameHomeSection(undefined, 'a', 'b'), [])
})

test('removing a section takes it off Home', () => {
  const home = [['Continue Watching', 'UPDATED_TIME_DESC', []], ['Anime - Romance', 'TRENDING_DESC', ['TV']]]
  assert.deepEqual(removeHomeSection(home, 'Anime - Romance'), [['Continue Watching', 'UPDATED_TIME_DESC', []]])
  assert.deepEqual(removeHomeSection(home, 'Missing'), home)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
