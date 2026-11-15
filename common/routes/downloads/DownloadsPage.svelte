<script>
  import { onMount } from 'svelte'
  import { downloads, downloadInfo, downloadsSupported, downloadAction, playDownload, openDownloadFolder } from '@/modules/downloads/downloads.js'
  import { formatBytes } from '@/modules/downloads/resolve.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { ELECTRON } from '@/modules/bridge.js'
  import { page, modal } from '@/modules/navigation.js'
  import { click } from '@/modules/click.js'
  import { ArrowDownToLine, Play, Pause, RotateCcw, X, Trash2, FolderOpen, TriangleAlert, Loader, Settings } from 'lucide-svelte'

  // Downloads: progress of the running downloads (pause / resume / cancel / retry) and the finished episodes
  // (play offline, delete), with the storage they use. Works without network: everything comes from the main process.

  let port = null
  onMount(async () => {
    port = await ELECTRON.getProxyPort?.()
  })

  const ACTIVE = ['queued', 'resolving', 'downloading', 'paused', 'failed']

  $: active = $downloads.filter(item => ACTIVE.includes(item.status))
  $: completed = $downloads.filter(item => item.status === 'completed')
  $: groups = groupByTitle(completed)
  $: used = $downloads.reduce((total, item) => total + (item.status === 'completed' ? (item.sizeOnDisk || item.bytes || 0) : (item.bytes || 0)), 0)

  function groupByTitle (items) {
    const map = new Map()
    for (const item of items) {
      const key = String(item.mediaId)
      if (!map.has(key)) map.set(key, { key, media: item.media, title: item.media ? anilistClient.title(item.media) : item.title, items: [] })
      map.get(key).items.push(item)
    }
    for (const group of map.values()) {
      group.items.sort((a, b) => (a.episode?.season ?? 0) - (b.episode?.season ?? 0) || (a.episode?.number ?? 0) - (b.episode?.number ?? 0))
      group.size = group.items.reduce((total, item) => total + (item.sizeOnDisk || 0), 0)
    }
    return [...map.values()].sort((a, b) => a.title.localeCompare(b.title))
  }

  function cover (item, port) {
    if (item.cover && port) return `http://localhost:${port}/downloads/${encodeURIComponent(item.id)}/${item.cover}`
    return item.media?.coverImage?.large || item.media?.coverImage?.medium || item.media?.coverImage?.extraLarge || ''
  }

  function episodeText (item) {
    const { number, season, localEpisode } = item.episode || {}
    const label = season != null && localEpisode != null ? `S${season} E${localEpisode}` : `Episode ${number}`
    return item.episodeTitle ? `${label} - ${item.episodeTitle}` : label
  }

  function statusText (item) {
    switch (item.status) {
      case 'queued': return item.attempts ? 'Waiting to retry with a fresh link…' : 'Queued'
      case 'resolving': return 'Getting a fresh link from the extension…'
      case 'paused': return 'Paused' + (item.bytes ? ` · ${formatBytes(item.bytes)}${item.totalBytes ? ` of ${formatBytes(item.totalBytes)}` : ''}` : '')
      case 'failed': return item.error || 'Download failed'
      case 'downloading': {
        const parts = [`${Math.floor((item.progress || 0) * 100)}%`]
        if (item.bytes) parts.push(item.totalBytes ? `${formatBytes(item.bytes)} of ${item.kind === 'hls' ? '~' : ''}${formatBytes(item.totalBytes)}` : formatBytes(item.bytes))
        if (item.speed) parts.push(`${formatBytes(item.speed)}/s`)
        if (item.quality) parts.push(`${item.quality}p`)
        return parts.join(' · ')
      }
      default: return ''
    }
  }

  function completedText (item) {
    const parts = [formatBytes(item.sizeOnDisk || item.bytes || 0)]
    if (item.quality) parts.push(`${item.quality}p`)
    if (item.subtitles?.length) parts.push(item.subtitles.length === 1 ? 'Subtitles' : `${item.subtitles.length} subtitles`)
    if (item.source?.extensionName) parts.push(item.source.extensionName)
    return parts.join(' · ')
  }

  function confirmDelete (item) {
    downloadAction('delete', item.id)
  }

  function deleteGroup (group) {
    for (const item of group.items) downloadAction('delete', item.id)
  }

  function openDetails (media) {
    if (media?.id) modal.open(modal.ANIME_DETAILS, media)
  }
</script>

<div class='h-full w-full overflow-y-scroll root overflow-x-hidden'>
  <div class='d-flex flex-column w-full mt-15 pl-sm-30 pl-md-80 pb-20'>
    <div class='d-flex align-items-center flex-wrap px-20 pt-20 pb-10'>
      <ArrowDownToLine size='2.6rem' class='mr-10 flex-shrink-0' />
      <h3 class='m-0 font-weight-bold'>Downloads</h3>
      {#if downloadsSupported}
        <div class='ml-md-auto mt-10 mt-md-0 d-flex align-items-center flex-wrap'>
          <span class='text-muted mr-15'>{formatBytes(used)} used · {completed.length} {completed.length === 1 ? 'episode' : 'episodes'}</span>
          <button type='button' class='btn bg-dark-light rounded-2 h-36 px-15 d-flex align-items-center mr-10' title={$downloadInfo.folder} use:click={() => openDownloadFolder()}>
            <FolderOpen size='1.8rem' class='mr-5' /> Open Folder
          </button>
          <button type='button' class='btn bg-dark-light rounded-2 h-36 px-15 d-flex align-items-center' title='Download settings' use:click={() => page.navigateTo(page.SETTINGS)}>
            <Settings size='1.8rem' class='mr-5' /> Settings
          </button>
        </div>
      {/if}
    </div>
    {#if downloadsSupported && $downloadInfo.folder}
      <div class='px-20 text-muted font-size-12 text-truncate'>Saved in {$downloadInfo.folder}</div>
    {/if}

    {#if !downloadsSupported}
      <div class='card m-20 p-15 bg-dark-light border wm-800'>
        <div class='d-flex'>
          <TriangleAlert size='4.3rem' class='flex-shrink-0' />
          <div class='ml-10'>
            <div class='font-size-18 font-weight-bold'>Downloads are not available</div>
            <div class='text-muted pre-wrap'>Downloading episodes needs the desktop app.</div>
          </div>
        </div>
      </div>
    {:else if !$downloads.length}
      <div class='card m-20 p-15 bg-dark-light border wm-800'>
        <div class='d-flex'>
          <ArrowDownToLine size='4.3rem' class='flex-shrink-0' />
          <div class='ml-10'>
            <div class='font-size-18 font-weight-bold'>No downloads yet</div>
            <div class='text-muted pre-wrap'>Use the download button of an episode in the details of a title, "Download Next Episodes" next to Watch Now, or "Download Episode" in the player menu. Downloaded episodes play without internet, with their subtitles.</div>
          </div>
        </div>
      </div>
    {/if}

    {#if active.length}
      <div class='px-20 pt-20 pb-5 font-size-18 font-weight-semi-bold'>In Progress</div>
      {#each active as item (item.id)}
        <div class='download-row d-flex align-items-center bg-dark-light rounded mx-20 my-5 p-10'>
          <img src={cover(item, port)} alt='' class='cover rounded flex-shrink-0 pointer' loading='lazy' on:error={(e) => { e.currentTarget.style.visibility = 'hidden' }} use:click={() => openDetails(item.media)} />
          <div class='flex-grow-1 mx-15 overflow-hidden'>
            <div class='font-weight-bold text-white text-truncate'>{item.media ? anilistClient.title(item.media) : item.title}</div>
            <div class='text-muted font-size-12 text-truncate'>{episodeText(item)}</div>
            {#if item.status === 'downloading' || item.status === 'paused'}
              <div class='progress my-5' class:paused={item.status === 'paused'}>
                <div class='progress-bar' style='width: {Math.floor((item.progress || 0) * 100)}%'></div>
              </div>
            {/if}
            <div class='font-size-12 d-flex align-items-center' class:text-danger={item.status === 'failed'} class:text-muted={item.status !== 'failed'}>
              {#if item.status === 'resolving'}<Loader size='1.4rem' class='spinning mr-5 flex-shrink-0' />{/if}
              {#if item.status === 'failed'}<TriangleAlert size='1.4rem' class='mr-5 flex-shrink-0' />{/if}
              <span class='status-text'>{statusText(item)}</span>
            </div>
          </div>
          <div class='d-flex flex-shrink-0'>
            {#if item.status === 'failed'}
              <button type='button' class='btn btn-square bg-dark rounded-2 mr-5 d-flex align-items-center justify-content-center' title='Retry' use:click={() => downloadAction('retry', item.id)}><RotateCcw size='1.8rem' /></button>
            {:else if item.status === 'paused'}
              <button type='button' class='btn btn-square bg-dark rounded-2 mr-5 d-flex align-items-center justify-content-center' title='Resume' use:click={() => downloadAction('resume', item.id)}><Play size='1.8rem' /></button>
            {:else}
              <button type='button' class='btn btn-square bg-dark rounded-2 mr-5 d-flex align-items-center justify-content-center' title='Pause' use:click={() => downloadAction('pause', item.id)}><Pause size='1.8rem' /></button>
            {/if}
            <button type='button' class='btn btn-square bg-dark rounded-2 d-flex align-items-center justify-content-center' title={item.status === 'failed' || item.status === 'paused' ? 'Delete' : 'Cancel'} use:click={() => downloadAction('cancel', item.id)}><X size='1.8rem' /></button>
          </div>
        </div>
      {/each}
    {/if}

    {#each groups as group (group.key)}
      <div class='d-flex align-items-center px-20 pt-20 pb-5'>
        <span class='font-size-18 font-weight-semi-bold text-truncate pointer' use:click={() => openDetails(group.media)}>{group.title}</span>
        <span class='text-muted ml-10 text-nowrap'>{group.items.length} {group.items.length === 1 ? 'episode' : 'episodes'} · {formatBytes(group.size)}</span>
        <button type='button' class='btn btn-link text-muted ml-auto font-size-12 text-nowrap' title='Delete every downloaded episode of this title' use:click={() => deleteGroup(group)}>Delete All</button>
      </div>
      {#each group.items as item (item.id)}
        <div class='download-row d-flex align-items-center bg-dark-light rounded mx-20 my-5 p-10 pointer' role='button' tabindex='0' use:click={() => playDownload(item)}>
          <img src={cover(item, port)} alt='' class='cover rounded flex-shrink-0' loading='lazy' on:error={(e) => { e.currentTarget.style.visibility = 'hidden' }} />
          <div class='flex-grow-1 mx-15 overflow-hidden'>
            <div class='font-weight-bold text-white text-truncate'>{episodeText(item)}</div>
            <div class='text-muted font-size-12 text-truncate'>{completedText(item)}</div>
            {#if item.subtitleError}
              <div class='text-warning font-size-12 text-truncate'>{item.subtitleError}</div>
            {/if}
          </div>
          <div class='d-flex flex-shrink-0'>
            <button type='button' class='btn btn-square bg-dark rounded-2 mr-5 d-flex align-items-center justify-content-center' title='Play offline' use:click={() => playDownload(item)}><Play size='1.8rem' fill='currentColor' /></button>
            <button type='button' class='btn btn-square bg-dark rounded-2 mr-5 d-flex align-items-center justify-content-center' title='Show in folder' use:click={() => openDownloadFolder(item.id)}><FolderOpen size='1.8rem' /></button>
            <button type='button' class='btn btn-square bg-dark rounded-2 d-flex align-items-center justify-content-center' title='Delete' use:click={() => confirmDelete(item)}><Trash2 size='1.8rem' /></button>
          </div>
        </div>
      {/each}
    {/each}
  </div>
</div>

<style>
  .download-row {
    max-width: 120rem;
    min-height: 8rem;
  }
  .cover {
    width: 4.6rem;
    height: 6.6rem;
    object-fit: cover;
    background: var(--dark-color-light);
  }
  .progress {
    height: .4rem;
    min-height: .4rem;
  }
  .progress.paused .progress-bar {
    opacity: .5;
  }
  .status-text {
    overflow: hidden;
    text-overflow: ellipsis;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
</style>
