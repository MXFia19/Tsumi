import { cache, caches } from '@/modules/cache.js'
import { getKitsuMappings } from '@/modules/anime/anime.js'
import { codes, getRandomInt, sleep } from '@/modules/util.js'
import { printError, status, isOffline } from '@/modules/networking.js'
import Bottleneck from 'bottleneck'
import Debug from 'debug'
const debug = Debug('ui:episodes')

/*
 * MAL Episode Information
 * api.jikan.moe was discontinued: episode titles, filler / recap flags and trailers come from Jikan v4 mirrors.
 */

/** Jikan v4 mirrors, tried in order. Tenrai follows the Jikan v4 schema; jikan-edge has its own camelCase schema (normalizeJikanEdge). */
const JIKAN_MIRRORS = [
  { name: 'tenrai', base: 'https://api.tenrai.org/v1' },
  { name: 'jikanEdge', base: 'https://jikan.lucashdo.com/v1', normalize: normalizeJikanEdge }
]

const EDGE_MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']

/** jikan-edge dates look like "Sep 29, 2023": converted to the Jikan ISO form ("2023-09-29T00:00:00+00:00"). */
function edgeDate (text) {
  const match = /^([A-Za-z]{3})\w*\s+(\d{1,2}),\s*(\d{4})$/.exec(String(text || '').trim())
  const month = match && EDGE_MONTHS.indexOf(match[1].toLowerCase())
  if (!match || month < 0) return null
  return `${match[3]}-${String(month + 1).padStart(2, '0')}-${match[2].padStart(2, '0')}T00:00:00+00:00`
}

/** Converts a jikan-edge answer to the Jikan v4 fields this module reads. */
function normalizeJikanEdge (json, root) {
  if (!json || typeof json !== 'object') return json
  if (root) {
    const data = json.data || {}
    return { data: { ...data, mal_id: data.malId, title_english: data.titleEnglish, title_japanese: data.titleJapanese, trailer: { youtube_id: data.trailer?.youtubeId ?? null, url: data.trailer?.url ?? null, embed_url: data.trailer?.embedUrl ?? null } } }
  }
  const pagination = json.meta?.pagination
  return {
    pagination: { has_next_page: !!pagination?.hasNextPage, current_page: pagination?.page },
    data: (Array.isArray(json.data) ? json.data : []).map(e => ({
      mal_id: e.number,
      url: e.url,
      title: e.title,
      title_romanji: e.titleRomanji,
      title_japanese: e.titleJapanese,
      aired: edgeDate(e.aired),
      score: e.score,
      filler: !!e.filler,
      recap: !!e.recap
    }))
  }
}

class Episodes {
  limiter = new Bottleneck({
    reservoir: 60,
    reservoirRefreshAmount: 60,
    reservoirRefreshInterval: 60 * 1000,
    maxConcurrent: 3,
    minTime: 333
  })

  rateLimitPromise = null
  concurrentRequests = new Map()
  /** An API that timed out or could not be reached is skipped for a while, so the episode list never waits on it. */
  downUntil = { tenrai: 0, jikanEdge: 0, kitsu: 0 }

  /** True when at least one server of the API ('jikan' = any Jikan mirror, or 'kitsu') is not being skipped. */
  available (api) {
    if (api === 'jikan') return JIKAN_MIRRORS.some(mirror => Date.now() >= this.downUntil[mirror.name])
    return Date.now() >= this.downUntil[api]
  }

  constructor () {
    this.limiter.on('failed', async (error) => {
      if (typeof error?.json !== 'function') return // not an HTTP response (network error): don't retry
      const info = (await error.json().catch(() => null)) || error
      if (await isOffline(info)) throw new Error('Failed making episode request, network is offline... not retrying.')
      if (info.status === 500) return 1

      const time = ((error.headers.get('retry-after') || 2) + 1) * 1000
      if (!this.rateLimitPromise) this.rateLimitPromise = sleep(time).then(() => { this.rateLimitPromise = null })
      return time
    })
  }

  async getEpisodeData (idMal) {
    if (!idMal) return []
    const page = 1
    const res = await this.requestEpisodes(true, idMal, page)
    if (res && res.pagination?.has_next_page && res.pagination?.last_visible_page) {
      const lastRes = await this.requestEpisodes(true, idMal, res.pagination.last_visible_page * 100)
      const arr = lastRes?.data?.map(e => ({
        filler: e.filler,
        recap: e.recap,
        episode_id: e.mal_id, // mal_id is the episode_id in the v4 API very stupid
        title: e.title || e.title_romanji || e.title_japanese,
        aired: e.aired
      }))
      return arr || []
    } else {
      return res?.data?.map(e => ({
        filler: e.filler,
        recap: e.recap,
        episode_id: e.mal_id, // mal_id is the episode_id in the v4 API very stupid
        title: e.title || e.title_romanji || e.title_japanese,
        aired: e.aired
      })) || []
    }
  }

  async getSingleEpisode (idMal, episode) {
    if (!idMal) return []
    const res = await this.requestEpisodes(true, idMal, Number(episode || 1) !== 0 ? (episode || 1) : 1)
    const singleEpisode = res?.data?.find(e => (e.mal_id === episode) || (e.mal_id === Number(episode || 1)))
    return singleEpisode ? {
      filler: singleEpisode.filler,
      recap: singleEpisode.recap,
      episode_id: singleEpisode.mal_id, // mal_id is the episode_id in the v4 API very stupid
      title: singleEpisode.title || singleEpisode.title_romanji || singleEpisode.title_japanese,
      aired: singleEpisode.aired
    } : []
  }

  async getKitsuEpisodes (id) {
    const mappings = await getKitsuMappings(id)
    const kitsuId = mappings?.data?.[0]?.relationships?.data?.id || mappings?.included?.[0]?.id
    if (kitsuId) {
      return this.requestEpisodes(false, kitsuId, 1)
    }
    return null
  }

  async getMedia (idMal) {
    if (!idMal) return []
    return this.requestEpisodes(true, idMal, 1, true)
  }

  handleArray (episodes, fileName) {
    const episodeParts = (Array.isArray(episodes) && episodes) || (fileName?.match(/(?<!Part\s)(?<!Cour\s)\b\d+\s*[-~]\s*\d+\b/i)?.map(n => +n.trim())) || (typeof episodes === 'string' && episodes.match(/^\d+\s*~\s*\d+$/) && episodes.split(/~\s*/).map(n => +n.trim()))
    if (episodeParts?.length && ((Number(episodeParts[0]) || episodeParts[0]) < (Number(episodeParts[1]) || episodeParts[1]))) return { first: (Number(episodeParts[0]) || episodeParts[0]), last: (Number(episodeParts[1]) || episodeParts[1]) }
    return null
  }

  async requestEpisodes (jikan, id, episode, root) {
    const page = Math.ceil(episode / 100)
    const cachedEntry = cache.cachedEntry(caches.EPISODES, `${id}:${page}:${root}`, status.value === 'offline')
    if (cachedEntry) return cachedEntry
    else if (status.value === 'offline') return
    const api = jikan ? 'jikan' : 'kitsu'
    if (!this.available(api)) return cache.cachedEntry(caches.EPISODES, `${id}:${page}:${root}`, true) || null
    if (this.concurrentRequests.has(`${id}:${page}:${root}`)) return this.concurrentRequests.get(`${id}:${page}:${root}`)
    const requestPromise = this.limiter.wrap(async () => {
      await this.rateLimitPromise
      if (!this.available(api)) return cache.cachedEntry(caches.EPISODES, `${id}:${page}:${root}`, true) || null
      debug(`Fetching Episode ${episode} for ${id} with Page ${page}`)
      const targets = jikan
        ? JIKAN_MIRRORS.map(mirror => ({ name: mirror.name, url: `${mirror.base}/anime/${id}${!root ? `/episodes?page=${page}` : ''}`, normalize: mirror.normalize }))
        : [{ name: 'kitsu', url: `https://kitsu.app/api/edge/anime/${id}/episodes` }]
      let res = null
      let normalize = null
      for (const target of targets) {
        if (Date.now() < this.downUntil[target.name]) continue
        try {
          const response = await fetch(target.url, { signal: AbortSignal.timeout(10_000) })
          // Server error or Cloudflare block (403): treated like an unreachable server, the next mirror is tried.
          if (response.status >= 500 || response.status === 403) throw new Error(`${target.name} answered ${response.status}`)
          res = response
          normalize = target.normalize
          break
        } catch (e) {
          // Timeout or unreachable server: skip it for 10 minutes instead of blocking the episode list.
          this.downUntil[target.name] = Date.now() + 10 * 60 * 1000
          debug(`${target.name} is unreachable, skipping it for 10 minutes`, e)
        }
      }
      if (!res) return cache.cachedEntry(caches.EPISODES, `${id}:${page}:${root}`, true) || null
      if (res.status === 429) {
        throw res
      }
      let json = null
      try {
        json = await res.json()
        if (res.ok && normalize) json = normalize(json, root)
      } catch (error) {
        if (res.ok) this.checkError(error, `${jikan ? 'jikan' : 'kitsu'}`)
      }
      if (!res.ok) {
        if (json) {
          for (const error of json?.errors || []) {
            this.checkError(error, `${jikan ? 'jikan' : 'kitsu'}`, true)
          }
        } else {
          this.checkError(res, `${jikan ? 'jikan' : 'kitsu'}`)
        }
      }
      return cache.cacheEntry(caches.EPISODES, `${id}:${page}:${root}`, {}, json, Date.now() + getRandomInt(1, 3) * 24 * 60 * 60 * 1000)
    })().catch((error) => {
      // Episode titles / filler flags are optional: fall back to stale data (or nothing) instead of failing the list.
      debug('Episode request failed, returning cached episode data if available', error)
      return cache.cachedEntry(caches.EPISODES, `${id}:${page}:${root}`, true) || null
    }).finally(() => {
      this.concurrentRequests.delete(`${id}:${page}:${root}`)
    })
    this.concurrentRequests.set(`${id}:${page}:${root}`, requestPromise)
    return requestPromise
  }

  checkError (error, type, silent) {
    if (!error || error.status === 404 || error.status === 521) { // api is likely down, we don't need to spam the user with toasts.
      debug(`Error (API Down): ${error.status || 429} - ${error.message || codes[error.status || 429]}`)
      return
    }
    if (!silent) printError('Episode Fetching Failed', `Failed to fetch ${type} anime episodes!`, error)
  }
}

export const episodesList = new Episodes()
