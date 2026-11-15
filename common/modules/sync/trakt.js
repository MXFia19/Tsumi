import { writable } from 'simple-store-svelte'
import { IPC } from '@/modules/bridge.js'
import { settings } from '@/modules/settings.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { getAniMappings } from '@/modules/anime/anime.js'
import Debug from 'debug'
const debug = Debug('ui:trakt')

/*
 * Trakt for the renderer. The account (device code flow, tokens encrypted with safeStorage, refresh) and every
 * API call live in the Electron main process (electron/src/main/trakt.js): the tokens never reach the page.
 * Here: the account status, scrobbling targets and the playback progress (/sync/playback) used to resume.
 */

const canInvoke = typeof IPC?.invoke === 'function'

/**
 * @typedef {{ available: boolean, state: 'unavailable' | 'disconnected' | 'linking' | 'connected', user: string, code: string, url: string, expiresAt: number, error: string }} TraktStatus
 * `unavailable`: the build has no Trakt client id / secret.
 */
/** @type {import('simple-store-svelte').Writable<TraktStatus>} */
export const traktStatus = writable({ available: false, state: 'unavailable', user: '', code: '', url: '', expiresAt: 0, error: '' })

/** @type {{ at: number, promise: Promise<any[]> } | null} */
let playbackCache = null

if (canInvoke) {
  IPC.invoke('trakt:status').then((/** @type {any} */ status) => { if (status) traktStatus.value = status }).catch(() => {})
  IPC.on('trakt:status', (/** @type {any} */ status) => {
    traktStatus.value = status
    playbackCache = null
  })
}

export function traktConnected () {
  return traktStatus.value.state === 'connected'
}

/** Starts the device code flow: the main process opens the verification page and polls. */
export function traktLink () {
  if (canInvoke) IPC.emit('trakt:link')
}

export function traktCancel () {
  if (canInvoke) IPC.emit('trakt:cancel')
}

export function traktUnlink () {
  if (canInvoke) IPC.emit('trakt:unlink')
}

/** Opens the verification page again (trakt.tv/activate). */
export function traktOpenVerification () {
  if (canInvoke) IPC.emit('trakt:open')
}

/**
 * @param {'GET' | 'POST' | 'DELETE'} method
 * @param {string} path
 * @param {any} [body]
 * @returns {Promise<{ status: number, data: any } | null>}
 */
async function request (method, path, body) {
  if (!canInvoke || !traktConnected()) return null
  try {
    return await IPC.invoke('trakt:request', { method, path, body })
  } catch (error) {
    debug('Trakt request failed', path, error)
    return null
  }
}

/**
 * Items paused on any device (movies and episodes), newest first; cached for a minute.
 * @param {boolean} [fresh]
 * @returns {Promise<any[]>}
 */
export function getTraktPlayback (fresh = false) {
  if (!traktConnected()) return Promise.resolve([])
  if (!fresh && playbackCache && Date.now() - playbackCache.at < 60_000) return playbackCache.promise
  const promise = request('GET', '/sync/playback').then(res => {
    const items = res?.status === 200 && Array.isArray(res.data) ? res.data : []
    return items.sort((a, b) => Date.parse(b.paused_at) - Date.parse(a.paused_at))
  })
  playbackCache = { at: Date.now(), promise }
  return promise
}

/**
 * Seasons of a TMDB show in the order of the episode list of the details (EpisodeList.svelte loadTmdbEpisodes):
 * seasons > 0, episodes numbered 1, 2, 3... across them.
 * @param {number} tmdbId
 */
async function tmdbSeasons (tmdbId) {
  const details = await tmdbClient.getDetails(tmdbId, 'tv')
  const seasons = []
  for (const season of details?.seasons || []) {
    const episodes = await tmdbClient.getSeasonEpisodes(tmdbId, season.season_number)
    seasons.push({ season: season.season_number, episodes: episodes.map(episode => ({ number: episode.episode, length: episode.length })) })
  }
  return seasons
}

/**
 * Absolute episode of the app → season / episode of a TMDB show.
 * @param {number} tmdbId
 * @param {number} absolute
 * @returns {Promise<{ season: number, number: number, length?: number } | null>}
 */
export async function tmdbEpisodeOf (tmdbId, absolute) {
  let count = 0
  for (const { season, episodes } of await tmdbSeasons(tmdbId)) {
    if (absolute <= count + episodes.length) {
      const episode = episodes[absolute - count - 1]
      return episode ? { season, number: episode.number, length: episode.length } : null
    }
    count += episodes.length
  }
  return null
}

/**
 * Season / episode of a TMDB show → absolute episode of the app.
 * @param {number} tmdbId
 * @param {number} seasonNumber
 * @param {number} number
 * @returns {Promise<{ episode: number, length?: number } | null>}
 */
export async function tmdbAbsoluteOf (tmdbId, seasonNumber, number) {
  let count = 0
  for (const { season, episodes } of await tmdbSeasons(tmdbId)) {
    const index = season === seasonNumber ? episodes.findIndex(episode => episode.number === number) : -1
    if (index !== -1) return { episode: count + index + 1, length: episodes[index].length }
    count += episodes.length
  }
  return null
}

/** @param {any} media */
export function tmdbIdOf (media) {
  if (!media?.isTmdb) return null
  const id = Number(media.idTmdb || (typeof media.id === 'string' ? media.id.replace(/^tmdb-(tv-|movie-)?/, '') : NaN))
  return Number.isInteger(id) && id > 0 ? id : null
}

/**
 * What Trakt calls this episode: { movie: { ids } } or { show: { ids }, episode: { season, number } }, null when it
 * can't be told (anime without mappings, scrobbling of anime off).
 * @param {any} media
 * @param {number} episode
 */
export async function traktTarget (media, episode) {
  if (!media) return null
  const tmdbId = tmdbIdOf(media)
  if (tmdbId) {
    if (media.format === 'MOVIE') return { movie: { ids: { tmdb: tmdbId } } }
    const found = await tmdbEpisodeOf(tmdbId, Number(episode) || 1)
    return found && { show: { ids: { tmdb: tmdbId } }, episode: { season: found.season, number: found.number } }
  }
  if (!settings.value.traktScrobbleAnime || typeof media.id !== 'number') return null
  const mappings = await getAniMappings(media.id).catch(() => null)
  const ids = mappings?.mappings
  if (!ids) return null
  if (media.format === 'MOVIE') {
    if (ids.imdb_id) return { movie: { ids: { imdb: ids.imdb_id } } }
    if (ids.themoviedb_id) return { movie: { ids: { tmdb: Number(ids.themoviedb_id) } } }
    return null
  }
  const data = mappings.episodes?.[String(episode)]
  const show = Number(data?.tvdbShowId || ids.thetvdb_id)
  if (!show || !Number.isInteger(data?.seasonNumber) || !Number.isInteger(data?.episodeNumber)) return null
  return { show: { ids: { tvdb: show } }, episode: { season: data.seasonNumber, number: data.episodeNumber } }
}

/**
 * @param {Record<string, any> | undefined} a ids of a Trakt item
 * @param {Record<string, any>} b ids of a target
 */
function sameIds (a, b) {
  return !!a && Object.entries(b).some(([key, value]) => value != null && a[key] != null && String(a[key]) === String(value))
}

/**
 * @param {any} item /sync/playback item
 * @param {any} target traktTarget()
 */
export function matchesTarget (item, target) {
  if (!item || !target) return false
  if (target.movie) return item.type === 'movie' && sameIds(item.movie?.ids, target.movie.ids)
  return item.type === 'episode' && sameIds(item.show?.ids, target.show.ids) &&
    item.episode?.season === target.episode.season && item.episode?.number === target.episode.number
}

/**
 * /scrobble/start | pause | stop. Stop at 80% or more marks it watched on Trakt, below it saves the progress.
 * @param {'start' | 'pause' | 'stop'} action
 * @param {any} target traktTarget()
 * @param {number} progress 0-100
 */
export async function scrobble (action, target, progress) {
  const res = await request('POST', `/scrobble/${action}`, { ...target, progress: Math.min(100, Math.max(0, Number(progress) || 0)) })
  if (action !== 'start') playbackCache = null
  if (res && res.status >= 400 && res.status !== 409) debug(`Trakt scrobble ${action} returned ${res.status}`)
  return res
}
