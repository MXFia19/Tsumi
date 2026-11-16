// Calendar dates ("2024-05-10") of MyAnimeList list entries, TMDB air / release dates, Jikan and Kitsu episodes are
// days, not instants. new Date('2024-05-10') reads them as UTC midnight, which is the previous day west of UTC
// (and gets written back to MyAnimeList one day earlier on every update). These helpers keep them as local days.
// Pure module, tested by dates.test.mjs.

// "2024", "2024-05", "2024-05-10", optionally followed by a time ("2023-09-29T00:00:00+00:00", "2024-05-10 12:00").
const DATE_ONLY = /^(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?(?=$|[T\s])/

function daysInMonth (year, month) {
  return new Date(year, month, 0).getDate()
}

/**
 * Calendar date of a date-only value, read as written (no time zone conversion).
 * Partial dates keep the missing parts as null ("2017-03" -> { year: 2017, month: 3, day: null }).
 * A Date is read in local time.
 * @param {string | Date | null | undefined} value
 * @returns {{ year: number, month: number | null, day: number | null } | null}
 */
export function parseDateOnly (value) {
  if (value === null || value === undefined || value === '') return null
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) return null
    return { year: value.getFullYear(), month: value.getMonth() + 1, day: value.getDate() }
  }
  const match = DATE_ONLY.exec(String(value).trim())
  if (!match) return null
  const year = Number(match[1])
  const month = match[2] !== undefined ? Number(match[2]) : null
  const day = match[3] !== undefined ? Number(match[3]) : null
  if (!(year > 0)) return null
  if (month !== null && (month < 1 || month > 12)) return null
  if (day !== null && (day < 1 || day > daysInMonth(year, month))) return null
  return { year, month, day }
}

/**
 * Local midnight of a date-only value (missing month / day count as the first), null when it is not a date.
 * @param {string | Date | null | undefined} value
 * @returns {Date | null}
 */
export function toLocalDate (value) {
  const date = parseDateOnly(value)
  if (!date) return null
  return new Date(date.year, (date.month || 1) - 1, date.day || 1)
}

const pad = (number) => String(number).padStart(2, '0')

/**
 * "YYYY-MM-DD" of a complete fuzzy date ({ year, month, day }), null when a part is missing.
 * @param {{ year?: number | null, month?: number | null, day?: number | null } | null | undefined} fuzzyDate
 * @returns {string | null}
 */
export function fuzzyDateString (fuzzyDate) {
  if (!fuzzyDate?.year || !fuzzyDate.month || !fuzzyDate.day) return null
  return `${fuzzyDate.year}-${pad(fuzzyDate.month)}-${pad(fuzzyDate.day)}`
}

/**
 * A complete date-only value as local midnight without offset ("2023-09-29T00:00:00"): new Date() reads it as local
 * time, so it is the same calendar day in every time zone. Other values (partial dates, null) are returned unchanged.
 * For data kept as strings (episode air dates of Jikan and Kitsu).
 * @param {any} value
 */
export function localDateTimeString (value) {
  const date = parseDateOnly(value)
  if (!date?.month || !date.day || value instanceof Date) return value ?? null
  return `${fuzzyDateString(date)}T00:00:00`
}

/**
 * Fuzzy date ({ year, month, day }) of the local day of a Date (today by default).
 * @param {Date} [date]
 */
export function localFuzzyDate (date = new Date()) {
  return { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate() }
}

/**
 * Sortable number (YYYYMMDD, missing parts as 0) of a date-only value or fuzzy date, 0 when there is none.
 * @param {string | Date | { year?: number | null, month?: number | null, day?: number | null } | null | undefined} value
 */
export function dateOnlyValue (value) {
  const date = (value && typeof value === 'object' && !(value instanceof Date)) ? value : parseDateOnly(value)
  if (!date?.year) return 0
  return date.year * 10000 + (date.month || 0) * 100 + (date.day || 0)
}
