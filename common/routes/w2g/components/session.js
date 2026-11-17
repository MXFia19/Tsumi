import { EventEmitter } from 'events'
import { writable } from 'simple-store-svelte'

/*
 * Shared Watch Together state, kept in a plain module so the player and the
 * extension modals can use it without importing WatchTogetherPage.svelte
 * (which would create an import cycle).
 */

/** Player <-> lobby events: 'player', 'index' (from the player) and 'playerupdate', 'setindex' (to the player). */
export const w2gEmitter = new EventEmitter()

/** @type {import('simple-store-svelte').Writable<import('./w2g.js').W2GClient | null>} */
export const state = writable(null)

// Only what another participant needs to start the same title with their own extension.
const SHARED_MEDIA_FIELDS = ['id', 'idMal', 'idTmdb', 'isTmdb', 'format', 'episodes', 'status', 'title', 'coverImage', 'bannerImage', 'season', 'seasonYear', 'duration', 'averageScore', 'genres']

function pickMedia (media) {
  return Object.fromEntries(SHARED_MEDIA_FIELDS.filter(field => media[field] !== undefined).map(field => [field, media[field]]))
}

/**
 * Tells the lobby (if any) which title/episode was just started locally.
 * @param {object} media Tsumi media object
 * @param {number | { number: number, season?: number, localEpisode?: number }} episode
 */
export function shareNowPlaying (media, episode) {
  // A module result opened as it is (sora/resultpage.js) only exists for this user's module: nothing to share.
  if (!media?.id || media.isSora || !state.value) return
  state.value.shareMedia({ media: pickMedia(media), episode })
}

/**
 * v2.4 "Add to Watch Together queue" (episode list, details page).
 * @param {object} media Tsumi media object
 * @param {number | { number: number, season?: number, localEpisode?: number }} episode
 * @param {string} [title] display title in the user's language
 * @returns {'added' | 'suggested' | 'duplicate' | null} null when not in a lobby with a queue
 */
export function queueEpisode (media, episode, title) {
  if (!media?.id || !state.value) return null
  const cover = media.coverImage?.medium || media.coverImage?.extraLarge || media.coverImage?.large || ''
  return state.value.addToQueue({ media: pickMedia(media), episode, title, cover })
}

/** Toast text for the result of queueEpisode / addNextEpisode. */
export function queueResultText (result) {
  if (result === 'added') return 'Added to Up next'
  if (result === 'suggested') return 'Suggested to the host'
  if (result === 'duplicate') return 'Already in Up next'
  return 'The lobby has no queue'
}
