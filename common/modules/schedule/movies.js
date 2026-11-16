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

export const THEATRICAL_TYPES = [2, 3]
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

/**
 * Country of the first preferred language that names one (["fr", "fr-BE", "en-US"] -> "BE"), null without one.
 * @param {readonly string[] | string[] | undefined} languages navigator.languages
 */
export function preferredRegion (languages) {
  for (const language of languages || []) {
    const region = localeRegion(language)
    if (region) return region
  }
  return null
}

/**
 * First release day ("YYYY-MM-DD") of one of `types` in `region`, else in the US, else (with `anywhere`) in any
 * country. Digital releases are often only listed for the US.
 * @param {any[]} results release_dates results
 * @param {number[]} types
 * @param {string | null} region
 * @param {boolean} [anywhere]
 * @returns {string | null}
 */
export function releaseDate (results, types, region, anywhere = false) {
  const days = (country) => (Array.isArray(results) ? results : [])
    .filter(entry => !country || entry?.iso_3166_1 === country)
    .flatMap(entry => Array.isArray(entry?.release_dates) ? entry.release_dates : [])
    .filter(date => types.includes(Number(date?.type)) && /^\d{4}-\d{2}-\d{2}/.test(String(date?.release_date || '')))
    .map(date => date.release_date.slice(0, 10))
    .sort()
  for (const country of [region, 'US']) {
    if (!country) continue
    const found = days(country)
    if (found.length) return found[0]
  }
  return anywhere ? (days(null)[0] || null) : null
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
 * @param {{ region?: string | null, theatrical?: boolean, digital?: boolean, now?: number, days?: number }} [options]
 */
export function movieReleaseNodes (results, { region = null, theatrical = true, digital = true, now = Date.now(), days = MOVIE_WINDOW_DAYS } = {}) {
  const until = now + days * 86_400_000
  const nodes = []
  const add = (release, day) => {
    if (!day) return
    const time = releaseDay(day).getTime()
    if (time > now && time <= until) nodes.push({ episode: 1, airingAt: Math.floor(time / 1000), label: RELEASE_LABELS[release], release })
  }
  if (theatrical) add('theatrical', releaseDate(results, THEATRICAL_TYPES, region))
  if (digital) add('digital', releaseDate(results, DIGITAL_TYPES, region, true))
  return nodes.sort((a, b) => a.airingAt - b.airingAt)
}
