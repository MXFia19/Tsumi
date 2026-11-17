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

/**
 * Episodes of an `extractEpisodes` answer (a JSON text or an array): entries with a link, once per link, in the
 * module's order. The module's numbers are kept when they are all different whole numbers; otherwise (no number,
 * seasons starting again at 1...) the episodes are numbered 1, 2, 3... in the list order, so a number (playback, saved
 * position, next episode) always means one episode. Like iOS SoraResultSource.
 * @param {any} raw
 * @returns {{ href: string, number: number, title: string }[]}
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
    episodes.push({ href, number, title })
  }
  const numbers = episodes.map(episode => episode.number)
  const own = numbers.every(number => Number.isInteger(number) && number >= 0) && new Set(numbers).size === numbers.length
  return episodes.map((episode, index) => ({ ...episode, number: own ? episode.number : index + 1 }))
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
 * Button text of an episode: "Play" for a result with one episode (a video, a stream), else "Episode N" and the
 * episode title when the module gives one.
 * @param {{ number: number, title: string }} episode
 * @param {number} count episodes of the result
 */
export function episodeLabel (episode, count) {
  if (count === 1) return 'Play'
  const title = episode.title && !/^episode\s*\d+$/i.test(episode.title) ? ` - ${episode.title}` : ''
  return `Episode ${episode.number}${title}`
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
