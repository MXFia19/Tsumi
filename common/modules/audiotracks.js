// Audio tracks of the PC player (routes/player/PlayerPage.svelte): the HLS audio renditions of hls.js (VF / VO in the
// same stream) and the tracks of a video file. Pure helpers, tested by audiotracks.test.mjs. iOS:
// ios-native/Tsumi/Player/PlayerController.swift (selectPreferredAudio).
import { subtitleLanguageCode } from './extensionUtils.js'
import { languageName } from './onlinesubs/core.js'

/** ISO 639-1 code of a track language or setting ("fre", "fr-FR", "jpn"), '' when unknown. */
export const audioLanguageCode = (lang) => subtitleLanguageCode(lang)

/**
 * Menu label of a track: its name, with the language when the name does not already say it ("VF (French)"), else
 * the language, else "Track 2".
 * @param {{ name?: string, lang?: string }} track
 * @param {number} index
 */
export function audioTrackLabel (track, index) {
  const name = String(track?.name || '').trim()
  const lang = String(track?.lang || '').trim()
  const code = audioLanguageCode(lang)
  const language = code ? languageName(code) : lang
  if (!name) return language || `Track ${index + 1}`
  const lower = name.toLowerCase()
  if (!language || lower.includes(language.toLowerCase()) || (lang && lower.includes(lang.toLowerCase()))) return name
  return `${name} (${language})`
}

/**
 * Menu entries of hls.js audio tracks ({ name, lang } MediaPlaylist objects): { index, label } in the stream order.
 * @param {{ name?: string, lang?: string }[]} tracks
 */
export function audioTrackOptions (tracks) {
  if (!Array.isArray(tracks)) return []
  return tracks.map((track, index) => ({ index, label: audioTrackLabel(track, index) }))
}

/**
 * Track to start with (index in `tracks`), -1 to keep the one the stream starts with: the one remembered for the show
 * (same name and language, else same language, else same name), then the preferred audio language, then Japanese.
 * @param {{ name?: string, lang?: string }[]} tracks
 * @param {{ remembered?: { name?: string, lang?: string } | null, preferred?: string }} [options]
 */
export function pickAudioTrack (tracks, { remembered = null, preferred = '' } = {}) {
  if (!Array.isArray(tracks) || tracks.length < 2) return -1
  const name = (track) => String(track?.name || '').trim().toLowerCase()
  const sameLanguage = (lang, wanted) => {
    const code = audioLanguageCode(lang)
    return !!code && code === audioLanguageCode(wanted)
  }
  if (remembered && (remembered.name || remembered.lang)) {
    const wantedName = name(remembered)
    const exact = tracks.findIndex(track => name(track) === wantedName && (!remembered.lang || sameLanguage(track?.lang, remembered.lang)))
    if (exact !== -1) return exact
    const byLanguage = remembered.lang ? tracks.findIndex(track => sameLanguage(track?.lang, remembered.lang)) : -1
    if (byLanguage !== -1) return byLanguage
    const byName = wantedName ? tracks.findIndex(track => name(track) === wantedName) : -1
    if (byName !== -1) return byName
  }
  for (const wanted of [preferred, 'jpn']) {
    if (!wanted) continue
    const index = tracks.findIndex(track => sameLanguage(track?.lang, wanted))
    if (index !== -1) return index
  }
  return -1
}
