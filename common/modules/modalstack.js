// Stack of the open modal layers (DetailsModal, the soft modals, the Year in Review). The top layer is the one drawn
// above the others: Esc closes it only, the D-pad (click.js) moves inside it only, focus moves into a layer when it
// opens and goes back where it was when it closes.
// No imports and no DOM access at load time: the stack logic is tested by modalstack.test.mjs.

/**
 * @typedef {Object} Layer
 * @property {any} node Root element of the layer
 * @property {number} priority Lower is drawn higher (navigation.js modal priorities)
 * @property {number} order Opening order, breaks priority ties (the last opened is on top)
 * @property {any} restore Element focused before the layer opened
 * @property {() => void} close Closes the layer (Esc)
 */

/** @type {Layer[]} */
const layers = []
let opened = 0

/**
 * The layer drawn on top: lowest priority, then the last opened.
 * @param {Layer[]} list
 * @returns {Layer | null}
 */
export function pickTop (list) {
  let top = null
  for (const layer of list) {
    if (!top || layer.priority < top.priority || (layer.priority === top.priority && layer.order > top.order)) top = layer
  }
  return top
}

/**
 * Adds a layer to a stack.
 * @param {Layer[]} list
 * @param {Omit<Layer, 'order'>} layer
 * @returns {Layer}
 */
export function addLayer (list, layer) {
  const added = { ...layer, order: ++opened }
  list.push(added)
  return added
}

/**
 * Removes a layer from a stack. The layers that opened from inside it take over its focus target: theirs is gone with
 * it (a notification opening the details, then closing).
 * @param {Layer[]} list
 * @param {Layer} layer
 * @returns {any} Element to give focus back to
 */
export function removeLayer (list, layer) {
  const index = list.indexOf(layer)
  if (index === -1) return null
  list.splice(index, 1)
  for (const other of list) {
    if (other.restore && layer.node?.contains?.(other.restore)) other.restore = layer.restore
  }
  return layer.restore
}

/** @returns {any} Root element of the top layer, null when no layer is open */
export function topLayer () {
  return pickTop(layers)?.node ?? null
}

/** @returns {boolean} A modal layer is open */
export function hasLayer () {
  return layers.length > 0
}

const NON_TEXT_INPUTS = new Set(['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'color', 'file', 'image'])
function isTyping (target) {
  if (!target || typeof target !== 'object') return false
  if (target.isContentEditable) return true
  const tag = String(target.tagName || '').toUpperCase()
  if (tag === 'TEXTAREA') return true
  return tag === 'INPUT' && !NON_TEXT_INPUTS.has(String(target.type || 'text').toLowerCase())
}

/**
 * Esc closes the top layer only. In a text field, the first Esc leaves the field (the search of the notifications...).
 * Handlers that use Esc themselves (a dropdown, a key capture) call preventDefault.
 * @param {KeyboardEvent} event
 */
function handleEscape (event) {
  if (event.key !== 'Escape' || event.defaultPrevented || event.isComposing) return
  const top = pickTop(layers)
  if (!top) return
  event.preventDefault()
  if (isTyping(event.target) && top.node.contains(event.target)) event.target.blur()
  else top.close()
}

const FOCUSABLE = 'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"], [disabled])'

/** Focus the control of a layer marked data-autofocus, else its first visible control, unless focus is already inside. */
function focusInside (node) {
  const active = document.activeElement
  if (active && active !== document.body && node.contains(active)) return
  for (const element of [...node.querySelectorAll('[data-autofocus]'), ...node.querySelectorAll(FOCUSABLE)]) {
    if (element.matches(':disabled') || element.checkVisibility?.({ visibilityProperty: true }) === false) continue
    element.focus({ preventScroll: true })
    if (document.activeElement === element) return
  }
}

// Focus goes back to where it was after keyboard / D-pad use only: with a mouse, the focused card would open its
// preview (cards preview on focus) although the pointer is elsewhere.
let keyboardUsed = false
let listening = false
function listen () {
  if (listening) return
  listening = true
  window.addEventListener('keydown', handleEscape)
  window.addEventListener('keydown', () => { keyboardUsed = true }, true)
  window.addEventListener('pointerdown', () => { keyboardUsed = false }, true)
}

/**
 * Svelte action of a modal layer root: `use:modalLayer={{ open, close, priority }}`.
 * @param {HTMLElement} node
 * @param {{ open?: boolean, close?: () => void, priority?: number }} params
 */
export function modalLayer (node, params = {}) {
  listen()
  /** @type {Layer | null} */
  let layer = null
  let close = params.close
  let focusFrame = null

  function open (priority) {
    layer = addLayer(layers, { node, priority: priority ?? 100, restore: document.activeElement, close: () => close?.() })
    // After the layer content rendered.
    cancelAnimationFrame(focusFrame)
    focusFrame = requestAnimationFrame(() => { if (layer) focusInside(node) })
  }

  function shut () {
    cancelAnimationFrame(focusFrame)
    const restore = removeLayer(layers, layer)
    layer = null
    // Back to where focus was, when focus is still in the closed layer (or lost) and the element is still shown.
    const active = document.activeElement
    if (!active || active === document.body || node.contains(active)) {
      if (keyboardUsed && restore?.isConnected && restore !== document.body) restore.focus({ preventScroll: true })
      else if (active && node.contains(active)) active.blur() // not left in a hidden layer
    }
  }

  function update ({ open: isOpen = false, close: nextClose, priority } = {}) {
    close = nextClose
    if (layer) layer.priority = priority ?? 100
    if (isOpen && !layer) open(priority)
    else if (!isOpen && layer) shut()
  }

  update(params)
  return {
    update,
    destroy () {
      if (layer) shut()
    }
  }
}
