// WebVTT conversion of the player's subtitle tracks (Chromecast text tracks). ASS styling is dropped: positioned
// lines become plain cues, italic / bold / underline are kept. Pure, tested by vtt.test.mjs.

const NBSP = String.fromCharCode(0xa0)

/** Removes a leading byte order mark. */
export function stripBom (text) {
  const value = String(text || '')
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value
}

/** "H:MM:SS.cc" (ASS), "HH:MM:SS,mmm" (SRT), "MM:SS.mmm" -> seconds (NaN when unreadable). */
export function parseTimestamp (value) {
  const match = String(value || '').trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$/)
  if (!match) return NaN
  const [, hours, minutes, seconds, fraction] = match
  const ms = fraction ? Number(fraction.padEnd(3, '0')) : 0
  return Number(hours || 0) * 3600 + Number(minutes) * 60 + Number(seconds) + ms / 1000
}

export function formatTimestamp (seconds) {
  const total = Math.max(0, Math.round((Number(seconds) || 0) * 1000))
  const ms = total % 1000
  const s = Math.floor(total / 1000) % 60
  const m = Math.floor(total / 60000) % 60
  const h = Math.floor(total / 3600000)
  const pad = (n, size = 2) => String(n).padStart(size, '0')
  return `${pad(h)}:${pad(m)}:${pad(s)}.${pad(ms, 3)}`
}

const escapeText = (text) => text.replace(/&(?![a-z]+;|#\d+;|#x[0-9a-f]+;)/gi, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const normalize = (text) => text.split('\n').map(line => line.trim()).filter(Boolean).join('\n').replace(/<(\w)><\/\1>/g, '')

function convertAss (text) {
  const open = { i: false, b: false, u: false }
  let drawing = false
  let output = ''
  const source = String(text || '')
  const pattern = /\{([^}]*)\}/g
  let last = 0
  const emitText = (chunk) => {
    if (drawing || !chunk) return
    output += escapeText(chunk.replace(/\\[Nn]/g, '\n').replace(/\\h/g, NBSP))
  }
  for (let match = pattern.exec(source); match; match = pattern.exec(source)) {
    emitText(source.slice(last, match.index))
    last = pattern.lastIndex
    for (const tag of match[1].split('\\').slice(1)) {
      const style = tag.match(/^([ibu])(\d+)$/)
      if (style) {
        const [, name, value] = style
        const on = name === 'b' ? Number(value) !== 0 : value === '1'
        if (on && !open[name]) output += `<${name}>`
        if (!on && open[name]) output += `</${name}>`
        open[name] = on
        continue
      }
      const draw = tag.match(/^p(\d+)$/)
      if (draw) drawing = Number(draw[1]) > 0
      if (tag === 'r') {
        for (const name of ['u', 'b', 'i']) {
          if (open[name]) output += `</${name}>`
          open[name] = false
        }
      }
    }
  }
  emitText(source.slice(last))
  for (const name of ['u', 'b', 'i']) if (open[name]) output += `</${name}>`
  return output
}

/** Text of an ASS event as WebVTT cue text: override blocks removed (italic/bold/underline kept), drawings dropped. */
export function assTextToVtt (text) {
  return normalize(convertAss(text))
}

/** SRT / WebVTT-like cue text: keeps <i>, <b>, <u>, drops other tags (<font>...), escapes the rest. */
export function srtTextToVtt (text) {
  const tokens = String(text || '').split(/(<\/?[a-z][^>]*>)/gi)
  let output = ''
  for (const token of tokens) {
    const tag = token.match(/^<(\/?)([a-z]+)[^>]*>$/i)
    if (tag) {
      const name = tag[2].toLowerCase()
      if (['i', 'b', 'u'].includes(name)) output += `<${tag[1]}${name}>`
      continue
    }
    // ASS-style tags inside SRT ({\an8}, {\i1}) are common too.
    output += convertAss(token)
  }
  return normalize(output)
}

/** Cues from SRT (or WebVTT) text. */
export function parseSrt (text) {
  const cues = []
  const blocks = stripBom(text).replace(/\r\n?/g, '\n').split(/\n\s*\n/)
  for (const block of blocks) {
    const lines = block.split('\n')
    const index = lines.findIndex(line => line.includes('-->'))
    if (index === -1) continue
    const [startText, rest] = lines[index].split('-->')
    const start = parseTimestamp(startText)
    const end = parseTimestamp(String(rest).trim().split(/\s+/)[0])
    if (!isFinite(start) || !isFinite(end)) continue
    const cueText = srtTextToVtt(lines.slice(index + 1).join('\n'))
    if (cueText) cues.push({ start, end, text: cueText })
  }
  return cues
}

/** Cues from the [Events] of an ASS / SSA script (uses its Format line). */
export function parseAssEvents (text) {
  const cues = []
  let format = ['layer', 'start', 'end', 'style', 'name', 'marginl', 'marginr', 'marginv', 'effect', 'text']
  let inEvents = false
  for (const raw of stripBom(text).split(/\r?\n/)) {
    const line = raw.trim()
    if (/^\[.*\]$/.test(line)) {
      inEvents = /^\[events\]$/i.test(line)
      continue
    }
    if (!inEvents) continue
    if (/^format:/i.test(line)) {
      format = line.slice(7).split(',').map(field => field.trim().toLowerCase())
      continue
    }
    if (!/^dialogue:/i.test(line)) continue
    const values = []
    let rest = line.slice(line.indexOf(':') + 1)
    for (let i = 0; i < format.length - 1; i++) {
      const comma = rest.indexOf(',')
      if (comma === -1) break
      values.push(rest.slice(0, comma).trim())
      rest = rest.slice(comma + 1)
    }
    values.push(rest)
    const field = (name) => values[format.indexOf(name)]
    const start = parseTimestamp(field('start'))
    const end = parseTimestamp(field('end'))
    if (!isFinite(start) || !isFinite(end)) continue
    const cueText = assTextToVtt(field('text'))
    if (cueText) cues.push({ start, end, text: cueText })
  }
  return cues
}

/**
 * WebVTT document from cues. `offset` is the player's subtitle offset in seconds (JASSUB timeOffset: positive
 * values show subtitles earlier). Identical overlapping cues (layered ASS lines) are merged.
 */
export function cuesToVtt (cues, offset = 0) {
  const shift = Number(offset) || 0
  const seen = new Set()
  const lines = ['WEBVTT', '']
  const sorted = [...cues].sort((a, b) => a.start - b.start || a.end - b.end)
  for (const cue of sorted) {
    const start = Math.max(0, cue.start - shift)
    const end = cue.end - shift
    if (!(end > start) || !cue.text) continue
    const key = `${start.toFixed(3)}|${end.toFixed(3)}|${cue.text}`
    if (seen.has(key)) continue
    seen.add(key)
    lines.push(`${formatTimestamp(start)} --> ${formatTimestamp(end)}`, cue.text.replace(/-->/g, '->'), '')
  }
  return lines.join('\n')
}

export function srtToVtt (text, offset = 0) {
  return cuesToVtt(parseSrt(text), offset)
}

/**
 * A track of the player's Subtitles module: `header` is the ASS script (subtitle files are converted to ASS
 * Dialogue lines when added), `events` the parsed embedded events ({ Start, Duration } in ms, ASS Text).
 */
export function trackToVtt ({ header, events }, offset = 0) {
  const cues = parseAssEvents(header)
  for (const event of events || []) {
    const start = Number(event?.Start) / 1000
    const end = start + Number(event?.Duration) / 1000
    const cueText = assTextToVtt(event?.Text)
    if (isFinite(start) && isFinite(end) && cueText) cues.push({ start, end, text: cueText })
  }
  return cuesToVtt(cues, offset)
}

export function cueCount (vtt) {
  return (String(vtt).match(/-->/g) || []).length
}
