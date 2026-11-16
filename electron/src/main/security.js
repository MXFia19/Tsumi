// Pure security helpers of the main process (no Electron import: tested by security.test.mjs).

/** Schemes the system may open with shell.openExternal: web pages and mail, never file:, UNC paths, ms-* handlers... */
const EXTERNAL_PROTOCOLS = new Set(['http:', 'https:', 'mailto:'])

/** @param {unknown} value */
function parseUrl (value) {
  if (typeof value !== 'string' || !value) return null
  try {
    return new URL(value)
  } catch {
    return null
  }
}

/** http(s) or mailto link, the only ones handed to the system. */
export function isExternalUrl (value) {
  const url = parseUrl(value)
  return !!url && EXTERNAL_PROTOCOLS.has(url.protocol)
}

/** http(s) URL. */
export function isWebUrl (value) {
  const url = parseUrl(value)
  return !!url && (url.protocol === 'http:' || url.protocol === 'https:')
}

/**
 * True when `value` is the page of the app itself (same scheme, host and path; the query and the hash may differ).
 * Windows file paths are compared without case (C:/ and c:/ are the same file).
 * @param {string} value
 * @param {string} appUrl
 */
export function isAppUrl (value, appUrl) {
  const url = parseUrl(value)
  const app = parseUrl(appUrl)
  if (!url || !app || url.protocol !== app.protocol || url.host !== app.host) return false
  if (url.protocol === 'file:') return url.pathname.toLowerCase() === app.pathname.toLowerCase()
  return url.pathname === app.pathname
}

/**
 * Host header of a request to a local server listening on `port`: only localhost, 127.0.0.1 or [::1]. Any other name
 * means a web page reached the server through a DNS name that resolves to this computer (DNS rebinding).
 * @param {unknown} host
 * @param {number} port
 */
export function isLoopbackHost (host, port) {
  if (typeof host !== 'string' || !port) return false
  const value = host.trim().toLowerCase()
  return value === `localhost:${port}` || value === `127.0.0.1:${port}` || value === `[::1]:${port}`
}

/**
 * Parameters of the rest of a tsumi:// link ("#access_token=...&token_type=Bearer", "?code=...&state=...", with or
 * without a leading slash). A '+' stays a '+' (tokens are not form-encoded), and the '/' some browsers append to the
 * link is dropped from the last value.
 * @param {string} rest
 * @returns {URLSearchParams}
 */
export function protocolParams (rest) {
  let text = String(rest || '')
  const start = text.search(/[?#]/)
  if (start !== -1) text = text.slice(start + 1)
  text = text.replace(/^\/+/, '').replace(/\/+$/, '')
  return new URLSearchParams(text.replace(/\+/g, '%2B'))
}

/** YouTube video id (11 characters of [A-Za-z0-9_-]). */
export function isYouTubeId (value) {
  return typeof value === 'string' && /^[\w-]{11}$/.test(value)
}

/**
 * Removes secrets from a log line: Authorization values, JWTs, OAuth fields, the path of Stremio addon manifests
 * (their configuration, often with debrid API keys, is in it), and the query / fragment of every http(s) URL (stream
 * links carry their tokens there; the host and path are kept so the log stays useful).
 * @param {string} text
 */
export function redact (text) {
  if (typeof text !== 'string' || !text) return text
  return text
    .replace(/\b(Bearer|Basic)\s+[\w\-.~+/]+=*/gi, '$1 [redacted]')
    .replace(/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[redacted]')
    .replace(/\b((?:access_token|refresh_token|id_token|client_secret|code_verifier)["']?\s*[=:]\s*["']?)[^"'&\s,;}]+/gi, '$1[redacted]')
    .replace(/\b((?:https?|stremio):\/\/[^\s"'<>/?#]+)\/[^\s"'<>?#]*\/manifest\.json/gi, '$1/[redacted]/manifest.json')
    .replace(/\b(https?:\/\/[^\s"'<>?#]+)[?#][^\s"'<>]*/gi, '$1?[redacted]')
}
