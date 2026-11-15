<script>
  import { click } from '@/modules/click.js'
  import { playAnime } from '@/modals/extension/ExtensionModal.svelte'
  import { getAnimeProgress, setAnimeProgress } from '@/modules/anime/animeprogress.js'
  import { durationMap } from '@/modules/anime/anime.js'
  import { tmdbClient } from '@/modules/tmdb.js'
  import { fetchNotePosition, noteService } from '@/modules/sync/remote.js'
  import { traktStatus, getTraktPlayback, tmdbIdOf, tmdbAbsoluteOf } from '@/modules/sync/trakt.js'
  import { requestResume } from '@/modules/sync/session.js'
  import { setRemotePosition } from '@/modules/sync/store.js'
  import { positionLabel, OFFER_MIN_AGE_DIFFERENCE, OFFER_MIN_DIFFERENCE } from '@/modules/sync/position.js'
  import { History } from 'lucide-svelte'

  /*
   * "Resume Episode 5 at 12:34 (from iPhone)" under the play button of the details: the position written in the
   * note of the list entry (anime) or the Trakt playback progress (shows and movies), when it is newer than what
   * this device played.
   */

  export let media

  /** @type {{ episode: number, time?: number, percent?: number, duration?: number, device: string, at: number, season?: number, number?: number } | null} */
  let offer = null
  let request = 0

  $: load(media, $traktStatus.state)

  /** @param {any} media */
  async function load (media) {
    const ticket = ++request
    const id = media?.id
    if (!id) {
      offer = null
      return
    }
    if (offer && offer.mediaId !== id) offer = null
    let found = null
    try {
      found = media.isTmdb ? await fromTrakt(media) : await fromNote(media)
    } catch {}
    if (ticket !== request) return
    offer = found && isNewer(found, getAnimeProgress({ mediaId: id, episode: found.episode })) ? { ...found, mediaId: id } : null
  }

  /** @param {any} media */
  async function fromNote (media) {
    if (!noteService(media)) return null
    const res = await fetchNotePosition(media)
    const position = res?.position
    // An earlier episode than the list progress was already watched (the line stays only when a removal failed).
    if (!position || position.episode < (res.progress || 0)) return null
    return position
  }

  /** @param {any} media */
  async function fromTrakt (media) {
    const tmdbId = tmdbIdOf(media)
    if (!tmdbId || $traktStatus.state !== 'connected') return null
    const isMovie = media.format === 'MOVIE'
    const item = (await getTraktPlayback()).find(entry => isMovie
      ? entry.type === 'movie' && String(entry.movie?.ids?.tmdb) === String(tmdbId)
      : entry.type === 'episode' && String(entry.show?.ids?.tmdb) === String(tmdbId))
    if (!item || !(item.progress > 0)) return null
    let episode = 1
    let minutes = 0
    let season
    let number
    if (isMovie) {
      minutes = (await tmdbClient.getDetails(tmdbId, 'movie'))?.runtime || 0
    } else {
      const found = await tmdbAbsoluteOf(tmdbId, item.episode?.season, item.episode?.number)
      if (!found) return null
      episode = found.episode
      minutes = found.length || 0
      season = item.episode.season
      number = item.episode.number
    }
    const duration = minutes * 60
    const position = { episode, percent: item.progress, time: duration ? item.progress / 100 * duration : undefined, duration: duration || undefined, device: 'Trakt', at: Date.parse(item.paused_at) }
    setRemotePosition(media.id, { ...position, source: 'trakt' })
    return { ...position, season, number }
  }

  /**
   * @param {{ time?: number, percent?: number, at: number }} remote
   * @param {any} local
   */
  function isNewer (remote, local) {
    if (!local) return (remote.time || 0) > 0 || (remote.percent || 0) > 0
    if (local.updatedAt && remote.at <= local.updatedAt + OFFER_MIN_AGE_DIFFERENCE) return false
    if (remote.time > 0) return Math.abs(remote.time - local.currentTime) > OFFER_MIN_DIFFERENCE
    const localPercent = local.safeduration ? local.currentTime / local.safeduration * 100 : 0
    return Math.abs((remote.percent || 0) - localPercent) > 2
  }

  function resume () {
    const target = offer
    if (!target || !media) return
    // The player resumes the local position: make it this one (the percentage of Trakt is applied exactly once
    // the real duration is known, see modules/sync/session.js).
    const safeduration = target.duration || ((media.duration || durationMap[media.format] || 24) * 60)
    const currentTime = target.time > 0 ? target.time : (target.percent || 0) / 100 * safeduration
    if (currentTime > 0) setAnimeProgress({ mediaId: media.id, episode: target.episode, currentTime, safeduration })
    requestResume({ mediaId: media.id, episode: target.episode, ...(target.device === 'Trakt' ? { percent: target.percent } : { time: target.time }) })
    offer = null
    playAnime(media, target.season != null ? { number: target.episode, season: target.season, localEpisode: target.number } : target.episode)
  }

  $: label = labelOf(offer, media)

  /**
   * @param {typeof offer} offer
   * @param {any} media
   */
  function labelOf (offer, media) {
    if (!offer) return ''
    if (media?.format === 'MOVIE') return 'Resume'
    if (offer.season != null) return `Resume S${offer.season}E${offer.number}`
    return `Resume Episode ${offer.episode}`
  }
</script>

{#if offer}
  <button type='button' class='btn btn-lg bg-dark-light shadow-none border-0 d-flex align-items-center mt-10 mw-full' use:click={resume} title='Played more recently on {offer.device === 'Trakt' ? 'another device (Trakt)' : offer.device}'>
    <History class='mr-10 flex-shrink-0' size='1.8rem' />
    <span class='text-truncate'>{label} at {positionLabel(offer.device === 'Trakt' ? { percent: offer.percent } : offer)} <span class='text-muted'>(from {offer.device})</span></span>
  </button>
{/if}
