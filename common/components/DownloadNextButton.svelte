<script>
  import { downloadsSupported, downloadEpisodes } from '@/modules/downloads/downloads.js'
  import { nextEpisodeNumbers } from '@/modules/downloads/resolve.js'
  import { getMediaMaxEp } from '@/modules/anime/anime.js'
  import { click } from '@/modules/click.js'
  import { ArrowDownToLine } from 'lucide-svelte'

  // "Download Next Episodes" of the details (next to Watch Now): the next 1 / 3 / 5 / 12 episodes after the list
  // progress, or all the released ones left. TMDB shows are downloaded episode by episode from the episode list.

  export let media

  let open = false

  $: isShow = media?.isTmdb && media?.format !== 'MOVIE'
  $: released = media ? (getMediaMaxEp(media, true) || (media.status === 'FINISHED' ? media.episodes : 0) || (media.format === 'MOVIE' ? 1 : 0)) : 0
  $: progress = media?.mediaListEntry?.status === 'COMPLETED' ? 0 : (media?.mediaListEntry?.progress || 0)
  $: remaining = Math.max(released - progress, 0)
  $: choices = [1, 3, 5, 12].filter(count => count < remaining)

  function download (count) {
    open = false
    const numbers = nextEpisodeNumbers({ progress, released, count })
    if (numbers.length) downloadEpisodes(media, numbers)
  }
</script>

{#if downloadsSupported && media && !isShow && released > 0 && media.status !== 'NOT_YET_RELEASED'}
  <div class='position-relative mr-10'>
    <button
      type='button'
      class='btn bg-dark-light btn-lg btn-square d-flex align-items-center justify-content-center shadow-none border-0'
      title={media.format === 'MOVIE' || released === 1 ? 'Download' : 'Download Next Episodes'}
      use:click={() => { if (released === 1) downloadEpisodes(media, [1]); else open = !open }}
    >
      <ArrowDownToLine size='1.7rem' />
    </button>
    {#if open}
      <div class='menu position-absolute bg-dark rounded shadow-lg py-5 z-30' role='menu' tabindex='-1' on:mouseleave={() => { open = false }}>
        <div class='px-15 py-5 text-muted font-size-12 text-nowrap'>After episode {progress}</div>
        {#each choices as count (count)}
          <div role='menuitem' tabindex='0' class='item px-15 py-5 pointer text-nowrap' use:click={() => download(count)}>
            {count === 1 ? 'Next episode' : `Next ${count} episodes`}
          </div>
        {/each}
        {#if remaining}
          <div role='menuitem' tabindex='0' class='item px-15 py-5 pointer text-nowrap' use:click={() => download(remaining)}>
            {progress ? 'All remaining' : 'All'} ({remaining})
          </div>
        {:else}
          <div class='px-15 py-5 text-nowrap'>No released episode left to watch.</div>
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .menu {
    top: 100%;
    left: 0;
    margin-top: .5rem;
    min-width: 18rem;
  }
  .item:hover, .item:focus {
    background: var(--dark-color-light);
  }
</style>
