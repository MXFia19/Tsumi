// Online subtitles (subs.wing.st, same provider as the iOS app: ios-native/Tsumi/Player/PlayerOnlineSubtitles.swift).
// Pure helpers: request URLs, episode numbering candidates, result cleanup and grouping. Tested by core.test.mjs.
//
// API (no public docs, observed): GET /subtitles?type=tv&tmdb=<id>&season=<s>&episode=<e> or ?type=movie&tmdb=<id>
// -> { total, subtitles: [{ id, language: 'en', url, type: 'srt', display: '<release>.srt', source, voteRef }] }.
// Only "movie" and "tv" exist; season and episode are required for tv. Files are UTF-8 SRT.

export const ONLINE_SUBS_API = 'https://subs.wing.st'

/** Preferred Subtitle Language setting (codes of PlayerTab.svelte) -> ISO 639-1 used by the provider. */
export const SETTING_TO_ISO = {
  eng: 'en',
  jpn: 'ja',
  chi: 'zh',
  por: 'pt',
  spa: 'es',
  lat: 'es',
  ger: 'de',
  pol: 'pl',
  cze: 'cs',
  dan: 'da',
  gre: 'el',
  fin: 'fi',
  fre: 'fr',
  hun: 'hu',
  ita: 'it',
  kor: 'ko',
  dut: 'nl',
  nor: 'no',
  rum: 'ro',
  rus: 'ru',
  slo: 'sk',
  swe: 'sv',
  ara: 'ar',
  idn: 'id'
}

const ALIASES = { nb: 'no', nn: 'no', iw: 'he', in: 'id', ji: 'yi', jw: 'jv', pb: 'pt', ze: 'zh' }

/** Lower-case primary language subtag ("pt-BR" -> "pt", "nb" -> "no"); "" when unknown. */
export function normalizeLanguage (code) {
  const primary = String(code || '').trim().toLowerCase().split(/[-_]/)[0]
  if (!/^[a-z]{2,3}$/.test(primary)) return ''
  return ALIASES[primary] || primary
}

/** ISO code of the Preferred Subtitle Language setting; English when it is None or unknown. */
export function preferredLanguage (setting) {
  if (!setting) return 'en'
  const value = String(setting).toLowerCase()
  return SETTING_TO_ISO[value] || normalizeLanguage(value) || 'en'
}

/** English name of a language code ("pt" -> "Portuguese"), the code itself when unknown. */
export function languageName (code) {
  if (!code || code === 'und') return 'Unknown'
  try {
    const name = new Intl.DisplayNames(['en'], { type: 'language' }).of(code)
    if (name && name.toLowerCase() !== code.toLowerCase()) return name
  } catch {}
  return code.toUpperCase()
}

/** @param {{ type: 'tv' | 'movie', tmdb: number, season?: number, episode?: number }} query */
export function subtitlesUrl (query) {
  const params = new URLSearchParams({ type: query.type, tmdb: String(query.tmdb) })
  if (query.type === 'tv') {
    params.set('season', String(query.season))
    params.set('episode', String(query.episode))
  }
  return `${ONLINE_SUBS_API}/subtitles?${params}`
}

export function queryKey (query) {
  return query.type === 'tv' ? `tv:${query.tmdb}:${query.season}:${query.episode}` : `movie:${query.tmdb}`
}

const positive = (value) => {
  const number = Number(value)
  return Number.isInteger(number) && number > 0 ? number : null
}

/**
 * Season / episode pairs to try, in order, for an anime episode. ani.zip gives the TVDB numbering
 * (seasonNumber / episodeNumber) and the absolute number; some shows are filed by the provider under one long
 * season (One Piece episode 1000 is S1E1000, not S21E109), so absolute numbering is the fallback.
 * @param {{ episode: number, aniEpisode?: any, tvdbSeason?: number, tvdbOffset?: number }} input
 */
export function episodeCandidates ({ episode, aniEpisode, tvdbSeason, tvdbOffset }) {
  const candidates = []
  const add = (season, number) => {
    const s = positive(season)
    const e = positive(number)
    if (s && e && !candidates.some(c => c.season === s && c.episode === e)) candidates.push({ season: s, episode: e })
  }
  if (aniEpisode) {
    add(aniEpisode.seasonNumber, aniEpisode.episodeNumber)
    add(1, aniEpisode.absoluteEpisodeNumber)
  }
  if (positive(tvdbSeason)) add(tvdbSeason, Number(episode) + (Number(tvdbOffset) || 0))
  add(1, episode)
  return candidates
}

/**
 * Season and episode of an absolute episode number of a TMDB show (episode lists number TMDB episodes across
 * seasons, specials excluded). `seasons`: TMDB seasons ({ season_number, episode_count }).
 */
export function tmdbSeasonEpisode (seasons, absolute) {
  let remaining = Number(absolute)
  if (!Number.isInteger(remaining) || remaining < 1) return null
  const list = (seasons || [])
    .map(season => ({ season: Number(season.season_number ?? season.seasonNumber), count: Number(season.episode_count ?? season.episodeCount) || 0 }))
    .filter(season => season.season > 0)
    .sort((a, b) => a.season - b.season)
  for (const season of list) {
    if (remaining <= season.count) return { season: season.season, episode: remaining }
    remaining -= season.count
  }
  return null
}

/**
 * Cleans the provider answer: valid https URLs only, language codes normalized, duplicate releases (same
 * language and file name, the provider often lists the same upload many times) removed. Provider order is kept.
 */
export function parseSubtitleList (json) {
  const list = []
  const seen = new Set()
  for (const entry of json?.subtitles || []) {
    const url = String(entry?.url || '')
    if (!/^https:\/\//i.test(url)) continue
    const language = normalizeLanguage(entry.language) || 'und'
    const name = String(entry.display || '').trim() || 'Subtitles'
    const key = `${language}|${name.toLowerCase()}`
    if (seen.has(key) || seen.has(url)) continue
    seen.add(key)
    seen.add(url)
    list.push({
      id: String(entry.id || url),
      url,
      language,
      name,
      source: String(entry.source || ''),
      format: String(entry.type || 'srt').toLowerCase()
    })
  }
  return list
}

/**
 * Groups by language: the preferred language first, then English, then the other languages by name.
 * @returns {{ language: string, name: string, items: any[] }[]}
 */
export function groupByLanguage (list, preferred, nameOf = languageName) {
  const groups = new Map()
  for (const item of list) {
    if (!groups.has(item.language)) groups.set(item.language, { language: item.language, name: nameOf(item.language), items: [] })
    groups.get(item.language).items.push(item)
  }
  const rank = (group) => group.language === preferred ? 0 : group.language === 'en' ? 1 : 2
  return [...groups.values()].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name))
}

/** Subtitle picked by "Automatically add online subtitles": first SRT in the preferred language. */
export function pickAutomatic (list, preferred) {
  const matching = list.filter(item => item.language === preferred)
  return matching.find(item => item.format === 'srt') || matching[0] || null
}

/** Track name shown in the subtitle menu: "English - <release name without extension>". */
export function trackLabel (item, nameOf = languageName) {
  const release = String(item?.name || '').replace(/\.(srt|vtt|ass|ssa|sub|txt)$/i, '').trim()
  const language = nameOf(item?.language)
  return release ? `${language} - ${release}` : language
}
