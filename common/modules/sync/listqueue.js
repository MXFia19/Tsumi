import { writable } from 'simple-store-svelte'
import { status } from '@/modules/networking.js'
import Helper from '@/modules/helper.js'
import Debug from 'debug'
const debug = Debug('ui:listqueue')

// Pending list updates: episode progress (Helper.updateEntry) that could not be saved, kept until it can be.
// Offline progress is queued without trying; online, an update that failed (network, AniList / MyAnimeList error) or
// had to wait (MyAnimeList list not loaded) is queued too. The queue is sent again when the connection comes back,
// every 10 minutes while it is not empty, and on retryListUpdates(). Entries that can never be applied (TMDB titles,
// unidentified media, episode out of range) are dropped, and an entry still failing after MAX_ATTEMPTS sends too.
//
// API for the UI:
//   pendingListUpdates          store of the pending updates: [{ mediaId, episode, at, attempts, error }]
//                               (count: $pendingListUpdates.length)
//   retryListUpdates()          sends them now; resolves to the number still pending
//   discardListUpdates(mediaId) forgets the updates of a media, or all of them without an argument
//   updateEntryOrQueue(media)   Helper.updateEntry, or queued (what the player calls after an episode)

const QUEUE_KEY = 'tsumi-offline-progress'
const MAX_ATTEMPTS = 10
const RETRY_INTERVAL = 10 * 60 * 1000
/** Results of Helper.updateEntry that leave the update pending. */
const RETRY_STATUSES = ['failed', 'deferred']

function readQueue () {
  try {
    const queue = JSON.parse(localStorage.getItem(QUEUE_KEY))
    return Array.isArray(queue) ? queue.filter(entry => entry && entry.mediaId != null) : []
  } catch {
    return []
  }
}

/** @type {import('simple-store-svelte').Writable<{ mediaId: number, episode: any, media: { id: number }, at: number, attempts?: number, error?: string }[]>} */
export const pendingListUpdates = writable(readQueue())

function writeQueue (queue) {
  try {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(queue))
  } catch (error) {
    debug('Failed to save the pending list updates', error)
  }
  pendingListUpdates.value = queue
}

const isOffline = () => status.value === 'offline' || !navigator.onLine

/** Keeps the update of `filemedia` (replacing older updates of the same media up to that episode). */
function enqueue (filemedia, error) {
  const mediaId = filemedia?.media?.id
  if (!mediaId || typeof mediaId === 'string' || !Helper.isAuthorized()) return
  const queue = readQueue().filter(entry => !(entry.mediaId === mediaId && (Number(entry.episode) || 0) <= (Number(filemedia.episode) || 0)))
  queue.push({ mediaId, episode: filemedia.episode, media: { id: mediaId }, at: Date.now(), attempts: 0, error })
  writeQueue(queue)
  debug('List update queued', mediaId, filemedia.episode, error)
}

/**
 * Helper.updateEntry, or queued when offline or when it could not be saved.
 * @param {{ media: any, episode?: any, failed?: boolean }} filemedia
 */
export async function updateEntryOrQueue (filemedia) {
  if (isOffline()) {
    enqueue(filemedia, 'offline')
    return { status: 'queued' }
  }
  let result
  try {
    result = await Helper.updateEntry(filemedia)
  } catch (error) {
    result = { status: 'failed', reason: error?.message }
  }
  if (RETRY_STATUSES.includes(result?.status)) enqueue(filemedia, result.reason)
  return result
}

let flushing = null

/** Sends the pending updates, oldest first. Resolves to the number still pending. */
async function flushListUpdates () {
  if (isOffline()) return readQueue().length
  for (const entry of readQueue().sort((a, b) => a.at - b.at)) {
    if (isOffline()) break
    const sameEntry = (other) => other.mediaId === entry.mediaId && other.episode === entry.episode && other.at === entry.at
    if (!readQueue().some(sameEntry)) continue // discarded or replaced meanwhile
    let result
    try {
      result = await Helper.updateEntry({ media: entry.media, episode: entry.episode })
    } catch (error) {
      result = { status: 'failed', reason: error?.message }
    }
    const queue = readQueue()
    if (RETRY_STATUSES.includes(result?.status)) {
      const attempts = (entry.attempts || 0) + 1
      if (attempts >= MAX_ATTEMPTS) {
        debug('Dropping a list update that kept failing', entry.mediaId, entry.episode, result.reason)
        writeQueue(queue.filter(other => !sameEntry(other)))
      } else {
        writeQueue(queue.map(other => sameEntry(other) ? { ...other, attempts, error: result.reason } : other))
      }
    } else {
      // Saved, nothing to do, or impossible (TMDB title, media not identified...): done.
      writeQueue(queue.filter(other => !sameEntry(other)))
    }
  }
  return readQueue().length
}

/** Sends the pending list updates now. Resolves to the number still pending. */
export function retryListUpdates () {
  if (!flushing) {
    flushing = flushListUpdates().catch(error => {
      debug('Failed to send the pending list updates', error)
      return readQueue().length
    }).finally(() => { flushing = null })
  }
  return flushing
}

/**
 * Forgets pending list updates.
 * @param {number} [mediaId] only the updates of this media, all of them without it
 */
export function discardListUpdates (mediaId) {
  writeQueue(mediaId == null ? [] : readQueue().filter(entry => entry.mediaId !== mediaId))
}

status.subscribe(value => {
  if (value !== 'offline') setTimeout(retryListUpdates, 5_000)
})
setInterval(() => {
  if (readQueue().length) retryListUpdates()
}, RETRY_INTERVAL)
