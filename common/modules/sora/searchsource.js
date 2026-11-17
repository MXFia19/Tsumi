import SectionsManager from '@/modules/sections.js'
import { extensionManager, callExtension } from '@/modules/extension.js'
import { anilistClient } from '@/modules/anilist.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { modal } from '@/modules/navigation.js'
import { toast } from 'svelte-sonner'
import Debug from 'debug'
import { matchTargets, pickBestMatch, resultMedia, cleanResultTitle } from './match.js'

const debug = Debug('ui:sora-search')

// Sora modules as a Source of the search page (SearchBar.svelte): the Title is searched in the module itself and its
// results are shown as cards. Opening one finds the matching AniList / TMDB title (details page, list tracking) and
// remembers the module and result, so Play uses them directly instead of searching every extension again
// (ExtensionModal.svelte playAnime, ExtensionResults.svelte). Remembered for the session only.

/** Enabled Sora modules (Stremio addons are listed by catalog instead). */
export function soraModules () {
  return extensionManager.getEnabled().filter(ext => ext.type !== 'stremio')
}

/** media id -> { extensionKey, href, title } of the module result it was opened from. */
export const preferredSources = new Map()

const emptyPage = () => ({ data: { Page: { pageInfo: { hasNextPage: false }, media: [] } } })

/** The module search in progress: the next one (another title or module) aborts it in the sandbox. */
let currentSearch = null

async function searchPage (ext, query, page, signal) {
  if (!query || page > 1) return emptyPage()
  const raw = await callExtension(ext, 'searchResults', [query], { signal })
  const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw
  const seen = new Set()
  const media = (Array.isArray(parsed) ? parsed : [])
    .filter(result => typeof result?.title === 'string' && result.title.trim() && typeof result?.href === 'string' && result.href)
    .filter(result => !seen.has(result.href) && seen.add(result.href))
    .slice(0, 100)
    .map(result => resultMedia(ext, result))
  return { data: { Page: { pageInfo: { hasNextPage: false }, media } } }
}

/**
 * Source option of a module for the search page (same shape as the catalog sections of routes/catalogs/sections.js).
 * @param {any} ext
 */
export function soraSection (ext) {
  return {
    key: ext.key,
    title: ext.manifest?.sourceName || ext.key,
    // Up to 100 results (searchPage keeps that many), like iOS: the search page asks for its default page size.
    load: (pageNumber = 1, perPage = 100, variables = null) => {
      const query = typeof variables?.search === 'string' ? variables.search.trim() : ''
      if (pageNumber > 1) return SectionsManager.wrapResponse(searchPage(ext, query, pageNumber), perPage)
      // A new search replaces the results (SearchPage): the previous module search is no longer needed.
      currentSearch?.abort()
      const controller = new AbortController()
      currentSearch = controller
      const res = searchPage(ext, query, pageNumber, controller.signal).finally(() => {
        if (currentSearch === controller) currentSearch = null
      })
      return SectionsManager.wrapResponse(res, perPage)
    },
    variables: { soraModule: ext.key }
  }
}

/** Aliases given by the module details ("A, B" text or an array), to match titles listed under another name. */
async function resultAliases (ext, href) {
  try {
    const raw = await callExtension(ext, 'extractDetails', [href])
    const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw
    const details = Array.isArray(parsed) ? parsed[0] : parsed
    const aliases = details?.aliases
    const list = Array.isArray(aliases) ? aliases : typeof aliases === 'string' ? aliases.split(/[,;\n|]/) : []
    return list.map(alias => String(alias).trim()).filter(alias => alias && alias.length < 200).slice(0, 10)
  } catch (error) {
    debug('extractDetails failed', error)
    return []
  }
}

async function candidates (titles, targets) {
  const lists = []
  for (const title of titles.slice(0, 3)) {
    if (targets.anime) {
      // Best matches first (like iOS): with 10 results per title, trending order could leave the right one out.
      lists.push(Promise.resolve(anilistClient.search({ search: title, page: 1, perPage: 10, sort: 'SEARCH_MATCH' })).then(res => res?.data?.Page?.media || []).catch(() => []))
    }
    if (targets.western) {
      // Every TMDB title, K-dramas, Asian and anime films included (the Search page's TMDB results leave them out).
      lists.push(tmdbClient.textSearch(title, 1, { includeAnime: true }).then(res => withAniList(res?.data?.Page?.media || [])).catch(() => []))
    }
  }
  return (await Promise.all(lists)).flat()
}

/** TMDB titles mapped to AniList (normalizeMedia gives them the AniList id) open their AniList entry. */
async function withAniList (media) {
  const mapped = media.filter(item => typeof item.id === 'number').map(item => item.id)
  const others = media.filter(item => typeof item.id !== 'number')
  if (!mapped.length) return others
  const res = await Promise.resolve(anilistClient.searchIDS({ id: mapped, page: 1, perPage: 50 })).catch(() => null)
  return [...others, ...(res?.data?.Page?.media || [])]
}

/** AniList / TMDB media matching a module result, null when none is close enough. */
export async function findMatch (sora) {
  const stored = extensionManager.extensions.get(sora.extensionKey)
  const ext = stored && { key: sora.extensionKey, ...stored }
  const targets = matchTargets(ext?.manifest)
  // "Attack on Titan (Dub)" is searched and scored as "Attack on Titan" (the original title is still scored).
  const clean = (list) => list.map(cleanResultTitle).filter((title, index, all) => title && all.indexOf(title) === index)
  const titles = clean([sora.title])
  let match = pickBestMatch([...titles, sora.title], await candidates(titles, targets))
  if (!match && ext) {
    const aliases = clean(await resultAliases(ext, sora.href))
    if (aliases.length) match = pickBestMatch([...titles, sora.title, ...aliases], await candidates(aliases, targets))
  }
  return match
}

let opening = null
let lookups = 0

/**
 * Card click on a module result: opens the details of the matching title and remembers the module result for Play.
 * The last result clicked wins: an earlier lookup still running is dropped.
 * @param {any} media card media built by resultMedia
 */
export async function openSoraResult (media) {
  const sora = media?.sora
  if (!sora || opening === sora.href) return
  const lookup = ++lookups
  opening = sora.href
  const toastId = toast.loading(`Looking for "${sora.title}" on AniList and TMDB…`)
  try {
    const match = await findMatch(sora)
    if (lookup !== lookups) {
      toast.dismiss(toastId)
      return
    }
    if (!match) {
      toast.error('No AniList or TMDB title matches this result', { id: toastId, description: `${sora.title} (${sora.extensionName})` })
      return
    }
    preferredSources.set(match.id, { extensionKey: sora.extensionKey, href: sora.href, title: sora.title })
    toast.dismiss(toastId)
    modal.open(modal.ANIME_DETAILS, match)
  } catch (error) {
    debug('Sora result match failed', error)
    if (lookup === lookups) toast.error('Could not open this result', { id: toastId, description: error?.message || String(error) })
    else toast.dismiss(toastId)
  } finally {
    if (lookup === lookups) opening = null
  }
}
