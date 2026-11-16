// Command line of the external player (pure, tested by externalPlayer.test.mjs). Used by externalPlayer.js.

/**
 * Kind of player from its executable path: 'mpv' (mpv, mpv.net), 'vlc', or 'other' (gets the URL only).
 * @param {string} path
 * @returns {'mpv' | 'vlc' | 'other'}
 */
export function playerKind (path) {
  const name = String(path || '').split(/[\\/]/).pop().toLowerCase().replace(/\.(exe|com|app)$/, '')
  if (name === 'mpv' || name === 'mpvnet' || name === 'mpv.net') return 'mpv'
  if (name === 'vlc') return 'vlc'
  return 'other'
}

/** Text for a command line argument: no control characters (a NUL makes spawn throw), at most 200 characters. */
export function cleanTitle (title) {
  // eslint-disable-next-line no-control-regex
  return String(title ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 200)
}

/** Start position in seconds (null when missing, not a number or at the start). */
export function startSeconds (value) {
  const seconds = Number(value)
  return Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds * 1000) / 1000 : null
}

/**
 * Arguments of the player (no shell: each one is passed as it is).
 * @param {'mpv' | 'vlc' | 'other'} kind
 * @param {{ url: string, title?: string, subtitle?: string | null, startTime?: number }} options
 *   subtitle: URL (mpv) or local file path (VLC) of the subtitle track
 */
export function playerArgs (kind, { url, title, subtitle, startTime }) {
  const name = cleanTitle(title)
  const start = startSeconds(startTime)
  if (kind === 'mpv') {
    const args = []
    if (name) args.push(`--force-media-title=${name}`)
    if (start) args.push(`--start=${start}`)
    if (subtitle) args.push(`--sub-file=${subtitle}`)
    // '--' ends the options: the URL is never read as one.
    args.push('--', url)
    return args
  }
  if (kind === 'vlc') {
    // A new VLC window even when VLC is set to a single instance: the running one would take the video and the process
    // started here would exit at once (the app would think the player was closed).
    const args = ['--no-one-instance']
    if (name) args.push(`--meta-title=${name}`)
    if (start) args.push(`--start-time=${start}`)
    if (subtitle) args.push(`--sub-file=${subtitle}`)
    args.push(url)
    return args
  }
  return [url]
}
