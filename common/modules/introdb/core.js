// TheIntroDB (https://theintrodb.org): community skip times (intro, recap, credits, preview) for shows, movies and
// anime, keyed by TVDB. Same logic as the iOS app (ios-native/Tsumi/Player/PlayerIntroDB.swift).
// Pure helpers: request URL and conversion of the answer to player chapters. Tested by core.test.mjs.
//
// API (public, no key, https://theintrodb.org/openapi.yaml): GET /v4/media?tmdb_id=<id>[&season=<s>&episode=<e>]
// or ?tvdb_id=<id>&season=<s>&episode=<e>[&tvdb_episode_id=<id>], optional duration_ms to pick the release version.
// -> { tvdb_id, type: 'tv' | 'movie', intro?: [{ start_ms, end_ms }], recap?: [...], credits?: [...], preview?: [...] }
// start_ms null = start of the video, end_ms null = end of the video. 404 = nothing submitted (or unknown media).
// TMDB numbering is converted by the server; TVDB numbering is its own.

export const INTRODB_API = 'https://api.theintrodb.org/v4'

/** Segment types of the answer and the chapter names the player recognises as skippable. */
export const INTRODB_SEGMENTS = [['intro', 'Intro'], ['recap', 'Recap'], ['credits', 'Credits'], ['preview', 'Preview']]

/** Shortest segment kept (the API stores "no recap" as a 0 to 0 segment). */
const MIN_SEGMENT_MS = 1000

const positive = (value) => {
  const number = Number(value)
  return Number.isInteger(number) && number > 0 ? number : null
}

/**
 * Request URL of a movie ({ tmdb }) or an episode ({ tmdb | tvdb, season, episode, tvdbEpisode? }).
 * @param {{ tmdb?: number, tvdb?: number, season?: number, episode?: number, tvdbEpisode?: number }} query
 * @param {number} [duration] video length in seconds (selects the closest release version)
 * @returns {string | null}
 */
export function introDbUrl (query, duration) {
  const params = new URLSearchParams()
  const tvdb = positive(query?.tvdb)
  const tmdb = positive(query?.tmdb)
  if (tvdb) params.set('tvdb_id', String(tvdb))
  else if (tmdb) params.set('tmdb_id', String(tmdb))
  else return null
  const hasEpisode = query.season != null || query.episode != null
  if (hasEpisode) {
    const season = Number(query.season)
    const episode = positive(query.episode)
    if (!Number.isInteger(season) || season < 0 || !episode) return null
    params.set('season', String(season))
    params.set('episode', String(episode))
    const tvdbEpisode = tvdb && positive(query.tvdbEpisode)
    if (tvdbEpisode) params.set('tvdb_episode_id', String(tvdbEpisode))
  }
  const ms = Math.round(Number(duration) * 1000)
  if (ms > 0) params.set('duration_ms', String(ms))
  return `${INTRODB_API}/media?${params}`
}

/**
 * Player chapters ({ start, end, text } in milliseconds, covering the whole video) from a TheIntroDB answer.
 * Segments are clamped to the video, overlaps are cut (the earlier segment wins) and the gaps between them become
 * "Episode" (or "Movie") chapters. Chapters carry `trusted: true`: they are meant for skipping, so the player allows
 * long ones (movie credits). Returns [] when the answer has no usable segment.
 * @param {any} json
 * @param {number} duration video length in seconds
 */
export function introDbChapters (json, duration) {
  const total = Math.round(Number(duration) * 1000)
  if (!json || !(total > 0)) return []
  const segments = []
  for (const [key, text] of INTRODB_SEGMENTS) {
    for (const segment of Array.isArray(json[key]) ? json[key] : []) {
      const start = segment?.start_ms == null ? 0 : Number(segment.start_ms)
      const end = segment?.end_ms == null ? total : Number(segment.end_ms)
      if (!Number.isFinite(start) || !Number.isFinite(end)) continue
      const from = Math.max(0, Math.min(start, total))
      const to = Math.max(0, Math.min(end, total))
      if (to - from >= MIN_SEGMENT_MS) segments.push({ start: from, end: to, text, trusted: true })
    }
  }
  segments.sort((a, b) => a.start - b.start || b.end - a.end)
  const kept = []
  for (const segment of segments) {
    const previous = kept[kept.length - 1]
    if (previous && segment.start < previous.end) {
      if (segment.end - previous.end < MIN_SEGMENT_MS) continue
      segment.start = previous.end
    }
    kept.push(segment)
  }
  if (!kept.length) return []
  const filler = json.type === 'movie' ? 'Movie' : 'Episode'
  const chapters = []
  let cursor = 0
  for (const segment of kept) {
    if (segment.start - cursor >= MIN_SEGMENT_MS) chapters.push({ start: cursor, end: segment.start, text: filler })
    else segment.start = cursor
    chapters.push(segment)
    cursor = segment.end
  }
  if (total - cursor >= MIN_SEGMENT_MS) chapters.push({ start: cursor, end: total, text: filler })
  else chapters[chapters.length - 1].end = total
  return chapters
}

/**
 * TheIntroDB query of an anime episode from its ani.zip mappings (TVDB show, season and episode numbers of
 * the episode, TVDB episode id). Movies use the TMDB id. null when the mappings do not place the episode.
 * @param {any} mappings ani.zip answer ({ mappings, episodes })
 * @param {number} episode AniList episode number
 * @param {boolean} isMovie
 */
export function animeQuery (mappings, episode, isMovie) {
  const ids = mappings?.mappings || {}
  if (isMovie || String(ids.type || '').toUpperCase() === 'MOVIE') {
    const tmdb = positive(ids.themoviedb_id)
    return tmdb ? { tmdb } : null
  }
  const entry = mappings?.episodes?.[String(Number(episode) || 1)]
  const tvdb = positive(entry?.tvdbShowId) || positive(ids.thetvdb_id)
  const season = Number(entry?.seasonNumber)
  const number = positive(entry?.episodeNumber)
  if (!tvdb || !Number.isInteger(season) || season < 0 || !number) return null
  return { tvdb, season, episode: number, tvdbEpisode: positive(entry?.tvdbId) || undefined }
}
