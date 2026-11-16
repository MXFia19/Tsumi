// SRT / WebVTT / MicroDVD text -> ASS "Dialogue:" lines for the libass renderer (JASSUB), used by subtitles.js.
// Pure (no imports), tested by subconvert.test.mjs.

/** One SRT / WebVTT cue: optional numeric id, "start --> end [settings]", then the text. */
export const CUE_RX = /(?:\d+\r?\n)?(\S{9,12})\s?-->\s?(\S{9,12})(.*)\r?\n([\s\S]*)$/i
/** One MicroDVD line: "{start frame}{end frame}text". */
export const MICRODVD_RX = /[{[](\d+)[}\]][{[](\d+)[}\]](.+)/i

/** Frame rate used when a MicroDVD file does not give one (23.976 fps, as before). */
const DEFAULT_FPS = 1000 / 41.708

const pad = (value) => String(value).padStart(2, '0')

/**
 * "HH:MM:SS,mmm" (SRT), "HH:MM:SS.mmm" / "MM:SS.mmm" (WebVTT), "H:MM:SS.cc" -> whole milliseconds, NaN when unreadable.
 * @param {string} value
 */
export function parseCueTimeMs (value) {
  const match = String(value ?? '').trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d+))?$/)
  if (!match) return NaN
  const [, hours, minutes, seconds, fraction] = match
  const ms = fraction ? Number(fraction.slice(0, 3).padEnd(3, '0')) : 0
  return ((Number(hours || 0) * 60 + Number(minutes)) * 60 + Number(seconds)) * 1000 + ms
}

/**
 * Milliseconds -> "H:MM:SS.cc". libass reads the fraction as centiseconds: writing 3 digits ("0:00:01.500") makes it
 * read 1.5 s as 6 s, so the fraction is always truncated to 2 digits.
 * @param {number} ms
 */
export function assTime (ms) {
  const cs = Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 10) : 0
  const hours = Math.floor(cs / 360000)
  const minutes = Math.floor(cs / 6000) % 60
  const seconds = Math.floor(cs / 100) % 60
  return `${hours}:${pad(minutes)}:${pad(seconds)}.${pad(cs % 100)}`
}

/**
 * HTML-like cue text -> ASS text: <b> <i> <u> <s> become override tags, other tags (font, WebVTT classes and
 * timestamps) are dropped, entities are decoded and line breaks become \N.
 * @param {string} text
 */
export function cueTextToAss (text) {
  return String(text ?? '')
    .replace(/\n+$/, '')
    .replace(/<(\/?)([^>\s/]*)[^>]*>/g, (_, closing, tag) => {
      const name = tag.toLowerCase()
      return ['b', 'i', 'u', 's'].includes(name) ? `{\\${name}${closing ? 0 : 1}}` : ''
    })
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, '\\h')
    .replace(/&amp;/g, '&')
    .replace(/\n/g, '\\N')
}

const dialogue = (startMs, endMs, text) => `Dialogue: 0,${assTime(startMs)},${assTime(endMs)},Default,,0,0,0,,${text}`

/**
 * SRT or WebVTT text -> ASS dialogue lines (unreadable cues are skipped).
 * @param {string} text
 */
export function srtToAss (text) {
  const lines = []
  for (const block of String(text ?? '').replace(/\r/g, '').split(/\n\n+/)) {
    const match = block.match(CUE_RX)
    if (!match) continue
    const start = parseCueTimeMs(match[1])
    const end = parseCueTimeMs(match[2])
    if (!Number.isFinite(start) || !Number.isFinite(end)) continue
    lines.push(dialogue(start, end, cueTextToAss(match[4])))
  }
  return lines
}

/**
 * MicroDVD (.sub) text -> ASS dialogue lines. A first line whose text is only a number ("{1}{1}23.976") gives the
 * frame rate and is not shown.
 * @param {string} text
 * @param {number} [fallbackFps]
 */
export function microDvdToAss (text, fallbackFps = DEFAULT_FPS) {
  const rows = String(text ?? '').replace(/\r/g, '').split('\n')
  const lines = []
  let fps = fallbackFps
  let first = true
  for (const row of rows) {
    const match = row.match(MICRODVD_RX)
    if (!match) continue
    if (first) {
      first = false
      const rate = Number(match[3].trim())
      if (/^\d+(\.\d+)?$/.test(match[3].trim()) && rate > 1 && rate < 200) {
        fps = rate
        continue
      }
    }
    const start = Number(match[1]) * 1000 / fps
    const end = Number(match[2]) * 1000 / fps
    lines.push(dialogue(start, end, match[3].replace(/\|/g, '\\N')))
  }
  return lines
}

/**
 * Subtitle file text -> what the renderer takes: the ASS script itself (string) for ASS / SSA, ASS dialogue lines
 * (string[]) for the other formats, undefined when the text is not a subtitle file.
 * @param {string} text
 * @param {string} type file extension
 * @returns {string | string[] | undefined}
 */
export function convertSubText (text, type) {
  const kind = String(type || '').toLowerCase()
  if (kind === 'ass' || kind === 'ssa') return text
  if (kind === 'srt' || kind === 'vtt') return srtToAss(text)
  if (kind === 'sub') return microDvdToAss(text)
  // Subbers have a tendency to not set the extensions properly (and pasted text has none).
  if (/^\s*\[Script Info\]/i.test(text)) return text
  if (CUE_RX.test(text)) return srtToAss(text)
  if (MICRODVD_RX.test(text)) return microDvdToAss(text)
}
