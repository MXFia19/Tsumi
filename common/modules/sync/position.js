/*
 * Cross-device resume: the playback position kept in the note of the list entry (AniList `notes`,
 * MyAnimeList `comments`). One line owned by Tsumi, the rest of the note is the user's and is never
 * touched:
 *
 *   [Tsumi] Ep 5 · 12:34 / 23:40 · PC · 2026-11-15T12:00:00Z
 *
 * episode · position / duration · device · time of the write (UTC). The duration part is optional and the
 * parser accepts `|` or `•` as separators too (a note edited by hand, a service that rewrote the dot).
 * No DOM, no app imports: the renderer modules, the Node test (position.test.mjs) and the Swift port
 * (ios-native/Tsumi/Services/PlaybackPositionNote.swift) follow the same rules.
 */

export const LINE_PREFIX = '[Tsumi]'

/** Minimum change of position (seconds) worth a new write of the same episode. */
export const MIN_POSITION_CHANGE = 5
/** Positions before this (seconds) are not written: opening an episode must not erase the position of another device. */
export const MIN_WRITE_TIME = 30
/** A remote position must differ by more than this (seconds) from the local one to be offered. */
export const OFFER_MIN_DIFFERENCE = 15
/** ... and be newer than the local one by more than this (ms), clocks of two devices are never exact. */
export const OFFER_MIN_AGE_DIFFERENCE = 5_000
/** Periodic write while playing. */
export const PERIODIC_WRITE_MS = 2 * 60_000
/** Write after a pause (cancelled when playback resumes before). */
export const PAUSE_WRITE_DELAY_MS = 3_000
/** Longest position or duration read or written (99:59:59): a note edited by hand can hold any number of hours. */
export const MAX_CLOCK = 99 * 3600 + 59 * 60 + 59

const SEP = '\\s*[·|•]\\s*'
const CLOCK = '((?:\\d+:)?\\d{1,2}:\\d{2})'
const ISO = '(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?Z)'
const LINE_RX = new RegExp(`^\\s*\\[Tsumi\\]\\s*Ep\\s*(\\d+)${SEP}${CLOCK}(?:\\s*/\\s*${CLOCK})?${SEP}(.*?)${SEP}${ISO}\\s*$`, 'i')
const OURS_RX = /^\s*\[Tsumi\]/i

/**
 * 754 → "12:34", 3723 → "1:02:03".
 * @param {number} seconds
 */
export function formatClock (seconds) {
  const value = Number(seconds)
  const total = Number.isFinite(value) ? Math.floor(Math.min(Math.max(0, value), MAX_CLOCK)) : 0
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  const mm = hours ? String(minutes).padStart(2, '0') : String(minutes)
  return `${hours ? hours + ':' : ''}${mm}:${String(secs).padStart(2, '0')}`
}

/**
 * "12:34" → 754, "1:02:03" → 3723, NaN when unreadable.
 * @param {string} text
 */
export function parseClock (text) {
  if (typeof text !== 'string' || !/^\d+(:\d{1,2}){1,2}$/.test(text.trim())) return NaN
  const total = text.trim().split(':').reduce((sum, part) => sum * 60 + Number(part), 0)
  return total <= MAX_CLOCK ? total : NaN // more than 99:59:59 (huge hour counts typed by hand): rejected
}

/**
 * Device name as written in the line: no separator, no line break, 24 characters at most.
 * @param {string} name
 */
export function cleanDevice (name) {
  const cleaned = String(name || '').replace(/[\r\n·|•]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 24)
  return cleaned || 'Unknown'
}

/** @param {number} time ms */
function isoSeconds (time) {
  return new Date(Math.floor(time / 1000) * 1000).toISOString().replace('.000Z', 'Z')
}

/**
 * @typedef {{ episode: number, time: number, duration?: number, device: string, at: number }} NotePosition
 * `time` / `duration` in seconds, `at` in ms since the epoch.
 */

/**
 * @param {NotePosition} position
 * @returns {string}
 */
export function formatLine ({ episode, time, duration, device, at }) {
  const clock = formatClock(time) + (duration > 0 ? ` / ${formatClock(duration)}` : '')
  return `${LINE_PREFIX} Ep ${Math.max(0, Math.floor(Number(episode) || 0))} · ${clock} · ${cleanDevice(device)} · ${isoSeconds(at || Date.now())}`
}

/**
 * Reads one line; null when it is not a (valid) Tsumi line.
 * @param {string} line
 * @returns {NotePosition | null}
 */
export function parseLine (line) {
  const match = LINE_RX.exec(String(line || ''))
  if (!match) return null
  const [, episode, time, duration, device, iso] = match
  const at = Date.parse(iso)
  const seconds = parseClock(time)
  if (!Number.isFinite(at) || !Number.isFinite(seconds)) return null
  const total = duration ? parseClock(duration) : NaN
  return {
    episode: Number(episode),
    time: seconds,
    ...(Number.isFinite(total) && total > 0 ? { duration: total } : {}),
    device: device.trim() || 'Unknown',
    at
  }
}

/** @param {string} notes */
function lines (notes) {
  return String(notes || '').split(/\r?\n/)
}

/**
 * The position written in a note (the newest valid line when someone left several), null without one.
 * @param {string | null | undefined} notes
 * @returns {NotePosition | null}
 */
export function readPosition (notes) {
  let found = null
  for (const line of lines(notes)) {
    const position = parseLine(line)
    if (position && (!found || position.at > found.at)) found = position
  }
  return found
}

/**
 * Whether the note has a Tsumi line (valid or not).
 * @param {string | null | undefined} notes
 */
export function hasPositionLine (notes) {
  return lines(notes).some(line => OURS_RX.test(line))
}

/**
 * The user's part of the note: every Tsumi line removed (valid or not), trailing blank lines trimmed.
 * @param {string | null | undefined} notes
 */
export function stripPosition (notes) {
  return lines(notes).filter(line => !OURS_RX.test(line)).join('\n').replace(/\s+$/, '')
}

/**
 * The note with our line replaced (or added at the end); `position` null removes it.
 * @param {string | null | undefined} notes
 * @param {NotePosition | null} position
 */
export function withPosition (notes, position) {
  const user = stripPosition(notes)
  if (!position) return user
  const line = formatLine(position)
  return user ? `${user}\n${line}` : line
}

/**
 * Whether the user should be offered the remote position of `episode` instead of the local one.
 * @param {NotePosition | null | undefined} remote
 * @param {{ currentTime?: number, updatedAt?: number } | null | undefined} local record of the local progress store
 * @param {number} episode
 */
export function shouldOffer (remote, local, episode) {
  if (!remote || Number(remote.episode) !== Number(episode)) return false
  if (!(remote.time > 0)) return false
  if (local?.updatedAt && remote.at <= local.updatedAt + OFFER_MIN_AGE_DIFFERENCE) return false
  return Math.abs(remote.time - (local?.currentTime || 0)) > OFFER_MIN_DIFFERENCE
}

/**
 * Whether a new write is needed: another episode, or a position that moved enough.
 * @param {{ episode: number, time: number } | null | undefined} last last position written (or read)
 * @param {{ episode: number, time: number }} next
 */
export function needsWrite (last, next) {
  if (!last) return true
  if (Number(last.episode) !== Number(next.episode)) return true
  return Math.abs((last.time || 0) - (next.time || 0)) >= MIN_POSITION_CHANGE
}

/**
 * "12:34" when the duration is known, "53%" otherwise (Trakt only stores a percentage).
 * @param {{ time?: number, percent?: number }} position
 */
export function positionLabel ({ time, percent }) {
  if (time > 0) return formatClock(time)
  if (percent > 0) return `${Math.round(Math.min(percent, 100))}%`
  return '0:00'
}
