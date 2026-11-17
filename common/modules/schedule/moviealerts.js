// Movie release alerts: the user turns on an alert on the details of a TMDB movie and is notified when it comes out
// in theaters, then on digital (modules/moviealerts.js runs the checks; iOS: ios-native/Tsumi/Services/MovieAlerts.swift).
// Pure helpers, tested by moviealerts.test.mjs. Release days come from movies.js (same regions as the schedule).
import { releaseDate, releaseDay, THEATRICAL_TYPES, DIGITAL_TYPES } from './movies.js'

/** Alerts still waiting after this long are dropped (a digital release that never got a date). */
export const ALERT_RETENTION_DAYS = 548

/** Badge of the notification list for each release. */
export const RELEASE_BADGES = { theatrical: 'In Theaters', digital: 'Digital' }

/** Local midnight of a time (ms). */
export function startOfDay (time) {
  const date = new Date(time)
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

/**
 * Theatrical and digital release days ("YYYY-MM-DD" or null) of a movie, like the schedule: theatrical in the release
 * regions only, digital anywhere when the regions have none (often only the US lists it).
 * @param {any[]} results TMDB release_dates results
 * @param {string[]} regions
 */
export function movieReleaseDays (results, regions) {
  return {
    theatrical: releaseDate(results, THEATRICAL_TYPES, regions),
    digital: releaseDate(results, DIGITAL_TYPES, regions, true)
  }
}

/**
 * Whether an alert can still be turned on: the movie is not on digital yet (or its digital day is unknown).
 * @param {{ digital?: string | null }} days
 * @param {number} [now]
 */
export function canAlert (days, now = Date.now()) {
  return !days?.digital || releaseDay(days.digital).getTime() >= startOfDay(now)
}

/**
 * What a check does with one alert. A release is due when its day has come, it was not notified yet, and it was
 * still to come (or today) when the alert was turned on: releases already past then never notify. When both are due
 * at once (the app was not opened for a while), only the digital one is notified. The alert is done once the digital
 * release was notified, when the movie was already on digital when the alert was turned on, or after
 * ALERT_RETENTION_DAYS.
 * @param {{ addedAt: number, notified?: string[] }} alert
 * @param {{ theatrical?: string | null, digital?: string | null }} days
 * @param {number} [now]
 * @returns {{ notify: 'theatrical' | 'digital' | null, day: string | null, notified: string[], done: boolean }}
 */
export function dueRelease (alert, days, now = Date.now()) {
  const added = startOfDay(Number(alert?.addedAt) || now)
  const notified = Array.isArray(alert?.notified) ? alert.notified.filter(kind => kind === 'theatrical' || kind === 'digital') : []
  const time = (kind) => days?.[kind] ? releaseDay(days[kind]).getTime() : NaN
  const due = (kind) => !notified.includes(kind) && time(kind) <= now && time(kind) >= added
  const notify = due('digital') ? 'digital' : due('theatrical') ? 'theatrical' : null
  const next = notify === 'digital' ? ['theatrical', 'digital'] : notify ? [...notified, notify] : notified
  const unique = next.filter((kind, index) => next.indexOf(kind) === index)
  const done = unique.includes('digital') || time('digital') < added || now - added > ALERT_RETENTION_DAYS * 86_400_000
  return { notify, day: notify ? days[notify] : null, notified: unique, done }
}

const shortDate = (day, locale) => releaseDay(day).toLocaleDateString(locale, { month: 'short', day: 'numeric' })

/**
 * Text of a release notification: "Out in theaters today!", "In theaters since Nov 18", "Out on digital today!"...
 * @param {'theatrical' | 'digital'} kind
 * @param {string} day
 * @param {number} [now]
 * @param {string} [locale]
 */
export function releaseMessage (kind, day, now = Date.now(), locale = 'en-US') {
  const today = releaseDay(day).getTime() === startOfDay(now)
  if (kind === 'digital') return today ? 'Out on digital today!' : `On digital since ${shortDate(day, locale)}`
  return today ? 'Out in theaters today!' : `In theaters since ${shortDate(day, locale)}`
}

/**
 * Releases still to come (today included), for the alert button: "In theaters Nov 18 · Digital Jan 6", '' when none
 * is known.
 * @param {{ theatrical?: string | null, digital?: string | null }} days
 * @param {number} [now]
 * @param {string} [locale]
 */
export function upcomingReleases (days, now = Date.now(), locale = 'en-US') {
  const today = startOfDay(now)
  const parts = []
  if (days?.theatrical && releaseDay(days.theatrical).getTime() >= today) parts.push(`In theaters ${shortDate(days.theatrical, locale)}`)
  if (days?.digital && releaseDay(days.digital).getTime() >= today) parts.push(`Digital ${shortDate(days.digital, locale)}`)
  return parts.join(' · ')
}
