// A Sora module result opened as it is, without an AniList / TMDB title (modules that are not anime, shows or movies,
// setting "Link results to AniList / TMDB" off, or "Open as is" when nothing matches): its own details and episodes
// (modals/SoraResultModal.svelte, sora/resultpage.js). Pure, tested by moduleresult.test.mjs.

/**
 * Whether the results of a module open their AniList / TMDB title (the default) or open as they are.
 * @param {any} config the module entry of settings.extensions
 */
export function linksResults (config) {
  return config?.linkResults !== false
}

/** A whole number from 0, else null. */
function whole (value) {
  return Number.isInteger(value) && value >= 0 && value < 1_000_000 ? value : null
}

/**
 * Season of each episode, or null when the result has one season only. Same rules as the season-aware episode pick
 * of linked results (ExtensionResults.svelte, iOS PlaybackResolver): a `season` given by the module wins, otherwise a
 * new season starts where the numbers start again. Stricter, since every episode is shown under its season: a season
 * is only inferred where the number goes back to 0 or 1, and never for a list numbered downwards (newest first), which
 * would start a season at every episode.
 * @param {{ number: number, season: number }[]} entries
 * @returns {number[] | null}
 */
function seasonsOf (entries) {
  const given = entries.map(entry => whole(entry.season))
  let current = given[0] ?? 1
  let last = NaN
  let up = 0
  let down = 0
  const seasons = entries.map(({ number }, index) => {
    if (given[index] != null) current = given[index]
    else if (number < last && number <= 1) current++
    if (number > last) up++
    else if (number < last) down++
    if (Number.isFinite(number)) last = number
    return current
  })
  if (new Set(seasons).size < 2) return null
  if (given.every(season => season == null) && down >= up) return null
  return seasons
}

/** Name of the season given by the module (`seasonTitle`, or `seasonName`), '' when none. */
function seasonTitleOf (entry) {
  const value = typeof entry.seasonTitle === 'string' ? entry.seasonTitle : typeof entry.seasonName === 'string' ? entry.seasonName : ''
  return value.trim().slice(0, 80)
}

/**
 * Episodes of an `extractEpisodes` answer (a JSON text or an array): entries with a link, once per link, in the
 * module's order. The module's numbers are kept when they are all different whole numbers; otherwise (no number,
 * seasons starting again at 1...) the episodes are numbered 1, 2, 3... in the list order, so a number (playback, saved
 * position, next episode) always means one episode. With seasons, each episode also has its season and its number in
 * that season (`seasonEpisode`, shown on the module page). Seasons come from the season names of the module
 * (`seasonTitle` on every episode: "Saison 1", "Films", "Kai"... in the module's order), else from its `season`
 * numbers or its numbers starting again. Like iOS SoraResultSource.
 * @param {any} raw
 * @returns {{ href: string, number: number, title: string, season: number | null, seasonTitle: string | null, seasonEpisode: number }[]}
 */
export function moduleEpisodes (raw) {
  let parsed = raw
  if (typeof raw === 'string') {
    try {
      parsed = JSON.parse(raw)
    } catch {
      return []
    }
  }
  if (!Array.isArray(parsed)) return []
  const seen = new Set()
  const episodes = []
  for (const entry of parsed) {
    const href = typeof entry?.href === 'string' ? entry.href.trim() : ''
    if (!href || seen.has(href)) continue
    seen.add(href)
    const title = typeof entry.title === 'string' ? entry.title.trim().slice(0, 200) : ''
    const number = entry.number == null || entry.number === '' ? NaN : Number(entry.number)
    const season = entry.season == null || entry.season === '' ? NaN : Number(entry.season)
    episodes.push({ href, number, title, season, seasonTitle: seasonTitleOf(entry) })
  }
  const numbers = episodes.map(episode => episode.number)
  const own = numbers.every(number => Number.isInteger(number) && number >= 0) && new Set(numbers).size === numbers.length
  // Named seasons: every episode has a season name, and there are several. Numbered 1, 2, 3... in the module's order.
  const names = episodes.map(episode => episode.seasonTitle)
  const named = names.length > 0 && names.every(Boolean) && new Set(names).size > 1 ? [...new Set(names)] : null
  const seasons = named ? names.map(name => named.indexOf(name) + 1) : seasonsOf(episodes)
  /** season -> episodes of it so far (number in the season when the module gives none) */
  const counts = new Map()
  return episodes.map((episode, index) => {
    const number = own ? episode.number : index + 1
    const season = seasons ? seasons[index] : null
    const place = (counts.get(season) || 0) + 1
    counts.set(season, place)
    const seasonEpisode = season == null ? number : (whole(episode.number) ?? place)
    return { href: episode.href, number, title: episode.title, season, seasonTitle: named ? episode.seasonTitle : null, seasonEpisode }
  })
}

/**
 * Episodes of a module result by season, for the season picker of the module page: seasons in order, specials
 * (season 0) last, with the module's season name when it gives one. One group with season null when the result has
 * no seasons.
 * @template {{ season?: number | null, seasonTitle?: string | null }} T
 * @param {T[]} episodes
 * @returns {{ season: number | null, title: string | null, episodes: T[] }[]}
 */
export function moduleSeasons (episodes) {
  /** @type {Map<number | null, T[]>} */
  const groups = new Map()
  for (const episode of episodes) {
    const season = episode.season ?? null
    if (!groups.has(season)) groups.set(season, [])
    groups.get(season).push(episode)
  }
  const order = (season) => (season === 0 ? Infinity : season ?? -1)
  return [...groups]
    .map(([season, list]) => ({ season, title: list[0].seasonTitle || null, episodes: list }))
    .sort((a, b) => order(a.season) - order(b.season))
}

/**
 * Name of a season in the picker: the module's name, else "Season N" ("Specials" for 0).
 * @param {number | null} season
 * @param {string | null} [title]
 */
export function seasonLabel (season, title) {
  if (title) return title
  return season === 0 ? 'Specials' : `Season ${season}`
}

/** Number of an episode title that only says "Episode N" ("Épisode 12.5" for a special), else null. */
function labelNumber (title) {
  return /^[ée]pisode\s*(\d[\w.-]*)$/i.exec(title || '')?.[1] ?? null
}

/**
 * Number shown for an episode: the one of its title when the title only says "Episode N" (a module numbering its
 * specials 12.5 and the next episodes after them), else its number in its season.
 * @param {{ number: number, title?: string, seasonEpisode?: number }} episode
 */
function shownNumber (episode) {
  return labelNumber(episode.title) ?? episode.seasonEpisode ?? episode.number
}

/**
 * Short name of an episode in messages ("Loading S2E1..."): with its season when the result has seasons.
 * @param {{ number: number, title?: string, season?: number | null, seasonTitle?: string | null, seasonEpisode?: number }} episode
 */
export function episodeName (episode) {
  const number = shownNumber(episode)
  if (episode.seasonTitle) return `${episode.seasonTitle} · episode ${number}`
  if (episode.season == null) return `episode ${number}`
  return episode.season === 0 ? `special ${number}` : `S${episode.season}E${number}`
}

/**
 * Season the module page opens on: the last one with an episode already started here, else the first.
 * @param {{ season: number | null, episodes: { number: number }[] }[]} groups
 * @param {(number: number) => boolean} started
 */
export function startSeason (groups, started) {
  let found = groups[0]?.season ?? null
  for (const group of groups) {
    if (group.episodes.some(episode => started(episode.number))) found = group.season
  }
  return found
}

/**
 * Description and air date of an `extractDetails` answer (an object, or an array whose first entry is the object).
 * @param {any} raw
 * @returns {{ description: string, airdate: string }}
 */
export function moduleDetails (raw) {
  let parsed = raw
  if (typeof raw === 'string') {
    try {
      parsed = JSON.parse(raw)
    } catch {
      return { description: '', airdate: '' }
    }
  }
  const details = Array.isArray(parsed) ? parsed[0] : parsed
  const text = (value, max) => (typeof value === 'string' ? value.trim().slice(0, max) : '')
  const airdate = text(details?.airdate, 60)
  return {
    description: text(details?.description, 4000),
    // Modules without the information often send "N/A" or "Unknown".
    airdate: /^(n\/?a|unknown|none|-)$/i.test(airdate) ? '' : airdate
  }
}

/**
 * Button text of an episode: "Play" for a result with one episode (a video, a stream), else "Episode N" (its number
 * in its season when the result has seasons, or the number of a title that only says "Episode N") and the episode
 * title when the module gives one.
 * @param {{ number: number, title: string, seasonEpisode?: number }} episode
 * @param {number} count episodes of the result
 */
export function episodeLabel (episode, count) {
  if (count === 1) return 'Play'
  const title = episode.title && labelNumber(episode.title) == null ? ` - ${episode.title}` : ''
  return `Episode ${shownNumber(episode)}${title}`
}

/**
 * Media of a module result for the player: its episode count lets the player offer the next and previous episodes
 * (played from the module again, ExtensionModal.svelte playAnime). Whole numbers only, from 1.
 * @param {any} media card media of the result (match.js resultMedia)
 * @param {{ number: number }[]} episodes
 */
export function playableMedia (media, episodes) {
  const numbers = episodes.map(episode => episode.number).filter(number => Number.isInteger(number) && number > 0)
  return { ...media, episodes: numbers.length ? Math.max(...numbers) : null }
}

/**
 * The module's episode with the requested number, none when the result has no such episode (another episode played
 * under that number would be wrong).
 * @param {{ number: number }[]} episodes
 * @param {number} number
 */
export function episodeFor (episodes, number) {
  return episodes.find(episode => episode.number === Number(number)) || null
}
