// "Relevance" paging of the search page: text searches with no explicit sort are fetched with AniList's
// SEARCH_MATCH order (and TMDB's text search), then ranked by title relevance (relevance.js). The first
// page also merges the titles already known locally (media cache, which holds the user's lists) that match
// the query fuzzily, so typos and partial titles still find shows the user has seen. Later pages are
// ranked within themselves and appended without duplicates. iOS: Services/SearchRelevance.swift.
import { mediaCache } from '@/modules/cache.js'
import { settings } from '@/modules/settings.js'
import { anilistClient } from '@/modules/anilist.js'
import { fuzzyMatches, rankByRelevance, relevancePopularity, prepare, LOCAL_MIN_QUERY_LENGTH } from '@/modules/search/relevance.js'
import Debug from 'debug'
const debug = Debug('ui:relevance')

/** Local fuzzy matches merged into the first page. */
const LOCAL_LIMIT = 20
/** Pages fetched at most for one requested page (guards against empty intermediate pages). */
const MAX_FETCHES = 10
const CHUNK = 500

/** @type {Map<string, object>} */
const snapshots = new Map()

/**
 * Snapshot key of a search: its variables (functions and stores left out), page size and account.
 * @param {object} search
 * @param {number} perPage
 * @param {string|number} [account]
 */
export function relevanceKey (search, perPage, account) {
  return JSON.stringify([perPage, account ?? null, search], (key, value) => (typeof value === 'function' || key === 'load' || key === 'preview') ? undefined : value)
}

/**
 * Media of the local cache that match the query, filtered like the searched sources.
 * @param {string} query
 * @param {{ anime: object|null, western: boolean }} recorded variables of the AniList search, TMDB searched
 */
async function localMatches (query, recorded) {
  if (prepare(query).chars.length < LOCAL_MIN_QUERY_LENGTH) return []
  const pool = []
  if (recorded.anime) {
    // fallbackSearch applies the same filters as the AniList query (format, status, genres, adult, ids...).
    const filtered = await anilistClient.fallbackSearch({ ...recorded.anime, search: undefined, sort: undefined, page: 1, perPage: Number.MAX_SAFE_INTEGER })
    pool.push(...(filtered?.data?.Page?.media || []).filter(media => media && typeof media.id === 'number'))
  }
  if (recorded.western) {
    const adult = settings.value.adult !== 'none'
    pool.push(...Object.values(mediaCache?.value || {}).filter(media => media && typeof media.id === 'string' && media.id.startsWith('tmdb-') && (adult || !media.isAdult)))
  }
  // Scored in chunks so a large cache does not freeze the page; same result as one fuzzyMatches call
  // (each chunk is sorted, the stable merge keeps the original order for ties).
  const matches = []
  for (let start = 0; start < pool.length; start += CHUNK) {
    if (start) await new Promise(resolve => setTimeout(resolve))
    matches.push(...fuzzyMatches(query, pool.slice(start, start + CHUNK), { limit: LOCAL_LIMIT }))
  }
  return matches.map((match, index) => ({ ...match, index, popularity: relevancePopularity(match.media) }))
    .sort((a, b) => (b.score - a.score) || (b.popularity - a.popularity) || (a.index - b.index))
    .slice(0, LOCAL_LIMIT)
    .map(({ media }) => media)
}

/**
 * One page of a relevance search.
 * @param {object} options
 * @param {string} options.key snapshot key (relevanceKey)
 * @param {number} options.page
 * @param {number} options.perPage
 * @param {string} options.query the text query
 * @param {(page: number, recorded: { anime: object|null, western: boolean }) => Promise<any>} options.fetchPage
 *   fetches one page of the sources (AniList sorted by SEARCH_MATCH), recording what it searched
 * @returns {Promise<{ data: { Page: { pageInfo: { hasNextPage: boolean }, media: object[] } } } | any>}
 */
export function relevancePage ({ key, page = 1, perPage = 50, query, fetchPage }) {
  let snapshot = snapshots.get(key)
  if (!snapshot || page === 1) {
    snapshot = { items: [], ids: new Set(), nextPage: 1, hasNextPage: true, merged: false, failure: null, recorded: { anime: null, western: false }, pending: Promise.resolve() }
    snapshots.delete(key)
    if (snapshots.size >= 10) snapshots.delete(snapshots.keys().next().value)
    snapshots.set(key, snapshot)
  }
  const start = (page - 1) * perPage
  const end = start + perPage
  const request = snapshot.pending.then(async () => {
    const batch = []
    const add = media => {
      if (!media || media.id == null || snapshot.ids.has(media.id)) return
      snapshot.ids.add(media.id)
      batch.push(media)
    }
    let fetches = 0
    while (snapshot.hasNextPage && snapshot.items.length + batch.length < end && fetches < MAX_FETCHES) {
      fetches++
      const res = await fetchPage(snapshot.nextPage, snapshot.recorded)
      snapshot.nextPage++
      const media = res?.data?.Page?.media
      if (!Array.isArray(media)) {
        snapshot.hasNextPage = false
        if (!snapshot.items.length && !batch.length) snapshot.failure = res
        break
      }
      media.forEach(add)
      snapshot.hasNextPage = !!res.data.Page.pageInfo?.hasNextPage
    }
    if (!snapshot.merged) {
      snapshot.merged = true
      try {
        const local = await localMatches(query, snapshot.recorded)
        local.forEach(add)
        if (local.length) debug(`Merged ${local.length} local matches for "${query}"`)
      } catch (error) {
        debug('Local relevance matches failed:', error)
      }
    }
    snapshot.items.push(...rankByRelevance(query, batch))
    if (!snapshot.items.length && snapshot.failure) return snapshot.failure
    return { data: { Page: { pageInfo: { hasNextPage: snapshot.hasNextPage || snapshot.items.length > end }, media: snapshot.items.slice(start, end) } } }
  })
  snapshot.pending = request.catch(() => {})
  return request.catch(error => {
    if (snapshots.get(key) === snapshot) snapshots.delete(key)
    throw error
  })
}
