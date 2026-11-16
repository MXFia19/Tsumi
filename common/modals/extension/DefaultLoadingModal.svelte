<script context='module'>
  import { modal } from '@/modules/navigation.js'
  import { settings } from '@/modules/settings.js'
  import { extensionManager, callExtension } from '@/modules/extension.js'
  import { sessionServer } from '@/modules/session.js'
  import { shareNowPlaying } from '@/routes/w2g/components/session.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { files, nowPlaying as currentMedia } from '@/components/MediaHandler.svelte'
  import { page } from '@/modules/navigation.js'
  import { parseStreamResponse } from '@/modules/streaming.js'
  import { click } from '@/modules/click.js'
  import Debug from 'debug'
  const debug = Debug('ui:default-loading')

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

  /** Number shown for an episode argument: a number, or an episode object ({ number, season, localEpisode }). */
  function episodeNumber (episode) {
    return typeof episode === 'object' && episode !== null ? episode.number : episode
  }
</script>

<script>
  import SoftModal from '@/components/modals/SoftModal.svelte'
  import { Loader } from 'lucide-svelte'
  import { onDestroy } from 'svelte'

  $: entry = $modal[modal.DEFAULT_LOADING]
  $: data = entry?.data
  $: media = data?.media
  $: episode = data?.episode || 1

  let statusText = 'Connecting to extension...'

  // The request in progress: { entry, controller }. Closing the dialog (Esc, backdrop, Cancel, another modal) or
  // opening it for another episode aborts it; after every await the request checks it is still the current one, so a
  // cancelled request never opens the player or the extension menu.
  let current = null

  function stop () {
    current?.controller.abort()
    current = null
  }

  function close () {
    modal.close(modal.DEFAULT_LOADING)
  }

  function cancel () {
    stop()
    close()
  }

  $: track(entry)
  function track (value) {
    if (current?.entry === value) return
    stop()
    if (value?.data?.media) autoPlay(value)
  }

  function fail (reason, failMedia, failEpisode) {
    close()
    modal.open(modal.EXTENSION_MENU, {
      media: failMedia,
      episode: failEpisode,
      defaultFailed: true,
      failReason: reason
    })
  }

  /**
   * @param {any} streamData
   * @param {number} episodeNum
   * @param {any} capturedMedia
   * @param {any} capturedEpisode episode argument of the request (number or episode object)
   * @param {{ source: string, origin: object }} launch name of the extension / addon the stream comes from (Watch
   *   Together shows it) and its search result ("Download Episode" of the player resolves a fresh link from it)
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

  async function autoPlay (requestEntry) {
    const controller = new AbortController()
    const request = { entry: requestEntry, controller }
    current = request
    const { signal } = controller
    const active = () => current === request && !signal.aborted

    const capturedMedia = requestEntry.data.media
    const capturedEpisode = requestEntry.data.episode || 1
    statusText = 'Connecting to extension...'

    const title = anilistClient.title(capturedMedia)
    const defaultKey = settings.value.defaultExtension
    // Right after the app starts the extensions are still being downloaded: wait for the default one.
    if (extensionManager.loading.has(defaultKey)) {
      await extensionManager.loading.get(defaultKey)
      if (!active()) return
    }
    const defaultExt = extensionManager
      .getEnabled()
      .find((e) => e.key === defaultKey)

    const launch = { source: defaultExt?.manifest?.sourceName || defaultExt?.key || '', origin: {} }
    if (!defaultExt) {
      const loadError = extensionManager.getStatus(defaultKey)?.error
      fail(
        loadError ? `Default extension failed to load: ${loadError}` : 'Default extension not found or disabled',
        capturedMedia,
        capturedEpisode
      )
      return
    }

    try {
      statusText = 'Searching...'
      // Stremio addons look the title up by its TMDB id, so they get the media too.
      const raw = await callExtension(
        defaultExt,
        'searchResults',
        [title, ...(defaultExt.type === 'stremio' ? [capturedMedia] : [])],
        { signal }
      )
      if (!active()) return
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw

      if (!Array.isArray(parsed) || !parsed.length) {
        fail(
          'No results found from default extension',
          capturedMedia,
          capturedEpisode
        )
        return
      }

      const scored = parsed
        .map((r) => ({
          ...r,
          extensionKey: defaultExt.key,
          score: titleScore(title, r.title)
        }))
        .sort((a, b) => b.score - a.score)

      const best = scored[0]
      launch.origin = { extensionKey: defaultExt.key, sourceHref: best.href, sourceTitle: best.title }
      statusText = 'Extracting episodes...'

      const rawEps = await callExtension(
        defaultExt,
        'extractEpisodes',
        [best.href],
        { signal }
      )
      if (!active()) return
      const parsedEps =
        typeof rawEps === 'string' ? JSON.parse(rawEps) : rawEps
      const episodes = Array.isArray(parsedEps) ? parsedEps : []

      if (!episodes.length) {
        fail(
          'No episodes found for this title',
          capturedMedia,
          capturedEpisode
        )
        return
      }

      let targetEp
      const isObject = typeof capturedEpisode === 'object' && capturedEpisode !== null
      const targetNumber = isObject ? capturedEpisode.number : Number(capturedEpisode)
      const targetLocal = isObject ? capturedEpisode.localEpisode : null
      const targetSeason = isObject ? capturedEpisode.season : null

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

      targetEp = targetEp || episodes[0]
      statusText = 'Loading stream...'

      const rawStream = await callExtension(
        defaultExt,
        'extractStreamUrl',
        [targetEp.href],
        { signal }
      )
      if (!active()) return
      let streamData
      try {
        streamData = parseStreamResponse(rawStream)
      } catch {
        const url =
          typeof rawStream === 'string'
            ? rawStream
            : rawStream?.url || rawStream?.streamUrl
        if (url) streamData = { url, headers: {}, subtitle: null }
      }

      if (!streamData?.url) {
        fail('No stream URL found', capturedMedia, capturedEpisode)
        return
      }

      const episodeNum = isObject ? capturedEpisode.number : targetEp.number || capturedEpisode

      // Handle multiple servers
      if (streamData.servers && streamData.servers.length > 1) {
        const sessionPref = sessionServer.value
        if (sessionPref) {
          const matchedIndex = streamData.servers.findIndex(
            (s, i) => (s.title || `Server ${i + 1}`) === sessionPref
          )
          if (matchedIndex !== -1) {
            launchPlayer(
              streamData,
              episodeNum,
              capturedMedia,
              capturedEpisode,
              launch,
              matchedIndex,
              streamData.servers[matchedIndex]
            )
            return
          }
        }

        close()
        modal.open(modal.SERVER_SELECTOR, {
          servers: streamData.servers,
          onSelect: (i) =>
            launchPlayer(
              streamData,
              episodeNum,
              capturedMedia,
              capturedEpisode,
              launch,
              i,
              streamData.servers[i]
            ),
          onBack: () => {}
        })
        return
      }

      launchPlayer(streamData, episodeNum, capturedMedia, capturedEpisode, launch)
    } catch (error) {
      if (!active() || error?.name === 'AbortError') return
      debug('Default extension auto-play failed:', error)
      fail(error?.message || 'Stream failed', capturedMedia, capturedEpisode)
    }
  }

  onDestroy(stop)
</script>

<SoftModal
  class='m-0 wm-400 rounded bg-very-dark p-30'
  bind:showModal={$modal[modal.DEFAULT_LOADING]}
  {close}
  id={modal.DEFAULT_LOADING}
>
  <div
    class='d-flex flex-column align-items-center justify-content-center py-20'
  >
    <Loader size='3.5rem' class='spinning text-primary mb-20' />
    <h5 class='mb-5 font-weight-bold text-white text-center title-truncate'>
      {anilistClient.title(media)}
    </h5>
    <span class='text-muted font-scale-14 text-center'>Episode {episodeNumber(episode)}</span>
    <span class='text-muted font-scale-14 mt-15'>{statusText}</span>
    <button type='button' class='btn bg-dark-light rounded-2 mt-20 px-20 font-scale-14' use:click={cancel}>Cancel</button>
  </div>
</SoftModal>

<style>
  .title-truncate {
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
    max-width: 100%;
  }
  .px-20 {
    padding-left: 2rem;
    padding-right: 2rem;
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
