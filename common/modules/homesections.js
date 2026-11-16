// Custom home sections (Settings > Interface > Anime / Western Sections) and the home layout (settings.homeSections:
// [title, sort, format] entries naming the sections by title). Pure functions (no imports, see homesections.test.mjs).

/**
 * A section title nobody uses yet: the name (trimmed, the fallback when empty), followed by 2, 3... when taken.
 * Two sections with one title collide: Home shows one of them.
 * @param {unknown} name
 * @param {Iterable<string>} taken Titles of the other sections
 * @param {string} [fallback]
 * @returns {string}
 */
export function uniqueSectionTitle (name, taken, fallback = 'New Section') {
  const base = String(name ?? '').trim() || fallback
  const used = new Set(taken)
  if (!used.has(base)) return base
  let number = 2
  while (used.has(`${base} ${number}`)) number++
  return `${base} ${number}`
}

/**
 * The home layout with a section renamed (renaming a custom section dropped it from Home).
 * @param {Array<[string, ...any[]]>} homeSections
 * @param {string} from
 * @param {string} to
 */
export function renameHomeSection (homeSections, from, to) {
  return (homeSections || []).map(entry => entry?.[0] === from ? [to, ...entry.slice(1)] : entry)
}

/**
 * The home layout without a section (a deleted custom section).
 * @param {Array<[string, ...any[]]>} homeSections
 * @param {string} title
 */
export function removeHomeSection (homeSections, title) {
  return (homeSections || []).filter(entry => entry?.[0] !== title)
}
