<script>
  // "Search online subtitles…" panel of the player (subs.wing.st), and "Automatically add online subtitles when
  // the source has none" (settings.onlineSubtitlesAuto). iOS: ios-native/Tsumi/Player/PlayerOnlineSubtitles.swift.
  import { settings } from '@/modules/settings.js'
  import { toast } from 'svelte-sonner'
  import { X, Loader, ChevronDown, ChevronRight, RefreshCw, Search } from 'lucide-svelte'
  import { searchOnlineSubtitles, downloadOnlineSubtitle, addToPlayer, errorMessage } from '@/modules/onlinesubs/index.js'
  import { groupByLanguage, preferredLanguage, pickAutomatic, trackLabel } from '@/modules/onlinesubs/core.js'
  import Debug from 'debug'

  const debug = Debug('ui:onlinesubs')

  export let open = false
  /** @type {import('@/modules/subtitles.js').default | null} */
  export let subs = null
  /** AniList or TMDB media playing */
  export let media = null
  export let episode = null

  let status = 'idle'
  let error = ''
  let groups = []
  let expanded = {}
  let filter = ''
  let busy = null
  let loadedFor = null
  let input

  $: preferred = preferredLanguage($settings.subtitleLanguage)
  $: key = media ? `${media.id}:${episode ?? ''}` : null
  $: if (open && key && loadedFor !== key) load(false)
  $: if (open && !key) {
    status = 'error'
    error = 'Online subtitles need a recognized title.'
  }
  $: filtered = filterGroups(groups, filter)
  $: if (open && input) input.focus()

  async function load (force) {
    const target = key
    loadedFor = target
    status = 'loading'
    error = ''
    groups = []
    filter = ''
    try {
      const { list } = await searchOnlineSubtitles(media, episode, { force })
      if (target !== key) return
      groups = groupByLanguage(list, preferred)
      expanded = groups.length ? { [groups[0].language]: true } : {}
      status = 'ready'
    } catch (err) {
      if (target !== key) return
      debug('Online subtitles search failed', err)
      error = errorMessage(err)
      status = 'error'
    }
  }

  function filterGroups (groups, filter) {
    const query = filter.trim().toLowerCase()
    if (!query) return groups
    return groups
      .map(group => group.name.toLowerCase().includes(query) ? group : { ...group, items: group.items.filter(item => item.name.toLowerCase().includes(query)) })
      .filter(group => group.items.length)
  }

  async function pick (item) {
    if (busy) return
    if (!subs) {
      toast.error('Could not add these subtitles', { description: 'The video is not ready yet.' })
      return
    }
    busy = item.id
    try {
      const text = await downloadOnlineSubtitle(item)
      await addToPlayer(subs, item, text)
      toast.success('Subtitles added', { description: trackLabel(item) })
      open = false
    } catch (err) {
      debug('Adding online subtitles failed', err)
      toast.error('Could not add these subtitles', { description: errorMessage(err) })
    }
    busy = null
  }

  function toggle (language) {
    expanded = { ...expanded, [language]: !expanded[language] }
  }

  function keydown (event) {
    // Keep the player shortcuts (space, arrows, C...) out of the panel.
    event.stopPropagation()
    if (event.key === 'Escape') open = false
  }

  // Automatic mode: when the source brought no subtitle track a few seconds after loading, add the first one in
  // the preferred language. Failures stay quiet (debug log only).
  let autoFor = null
  $: scheduleAutomatic(subs, $settings.onlineSubtitlesAuto)
  function scheduleAutomatic (instance, enabled) {
    if (!instance || !enabled || autoFor === instance) return
    autoFor = instance
    const target = { media, episode }
    setTimeout(async () => {
      if (subs !== instance || !instance.headers || instance.headers.some(Boolean)) return
      try {
        const { list } = await searchOnlineSubtitles(target.media, target.episode)
        const item = pickAutomatic(list, preferredLanguage(settings.value.subtitleLanguage))
        if (!item) return debug('No online subtitles in the preferred language')
        const text = await downloadOnlineSubtitle(item)
        if (subs !== instance || !instance.headers || instance.headers.some(Boolean)) return
        await addToPlayer(instance, item, text)
        toast('Online subtitles added', { description: trackLabel(item) })
      } catch (err) {
        debug('Automatic online subtitles failed', err)
      }
    }, 8000)
  }
</script>

{#if open}
  <!-- svelte-ignore a11y-no-noninteractive-element-interactions -->
  <div
    class='online-subs position-absolute bg-dark rounded d-flex flex-column text-white'
    role='dialog'
    aria-label='Online Subtitles'
    tabindex='-1'
    on:keydown={keydown}
    on:click|stopPropagation
    on:dblclick|stopPropagation
  >
    <div class='d-flex align-items-center px-15 pt-15 pb-10'>
      <div class='font-size-18 font-weight-bold mr-auto'>Online Subtitles</div>
      <button type='button' class='btn btn-square btn-sm d-flex align-items-center justify-content-center mr-5' title='Search again' disabled={status === 'loading'} on:click={() => load(true)}>
        <RefreshCw size='1.6rem' />
      </button>
      <button type='button' class='btn btn-square btn-sm d-flex align-items-center justify-content-center' title='Close' on:click={() => (open = false)}>
        <X size='1.8rem' />
      </button>
    </div>
    <div class='px-15 pb-10 position-relative'>
      <Search size='1.6rem' class='search-icon position-absolute text-muted' />
      <input bind:this={input} type='search' class='form-control bg-dark-light pl-35' placeholder='Filter by language or release' bind:value={filter} disabled={status !== 'ready'} />
    </div>
    <div class='list overflow-y-auto px-15 pb-15'>
      {#if status === 'loading'}
        <div class='d-flex align-items-center justify-content-center text-muted py-20'>
          <Loader size='2rem' class='spin mr-10' /> Searching online subtitles…
        </div>
      {:else if status === 'error'}
        <div class='text-center text-muted py-20'>{error}</div>
      {:else if status === 'ready' && !groups.length}
        <div class='text-center text-muted py-20'>No online subtitles found for this episode.</div>
      {:else if status === 'ready' && !filtered.length}
        <div class='text-center text-muted py-20'>Nothing matches this filter.</div>
      {:else}
        {#each filtered as group (group.language)}
          {@const isOpen = expanded[group.language] || !!filter.trim()}
          <button type='button' class='group btn btn-block d-flex align-items-center text-left px-10 mt-5' on:click={() => toggle(group.language)}>
            {#if isOpen}<ChevronDown size='1.6rem' />{:else}<ChevronRight size='1.6rem' />{/if}
            <span class='ml-5 font-weight-bold'>{group.name}</span>
            {#if group.language === preferred}<span class='badge badge-primary ml-10'>Preferred</span>{/if}
            <span class='ml-auto text-muted font-size-12'>{group.items.length}</span>
          </button>
          {#if isOpen}
            {#each group.items as item (item.id)}
              <button type='button' class='item btn btn-block d-flex align-items-center text-left px-10 py-5' disabled={!!busy} title={item.name} on:click={() => pick(item)}>
                <span class='text-truncate mr-10'>{item.name}</span>
                {#if busy === item.id}
                  <Loader size='1.6rem' class='spin ml-auto flex-shrink-0' />
                {:else if item.source}
                  <span class='ml-auto text-muted font-size-12 flex-shrink-0'>{item.source}</span>
                {/if}
              </button>
            {/each}
          {/if}
        {/each}
      {/if}
    </div>
  </div>
{/if}

<style>
  .online-subs {
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: 52rem;
    max-width: calc(100% - 2rem);
    max-height: 75%;
    z-index: 60;
    box-shadow: 0 1rem 3rem rgba(0, 0, 0, 0.6);
    pointer-events: all;
  }
  .list {
    min-height: 8rem;
  }
  .online-subs :global(.search-icon) {
    left: 2.5rem;
    top: 1rem;
    pointer-events: none;
  }
  .group, .item {
    height: auto;
    min-height: 3.2rem;
    font-size: 1.4rem;
    background: transparent;
    border: none;
    box-shadow: none;
  }
  .group:hover, .item:hover, .group:focus-visible, .item:focus-visible {
    background: hsla(var(--white-color-hsl), 0.08);
  }
  .item {
    padding-left: 3.2rem !important;
  }
  .online-subs :global(.spin) {
    animation: online-subs-spin 1s linear infinite;
  }
  @keyframes online-subs-spin {
    to { transform: rotate(360deg); }
  }
</style>
