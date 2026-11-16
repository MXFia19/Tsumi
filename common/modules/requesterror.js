// Readable reason of a failed list request (List Editor toasts, components/Scoring.svelte): AniList GraphQL errors,
// MyAnimeList errors, an HTTP response or a thrown error. Pure function (no imports, see requesterror.test.mjs).

/**
 * @param {any} res What the request returned or threw
 * @param {Record<number, string>} [codes] HTTP status texts (util.js codes)
 * @returns {string}
 */
export function requestErrorText (res, codes = {}) {
  if (res === null || res === undefined) return 'No response from the server.'
  if (typeof res === 'string') return res
  const status = (code) => Number.isInteger(code) && code > 0 ? `${code}${codes[code] ? ` - ${codes[code]}` : ''}` : ''
  const join = (...parts) => parts.filter(Boolean).join(': ')
  // AniList GraphQL: { data, errors: [{ message, status }] }
  if (Array.isArray(res.errors) && res.errors.length) {
    const messages = res.errors.map(error => [].concat(error?.message ?? '').filter(Boolean).join(' ')).filter(Boolean)
    return join(status(res.errors[0]?.status), [...new Set(messages)].join(', ')) || 'Unknown error.'
  }
  // MyAnimeList: { error, message }
  if (typeof res.error === 'string') return res.message || res.error
  // Thrown Error, or a Response (fetch, thrown on 429 / 500).
  if (typeof res.status === 'number' && res.status >= 400) return status(res.status) + (!codes[res.status] && res.statusText ? ` - ${res.statusText}` : '')
  if (res instanceof Error || typeof res.message === 'string') return res.message || res.name || 'Unknown error.'
  return 'The server answered without the change.'
}
