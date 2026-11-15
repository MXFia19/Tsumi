// Right-click menu (Shiru 6.9.0, #32): the entries for what was right-clicked. Pure helpers of contextMenu.js,
// tested by contextMenuTemplate.test.mjs.

/**
 * Subset of the params of Electron's webContents `context-menu` event.
 * @typedef {Object} ContextMenuParams
 * @property {boolean} [isEditable]
 * @property {{ canCut?: boolean, canCopy?: boolean, canPaste?: boolean, canSelectAll?: boolean }} [editFlags]
 * @property {string} [selectionText]
 * @property {string} [linkURL]
 * @property {string} [srcURL]
 * @property {string} [mediaType]
 * @property {boolean} [hasImageContents]
 * @property {string} [misspelledWord]
 * @property {string[]} [dictionarySuggestions]
 * @property {string} [pageURL]
 */

/**
 * A menu role (the focused web contents does it), an action of contextMenu.js, or a separator.
 * @typedef {{ type: 'separator' } | { role: 'cut' | 'copy' | 'paste' | 'selectAll', enabled?: boolean } | { label: string, action: 'replaceMisspelling' | 'copyLink' | 'openLink' | 'copyImage' | 'copyImageAddress' | 'inspect', value?: string }} ContextMenuEntry
 */

/**
 * An http(s) link to another page (not an anchor of the page itself, like the app's href='#' links).
 * @param {string | undefined} url
 * @param {string | undefined} pageURL
 */
export function isWebLink (url, pageURL) {
  if (!url) return false
  try {
    const link = new URL(url)
    if (link.protocol !== 'http:' && link.protocol !== 'https:') return false
    if (!pageURL) return true
    const page = new URL(pageURL)
    link.hash = ''
    page.hash = ''
    return link.href !== page.href
  } catch {
    return false
  }
}

/**
 * Entries for a right-click: edit actions in a text field, Copy on selected text, link and image actions, Inspect.
 * @param {ContextMenuParams} params
 * @param {{ inspect?: boolean }} [options] inspect: devtools are allowed (development, or opened from the settings)
 * @returns {ContextMenuEntry[]} empty: no menu
 */
export function contextMenuEntries (params, { inspect = false } = {}) {
  /** @type {ContextMenuEntry[][]} */
  const groups = []
  const flags = params.editFlags || {}
  if (params.isEditable) {
    const suggestions = params.misspelledWord ? (params.dictionarySuggestions || []).slice(0, 5) : []
    if (suggestions.length) groups.push(suggestions.map(word => ({ label: word, action: 'replaceMisspelling', value: word })))
    groups.push([
      { role: 'cut', enabled: !!flags.canCut },
      { role: 'copy', enabled: !!flags.canCopy },
      { role: 'paste', enabled: !!flags.canPaste },
      { role: 'selectAll', enabled: flags.canSelectAll !== false }
    ])
  } else if (params.selectionText?.trim()) {
    groups.push([{ role: 'copy', enabled: flags.canCopy !== false }])
  }
  if (isWebLink(params.linkURL, params.pageURL)) {
    groups.push([
      { label: 'Copy Link', action: 'copyLink', value: params.linkURL },
      { label: 'Open Link in Browser', action: 'openLink', value: params.linkURL }
    ])
  }
  if (params.mediaType === 'image') {
    /** @type {ContextMenuEntry[]} */
    const image = []
    if (params.hasImageContents) image.push({ label: 'Copy Image', action: 'copyImage' })
    if (/^https?:\/\//i.test(params.srcURL || '')) image.push({ label: 'Copy Image Address', action: 'copyImageAddress', value: params.srcURL })
    if (image.length) groups.push(image)
  }
  if (inspect) groups.push([{ label: 'Inspect', action: 'inspect' }])
  return groups.flatMap((group, index) => index ? [{ type: 'separator' }, ...group] : group)
}
