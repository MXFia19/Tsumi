// Pure helpers of the PC player (routes/player/PlayerPage.svelte) and of MediaHandler.svelte: resume position,
// subtitle offset, end-credit chapters ("Up next"), HLS quality labels, merged episodes. No imports, tested by
// playerstate.test.mjs.

/** Chapter names the player knows (skip button, auto-skip, "Up next"), from the chapter text. */
export const CHAPTER_KINDS = [
  ['Intro', /^intro$/im],
  ['Opening', /^op$|opening$|title$|^ncop/im],
  ['Outro', /^outro$/im],
  ['Ending', /^ed$|ending$|^nced/im],
  ['Credits', /credits/i],
  ['Preview', /^preview$|previews$|pv$|next$/im],
  ['Recap', /recap/im]
]

/** Chapters that close an episode: "Up next" shows while one of them plays. */
export const END_CHAPTER_KINDS = ['Credits', 'Preview', 'Ending', 'Outro']

/** @param {string} [text] chapter text -> its kind ('Intro', 'Credits'...), null for a content chapter */
export function chapterKind (text) {
  const value = String(text ?? '').trim()
  if (!value) return null
  for (const [name, regex] of CHAPTER_KINDS) {
    if (regex.test(value)) return name
  }
  return null
}

/** Episodes shorter than this are never offered a resume. */
export const MIN_RESUME_S = 10
/** The player resumes a little before the saved position. */
export const RESUME_REWIND_S = 5

/**
 * Where to resume an episode from its saved progress, or null to start it from the beginning: nothing saved, less
 * than 10 s watched, or already past the completion threshold (a finished episode starts over instead of jumping to
 * its last seconds and to the next episode). The threshold is clamped to 50-97 % (same as the iPhone player).
 * @param {{ currentTime?: number, safeduration?: number } | null | undefined} progress saved by animeprogress.js
 * @param {{ threshold?: number, duration?: number }} [options] threshold in percent (playerAutocompleteThreshold),
 *   duration of the loaded video in seconds when known
 * @returns {number | null} seconds
 */
export function resumePosition (progress, { threshold = 85, duration } = {}) {
  const time = Number(progress?.currentTime)
  if (!Number.isFinite(time) || time < MIN_RESUME_S) return null
  const length = Number.isFinite(Number(duration)) && Number(duration) > 0 ? Number(duration) : Number(progress?.safeduration)
  const ratio = Math.min(Math.max(Number(threshold) || 85, 50), 97) / 100
  if (length > 0 && time >= length * ratio) return null
  if (length > 0 && time >= length) return null
  return Math.max(time - RESUME_REWIND_S, 0)
}

/**
 * Subtitle offset typed by the user, in seconds: "1.5", "1,5", "-0,25", "+2". An empty field is 0, an unreadable or
 * unfinished one ("-", "abc") is null (keep the previous value).
 * @param {unknown} value
 * @returns {number | null}
 */
export function parseSubtitleOffset (value) {
  const text = String(value ?? '').trim().replace(',', '.')
  if (!text) return 0
  if (!/^[+-]?(\d+\.?\d*|\.\d+)$/.test(text)) return null
  const number = Math.round(Number(text) * 1000) / 1000
  if (!Number.isFinite(number)) return null
  return Math.max(-3600, Math.min(3600, number))
}

/** Shows whose subtitle offset is remembered (the oldest are forgotten, same as the iPhone player). */
export const MAX_REMEMBERED_OFFSETS = 200

/**
 * Remembered subtitle offsets ({ [show]: { offset, at } }) after setting `offset` for `key`: 0 forgets the show, and
 * only the most recently set MAX_REMEMBERED_OFFSETS shows are kept.
 * @param {Record<string, any> | null | undefined} entries
 * @param {string} key
 * @param {number} offset seconds
 * @param {number} [now]
 */
export function rememberOffset (entries, key, offset, now = Date.now(), max = MAX_REMEMBERED_OFFSETS) {
  const next = { ...(entries && typeof entries === 'object' ? entries : {}) }
  if (offset) next[key] = { offset, at: now }
  else delete next[key]
  const keys = Object.keys(next)
  if (keys.length > max) {
    keys.sort((a, b) => (Number(next[a]?.at) || 0) - (Number(next[b]?.at) || 0))
    for (const old of keys.slice(0, keys.length - max)) delete next[old]
  }
  return next
}

/**
 * Subtitle URL of an extension stream response: a string, or the first usable entry of an array / object
 * ({ url | file | src }). Only http(s), data: and blob: URLs. Null when there is none.
 * @param {unknown} subtitle
 * @returns {string | null}
 */
export function subtitleUrlOf (subtitle) {
  if (!subtitle) return null
  if (typeof subtitle === 'string') return /^(https?:\/\/|data:|blob:)/i.test(subtitle.trim()) ? subtitle.trim() : null
  if (Array.isArray(subtitle)) {
    for (const entry of subtitle) {
      const url = subtitleUrlOf(entry)
      if (url) return url
    }
    return null
  }
  if (typeof subtitle === 'object') {
    const entry = /** @type {any} */ (subtitle)
    return subtitleUrlOf(entry.url || entry.file || entry.src || null)
  }
  return null
}

/**
 * "Up next" applies at `time`: the chapter playing then and every chapter after it close the episode (credits,
 * preview, ending), and that chapter starts in the second half of the video.
 * @param {{ start: number, end: number, text?: string }[]} chapters milliseconds
 * @param {number} time seconds
 * @param {number} duration seconds
 */
export function inEndChapters (chapters, time, duration) {
  if (!Array.isArray(chapters) || !chapters.length || !(duration > 0) || !Number.isFinite(time)) return false
  const index = chapters.findIndex(chapter => time >= chapter.start / 1000 && time < chapter.end / 1000)
  if (index === -1) return false
  if (chapters[index].start / 1000 < duration / 2) return false
  return chapters.slice(index).every(chapter => END_CHAPTER_KINDS.includes(chapterKind(chapter.text)))
}

/**
 * Whole seconds the "Up next" card shows before the next episode starts. The countdown follows the video (as on the
 * iPhone): it waits while paused or buffering and runs faster at a higher speed. It never shows more than what is left
 * of the episode (autoplay takes over at its end).
 * @param {number} startsAt video time (s) the next episode starts at
 * @param {number} time video time (s)
 * @param {number} [duration] length of the episode (s)
 */
export function upNextRemaining (startsAt, time, duration) {
  const end = Number(duration) > 0 ? Math.min(startsAt, Number(duration)) : startsAt
  const left = end - time
  return Number.isFinite(left) ? Math.max(0, Math.ceil(left)) : 0
}

/**
 * Quality menu entries of hls.js levels, best first: "1080p", "720p"... (bitrate when two levels share a height or
 * when the height is unknown).
 * @param {{ height?: number, bitrate?: number }[]} levels
 * @returns {{ index: number, label: string }[]}
 */
export function hlsLevelOptions (levels) {
  if (!Array.isArray(levels)) return []
  const kbps = (level) => `${Math.round((Number(level?.bitrate) || 0) / 1000)} kbps`
  const options = levels.map((level, index) => ({ index, height: Number(level?.height) || 0, bitrate: Number(level?.bitrate) || 0, level }))
  options.sort((a, b) => b.height - a.height || b.bitrate - a.bitrate)
  const counts = {}
  for (const option of options) counts[option.height] = (counts[option.height] || 0) + 1
  return options.map(({ index, height, level }) => ({
    index,
    label: !height ? kbps(level) : counts[height] > 1 ? `${height}p (${kbps(level)})` : `${height}p`
  }))
}

/**
 * Several episodes merged in one video file: the range of episodes a video of `duration` seconds holds when one
 * episode lasts `episodeMinutes`, null when it is a single (even long) episode.
 * @param {number} duration seconds
 * @param {number} episodeMinutes
 * @param {number} episode episode number of the file
 * @returns {{ first: number, last: number } | null}
 */
export function episodeRangeOf (duration, episodeMinutes, episode) {
  const length = Number(episodeMinutes) * 60
  if (!(duration > 120) || !(length > 0) || !(Number(episode) > 0)) return null
  if (duration <= length + 360) return null // 6 minutes of margin
  const multiplier = Math.round(duration / length)
  if (multiplier < 2) return null
  return { first: episode * multiplier - (multiplier - 1), last: episode * multiplier }
}

/**
 * TMDB shows and movies (TheMovieDB ids are strings "tmdb-..." or carry isTmdb): their episodes are never merged
 * files, and their runtime is only an average.
 * @param {any} media
 */
export function isTmdbMedia (media) {
  return !!(media?.isTmdb || (typeof media?.id === 'string' && media.id.startsWith('tmdb-')))
}
