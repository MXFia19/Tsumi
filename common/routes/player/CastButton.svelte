<script>
  // Cast button of the player's control bar (PC app): device picker and "Stop casting". The casting logic lives in
  // common/modules/cast.js (renderer) and electron/src/main/cast/ (discovery, Cast protocol, LAN proxy).
  import { onDestroy } from 'svelte'
  import { Cast, Loader, Check } from 'lucide-svelte'
  import { anilistClient } from '@/modules/anilist.js'
  import { cast, castDevices, castState, castSupported } from '@/modules/cast.js'

  export let video = null
  /** File playing (MediaHandler): url, streamHeaders, media */
  export let current = null
  /** nowPlaying */
  export let media = null
  export let streamServers = []
  export let activeServerIndex = 0
  export let subs = null
  /** Changes whenever the subtitle tracks or the selected one change */
  export let subHeaders = null
  /** Subtitle offset (s) */
  export let delay = 0
  export let disabled = false
  /** Called before the menu opens: the player closes its other menus (one menu at a time). */
  export let onOpen = null

  let open = false
  let node

  $: source = disabled ? null : buildSource(current, streamServers, activeServerIndex)
  $: castable = !!source && /^https?:\/\//i.test(source.url)
  $: metadata = buildMetadata(current, media)
  $: if ($castState.active) cast.update({ video, source, metadata, subs, subHeaders, delay })

  function buildSource (current, servers, index) {
    if (!current?.url) return null
    const server = servers?.[index]
    return {
      url: server?.streamUrl || current.url,
      headers: (server ? server.headers : null) || current.streamHeaders || {}
    }
  }

  function buildMetadata (current, media) {
    const item = current?.media?.media || media?.media
    const episode = current?.media?.episode ?? media?.episode
    const title = (item && anilistClient.title(item)) || current?.name || 'Tsumi'
    const subtitle = item?.format === 'MOVIE' || episode == null || episode === '' ? '' : `Episode ${episode}`
    const image = [item?.bannerImage, item?.coverImage?.extraLarge].find(url => /^https:\/\//i.test(url || '')) || null
    return { title, subtitle, image }
  }

  function toggle () {
    if (!open) onOpen?.()
    open = !open
    if (open) cast.discover(true)
    else if (!$castState.active) cast.discover(false)
  }

  /** Closes the device menu (also used by the player when another of its menus opens). */
  export function close () {
    if (!open) return
    open = false
    if (!$castState.active) cast.discover(false)
  }

  function choose (device) {
    close()
    if ($castState.active && $castState.device?.id === device.id) return
    cast.start(device, { video, source, metadata, subs, delay })
  }

  function stop () {
    close()
    cast.stop()
  }

  function outside (event) {
    if (open && node && !node.contains(event.target)) close()
  }

  onDestroy(() => {
    if ($castState.active) cast.stop({ resume: false })
  })
</script>

<svelte:window on:pointerdown={outside} />

{#if castSupported && (castable || $castState.active)}
  <div class='dropdown dropup with-arrow cast-button' class:show={open} bind:this={node}>
    <span
      class='icon text-white ctrl mr-5 d-flex align-items-center h-full'
      class:casting={$castState.active}
      title={$castState.active ? `Casting to ${$castState.device?.name || 'a Cast device'}` : 'Cast'}
      role='button'
      tabindex='0'
      on:click|stopPropagation={toggle}
      on:keydown={(event) => event.key === 'Enter' && toggle()}
    >
      <Cast size='2.5rem' strokeWidth={2.5} />
    </span>
    <div class='dropdown-menu dropdown-menu-right ctrl p-10 mr-15 text-nowrap' on:click|stopPropagation role='menu' tabindex='-1' on:keydown|stopPropagation>
      <div class='font-weight-bold mb-5'>Cast to a device</div>
      {#each $castDevices as device (device.id)}
        <button type='button' class='device btn btn-block d-flex align-items-center text-left px-10' on:click={() => choose(device)}>
          <span class='d-flex flex-column overflow-hidden'>
            <span class='text-truncate'>{device.name}</span>
            {#if device.model || device.status}
              <span class='text-muted font-size-12 text-truncate'>{[device.model, device.status].filter(Boolean).join(' · ')}</span>
            {/if}
          </span>
          {#if $castState.active && $castState.device?.id === device.id}
            <Check size='1.6rem' class='ml-auto flex-shrink-0' />
          {/if}
        </button>
      {/each}
      {#if !$castDevices.length}
        <div class='d-flex align-items-center text-muted py-5'>
          <Loader size='1.6rem' class='mr-10' /> Looking for devices on your network…
        </div>
      {/if}
      {#if $castState.active}
        <button type='button' class='btn btn-danger btn-block mt-10' on:click={stop}>Stop casting</button>
      {/if}
    </div>
  </div>
{/if}

<style>
  .cast-button .dropdown-menu {
    min-width: 24rem;
    max-width: 32rem;
  }
  .casting {
    color: var(--accent-color) !important;
  }
  .device {
    height: auto;
    min-height: 3.6rem;
    background: transparent;
    border: none;
    box-shadow: none;
    font-size: 1.4rem;
  }
  .device:hover, .device:focus-visible {
    background: hsla(var(--white-color-hsl), 0.08);
  }
</style>
