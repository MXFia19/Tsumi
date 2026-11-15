// Session token helpers without app imports (tested by token.test.mjs). AniList access tokens are JWTs that
// expire about a year after the login (payload `exp`, in seconds) and can be revoked earlier; AniList then
// answers 401 or an "Invalid token" error. iOS: Services/SessionExpiry.swift.

/** Days before a known expiry when the "expires soon" prompt is shown. */
export const EXPIRY_WARNING_DAYS = 7
export const SESSION_EXPIRED_MESSAGE = 'Your AniList session has expired. Log in again to keep your list in sync.'

const expiryCache = new Map()

/** The token without a "Bearer " prefix. */
export function bareToken (token) {
  return typeof token === 'string' ? token.replace(/^Bearer\s+/i, '').trim() : ''
}

/** Whether two tokens are the same (with or without "Bearer "). */
export function sameToken (a, b) {
  const left = bareToken(a)
  return !!left && left === bareToken(b)
}

/**
 * `exp` (Unix seconds) of a JWT access token, null when the token is not a JWT or has no expiry.
 * @param {string} token
 * @returns {number | null}
 */
export function decodeTokenExpiry (token) {
  const bare = bareToken(token)
  if (!bare) return null
  if (expiryCache.has(bare)) return expiryCache.get(bare)
  let expiry = null
  const parts = bare.split('.')
  if (parts.length === 3) {
    try {
      const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/')
      const payload = JSON.parse(atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4)))
      const exp = Number(payload?.exp)
      if (Number.isFinite(exp) && exp > 0) expiry = exp
    } catch {
      expiry = null
    }
  }
  if (expiryCache.size > 50) expiryCache.clear()
  expiryCache.set(bare, expiry)
  return expiry
}

/**
 * @param {number | null | undefined} expiresAt Unix seconds
 * @param {number} [now] Unix seconds
 * @returns {'expired' | 'expiring' | 'valid' | 'unknown'}
 */
export function tokenExpiryState (expiresAt, now = Date.now() / 1000) {
  if (!expiresAt) return 'unknown'
  if (now >= expiresAt) return 'expired'
  if (expiresAt - now <= EXPIRY_WARNING_DAYS * 24 * 60 * 60) return 'expiring'
  return 'valid'
}

/** Whole days left before `expiresAt` (at least 1 while not expired). */
export function daysLeft (expiresAt, now = Date.now() / 1000) {
  return Math.max(1, Math.ceil((expiresAt - now) / (24 * 60 * 60)))
}

/**
 * Expiry of a stored AniList profile: its saved `expires_in`, else the token's own `exp`.
 * @param {{ token?: string, expires_in?: number } | null} profile
 */
export function profileExpiry (profile) {
  return Number(profile?.expires_in) || decodeTokenExpiry(profile?.token) || null
}

/**
 * Whether an AniList GraphQL response says the token is not accepted (expired or revoked).
 * @param {number} status HTTP status
 * @param {any} json response body
 */
export function isAniListAuthError (status, json) {
  if (status === 401) return true
  return (Array.isArray(json?.errors) ? json.errors : []).some(error => error?.status === 401 || /invalid token/i.test(String(error?.message || '')))
}

/** Whether a GraphQL request body is a mutation (query text without whitespace, see anilist.js alRequest). */
export function isMutationBody (body) {
  return typeof body === 'string' && /^\{"query":"mutation/.test(body)
}
