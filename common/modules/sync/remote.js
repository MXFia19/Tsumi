import { settings, alToken, malToken } from '@/modules/settings.js'
import { anilistClient } from '@/modules/anilist.js'
import { malClient } from '@/modules/myanimelist.js'
import { VERSION } from '@/modules/bridge.js'
import { SUPPORTS } from '@/modules/support.js'
import { readPosition, withPosition, hasPositionLine } from '@/modules/sync/position.js'
import { setRemotePosition } from '@/modules/sync/store.js'
import Debug from 'debug'
const debug = Debug('ui:sync')

/*
 * Cross-device resume through the note of the list entry: AniList `notes`, MyAnimeList `comments`
 * (format in position.js). Reads keep `remotePositions` (store.js) up to date; every write is a
 * read-modify-write of the current note so the user's own text is never lost.
 */

/** Name written in the note line ("Resume at 12:34 (from PC)" on the other device). */
export const DEVICE_NAME = SUPPORTS.isAndroid ? 'Android' : VERSION?.platform === 'darwin' ? 'Mac' : 'PC'

/** A note read less than this long ago is reused by the next write instead of being read again. */
const READ_REUSE_MS = 20_000

const ENTRY_QUERY = /* js */`
  query($id: Int) {
    Media(id: $id, type: ANIME) {
      id,
      mediaListEntry {
        id,
        status,
        progress,
        notes,
        updatedAt
      }
    }
  }`

const SAVE_NOTES = /* js */`
  mutation($id: Int, $notes: String) {
    SaveMediaListEntry(mediaId: $id, notes: $notes) {
      id,
      notes
    }
  }`

/**
 * Where the note of this media lives: 'anilist', 'mal', or null (setting off, not logged in, TMDB title).
 * @param {any} media
 * @returns {'anilist' | 'mal' | null}
 */
export function noteService (media) {
  if (!settings.value.syncPlaybackPosition || !media || media.isTmdb) return null
  if (alToken?.token && Number.isInteger(media.id)) return 'anilist'
  if (malToken?.token && !malToken.reauth && Number.isInteger(media.idMal)) return 'mal'
  return null
}

/** @typedef {{ exists: boolean, unknown?: boolean, notes?: string, progress?: number, status?: string }} NoteEntry */

/** @type {Map<string, { entry: NoteEntry, at: number }>} */
const lastRead = new Map()
/** @type {Map<string, Promise<any>>} */
const chains = new Map()

/** @param {any} media @param {string} kind */
const keyOf = (media, kind) => `${kind}:${kind === 'mal' ? media.idMal : media.id}`

/**
 * One read-modify-write at a time per entry.
 * @template T
 * @param {string} key
 * @param {() => Promise<T>} task
 * @returns {Promise<T>}
 */
function serial (key, task) {
  const next = (chains.get(key) || Promise.resolve()).catch(() => {}).then(task)
  chains.set(key, next)
  next.finally(() => { if (chains.get(key) === next) chains.delete(key) }).catch(() => {})
  return next
}

/**
 * The list entry of the current account with its note; null when the request failed.
 * `unknown`: the service did not return the note, so it must not be written (it would erase the user's text).
 * @param {any} media
 * @param {'anilist' | 'mal'} kind
 * @returns {Promise<NoteEntry | null>}
 */
async function readEntry (media, kind) {
  /** @type {NoteEntry | null} */
  let entry = null
  if (kind === 'anilist') {
    const res = await anilistClient.alRequest(ENTRY_QUERY, { id: media.id })
    const data = res?.data?.Media
    if (!data) return null
    const listEntry = data.mediaListEntry
    entry = !listEntry
      ? { exists: false }
      : { exists: true, unknown: listEntry.notes !== null && typeof listEntry.notes !== 'string', notes: listEntry.notes || '', progress: listEntry.progress, status: listEntry.status }
  } else {
    const res = await malClient.malRequest({ type: 'GET', path: `anime/${media.idMal}?fields=my_list_status{status,num_episodes_watched,is_rewatching,comments}` })
    if (!res || !res.id) return null
    const status = res.my_list_status
    entry = !status
      ? { exists: false }
      : { exists: true, unknown: typeof status.comments !== 'string', notes: status.comments || '', progress: status.num_episodes_watched, status: status.is_rewatching ? 'REPEATING' : status.status }
  }
  lastRead.set(keyOf(media, kind), { entry, at: Date.now() })
  return entry
}

/**
 * @param {any} media
 * @param {'anilist' | 'mal'} kind
 * @param {string} notes
 */
async function writeNotes (media, kind, notes) {
  if (kind === 'anilist') {
    const res = await anilistClient.alRequest(SAVE_NOTES, { id: media.id, notes })
    return typeof res?.data?.SaveMediaListEntry?.id === 'number'
  }
  const res = await malClient.malRequest({ type: 'PUT', path: `anime/${media.idMal}/my_list_status` }, { comments: notes })
  return !!res?.status
}

/**
 * Reads the position written in the note of `media` (fresh request) and records it in `remotePositions`.
 * @param {any} media
 * @returns {Promise<(NoteEntry & { position: import('./position.js').NotePosition | null }) | null>}
 */
export async function fetchNotePosition (media) {
  const kind = noteService(media)
  if (!kind) return null
  try {
    const entry = await serial(keyOf(media, kind), () => readEntry(media, kind))
    if (!entry) return null
    const position = entry.exists && !entry.unknown ? readPosition(entry.notes) : null
    setRemotePosition(media.id, position && { ...position, source: kind })
    return { ...entry, position }
  } catch (error) {
    debug('Failed to read the note of', media?.id, error)
    return null
  }
}

/**
 * Writes `position` in the note of `media` (replacing the previous Tsumi line), or removes the line when
 * `position` is null. Only for an entry already on the list. Resolves to true when the note is as wanted.
 * @param {any} media
 * @param {import('./position.js').NotePosition | null} position
 * @param {{ upToEpisode?: number }} [options] removal only: keep a line for a later episode (another device moved on)
 */
export function saveNotePosition (media, position, { upToEpisode } = {}) {
  const kind = noteService(media)
  if (!kind) return Promise.resolve(false)
  const key = keyOf(media, kind)
  return serial(key, async () => {
    try {
      const cached = lastRead.get(key)
      const entry = cached && Date.now() - cached.at < READ_REUSE_MS ? cached.entry : await readEntry(media, kind)
      if (!entry?.exists || entry.unknown) return false
      const current = entry.notes || ''
      if (!position) {
        if (!hasPositionLine(current)) return true
        const written = readPosition(current)
        if (written && upToEpisode != null && written.episode > upToEpisode) return true
      }
      const next = withPosition(current, position)
      if (next === current) return true
      const ok = await writeNotes(media, kind, next)
      if (ok) {
        lastRead.set(key, { entry: { ...entry, notes: next }, at: Date.now() })
        setRemotePosition(media.id, position && { ...position, source: kind })
        debug(position ? `Saved the position of episode ${position.episode} in the note of ${media.id}` : `Removed the position from the note of ${media.id}`)
      } else {
        lastRead.delete(key)
      }
      return ok
    } catch (error) {
      lastRead.delete(key)
      debug('Failed to write the note of', media?.id, error)
      return false
    }
  })
}

// The notes come with the user lists (anilist.js asks for them): the positions of every entry are known at
// startup and after each list refresh, so the episode progress bars show them without one request per title.
anilistClient.userLists.subscribe(promise => {
  if (!promise?.then || !settings.value.syncPlaybackPosition) return
  promise.then(res => {
    for (const list of res?.data?.MediaListCollection?.lists || []) {
      for (const { media } of list.entries || []) {
        const entry = media?.mediaListEntry
        // Entries saved by the app carry no notes (SaveMediaListEntry result): keep what is known.
        if (!entry || !('notes' in entry)) continue
        const position = readPosition(entry.notes)
        setRemotePosition(media.id, position && { ...position, source: 'anilist' })
      }
    }
  }).catch(() => {})
})
