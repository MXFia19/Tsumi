// Pure helpers of the offline downloads (renderer side), unit tested by resolve.test.mjs.
// Same title scoring and season-aware episode matching as DefaultLoadingModal.svelte / ExtensionResults.svelte,
// except that a download never falls back to another episode than the one asked for.

/** titleScore of the extension modals: 100 exact, 90 containment, up to 80 by matching words. */
export function titleScore (searchTitle, resultTitle) {
  if (!searchTitle || !resultTitle) return 0
  const a = searchTitle.toLowerCase().replace(/[^a-z0-9\s]/g, '').trim()
  const b = resultTitle.toLowerCase().replace(/[^a-z0-9\s]/g, '').trim()
  if (a === b) return 100
  if (b.includes(a) || a.includes(b)) return 90
  const aWords = a.split(/\s+/)
  const bWords = b.split(/\s+/)
  const matches = aWords.filter((w) => bWords.some((bw) => bw === w || (w.length > 2 && bw.includes(w)))).length
  return Math.min(Math.round((matches / Math.max(aWords.length, 1)) * 80), 80)
}

/** Best search result (highest score, first on ties). */
export function bestResult (results, title) {
  if (!Array.isArray(results) || !results.length) return null
  return results
    .map((result, index) => ({ result, index, score: titleScore(title, result?.title) }))
    .sort((a, b) => b.score - a.score || a.index - b.index)[0].result
}

/**
 * Episode of an extension list for { number, season, localEpisode }: season + local number, "/S/E" in the href,
 * inferred seasons (numbering restarts), a unique local number; the absolute number otherwise. Null when not found
 * (a single-episode list is that episode: movies).
 */
export function matchEpisode (episodes, episode) {
  if (!Array.isArray(episodes) || !episodes.length) return null
  const targetNumber = Number(typeof episode === 'object' ? episode?.number : episode)
  const targetSeason = typeof episode === 'object' ? episode?.season : null
  const targetLocal = typeof episode === 'object' ? episode?.localEpisode : null
  let found = null
  if (targetSeason != null && targetLocal != null) {
    found = episodes.find(ep => ep.season != null && Number(ep.season) === Number(targetSeason) && Number(ep.number) === Number(targetLocal))
    if (!found) found = episodes.find(ep => typeof ep.href === 'string' && new RegExp(`/${targetSeason}/${targetLocal}(?:/|$)`).test(ep.href))
    if (!found) {
      let season = episodes[0]?.season != null ? Number(episodes[0].season) : 1
      let last = 0
      const inferred = episodes.map(ep => {
        const number = Number(ep.number)
        if (ep.season == null) {
          if (number < last) season++
        } else season = Number(ep.season)
        last = number
        return season
      })
      const index = episodes.findIndex((ep, i) => inferred[i] === Number(targetSeason) && Number(ep.number) === Number(targetLocal))
      if (index !== -1) found = episodes[index]
    }
    if (!found) {
      const local = episodes.filter(ep => Number(ep.number) === Number(targetLocal))
      if (local.length === 1) found = local[0]
    }
  } else {
    found = episodes.find(ep => Number(ep.number) === targetNumber)
  }
  if (!found && episodes.length === 1) found = episodes[0]
  return found || null
}

/** Subtitle list of a stream answer: a URL, an object ({ url | file | src, lang | language | label }) or an array. */
export function normalizeSubtitles (value) {
  const list = Array.isArray(value) ? value : value ? [value] : []
  const out = []
  for (const entry of list) {
    if (typeof entry === 'string') {
      if (entry.trim()) out.push({ url: entry.trim(), lang: '', label: '' })
      continue
    }
    if (!entry || typeof entry !== 'object') continue
    const url = entry.url || entry.file || entry.src
    if (typeof url !== 'string' || !url.trim()) continue
    const lang = String(entry.lang || entry.language || entry.srclang || '')
    out.push({ url: url.trim(), lang, label: String(entry.label || entry.name || lang || '') })
  }
  const seen = new Set()
  return out.filter(subtitle => !seen.has(subtitle.url) && seen.add(subtitle.url))
}

const LANGUAGES = {
  eng: 'en|eng|english',
  jpn: 'ja|jpn|japanese',
  chi: 'zh|chi|zho|chinese',
  por: 'pt|por|portuguese',
  spa: 'es|spa|spanish',
  lat: 'es-?419|lat|latin|spanish',
  ger: 'de|ger|deu|german',
  pol: 'pl|pol|polish',
  cze: 'cs|cze|ces|czech',
  dan: 'da|dan|danish',
  gre: 'el|gre|ell|greek',
  fin: 'fi|fin|finnish',
  fre: 'fr|fre|fra|french',
  hun: 'hu|hun|hungarian',
  ita: 'it|ita|italian',
  kor: 'ko|kor|korean',
  dut: 'nl|dut|nld|dutch',
  nor: 'no|nor|nb|norwegian',
  rum: 'ro|rum|ron|romanian',
  rus: 'ru|rus|russian',
  slo: 'sk|slo|slk|slovak',
  swe: 'sv|swe|swedish',
  ara: 'ar|ara|arabic',
  idn: 'id|ind|idn|indonesian'
}

function matchesLanguage (subtitle, code) {
  if (!code) return false
  const pattern = new RegExp(`^(${LANGUAGES[code] || code})\\b`, 'i')
  return pattern.test(subtitle.lang || '') || pattern.test(subtitle.label || '')
}

/** Subtitle played offline: the preferred subtitle language, else French (iOS stream parser rule), else the first. */
export function preferredSubtitle (subtitles, language) {
  if (!Array.isArray(subtitles) || !subtitles.length) return null
  return subtitles.find(subtitle => matchesLanguage(subtitle, language)) || subtitles.find(subtitle => matchesLanguage(subtitle, 'fre')) || subtitles[0]
}

/** Server of a fresh stream: the one downloaded before (title), else the session choice, else the first. */
export function pickServerIndex (servers, preferredTitle, sessionTitle) {
  if (!Array.isArray(servers) || !servers.length) return 0
  const titleOf = (server, index) => server?.title || `Server ${index + 1}`
  for (const wanted of [preferredTitle, sessionTitle]) {
    if (!wanted) continue
    const index = servers.findIndex((server, i) => titleOf(server, i) === wanted)
    if (index !== -1) return index
  }
  return 0
}

/**
 * Every server index, the one to try first (pickServerIndex) then the others in the extension's order: the
 * downloader moves to the next one when a server is dead (unknown host, refused, HTTP error...).
 */
export function orderServerIndexes (servers, preferredTitle, sessionTitle) {
  if (!Array.isArray(servers) || !servers.length) return []
  const first = pickServerIndex(servers, preferredTitle, sessionTitle)
  return [first, ...servers.map((_, index) => index).filter(index => index !== first)]
}

/** Episodes to download for "Download next N episodes": after the list progress, up to the last released one. */
export function nextEpisodeNumbers ({ progress = 0, released = 0, count = 1, zeroEpisode = false } = {}) {
  const first = Math.max(Number(progress) || 0, 0) + (zeroEpisode ? 0 : 1)
  const last = Math.min(first + Math.max(Number(count) || 1, 1) - 1, Number(released) || 0)
  const numbers = []
  for (let number = first; number <= last; number++) numbers.push(number)
  return numbers
}

/** "1.2 GB" */
export function formatBytes (bytes) {
  const value = Number(bytes) || 0
  if (value < 1024) return `${value} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let size = value / 1024
  let unit = 0
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024
    unit++
  }
  return `${size >= 100 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`
}
