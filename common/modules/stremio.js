import { tmdbClient } from '@/modules/tmdb.js'
import Debug from 'debug'

const debug = Debug('ui:stremio')

/*
 * Stremio addon support.
 *
 * A Stremio addon is described by a manifest.json (id, name, resources, types,
 * catalogs, idPrefixes) and answers plain HTTP GET requests:
 *   {base}/{resource}/{type}/{id}[/{extra}].json
 * with resource = catalog | meta | stream.
 *
 * To fit Tsumi's extension system, an addon is exposed through the same three
 * functions as a Sora module (searchResults, extractEpisodes, extractStreamUrl).
 * The "href" passed between them is an opaque reference: "stremio:" + JSON.
 */

const REQUEST_TIMEOUT = 45000
const requestCache = new Map()

export function isStremioManifest (manifest) {
  return !!manifest && typeof manifest === 'object' && !manifest.scriptUrl && typeof manifest.id === 'string' && Array.isArray(manifest.resources)
}

/** stremio:// install links point to the same manifest over https. */
export function normalizeManifestUrl (url) {
  return String(url || '').trim().replace(/^stremio:\/\//i, 'https://')
}

export function addonBaseUrl (manifestUrl) {
  return normalizeManifestUrl(manifestUrl).replace(/\/manifest\.json(\?.*)?$/i, '').replace(/\/+$/, '')
}

/** Shape the Stremio manifest like a Sora manifest so the settings UI can show it. */
function normalizeStremioManifest (manifest) {
  return {
    sourceName: manifest.name || manifest.id,
    iconUrl: manifest.logo || manifest.icon || null,
    version: manifest.version || '0.0.0',
    description: manifest.description || '',
    streamType: 'Stremio',
    stremioId: manifest.id
  }
}

export function loadStremioAddon (manifestUrl, manifest) {
  return {
    manifest: normalizeStremioManifest(manifest),
    script: null,
    type: 'stremio',
    stremio: { base: addonBaseUrl(manifestUrl), manifest }
  }
}

function resourceInfo (manifest, name) {
  for (const resource of manifest?.resources || []) {
    if (resource === name) return { types: manifest.types || [], idPrefixes: manifest.idPrefixes || null }
    if (resource && typeof resource === 'object' && resource.name === name) {
      return { types: resource.types || manifest.types || [], idPrefixes: resource.idPrefixes || manifest.idPrefixes || null }
    }
  }
  return null
}

export function supportsResource (manifest, name, type, id) {
  const info = resourceInfo(manifest, name)
  if (!info) return false
  if (type && info.types.length && !info.types.includes(type)) return false
  if (id && info.idPrefixes?.length && !info.idPrefixes.some(prefix => String(id).startsWith(prefix))) return false
  return true
}

function encodeId (id) {
  return String(id).split(':').map(encodeURIComponent).join(':')
}

function extraPath (extra) {
  const parts = Object.entries(extra || {})
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
  return parts.length ? `/${parts.join('&')}` : ''
}

/** GET a Stremio resource. ttl = 0 disables caching (stream links can expire). */
async function stremioRequest (base, resource, type, id, extra = null, ttl = 5 * 60 * 1000) {
  const url = `${base}/${resource}/${encodeURIComponent(type)}/${encodeId(id)}${extraPath(extra)}.json`
  const cached = ttl > 0 && requestCache.get(url)
  if (cached && Date.now() - cached.time < ttl) return cached.promise

  const promise = (async () => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT)
    try {
      const res = await fetch(url, { signal: controller.signal })
      if (!res.ok) throw new Error(`Addon returned HTTP ${res.status} for ${resource}`)
      return await res.json()
    } catch (error) {
      if (error?.name === 'AbortError') throw new Error(`Addon did not answer in time (${resource})`)
      throw error
    } finally {
      clearTimeout(timer)
    }
  })()

  if (ttl > 0) {
    requestCache.set(url, { time: Date.now(), promise })
    promise.catch(() => requestCache.delete(url))
  }
  return promise
}

/* ---------------------------------------------------------------------------
 * Identifiers: Tsumi media -> Stremio id
 * ------------------------------------------------------------------------- */

const encodeRef = (ref) => 'stremio:' + JSON.stringify(ref)
const decodeRef = (href) => JSON.parse(String(href).replace(/^stremio:/, ''))

async function tmdbFromImdb (imdbId, tmdbType) {
  try {
    const res = await tmdbClient.handleRequest(`/find/${imdbId}`, { external_source: 'imdb_id' })
    const list = tmdbType === 'movie' ? res?.movie_results : res?.tv_results
    return list?.[0]?.id || (res?.tv_results?.[0] || res?.movie_results?.[0])?.id || null
  } catch (error) {
    debug('IMDb -> TMDB lookup failed', imdbId, error)
    return null
  }
}

/**
 * What Tsumi knows about a title: its TMDB id and, for AniList anime, which
 * TMDB/TVDB season the AniList entry corresponds to (and the episode offset).
 */
function resolveMediaIds (media) {
  if (!media) return null
  let tmdbType = media.format === 'MOVIE' ? 'movie' : 'tv'
  let tmdbId = media.idTmdb || (typeof media.id === 'string' && media.id.startsWith('tmdb-') ? Number(media.id.slice(5)) : null)
  let season = null
  let offset = 0

  const isAnilist = !media.isTmdb && Number.isInteger(Number(media.id))
  if (isAnilist) {
    const map = tmdbClient.anilistToTmdb?.[media.id]
    if (map?.id) {
      tmdbId = tmdbId || map.id
      if (String(map.type).toUpperCase() === 'MOVIE') tmdbType = 'movie'
      if (Number(map.tvdb_season) > 0) season = Number(map.tvdb_season)
      offset = Number(map.tvdb_epoffset) || 0
    }
  }
  if (!tmdbId) return null
  return { tmdbId: Number(tmdbId), tmdbType, stremioType: tmdbType === 'movie' ? 'movie' : 'series', season, offset }
}

/** Pick an id the addon accepts for this resource: tmdb:123 first, then the IMDb id. */
async function pickAddonId (manifest, resource, ids) {
  const type = ids.stremioType
  const tmdbStremioId = `tmdb:${ids.tmdbId}`
  if (supportsResource(manifest, resource, type, tmdbStremioId)) return tmdbStremioId
  if (supportsResource(manifest, resource, type, 'tt')) {
    const details = await tmdbClient.getDetails(ids.tmdbId, ids.tmdbType)
    const imdbId = details?.externalIds?.imdb_id
    if (imdbId && supportsResource(manifest, resource, type, imdbId)) return imdbId
  }
  return null
}

/* ---------------------------------------------------------------------------
 * Catalog helpers
 * ------------------------------------------------------------------------- */

export function catalogSupports (catalog, name) {
  return (catalog.extra || []).some(extra => extra.name === name) || (catalog.extraSupported || []).includes(name)
}

function catalogRequiresExtra (catalog) {
  return (catalog.extra || []).some(extra => extra.isRequired) || (catalog.extraRequired || []).length > 0
}

/** Catalogs to browse (no mandatory filter), or catalogs that can search. */
export function listCatalogs (ext, { search = false } = {}) {
  const catalogs = ext?.stremio?.manifest?.catalogs || []
  return catalogs.filter(catalog => {
    if (search) return catalogSupports(catalog, 'search')
    if (!catalogRequiresExtra(catalog)) return true
    // A catalog whose only required extra is "search" is a search catalog.
    return false
  })
}

async function searchCatalogs (ext, query, types = null) {
  const { base } = ext.stremio
  const results = []
  const seen = new Set()
  const catalogs = listCatalogs(ext, { search: true }).filter(catalog => !types || types.includes(catalog.type))
  const responses = await Promise.allSettled(catalogs.map(catalog => stremioRequest(base, 'catalog', catalog.type, catalog.id, { search: query })))
  responses.forEach((response, i) => {
    if (response.status !== 'fulfilled') return debug('Catalog search failed', catalogs[i].id, response.reason)
    for (const meta of response.value?.metas || []) {
      const type = meta.type || catalogs[i].type
      const key = `${type}:${meta.id}`
      if (seen.has(key)) continue
      seen.add(key)
      results.push({ ...meta, type })
    }
  })
  return results
}

/** Turn a Stremio catalog item into a Tsumi media object (same shape as TMDB items). */
export async function metaToMedia (meta, fallbackType) {
  const stremioType = meta.type || fallbackType
  const tmdbType = stremioType === 'movie' ? 'movie' : 'tv'
  const id = String(meta.id || '')
  let tmdbId = null
  if (id.startsWith('tmdb:')) tmdbId = Number(id.split(':')[1]) || null
  else if (/^tt\d+/.test(id)) tmdbId = await tmdbFromImdb(id.split(':')[0], tmdbType)
  if (!tmdbId) return null

  const year = parseInt(String(meta.releaseInfo || meta.year || '').slice(0, 4)) || null
  const media = tmdbClient.normalizeMedia({
    id: tmdbId,
    media_type: tmdbType,
    name: meta.name,
    title: meta.name,
    overview: meta.description,
    first_air_date: tmdbType === 'tv' && year ? `${year}-01-01` : undefined,
    release_date: tmdbType === 'movie' && year ? `${year}-01-01` : undefined,
    genre_ids: []
  })
  if (!media) return null

  const poster = meta.poster || null
  media.coverImage = {
    extraLarge: poster?.includes('image.tmdb.org') ? poster.replace(/\/w\d+\//, '/w500/') : poster,
    medium: poster,
    color: null
  }
  if (meta.background) media.bannerImage = meta.background
  if (Array.isArray(meta.genres) && meta.genres.length) media.genres = meta.genres
  const rating = parseFloat(meta.imdbRating)
  if (!isNaN(rating)) media.averageScore = Math.round(rating * 10)
  media.stremioId = id
  return media
}

async function metasToPage (metas, fallbackType, hasNextPage) {
  const media = (await Promise.all(metas.map(meta => metaToMedia(meta, fallbackType).catch(() => null)))).filter(Boolean)
  return { data: { Page: { media, pageInfo: { hasNextPage } } } }
}

/**
 * Load one page of a catalog in the format Tsumi's sections expect
 * ({ data: { Page: { media, pageInfo } } }). Stremio pages with "skip".
 */
export async function loadCatalogPage (ext, catalog, page = 1, perPage = 50, extra = {}) {
  const { base } = ext.stremio
  const canSkip = catalogSupports(catalog, 'skip')
  if (page > 1 && !canSkip) return { data: { Page: { media: [], pageInfo: { hasNextPage: false } } } }

  const metas = []
  let skip = (page - 1) * perPage
  let lastBatch = 0
  for (let i = 0; i < 6 && metas.length < perPage; i++) {
    const res = await stremioRequest(base, 'catalog', catalog.type, catalog.id, { ...extra, ...(skip > 0 ? { skip } : {}) })
    const batch = res?.metas || []
    lastBatch = batch.length
    if (!batch.length) break
    metas.push(...batch)
    skip += batch.length
    if (!canSkip) break
  }
  return metasToPage(metas.slice(0, perPage), catalog.type, canSkip && lastBatch > 0)
}

/* ---------------------------------------------------------------------------
 * Sora-compatible functions
 * ------------------------------------------------------------------------- */

async function searchResults (ext, title, media) {
  const { manifest } = ext.stremio
  const ids = resolveMediaIds(media)

  // Tsumi already knows the exact title: ask the addon by id, no guessing.
  if (ids) {
    const id = await pickAddonId(manifest, 'stream', ids)
    if (id) {
      return [{
        title: title || media?.title?.userPreferred || id,
        image: media?.coverImage?.extraLarge || media?.coverImage?.medium || '',
        href: encodeRef({ type: ids.stremioType, id, season: ids.season, offset: ids.offset })
      }]
    }
  }

  // Otherwise fall back to the addon's own search.
  if (!title) return []
  const types = ids ? [ids.stremioType] : (media ? [media.format === 'MOVIE' ? 'movie' : 'series'] : null)
  const metas = await searchCatalogs(ext, title, types)
  return metas.map(meta => ({
    title: meta.name,
    image: meta.poster || '',
    href: encodeRef({ type: meta.type, id: meta.id })
  }))
}

async function videosFromTmdb (id) {
  let tmdbId = null
  if (id.startsWith('tmdb:')) tmdbId = Number(id.split(':')[1])
  else if (id.startsWith('tt')) tmdbId = await tmdbFromImdb(id, 'tv')
  if (!tmdbId) return []
  const details = await tmdbClient.getDetails(tmdbId, 'tv')
  const videos = []
  for (const season of details?.seasons || []) {
    for (let episode = 1; episode <= (season.episode_count || 0); episode++) {
      videos.push({ id: `${id}:${season.season_number}:${episode}`, season: season.season_number, episode })
    }
  }
  return videos
}

async function extractEpisodes (ext, href) {
  const ref = decodeRef(href)
  if (ref.type === 'movie') return [{ number: 1, title: 'Movie', href: encodeRef({ type: 'movie', id: ref.id }) }]

  const { base, manifest } = ext.stremio
  let videos = []
  if (supportsResource(manifest, 'meta', ref.type, ref.id)) {
    try {
      videos = (await stremioRequest(base, 'meta', ref.type, ref.id, null, 30 * 60 * 1000))?.meta?.videos || []
    } catch (error) {
      debug('Addon meta failed, falling back to TMDB', error)
    }
  }
  if (!videos.length) videos = await videosFromTmdb(ref.id)

  let episodes = videos
    .filter(video => video.season == null || Number(video.season) > 0)
    .map(video => ({
      number: Number(video.episode ?? video.number),
      season: video.season != null ? Number(video.season) : null,
      title: video.title || video.name || '',
      href: encodeRef({ type: ref.type, id: video.id })
    }))
    .filter(episode => Number.isFinite(episode.number))
    .sort((a, b) => (a.season ?? 0) - (b.season ?? 0) || a.number - b.number)

  // AniList entries are one season each: keep that season and number episodes
  // the way AniList does (after the mapping's episode offset).
  if (ref.season > 0) {
    const offset = Number(ref.offset) || 0
    const inSeason = episodes.filter(episode => episode.season === ref.season && episode.number > offset)
    if (inSeason.length) episodes = inSeason.map(episode => ({ ...episode, season: null, number: episode.number - offset }))
  }
  return episodes
}

function streamTitle (stream, index) {
  const lines = (text) => String(text || '').split('\n').map(line => line.trim()).filter(Boolean)
  const name = lines(stream.name)
  const details = lines(stream.title || stream.description).filter(line => !name.some(part => part.includes(line)))
  return [...name, ...details].join(' · ') || `Server ${index + 1}`
}

function pickSubtitle (subtitles) {
  if (!Array.isArray(subtitles) || !subtitles.length) return null
  const french = subtitles.find(sub => /^(fr|fre|fra|french)/i.test(sub.lang || ''))
  return (french || subtitles[0])?.url || null
}

async function extractStreamUrl (ext, href) {
  const ref = decodeRef(href)
  const res = await stremioRequest(ext.stremio.base, 'stream', ref.type, ref.id, null, 0)
  const all = res?.streams || []
  const playable = all.filter(stream => typeof stream.url === 'string' && /^https?:/i.test(stream.url))
  if (!playable.length) {
    throw new Error(all.length ? 'This addon only returned torrent or external links, which Tsumi cannot play' : 'No streams found for this title')
  }
  return {
    streams: playable.map((stream, i) => ({
      title: streamTitle(stream, i),
      streamUrl: stream.url,
      headers: stream.behaviorHints?.proxyHeaders?.request || {}
    })),
    subtitles: pickSubtitle(playable[0].subtitles)
  }
}

export async function callStremioFunction (ext, functionName, ...args) {
  if (!ext?.stremio) throw new Error('Stremio addon not loaded')
  switch (functionName) {
    case 'searchResults': return searchResults(ext, args[0], args[1])
    case 'extractEpisodes': return extractEpisodes(ext, args[0])
    case 'extractStreamUrl': return extractStreamUrl(ext, args[0])
    default: throw new Error(`Stremio addons do not support ${functionName}`)
  }
}
