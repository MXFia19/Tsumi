// Rules of the list update queue (sync/listqueue.js): which account an update belongs to, which stored updates are
// kept, and what a send result does to an update. Pure module (no app imports), tested by pendingupdates.test.mjs.

/** Failed sends after which an update is given up (iOS: 5, but it retries at launch and on reconnection only). */
export const MAX_ATTEMPTS = 10

/** Results of Helper.updateEntry that leave the update pending: not saved, or MyAnimeList list unknown. */
export const RETRY_STATUSES = ['failed', 'deferred']

/**
 * Account of a viewer: "anilist:<id>" or "mal:<id>" (the ids of the two services can collide), null when unknown.
 * @param {'anilist' | 'mal'} service
 * @param {number | string} [viewerId]
 */
export function accountKey (service, viewerId) {
  return service && viewerId != null && viewerId !== '' ? `${service}:${viewerId}` : null
}

/**
 * Account of a stored profile ({ viewer, token... }): AniList viewers have an avatar, MyAnimeList ones a picture
 * (the same test as Helper.syncProgress and setViewer).
 */
export function profileAccount (profile) {
  const viewer = profile?.viewer?.data?.Viewer
  return accountKey(viewer?.avatar ? 'anilist' : 'mal', viewer?.id)
}

/**
 * Stored updates that are kept: valid entries of the signed-in accounts (`known`: the current one and the other
 * profiles). Entries of an account that was logged out are dropped, never sent to another account. Entries of older
 * versions (no account) are given to the current account, the one they were most likely made on.
 * @param {any} stored parsed storage value
 * @param {string | null} current account of the current profile
 * @param {(string | null)[]} known accounts still signed in
 */
export function keptUpdates (stored, current, known) {
  if (!Array.isArray(stored)) return []
  const signedIn = new Set(known.filter(Boolean))
  const kept = []
  for (const entry of stored) {
    if (!entry || entry.mediaId == null) continue
    const account = entry.account || current
    if (account && signedIn.has(account)) kept.push(entry.account ? entry : { ...entry, account })
  }
  return kept
}

/** Same pending update (account, media, episode and time it was queued). */
export function sameUpdate (a, b) {
  return a.account === b.account && a.mediaId === b.mediaId && a.episode === b.episode && a.at === b.at
}

/**
 * The queue with `update` added: older updates of the same media and account up to that episode are replaced.
 * @param {any[]} queue
 * @param {{ account: string, mediaId: number, episode: any }} update
 */
export function withUpdate (queue, update) {
  const episode = Number(update.episode) || 0
  return [...queue.filter(entry => !(entry.account === update.account && entry.mediaId === update.mediaId && (Number(entry.episode) || 0) <= episode)), update]
}

/** Updates of an account, oldest first. */
export function accountUpdates (queue, account) {
  return account ? queue.filter(entry => entry.account === account).sort((a, b) => a.at - b.at) : []
}

/**
 * What a send result does to a pending update.
 * - `done`: saved, nothing to change, or it can never be saved (TMDB title, unidentified media...): removed.
 * - `retry`: kept with `attempts`; the later updates wait so that they are still sent in order (like iOS).
 * - `drop`: failed {@link MAX_ATTEMPTS} times: removed (the caller tells the user).
 * During an outage (`outage`: no network, or AniList down: status 'offline' / 'offline_anilist') a failure is not
 * counted: an outage of a few hours used to use up the attempts and lose the progress.
 * @param {{ attempts?: number }} entry
 * @param {{ status?: string } | null | undefined} result Helper.updateEntry result
 * @param {{ outage?: boolean, maxAttempts?: number }} [options]
 * @returns {{ action: 'done' | 'retry' | 'drop', attempts: number }}
 */
export function sendOutcome (entry, result, { outage = false, maxAttempts = MAX_ATTEMPTS } = {}) {
  const attempts = Number(entry?.attempts) || 0
  if (!RETRY_STATUSES.includes(result?.status)) return { action: 'done', attempts }
  if (outage) return { action: 'retry', attempts }
  if (attempts + 1 >= maxAttempts) return { action: 'drop', attempts: attempts + 1 }
  return { action: 'retry', attempts: attempts + 1 }
}

/** True while the network or AniList is down (networking.js status: 'offline', 'offline_anilist'). */
export function isOutage (status) {
  return /offline/i.test(String(status || ''))
}
