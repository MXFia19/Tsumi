<script context='module'>
  import { settings } from '@/modules/settings.js'
  import {
    extensionManager,
    callExtension
  } from '@/modules/extension.js'
  import { sessionServer } from '@/modules/session.js'
  import { shareNowPlaying } from '@/routes/w2g/components/session.js'
  import {
    files,
    nowPlaying as currentMedia
  } from '@/components/MediaHandler.svelte'
  import { page, modal } from '@/modules/navigation.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { click } from '@/modules/click.js'
  import { toast } from 'svelte-sonner'
  import { parseStreamResponse } from '@/modules/streaming.js'
  import { X, Loader, Play, AlertTriangle } from 'lucide-svelte'
  import Debug from 'debug'
  const debug = Debug('ui:streams')

  function titleScore (searchTitle, resultTitle) {
    if (!searchTitle || !resultTitle) return 0
    const a = searchTitle
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .trim()
    const b = resultTitle
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .trim()
    if (a === b) return 100
    if (b.includes(a) || a.includes(b)) return 90
    const aWords = a.split(/\s+/)
    const bWords = b.split(/\s+/)
    const matches = aWords.filter((w) =>
      bWords.some((bw) => bw === w || (w.length > 2 && bw.includes(w)))
    ).length
    return Math.min(
      Math.round((matches / Math.max(aWords.length, 1)) * 80),
      80
    )
  }
</script>

<script>
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import { onDestroy } from 'svelte'
  import {
    getKitsuMappings,
    getEpisodeMetadataForMedia
  } from '@/modules/anime/anime.js'

  export let search
  export let close

  let loading = true
  // Extensions whose search has not answered yet: the results of the others are shown meanwhile.
  let pendingSearches = 0
  let groupedResults = []
  let playingResult = null
  let expandedGroups = {}

  $: defaultFailed = search?.defaultFailed
  $: failReason = search?.failReason

  // Search and result selection in progress. A new search (menu reopened for another title / episode), closing the
  // menu or Cancel aborts them (sandboxed modules are stopped), and every step checks it is still current.
  let searchController = null
  let selection = null // { result, controller }

  function cancelSelection () {
    selection?.controller.abort()
    selection = null
    playingResult = null
  }

  async function searchExtensions (forSearch) {
    searchController?.abort()
    cancelSelection()
    const controller = new AbortController()
    searchController = controller
    const { signal } = controller
    loading = true
    pendingSearches = 0
    groupedResults = []
    const title = anilistClient.title(forSearch?.media)
    if (!title) {
      loading = false
      return
    }

    const enabled = extensionManager.getEnabled()
    if (!enabled.length) {
      loading = false
      return
    }

    const starredKey = settings.value.starredExtension

    // Default extension auto-play is now handled by DefaultLoadingModal.
    // If we get here with defaultFailed, skip auto-play and do normal search.
    // If we get here without defaultFailed but with a default set, it means
    // playAnime was called with force=true, so also do normal search.

    // Normal flow: search all extensions; groups appear as soon as their extension answers, starred first, the
    // others in the order of the extension list.
    const sorted = [...enabled].sort((a, b) => {
      if (a.key === starredKey && b.key !== starredKey) return -1
      if (b.key === starredKey && a.key !== starredKey) return 1
      return 0
    })
    pendingSearches = sorted.length

    const searches = sorted.map((ext, order) =>
      callExtension(
        ext,
        'searchResults',
        [title, ...(ext.type === 'stremio' ? [forSearch?.media] : [])],
        { signal }
      )
        .then((raw) => {
          if (signal.aborted) return
          const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw
          if (Array.isArray(parsed) && parsed.length) {
            const scored = parsed
              .map((r) => ({
                ...r,
                extensionKey: ext.key,
                extensionName: ext.manifest?.sourceName || ext.key,
                extensionIcon: ext.manifest?.iconUrl,
                score: titleScore(title, r.title)
              }))
              .sort((a, b) => b.score - a.score)
            groupedResults = [
              ...groupedResults,
              {
                extensionKey: ext.key,
                extensionName: ext.manifest?.sourceName || ext.key,
                extensionIcon: ext.manifest?.iconUrl,
                isStarred: ext.key === starredKey,
                order,
                results: scored
              }
            ].sort((a, b) => a.order - b.order)
          }
        })
        .catch((error) => { if (error?.name !== 'AbortError') debug(`Extension ${ext.key} search failed:`, error) })
        .finally(() => { if (!signal.aborted) pendingSearches-- })
    )
    await Promise.allSettled(searches)
    if (!signal.aborted) loading = false
  }

  /**
   * @param {any} result
   * @param {{ strict?: boolean }} [options] strict: a result that does not list the episode is not played (preferred
   *   Sora source); otherwise its first episode is (movies, single-file results).
   */
  async function selectResult (result, { strict = false } = {}) {
    if (playingResult) return
    const controller = new AbortController()
    const current = { result, controller }
    selection = current
    playingResult = result
    const { signal } = controller
    const active = () => selection === current && !signal.aborted
    const capturedSearch = search
    const capturedMedia = capturedSearch?.media
    const capturedEpisode = capturedSearch?.episode
    const ext = extensionManager.extensions.get(result.extensionKey)
    const launch = {
      source: ext?.manifest?.sourceName || result.extensionName || '',
      origin: { extensionKey: result.extensionKey, sourceHref: result.href, sourceTitle: result.title }
    }
    const done = () => {
      if (selection !== current) return
      selection = null
      playingResult = null
    }

    try {
      const rawEpisodes = await callExtension(
        { key: result.extensionKey, ...ext },
        'extractEpisodes',
        [result.href],
        { signal }
      )
      if (!active()) return
      const parsedEpisodes =
        typeof rawEpisodes === 'string' ? JSON.parse(rawEpisodes) : rawEpisodes
      const episodes = Array.isArray(parsedEpisodes) ? parsedEpisodes : []

      if (!episodes.length) {
        toast.error('No episodes found for this title')
        done()
        return
      }

      let targetEp
      const targetNumber =
        typeof capturedEpisode === 'object'
          ? capturedEpisode.number
          : Number(capturedEpisode)
      const targetLocal =
        typeof capturedEpisode === 'object'
          ? capturedEpisode.localEpisode
          : null
      const targetSeason =
        typeof capturedEpisode === 'object' ? capturedEpisode.season : null

      if (targetSeason != null && targetLocal != null) {
        targetEp = episodes.find(
          (ep) =>
            ep.season != null &&
              Number(ep.season) === targetSeason &&
              Number(ep.number) === targetLocal
        )

        if (!targetEp) {
          targetEp = episodes.find((ep) =>
            ep.href?.match(
              new RegExp(`/${targetSeason}/${targetLocal}(?:/|$)`)
            )
          )
        }

        if (!targetEp) {
          let currentInferredSeason =
            episodes[0]?.season != null ? Number(episodes[0].season) : 1
          let lastNum = 0
          for (const ep of episodes) {
            const num = Number(ep.number)
            if (ep.season == null) {
              if (num < lastNum) currentInferredSeason++
              ep.inferredSeason = currentInferredSeason
            } else {
              currentInferredSeason = Number(ep.season)
              ep.inferredSeason = currentInferredSeason
            }
            lastNum = num
          }
          targetEp = episodes.find(
            (ep) =>
              ep.inferredSeason === targetSeason &&
                Number(ep.number) === targetLocal
          )
        }

        if (!targetEp) {
          const localMatches = episodes.filter(
            (ep) => Number(ep.number) === targetLocal
          )
          if (localMatches.length === 1) targetEp = localMatches[0]
        }
      } else {
        targetEp = episodes.find((ep) => Number(ep.number) === targetNumber)
      }

      if (!targetEp && strict && episodes.length > 1) {
        // Playing episode 1 as episode N would also count it on the list: the other extensions are listed instead.
        toast.error(`${launch.source || 'This module'} has no episode ${targetLocal ?? targetNumber} for this result`, { description: 'Pick another result below.' })
        done()
        return
      }
      targetEp = targetEp || episodes[0]

      const raw = await callExtension(
        { key: result.extensionKey, ...ext },
        'extractStreamUrl',
        [targetEp.href],
        { signal }
      )
      if (!active()) return
      let streamData
      try {
        streamData = parseStreamResponse(raw)
      } catch {
        const url = typeof raw === 'string' ? raw : raw?.url || raw?.streamUrl
        if (url) streamData = { url, headers: {}, subtitle: null }
      }

      if (!streamData?.url) {
        toast.error('No stream URL found for this episode')
        done()
        return
      }

      // Show server selector modal if multiple servers available
      if (streamData.servers && streamData.servers.length > 1) {
        const episodeNum =
          typeof capturedEpisode === 'object'
            ? capturedEpisode.number
            : targetEp.number || capturedEpisode
        const capturedStreamData = streamData

        const sessionPref = sessionServer.value
        if (sessionPref) {
          const matchedIndex = capturedStreamData.servers.findIndex(
            (s, i) => (s.title || `Server ${i + 1}`) === sessionPref
          )
          if (matchedIndex !== -1) {
            done()
            launchPlayer(
              capturedStreamData,
              episodeNum,
              capturedMedia,
              capturedEpisode,
              launch,
              matchedIndex,
              capturedStreamData.servers[matchedIndex]
            )
            return
          }
        }

        done()
        modal.open(modal.SERVER_SELECTOR, {
          servers: capturedStreamData.servers,
          onSelect: (serverIndex) => {
            const server = capturedStreamData.servers[serverIndex]
            launchPlayer(
              capturedStreamData,
              episodeNum,
              capturedMedia,
              capturedEpisode,
              launch,
              serverIndex,
              server
            )
          },
          onBack: () => {}
        })
        return
      }

      const episodeNum =
        typeof capturedEpisode === 'object'
          ? capturedEpisode.number
          : targetEp.number || capturedEpisode
      done()
      launchPlayer(streamData, episodeNum, capturedMedia, capturedEpisode, launch, 0)
    } catch (error) {
      if (!active() || error?.name === 'AbortError') return
      debug('Failed to get stream URL:', error)
      toast.error('Stream failed: ' + (error?.message || error))
      done()
    }
  }

  /**
   * @param {{ source: string, origin: object }} launch name of the extension / addon the stream comes from (Watch
   *   Together shows it as the source) and its search result ("Download Episode" of the player resolves a fresh link
   *   from it)
   */
  function launchPlayer (
    streamData,
    episodeNum,
    capturedMedia,
    capturedEpisode,
    launch,
    serverIndex = 0,
    server = null
  ) {
    const url = server?.streamUrl || streamData.url
    const headers = server?.headers || streamData.headers || {}
    const episodeRef = typeof capturedEpisode === 'object' && capturedEpisode !== null ? capturedEpisode : null

    $currentMedia = { media: capturedMedia, episode: episodeNum }
    // Watch Together: let the other participants start the same episode.
    shareNowPlaying(capturedMedia, episodeRef || episodeNum)
    files.set([
      {
        name: `${anilistClient.title(capturedMedia)} - Episode ${episodeNum}.mp4`,
        url,
        streamHeaders: headers,
        streamServers: streamData.servers || [],
        subtitle: streamData.subtitle || null,
        length: 0,
        media: {
          media: capturedMedia,
          episode: episodeNum,
          parseObject: {
            anime_title: anilistClient.title(capturedMedia),
            episode_number: episodeNum
          }
        },
        activeServerIndex: serverIndex,
        sourceName: launch.source,
        ...launch.origin,
        episodeRef
      }
    ])

    page.navigateTo(page.PLAYER)
    close()
  }

  // Only a new search object starts a search: Svelte re-sends object props whenever the modal store changes (another
  // modal opening, the server selector...), which must not restart the search or abort the stream being loaded.
  let searchedFor = null
  $: if (search && search !== searchedFor) {
    searchedFor = search
    searchExtensions(search)
    playPreferred(search.preferred)
  }

  // A title opened from a Sora module result of the search page plays from that module and result right away
  // (modules/sora/searchsource.js); the search above still lists the other extensions if it fails.
  function playPreferred (preferred) {
    if (!preferred?.extensionKey || !preferred.href) return
    const ext = extensionManager.getEnabled().find(enabled => enabled.key === preferred.extensionKey)
    if (!ext) return
    selectResult({ extensionKey: ext.key, extensionName: ext.manifest?.sourceName || ext.key, extensionIcon: ext.manifest?.iconUrl, href: preferred.href, title: preferred.title }, { strict: true })
  }

  function toggleGroup (key) {
    expandedGroups[key] = !expandedGroups[key]
    expandedGroups = expandedGroups
  }

  onDestroy(() => {
    searchController?.abort()
    cancelSelection()
    groupedResults = []
    search = null
  })
</script>

<div
  class='controls w-full bg-very-dark position-sticky top-0 z-10 pt-20 pb-10 px-30 mb-10'
>
  <div class='d-flex'>
    <h3
      class='mb-0 font-weight-bold text-white header-title mr-5 font-scale-40'
    >
      {anilistClient.title(search?.media)}
    </h3>
    <button
      type='button'
      class='btn btn-square bg-dark-very-light ml-auto d-flex align-items-center justify-content-center rounded-2 flex-shrink-0'
      use:click={close}><X size='1.7rem' strokeWidth='3' /></button
    >
    <div class='position-absolute top-0 left-0 w-full h-full z--1'>
      <div class='position-absolute w-full h-full overflow-hidden'>
        <SmartImage
          class='img-cover w-full h-full'
          images={[
            search?.media?.bannerImage,
            ...(search?.media?.trailer?.id
              ? [
                `https://i.ytimg.com/vi/${search.media.trailer.id}/maxresdefault.jpg`,
                `https://i.ytimg.com/vi/${search.media.trailer.id}/hqdefault.jpg`
              ]
              : []),
            () =>
              getKitsuMappings(search?.media?.id).then((metadata) => [
                metadata?.included?.[0]?.attributes?.coverImage?.original,
                metadata?.included?.[0]?.attributes?.coverImage?.large,
                metadata?.included?.[0]?.attributes?.coverImage?.small,
                metadata?.included?.[0]?.attributes?.coverImage?.tiny
              ]),
            () =>
              getEpisodeMetadataForMedia(search?.media).then(
                (metadata) => metadata?.[1]?.image
              ),
            search?.media?.coverImage?.extraLarge
          ]}
        />
      </div>
      <div
        class='position-absolute top-0 left-0 w-full h-full'
        style='background: var(--extension-banner-gradient)'
      ></div>
    </div>
  </div>
</div>

<div class='mt-10 mb-sm-10 px-30'>
  {#if defaultFailed}
    <div class='d-flex align-items-center bg-dark-light rounded p-15 mb-20'>
      <AlertTriangle size='2rem' class='text-warning mr-15 flex-shrink-0' />
      <div>
        <span class='font-weight-bold text-white font-scale-16'
        >Default extension failed</span
        >
        <span class='text-muted font-scale-14 d-block mt-3'
        >{failReason || 'Unable to auto-play from your default extension.'} Showing
        all results instead.</span
        >
      </div>
    </div>
  {/if}
  {#if playingResult}
    <div class='d-flex align-items-center bg-dark-light rounded p-15 mb-20'>
      <Loader size='2rem' class='spinning text-muted mr-15 flex-shrink-0' />
      <span class='text-white font-scale-16 text-truncate'>Loading {playingResult.title || 'stream'}...</span>
      <button type='button' class='btn bg-dark rounded-2 ml-auto px-15 font-scale-14 flex-shrink-0' use:click={cancelSelection}>Cancel</button>
    </div>
  {/if}
  {#if loading && !groupedResults.length}
    <div
      class='d-flex flex-column align-items-center justify-content-center mt-80'
    >
      <Loader size='4rem' class='spinning text-muted' />
      <span class='text-muted mt-20 font-scale-18'>Searching extensions...</span
      >
    </div>
  {:else if !groupedResults.length}
    <div
      class='d-flex flex-column align-items-center justify-content-center mt-80'
    >
      <h3 class='font-weight-bold'>Ooops!</h3>
      <span class='text-muted font-scale-18'>
        {#if !extensionManager.getEnabled().length}
          No extensions enabled. Add extensions in Settings → Extensions.
        {:else}
          No results found from any extension.
        {/if}
      </span>
    </div>
  {:else}
    {#each groupedResults as group (group.extensionKey)}
      <div class='mb-20'>
        <div class='d-flex align-items-center mb-10'>
          {#if group.extensionIcon}
            <img class='ext-icon mr-5' src={group.extensionIcon} alt="" />
          {/if}
          <span class='font-weight-bold font-scale-18 text-white'
          >{group.extensionName}</span
          >
          {#if group.isStarred}
            <span class='badge bg-warning border-0 ml-10 font-scale-12'
            >Starred</span
            >
          {/if}
          <span class='text-muted ml-10 font-scale-14'
          >{group.results.length} result{group.results.length === 1
            ? ''
            : 's'}</span
          >
        </div>
        <div
          class='results-grid'
          class:results-grid-collapsed={!expandedGroups[group.extensionKey]}
        >
          {#each group.results as result, i}
            <div class='d-flex p-15 position-relative'>
              <button
                type='button'
                class='item load-in small-card d-flex flex-column pointer border-0 p-0 text-left w-full'
                disabled={!!playingResult}
                use:click={() => selectResult(result)}
              >
                <div class='d-inline-block position-relative w-full'>
                  {#if playingResult === result}
                    <div
                      class='position-absolute w-full h-full d-flex align-items-center justify-content-center z-2'
                    >
                      <Loader size='3rem' class='spinning text-white' />
                    </div>
                  {/if}
                  {#if result.image}
                    <SmartImage
                      class='cover-img cover-color cover-ratio w-full rounded'
                      color='var(--tertiary-color)'
                      images={[result.image, './404_cover.png']}
                    />
                  {:else}
                    <div
                      class='cover-ratio w-full rounded d-flex align-items-center justify-content-center'
                      style='background: var(--dark-color-light)'
                    >
                      <Play size='3rem' class='text-muted' />
                    </div>
                  {/if}
                </div>
                <div
                  class='text-white font-weight-very-bold font-size-16 title overflow-hidden mt-5'
                >
                  {result.title}
                </div>
                <div
                  class='d-flex flex-row mt-auto font-weight-medium justify-content-between w-full text-muted'
                >
                  <span
                    class="badge border-0 font-scale-12 {result.score >= 80
                      ? 'bg-success'
                      : result.score >= 50
                        ? 'bg-warning'
                        : 'bg-light'}">{result.score}% match</span
                  >
                </div>
              </button>
            </div>
          {/each}
        </div>
        {#if group.results.length > 5 && !expandedGroups[group.extensionKey]}
          <span
            class='more-link text-muted font-scale-14 pointer mt-5 ml-15'
            use:click={() => toggleGroup(group.extensionKey)}
          >+ {group.results.length - 5} More</span
          >
        {:else if group.results.length > 5 && expandedGroups[group.extensionKey]}
          <span
            class='more-link text-muted font-scale-14 pointer mt-5 ml-15'
            use:click={() => toggleGroup(group.extensionKey)}>Show Less</span
          >
        {/if}
      </div>
    {/each}
    {#if loading && pendingSearches > 0}
      <div class='d-flex align-items-center text-muted font-scale-14 mb-20'>
        <Loader size='1.6rem' class='spinning mr-10' />
        <span>Waiting for {pendingSearches} more extension{pendingSearches === 1 ? '' : 's'}...</span>
      </div>
    {/if}
  {/if}
</div>

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
  .title {
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    line-height: 1.2;
  }
  .mt-80 {
    margin-top: 8rem;
  }
  .results-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr));
  }
  .results-grid-collapsed {
    max-height: 32rem;
    overflow: hidden;
  }
  .results-grid :global(.item.small-card) {
    max-width: 19rem;
  }
  .small-card {
    background: transparent;
    aspect-ratio: 152/296;
  }
  .small-card:hover {
    z-index: 30;
  }
  .small-card:disabled {
    opacity: 0.6;
  }
  .more-link {
    display: inline-block;
  }
  .px-15 {
    padding-left: 1.5rem;
    padding-right: 1.5rem;
  }
  .more-link:hover {
    color: var(--white-color) !important;
  }
  .ext-icon {
    width: 2rem;
    height: 2rem;
    border-radius: 50%;
  }
  :global(.spinning) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    from {
      transform: rotate(0deg);
    }
    to {
      transform: rotate(360deg);
    }
  }
</style>
