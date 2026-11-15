// Search relevance: pure title scoring (no imports) used by the search page "Relevance" sort, the local
// fuzzy matches merged into search results, the offline fallback search and the title resolver.
// Mirrored by ios-native/Tsumi/Services/SearchRelevance.swift: keep both rule sets identical.
// Tests: node common/modules/search/relevance.test.mjs
//
// Rules (query and title are normalised: NFKD, lower case, marks and apostrophes removed, "&" -> "and",
// every other non letter / digit run -> one space; "compact" = the words joined without spaces):
//   100 exact            title == query, or compact title == compact query
//    90 prefix           title starts with the query (or compact with compact)
//    80 phrase           the query is a run of whole words of the title
//    70 words            every query word is a title word (any order); words of 2+ letters may be a word prefix
//    60 substring        the compact query is inside the compact title
//    50 / 45 / 40 fuzzy  every query word is within its edit budget of a title word (or of its start);
//                        50 for 1 edit in total, 45 for 2, 40 for more
//    30 compact fuzzy    the compact query is within its edit budget of the compact title (or of its start)
//     0                  no match
// Edit budget of a word: 0 under 4 letters, 1 from 4, 2 from 8 (optimal string alignment distance, so a
// swap of two neighbouring letters is one edit). Synonyms score 5 less than main titles. Ranking: score,
// then popularity (TMDB popularity x 1000, like the mixed search), then the original order.

export const SCORE = Object.freeze({
  EXACT: 100,
  PREFIX: 90,
  PHRASE: 80,
  WORDS: 70,
  SUBSTRING: 60,
  FUZZY: 50,
  FUZZY_MIN: 40,
  COMPACT_FUZZY: 30,
  NONE: 0
})
export const SYNONYM_PENALTY = 5
/** Local fuzzy matches are only looked up from this many letters (compact query). */
export const LOCAL_MIN_QUERY_LENGTH = 3

const MARKS = /\p{M}/gu
const APOSTROPHES = /['`‘’ʼ]/g
const SEPARATORS = /[^\p{L}\p{N}]+/gu

/**
 * @param {string} text
 * @returns {string} normalised title: lower case words separated by single spaces
 */
export function normalizeTitle (text) {
  if (typeof text !== 'string' || !text) return ''
  return text.normalize('NFKD').toLowerCase().normalize('NFKD')
    .replace(MARKS, '')
    .replace(/ς/g, 'σ') // final sigma
    .replace(APOSTROPHES, '')
    .replace(/&/g, ' and ')
    .replace(SEPARATORS, ' ')
    .trim()
}

/** Edit budget of a word (or compact query) of `length` code points. */
export function maxEdits (length) {
  return length >= 8 ? 2 : length >= 4 ? 1 : 0
}

/**
 * @typedef {{ norm: string, padded: string, tokens: string[], compact: string, chars: string[], tokenChars: string[][], memo?: Map<string, number>[] }} Prepared
 */

/**
 * @param {string} text
 * @returns {Prepared}
 */
export function prepare (text) {
  const norm = normalizeTitle(text)
  const tokens = norm ? norm.split(' ') : []
  const compact = tokens.join('')
  return { norm, padded: ' ' + norm + ' ', tokens, compact, chars: Array.from(compact), tokenChars: tokens.map(token => Array.from(token)) }
}

let rowA = new Int32Array(64)
let rowB = new Int32Array(64)
let rowC = new Int32Array(64)

/**
 * Optimal string alignment distance between two code point arrays (`b` limited to its first `bLength`
 * items), capped at `max + 1`.
 * @param {string[]} a
 * @param {string[]} b
 * @param {number} max
 * @param {number} [bLength]
 */
export function editDistance (a, b, max, bLength = b.length) {
  const la = a.length
  const lb = Math.min(bLength, b.length)
  if (Math.abs(la - lb) > max) return max + 1
  if (!la || !lb) return Math.min(Math.max(la, lb), max + 1)
  if (rowA.length <= lb) {
    rowA = new Int32Array(lb + 1)
    rowB = new Int32Array(lb + 1)
    rowC = new Int32Array(lb + 1)
  }
  let previous2 = rowA
  let previous = rowB
  let current = rowC
  for (let j = 0; j <= lb; j++) previous[j] = j
  for (let i = 1; i <= la; i++) {
    current[0] = i
    let rowMin = i
    for (let j = 1; j <= lb; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      let value = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) value = Math.min(value, previous2[j - 2] + 1)
      current[j] = value
      if (value < rowMin) rowMin = value
    }
    // Later rows never go below the smallest value of this one: stop once it is over the budget.
    if (rowMin > max) return max + 1
    const recycled = previous2
    previous2 = previous
    previous = current
    current = recycled
  }
  return Math.min(previous[lb], max + 1)
}

/** Distance of a query word to a title word: 0 for equal or a prefix (2+ letters), else its edits (or the word start's). */
function wordDistance (token, tokenChars, word, wordChars) {
  if (word === token) return 0
  if (tokenChars.length >= 2 && word.startsWith(token)) return 0
  const max = maxEdits(tokenChars.length)
  if (!max || wordChars.length < tokenChars.length - max) return Infinity
  let distance = editDistance(tokenChars, wordChars, max)
  if (distance && wordChars.length > tokenChars.length) distance = Math.min(distance, editDistance(tokenChars, wordChars, max, tokenChars.length))
  return distance <= max ? distance : Infinity
}

/**
 * Score of one title for a query (both prepared).
 * @param {Prepared} query
 * @param {Prepared} title
 * @returns {number}
 */
export function scoreTitle (query, title) {
  if (!query.compact || !title.compact) return SCORE.NONE
  if (title.norm === query.norm || title.compact === query.compact) return SCORE.EXACT
  if (title.norm.startsWith(query.norm) || title.compact.startsWith(query.compact)) return SCORE.PREFIX
  if (title.padded.includes(query.padded)) return SCORE.PHRASE
  if (query.tokens.every((token, index) => title.tokens.some(word => word === token || (query.tokenChars[index].length >= 2 && word.startsWith(token))))) return SCORE.WORDS
  if (title.compact.includes(query.compact)) return SCORE.SUBSTRING
  // Word distances repeat across titles: memoised per query word.
  const memo = query.memo || (query.memo = query.tokens.map(() => new Map()))
  let edits = 0
  let fuzzy = true
  for (let index = 0; index < query.tokens.length; index++) {
    let best = Infinity
    for (let w = 0; w < title.tokens.length && best > 0; w++) {
      const word = title.tokens[w]
      let distance = memo[index].get(word)
      if (distance === undefined) {
        distance = wordDistance(query.tokens[index], query.tokenChars[index], word, title.tokenChars[w])
        memo[index].set(word, distance)
      }
      if (distance < best) best = distance
    }
    if (best === Infinity) {
      fuzzy = false
      break
    }
    edits += best
  }
  if (fuzzy) return Math.max(SCORE.FUZZY_MIN, SCORE.FUZZY - 5 * Math.max(0, edits - 1))
  const max = maxEdits(query.chars.length)
  if (max) {
    let distance = editDistance(query.chars, title.chars, max)
    if (distance > max && title.chars.length > query.chars.length) distance = editDistance(query.chars, title.chars, max, query.chars.length)
    if (distance <= max) return SCORE.COMPACT_FUZZY
  }
  return SCORE.NONE
}

const preparedTitles = new WeakMap()

/**
 * Prepared main titles and synonyms of a media (cached per media object).
 * @param {{ title?: Record<string, string>, synonyms?: string[] }} media
 * @returns {{ main: Prepared[], synonyms: Prepared[] }}
 */
export function prepareMedia (media) {
  const titles = [media?.title?.romaji, media?.title?.english, media?.title?.native, media?.title?.userPreferred].filter(title => typeof title === 'string' && title)
  const synonyms = (Array.isArray(media?.synonyms) ? media.synonyms : []).filter(title => typeof title === 'string' && title)
  const signature = titles.join('\n') + '\n\n' + synonyms.join('\n')
  const cached = media && typeof media === 'object' ? preparedTitles.get(media) : null
  if (cached?.signature === signature) return cached.prepared
  const unique = list => {
    const seen = new Set()
    return list.map(prepare).filter(item => item.compact && !seen.has(item.norm) && seen.add(item.norm))
  }
  const prepared = { main: unique(titles), synonyms: unique(synonyms) }
  if (media && typeof media === 'object') preparedTitles.set(media, { signature, prepared })
  return prepared
}

/**
 * Best score of a media's titles (romaji, English, native, userPreferred; synonyms minus 5).
 * @param {string | Prepared} query
 * @param {object} media
 * @returns {number}
 */
export function scoreMedia (query, media) {
  const prepared = typeof query === 'string' ? prepare(query) : query
  if (!prepared?.compact || !media) return SCORE.NONE
  const titles = prepareMedia(media)
  let best = SCORE.NONE
  for (const title of titles.main) {
    best = Math.max(best, scoreTitle(prepared, title))
    if (best === SCORE.EXACT) return best
  }
  for (const title of titles.synonyms) {
    const score = scoreTitle(prepared, title)
    if (score > SCORE.NONE) best = Math.max(best, score - SYNONYM_PENALTY)
  }
  return best
}

/** Popularity tie-break: TMDB popularity is scaled like the mixed AniList / TMDB search. */
export function relevancePopularity (media) {
  const popularity = Number(media?.popularity) || 0
  return media?.isTmdb ? popularity * 1000 : popularity
}

/**
 * Sorts media by relevance to the query: score, then popularity, then the original order.
 * @template T
 * @param {string} query
 * @param {T[]} list
 * @returns {T[]}
 */
export function rankByRelevance (query, list) {
  const prepared = prepare(query)
  return (list || []).filter(Boolean)
    .map((media, index) => ({ media, index, score: scoreMedia(prepared, media), popularity: relevancePopularity(media) }))
    .sort((a, b) => (b.score - a.score) || (b.popularity - a.popularity) || (a.index - b.index))
    .map(({ media }) => media)
}

/**
 * Media of `list` matching the query (score above 0), best first, at most `limit`.
 * Empty when the compact query has fewer than LOCAL_MIN_QUERY_LENGTH letters.
 * @template T
 * @param {string} query
 * @param {T[]} list
 * @param {{ limit?: number, minScore?: number }} [options]
 * @returns {{ media: T, score: number }[]}
 */
export function fuzzyMatches (query, list, { limit = 20, minScore = 1 } = {}) {
  const prepared = prepare(query)
  if (prepared.chars.length < LOCAL_MIN_QUERY_LENGTH) return []
  return (list || []).filter(Boolean)
    .map((media, index) => ({ media, index, score: scoreMedia(prepared, media), popularity: relevancePopularity(media) }))
    .filter(entry => entry.score >= minScore)
    .sort((a, b) => (b.score - a.score) || (b.popularity - a.popularity) || (a.index - b.index))
    .slice(0, limit)
    .map(({ media, score }) => ({ media, score }))
}

/**
 * Whether a search sorts by relevance: a text query with no sort (or SEARCH_MATCH).
 * @param {{ search?: string, sort?: string | string[] }} variables
 */
export function isRelevanceSort (variables) {
  const sort = Array.isArray(variables?.sort) ? variables.sort[0] : variables?.sort
  return !!(typeof variables?.search === 'string' && prepare(variables.search).compact) && (!sort || sort === 'SEARCH_MATCH')
}

/**
 * Whether one of the media's titles or synonyms is exactly the query (normalised, spaces ignored).
 * @param {string | Prepared} query
 * @param {object} media
 */
export function isExactTitleMatch (query, media) {
  const prepared = typeof query === 'string' ? prepare(query) : query
  if (!prepared?.compact || !media) return false
  const titles = prepareMedia(media)
  return titles.main.some(title => title.compact === prepared.compact) || titles.synonyms.some(title => title.compact === prepared.compact)
}
