import { createHash, randomBytes } from 'node:crypto'

// Trakt sign-in: OAuth authorization code flow with PKCE (S256), Client ID only (https://developer.trakt.tv/docs/pkce).
// Pure helpers of electron/src/main/trakt.js, tested by traktAuth.test.mjs.

/** Every OAuth request (authorize, token, refresh, revoke) goes to this host, not to the API host. */
export const TRAKT_AUTH = 'https://auth.trakt.tv'
/**
 * Redirect URI registered in the Trakt app settings: a GitHub Pages page (docs/trakt/index.html) that sends the code
 * on to tsumi://trakt/callback. It must be identical in the authorize request, the token exchange and the refresh.
 */
export const TRAKT_REDIRECT_URI = 'https://mxfia19.github.io/Tsumi/trakt/'

/** @param {Buffer} buffer */
export function base64url (buffer) {
  return buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * code_challenge of a code_verifier: base64url (no padding) of its SHA-256.
 * @param {string} verifier
 */
export function codeChallenge (verifier) {
  return base64url(createHash('sha256').update(verifier, 'ascii').digest())
}

/**
 * New verifier (43 characters of [A-Za-z0-9-_], within the 43-128 of RFC 7636), its challenge and a state.
 * @returns {{ verifier: string, challenge: string, state: string }}
 */
export function createPkce () {
  const verifier = base64url(randomBytes(32))
  return { verifier, challenge: codeChallenge(verifier), state: base64url(randomBytes(24)) }
}

/**
 * @param {{ clientId: string, state: string, challenge: string, redirectUri?: string }} options
 */
export function authorizeUrl ({ clientId, state, challenge, redirectUri = TRAKT_REDIRECT_URI }) {
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectUri,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256'
  })
  return `${TRAKT_AUTH}/oauth/authorize?${params}`
}

/**
 * Query of a tsumi://trakt/callback?code=...&state=... link (or of its "callback?..." remainder, as protocol.js
 * passes it). Windows may add a trailing "/" to the link. Null when it carries neither a code nor an error.
 * @param {string} link
 * @returns {{ code: string, state: string, error: string } | null}
 */
export function parseCallback (link) {
  if (typeof link !== 'string') return null
  const start = link.indexOf('?')
  if (start === -1) return null
  const query = link.slice(start + 1).split('#')[0].replace(/\/+$/, '')
  const params = new URLSearchParams(query)
  /** @param {string} key */
  const value = key => (params.get(key) || '').trim().replace(/\/+$/, '')
  const code = value('code')
  const error = value('error')
  if (!code && !error) return null
  return { code, state: value('state'), error }
}

/**
 * OAuth error code, reduced to a short word that is safe to show (never the description, which may echo input).
 * @param {unknown} value an error code, or a token endpoint answer { error, error_description }
 */
export function oauthErrorCode (value) {
  const error = typeof value === 'string' ? value : /** @type {any} */ (value)?.error
  return typeof error === 'string' ? error.replace(/[^\w.-]/g, '').slice(0, 40) : ''
}

/**
 * Message for an error=... of the authorize redirect.
 * @param {string} error
 */
export function callbackErrorMessage (error) {
  if (error === 'access_denied') return 'Access was denied on Trakt.'
  return `Trakt could not sign you in (${oauthErrorCode(error) || 'unknown error'}), try again.`
}
