// Cross-device resume note line. Run with: node common/modules/sync/position.test.mjs
import assert from 'node:assert/strict'
import {
  formatClock, parseClock, cleanDevice, formatLine, parseLine, readPosition, stripPosition, withPosition,
  shouldOffer, needsWrite, positionLabel, MAX_CLOCK
} from './position.js'

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

const AT = Date.parse('2026-11-15T12:00:00Z')

test('formatClock / parseClock', () => {
  assert.equal(formatClock(0), '0:00')
  assert.equal(formatClock(754), '12:34')
  assert.equal(formatClock(754.9), '12:34')
  assert.equal(formatClock(3723), '1:02:03')
  assert.equal(formatClock(-5), '0:00')
  assert.equal(parseClock('12:34'), 754)
  assert.equal(parseClock('1:02:03'), 3723)
  assert.ok(Number.isNaN(parseClock('abc')))
  assert.ok(Number.isNaN(parseClock('12')))
})

test('clocks are capped at 99:59:59 (larger values from a hand-edited note are rejected)', () => {
  assert.equal(MAX_CLOCK, 359_999)
  assert.equal(formatClock(MAX_CLOCK), '99:59:59')
  assert.equal(formatClock(1e12), '99:59:59')
  assert.equal(formatClock(Infinity), '0:00')
  assert.equal(formatClock(NaN), '0:00')
  assert.equal(parseClock('99:59:59'), MAX_CLOCK)
  assert.ok(Number.isNaN(parseClock('100:00:00')))
  assert.ok(Number.isNaN(parseClock('99999999999999999999:00:00')))
  assert.ok(Number.isNaN(parseClock('6000:00')))
  assert.equal(parseLine('[Tsumi] Ep 3 · 123456789:00:00 · PC · 2026-11-15T12:00:00Z'), null)
  const line = parseLine('[Tsumi] Ep 3 · 12:00 / 999999:00:00 · PC · 2026-11-15T12:00:00Z')
  assert.equal(line.time, 720)
  assert.equal(line.duration, undefined)
  assert.equal(positionLabel({ percent: 250 }), '100%')
})

test('cleanDevice removes separators and line breaks', () => {
  assert.equal(cleanDevice('PC'), 'PC')
  assert.equal(cleanDevice('My · PC | x\nY'), 'My PC x Y')
  assert.equal(cleanDevice(''), 'Unknown')
  assert.equal(cleanDevice('a'.repeat(40)).length, 24)
})

test('formatLine writes the documented format', () => {
  assert.equal(formatLine({ episode: 5, time: 754, duration: 1420, device: 'PC', at: AT }), '[Tsumi] Ep 5 · 12:34 / 23:40 · PC · 2026-11-15T12:00:00Z')
  assert.equal(formatLine({ episode: 1, time: 3723, device: 'iPhone', at: AT + 999 }), '[Tsumi] Ep 1 · 1:02:03 · iPhone · 2026-11-15T12:00:00Z')
})

test('parseLine reads what formatLine writes', () => {
  const position = { episode: 12, time: 754, duration: 1420, device: 'iPhone', at: AT }
  assert.deepEqual(parseLine(formatLine(position)), position)
  assert.deepEqual(parseLine('[Tsumi] Ep 3 · 0:10 · PC · 2026-11-15T12:00:00Z'), { episode: 3, time: 10, device: 'PC', at: AT })
})

test('parseLine is lenient on separators, spaces and case', () => {
  assert.equal(parseLine('[tsumi] ep 5 | 12:34 / 23:40 | PC | 2026-11-15T12:00:00Z')?.time, 754)
  assert.equal(parseLine('  [Tsumi] Ep 5 • 12:34 • iPad • 2026-11-15T12:00:00.000Z  ')?.device, 'iPad')
  assert.equal(parseLine('[Tsumi]Ep 5·12:34·PC·2026-11-15T12:00:00Z')?.episode, 5)
})

test('parseLine rejects other lines', () => {
  assert.equal(parseLine('Great show'), null)
  assert.equal(parseLine('[Tsumi] Ep x · 12:34 · PC · 2026-11-15T12:00:00Z'), null)
  assert.equal(parseLine('[Tsumi] Ep 5 · 12:34 · PC · yesterday'), null)
  assert.equal(parseLine(''), null)
  assert.equal(parseLine(null), null)
})

test('readPosition finds our line among the user text, the newest when there are several', () => {
  const notes = 'Watched with friends\n[Tsumi] Ep 4 · 1:00 · PC · 2026-11-14T12:00:00Z\nmore text\n[Tsumi] Ep 5 · 2:00 · iPhone · 2026-11-15T12:00:00Z'
  assert.deepEqual(readPosition(notes), { episode: 5, time: 120, device: 'iPhone', at: AT })
  assert.equal(readPosition('just text'), null)
  assert.equal(readPosition(''), null)
  assert.equal(readPosition(undefined), null)
  assert.equal(readPosition('a\r\n[Tsumi] Ep 2 · 0:30 · PC · 2026-11-15T12:00:00Z\r\n')?.episode, 2)
})

test('withPosition keeps the user text and replaces only our line', () => {
  const position = { episode: 5, time: 754, device: 'PC', at: AT }
  assert.equal(withPosition('', position), '[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z')
  assert.equal(withPosition(null, position), '[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z')
  assert.equal(withPosition('My note\nline 2', position), 'My note\nline 2\n[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z')
  const twice = withPosition(withPosition('My note', { ...position, episode: 4 }), position)
  assert.equal(twice, 'My note\n[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z')
  assert.equal(withPosition('[Tsumi] broken line\nMine', position), 'Mine\n[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z')
})

test('withPosition(null) removes our line and leaves the user text as it was', () => {
  assert.equal(withPosition('My note\n[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z', null), 'My note')
  assert.equal(withPosition('[Tsumi] Ep 5 · 12:34 · PC · 2026-11-15T12:00:00Z', null), '')
  assert.equal(withPosition('Line 1\n\nLine 3', null), 'Line 1\n\nLine 3')
  assert.equal(stripPosition('A\n[Tsumi] Ep 1 · 0:01 · PC · 2026-11-15T12:00:00Z\nB'), 'A\nB')
})

test('shouldOffer only for the same episode, newer and far enough', () => {
  const remote = { episode: 5, time: 754, device: 'PC', at: AT }
  assert.equal(shouldOffer(remote, null, 5), true)
  assert.equal(shouldOffer(remote, undefined, 4), false)
  assert.equal(shouldOffer(remote, { currentTime: 100, updatedAt: AT - 60_000 }, 5), true)
  assert.equal(shouldOffer(remote, { currentTime: 100, updatedAt: AT + 1_000 }, 5), false) // local is newer
  assert.equal(shouldOffer(remote, { currentTime: 100, updatedAt: AT - 1_000 }, 5), false) // too close in time
  assert.equal(shouldOffer(remote, { currentTime: 750, updatedAt: AT - 60_000 }, 5), false) // same place
  assert.equal(shouldOffer({ ...remote, time: 0 }, null, 5), false)
  assert.equal(shouldOffer(null, null, 5), false)
})

test('needsWrite skips unchanged positions', () => {
  assert.equal(needsWrite(null, { episode: 1, time: 10 }), true)
  assert.equal(needsWrite({ episode: 1, time: 10 }, { episode: 1, time: 12 }), false)
  assert.equal(needsWrite({ episode: 1, time: 10 }, { episode: 1, time: 15 }), true)
  assert.equal(needsWrite({ episode: 1, time: 10 }, { episode: 2, time: 10 }), true)
})

test('positionLabel', () => {
  assert.equal(positionLabel({ time: 754 }), '12:34')
  assert.equal(positionLabel({ percent: 53.4 }), '53%')
  assert.equal(positionLabel({}), '0:00')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
