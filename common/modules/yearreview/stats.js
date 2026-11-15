// Year in Review: pure statistics, no app imports (tested with node, see stats.test.mjs).
// Ported to Swift in ios-native/Tsumi/Services/YearReviewStats.swift: keep both in step.
//
// Inputs, all normalised by yearreview.js from AniList:
//   activities: [{ id, status, progress, createdAt (epoch seconds), mediaId }]   (ListActivity of the year)
//   media:      { [id]: { id, title, cover, color, banner, format, episodes, duration, genres: [], studios: [] } }
//   entries:    [{ mediaId, status, score (0-10, 0 = none), progress, repeat, startedAt, completedAt, updatedAt, createdAt }]
//               (startedAt / completedAt are AniList fuzzy dates { year, month, day })
//   prior:      { [mediaId]: progress before the year } (optional, see mediaNeedingPrior)
//
// Episode counting (AniList list activities):
// - "watched episode 4 - 6" counts 3, overlapping ranges of the same title are only counted once;
// - "completed" has no episode number: it adds the episodes between the last progress seen and the total.
//   Without an earlier progress in the year, the progress before the year (prior) is used, else the whole
//   title counts when it was started this year (or has no start date) and only the last episode otherwise;
// - "rewatched episode" / "rewatched" are counted the same way in a separate rewatch cycle;
// - a list entry completed this year with no activity at all (activities disabled, imports) is treated as a
//   "completed" activity at its completion date.

export const STATS_VERSION = 1
export const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
export const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
export const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
/** Minutes per episode when AniList has no duration. */
export const DEFAULT_EPISODE_MINUTES = 24
export const DEFAULT_MOVIE_MINUTES = 90
/** A local history record counts as a watched episode from this fraction. */
export const LOCAL_WATCHED_FRACTION = 0.8
const MAX_RANGE = 5000
const TOP_COUNT = 5

/** Local-time bounds of a year in epoch seconds: start <= createdAt < end. */
export function yearBounds (year) {
  return {
    start: Math.floor(new Date(year, 0, 1).getTime() / 1000),
    end: Math.floor(new Date(year + 1, 0, 1).getTime() / 1000)
  }
}

/** "5" → { from: 5, to: 5 }, "1 - 12" → { from: 1, to: 12 }, anything else → null. */
export function parseProgress (progress) {
  if (progress === null || progress === undefined) return null
  const numbers = String(progress).match(/\d+/g)
  if (!numbers?.length) return null
  const first = Number(numbers[0])
  const last = Number(numbers[numbers.length - 1])
  const from = Math.min(first, last)
  const to = Math.max(first, last)
  if (!Number.isFinite(from) || !Number.isFinite(to) || to - from > MAX_RANGE) return null
  return { from, to }
}

/** ListActivity.status → watch | rewatch | complete | rewatched | drop | pause | plan | other. */
export function activityKind (status) {
  const text = String(status || '').trim().toLowerCase()
  if (text.startsWith('rewatched episode')) return 'rewatch'
  if (text.startsWith('watched episode')) return 'watch'
  if (text === 'rewatched') return 'rewatched'
  if (text === 'completed') return 'complete'
  if (text === 'dropped') return 'drop'
  if (text.startsWith('paused')) return 'pause'
  if (text.startsWith('plans')) return 'plan'
  if (text.startsWith('rewatching')) return 'rewatch'
  if (text.startsWith('watching')) return 'watch'
  return 'other'
}

/** AniList fuzzy date → epoch seconds at local noon (null without a year). */
export function fuzzyToTime (fuzzy) {
  if (!fuzzy?.year) return null
  return Math.floor(new Date(fuzzy.year, (fuzzy.month || 1) - 1, fuzzy.day || 1, 12).getTime() / 1000)
}

export function fuzzyInYear (fuzzy, year) {
  return !!fuzzy?.year && fuzzy.year === year
}

function fuzzyBefore (fuzzy, year) {
  return !!fuzzy?.year && fuzzy.year < year
}

/** Local calendar day "YYYY-MM-DD" of epoch seconds. */
export function dayKey (seconds) {
  const date = new Date(seconds * 1000)
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

function dayIndex (key) {
  const [year, month, day] = key.split('-').map(Number)
  return Math.round(Date.UTC(year, month - 1, day) / 86_400_000)
}

/** "YYYY-MM-DD" → "Saturday, March 14". */
export function formatDay (key) {
  if (!key) return ''
  const [year, month, day] = key.split('-').map(Number)
  const weekday = new Date(year, month - 1, day).getDay()
  return `${WEEKDAYS[weekday]}, ${MONTH_NAMES[month - 1]} ${day}`
}

/** "YYYY-MM-DD" → "Mar 14". */
export function formatShortDay (key) {
  if (!key) return ''
  const [, month, day] = key.split('-').map(Number)
  return `${MONTHS[month - 1]} ${day}`
}

/** Hours for display: one decimal under 10 hours, whole hours above. */
export function hoursValue (minutes) {
  const hours = (minutes || 0) / 60
  return hours < 10 ? Math.round(hours * 10) / 10 : Math.round(hours)
}

/** "12,345" (English grouping); one decimal is kept for values like the "1.5" of hoursValue. */
export function formatNumber (value) {
  const rounded = Math.round((Number(value) || 0) * 10) / 10
  const whole = Math.trunc(Math.abs(rounded))
  const tenths = Math.round((Math.abs(rounded) - whole) * 10)
  const text = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (tenths ? `.${tenths}` : '')
  return rounded < 0 ? `-${text}` : text
}

export function episodeMinutes (media) {
  if (media?.duration > 0) return media.duration
  return media?.format === 'MOVIE' ? DEFAULT_MOVIE_MINUTES : DEFAULT_EPISODE_MINUTES
}

/** Episode total used by completions: 1 for movies, null when unknown. */
function totalEpisodes (media) {
  if (media?.episodes > 0) return media.episodes
  return media?.format === 'MOVIE' ? 1 : null
}

function entryMap (entries) {
  const map = new Map()
  for (const entry of entries || []) {
    if (entry?.mediaId && !map.has(entry.mediaId)) map.set(entry.mediaId, entry)
  }
  return map
}

/**
 * Activities of the year in chronological order, plus a synthetic "completed" activity for every entry
 * completed this year without a "completed" activity in the year (activity disabled for that status, imports).
 */
function timeline ({ year, activities, entries }) {
  const { start, end } = yearBounds(year)
  const list = (activities || []).filter(activity => activity?.mediaId && activity.createdAt >= start && activity.createdAt < end)
  const withCompletion = new Set(list.filter(activity => activityKind(activity.status) === 'complete').map(activity => activity.mediaId))
  for (const entry of entries || []) {
    if (!entry?.mediaId || withCompletion.has(entry.mediaId)) continue
    if (!['COMPLETED', 'REPEATING'].includes(entry.status) || !fuzzyInYear(entry.completedAt, year)) continue
    const time = Math.min(Math.max(fuzzyToTime(entry.completedAt), start), end - 1)
    list.push({ id: 0, status: 'completed', progress: null, createdAt: time, mediaId: entry.mediaId, synthetic: true })
    withCompletion.add(entry.mediaId)
  }
  return list.sort((a, b) => (a.createdAt - b.createdAt) || (a.id - b.id))
}

/**
 * Titles whose first completion of the year has no earlier progress in the year: their progress before
 * the year (one AniList lookup) tells how many episodes were left. Movies, one-episode titles and entries
 * added to the list during the year (no earlier progress possible) are skipped.
 */
export function mediaNeedingPrior ({ year, activities, media, entries }) {
  const { start } = yearBounds(year)
  const entriesById = entryMap(entries)
  const seen = new Set()
  const result = []
  for (const activity of timeline({ year, activities, entries })) {
    const kind = activityKind(activity.status)
    if (seen.has(activity.mediaId)) continue
    if (kind === 'watch' || kind === 'rewatch' || kind === 'rewatched') { seen.add(activity.mediaId); continue }
    if (kind !== 'complete') continue
    seen.add(activity.mediaId)
    const total = totalEpisodes(media?.[activity.mediaId])
    const added = entriesById.get(activity.mediaId)?.createdAt
    if (total && total > 1 && !(added >= start)) result.push(activity.mediaId)
  }
  return result
}

/**
 * Progress before the year from the latest earlier activities of the given titles (newest first).
 * Returns { [mediaId]: progress }; titles without a usable activity are left out.
 */
export function priorFromActivities (activities, media) {
  const prior = {}
  for (const activity of activities || []) {
    const id = activity?.mediaId
    if (!id || id in prior) continue
    const kind = activityKind(activity.status)
    const range = parseProgress(activity.progress)
    const total = totalEpisodes(media?.[id])
    if (kind === 'watch' && range) prior[id] = range.to
    else if ((kind === 'complete' || kind === 'rewatch' || kind === 'rewatched') && total) prior[id] = total
    else if (kind === 'plan') prior[id] = 0
  }
  return prior
}

function topBy (map, limit, compare) {
  return [...map.values()].sort(compare).slice(0, limit)
}

/** Every statistic of the Year in Review screen. */
export function computeYearStats ({ year, activities, media, entries, prior }) {
  const mediaMap = media || {}
  const entriesById = entryMap(entries)
  const priorMap = prior || {}
  const { start, end } = yearBounds(year)

  /** Per title: watched episodes this year and the state of the first-watch / rewatch cycles. */
  const titles = new Map()
  const state = new Map()
  const events = [] // { mediaId, time, episodes }
  const started = new Set()
  const completed = new Set()
  const dropped = new Set()
  const touched = new Set()
  let rewatchEpisodes = 0

  const titleFor = (id) => {
    if (!titles.has(id)) titles.set(id, { mediaId: id, episodes: 0, minutes: 0 })
    return titles.get(id)
  }
  const stateFor = (id) => {
    if (!state.has(id)) state.set(id, { max: null, rewatchMax: null, seenWatch: false })
    return state.get(id)
  }
  const add = (id, time, episodes, rewatch) => {
    if (episodes <= 0) return
    const minutes = episodes * episodeMinutes(mediaMap[id])
    const title = titleFor(id)
    title.episodes += episodes
    title.minutes += minutes
    if (rewatch) rewatchEpisodes += episodes
    events.push({ mediaId: id, time, episodes, minutes })
  }

  for (const activity of timeline({ year, activities, entries })) {
    const id = activity.mediaId
    const kind = activityKind(activity.status)
    const range = parseProgress(activity.progress)
    const total = totalEpisodes(mediaMap[id])
    const entry = entriesById.get(id)
    const current = stateFor(id)
    touched.add(id)

    if (kind === 'watch') {
      if (range) {
        if (!current.seenWatch && range.from <= 1) started.add(id)
        const base = Math.max(range.from - 1, current.max ?? -1)
        add(id, activity.createdAt, Math.max(0, range.to - base), false)
        current.max = Math.max(current.max ?? 0, range.to)
      }
      current.seenWatch = true
    } else if (kind === 'rewatch') {
      if (range) {
        if (range.from <= 1) current.rewatchMax = 0
        const base = Math.max(range.from - 1, current.rewatchMax ?? -1)
        add(id, activity.createdAt, Math.max(0, range.to - base), true)
        current.rewatchMax = Math.max(current.rewatchMax ?? 0, range.to)
      }
    } else if (kind === 'complete') {
      completed.add(id)
      let base = current.max
      if (base === null && typeof priorMap[id] === 'number') base = priorMap[id]
      if (total) {
        if (base === null) {
          base = fuzzyBefore(entry?.startedAt, year) ? total - 1 : 0
        }
        if (base <= 0 && !current.seenWatch) started.add(id)
        add(id, activity.createdAt, Math.max(0, total - base), false)
        current.max = Math.max(current.max ?? 0, total)
      } else if (!current.seenWatch) {
        // Unknown total (should not happen for a completed title): at least the last episode.
        add(id, activity.createdAt, 1, false)
      }
      current.seenWatch = true
    } else if (kind === 'rewatched') {
      if (total) {
        const base = current.rewatchMax ?? 0
        add(id, activity.createdAt, Math.max(0, total - base), true)
      }
      current.rewatchMax = null
    } else if (kind === 'drop') {
      dropped.add(id)
    }
  }

  for (const entry of entries || []) {
    if (!entry?.mediaId) continue
    if (['COMPLETED', 'REPEATING'].includes(entry.status) && fuzzyInYear(entry.completedAt, year)) {
      completed.add(entry.mediaId)
      touched.add(entry.mediaId)
    }
    if (fuzzyInYear(entry.startedAt, year)) {
      started.add(entry.mediaId)
      touched.add(entry.mediaId)
    }
    if (entry.status === 'DROPPED' && entry.updatedAt >= start && entry.updatedAt < end && titles.get(entry.mediaId)?.episodes > 0) {
      dropped.add(entry.mediaId)
    }
  }

  const watched = [...titles.values()].filter(title => title.episodes > 0)
  const episodes = watched.reduce((sum, title) => sum + title.episodes, 0)
  const minutes = watched.reduce((sum, title) => sum + title.minutes, 0)

  // Months and days
  const months = new Array(12).fill(0)
  const monthMinutes = new Array(12).fill(0)
  const days = new Map()
  for (const event of events) {
    const month = new Date(event.time * 1000).getMonth()
    months[month] += event.episodes
    monthMinutes[month] += event.minutes
    const key = dayKey(event.time)
    if (!days.has(key)) days.set(key, { date: key, episodes: 0, minutes: 0, perMedia: new Map() })
    const day = days.get(key)
    day.episodes += event.episodes
    day.minutes += event.minutes
    day.perMedia.set(event.mediaId, (day.perMedia.get(event.mediaId) || 0) + event.episodes)
  }
  let bingeDay = null
  for (const day of [...days.values()].sort((a, b) => a.date.localeCompare(b.date))) {
    if (!bingeDay || day.episodes > bingeDay.episodes) bingeDay = day
  }
  if (bingeDay) {
    bingeDay = {
      date: bingeDay.date,
      episodes: bingeDay.episodes,
      minutes: bingeDay.minutes,
      mediaIds: [...bingeDay.perMedia.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id)
    }
  }
  const dayKeys = [...days.keys()].sort()
  let longestStreak = null
  let runStart = null
  let previous = null
  for (const key of dayKeys) {
    const index = dayIndex(key)
    if (previous === null || index !== previous + 1) runStart = key
    const length = index - dayIndex(runStart) + 1
    if (!longestStreak || length > longestStreak.days) longestStreak = { days: length, start: runStart, end: key }
    previous = index
  }

  // Ranked lists
  const topAnime = watched
    .sort((a, b) => (b.episodes - a.episodes) || (b.minutes - a.minutes) || (a.mediaId - b.mediaId))
    .slice(0, TOP_COUNT)
    .map(({ mediaId, episodes, minutes }) => ({ mediaId, episodes, minutes }))
  const rank = (field) => {
    const map = new Map()
    for (const title of watched) {
      const names = [...new Set(mediaMap[title.mediaId]?.[field] || [])]
      for (const name of names) {
        if (!name) continue
        if (!map.has(name)) map.set(name, { name, count: 0, episodes: 0, minutes: 0 })
        const item = map.get(name)
        item.count++
        item.episodes += title.episodes
        item.minutes += title.minutes
      }
    }
    return topBy(map, TOP_COUNT, (a, b) => (b.count - a.count) || (b.minutes - a.minutes) || a.name.localeCompare(b.name))
  }

  // Scores of the titles watched / completed this year
  let scoreSum = 0
  let scoredCount = 0
  let topRated = null
  for (const id of new Set([...watched.map(title => title.mediaId), ...completed])) {
    const score = entriesById.get(id)?.score
    if (!(score > 0)) continue
    scoreSum += score
    scoredCount++
    const episodesOf = titles.get(id)?.episodes || 0
    if (!topRated || score > topRated.score || (score === topRated.score && episodesOf > topRated.episodes)) {
      topRated = { mediaId: id, score, episodes: episodesOf }
    }
  }

  const ordered = events.slice().sort((a, b) => a.time - b.time)
  const first = ordered[0] ? { mediaId: ordered[0].mediaId, time: ordered[0].time } : null
  const last = ordered.length ? { mediaId: ordered[ordered.length - 1].mediaId, time: ordered[ordered.length - 1].time } : null

  return {
    version: STATS_VERSION,
    year,
    hasData: episodes > 0 || completed.size > 0 || started.size > 0 || dropped.size > 0,
    episodes,
    minutes,
    titles: watched.length,
    rewatchEpisodes,
    started: started.size,
    completed: completed.size,
    dropped: dropped.size,
    startedIds: [...started],
    completedIds: [...completed],
    droppedIds: [...dropped],
    averageScore: scoredCount ? Math.round(scoreSum / scoredCount * 10) / 10 : null,
    scoredCount,
    topRated: topRated ? { mediaId: topRated.mediaId, score: topRated.score } : null,
    topAnime,
    genres: rank('genres'),
    studios: rank('studios'),
    months,
    monthMinutes,
    bingeDay,
    activeDays: days.size,
    longestStreak,
    first,
    last,
    touched: touched.size
  }
}

/**
 * Local watch history (shows and movies from TMDB, not on AniList) for one year.
 * records: [{ key, episode, currentTime (s), duration (s), updatedAt (ms) }]
 */
export function computeLocalStats (records, year) {
  const startMs = new Date(year, 0, 1).getTime()
  const endMs = new Date(year + 1, 0, 1).getTime()
  const titles = new Map()
  let episodes = 0
  let minutes = 0
  for (const record of records || []) {
    if (!record?.key || !(record.updatedAt >= startMs && record.updatedAt < endMs)) continue
    const duration = record.duration > 0 ? record.duration : 0
    if (!duration) continue
    const watchedSeconds = Math.min(Math.max(record.currentTime || 0, 0), duration)
    const finished = watchedSeconds / duration >= LOCAL_WATCHED_FRACTION ? 1 : 0
    if (!titles.has(record.key)) titles.set(record.key, { key: record.key, episodes: 0, minutes: 0, lastWatched: 0 })
    const title = titles.get(record.key)
    title.episodes += finished
    title.minutes += watchedSeconds / 60
    title.lastWatched = Math.max(title.lastWatched, record.updatedAt)
    episodes += finished
    minutes += watchedSeconds / 60
  }
  const top = [...titles.values()]
    .sort((a, b) => (b.minutes - a.minutes) || (b.episodes - a.episodes) || String(a.key).localeCompare(String(b.key)))
    .slice(0, TOP_COUNT)
    .map(title => ({ ...title, minutes: Math.round(title.minutes) }))
  return { year, hasData: titles.size > 0, titles: titles.size, episodes, minutes: Math.round(minutes), top }
}

/**
 * Years offered by the picker: the current year plus every year found in the list entries
 * (started / completed / added / updated) and in the extra years (local history), newest first.
 */
export function availableYears (entries, now = new Date(), extraYears = []) {
  const current = now.getFullYear()
  const years = new Set([current, ...extraYears])
  const yearOf = (seconds) => seconds > 0 ? new Date(seconds * 1000).getFullYear() : null
  for (const entry of entries || []) {
    for (const year of [entry?.startedAt?.year, entry?.completedAt?.year, yearOf(entry?.createdAt), yearOf(entry?.updatedAt)]) {
      if (year) years.add(year)
    }
  }
  return [...years].filter(year => year >= 2000 && year <= current).sort((a, b) => b - a)
}

/** Year shown by the Home banner: December → this year, January → last year, else null. */
export function bannerYear (now = new Date()) {
  const month = now.getMonth()
  if (month === 11) return now.getFullYear()
  if (month === 0) return now.getFullYear() - 1
  return null
}
