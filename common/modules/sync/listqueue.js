import { writable } from 'simple-store-svelte'
import { toast } from 'svelte-sonner'
import { status } from '@/modules/networking.js'
import { alToken, malToken, profiles, settings } from '@/modules/settings.js'
import { mediaCache } from '@/modules/cache.js'
import { isAniListTokenUsable } from '@/modules/auth/expiry.js'
import Helper from '@/modules/helper.js'
import { accountKey, profileAccount, keptUpdates, sameUpdate, withUpdate, accountUpdates, sendOutcome, isOutage, RETRY_STATUSES } from '@/modules/sync/pendingupdates.js'
import Debug from 'debug'
const debug = Debug('ui:listqueue')

// Pending list updates: episode progress (Helper.updateEntry) that could not be saved, kept until it can be.
// Offline progress is queued without trying; online, an update that failed (network, AniList / MyAnimeList error) or
// had to wait (MyAnimeList list not loaded) is queued too. The queue is sent again when the connection comes back,
// every 10 minutes while it is not empty, and on retryListUpdates(). Entries that can never be applied (TMDB titles,
// unidentified media, episode out of range) are dropped, and an entry still failing after MAX_ATTEMPTS sends too
// (with an error toast); failures during an outage (no network, AniList down) are not counted. The updates are sent
// oldest first and a failure stops the send, so that they stay in order (like iOS DownloadProgressQueue).
//
// Each update belongs to the account it was made on (service + viewer id): only the current account's updates are
// sent (a profile switch never writes them to another list), the other signed-in profiles keep theirs until they are
// the current one again, and the updates of a profile that was logged out are deleted. Rules: sync/pendingupdates.js.
//
// API for the UI (current account only):
//   pendingListUpdates          store of the pending updates, oldest first:
//                               [{ mediaId, episode, title, at, attempts, error, account, media }]
//                               (count: $pendingListUpdates.length)
//   retryListUpdates()          sends them now; resolves to the number still pending
//   discardListUpdates(mediaId) forgets the updates of a media, or all of them without an argument
//   updateEntryOrQueue(media)   Helper.updateEntry, or queued (what the player calls after an episode)

const QUEUE_KEY = 'tsumi-offline-progress'
const RETRY_INTERVAL = 10 * 60 * 1000

/** Account of the current profile ("anilist:<id>" / "mal:<id>"), null when signed out. */
function currentAccount () {
  return accountKey(alToken ? 'anilist' : 'mal', (alToken || malToken)?.viewer?.data?.Viewer?.id)
}

/** Accounts still signed in: the current profile and the other profiles. */
function knownAccounts () {
  return [currentAccount(), ...(profiles.value || []).map(profileAccount)]
}

/** False while the current session has expired (log in again): its updates wait instead of failing. */
function sessionUsable () {
  if (alToken) return isAniListTokenUsable(alToken.token)
  return !!malToken && !malToken.reauth
}

/** Every kept update (all signed-in accounts), see keptUpdates. */
function readQueue () {
  let stored = null
  try {
    stored = JSON.parse(localStorage.getItem(QUEUE_KEY))
  } catch {}
  return keptUpdates(stored, currentAccount(), knownAccounts())
}

/** @type {import('simple-store-svelte').Writable<{ mediaId: number, episode: any, title?: string, at: number, attempts?: number, error?: string, account: string, media: { id: number } }[]>} */
export const pendingListUpdates = writable(accountUpdates(readQueue(), currentAccount()))

function writeQueue (queue) {
  try {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(queue))
  } catch (error) {
    debug('Failed to save the pending list updates', error)
  }
  pendingListUpdates.value = accountUpdates(queue, currentAccount())
}

const isOffline = () => status.value === 'offline' || !navigator.onLine

/** Keeps the update of `filemedia` (replacing older updates of the same media up to that episode). */
function enqueue (filemedia, error) {
  const mediaId = filemedia?.media?.id
  const account = currentAccount()
  if (!mediaId || typeof mediaId === 'string' || !account) return
  const title = filemedia.media.title?.userPreferred || mediaCache?.value?.[mediaId]?.title?.userPreferred
  writeQueue(withUpdate(readQueue(), { account, mediaId, episode: filemedia.episode, title, media: { id: mediaId }, at: Date.now(), attempts: 0, error }))
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

/** An update given up after too many failed sends: the progress was not saved, the user is told. */
function notifyDropped (entry, reason) {
  const title = mediaCache?.value?.[entry.mediaId]?.title?.userPreferred || entry.title || 'A title'
  debug('Dropping a list update that kept failing', entry.mediaId, entry.episode, reason)
  if (settings.value.toasts.includes('All') || settings.value.toasts.includes('Errors')) {
    toast.error('Failed to Update Progress', {
      description: `${title}: episode ${entry.episode} could not be saved to your list${reason ? ` (${reason})` : ''}.`,
      duration: 9000
    })
  }
}

let flushing = null

/** Sends the pending updates of the current account, oldest first. Resolves to the number still pending. */
async function flushListUpdates () {
  const account = currentAccount()
  if (isOffline() || !account || !sessionUsable()) return accountUpdates(readQueue(), account).length
  for (const entry of accountUpdates(readQueue(), account)) {
    if (isOffline() || currentAccount() !== account) break
    if (!readQueue().some(other => sameUpdate(other, entry))) continue // discarded or replaced meanwhile
    const outageBefore = isOutage(status.value)
    let result
    try {
      result = await Helper.updateEntry({ media: entry.media, episode: entry.episode })
    } catch (error) {
      result = { status: 'failed', reason: error?.message }
    }
    const { action, attempts } = sendOutcome(entry, result, { outage: outageBefore || isOutage(status.value) || isOffline() })
    const queue = readQueue()
    if (action === 'retry') {
      writeQueue(queue.map(other => sameUpdate(other, entry) ? { ...other, attempts, error: result?.reason } : other))
      break // the later updates wait, so that they are still sent in order
    }
    // Saved, nothing to do, impossible (TMDB title, media not identified...), or given up.
    writeQueue(queue.filter(other => !sameUpdate(other, entry)))
    if (action === 'drop') notifyDropped(entry, result?.reason)
  }
  return accountUpdates(readQueue(), account).length
}

/** Sends the pending list updates now. Resolves to the number still pending. */
export function retryListUpdates () {
  if (!flushing) {
    flushing = flushListUpdates().catch(error => {
      debug('Failed to send the pending list updates', error)
      return pendingListUpdates.value.length
    }).finally(() => { flushing = null })
  }
  return flushing
}

/**
 * Forgets pending list updates of the current account.
 * @param {number} [mediaId] only the updates of this media, all of them without it
 */
export function discardListUpdates (mediaId) {
  const account = currentAccount()
  writeQueue(readQueue().filter(entry => entry.account !== account || (mediaId != null && entry.mediaId !== mediaId)))
}

// Saves the kept updates whenever the profiles change, and at startup: the updates of a profile that was logged out
// or removed are deleted (logging the current profile out reloads the app).
profiles.subscribe(() => writeQueue(readQueue()))
status.subscribe(value => {
  if (!isOutage(value)) setTimeout(retryListUpdates, 5_000)
})
setInterval(() => {
  if (pendingListUpdates.value.length) retryListUpdates()
}, RETRY_INTERVAL)
