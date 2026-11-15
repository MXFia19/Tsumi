// Pure HLS helpers of the offline downloads (no Electron / fs imports, unit tested by hls.test.mjs).
// A downloaded HLS episode is a folder with the original playlists rewritten to point at local files:
// every segment, AES-128 key and init segment (EXT-X-MAP) is saved as its own file, byte ranges included.

/** Parses an attribute list: KEY=VALUE,KEY2="quoted, value". Keys are upper-cased. */
export function parseAttributes (text = '') {
  const attributes = {}
  const pattern = /([A-Z0-9-]+)\s*=\s*("[^"]*"|[^,]*)/gi
  let match
  while ((match = pattern.exec(text))) {
    let value = match[2].trim()
    if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1)
    attributes[match[1].toUpperCase()] = value
  }
  return attributes
}

function resolveUrl (uri, baseUrl) {
  try {
    return new URL(uri, baseUrl).href
  } catch {
    return uri
  }
}

function tagValue (line) {
  const index = line.indexOf(':')
  return index === -1 ? '' : line.slice(index + 1)
}

export function isMasterPlaylist (text = '') {
  return /#EXT-X-STREAM-INF/i.test(text)
}

export function isPlaylistText (text = '') {
  return /^\s*#EXTM3U/.test(text)
}

/**
 * Master playlist: variants (EXT-X-STREAM-INF + URI line) and renditions (EXT-X-MEDIA).
 * @returns {{ variants: Array<{ uri: string, bandwidth: number, averageBandwidth: number, width: number, height: number, codecs: string, audio: string, attributes: Record<string, string> }>, media: Array<{ type: string, groupId: string, name: string, language: string, isDefault: boolean, uri: string, attributes: Record<string, string> }>, independentSegments: boolean }}
 */
export function parseMasterPlaylist (text = '', baseUrl = '') {
  const lines = text.split(/\r?\n/)
  const variants = []
  const media = []
  let pending = null
  let independentSegments = false
  for (const raw of lines) {
    const line = raw.trim()
    if (!line) continue
    if (/^#EXT-X-INDEPENDENT-SEGMENTS/i.test(line)) independentSegments = true
    if (/^#EXT-X-STREAM-INF:/i.test(line)) {
      pending = parseAttributes(tagValue(line))
      continue
    }
    if (/^#EXT-X-MEDIA:/i.test(line)) {
      const attributes = parseAttributes(tagValue(line))
      media.push({
        type: (attributes.TYPE || '').toUpperCase(),
        groupId: attributes['GROUP-ID'] || '',
        name: attributes.NAME || '',
        language: attributes.LANGUAGE || '',
        isDefault: (attributes.DEFAULT || '').toUpperCase() === 'YES',
        uri: attributes.URI ? resolveUrl(attributes.URI, baseUrl) : '',
        attributes
      })
      continue
    }
    if (line.startsWith('#')) continue
    if (pending) {
      const [width, height] = (pending.RESOLUTION || '').split('x').map(Number)
      variants.push({
        uri: resolveUrl(line, baseUrl),
        bandwidth: Number(pending.BANDWIDTH) || 0,
        averageBandwidth: Number(pending['AVERAGE-BANDWIDTH']) || 0,
        width: width || 0,
        height: height || 0,
        codecs: pending.CODECS || '',
        audio: pending.AUDIO || '',
        attributes: pending
      })
      pending = null
    }
  }
  return { variants, media, independentSegments }
}

/** Download quality setting: highest, 1080, 720, 480, 360 or lowest. */
export const QUALITIES = ['highest', '1080', '720', '480', '360', 'lowest']

/**
 * Variant for a quality setting. A height limit takes the best variant at or under it (the lowest one when
 * all are taller); variants without RESOLUTION are ranked by bandwidth.
 */
export function pickVariant (variants = [], quality = 'highest') {
  const usable = variants.filter(variant => variant?.uri)
  if (!usable.length) return null
  const rank = (variant) => variant.height * 1e9 + (variant.bandwidth || variant.averageBandwidth)
  const sorted = [...usable].sort((a, b) => rank(a) - rank(b))
  if (quality === 'lowest') return sorted[0]
  const limit = Number(quality)
  if (!limit || !sorted.some(variant => variant.height)) return sorted[sorted.length - 1]
  const fitting = sorted.filter(variant => variant.height && variant.height <= limit)
  return fitting.length ? fitting[fitting.length - 1] : sorted.find(variant => variant.height) || sorted[0]
}

/** Audio rendition to keep with a variant (its AUDIO group: DEFAULT=YES, else the first one with a URI). */
export function pickAudioRendition (master, variant) {
  if (!variant?.audio) return null
  const group = master.media.filter(media => media.type === 'AUDIO' && media.groupId === variant.audio && media.uri)
  return group.find(media => media.isDefault) || group[0] || null
}

/** Why an encryption method cannot be saved (null when it can: none or AES-128 with a plain key). */
export function drmReason (attributes = {}) {
  const method = (attributes.METHOD || 'NONE').toUpperCase()
  if (method === 'NONE') return null
  const keyFormat = (attributes.KEYFORMAT || 'identity').toLowerCase()
  if (method === 'AES-128' && keyFormat === 'identity') return null
  return 'This stream is DRM-protected (' + method + (keyFormat !== 'identity' ? ', ' + keyFormat : '') + ') and can\'t be downloaded.'
}

const SEGMENT_EXTENSIONS = ['ts', 'm4s', 'mp4', 'm4v', 'm4a', 'aac', 'mp3', 'ac3', 'ec3', 'vtt', 'webvtt', 'cmfv', 'cmfa']

function segmentExtension (url) {
  try {
    const path = new URL(url).pathname
    const extension = path.split('.').pop()?.toLowerCase()
    if (extension && SEGMENT_EXTENSIONS.includes(extension)) return extension
  } catch {}
  return 'ts'
}

function parseByteRange (value) {
  const match = /^(\d+)(?:@(\d+))?$/.exec((value || '').trim())
  if (!match) return null
  return { length: Number(match[1]), offset: match[2] != null ? Number(match[2]) : null }
}

function replaceUri (line, uri) {
  return line.replace(/URI\s*=\s*"[^"]*"/i, `URI="${uri}"`).replace(/URI\s*=\s*(?!")[^,]*/i, `URI="${uri}"`)
}

function dropAttribute (line, name) {
  return line.replace(new RegExp(`,?${name}\\s*=\\s*("[^"]*"|[^,]*)`, 'i'), '').replace(':,', ':')
}

const DROPPED_TAGS = /^#EXT-X-(BYTERANGE|PART|PART-INF|PRELOAD-HINT|RENDITION-REPORT|SERVER-CONTROL|SKIP|SESSION-KEY):?/i

/**
 * Media playlist → files to download and the local playlist pointing at them.
 * `prefix` names the files of this playlist (v = video, a = audio) so two playlists can share a folder.
 * @returns {{ resources: Array<{ kind: 'segment'|'key'|'map', url: string, file: string, range: { start: number, end: number } | null }>, playlist: string, drm: string | null, duration: number, segmentCount: number, endList: boolean }}
 */
export function planMediaPlaylist (text = '', baseUrl = '', prefix = 'v') {
  const lines = text.split(/\r?\n/)
  const resources = []
  const out = []
  const keyFiles = new Map()
  const mapFiles = new Map()
  const rangeEnds = new Map()
  let drm = null
  let duration = 0
  let segmentCount = 0
  let endList = false
  let pendingRange = null

  for (const raw of lines) {
    const line = raw.trim()
    if (!line) continue
    if (line.startsWith('#')) {
      if (/^#EXT-X-ENDLIST/i.test(line)) endList = true
      if (/^#EXT-X-BYTERANGE:/i.test(line)) {
        pendingRange = parseByteRange(tagValue(line))
        continue
      }
      if (DROPPED_TAGS.test(line)) continue
      if (/^#EXTINF:/i.test(line)) duration += parseFloat(tagValue(line)) || 0
      if (/^#EXT-X-KEY:/i.test(line)) {
        const attributes = parseAttributes(tagValue(line))
        const reason = drmReason(attributes)
        if (reason) {
          drm = drm || reason
          out.push(line)
          continue
        }
        if ((attributes.METHOD || '').toUpperCase() === 'AES-128' && attributes.URI) {
          const url = resolveUrl(attributes.URI, baseUrl)
          if (!keyFiles.has(url)) {
            const file = `${prefix}-key-${keyFiles.size}.key`
            keyFiles.set(url, file)
            resources.push({ kind: 'key', url, file, range: null })
          }
          out.push(replaceUri(line, keyFiles.get(url)))
          continue
        }
        out.push(line)
        continue
      }
      if (/^#EXT-X-MAP:/i.test(line)) {
        const attributes = parseAttributes(tagValue(line))
        if (!attributes.URI) {
          out.push(line)
          continue
        }
        const url = resolveUrl(attributes.URI, baseUrl)
        const byteRange = parseByteRange(attributes.BYTERANGE)
        const range = byteRange ? { start: byteRange.offset || 0, end: (byteRange.offset || 0) + byteRange.length - 1 } : null
        const mapKey = url + (range ? `#${range.start}-${range.end}` : '')
        if (!mapFiles.has(mapKey)) {
          const file = `${prefix}-init-${mapFiles.size}.${segmentExtension(url) === 'ts' ? 'mp4' : segmentExtension(url)}`
          mapFiles.set(mapKey, file)
          resources.push({ kind: 'map', url, file, range })
        }
        out.push(replaceUri(dropAttribute(line, 'BYTERANGE'), mapFiles.get(mapKey)))
        continue
      }
      out.push(line)
      continue
    }
    // Segment URI.
    const url = resolveUrl(line, baseUrl)
    let range = null
    if (pendingRange) {
      const start = pendingRange.offset != null ? pendingRange.offset : (rangeEnds.get(url) || 0)
      range = { start, end: start + pendingRange.length - 1 }
      rangeEnds.set(url, range.end + 1)
      pendingRange = null
    }
    const file = `${prefix}-${String(segmentCount).padStart(5, '0')}.${segmentExtension(url)}`
    resources.push({ kind: 'segment', url, file, range })
    out.push(file)
    segmentCount++
  }
  if (!endList) out.push('#EXT-X-ENDLIST')
  return { resources, playlist: out.join('\n') + '\n', drm, duration, segmentCount, endList }
}

/** Local master playlist joining a video playlist and its separate audio rendition. */
export function buildLocalMaster ({ variant, audio, independentSegments }, videoFile = 'video.m3u8', audioFile = 'audio.m3u8') {
  const lines = ['#EXTM3U']
  if (independentSegments) lines.push('#EXT-X-INDEPENDENT-SEGMENTS')
  const streamAttributes = [`BANDWIDTH=${variant?.bandwidth || 1}`]
  if (variant?.width && variant?.height) streamAttributes.push(`RESOLUTION=${variant.width}x${variant.height}`)
  if (variant?.codecs) streamAttributes.push(`CODECS="${variant.codecs}"`)
  if (audio) {
    const name = (audio.name || 'Audio').replace(/"/g, '')
    const language = audio.language ? `,LANGUAGE="${audio.language.replace(/"/g, '')}"` : ''
    lines.push(`#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="${name}"${language},DEFAULT=YES,AUTOSELECT=YES,URI="${audioFile}"`)
    streamAttributes.push('AUDIO="audio"')
  }
  lines.push(`#EXT-X-STREAM-INF:${streamAttributes.join(',')}`)
  lines.push(videoFile)
  return lines.join('\n') + '\n'
}

/** True for a stream URL / content type that is HLS. */
export function looksLikeHls (url = '', contentType = '') {
  return /\.m3u8(\?|#|$)/i.test(url) || /mpegurl/i.test(contentType)
}

/** True for a DASH manifest (not supported by the downloader). */
export function looksLikeDash (url = '', contentType = '') {
  return /\.mpd(\?|#|$)/i.test(url) || /dash\+xml/i.test(contentType)
}
