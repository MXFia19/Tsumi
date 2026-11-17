// Entries of the schedule page (routes/SchedulePage.svelte): AniList anime, TMDB shows and TMDB movies merged into
// one list sorted by time, page after page. Pure helpers, tested by listing.test.mjs. iOS: ScheduleView.swift (days,
// loadMore).

/** One entry per show or movie: TMDB shows and movies have separate id spaces. */
export function scheduleKey (media) {
  return `${media?.format}:${media?.id}`
}

/**
 * The entries of one page of the schedule, sorted by time. Left out: the entries already listed by an earlier page of
 * the same load (`seen`, filled here: the pages of the TMDB shows and movies overlap), those of an excluded format
 * (AniList only filters the anime: excluding Movie or TV Show also hides the TMDB movies and shows, like iOS), and
 * those with nothing to come.
 * @template T
 * @param {T[]} media
 * @param {{ time: (media: T) => number | null, seen?: Set<string>, formatNot?: string[] }} options
 *   time: of the next airing or release (ms), null when nothing is to come
 * @returns {T[]}
 */
export function schedulePageEntries (media, { time, seen = new Set(), formatNot = [] }) {
  const excluded = new Set(Array.isArray(formatNot) ? formatNot : [])
  const times = new Map()
  for (const item of Array.isArray(media) ? media : []) {
    if (!item || excluded.has(/** @type {any} */ (item).format)) continue
    const key = scheduleKey(item)
    if (seen.has(key)) continue
    const at = time(item)
    if (at == null) continue
    seen.add(key)
    times.set(item, at)
  }
  return [...times.keys()].sort((a, b) => compareTimes(times.get(a), times.get(b)))
}

/**
 * Sort order of two times; a missing or invalid one goes last.
 * @param {number | null | undefined} a
 * @param {number | null | undefined} b
 */
export function compareTimes (a, b) {
  const x = Number.isNaN(Number(a ?? NaN)) ? Infinity : Number(a)
  const y = Number.isNaN(Number(b ?? NaN)) ? Infinity : Number(b)
  if (x === y) return 0
  return x < y ? -1 : 1
}
