// Upcoming movies in the schedule (SchedulePage.svelte; iOS: ios-native/Tsumi/Services/TMDBService.swift
// movieSchedule). A movie shows up at its theatrical release and again at its digital release, with the "Release"
// filter of the schedule choosing which. Pure helpers, tested by movies.test.mjs.
//
// Dates come from TMDB /movie/{id}/release_dates: { results: [{ iso_3166_1, release_dates: [{ type, release_date }] }] }
// Release types: 1 premiere, 2 theatrical (limited), 3 theatrical, 4 digital, 5 physical, 6 TV.

/** "Release" filter of the schedule (search.release). */
export const RELEASE_FILTERS = { '': 'Any', episodes: 'Episodes', movies: 'Movies', theatrical: 'In Theaters', digital: 'Digital' }

/** How far ahead movies are listed. */
export const MOVIE_WINDOW_DAYS = 60

/**
 * Theatrical: the wide release (3) of a country, else its limited one (2). A limited release before the wide one (US
 * awards runs) would otherwise hide the wide date once it has passed (schedule and release alerts).
 */
export const THEATRICAL_TYPES = [[3], [2]]
export const DIGITAL_TYPES = [4]

/** Text of the schedule card: "In theaters in 2 days", "On digital in 3 weeks" ({suffix} is filled by getAiringInfo). */
export const RELEASE_LABELS = { theatrical: 'In theaters', digital: 'On digital' }

/**
 * What a "Release" filter value lists.
 * @param {string} [release]
 * @returns {{ episodes: boolean, theatrical: boolean, digital: boolean }}
 */
export function releaseKinds (release) {
  switch (release) {
    case 'episodes': return { episodes: true, theatrical: false, digital: false }
    case 'movies': return { episodes: false, theatrical: true, digital: true }
    case 'theatrical': return { episodes: false, theatrical: true, digital: false }
    case 'digital': return { episodes: false, theatrical: false, digital: true }
    default: return { episodes: true, theatrical: true, digital: true }
  }
}

/** Country of a locale ("fr-FR" -> "FR", "zh-Hans-CN" -> "CN"), null without one. */
export function localeRegion (locale) {
  const match = /[-_]([A-Za-z]{2})(?=$|[-_.@])/.exec(String(locale || ''))
  return match ? match[1].toUpperCase() : null
}

/** Main country of a language without one ("fr" -> FR): TMDB often has no dates for smaller countries. */
const LANGUAGE_COUNTRIES = { fr: 'FR', de: 'DE', es: 'ES', it: 'IT', nl: 'NL', pt: 'PT', pl: 'PL', sv: 'SE', da: 'DK', nb: 'NO', no: 'NO', fi: 'FI', ru: 'RU', tr: 'TR', ja: 'JP', ko: 'KR', zh: 'CN', en: 'US' }

/**
 * Countries whose release dates are used, in order: the first country named by the preferred languages (or the
 * device region on iOS), the main country of the first language, the other named countries and languages, then
 * the US. ["fr", "fr-BE", "en-US"] -> ["BE", "FR", "US"].
 * @param {readonly string[] | string[] | undefined} languages navigator.languages
 * @returns {string[]}
 */
export function releaseRegions (languages) {
  const list = Array.isArray(languages) ? languages : []
  const named = list.map(localeRegion).filter(Boolean)
  const spoken = list.map(language => LANGUAGE_COUNTRIES[String(language).slice(0, 2).toLowerCase()]).filter(Boolean)
  const regions = []
  for (const region of [named[0], spoken[0], ...named.slice(1), ...spoken.slice(1), 'US']) {
    if (region && !regions.includes(region)) regions.push(region)
  }
  return regions
}

/**
 * First release day ("YYYY-MM-DD") of one of `types` in the first of `regions` that has one (a single region
 * falls back to the US), else (with `anywhere`) in any country. Digital releases are often only listed for the US.
 * `types` can be groups tried in order within each country ([[3], [2]]: wide, else limited).
 * @param {any[]} results release_dates results
 * @param {number[] | number[][]} types
 * @param {string[] | string | null} regions
 * @param {boolean} [anywhere]
 * @returns {string | null}
 */
export function releaseDate (results, types, regions, anywhere = false) {
  const groups = Array.isArray(types?.[0]) ? types : [types]
  const days = (country, group) => (Array.isArray(results) ? results : [])
    .filter(entry => !country || entry?.iso_3166_1 === country)
    .flatMap(entry => Array.isArray(entry?.release_dates) ? entry.release_dates : [])
    .filter(date => group.includes(Number(date?.type)) && /^\d{4}-\d{2}-\d{2}/.test(String(date?.release_date || '')))
    .map(date => date.release_date.slice(0, 10))
    .sort()
  const first = (country) => {
    for (const group of groups) {
      const found = days(country, group)
      if (found.length) return found[0]
    }
    return null
  }
  for (const country of Array.isArray(regions) ? regions : [regions, 'US']) {
    if (!country) continue
    const found = first(country)
    if (found) return found
  }
  return anywhere ? first(null) : null
}

/** Local midnight of a "YYYY-MM-DD" day. */
export function releaseDay (day) {
  const [year, month, date] = String(day).slice(0, 10).split('-').map(Number)
  return new Date(year, month - 1, date)
}

/**
 * Schedule nodes of a movie ({ episode: 1, airingAt in seconds, label, release }): its theatrical and digital
 * releases still to come within MOVIE_WINDOW_DAYS, earliest first.
 * @param {any[]} results release_dates results
 * @param {{ regions?: string[] | string | null, theatrical?: boolean, digital?: boolean, now?: number, days?: number }} [options]
 */
export function movieReleaseNodes (results, { regions = ['US'], theatrical = true, digital = true, now = Date.now(), days = MOVIE_WINDOW_DAYS } = {}) {
  const until = now + days * 86_400_000
  const nodes = []
  const add = (release, day) => {
    if (!day) return
    const time = releaseDay(day).getTime()
    if (time > now && time <= until) nodes.push({ episode: 1, airingAt: Math.floor(time / 1000), label: RELEASE_LABELS[release], release })
  }
  if (theatrical) add('theatrical', releaseDate(results, THEATRICAL_TYPES, regions))
  if (digital) add('digital', releaseDate(results, DIGITAL_TYPES, regions, true))
  return nodes.sort((a, b) => a.airingAt - b.airingAt)
}
