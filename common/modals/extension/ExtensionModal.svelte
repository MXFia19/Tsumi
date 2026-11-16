<script context='module'>
  import SoftModal from '@/components/modals/SoftModal.svelte'
  import ExtensionResults from '@/modals/extension/components/ExtensionResults.svelte'
  import { modal } from '@/modules/navigation.js'
  import { settings } from '@/modules/settings.js'
  import { mediaCache } from '@/modules/cache.js'
  import { playDownloadedIfAvailable } from '@/modules/downloads/downloads.js'

  export function playAnime (media, episode = 1, force = false) {
    const episodeData = typeof episode === 'object' && episode !== null ? { ...episode } : { number: Number(episode) }
    episodeData.number = isNaN(episodeData.number) ? 1 : episodeData.number
    // A downloaded episode plays from disk (works offline); force (right click) still opens the extensions.
    if (!force && playDownloadedIfAvailable(media, episodeData)) return

    // Use compact loading dialog when a default extension is set
    if (settings.value.defaultExtension && !force) {
      modal.open(modal.DEFAULT_LOADING, { media, episode: episodeData })
    } else {
      modal.open(modal.EXTENSION_MENU, { media, episode: episodeData })
    }
  }

  // Watch Together: another participant started a title (see routes/w2g).
  window.addEventListener('w2g-play', ({ detail }) => {
    if (detail?.media?.id) playAnime(mediaCache.value[detail.media.id] || detail.media, detail.episode)
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
