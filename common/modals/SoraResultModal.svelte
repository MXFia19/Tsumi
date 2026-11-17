<script>
  import SoftModal from '@/components/modals/SoftModal.svelte'
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import { modal } from '@/modules/navigation.js'
  import { click } from '@/modules/click.js'
  import { playAnime } from '@/modals/extension/ExtensionModal.svelte'
  import { resultEpisodes, resultDetails, forgetEpisodes } from '@/modules/sora/resultpage.js'
  import { episodeLabel } from '@/modules/sora/moduleresult.js'
  import { getAnimeProgress } from '@/modules/anime/animeprogress.js'
  import { X, Play, Loader, CircleAlert, RefreshCw, Puzzle } from 'lucide-svelte'

  // Page of a Sora module result opened as it is, without an AniList / TMDB title (sora/searchsource.js): what the
  // module says about it and its episodes, played from that module only (ExtensionModal.svelte playAnime). No list
  // tracking.

  $: media = $modal[modal.SORA_RESULT]?.data
  $: sora = media?.sora

  let loadedFor = null
  let episodes = []
  let loading = false
  let error = ''
  let details = { description: '', airdate: '' }
  let detailsController = null

  $: if (media?.id !== loadedFor) load(media)

  async function load (target) {
    loadedFor = target?.id
    episodes = []
    error = ''
    details = { description: '', airdate: '' }
    detailsController?.abort()
    if (!target?.sora) return
    const controller = new AbortController()
    detailsController = controller
    resultDetails(target, { signal: controller.signal }).then(found => { if (loadedFor === target.id) details = found })
    loading = true
    try {
      const list = await resultEpisodes(target)
      if (loadedFor === target.id) episodes = list
    } catch (err) {
      if (loadedFor === target.id) error = err?.message || String(err)
    } finally {
      if (loadedFor === target.id) loading = false
    }
  }

  /** Part of an episode already watched here (saved position), 0 to 1. */
  function watched (number) {
    const progress = media && getAnimeProgress({ mediaId: media.id, episode: number })
    return progress?.safeduration ? Math.min(1, Math.max(0, progress.currentTime / progress.safeduration)) : 0
  }

  function retry () {
    forgetEpisodes(media)
    loadedFor = null
  }

  function close () {
    detailsController?.abort()
    modal.close(modal.SORA_RESULT)
  }
</script>

<SoftModal class='m-0 w-full wm-1150 h-full rounded bg-very-dark pt-0 mx-20' bind:showModal={$modal[modal.SORA_RESULT]} {close} id={modal.SORA_RESULT} label={sora?.title}>
  {#if sora}
    <div class='controls w-full bg-very-dark position-sticky top-0 z-10 pt-20 pb-10 px-30 mb-10'>
      <div class='d-flex align-items-start'>
        <div class='overflow-hidden mr-5'>
          <h3 class='mb-0 font-weight-bold text-white header-title font-scale-40' title={sora.title}>{sora.title}</h3>
          <div class='d-flex align-items-center text-muted font-scale-16 mt-5'>
            <Puzzle size='1.6rem' class='mr-5 flex-shrink-0' />
            <span class='text-truncate'>{sora.extensionName}{details.airdate ? ` · ${details.airdate}` : ''}</span>
          </div>
        </div>
        <button type='button' class='btn btn-square bg-dark-very-light ml-auto d-flex align-items-center justify-content-center rounded-2 flex-shrink-0' use:click={close} aria-label='Close'><X size='1.7rem' strokeWidth='3' /></button>
        <div class='position-absolute top-0 left-0 w-full h-full z--1'>
          <div class='position-absolute w-full h-full overflow-hidden'>
            <SmartImage class='img-cover w-full h-full' images={[sora.image]} />
          </div>
          <div class='position-absolute top-0 left-0 w-full h-full' style='background: var(--extension-banner-gradient)'></div>
        </div>
      </div>
    </div>

    <div class='px-30 pb-30'>
      <div class='d-flex flex-column flex-md-row'>
        {#if sora.image}
          <div class='cover flex-shrink-0 mb-20 mr-md-20 rounded overflow-hidden'>
            <SmartImage class='img-cover w-full h-full' images={[sora.image]} />
          </div>
        {/if}
        <div class='flex-grow-1 overflow-hidden'>
          <div class='text-muted font-scale-14 mb-15'>Opened as it is from the module: no AniList or TMDB title, no list tracking.</div>
          {#if details.description}
            <p class='text-white font-scale-16 description pre-wrap mt-0 mb-20'>{details.description}</p>
          {/if}

          {#if loading}
            <div class='d-flex align-items-center text-muted font-scale-16'><Loader size='1.8rem' class='mr-10 spinning' />Loading episodes...</div>
          {:else if error}
            <div class='d-flex align-items-center text-danger font-scale-16'>
              <CircleAlert size='1.8rem' class='mr-10 flex-shrink-0' />
              <span class='text-break'>{error}</span>
              <button type='button' class='btn btn-sm bg-dark rounded-2 ml-10 d-flex align-items-center flex-shrink-0' use:click={retry}><RefreshCw size='1.4rem' class='mr-5' />Retry</button>
            </div>
          {:else if !episodes.length}
            <div class='text-muted font-scale-16'>No episodes found</div>
          {:else}
            <div class='episodes'>
              {#each episodes as episode (episode.href)}
                {@const progress = watched(episode.number)}
                <button type='button' class='btn bg-dark-light d-flex align-items-center rounded-2 px-15 py-10 h-auto text-left position-relative overflow-hidden' use:click={() => playAnime(media, { number: episode.number })} title={episodeLabel(episode, episodes.length)}>
                  <Play size='1.6rem' class='mr-10 flex-shrink-0' fill='currentColor' />
                  <span class='text-truncate'>{episodeLabel(episode, episodes.length)}</span>
                  {#if progress > 0}
                    <span class='watched position-absolute bottom-0 left-0' style='width: {progress * 100}%'></span>
                  {/if}
                </button>
              {/each}
            </div>
          {/if}
        </div>
      </div>
    </div>
  {/if}
</SoftModal>

<style>
  .controls {
    box-shadow: 0 1.2rem 1.2rem var(--dark-color-dim);
  }
  .header-title {
    display: inline-block;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100%;
    text-shadow: 2px 2px 4px hsla(var(--black-color-hsl), 1);
  }
  .cover {
    width: 18rem;
    aspect-ratio: 2 / 3;
  }
  .description {
    line-height: 1.5;
    max-height: 20rem;
    overflow-y: auto;
  }
  .watched {
    height: .3rem;
    background: var(--accent-color);
  }
  .episodes {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr));
    gap: 1rem;
  }
</style>
