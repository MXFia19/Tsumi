import { tmdbClient } from '@/modules/tmdb.js'
import { settings } from '@/modules/settings.js'
import { readCapped } from '@/modules/sandbox/network.js'
import { LruCache, CatalogPager, pickStremioSubtitle, animeMetaId } from '@/modules/extensionUtils.js'
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
// Catalog / meta responses, by URL, for a few minutes. Bounded (least recently used out): it used to keep every
// response of the session.
const requestCache = new LruCache(150)

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
  if (ttl > 0) {
    const cached = requestCache.get(url)
    if (cached && Date.now() - cached.time < cached.ttl) return cached.promise
    if (cached) requestCache.delete(url)
  }

  const promise = (async () => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT)
    try {
      const res = await fetch(url, { signal: controller.signal })
      if (!res.ok) throw new Error(`Addon returned HTTP ${res.status} for ${resource}`)
      // Capped like module responses: a broken or hostile addon cannot fill the memory.
      return JSON.parse(new TextDecoder().decode(await readCapped(res)))
    } catch (error) {
      if (error?.name === 'AbortError') throw new Error(`Addon did not answer in time (${resource})`)
      throw error
    } finally {
      clearTimeout(timer)
    }
  })()

  if (ttl > 0) {
    const entry = { time: Date.now(), ttl, promise }
    requestCache.set(url, entry)
    promise.catch(() => { if (requestCache.peek(url) === entry) requestCache.delete(url) })
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

/** True when the addon explicitly lists this id prefix (kitsu:, mal:, anilist:...) for the resource and type. */
function listsIdPrefix (manifest, resource, type, id) {
  const info = resourceInfo(manifest, resource)
  if (!info || (type && info.types.length && !info.types.includes(type))) return false
  return !!info.idPrefixes?.some(prefix => prefix && String(id).startsWith(prefix))
}

/** Kitsu id of an AniList anime, from the existing mappings (ani.zip, then Kitsu's own mapping). */
async function kitsuIdOf (anilistId) {
  try {
    const { getAniMappings, getKitsuMappings } = await import('@/modules/anime/anime.js')
    const ani = await Promise.resolve().then(() => getAniMappings(anilistId)).catch(() => null)
    if (ani?.mappings?.kitsu_id) return Number(ani.mappings.kitsu_id) || null
    const kitsu = await Promise.resolve().then(() => getKitsuMappings(anilistId)).catch(() => null)
    return Number(kitsu?.data?.[0]?.relationships?.item?.data?.id || kitsu?.included?.[0]?.id) || null
  } catch (error) {
    debug('Kitsu mapping failed', anilistId, error)
    return null
  }
}

/**
 * Anime-only addons (ids kitsu:1, mal:1, anilist:1): the id of an AniList entry they accept, for its stream type or
 * the "anime" type some of them use.
 */
async function pickAnimeAddonId (manifest, media) {
  if (!media || media.isTmdb || !Number.isInteger(Number(media.id))) return null
  const baseType = media.format === 'MOVIE' ? 'movie' : 'series'
  for (const type of [baseType, 'anime']) {
    if (listsIdPrefix(manifest, 'stream', type, `anilist:${media.id}`)) return { type, id: `anilist:${media.id}` }
    if (media.idMal && listsIdPrefix(manifest, 'stream', type, `mal:${media.idMal}`)) return { type, id: `mal:${media.idMal}` }
    if (listsIdPrefix(manifest, 'stream', type, 'kitsu:1')) {
      const kitsuId = await kitsuIdOf(media.id)
      if (kitsuId) return { type, id: `kitsu:${kitsuId}` }
    }
  }
  return null
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

// Kitsu anime id -> { anilist, mal } ids (null: Kitsu knows no mapping).
const kitsuCache = new LruCache(1000)

/** AniList / MAL ids of Kitsu anime, 20 per request (Kitsu's mappings, the provider getKitsuMappings already uses). */
async function kitsuToAnime (kitsuIds) {
  const missing = kitsuIds.filter(id => !kitsuCache.has(id))
  for (let i = 0; i < missing.length; i += 20) {
    const chunk = missing.slice(i, i + 20)
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 20000)
    try {
      const res = await fetch(`https://kitsu.app/api/edge/anime?filter[id]=${chunk.join(',')}&include=mappings&fields[anime]=mappings&fields[mappings]=externalSite,externalId&page[limit]=20`, { signal: controller.signal })
      if (!res.ok) throw new Error(`Kitsu returned HTTP ${res.status}`)
      const json = JSON.parse(new TextDecoder().decode(await readCapped(res)))
      const mappings = new Map((json?.included || []).filter(item => item?.type === 'mappings').map(item => [item.id, item.attributes]))
      for (const anime of json?.data || []) {
        const ids = { anilist: null, mal: null }
        for (const ref of anime?.relationships?.mappings?.data || []) {
          const mapping = mappings.get(ref.id)
          if (mapping?.externalSite === 'anilist/anime') ids.anilist = Number(mapping.externalId) || null
          if (mapping?.externalSite === 'myanimelist/anime') ids.mal = Number(mapping.externalId) || null
        }
        kitsuCache.set(Number(anime.id), ids.anilist || ids.mal ? ids : null)
      }
      for (const id of chunk) if (!kitsuCache.has(id)) kitsuCache.set(id, null)
    } catch (error) {
      debug('Kitsu id lookup failed', error)
    } finally {
      clearTimeout(timer)
    }
  }
  return new Map(kitsuIds.map(id => [id, kitsuCache.get(id) || null]))
}

/**
 * AniList media of the anime metas of a catalog page (ids kitsu:, mal:, anilist:), so anime-only addons show their
 * items like the rest of the app (AniList cards, details, playback). Batched: one AniList request per 50 ids.
 * @returns {Promise<Map<string, any>>} meta id -> AniList media
 */
async function animeMediaFor (metas) {
  const parsed = metas.map(meta => [meta, animeMetaId(meta?.id)]).filter(([, ids]) => ids)
  if (!parsed.length) return new Map()
  const kitsu = await kitsuToAnime([...new Set(parsed.filter(([, ids]) => ids.source === 'kitsu').map(([, ids]) => ids.id))])
  const wanted = parsed.map(([meta, ids]) => {
    if (ids.source === 'anilist') return [meta, { anilist: ids.id }]
    if (ids.source === 'mal') return [meta, { mal: ids.id }]
    const mapped = kitsu.get(ids.id)
    return [meta, mapped?.anilist ? { anilist: mapped.anilist } : mapped?.mal ? { mal: mapped.mal } : null]
  }).filter(([, ids]) => ids)

  const byId = new Map()
  const byMal = new Map()
  try {
    const { anilistClient } = await import('@/modules/anilist.js')
    const load = async (key, list) => {
      for (let i = 0; i < list.length; i += 50) {
        const res = await anilistClient.searchIDS({ [key]: list.slice(i, i + 50), perPage: 50 })
        for (const media of res?.data?.Page?.media || []) {
          byId.set(media.id, media)
          if (media.idMal) byMal.set(media.idMal, media)
        }
      }
    }
    const anilistIds = [...new Set(wanted.map(([, ids]) => ids.anilist).filter(Boolean))]
    const malIds = [...new Set(wanted.map(([, ids]) => ids.mal).filter(Boolean))]
    if (anilistIds.length) await load('id', anilistIds)
    if (malIds.length) await load('idMal', malIds)
  } catch (error) {
    debug('AniList lookup of catalog anime failed', error)
  }
  return new Map(wanted.map(([meta, ids]) => [meta.id, ids.anilist ? byId.get(ids.anilist) : byMal.get(ids.mal)]).filter(([, media]) => media))
}

async function metasToPage (metas, fallbackType, hasNextPage) {
  const anime = await animeMediaFor(metas)
  const media = (await Promise.all(metas.map(meta => anime.get(meta.id) || metaToMedia(meta, fallbackType).catch(() => null)))).filter(Boolean)
  return { data: { Page: { media, pageInfo: { hasNextPage } } } }
}

// Pager of each catalog (+ filters) in use, see CatalogPager (extensionUtils.js).
const catalogPagers = new LruCache(40)

/**
 * Load one page of a catalog in the format Tsumi's sections expect
 * ({ data: { Page: { media, pageInfo } } }). Stremio pages with "skip" = number of items received so far.
 */
export async function loadCatalogPage (ext, catalog, page = 1, perPage = 50, extra = {}) {
  const { base } = ext.stremio
  const key = `${base}|${catalog.type}|${catalog.id}|${JSON.stringify(extra || {})}`
  let pager = catalogPagers.get(key)
  if (!pager) {
    pager = new CatalogPager(
      async (skip) => (await stremioRequest(base, 'catalog', catalog.type, catalog.id, { ...extra, ...(skip > 0 ? { skip } : {}) }))?.metas || [],
      { canSkip: catalogSupports(catalog, 'skip') }
    )
    catalogPagers.set(key, pager)
  }
  const { items, hasNextPage } = await pager.page(page, perPage)
  return metasToPage(items, catalog.type, hasNextPage)
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

  // Anime-only addons: AniList entries map to their kitsu: / mal: / anilist: ids.
  const anime = await pickAnimeAddonId(manifest, media)
  if (anime) {
    return [{
      title: title || media?.title?.userPreferred || anime.id,
      image: media?.coverImage?.extraLarge || media?.coverImage?.medium || '',
      href: encodeRef({ type: anime.type, id: anime.id, episodes: Number(media?.episodes) || null })
    }]
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
  // Anime ids without a meta resource: "kitsu:1:5" is episode 5 (Stremio convention), the count comes from AniList.
  if (!videos.length && animeMetaId(ref.id) && ref.episodes > 0) {
    videos = Array.from({ length: ref.episodes }, (_, i) => ({ id: `${ref.id}:${i + 1}`, episode: i + 1 }))
  }

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

async function extractStreamUrl (ext, href) {
  const ref = decodeRef(href)
  const res = await stremioRequest(ext.stremio.base, 'stream', ref.type, ref.id, null, 0)
  const all = res?.streams || []
  const playable = all.filter(stream => typeof stream.url === 'string' && /^https?:/i.test(stream.url))
  if (!playable.length) {
    throw new Error(all.length ? 'This addon only returned peer-to-peer or external links, which Tsumi cannot play' : 'No streams found for this title')
  }
  return {
    streams: playable.map((stream, i) => ({
      title: streamTitle(stream, i),
      streamUrl: stream.url,
      headers: stream.behaviorHints?.proxyHeaders?.request || {}
    })),
    // Only a subtitle in the Preferred Subtitle Language: another one would also block the automatic online subtitles.
    subtitles: pickStremioSubtitle(playable[0].subtitles, settings.value.subtitleLanguage)
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
