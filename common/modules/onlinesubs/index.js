import { getAniMappings } from '@/modules/anime/anime.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { parseSrt } from '@/modules/vtt.js'
import Debug from 'debug'
import { subtitlesUrl, episodeCandidates, tmdbSeasonEpisode, parseSubtitleList, languageName } from './core.js'

const debug = Debug('ui:onlinesubs')

// Search results are kept per episode for an hour, downloaded files for the session (a few at most).
const SEARCH_TTL = 60 * 60 * 1000
const searches = new Map()
const files = new Map()

export class OnlineSubtitlesError extends Error {}

/** Message shown to the user for a failure (network errors, provider errors, empty files). */
export function errorMessage (error) {
  if (error instanceof OnlineSubtitlesError) return error.message
  if (error?.name === 'TimeoutError' || error?.name === 'AbortError') return 'The subtitle service took too long to answer.'
  if (error instanceof TypeError) return 'Could not reach the subtitle service. Check your connection.'
  return error?.message || 'Something went wrong while loading subtitles.'
}

/**
 * Requests to try for a title and episode (in order): TMDB id from the media for TMDB titles, from ani.zip
 * (animap as a fallback) for anime, with the season / episode numbering candidates.
 * @returns {Promise<{ type: 'tv' | 'movie', tmdb: number, season?: number, episode?: number }[]>}
 */
export async function resolveQueries (media, episode) {
  if (!media) return []
  const number = Number(episode) || 1
  const isTmdb = media.isTmdb || (typeof media.id === 'string' && media.id.startsWith('tmdb-'))
  if (isTmdb) {
    const tmdb = Number(media.idTmdb || String(media.id).replace('tmdb-', ''))
    if (!tmdb) return []
    if (media.format === 'MOVIE') return [{ type: 'movie', tmdb }]
    // Episode lists of TMDB shows number episodes across seasons.
    const details = await tmdbClient.getDetails(tmdb, 'tv').catch(() => null)
    const mapped = tmdbSeasonEpisode(details?.seasons, number)
    const candidates = mapped ? [mapped] : []
    if (!mapped || mapped.season !== 1 || mapped.episode !== number) candidates.push({ season: 1, episode: number })
    return candidates.map(candidate => ({ type: 'tv', tmdb, ...candidate }))
  }
  const mappings = await getAniMappings(media.id).catch(error => {
    debug('ani.zip mappings failed', error)
    return null
  })
  const animap = tmdbClient.anilistToTmdb?.[media.id]
  const tmdb = Number(mappings?.mappings?.themoviedb_id) || Number(media.idTmdb) || Number(animap?.id) || null
  if (!tmdb) return []
  const type = String(mappings?.mappings?.type || animap?.type || '').toUpperCase()
  if (media.format === 'MOVIE' || type === 'MOVIE') return [{ type: 'movie', tmdb }]
  return episodeCandidates({
    episode: number,
    aniEpisode: mappings?.episodes?.[String(number)],
    tvdbSeason: animap?.tvdb_season,
    tvdbOffset: animap?.tvdb_epoffset
  }).map(candidate => ({ type: 'tv', tmdb, ...candidate }))
}

async function fetchList (query) {
  const response = await fetch(subtitlesUrl(query), { signal: AbortSignal.timeout(20_000) })
  if (response.status === 429) throw new OnlineSubtitlesError('The subtitle service is busy, try again in a minute.')
  if (!response.ok) throw new OnlineSubtitlesError(`The subtitle service is unavailable (error ${response.status}).`)
  return parseSubtitleList(await response.json())
}

/**
 * Online subtitles of an episode (or movie). Tries each numbering until one has results.
 * @returns {Promise<{ list: ReturnType<typeof parseSubtitleList>, query: any }>}
 */
export function searchOnlineSubtitles (media, episode, { force = false } = {}) {
  const key = `${media?.id}:${episode ?? ''}`
  const cached = searches.get(key)
  if (!force && cached && Date.now() - cached.time < SEARCH_TTL) return cached.promise
  const promise = (async () => {
    const queries = await resolveQueries(media, episode)
    if (!queries.length) throw new OnlineSubtitlesError('This title has no TMDB match, so online subtitles cannot be searched.')
    let answered = false
    let lastError = null
    for (const query of queries) {
      try {
        const list = await fetchList(query)
        answered = true
        if (list.length) return { list, query }
      } catch (error) {
        debug('Online subtitles request failed', query, error)
        lastError = error
      }
    }
    if (!answered && lastError) throw lastError
    return { list: [], query: queries[0] }
  })()
  searches.set(key, { time: Date.now(), promise })
  promise.catch(() => searches.delete(key))
  return promise
}

/** Downloads a subtitle file of the list (text). */
export async function downloadOnlineSubtitle (item) {
  if (files.has(item.url)) return files.get(item.url)
  const response = await fetch(item.url, { signal: AbortSignal.timeout(30_000) })
  if (!response.ok) throw new OnlineSubtitlesError(`The subtitle file could not be downloaded (error ${response.status}).`)
  const text = await response.text()
  if (!text.trim()) throw new OnlineSubtitlesError('The subtitle file is empty.')
  if (files.size >= 20) files.delete(files.keys().next().value)
  files.set(item.url, text)
  return text
}

/**
 * Adds a downloaded subtitle to the player (Subtitles module: converted to ASS for JASSUB) and selects it.
 * @param {import('@/modules/subtitles.js').default} subs
 * @returns {Promise<number>} track number
 */
export async function addToPlayer (subs, item, text) {
  if (!subs?.headers) throw new OnlineSubtitlesError('The video is not ready yet.')
  const format = ['srt', 'vtt', 'ass', 'ssa', 'sub'].includes(item.format) ? item.format : 'srt'
  if ((format === 'srt' || format === 'vtt') && !parseSrt(text).length) throw new OnlineSubtitlesError('This file does not contain subtitles.')
  const index = await subs.addSingleSubtitleFile(new File([text], `online.${format}`, { type: 'text/plain' }))
  const header = subs.headers?.[index]
  if (!header) throw new OnlineSubtitlesError('The video changed while the subtitles were loading.')
  header.language = languageName(item.language)
  header.name = String(item.name || '').replace(/\.(srt|vtt|ass|ssa|sub|txt)$/i, '')
  header.online = true
  subs.initSubtitleRenderer()
  subs.selectCaptions(index)
  setTimeout(() => subs?.renderer?.resize(), 200) // video metadata takes a few frames to update (same fix as the player)
  return index
}
