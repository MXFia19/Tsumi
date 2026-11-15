// HLS helpers of the Cast proxy (pure, tested by hls.test.mjs): playlist detection, URL rewriting so every
// variant / segment / key / map goes through the proxy, and the segment format the Cast receiver needs to know.

function stripBom (text) {
  const value = String(text || '')
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value
}

/** True when the bytes start like an M3U8 playlist (BOM and leading whitespace allowed). */
export function isPlaylistStart (bytes) {
  if (!bytes || !bytes.length) return false
  const text = stripBom(Buffer.from(bytes.subarray(0, 32)).toString('utf8')).trimStart()
  return text.startsWith('#EXTM3U')
}

/** Absolute http(s) URL of a playlist reference, or null for data:, skd: and other schemes left as they are. */
export function resolveUri (uri, base) {
  const value = String(uri || '').trim()
  if (!value) return null
  try {
    const url = new URL(value, base)
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null
  } catch {
    return null
  }
}

/**
 * Rewrites a playlist: URI="..." attributes of tags (EXT-X-KEY, EXT-X-MAP, EXT-X-MEDIA, EXT-X-I-FRAME-STREAM-INF,
 * EXT-X-PART, EXT-X-PRELOAD-HINT, EXT-X-SESSION-KEY...) and the URI lines (variants, segments).
 * @param {string} text
 * @param {string} baseUrl final URL of the playlist (relative references resolve against it)
 * @param {(absoluteUrl: string) => string} toProxy
 */
export function rewritePlaylist (text, baseUrl, toProxy) {
  return stripBom(text).split(/\r?\n/).map(line => {
    const trimmed = line.trim()
    if (!trimmed) return line
    if (trimmed.startsWith('#')) {
      if (!/URI=/i.test(trimmed)) return line
      return line.replace(/([:,]\s*)URI=(?:"([^"]*)"|'([^']*)'|([^,\s"']+))/gi, (match, prefix, double, single, bare) => {
        const absolute = resolveUri(double ?? single ?? bare, baseUrl)
        return absolute ? `${prefix}URI="${toProxy(absolute)}"` : match
      })
    }
    const absolute = resolveUri(trimmed, baseUrl)
    return absolute ? toProxy(absolute) : line
  }).join('\n')
}

/** Variant playlists of a master playlist (absolute URLs, in order), empty for a media playlist. */
export function variantUrls (text, baseUrl) {
  const lines = String(text).split(/\r?\n/).map(line => line.trim())
  const variants = []
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue
    for (let j = i + 1; j < lines.length; j++) {
      if (!lines[j] || lines[j].startsWith('#')) continue
      const absolute = resolveUri(lines[j], baseUrl)
      if (absolute) variants.push(absolute)
      i = j
      break
    }
  }
  return variants
}

/**
 * Segment format of a media playlist for the Cast LOAD request (hlsSegmentFormat / hlsVideoSegmentFormat).
 * fMP4 when the playlist has an initialization section (EXT-X-MAP) or .mp4/.m4s segments, raw audio for
 * .aac / .mp3 segments, MPEG-TS otherwise (including segments disguised with an image extension).
 */
export function segmentFormat (text) {
  const lines = String(text).split(/\r?\n/).map(line => line.trim())
  if (lines.some(line => line.startsWith('#EXT-X-MAP'))) return { segment: 'fmp4', video: 'fmp4' }
  const first = lines.find(line => line && !line.startsWith('#'))
  const extension = (first || '').split(/[?#]/)[0].split('.').pop()?.toLowerCase()
  if (extension === 'mp4' || extension === 'm4s' || extension === 'm4v' || extension === 'cmfv') return { segment: 'fmp4', video: 'fmp4' }
  if (extension === 'aac') return { segment: 'aac', video: null }
  if (extension === 'mp3') return { segment: 'mp3', video: null }
  return { segment: 'ts', video: 'mpeg2_ts' }
}

/** Content type for a progressive file, from the server answer or the URL extension. */
export function fileContentType (contentType, url) {
  const type = String(contentType || '').split(';')[0].trim().toLowerCase()
  if (type.startsWith('video/') || type.startsWith('audio/')) return type
  const extension = String(url || '').split(/[?#]/)[0].split('.').pop()?.toLowerCase()
  const byExtension = { mp4: 'video/mp4', m4v: 'video/mp4', webm: 'video/webm', mkv: 'video/x-matroska', mov: 'video/quicktime', ts: 'video/mp2t', mp3: 'audio/mpeg', m4a: 'audio/mp4' }
  return byExtension[extension] || 'video/mp4'
}
