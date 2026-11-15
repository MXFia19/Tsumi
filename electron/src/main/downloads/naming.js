// Pure naming helpers of the offline downloads (unit tested by naming.test.mjs).

/** Folder / file name safe on Windows, macOS and Linux (no reserved characters, names or trailing dots). */
export function sanitizeName (name, fallback = 'Untitled') {
  let safe = String(name ?? '')
    // eslint-disable-next-line no-control-regex
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/, '')
  if (/^(con|prn|aux|nul|com\d|lpt\d)$/i.test(safe)) safe = `_${safe}`
  if (safe.length > 80) safe = safe.slice(0, 80).trim().replace(/[. ]+$/, '')
  return safe || fallback
}

const pad = (value) => String(value).padStart(2, '0')

/** "Episode 05", or "S02E05" for a season episode (TMDB shows). */
export function episodeLabel (episode = {}) {
  if (episode.season != null && episode.localEpisode != null) return `S${pad(episode.season)}E${pad(episode.localEpisode)}`
  return `Episode ${pad(Number(episode.number) || 0)}`
}

/** Stable id of one episode download: media id + season + episode. */
export function downloadId (mediaId, episode = {}) {
  const media = String(mediaId ?? 'media').replace(/[^a-zA-Z0-9_-]/g, '_')
  const season = episode.season != null ? episode.season : 0
  const number = episode.season != null && episode.localEpisode != null ? episode.localEpisode : (Number(episode.number) || 0)
  return `${media}-s${season}-e${number}`
}

/** Subtitle file extension from its URL, content type or first bytes. */
export function subtitleExtension (url = '', contentType = '', text = '') {
  const fromUrl = (() => {
    try {
      return new URL(url).pathname.split('.').pop()?.toLowerCase()
    } catch {
      return ''
    }
  })()
  if (['vtt', 'srt', 'ass', 'ssa'].includes(fromUrl)) return fromUrl
  if (/vtt/i.test(contentType) || /^\s*WEBVTT/.test(text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text)) return 'vtt'
  if (/\[Script Info\]/i.test(text)) return 'ass'
  return 'srt'
}

/** Video file extension from the content type / URL of a direct download. */
export function videoExtension (url = '', contentType = '') {
  if (/matroska|mkv/i.test(contentType)) return 'mkv'
  if (/webm/i.test(contentType)) return 'webm'
  if (/mp2t/i.test(contentType)) return 'ts'
  try {
    const extension = new URL(url).pathname.split('.').pop()?.toLowerCase()
    if (['mp4', 'm4v', 'mkv', 'webm', 'mov'].includes(extension)) return extension
  } catch {}
  return 'mp4'
}

/** Total size from a Content-Range header ("bytes 0-99/1234"), null when unknown. */
export function totalFromContentRange (value = '') {
  const match = /\/(\d+)\s*$/.exec(value || '')
  return match ? Number(match[1]) : null
}

/** Message for an HTTP failure of the source. */
export function httpErrorMessage (status) {
  if (status === 401 || status === 403) return `The source refused the download (HTTP ${status}). The link may have expired: retry to get a fresh one.`
  if (status === 404 || status === 410) return `The source file is gone (HTTP ${status}). Retry to get a fresh link, or pick another source.`
  if (status === 429) return 'The source is rate limiting downloads (HTTP 429). Try again later.'
  return `The source answered HTTP ${status}.`
}
