<script context='module'>
  import SoftModal from '@/components/modals/SoftModal.svelte'
  import ExtensionResults, { streamFrom, startStream } from '@/modals/extension/components/ExtensionResults.svelte'
  import { modal } from '@/modules/navigation.js'
  import { settings } from '@/modules/settings.js'
  import { mediaCache } from '@/modules/cache.js'
  import { callExtension } from '@/modules/extension.js'
  import { playDownloadedIfAvailable } from '@/modules/downloads/downloads.js'
  import { preferredSources } from '@/modules/sora/searchsource.js'
  import { resultModule, resultEpisodes } from '@/modules/sora/resultpage.js'
  import { episodeFor, playableMedia, episodeName } from '@/modules/sora/moduleresult.js'
  import { toast } from 'svelte-sonner'
  import Debug from 'debug'
  const debug = Debug('ui:extension-modal')

  export function playAnime (media, episode = 1, force = false) {
    const episodeData = typeof episode === 'object' && episode !== null ? { ...episode } : { number: Number(episode) }
    episodeData.number = isNaN(episodeData.number) ? 1 : episodeData.number
    // A module result opened as it is (module page, the player's next / previous episode): only its module plays it.
    if (media?.isSora) {
      playModuleEpisode(media, episodeData.number)
      return
    }
    // A downloaded episode plays from disk (works offline); force (right click) still opens the extensions.
    if (!force && playDownloadedIfAvailable(media, episodeData)) return

    // Opened from a Sora module result of the search page: play from that module and result (sora/searchsource.js).
    // The other extensions are still searched and listed, in case it fails.
    const preferred = !force && preferredSources.get(media?.id)
    if (preferred) {
      modal.open(modal.EXTENSION_MENU, { media, episode: episodeData, preferred })
      return
    }

    // Use compact loading dialog when a default extension is set
    if (settings.value.defaultExtension && !force) {
      modal.open(modal.DEFAULT_LOADING, { media, episode: episodeData })
    } else {
      modal.open(modal.EXTENSION_MENU, { media, episode: episodeData })
    }
  }

  /** Episode of a module result being loaded: a newer request (another episode, the next one) replaces it. */
  let moduleRequest = null

  /**
   * Plays an episode of a module result opened as it is (no AniList / TMDB title): its stream from the module, the
   * server choice, then the player. The playing media knows the module's episode count (next / previous episode).
   * @param {any} media card media of the result (sora/match.js resultMedia)
   * @param {number} number episode number given by the module
   */
  async function playModuleEpisode (media, number) {
    moduleRequest?.abort()
    const controller = new AbortController()
    moduleRequest = controller
    const { signal } = controller
    const toastId = toast.loading(`Loading episode ${number} of "${media.sora.title}"…`)
    try {
      const ext = resultModule(media)
      if (!ext) throw new Error(`${media.sora.extensionName} is disabled or not installed`)
      const episodes = await resultEpisodes(media)
      if (signal.aborted) return
      const episode = episodeFor(episodes, number)
      if (!episode) throw new Error(`${media.sora.extensionName} has no episode ${number} for this result`)
      // With seasons, the number played is the place in the list: the message gives the season and its number.
      if (episode.season != null) toast.loading(`Loading ${episodeName(episode)} of "${media.sora.title}"…`, { id: toastId })
      const raw = await callExtension(ext, 'extractStreamUrl', [episode.href], { signal })
      if (signal.aborted) return
      const streamData = streamFrom(raw)
      if (!streamData?.url) throw new Error('No stream URL found for this episode')
      toast.dismiss(toastId)
      const launch = {
        source: ext.manifest?.sourceName || media.sora.extensionName,
        origin: { extensionKey: ext.key, sourceHref: media.sora.href, sourceTitle: media.sora.title }
      }
      startStream(streamData, episode.number, playableMedia(media, episodes), { number: episode.number }, launch, () => modal.close(modal.SORA_RESULT))
    } catch (error) {
      if (signal.aborted || error?.name === 'AbortError') {
        toast.dismiss(toastId)
        return
      }
      debug('Module episode failed', error)
      toast.error('Could not play this episode', { id: toastId, description: error?.message || String(error) })
    } finally {
      if (moduleRequest === controller) moduleRequest = null
    }
  }

  // Watch Together: another participant started a title (see routes/w2g). The id comes from a peer: an own property
  // only (mediaCache.value["toString"] is a function).
  window.addEventListener('w2g-play', ({ detail }) => {
    const id = detail?.media?.id
    if (!id) return
    const cache = mediaCache?.value
    const cached = cache && Object.hasOwn(cache, id) ? cache[id] : null
    playAnime(cached || detail.media, detail.episode)
  })
</script>

<script>
  function close () {
    modal.close(modal.EXTENSION_MENU)
  }
</script>

<SoftModal class='m-0 w-full wm-1150 h-full rounded bg-very-dark pt-0 mx-20' bind:showModal={$modal[modal.EXTENSION_MENU]} {close} id={modal.EXTENSION_MENU}>
  <!-- $modal, not modal.value: reopening the menu for another title / episode while it is open must update it. -->
  <ExtensionResults search={$modal[modal.EXTENSION_MENU]?.data} {close} />
</SoftModal>
