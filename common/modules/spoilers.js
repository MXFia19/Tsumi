// Spoiler protection (Settings > Interface > Spoiler Protection), adapted from the "Spoiler Control" of Shiru 6.6.0.
// A level (each one includes everything from the level before it) applies to the titles whose list status is
// selected; episode content is only hidden after the list progress. Pure functions (no store access), tested by
// spoilers.test.mjs and mirrored by ios-native/Tsumi/Core/SpoilerProtection.swift.

/** [label, value] of the levels, Off first (the default). */
export const SPOILER_LEVELS = [['Off', 'off'], ['Minimal', 'minimal'], ['Moderate', 'moderate'], ['Strict', 'strict'], ['Hermit', 'hermit']]

export const NOT_ON_LIST = 'NOTONLIST'

/** [label, value] of the list statuses protection can apply to. Completed is left out: nothing is left to spoil. */
export const SPOILER_STATUSES = [['Watching', 'CURRENT'], ['Rewatching', 'REPEATING'], ['Planning', 'PLANNING'], ['Paused', 'PAUSED'], ['Dropped', 'DROPPED'], ['Not on List', NOT_ON_LIST]]

export const DEFAULT_SPOILER_STATUS = ['CURRENT', 'REPEATING']

/** Shown instead of a hidden episode title or description, or of a hidden synopsis. */
export const SPOILER_TEXT = 'Hidden to avoid spoilers'

export const SPOILER_DESCRIPTION = 'Hides what you have not watched yet, for the titles whose list status is selected below. Episode content is only hidden after your progress, and each level includes everything from the level before it.\n\n' +
  'Minimal hides the thumbnails of the episodes you have not watched.\n' +
  'Moderate also hides their descriptions, the review count, and the tags marked as spoilers for the title.\n' +
  'Strict also hides their titles, the synopsis and rating of the title (next seasons and sequels too when their status is selected), and the tags marked as general spoilers.\n' +
  'Hermit also hides episode durations and the length of the title.'

export const SPOILER_STATUS_DESCRIPTION = 'Spoiler protection only applies to titles with one of these list statuses, everything else shows normally. For example, with only "Watching", the series you are currently watching are protected. Add "Planning" or "Not on List" to also protect the next seasons and sequels you have not started.'

const RANKS = { off: 0, minimal: 1, moderate: 2, strict: 3, hermit: 4 }

/** Lowest level hiding each item. */
export const SPOILER_ITEMS = Object.freeze({
  episodeImage: 'minimal',
  episodeDescription: 'moderate',
  reviews: 'moderate',
  mediaSpoilerTags: 'moderate',
  episodeTitle: 'strict',
  synopsis: 'strict',
  rating: 'strict',
  generalSpoilerTags: 'strict',
  duration: 'hermit'
})

/**
 * The selected level ('off' when missing or unknown).
 * @param {{ spoilers?: string } | null | undefined} settings
 */
export function spoilerLevel (settings) {
  const level = settings?.spoilers
  return typeof level === 'string' && Object.hasOwn(RANKS, level) ? level : 'off'
}

/**
 * The level hides this item at all (whatever the title).
 * @param {keyof typeof SPOILER_ITEMS} item
 * @param {{ spoilers?: string } | null | undefined} settings
 */
export function levelHides (item, settings) {
  const minimum = SPOILER_ITEMS[item]
  if (!minimum) return false
  return RANKS[spoilerLevel(settings)] >= RANKS[minimum]
}

/** List status of a title, 'NOTONLIST' without a list entry. */
export function spoilerListStatus (media) {
  return media?.mediaListEntry?.status || NOT_ON_LIST
}

/**
 * Protection is on and applies to the list status of this title.
 * @param {any} media
 * @param {{ spoilers?: string, spoilerStatus?: string[] } | null | undefined} settings
 */
export function isProtected (media, settings) {
  if (spoilerLevel(settings) === 'off') return false
  const statuses = Array.isArray(settings?.spoilerStatus) ? settings.spoilerStatus : []
  return statuses.includes(spoilerListStatus(media))
}

/**
 * The episode comes after the list progress. `episode` is counted like the progress (+1 when the series has an
 * episode 0); anything that is not a number (batch, unknown episode) is not an episode to protect.
 */
export function isUnwatched (media, episode) {
  const number = typeof episode === 'string' && episode.trim() !== '' ? Number(episode) : episode
  if (typeof number !== 'number' || !Number.isFinite(number)) return false
  const progress = Number(media?.mediaListEntry?.progress) || 0
  return progress < number
}

/**
 * Series content (synopsis, rating, review count, length, spoiler tags) of a protected title.
 * @param {keyof typeof SPOILER_ITEMS} item
 */
export function hidesMedia (item, media, settings) {
  return levelHides(item, settings) && isProtected(media, settings)
}

/**
 * Content of an episode after the progress of a protected title (thumbnail, description, title, duration).
 * @param {keyof typeof SPOILER_ITEMS} item
 */
export function hidesEpisode (item, media, episode, settings) {
  return levelHides(item, settings) && isProtected(media, settings) && isUnwatched(media, episode)
}

/**
 * AniList tags marked as spoilers: for this title (isMediaSpoiler) from Moderate, in general (isGeneralSpoiler) from Strict.
 * @param {{ isMediaSpoiler?: boolean, isGeneralSpoiler?: boolean } | null | undefined} tag
 */
export function hidesTag (tag, media, settings) {
  if (tag?.isMediaSpoiler && hidesMedia('mediaSpoilerTags', media, settings)) return true
  return !!tag?.isGeneralSpoiler && hidesMedia('generalSpoilerTags', media, settings)
}

/**
 * Episode cards of the feeds show the banner / cover instead of the episode image. Tsumi always did it for the titles
 * you watch, rewatch, paused or plan before you reach the episode (kept as is when protection is off); protection
 * adds the statuses selected in its setting.
 */
export function hidesEpisodeThumbnail (media, episode, settings) {
  const entry = media?.mediaListEntry
  if (entry?.status && ['CURRENT', 'REPEATING', 'PAUSED', 'PLANNING'].includes(entry.status) && entry.progress < episode) return true
  return hidesEpisode('episodeImage', media, episode, settings)
}

/** The text, or the spoiler placeholder when it is hidden (an empty text stays empty). */
export function spoilerText (text, hidden) {
  return hidden && text ? SPOILER_TEXT : text
}
