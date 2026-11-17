// What a stream URL is (streaming.js loadStream): an HLS playlist is played with hls.js, anything else by the video
// element through the local proxy. Most HLS links contain ".m3u8", but some extensions give playlists without it
// ("…/master", "…/playlist?token=…"), which iOS (AVPlayer) plays anyway: those are recognised by their first bytes.
// Pure helpers, tested by streamkind.test.mjs.

const VIDEO_FILE = /\.(mp4|m4v|mkv|webm|mov|avi|flv|wmv|ts|m2ts|mpd|mp3|m4a|aac|ogg|ogv)$/i

/**
 * 'hls' when the URL says it is a playlist, 'file' when its path ends with a media file extension, else 'unknown' (look
 * at the content).
 * @param {string} url
 * @returns {'hls' | 'file' | 'unknown'}
 */
export function streamKindFromUrl (url) {
  const text = String(url || '')
  if (text.toLowerCase().includes('.m3u8')) return 'hls'
  let path = ''
  try {
    path = new URL(text).pathname
  } catch {
    path = text.split(/[?#]/)[0]
  }
  return VIDEO_FILE.test(path) ? 'file' : 'unknown'
}

/**
 * Whether a response is an HLS playlist, from its content type and its first bytes (a playlist starts with #EXTM3U,
 * after an optional byte order mark and blank lines).
 * @param {string | null | undefined} contentType
 * @param {string} start first characters of the body
 */
export function isPlaylistResponse (contentType, start) {
  if (/mpegurl/i.test(String(contentType || ''))) return true
  const text = String(start || '')
  // A byte order mark may come first.
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
  return /^\s*#EXTM3U/.test(body)
}
