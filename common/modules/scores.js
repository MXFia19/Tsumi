// List scores are kept on the 0-10 scale everywhere in the app: AniList entries are queried with
// score(format: POINT_10) (media queries and the SaveMediaListEntry answer) and MyAnimeList scores are integers 0-10.
// AniList mutations take scoreRaw (0-100), MyAnimeList takes an integer 0-10.
// Pure module, tested by scores.test.mjs.

/**
 * Score on the 0-10 scale of the app, 0 when there is none (null, NaN, negative). Values above 10 are clamped.
 * @param {any} score
 */
export function normalizeScore (score) {
  const number = Number(score)
  if (!Number.isFinite(number) || number <= 0) return 0
  return Math.min(number, 10)
}

/**
 * AniList scoreRaw (0-100) of a 0-10 score.
 * @param {any} score
 */
export function toAniListRawScore (score) {
  return Math.round(normalizeScore(score) * 10)
}

/**
 * 0-10 score of an AniList scoreRaw (0-100).
 * @param {any} raw
 */
export function fromAniListRawScore (raw) {
  const number = Number(raw)
  if (!Number.isFinite(number) || number <= 0) return 0
  return Math.min(number, 100) / 10
}

/**
 * MyAnimeList score (integer 0-10) of a 0-10 score.
 * @param {any} score
 */
export function toMalScore (score) {
  return Math.round(normalizeScore(score))
}
