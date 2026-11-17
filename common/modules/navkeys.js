// Keyboard back / forward through the app's own history (Shiru 6.9.0): Alt+Left / Alt+Right and the keyboard's
// BrowserBack / BrowserForward keys, wired by navigation.js next to the mouse back / forward buttons. Also which
// arrow keys the D-pad navigation of click.js leaves to text fields, selects and ranges.
// Pure functions (no imports, see navkeys.test.mjs).

const NON_TEXT_INPUTS = new Set(['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'color', 'file', 'image'])

/**
 * @param {{ key?: string, altKey?: boolean, ctrlKey?: boolean, shiftKey?: boolean, metaKey?: boolean, repeat?: boolean, isComposing?: boolean } | null | undefined} event keydown
 * @returns {'back' | 'forward' | null}
 */
export function navigationKeyDirection (event) {
  if (!event || event.repeat || event.isComposing) return null
  if (event.key === 'BrowserBack') return 'back'
  if (event.key === 'BrowserForward') return 'forward'
  if (!event.altKey || event.ctrlKey || event.shiftKey || event.metaKey) return null
  if (event.key === 'ArrowLeft') return 'back'
  if (event.key === 'ArrowRight') return 'forward'
  return null
}

/**
 * The key goes to a field that takes text (the keys are the user's typing, not navigation).
 * @param {any} target keydown target
 */
export function isTypingTarget (target) {
  if (!target || typeof target !== 'object') return false
  if (target.isContentEditable) return true
  const tag = String(target.tagName || '').toUpperCase()
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true
  if (tag !== 'INPUT') return false
  return !NON_TEXT_INPUTS.has(String(target.type || 'text').toLowerCase())
}

/** Controls whose ↑/↓ change something (value, line): kept by a field the user clicked or tabbed into. */
const VERTICAL_CONTROLS = new Set(['number', 'range'])

/**
 * An arrow key pressed on this control is left to it (caret, value) instead of the D-pad navigation (click.js).
 * A field the user clicked or tabbed into keeps ←/→ (caret, value), and ↑/↓ when they change something: selects,
 * ranges, number fields, textareas. In a one-line text field ↑/↓ still navigate (from the Genres field down to its
 * options, to the next settings row).
 * A field the D-pad itself moved to keeps navigating, since a remote has no Tab key to leave it (↓ on a select of a
 * settings list must reach the next row, not change the value): only ←/→ stay in the control there, to change a
 * range, or to move the caret of a text field until its start / end, where the next press leaves the field.
 * @param {any} target keydown target
 * @param {string} key 'ArrowLeft' | 'ArrowRight' | 'ArrowUp' | 'ArrowDown'
 * @param {boolean} [dpadFocused] the D-pad moved the focus to this control
 */
export function arrowKeyStaysInControl (target, key, dpadFocused = false) {
  if (!target || typeof target !== 'object') return false
  const tag = String(target.tagName || '').toUpperCase()
  const type = String(target.type || 'text').toLowerCase()
  const horizontal = key === 'ArrowLeft' || key === 'ArrowRight'
  if (tag === 'INPUT' && type === 'range') return !dpadFocused || horizontal
  if (!isTypingTarget(target)) return false
  if (!dpadFocused) return horizontal || tag !== 'INPUT' || VERTICAL_CONTROLS.has(type)
  if (!horizontal || tag === 'SELECT') return false
  let start = null
  let end = null
  try {
    start = target.selectionStart
    end = target.selectionEnd
  } catch {}
  // No caret API (number, email, contenteditable): the field keeps ←/→.
  if (typeof start !== 'number' || typeof end !== 'number') return true
  if (start !== end) return true // the arrow collapses the selection first
  return key === 'ArrowLeft' ? start > 0 : end < String(target.value ?? '').length
}
