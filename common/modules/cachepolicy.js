// Cache and retry policy of the data sources (AniList, MyAnimeList, ani.zip, Kitsu, Jikan, TMDB): how long each
// answer stays fresh, how much of each cache is kept, and how failed requests are retried.
// Pure module (no app imports), tested by cachepolicy.test.mjs.
import { toLocalDate } from './dates.js'

export const SECOND = 1000
export const MINUTE = 60 * SECOND
export const HOUR = 60 * MINUTE
export const DAY = 24 * HOUR
export const WEEK = 7 * DAY

/**
 * Random duration between min and max (both in ms), so entries cached together don't all expire together.
 * @param {number} min
 * @param {number} [max]
 * @param {() => number} [random]
 */
export function jitter (min, max = min, random = Math.random) {
  return Math.round(min + (max - min) * random())
}

/**
 * Freshness of the answers of each source, [min, max] in ms (a random value in between is used).
 * AniList: list sections are re-queried often, details rarely change. Jikan / Kitsu episodes: titles and filler
 * flags. MALDubs: dub list of the MAL-Dubs project.
 */
export const TTL = {
  anilistNotifications: [4 * MINUTE], // re-cached by the 5 minute notification check
  anilistUserLists: [14 * MINUTE], // re-cached by the 15 minute list refresh
  anilistCompound: [60 * MINUTE, 90 * MINUTE],
  anilistSearch: [75 * MINUTE, 100 * MINUTE],
  anilistMedia: [80 * MINUTE, 100 * MINUTE],
  anilistSearchIds: [24 * MINUTE, 30 * MINUTE],
  anilistAllIds: [34 * MINUTE, 46 * MINUTE],
  anilistEpisodes: [75 * MINUTE, 100 * MINUTE],
  anilistEpisodeDate: [90 * MINUTE, 100 * MINUTE],
  anilistFollowing: [200 * MINUTE, 300 * MINUTE],
  anilistRecommendations: [1500 * MINUTE, 2000 * MINUTE],
  jikanEpisodes: [DAY, 3 * DAY],
  kitsuPartialEpisodes: [HOUR], // an episode page failed: try again soon
  malDubs: [100 * MINUTE, 200 * MINUTE],
  tmdbReleaseDates: [12 * HOUR], // digital release dates are often added late
  tmdbCollection: [WEEK],
  tmdbImagesFound: [4 * WEEK],
  tmdbImagesMissing: [3 * DAY] // logos and backdrops get added later
}

/**
 * Expiry timestamp of an answer cached now for a TTL range of {@link TTL}.
 * @param {number[]} range
 * @param {number} [now]
 * @param {() => number} [random]
 */
export function expiresIn (range, now = Date.now(), random = Math.random) {
  return now + jitter(range[0], range[1] ?? range[0], random)
}

/**
 * True when a media finished airing at least a month ago (its ani.zip / Kitsu mappings won't change much).
 * @param {any} media AniList media
 * @param {number} [now]
 */
export function finishedLongAgo (media, now = Date.now()) {
  if (media?.status !== 'FINISHED') return false
  const date = new Date(now)
  if (media.endDate?.year) return (date.getFullYear() - media.endDate.year) * 12 + (date.getMonth() + 1 - (media.endDate.month || 12)) >= 1
  const year = media.startDate?.year || media.seasonYear
  return !!year && date.getFullYear() - year >= 1
}

/**
 * ani.zip and Kitsu mappings: 60 to 90 minutes while a series airs, 2 to 3 weeks once it finished.
 * @param {any} media AniList media
 * @param {number} [now]
 * @param {() => number} [random]
 */
export function mappingTtl (media, now = Date.now(), random = Math.random) {
  return finishedLongAgo(media, now) ? jitter(14 * DAY, 21 * DAY, random) : jitter(60 * MINUTE, 90 * MINUTE, random)
}

/**
 * TMDB details (tmdb.js getDetails): hours while a show airs (new episodes and seasons), weeks once it ended or a
 * movie has been out for a while. 0 when there are no details (not cached).
 * @param {any} details
 * @param {number} [now]
 */
export function tmdbDetailsTtl (details, now = Date.now()) {
  if (!details) return 0
  if (details.mediaType === 'movie') {
    const release = toLocalDate(details.releaseDate)
    return release && now - release.getTime() > 60 * DAY ? 3 * WEEK : DAY
  }
  if (details.status === 'FINISHED') return 3 * WEEK
  const next = toLocalDate(details.next_episode_to_air?.air_date)
  if (next && next.getTime() - now < 2 * DAY) return 3 * HOUR
  return details.status === 'RELEASING' ? 12 * HOUR : DAY
}

/**
 * Episodes of a TMDB season (tmdb.js getSeasonEpisodes): 6 hours while episodes are upcoming, undated or aired in
 * the last two weeks (titles, images and new episodes get added), 3 weeks otherwise.
 * @param {{ airdate?: any }[]} episodes
 * @param {number} [now]
 */
export function tmdbSeasonTtl (episodes, now = Date.now()) {
  if (!episodes?.length) return 6 * HOUR
  const recent = episodes.some(episode => {
    const date = toLocalDate(episode?.airdate)
    return !date || now - date.getTime() < 14 * DAY
  })
  return recent ? 6 * HOUR : 3 * WEEK
}

/** Expired entries are kept this long as offline fallback before startup pruning drops them. */
export const STALE_GRACE = 14 * DAY

/** Most entries kept per query cache (sub-maps of the "queries" store, by cache key). */
export const QUERY_LIMITS = {
  search: 400,
  searchIDS: 800,
  compound: 300,
  episodes: 1500,
  recommendations: 300,
  following: 200,
  notifications: 20,
  extensions: 300
}

/** Query caches never pruned: schedule feeds and dub lists are read as fallback whatever their age. */
export const UNPRUNED_QUERIES = ['rss']

/** Most entries kept in the "mappings" store, by key prefix (TMDB, ani.zip, Kitsu answers). */
export const MAPPING_LIMITS = [['tmdb-', 2000], ['ani-', 2500], ['kitsu-', 2500]]

/**
 * Keys to drop from a TTL cache ({ key: { data, expiry, cachedAt } }): empty entries, entries expired for longer
 * than `grace` (expired entries stay a while as offline fallback), then the least recently cached ones above
 * `limit`. Entries without an expiry are only dropped by the limit.
 * @param {Record<string, any>} entries
 * @param {{ now?: number, grace?: number, limit?: number, keys?: string[] }} [options] keys: subset to consider
 * @returns {string[]}
 */
export function staleKeys (entries, { now = Date.now(), grace = STALE_GRACE, limit = Infinity, keys } = {}) {
  const dropped = []
  const kept = []
  for (const key of keys || Object.keys(entries || {})) {
    const entry = entries?.[key]
    const expiry = Number(entry?.expiry)
    if (!entry || typeof entry !== 'object' || (Number.isFinite(expiry) && expiry + grace < now)) dropped.push(key)
    else kept.push(key)
  }
  if (kept.length > limit) {
    const cachedAt = (key) => Number(entries[key]?.cachedAt) || Number(entries[key]?.expiry) || 0
    kept.sort((a, b) => cachedAt(a) - cachedAt(b))
    dropped.push(...kept.slice(0, kept.length - Math.max(0, limit)))
  }
  return dropped
}

/**
 * Keys to drop from the "mappings" store: {@link staleKeys} with the limit of each prefix of {@link MAPPING_LIMITS}.
 * @param {Record<string, any>} entries
 * @param {{ now?: number, grace?: number, limits?: [string, number][] }} [options]
 */
export function staleMappingKeys (entries, { now = Date.now(), grace = STALE_GRACE, limits = MAPPING_LIMITS } = {}) {
  const groups = new Map(limits.map(([prefix]) => [prefix, []]))
  const others = []
  for (const key of Object.keys(entries || {})) {
    const prefix = limits.find(([candidate]) => key.startsWith(candidate))?.[0]
    if (prefix) groups.get(prefix).push(key)
    else others.push(key)
  }
  const dropped = staleKeys(entries, { now, grace, keys: others })
  for (const [prefix, limit] of limits) dropped.push(...staleKeys(entries, { now, grace, limit, keys: groups.get(prefix) }))
  return dropped
}

/**
 * Milliseconds to wait from a Retry-After header (seconds or HTTP date), null when absent or invalid.
 * @param {string | null | undefined} value
 * @param {number} [now]
 */
export function retryAfterMs (value, now = Date.now()) {
  if (value === null || value === undefined || String(value).trim() === '') return null
  const seconds = Number(value)
  if (Number.isFinite(seconds)) return seconds >= 0 ? seconds * SECOND : null
  const date = Date.parse(String(value))
  return Number.isNaN(date) ? null : Math.max(0, date - now)
}

/**
 * Delay before retrying a failed request (Bottleneck 'failed' handler), null to give up.
 * Retry-After (429, 503) is honoured, otherwise the delay doubles from `base` on each attempt, up to `max`.
 * @param {any} error the thrown Response or Error
 * @param {number} attempt Bottleneck jobInfo.retryCount (0 on the first failure)
 * @param {{ retries?: number, base?: number, max?: number, now?: number }} [options]
 * @returns {number | null}
 */
export function retryDelay (error, attempt, { retries = 3, base = SECOND, max = MINUTE, now = Date.now() } = {}) {
  const count = Number(attempt) || 0
  if (count >= retries) return null
  const header = typeof error?.headers?.get === 'function' ? error.headers.get('retry-after') : null
  const after = retryAfterMs(header, now)
  if (after !== null) return Math.min(after + SECOND, Math.max(max, base))
  return Math.min(base * 2 ** count, Math.max(max, base))
}
