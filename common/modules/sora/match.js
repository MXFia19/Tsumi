// Matching a Sora module search result (a title and a link, no AniList / TMDB id) to an AniList or TMDB media, so
// the details page, list tracking and the rest of the app work for it (sora/searchsource.js). Pure, tested by
// match.test.mjs.
import { scoreMedia, relevancePopularity, SCORE } from '../search/relevance.js'

/** Lowest title score accepted as the same title (a fuzzy match with a few typos still passes). */
export const MATCH_MIN_SCORE = SCORE.FUZZY

/**
 * Which catalogues to search for a module, from its manifest `type` ("anime", "movies", "shows"...): AniList for
 * anime, TMDB for movies and shows, both when unknown (most modules don't say).
 * @param {any} manifest
 * @returns {{ anime: boolean, western: boolean }}
 */
export function matchTargets (manifest) {
  const type = String(manifest?.type || '').toLowerCase()
  // Tested apart: "anime/movies" searches both.
  const anime = /anime|manga|donghua/.test(type)
  const western = /movie|show|serie|tv|film|drama|cartoon/.test(type)
  if (anime && !western) return { anime: true, western: false }
  if (western && !anime) return { anime: false, western: true }
  return { anime: true, western: true }
}

// Version tags modules add at the end of titles: "Attack on Titan (Dub)", "Naruto Shippuden VF", "One Piece [VOSTFR]",
// "Dune (2021)". AniList and TMDB titles have none, so they are removed before searching and scoring.
const VERSION_TAG = /(?:\s*[([]\s*(?:(?:english|french|eng|fr)\s+)?(?:dub(?:bed)?|sub(?:bed)?|vf|vostfr|vost|vo|multi|uncensored|censored|(?:19|20)\d\d)\s*[)\]]|\s+(?:dub|sub|vf|vostfr|vost|multi)|\s*\[[^\]]*\])\s*$/i

/**
 * Title of a module result without its version tags (several in a row: "X (Dub) [HD]"); the title itself when that
 * would leave nothing.
 * @param {string} title
 */
export function cleanResultTitle (title) {
  let text = String(title || '').trim()
  for (let i = 0; i < 5; i++) {
    const next = text.replace(VERSION_TAG, '').trim()
    if (next === text || !next) break
    text = next
  }
  return text
}

/**
 * Best media for a result title among the candidates: the highest title score (aliases included), then the most
 * popular. null when nothing reaches MATCH_MIN_SCORE (better no match than another show).
 * @param {string[]} titles result title first, then its aliases
 * @param {any[]} candidates AniList / TMDB media
 */
export function pickBestMatch (titles, candidates) {
  const queries = (Array.isArray(titles) ? titles : [titles]).map(title => String(title || '').trim()).filter(Boolean)
  let best = null
  for (const media of Array.isArray(candidates) ? candidates : []) {
    if (!media?.id) continue
    let score = 0
    for (const query of queries) score = Math.max(score, scoreMedia(query, media))
    if (score < MATCH_MIN_SCORE) continue
    if (!best || score > best.score || (score === best.score && relevancePopularity(media) > relevancePopularity(best.media))) best = { media, score }
  }
  return best?.media || null
}

/**
 * Card media of a module result: no AniList / TMDB data, only what the module gives.
 * @param {{ key: string, manifest?: any }} ext
 * @param {{ title: string, href: string, image?: string }} result
 */
export function resultMedia (ext, result) {
  const title = String(result.title).trim()
  const image = typeof result.image === 'string' && /^https?:\/\//i.test(result.image) ? result.image : null
  return {
    id: `sora-${ext.key}-${result.href}`,
    isSora: true,
    sora: { extensionKey: ext.key, extensionName: ext.manifest?.sourceName || ext.key, href: result.href, title, image },
    title: { romaji: title, english: title, native: title, userPreferred: title },
    coverImage: { extraLarge: image, medium: image, color: null },
    bannerImage: image,
    synonyms: [],
    genres: [],
    tags: []
  }
}
