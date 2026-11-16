// Network rules of the extensions (Sora modules and Stremio addons), pure helpers unit tested by network.test.mjs.
// Same rules as the iOS app: a module may only use http(s), may not reach the user's own machine or local network
// (loopback, private, link-local addresses) unless the module itself is served from there, and a response body is
// capped so a module cannot make the app download a whole video in memory.

/** Largest response body handed to a module or read from a Stremio addon. */
export const MAX_RESPONSE_BYTES = 20 * 1024 * 1024

function parseIPv4 (host) {
  const parts = host.split('.')
  if (parts.length !== 4 || !parts.every(part => /^\d{1,3}$/.test(part))) return null
  const bytes = parts.map(Number)
  return bytes.every(byte => byte <= 255) ? bytes : null
}

function ipv4Kind ([a, b]) {
  if (a === 127 || a === 0) return 'loopback'
  if (a === 169 && b === 254) return 'link-local'
  if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) return 'private'
  if (a === 100 && b >= 64 && b <= 127) return 'private' // carrier-grade NAT
  if (a === 198 && (b === 18 || b === 19)) return 'private' // benchmarking networks
  if (a >= 224) return 'private' // multicast, reserved, broadcast
  return 'public'
}

/** The 8 groups of an IPv6 address (URL hostnames are already normalized, "::" expanded here). */
function parseIPv6 (host) {
  let text = host
  // An embedded IPv4 (::ffff:127.0.0.1) becomes two groups.
  const v4 = text.match(/(\d{1,3}(?:\.\d{1,3}){3})$/)
  if (v4) {
    const bytes = parseIPv4(v4[1])
    if (!bytes) return null
    text = text.slice(0, -v4[1].length) + ((bytes[0] << 8) | bytes[1]).toString(16) + ':' + ((bytes[2] << 8) | bytes[3]).toString(16)
  }
  const halves = text.split('::')
  if (halves.length > 2) return null
  const head = halves[0] ? halves[0].split(':') : []
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : []
  const missing = 8 - head.length - tail.length
  if (halves.length === 1 ? missing !== 0 : missing < 0) return null
  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill('0'), ...tail]
  if (!groups.every(group => /^[0-9a-f]{1,4}$/i.test(group))) return null
  return groups.map(group => parseInt(group, 16))
}

function ipv6Kind (groups) {
  if (groups.every(group => group === 0)) return 'loopback' // ::
  if (groups.slice(0, 7).every(group => group === 0) && groups[7] === 1) return 'loopback' // ::1
  // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) addresses: the IPv4 rules apply.
  if (groups.slice(0, 5).every(group => group === 0) && (groups[5] === 0xffff || groups[5] === 0)) {
    return ipv4Kind([groups[6] >> 8, groups[6] & 255, groups[7] >> 8, groups[7] & 255])
  }
  if ((groups[0] & 0xffc0) === 0xfe80) return 'link-local' // fe80::/10
  if ((groups[0] & 0xfe00) === 0xfc00) return 'private' // fc00::/7 unique local
  if ((groups[0] & 0xffc0) === 0xfec0) return 'private' // deprecated site-local
  if ((groups[0] & 0xff00) === 0xff00) return 'private' // multicast
  return 'public'
}

/**
 * Kind of a host name as found in URL.hostname: 'loopback', 'private', 'link-local' or 'public'.
 * Names without a dot (intranet machines) and local DNS suffixes (.local, .lan, .internal, .home.arpa...) are private.
 * A public name that resolves to a local address (DNS rebinding) cannot be seen from here.
 */
export function hostKind (hostname) {
  const host = String(hostname || '').trim().toLowerCase().replace(/^\[(.*)\]$/, '$1').replace(/\.+$/, '')
  if (!host) return 'private'
  if (host === 'localhost' || host.endsWith('.localhost')) return 'loopback'
  const v4 = parseIPv4(host)
  if (v4) return ipv4Kind(v4)
  if (host.includes(':')) {
    const v6 = parseIPv6(host.replace(/%.*$/, ''))
    return v6 ? ipv6Kind(v6) : 'private'
  }
  if (!host.includes('.')) return 'private'
  if (/\.(local|lan|internal|intranet|home|corp|localdomain|home\.arpa)$/.test(host)) return 'private'
  return 'public'
}

/** True for loopback, private and link-local hosts. */
export function isLocalHost (hostname) {
  return hostKind(hostname) !== 'public'
}

/** True when the URL points to the user's machine or local network (false for invalid URLs). */
export function isLocalUrl (url) {
  try {
    return isLocalHost(new URL(String(url)).hostname)
  } catch {
    return false
  }
}

/**
 * Validates a request made by a module and returns it as a URL. Only http(s); local addresses only when `allowLocal`
 * (the module itself is served from the user's machine or network, e.g. while developing it).
 * @param {string} input
 * @param {{ allowLocal?: boolean }} [policy]
 */
export function checkModuleUrl (input, { allowLocal = false } = {}) {
  let url
  try {
    url = new URL(String(input))
  } catch {
    throw new Error('Blocked request: invalid URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`Blocked request: modules may only use http(s), not ${url.protocol.replace(/:$/, '')}`)
  }
  if (!allowLocal && isLocalHost(url.hostname)) {
    throw new Error(`Blocked request to a local network address (${url.hostname})`)
  }
  return url
}

/**
 * What the app shows of an extension URL: its host only. Stremio manifest URLs often carry the user's configuration
 * or a private token in their path, which must not appear on screen or in error messages.
 */
export function maskUrl (input) {
  try {
    const url = new URL(String(input || '').trim().replace(/^stremio:\/\//i, 'https://'))
    return url.host || url.protocol.replace(/:$/, '')
  } catch {
    return 'invalid address'
  }
}

/**
 * Where to download a module script from: http(s) only (a file: or data: script is refused); a plain http script on a
 * public host is tried over https first.
 * @returns {string[]} URLs to try in order
 */
export function scriptUrlCandidates (scriptUrl, manifestUrl) {
  let url
  try {
    url = new URL(String(scriptUrl), manifestUrl)
  } catch {
    throw new Error('Invalid manifest: scriptUrl is not a valid URL')
  }
  if (url.protocol === 'https:') return [url.href]
  if (url.protocol !== 'http:') throw new Error(`Invalid manifest: the script must be served over http(s), not ${url.protocol.replace(/:$/, '')}`)
  if (isLocalHost(url.hostname)) return [url.href]
  const secure = new URL(url.href)
  secure.protocol = 'https:'
  return [secure.href, url.href]
}

/** Manifest URLs: http(s) only (stremio:// links are https). */
export function checkManifestUrl (input) {
  let url
  try {
    url = new URL(String(input || '').trim().replace(/^stremio:\/\//i, 'https://'))
  } catch {
    throw new Error('Enter the full address of the manifest (https://...)')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('Extensions can only be installed from an http(s) address')
  return url.href
}

function tooLarge (max) {
  return new Error(`Response too large (over ${Math.round(max / 1024 / 1024)} MB)`)
}

/**
 * Reads a fetch Response body into an ArrayBuffer, failing once it exceeds `max` bytes (declared length or streamed).
 * @param {Response} response
 * @param {number} [max]
 * @returns {Promise<ArrayBuffer>}
 */
export async function readCapped (response, max = MAX_RESPONSE_BYTES) {
  const declared = Number(response.headers?.get?.('content-length'))
  if (Number.isFinite(declared) && declared > max) {
    try { await response.body?.cancel() } catch {}
    throw tooLarge(max)
  }
  if (!response.body) return new ArrayBuffer(0)
  const reader = response.body.getReader()
  const chunks = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > max) {
      try { await reader.cancel() } catch {}
      throw tooLarge(max)
    }
    chunks.push(value)
  }
  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out.buffer
}

/**
 * Hosts a module says it uses (manifest baseUrl / searchBaseUrl, script host) and the absolute http(s) URLs written in
 * its script, shown before installing it. Best effort: a module can still build other addresses at run time.
 * @param {any} manifest
 * @param {string} [script]
 * @param {string} [scriptUrl]
 * @returns {string[]}
 */
export function moduleDomains (manifest, script = '', scriptUrl = '') {
  const hosts = new Set()
  const add = (value) => {
    try {
      const url = new URL(String(value))
      if ((url.protocol === 'http:' || url.protocol === 'https:') && url.hostname) hosts.add(url.hostname.toLowerCase())
    } catch {}
  }
  add(manifest?.baseUrl)
  add(manifest?.searchBaseUrl)
  add(scriptUrl)
  const literal = /https?:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d+)?/gi
  for (const match of String(script || '').matchAll(literal)) {
    add(match[0])
    if (hosts.size >= 40) break
  }
  return [...hosts].sort()
}
