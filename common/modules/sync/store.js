import { writable } from 'simple-store-svelte'

/*
 * Positions written by another device, by media id (cross-device resume):
 * { episode, time?, duration?, percent?, device, at, source: 'anilist' | 'mal' | 'trakt' }
 * `time` / `duration` in seconds, `percent` 0-100 (Trakt only stores a percentage), `at` in ms.
 * No app imports: animeprogress.js reads it to show these positions on the episode progress bars.
 */
export const remotePositions = writable({})

/**
 * @param {string | number} mediaId
 * @param {object | null} position null forgets the media
 */
export function setRemotePosition (mediaId, position) {
  if (mediaId == null) return
  const current = remotePositions.value
  const previous = current[mediaId]
  if (!position && !previous) return
  if (position && previous && JSON.stringify(previous) === JSON.stringify(position)) return
  const next = { ...current }
  if (position) next[mediaId] = position
  else delete next[mediaId]
  remotePositions.value = next
}

/**
 * Watched percentage (0-100) of a remote position, 0 when unknown.
 * @param {{ time?: number, duration?: number, percent?: number } | null | undefined} position
 */
export function remotePercent (position) {
  if (!position) return 0
  if (position.duration > 0 && position.time >= 0) return Math.min(100, Math.ceil(position.time / position.duration * 100))
  if (position.percent > 0) return Math.min(100, Math.ceil(position.percent))
  return 0
}
