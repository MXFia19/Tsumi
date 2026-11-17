// Upstream side of the stream proxy (streamProxy.js), pure Node (no Electron import: tested by proxyUpstream.test.mjs).
//
// moduleFetch makes the requests of the /fetch route, i.e. every fetchv2 of a Sora module on PC. It applies the network
// rules of the modules (common/modules/sandbox/network.js, the same as on iOS) where the connection is made, which the
// renderer cannot do: the address a host name resolves to is checked when connecting (a public name such as
// 127.0.0.1.nip.io that resolves to this computer is refused, and the address checked is the one connected to, so a DNS
// answer that changes between a check and the connection cannot slip through), and redirects are followed one by one,
// each checked like the first request. The body is streamed by the route with a size cap (byteLimit).

import http from 'node:http'
import https from 'node:https'
import dns from 'node:dns'
import zlib from 'node:zlib'
import { Transform } from 'node:stream'
import { hostKind, MAX_RESPONSE_BYTES } from '../../../common/modules/sandbox/network.js'
import { sanitizeHeaders } from './cast/proxy.js'

export { MAX_RESPONSE_BYTES }

export const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

/** Redirects followed before giving up (Fetch standard). */
export const MAX_REDIRECTS = 20
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308])
/** Statuses without a body (Fetch standard "null body status"). */
const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304])
/** Headers that describe the request body, dropped when a redirect turns the request into a GET. */
const BODY_HEADERS = ['content-type', 'content-encoding', 'content-language', 'content-location', 'content-length']
/** Headers not sent to another origin after a redirect (what undici, the fetch of Node, drops). */
const CROSS_ORIGIN_HEADERS = ['authorization', 'proxy-authorization', 'cookie', 'host']

/** Error of a request the network rules refuse; the module's fetchv2 fails with this message. */
function blockedError (hostname) {
  const error = new Error(`Blocked request to a local network address (${hostname})`)
  error.code = 'ELOCALADDRESS'
  return error
}

export function tooLargeError (max = MAX_RESPONSE_BYTES) {
  const error = new Error(`Response too large (over ${Math.round(max / 1024 / 1024)} MB)`)
  error.code = 'ETOOLARGE'
  return error
}

/**
 * Checks a URL a module asks for, or a redirect leads to: http(s) only, and no local host (loopback, private,
 * link-local, multicast... see hostKind) unless the module itself is served from the user's machine or network.
 * @param {string} input
 * @param {{ allowLocal?: boolean, kindOf?: (host: string) => string }} [policy]
 */
export function checkTarget (input, { allowLocal = false, kindOf = hostKind } = {}) {
  let url
  try {
    url = new URL(String(input))
  } catch {
    throw new Error('Blocked request: invalid URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`Blocked request: modules may only use http(s), not ${url.protocol.replace(/:$/, '')}`)
  }
  if (!allowLocal && kindOf(url.hostname) !== 'public') throw blockedError(url.hostname)
  return url
}

/**
 * A `lookup` for http.request that refuses host names resolving to a local address (every answer is checked, IPv4
 * and IPv6). Node connects to the address it returns. IP literals never get here: checkTarget checks them.
 * @param {{ resolve?: typeof dns.lookup, kindOf?: (host: string) => string }} [options] resolve / kindOf: for the tests
 */
export function guardedLookup ({ resolve = dns.lookup, kindOf = hostKind } = {}) {
  return (hostname, options, callback) => {
    if (typeof options === 'function') {
      callback = options
      options = {}
    }
    resolve(hostname, { ...options, all: true }, (error, addresses) => {
      if (error) return callback(error)
      const list = Array.isArray(addresses) ? addresses : []
      if (!list.length) return callback(Object.assign(new Error(`getaddrinfo ENOTFOUND ${hostname}`), { code: 'ENOTFOUND', hostname }))
      if (list.some(entry => kindOf(entry.address) !== 'public')) return callback(blockedError(hostname))
      if (options?.all) return callback(null, list)
      callback(null, list[0].address, list[0].family)
    })
  }
}

/**
 * Method of the request that follows a redirect (Fetch standard): a 303 turns everything but GET / HEAD into a GET,
 * a 301 / 302 turns a POST into a GET; the body is dropped with it. 307 / 308 keep both.
 * @param {number} status
 * @param {string} method
 */
export function redirectMethod (status, method) {
  if ((status === 303 && method !== 'GET' && method !== 'HEAD') || ((status === 301 || status === 302) && method === 'POST')) {
    return { method: 'GET', dropBody: true }
  }
  return { method, dropBody: false }
}

/** Header objects merged without case duplicates (the last one wins, with its own spelling). */
function mergeHeaders (...sources) {
  const merged = new Map()
  for (const source of sources) {
    for (const [name, value] of Object.entries(source || {})) merged.set(name.toLowerCase(), [name, value])
  }
  return Object.fromEntries(merged.values())
}

function withoutHeaders (headers, names) {
  return Object.fromEntries(Object.entries(headers).filter(([name]) => !names.includes(name.toLowerCase())))
}

/** Headers undici (the fetch this route used before) adds; the module's own headers win. */
function defaultHeaders () {
  return {
    'User-Agent': DEFAULT_USER_AGENT,
    Accept: '*/*',
    'Accept-Language': '*',
    'Sec-Fetch-Mode': 'cors',
    'Accept-Encoding': 'gzip, deflate, br'
  }
}

/** One keep-alive agent per scheme and policy: a connection opened for a local module is never reused for another. */
const agents = new Map()
function agentFor (protocol, allowLocal) {
  const key = `${protocol}${allowLocal ? 'local' : ''}`
  if (!agents.has(key)) agents.set(key, new (protocol === 'https:' ? https.Agent : http.Agent)({ keepAlive: true }))
  return agents.get(key)
}

/** @returns {Promise<http.IncomingMessage>} */
function requestOnce (url, { method, headers, body, signal, lookup, agent }) {
  return new Promise((resolve, reject) => {
    const client = url.protocol === 'https:' ? https : http
    let request
    try {
      request = client.request(url, { method, headers, signal, agent, ...(lookup ? { lookup } : {}) }, resolve)
    } catch (error) {
      // Invalid header name or value, invalid method...
      reject(error)
      return
    }
    request.on('error', reject)
    request.end(body ?? undefined)
  })
}

/**
 * A request of a module. Redirects are followed by hand (each one checked) unless `redirect` is 'manual', where the
 * 3xx answer is the result, or 'error', where a redirect fails the request.
 * @param {{ url: string, method?: string, headers?: Record<string, string>, body?: string | null, redirect?: string,
 *   allowLocal?: boolean, signal?: AbortSignal }} request
 * @param {{ resolve?: typeof dns.lookup, kindOf?: (host: string) => string, agent?: any }} [options] for the tests
 * @returns {Promise<{ response: http.IncomingMessage, url: string, redirected: boolean }>} response: body not read yet
 */
export async function moduleFetch ({ url, method = 'GET', headers = {}, body = null, redirect = 'follow', allowLocal = false, signal }, options = {}) {
  const kindOf = options.kindOf || hostKind
  const lookup = allowLocal ? null : guardedLookup({ resolve: options.resolve, kindOf })
  let current = checkTarget(url, { allowLocal, kindOf })
  let currentMethod = String(method || 'GET').toUpperCase()
  let currentHeaders = mergeHeaders(defaultHeaders(), sanitizeHeaders(headers))
  let currentBody = currentMethod === 'GET' || currentMethod === 'HEAD' || body == null ? null : String(body)

  for (let redirects = 0; ; redirects++) {
    const sent = currentBody === null ? currentHeaders : { ...currentHeaders, 'Content-Length': String(Buffer.byteLength(currentBody)) }
    const response = await requestOnce(current, {
      method: currentMethod,
      headers: sent,
      body: currentBody,
      signal,
      lookup,
      agent: options.agent !== undefined ? options.agent : agentFor(current.protocol, allowLocal)
    })
    const location = response.headers.location
    if (!REDIRECT_STATUSES.has(response.statusCode) || !location || redirect === 'manual') {
      return { response, url: current.href, redirected: redirects > 0 }
    }
    // The body of a redirect is not used: read it away so the connection goes back to the pool.
    response.resume()
    if (redirect === 'error') throw new Error('Blocked request: the server redirected and the module asked for no redirects')
    if (redirects >= MAX_REDIRECTS) throw new Error('Too many redirects')
    let next
    try {
      next = new URL(location, current)
    } catch {
      throw new Error('The server redirected to an invalid address')
    }
    next = checkTarget(next.href, { allowLocal, kindOf })
    const change = redirectMethod(response.statusCode, currentMethod)
    currentMethod = change.method
    if (change.dropBody) {
      currentBody = null
      currentHeaders = withoutHeaders(currentHeaders, BODY_HEADERS)
    }
    if (next.origin !== current.origin) currentHeaders = withoutHeaders(currentHeaders, CROSS_ORIGIN_HEADERS)
    current = next
  }
}

const ZLIB_FLUSH = { flush: zlib.constants.Z_SYNC_FLUSH, finishFlush: zlib.constants.Z_SYNC_FLUSH }
const BROTLI_FLUSH = { flush: zlib.constants.BROTLI_OPERATION_FLUSH, finishFlush: zlib.constants.BROTLI_OPERATION_FLUSH }

/**
 * Streams that undo the Content-Encoding of a response (gzip, deflate, br, in the reverse order of the header), like
 * fetch does. An encoding it does not know leaves the body as it is (empty list), as fetch does too.
 * @param {string | undefined} contentEncoding
 * @param {{ method?: string, status?: number }} [response] HEAD answers and null body statuses are not decoded
 * @returns {import('node:stream').Transform[]}
 */
export function decodersFor (contentEncoding, { method = 'GET', status = 200 } = {}) {
  if (method === 'HEAD' || NULL_BODY_STATUSES.has(status)) return []
  const codings = String(contentEncoding || '').toLowerCase().split(',').map(coding => coding.trim()).filter(coding => coding && coding !== 'identity')
  if (!codings.every(coding => ['gzip', 'x-gzip', 'deflate', 'br'].includes(coding))) return []
  return codings.reverse().map(coding => {
    if (coding === 'br') return zlib.createBrotliDecompress(BROTLI_FLUSH)
    if (coding === 'deflate') return zlib.createInflate(ZLIB_FLUSH)
    return zlib.createGunzip(ZLIB_FLUSH)
  })
}

/** Passes the bytes through and fails once more than `max` went by. */
export function byteLimit (max = MAX_RESPONSE_BYTES) {
  let total = 0
  return new Transform({
    transform (chunk, _encoding, callback) {
      total += chunk.length
      if (total > max) return callback(tooLargeError(max))
      callback(null, chunk)
    }
  })
}

/**
 * Reads the start of a body (at least `min` bytes, unless it is shorter) to see what it is.
 * @param {ReadableStreamDefaultReader<Uint8Array>} reader
 * @returns {Promise<{ head: Buffer, done: boolean }>}
 */
export async function readHead (reader, min = 32) {
  const chunks = []
  let length = 0
  while (length < min) {
    const { done, value } = await reader.read()
    if (done) return { head: Buffer.concat(chunks), done: true }
    chunks.push(Buffer.from(value))
    length += value.byteLength
  }
  return { head: Buffer.concat(chunks), done: false }
}

/**
 * The rest of a body after readHead, as one Buffer, failing over `max` bytes in all.
 * @param {ReadableStreamDefaultReader<Uint8Array>} reader
 * @param {{ head: Buffer, done: boolean }} start
 */
export async function readRest (reader, { head, done }, max) {
  const chunks = [head]
  let length = head.length
  if (length > max) throw tooLargeError(max)
  if (!done) {
    for (;;) {
      const next = await reader.read()
      if (next.done) break
      length += next.value.byteLength
      if (length > max) {
        reader.cancel().catch(() => {})
        throw tooLargeError(max)
      }
      chunks.push(Buffer.from(next.value))
    }
  }
  return Buffer.concat(chunks)
}

/**
 * The chunks of a body after readHead (the head first). The reader is cancelled when the consumer stops early.
 * @param {ReadableStreamDefaultReader<Uint8Array>} reader
 * @param {{ head: Buffer, done: boolean }} start
 */
export async function * bodyChunks (reader, { head, done }) {
  try {
    if (head.length) yield head
    if (done) return
    for (;;) {
      const next = await reader.read()
      if (next.done) return
      yield next.value
    }
  } finally {
    reader.cancel().catch(() => {})
  }
}
