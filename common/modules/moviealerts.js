import { writable } from 'simple-store-svelte'
import Debug from 'debug'
import { cache, caches, mediaCache } from '@/modules/cache.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { releaseRegions } from '@/modules/schedule/movies.js'
import { movieReleaseDays, dueRelease, releaseMessage } from '@/modules/schedule/moviealerts.js'

const debug = Debug('ui:movie-alerts')

// Release alerts of TMDB movies (details "Release alert" button, MovieAlertButton.svelte): checked a little after
// start and every 6 hours, each due release becomes a notification of the NotificationsModal ('notification-app').
// The list is kept with the notification bookkeeping (cache NOTIFICATIONS 'movieAlerts', reset with them). Pure
// logic in schedule/moviealerts.js; iOS: ios-native/Tsumi/Services/MovieAlerts.swift.

const FIRST_CHECK_DELAY = 20_000
const CHECK_INTERVAL = 6 * 60 * 60 * 1000

/** Release regions, the same as the schedule (TMDBClient.getMovieSchedule). */
export function alertRegions () {
  return releaseRegions(globalThis.navigator?.languages?.length ? globalThis.navigator.languages : [globalThis.navigator?.language])
}

/** @typedef {{ id: string, idTmdb: number, title: string, media: any, addedAt: number, notified: string[] }} MovieAlert */

const stored = () => (cache.getEntry(caches.NOTIFICATIONS, 'movieAlerts') || []).filter(alert => alert?.idTmdb)

/** @type {import('simple-store-svelte').Writable<MovieAlert[]>} */
export const movieAlerts = writable(stored())
window.addEventListener('notification-reset', () => movieAlerts.set([]))

function save (list) {
  cache.setEntry(caches.NOTIFICATIONS, 'movieAlerts', list)
  movieAlerts.set(list)
}

/** TMDB movies only: anime movies of AniList have their own airing notifications. */
export function isAlertable (media) {
  return !!(media?.isTmdb && media.idTmdb && media.format === 'MOVIE')
}

const dayRequests = new Map()
/**
 * Theatrical and digital release days of a movie (release dates cached 12 hours by tmdb.js). The details ask twice
 * (alert button and dates line): one request for both.
 */
export function movieDays (media) {
  const id = media.idTmdb
  const pending = dayRequests.get(id)
  if (pending && Date.now() - pending.at < 60_000) return pending.promise
  const promise = tmdbClient.getReleaseDates(id).then(results => movieReleaseDays(results, alertRegions()))
  dayRequests.set(id, { promise, at: Date.now() })
  promise.catch(() => dayRequests.delete(id))
  return promise
}

const SNAPSHOT_KEYS = ['id', 'idTmdb', 'isTmdb', 'format', 'title', 'coverImage', 'bannerImage', 'description', 'seasonYear', 'status', 'genres', 'averageScore', 'popularity', 'episodes', 'duration', 'trailer', 'logo']
/** What the details need to open again from a notification (the media cache may have dropped the movie). */
function snapshot (media) {
  return Object.fromEntries(SNAPSHOT_KEYS.filter(key => media[key] !== undefined).map(key => [key, media[key]]))
}

/**
 * Turns the alert of a movie on or off.
 * @returns {boolean} whether the alert is now on
 */
export function toggleMovieAlert (media) {
  if (!isAlertable(media)) return false
  const list = movieAlerts.value
  if (list.some(alert => alert.idTmdb === media.idTmdb)) {
    save(list.filter(alert => alert.idTmdb !== media.idTmdb))
    return false
  }
  const title = media.title?.userPreferred || media.title?.english || media.title?.romaji || 'Movie'
  save([...list, { id: media.id, idTmdb: media.idTmdb, title, media: snapshot(media), addedAt: Date.now(), notified: [] }])
  checkSoon() // a movie out today notifies without waiting for the next check
  return true
}

/**
 * Media of a TMDB movie id ("tmdb-123") for the details: the cached one, the one kept by an alert, else TMDB.
 * @param {string} id
 */
export async function movieMedia (id) {
  const cached = mediaCache.value[id]
  if (cached) return cached
  const alert = movieAlerts.value.find(alert => alert.id === id)
  if (alert?.media) return alert.media
  const idTmdb = Number(String(id).replace(/^tmdb-/, ''))
  if (!idTmdb) return null
  const data = await tmdbClient.handleRequest(`/movie/${idTmdb}`).catch(() => null)
  return data?.id ? tmdbClient.normalizeMedia({ ...data, media_type: 'movie' }) : null
}

function notify (alert, kind, day, now) {
  const media = alert.media || {}
  const link = `tsumi://anime/${alert.id}`
  window.dispatchEvent(new CustomEvent('notification-app', {
    detail: {
      id: alert.id,
      title: alert.title,
      message: releaseMessage(kind, day, now),
      icon: media.coverImage?.medium || media.coverImage?.extraLarge,
      iconXL: media.coverImage?.extraLarge,
      heroImg: media.bannerImage || (media.trailer?.id && `https://i.ytimg.com/vi/${media.trailer.id}/hqdefault.jpg`),
      timestamp: Math.floor(now / 1000),
      format: 'MOVIE',
      release: kind,
      click_action: 'VIEW',
      button: [{ text: 'View Movie', activation: link }],
      activation: { type: 'protocol', launch: link }
    }
  }))
}

let checking = null
/** One pass over the alerts: notifies the releases that came out and drops the finished alerts. */
export function checkMovieAlerts () {
  checking ??= (async () => {
    try {
      const regions = alertRegions()
      const now = Date.now()
      const updates = new Map()
      for (const alert of movieAlerts.value) {
        let days
        try {
          days = movieReleaseDays(await tmdbClient.getReleaseDates(alert.idTmdb), regions)
        } catch (error) {
          debug('Release dates failed', alert.idTmdb, error)
          continue
        }
        const result = dueRelease(alert, days, now)
        if (result.notify) {
          debug(`${alert.title}: ${result.notify} release ${result.day}`)
          notify(alert, result.notify, result.day, now)
        }
        if (result.done || result.notify) updates.set(alert.idTmdb, result)
      }
      if (!updates.size) return
      // The list may have changed during the requests (toggled from the details): apply to the current one.
      save(movieAlerts.value.flatMap(alert => {
        const result = updates.get(alert.idTmdb)
        if (!result) return [alert]
        return result.done ? [] : [{ ...alert, notified: result.notified }]
      }))
    } catch (error) {
      debug('Movie alerts check failed', error)
    } finally {
      checking = null
    }
  })()
  return checking
}

let soonTimer = null
function checkSoon () {
  clearTimeout(soonTimer)
  soonTimer = setTimeout(checkMovieAlerts, 5_000)
}

let started = false
/** Starts the checks (App.svelte). */
export function startMovieAlerts () {
  if (started) return
  started = true
  setTimeout(checkMovieAlerts, FIRST_CHECK_DELAY)
  setInterval(checkMovieAlerts, CHECK_INTERVAL)
}
