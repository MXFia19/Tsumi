// Keyboard back / forward through the app's own history (Shiru 6.9.0): Alt+Left / Alt+Right and the keyboard's
// BrowserBack / BrowserForward keys, wired by navigation.js next to the mouse back / forward buttons.
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
