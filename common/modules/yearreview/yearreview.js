// Year in Review: AniList data (list activities of the year, list entries, progress before the year),
// cached per user and year in IndexedDB, and the local watch history of TMDB shows / movies.
// Statistics are computed by stats.js. Ported to Swift in ios-native/Tsumi/Services/YearReviewService.swift.
import { writable } from 'simple-store-svelte'
import { alToken, malToken } from '@/modules/settings.js'
import { anilistClient } from '@/modules/anilist.js'
import { cache, caches } from '@/modules/cache.js'
import { computeYearStats, computeLocalStats, availableYears, mediaNeedingPrior, priorFromActivities, yearBounds, MONTH_NAMES } from './stats.js'
import Debug from 'debug'
const debug = Debug('ui:yearreview')

const ENDPOINT = 'https://graphql.anilist.co'
/** Bump when the cached data shape changes. */
const DATA_VERSION = 1
const DAY = 24 * 60 * 60
/** The current year is refreshed (incrementally) after this many seconds. */
const CURRENT_YEAR_TTL = 3 * 60 * 60
const ENTRIES_TTL = 6 * 60 * 60
/** Incremental refreshes re-read this much activity before the last fetch (AniList merges recent activities). */
const OVERLAP = 2 * DAY
const MAX_PAGES = 400

/** Overlay state: { open, year } (year null = default year). */
export const yearReviewView = writable({ open: false, year: null })

export function openYearReview (year = null) {
  yearReviewView.set({ open: true, year })
}

export function closeYearReview () {
  yearReviewView.set({ open: false, year: null })
}

/** Who can see a review: { kind: 'anilist', userId, name, avatar, token } | { kind: 'mal', name } | { kind: 'none' }. */
export function reviewAccount () {
  const viewer = alToken?.viewer?.data?.Viewer
  if (alToken?.token && viewer?.id) {
    return { kind: 'anilist', userId: viewer.id, name: viewer.name || 'AniList User', avatar: viewer.avatar?.large || viewer.avatar?.medium || null, token: alToken.token }
  }
  if (malToken) return { kind: 'mal', name: malToken.viewer?.data?.Viewer?.name || 'MyAnimeList User' }
  return { kind: 'none' }
}

// --- Storage (own IndexedDB database, one record per key) ---

const DB_NAME = 'tsumi-year-review'
const STORE = 'reviews'
const memoryStore = new Map()
let databasePromise = null

function database () {
  if (!databasePromise) {
    databasePromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, 1)
      request.onupgradeneeded = () => request.result.createObjectStore(STORE)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    }).catch(error => {
      debug('IndexedDB unavailable, keeping the reviews in memory', error)
      return null
    })
  }
  return databasePromise
}

async function storeGet (key) {
  const db = await database()
  if (!db) return memoryStore.get(key) ?? null
  return new Promise(resolve => {
    const request = db.transaction(STORE, 'readonly').objectStore(STORE).get(key)
    request.onsuccess = () => resolve(request.result ?? null)
    request.onerror = () => resolve(null)
  })
}

async function storeSet (key, value) {
  memoryStore.set(key, value)
  const db = await database()
  if (!db) return
  await new Promise(resolve => {
    const transaction = db.transaction(STORE, 'readwrite')
    transaction.objectStore(STORE).put(value, key)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => resolve()
    transaction.onabort = () => resolve()
  })
}

// --- Transport ---

function abortError () {
  const error = new Error('Cancelled')
  error.name = 'AbortError'
  return error
}

/** Waits `seconds`, reporting the countdown (rate limit) through `onWait`. */
async function countdown (seconds, onWait, signal) {
  for (let left = Math.ceil(seconds); left > 0; left--) {
    if (signal?.aborted) throw abortError()
    onWait?.(left)
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
  onWait?.(0)
}

function errorMessage (json, status) {
  const message = json?.errors?.[0]?.message
  if (message) return message
  return status ? `AniList returned HTTP ${status}` : 'AniList returned no data'
}

/**
 * One GraphQL request through the app-wide AniList limiter. 429 waits for Retry-After (AniList is sometimes
 * degraded to 30 requests / minute), 5xx and network errors back off, and a nearly exhausted
 * X-RateLimit-Remaining pauses before the next request.
 */
async function request (query, variables, { token, signal, onWait } = {}) {
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json' }
  if (token) headers.Authorization = token.startsWith('Bearer ') ? token : `Bearer ${token}`
  const body = JSON.stringify({ query, variables })
  let failures = 0
  for (let attempt = 0; attempt < 10; attempt++) {
    if (signal?.aborted) throw abortError()
    await anilistClient.rateLimitPromise
    // Never rejects: a rejected job would go through the limiter's retry / toast handler.
    const { res, error } = await anilistClient.limiter.schedule(() => fetch(ENDPOINT, { method: 'POST', credentials: 'omit', headers, body, signal }).then(res => ({ res }), error => ({ error })))
    if (signal?.aborted) throw abortError()
    if (error) {
      if (++failures > 3) throw new Error('Could not reach AniList. Check your connection and try again.')
      await countdown(Math.min(5 * 2 ** failures, 30), null, signal)
      continue
    }
    if (res.status === 429) {
      const retryAfter = Number(res.headers.get('retry-after'))
      await countdown((Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 60) + 1, onWait, signal)
      continue
    }
    if (res.status >= 500) {
      if (++failures > 3) throw new Error(`AniList is having trouble (HTTP ${res.status}). Try again later.`)
      await countdown(Math.min(5 * 2 ** failures, 30), null, signal)
      continue
    }
    const json = await res.json().catch(() => null)
    if (!res.ok || !json?.data) throw new Error(errorMessage(json, res.ok ? 0 : res.status))
    const remaining = res.headers.get('x-ratelimit-remaining')
    if (remaining !== null && Number(remaining) <= 2) {
      const reset = Number(res.headers.get('x-ratelimit-reset'))
      const wait = reset > 0 ? reset - Date.now() / 1000 : 20
      await countdown(Math.max(1, Math.min(60, wait)), onWait, signal)
    }
    return json
  }
  throw new Error('AniList keeps rate limiting requests. Try again in a few minutes.')
}

// --- Queries ---

const MEDIA_FIELDS = 'id title { userPreferred english romaji } coverImage { extraLarge large color } bannerImage format episodes duration genres'

const ENTRIES_QUERY = `query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME, forceSingleCompletedList: true) {
    lists {
      entries {
        status score(format: POINT_10_DECIMAL) progress repeat updatedAt createdAt
        startedAt { year month day }
        completedAt { year month day }
        media { ${MEDIA_FIELDS} studios { edges { isMain node { name isAnimationStudio } } } }
      }
    }
  }
}`

const ACTIVITIES_QUERY = `query ($userId: Int, $page: Int, $after: Int, $before: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    activities(userId: $userId, type: ANIME_LIST, createdAt_greater: $after, createdAt_lesser: $before, sort: ID) {
      ... on ListActivity { id status progress createdAt media { ${MEDIA_FIELDS} } }
    }
  }
}`

const PRIOR_QUERY = `query ($userId: Int, $page: Int, $mediaIds: [Int], $before: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    activities(userId: $userId, type: ANIME_LIST, mediaId_in: $mediaIds, createdAt_lesser: $before, sort: ID_DESC) {
      ... on ListActivity { id status progress createdAt media { id } }
    }
  }
}`

function normalizeMedia (media) {
  return {
    id: media.id,
    title: media.title?.userPreferred || media.title?.english || media.title?.romaji || 'Unknown title',
    cover: media.coverImage?.extraLarge || media.coverImage?.large || null,
    color: media.coverImage?.color || null,
    banner: media.bannerImage || null,
    format: media.format || null,
    episodes: media.episodes || null,
    duration: media.duration || null,
    genres: media.genres || [],
    studios: mainStudios(media.studios?.edges)
  }
}

/** Main studios of a media (studios(isMain: true) is ignored inside MediaListCollection, so edges are filtered here). */
function mainStudios (edges) {
  const named = (edges || []).filter(edge => edge?.node?.name)
  const main = named.filter(edge => edge.isMain)
  return [...new Set((main.length ? main : named.filter(edge => edge.node.isAnimationStudio)).map(edge => edge.node.name))]
}

/** Keeps the non-empty fields of both (list entries carry the studios, activities do not). */
function mergeMedia (current, next) {
  if (!current) return next
  const merged = { ...current }
  for (const [key, value] of Object.entries(next)) {
    if (value !== null && value !== undefined && !(Array.isArray(value) && !value.length)) merged[key] = value
  }
  return merged
}

async function fetchEntries (account, { signal, onWait }) {
  const json = await request(ENTRIES_QUERY, { userId: account.userId }, { token: account.token, signal, onWait })
  const entries = []
  const media = {}
  const seen = new Set()
  for (const list of json.data.MediaListCollection?.lists || []) {
    for (const entry of list?.entries || []) {
      if (!entry?.media?.id || seen.has(entry.media.id)) continue
      seen.add(entry.media.id)
      media[entry.media.id] = normalizeMedia(entry.media)
      entries.push({
        mediaId: entry.media.id,
        status: entry.status,
        score: entry.score || 0,
        progress: entry.progress || 0,
        repeat: entry.repeat || 0,
        startedAt: entry.startedAt?.year ? entry.startedAt : null,
        completedAt: entry.completedAt?.year ? entry.completedAt : null,
        updatedAt: entry.updatedAt || 0,
        createdAt: entry.createdAt || 0
      })
    }
  }
  return { fetchedAt: Math.floor(Date.now() / 1000), entries, media }
}

const pendingEntries = new Map()

/** List entries of the user, cached ENTRIES_TTL (they also give the years of the picker). */
async function loadEntries (account, { force, onWait, onProgress } = {}) {
  const key = `entries:${account.userId}`
  const cached = await storeGet(key)
  const now = Math.floor(Date.now() / 1000)
  if (!force && cached?.v === DATA_VERSION && now - cached.fetchedAt < ENTRIES_TTL) return cached
  onProgress?.({ message: 'Reading your AniList list…', fraction: 0 })
  // The year picker and the review ask at the same time: one request (not shared by forced refreshes).
  if (!force && pendingEntries.has(key)) return pendingEntries.get(key)
  const pending = (async () => {
    try {
      // Not cancelled with the review: one request, shared by the callers and cached.
      const fresh = { v: DATA_VERSION, ...await fetchEntries(account, { onWait }) }
      await storeSet(key, fresh)
      return fresh
    } catch (error) {
      if (cached?.v === DATA_VERSION && error.name !== 'AbortError') {
        debug('Using the cached list entries', error)
        return cached
      }
      throw error
    }
  })()
  if (!force) {
    pendingEntries.set(key, pending)
    pending.finally(() => pendingEntries.delete(key)).catch(() => {})
  }
  return pending
}

/** Every ListActivity created in [after + 1, before), page by page. */
async function fetchActivities (account, { after, before, start, signal, onWait, onProgress }) {
  const activities = []
  const media = {}
  const span = Math.max(1, Math.min(before, Date.now() / 1000) - start)
  for (let page = 1; page <= MAX_PAGES; page++) {
    const json = await request(ACTIVITIES_QUERY, { userId: account.userId, page, after, before }, { token: account.token, signal, onWait })
    const raw = json.data.Page?.activities || []
    const items = raw.filter(item => item?.id && item.media?.id)
    let latest = 0
    for (const item of items) {
      media[item.media.id] = mergeMedia(media[item.media.id], normalizeMedia(item.media))
      activities.push({ id: item.id, status: item.status, progress: item.progress ?? null, createdAt: item.createdAt, mediaId: item.media.id })
      latest = Math.max(latest, item.createdAt)
    }
    if (latest) {
      const month = MONTH_NAMES[new Date(latest * 1000).getMonth()]
      onProgress?.({ message: `Reading your activity… ${month} (${activities.length} updates)`, fraction: Math.min(0.95, Math.max(0.05, (latest - start) / span)) })
    }
    if (!json.data.Page?.pageInfo?.hasNextPage || !raw.length) break
  }
  return { activities, media }
}

/** Progress before the year of the given titles (newest earlier activity of each). */
async function fetchPrior (account, mediaIds, before, media, { signal, onWait }) {
  if (!mediaIds.length) return {}
  const found = []
  for (let page = 1; page <= 3; page++) {
    const json = await request(PRIOR_QUERY, { userId: account.userId, page, mediaIds, before }, { token: account.token, signal, onWait })
    const items = (json.data.Page?.activities || []).filter(item => item?.media?.id)
    found.push(...items.map(item => ({ mediaId: item.media.id, status: item.status, progress: item.progress })))
    const prior = priorFromActivities(found, media)
    if (mediaIds.every(id => id in prior) || !json.data.Page?.pageInfo?.hasNextPage) break
  }
  return priorFromActivities(found, media)
}

function isFresh (dataset, year) {
  if (dataset?.v !== DATA_VERSION) return false
  const now = Math.floor(Date.now() / 1000)
  const { end } = yearBounds(year)
  if (dataset.fetchedAt >= end + OVERLAP) return true // fetched after the year was over
  return year >= new Date().getFullYear() && now - dataset.fetchedAt < CURRENT_YEAR_TTL
}

/** Entries that matter for the year: titles of its activities, or started / completed during it. */
function relevantEntries (entries, mediaIds, year) {
  return entries.filter(entry => mediaIds.has(entry.mediaId) || entry.startedAt?.year === year || entry.completedAt?.year === year)
}

/**
 * Loads the AniList data of a year (cache first) and computes its statistics.
 * @param {{ year: number, force?: boolean, signal?: AbortSignal, onProgress?: (progress: { message: string, fraction: number, wait?: number }) => void }} options
 */
export async function loadYearReview ({ year, force = false, signal, onProgress }) {
  const account = reviewAccount()
  if (account.kind !== 'anilist') throw new Error('Year in Review needs an AniList account.')
  let lastProgress = { message: 'Loading…', fraction: 0 }
  const progress = (value) => {
    lastProgress = value
    onProgress?.(value)
  }
  const onWait = (seconds) => onProgress?.({ ...lastProgress, wait: seconds })
  const key = `review:${account.userId}:${year}`

  let dataset = await storeGet(key)
  if (dataset?.v !== DATA_VERSION) dataset = null
  let stale = false
  if (force || !isFresh(dataset, year)) {
    try {
      dataset = await fetchDataset(account, { year, dataset, force, signal, onWait, progress })
      await storeSet(key, dataset)
    } catch (error) {
      // Offline / AniList down: the last cached data of the year is better than nothing.
      if (!dataset || error.name === 'AbortError') throw error
      debug('Showing the cached review after a failed refresh', error)
      stale = true
    }
  }
  progress({ message: 'Done', fraction: 1 })
  const cleanPrior = Object.fromEntries(Object.entries(dataset.prior || {}).filter(([, value]) => typeof value === 'number'))
  const stats = computeYearStats({ year, activities: dataset.activities, media: dataset.media, entries: dataset.entries, prior: cleanPrior })
  return { year, stats, media: dataset.media, fetchedAt: dataset.fetchedAt, stale, local: localReview(year) }
}

/** Fetches (or completes, for an incremental refresh) the AniList data of a year. */
async function fetchDataset (account, { year, dataset, force, signal, onWait, progress }) {
  const { start, end } = yearBounds(year)
  const entries = await loadEntries(account, { force, onWait, onProgress: progress })
  if (signal?.aborted) throw abortError()
  const incremental = !force && dataset && dataset.fetchedAt > start
  const after = incremental ? Math.max(start - 1, dataset.fetchedAt - OVERLAP) : start - 1
  progress({ message: 'Reading your activity…', fraction: 0.05 })
  const fetched = await fetchActivities(account, { after, before: end, start, signal, onWait, onProgress: progress })

  const byId = new Map((incremental ? dataset.activities : []).map(activity => [activity.id, activity]))
  for (const activity of fetched.activities) byId.set(activity.id, activity)
  const activities = [...byId.values()].sort((a, b) => a.id - b.id)
  const mediaIds = new Set(activities.map(activity => activity.mediaId))
  const yearEntries = relevantEntries(entries.entries, mediaIds, year)
  for (const entry of yearEntries) mediaIds.add(entry.mediaId)
  const media = {}
  for (const id of mediaIds) {
    media[id] = mergeMedia(mergeMedia(incremental ? dataset.media?.[id] : null, fetched.media[id] || null), entries.media[id] || null)
    if (!media[id]) delete media[id]
  }

  const prior = incremental ? { ...dataset.prior } : {}
  const missing = mediaNeedingPrior({ year, activities, media, entries: yearEntries }).filter(id => !(id in prior)).slice(0, 100)
  if (missing.length) {
    progress({ message: 'Checking where you left off last year…', fraction: 0.97 })
    Object.assign(prior, await fetchPrior(account, missing, start, media, { signal, onWait }))
    for (const id of missing) if (!(id in prior)) prior[id] = null
  }

  return { v: DATA_VERSION, year, userId: account.userId, fetchedAt: Math.floor(Date.now() / 1000), activities, media, entries: yearEntries, prior }
}

/** Years of the picker (needs the list entries: one request when they are not cached). */
export async function loadYears ({ onProgress } = {}) {
  const account = reviewAccount()
  const extra = localYears()
  if (account.kind !== 'anilist') return availableYears([], new Date(), extra)
  try {
    const entries = await loadEntries(account, { onProgress })
    return availableYears(entries.entries, new Date(), extra)
  } catch (error) {
    if (error.name === 'AbortError') throw error
    debug('Could not load the list entries for the year picker', error)
    return availableYears([], new Date(), extra)
  }
}

// --- Local watch history (shows and movies from TMDB) ---

function localRecords () {
  const history = cache.getEntry(caches.HISTORY, 'animeEpisodeProgress') || []
  return history
    .filter(record => typeof record?.mediaId === 'string' && record.mediaId.startsWith('tmdb-'))
    .map(record => ({ key: record.mediaId, episode: record.episode, currentTime: record.currentTime, duration: record.safeduration, updatedAt: record.updatedAt }))
}

function localYears () {
  return [...new Set(localRecords().map(record => new Date(record.updatedAt).getFullYear()).filter(Number.isFinite))]
}

/** Local history stats of the year, with the titles / posters of the media cache. */
export function localReview (year) {
  const stats = computeLocalStats(localRecords(), year)
  stats.top = stats.top.map(item => {
    const media = cache.getMedia(item.key) || {}
    return {
      ...item,
      title: media.title?.userPreferred || media.title?.english || media.title?.romaji || 'Unknown title',
      cover: media.coverImage?.extraLarge || media.coverImage?.medium || null,
      isMovie: media.format === 'MOVIE'
    }
  })
  return stats
}
