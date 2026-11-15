<script>
  import { downloads, downloadsSupported, findDownload, downloadEpisode, downloadAction, playDownload } from '@/modules/downloads/downloads.js'
  import { page } from '@/modules/navigation.js'
  import { click } from '@/modules/click.js'
  import { ArrowDownToLine, CircleCheck, Loader, Pause, TriangleAlert } from 'lucide-svelte'

  // Download state / action of one episode (EpisodeList.svelte). Click: download, play the downloaded file,
  // retry a failed download, or open the Downloads page while it runs.

  export let media
  /** { number, season?, localEpisode?, title?, image? } */
  export let episode
  export let size = '1.8rem'

  $: item = findDownload($downloads, media?.id, episode)
  $: percent = Math.floor((item?.progress || 0) * 100)
  $: title = describe(item, percent)

  function describe (item, percent) {
    if (!item) return 'Download episode'
    switch (item.status) {
      case 'completed': return 'Downloaded: play offline'
      case 'failed': return `Download failed: ${item.error || 'retry'}`
      case 'paused': return 'Download paused'
      case 'downloading': return `Downloading ${percent}%`
      default: return 'Download queued'
    }
  }

  function handle () {
    if (!item) return downloadEpisode(media, episode)
    if (item.status === 'completed') return playDownload(item)
    if (item.status === 'failed') return downloadAction('retry', item.id)
    page.navigateTo(page.DOWNLOADS)
  }
</script>

{#if downloadsSupported}
  <button type='button' class='download-button btn btn-square bg-transparent shadow-none border-0 p-0 d-flex align-items-center justify-content-center {$$restProps.class || ''}' {title} aria-label={title} use:click={handle}>
    {#if !item}
      <ArrowDownToLine {size} />
    {:else if item.status === 'completed'}
      <CircleCheck {size} color='var(--success-color, #5cd13d)' />
    {:else if item.status === 'failed'}
      <TriangleAlert {size} color='var(--danger-color, #e85d75)' />
    {:else if item.status === 'paused'}
      <Pause {size} />
    {:else if item.status === 'downloading'}
      <span class='percent font-weight-bold'>{percent}%</span>
    {:else}
      <Loader {size} class='spinning' />
    {/if}
  </button>
{/if}

<style>
  .download-button {
    width: 3rem;
    height: 3rem;
    min-width: 3rem;
    opacity: .85;
  }
  .download-button:hover, .download-button:focus {
    opacity: 1;
  }
  .percent {
    font-size: 1.1rem;
  }
</style>
