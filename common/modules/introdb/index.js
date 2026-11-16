import { getAniMappings } from '@/modules/anime/anime.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { tmdbSeasonEpisode, episodeNumber } from '@/modules/onlinesubs/core.js'
import Debug from 'debug'
import { introDbUrl, introDbChapters, animeQuery } from './core.js'

const debug = Debug('ui:introdb')

// Answers kept for the session per request URL (a few dozen at most).
const answers = new Map()

/**
 * TheIntroDB query of a title and episode: TMDB id for TMDB movies, TMDB id with the season / episode of the
 * absolute episode number for TMDB shows (episode lists number them across seasons), ani.zip TVDB numbering for
 * anime. null when the episode cannot be placed (better no chapters than the skip times of another episode).
 */
export async function introDbQuery (media, episode) {
  if (!media) return null
  const number = episodeNumber(episode) // episode 0 (prologue) stays 0: no skip times rather than episode 1's
  const isTmdb = media.isTmdb || (typeof media.id === 'string' && media.id.startsWith('tmdb-'))
  if (isTmdb) {
    const tmdb = Number(media.idTmdb || String(media.id).replace(/^tmdb-(tv-|movie-)?/, ''))
    if (!tmdb) return null
    if (media.format === 'MOVIE') return { tmdb }
    const details = await tmdbClient.getDetails(tmdb, 'tv').catch(() => null)
    const mapped = tmdbSeasonEpisode(details?.seasons, number)
    return mapped ? { tmdb, ...mapped } : null
  }
  const mappings = await getAniMappings(media.id).catch(error => {
    debug('ani.zip mappings failed', error)
    return null
  })
  return animeQuery(mappings, number, media.format === 'MOVIE')
}

/**
 * Chapters of an episode (or movie) from TheIntroDB, [] when it has nothing for it or cannot be reached.
 * @param {any} media AniList or TMDB media
 * @param {number} episode
 * @param {number} duration video length in seconds
 */
export async function getChaptersIntroDB (media, episode, duration) {
  const query = await introDbQuery(media, episode)
  const url = query && introDbUrl(query, duration)
  if (!url) return []
  if (!answers.has(url)) {
    const request = fetch(url, { signal: AbortSignal.timeout(15_000) }).then(async response => {
      // 404: nothing submitted for this episode yet (or unknown media); 429: rate limited.
      if (!response.ok) {
        debug('TheIntroDB answered', response.status)
        if (response.status !== 404) answers.delete(url)
        return null
      }
      return response.json()
    }).catch(error => {
      debug('TheIntroDB request failed', error)
      answers.delete(url)
      return null
    })
    if (answers.size >= 50) answers.delete(answers.keys().next().value)
    answers.set(url, request)
  }
  return introDbChapters(await answers.get(url), duration)
}
