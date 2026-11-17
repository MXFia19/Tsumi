import { extensionManager, callExtension } from '@/modules/extension.js'
import { settings } from '@/modules/settings.js'
import { modal } from '@/modules/navigation.js'
import { linksResults, moduleEpisodes, moduleDetails } from './moduleresult.js'

// Module results opened as they are (no AniList / TMDB title): the module page (modals/SoraResultModal.svelte) and the
// playback of their episodes (ExtensionModal.svelte playAnime) ask the module itself. Episodes are kept for the
// session, so the next / previous episode of the player does not ask again.

/** Whether the results of this module open their AniList / TMDB title (setting of the Extensions tab). */
export function moduleLinksResults (extensionKey) {
  return linksResults(settings.value.extensions?.[extensionKey])
}

/** Opens the module page of a result (match.js resultMedia card media). */
export function openModuleResult (media) {
  if (media?.sora) modal.open(modal.SORA_RESULT, media)
}

/** Enabled module of a result, null when it was disabled or removed. */
export function resultModule (media) {
  const ext = extensionManager.getEnabled().find(enabled => enabled.key === media?.sora?.extensionKey)
  return ext || null
}

/** media id -> { promise } */
const episodeLists = new Map()

/**
 * Episodes of a module result (extractEpisodes), asked once per session; a failed answer is asked again next time.
 * Not aborted when the module page closes: the player may be waiting for the same list.
 * @param {any} media
 * @returns {Promise<{ href: string, number: number, title: string }[]>}
 */
export function resultEpisodes (media) {
  const ext = resultModule(media)
  if (!ext) return Promise.reject(new Error(`${media?.sora?.extensionName || 'This module'} is disabled or not installed`))
  const known = episodeLists.get(media.id)
  if (known) return known.promise
  const promise = callExtension(ext, 'extractEpisodes', [media.sora.href]).then(moduleEpisodes)
  episodeLists.set(media.id, { promise })
  promise.catch(() => { if (episodeLists.get(media.id)?.promise === promise) episodeLists.delete(media.id) })
  return promise
}

/** Forgets the episodes of a result ("Retry" of the module page). */
export function forgetEpisodes (media) {
  episodeLists.delete(media?.id)
}

/**
 * Description and air date of a module result (extractDetails), empty when the module has none or fails.
 * @param {any} media
 * @param {{ signal?: AbortSignal }} [options]
 */
export async function resultDetails (media, { signal } = {}) {
  const ext = resultModule(media)
  if (!ext) return moduleDetails(null)
  try {
    return moduleDetails(await callExtension(ext, 'extractDetails', [media.sora.href], { signal }))
  } catch {
    return moduleDetails(null)
  }
}
