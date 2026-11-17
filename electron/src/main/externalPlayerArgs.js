// Command line of the external player and the position it reports when it closes (pure, tested by
// externalPlayer.test.mjs). Used by externalPlayer.js.

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
 * @param {{ url: string, title?: string, subtitle?: string | null, startTime?: number, ipcPath?: string | null }} options
 *   subtitle: URL (mpv) or local file path (VLC) of the subtitle track; ipcPath: mpv JSON IPC server (named pipe or
 *   socket) through which the app reads the position
 */
export function playerArgs (kind, { url, title, subtitle, startTime, ipcPath }) {
  const name = cleanTitle(title)
  const start = startSeconds(startTime)
  if (kind === 'mpv') {
    const args = []
    if (name) args.push(`--force-media-title=${name}`)
    if (start) args.push(`--start=${start}`)
    if (subtitle) args.push(`--sub-file=${subtitle}`)
    if (ipcPath) args.push(`--input-ipc-server=${ipcPath}`)
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

/** mpv commands sent once connected: report the position and the length whenever they change. */
export const MPV_OBSERVE = '{"command":["observe_property",1,"time-pos"]}\n{"command":["observe_property",2,"duration"]}\n'

/**
 * Reads mpv JSON IPC messages (one JSON object per line, https://mpv.io/manual/master/#json-ipc) into `state`:
 * `position` and `duration` (seconds, from the observed properties) and `ended` (the end of the file was reached).
 * A property that becomes unavailable (null when the file closes) keeps its last value.
 * @param {{ position?: number | null, duration?: number | null, ended?: boolean }} state
 * @param {string} text what was received, after the unfinished line returned by the previous call
 * @returns {string} the unfinished last line, for the next call
 */
export function readMpvMessages (state, text) {
  const lines = String(text ?? '').split('\n')
  const rest = lines.pop() || ''
  for (const line of lines) {
    let message
    try {
      message = JSON.parse(line)
    } catch {
      continue
    }
    if (message?.event === 'property-change' && typeof message.data === 'number' && Number.isFinite(message.data)) {
      if (message.name === 'time-pos' && message.data >= 0) state.position = message.data
      else if (message.name === 'duration' && message.data > 0) state.duration = message.data
    } else if (message?.event === 'end-file' && message.reason === 'eof') {
      state.ended = true
    }
  }
  // A line this long is not an mpv message: never let the buffer grow.
  return rest.length > 65_536 ? '' : rest
}

/** Shorter than this, a player that closed is taken as one that did not play (failed, or handed over to a running one). */
export const MIN_ESTIMATED_S = 10

/**
 * Where the external player stopped, sent with 'external-player:closed' (saved progress, completion, "Play next").
 * mpv reports its own position over JSON IPC (`report.connected`), and the end of the episode when it reached it.
 * Other players (VLC...) only give the time they stayed open: the position is then estimated from the start position
 * and that time (as the old Miru external player did), and flagged `estimated`.
 * @param {{ connected?: boolean, position?: number | null, duration?: number | null, ended?: boolean }} report
 * @param {{ startTime?: number, elapsed?: number }} launch start position and seconds since the player started
 * @returns {{ position?: number, duration?: number, estimated?: boolean }}
 */
export function closedPosition (report, { startTime, elapsed } = {}) {
  const duration = Number(report?.duration) > 0 ? Number(report.duration) : undefined
  if (report?.connected) {
    if (report.ended && duration) return { position: duration, duration }
    const position = Number(report.position)
    return report.position != null && Number.isFinite(position) && position > 0 ? { position, ...(duration ? { duration } : {}) } : {}
  }
  const seconds = Number(elapsed)
  if (!Number.isFinite(seconds) || seconds < MIN_ESTIMATED_S) return {}
  return { position: Math.round(((startSeconds(startTime) || 0) + seconds) * 1000) / 1000, estimated: true }
}
