// Settings imported from the clipboard (Settings > App > Import from Clipboard), checked against the defaults before
// the app saves them and reloads. Pure functions (no imports, see settingsimport.test.mjs).

// Settings missing from the defaults (built at launch by settings.js), with a sample value of their shape.
const EXTRA_SETTINGS = { homeSections: [['', '', []]] }

/** @param {unknown} value */
function kind (value) {
  if (value === null || value === undefined) return 'none'
  if (Array.isArray(value)) return 'array'
  return typeof value
}

/**
 * The imported value has the shape of the default value: same type, finite numbers, list items like the default
 * list items (section lists: arrays starting with their title).
 * @param {unknown} value
 * @param {unknown} reference
 */
export function matchesDefault (value, reference) {
  const expected = kind(reference)
  if (expected === 'none') return true // no default to compare with (font, defaultExtension...)
  if (kind(value) !== expected) return false
  if (expected === 'number') return Number.isFinite(value)
  if (expected === 'array' && reference.length) {
    const sample = reference[0]
    return value.every(item => kind(item) === kind(sample) && (kind(sample) !== 'array' || typeof sample[0] !== 'string' || typeof item[0] === 'string'))
  }
  return true
}

/**
 * @param {unknown} imported Parsed clipboard JSON
 * @param {Record<string, any>} defaults Default settings (util.js)
 * @returns {{ settings: Record<string, any>, ignored: string[] }} The valid settings, and the keys left out
 * @throws {Error} When the data holds no setting at all
 */
export function validateImportedSettings (imported, defaults) {
  if (kind(imported) !== 'object') throw new Error('The copied data is not a settings object.')
  const reference = { ...EXTRA_SETTINGS, ...defaults }
  const settings = {}
  const ignored = []
  for (const [key, value] of Object.entries(imported)) {
    if (Object.hasOwn(reference, key) && matchesDefault(value, reference[key])) settings[key] = value
    else ignored.push(key)
  }
  if (!Object.keys(settings).length) throw new Error('The copied data holds no Tsumi setting.')
  return { settings, ignored }
}
