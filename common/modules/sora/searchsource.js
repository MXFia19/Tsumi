import SectionsManager from '@/modules/sections.js'
import { extensionManager, callExtension } from '@/modules/extension.js'
import { anilistClient } from '@/modules/anilist.js'
import { tmdbClient } from '@/modules/tmdb.js'
import { modal } from '@/modules/navigation.js'
import { toast } from 'svelte-sonner'
import Debug from 'debug'
import { matchTargets, pickBestMatch, resultMedia } from './match.js'

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

async function searchPage (ext, query, page) {
  if (!query || page > 1) return emptyPage()
  const raw = await callExtension(ext, 'searchResults', [query])
  const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw
  const media = (Array.isArray(parsed) ? parsed : [])
    .filter(result => typeof result?.title === 'string' && result.title.trim() && typeof result?.href === 'string' && result.href)
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
    load: (pageNumber = 1, perPage = 50, variables = null) => {
      const query = typeof variables?.search === 'string' ? variables.search.trim() : ''
      return SectionsManager.wrapResponse(searchPage(ext, query, pageNumber), perPage)
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
      lists.push(Promise.resolve(anilistClient.search({ search: title, page: 1, perPage: 10 })).then(res => res?.data?.Page?.media || []).catch(() => []))
    }
    if (targets.western) {
      lists.push(tmdbClient.textSearch(title).then(res => res?.data?.Page?.media || []).catch(() => []))
    }
  }
  return (await Promise.all(lists)).flat()
}

/** AniList / TMDB media matching a module result, null when none is close enough. */
export async function findMatch (sora) {
  const stored = extensionManager.extensions.get(sora.extensionKey)
  const ext = stored && { key: sora.extensionKey, ...stored }
  const targets = matchTargets(ext?.manifest)
  let match = pickBestMatch([sora.title], await candidates([sora.title], targets))
  if (!match && ext) {
    const aliases = await resultAliases(ext, sora.href)
    if (aliases.length) match = pickBestMatch([sora.title, ...aliases], await candidates(aliases, targets))
  }
  return match
}

let opening = null

/**
 * Card click on a module result: opens the details of the matching title and remembers the module result for Play.
 * @param {any} media card media built by resultMedia
 */
export async function openSoraResult (media) {
  const sora = media?.sora
  if (!sora || opening === sora.href) return
  opening = sora.href
  const toastId = toast.loading(`Looking for "${sora.title}" on AniList and TMDB…`)
  try {
    const match = await findMatch(sora)
    if (!match) {
      toast.error('No AniList or TMDB title matches this result', { id: toastId, description: `${sora.title} (${sora.extensionName})` })
      return
    }
    preferredSources.set(match.id, { extensionKey: sora.extensionKey, href: sora.href, title: sora.title })
    toast.dismiss(toastId)
    modal.open(modal.ANIME_DETAILS, match)
  } catch (error) {
    debug('Sora result match failed', error)
    toast.error('Could not open this result', { id: toastId, description: error?.message || String(error) })
  } finally {
    opening = null
  }
}
