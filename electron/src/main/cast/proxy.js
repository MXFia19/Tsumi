import http from 'node:http'
import crypto from 'node:crypto'
import { Readable } from 'node:stream'
import Debug from 'debug'
import { isPlaylistStart, rewritePlaylist, variantUrls, segmentFormat, fileContentType } from './hls.js'

const debug = Debug('electron:cast:proxy')

const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
// Request headers of the receiver forwarded upstream (the source headers from the extension are added on top).
const FORWARDED = ['range', 'if-range', 'accept', 'accept-language']

const encodeTarget = (url) => Buffer.from(url, 'utf8').toString('base64url')
const decodeTarget = (value) => Buffer.from(value, 'base64url').toString('utf8')

/** Last path segment, safe for a URL (keeps the extension, which some receivers look at). */
export function fileName (url, fallback = 'media') {
  try {
    const name = decodeURIComponent(new URL(url).pathname.split('/').pop() || '')
    const safe = name.replace(/[^\w.-]+/g, '_').slice(-80)
    return safe || fallback
  } catch {
    return fallback
  }
}

/** Header names and values that can be sent with fetch (drops pseudo / hop-by-hop headers and empty values). */
export function sanitizeHeaders (headers) {
  const result = {}
  for (const [key, value] of Object.entries(headers || {})) {
    if (value == null || value === '') continue
    const name = String(key).trim()
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name)) continue
    if (['host', 'connection', 'content-length', 'transfer-encoding', 'keep-alive', 'upgrade'].includes(name.toLowerCase())) continue
    result[name] = String(value).replace(/[\r\n]+/g, ' ')
  }
  return result
}

/**
 * HTTP proxy the Cast device streams from while casting. Bound to the LAN address that reaches the device, on a
 * random port, every path starts with an unguessable token. It adds the CORS headers receivers need, sends the
 * headers the source requires (Referer, Origin...), forwards Range for progressive files, rewrites HLS playlists so
 * nested URLs come back through it, and serves the subtitle tracks as WebVTT.
 */
export default class CastProxy {
  server = null
  host = ''
  port = 0
  token = ''
  headers = {}
  /** Hosts the source and its playlists point to: the only ones the proxy fetches. */
  allowedHosts = new Set()
  /** @type {Map<string, string>} published path -> WebVTT text */
  texts = new Map()

  async start (host) {
    if (this.server && this.host === host) return
    await this.stop()
    this.host = host
    this.token = crypto.randomBytes(24).toString('hex')
    this.server = http.createServer((req, res) => {
      this.handle(req, res).catch(error => {
        debug('Proxy error', error?.message)
        if (!res.headersSent) {
          this.cors(res)
          res.writeHead(502)
        }
        res.end()
      })
    })
    this.server.keepAliveTimeout = 30_000
    await new Promise((resolve, reject) => {
      this.server.once('error', reject)
      this.server.listen(0, host, () => {
        this.server.off('error', reject)
        resolve()
      })
    })
    this.port = this.server.address().port
    debug(`Cast proxy listening on ${host}:${this.port}`)
  }

  async stop () {
    const server = this.server
    this.server = null
    this.texts.clear()
    this.allowedHosts.clear()
    if (!server) return
    await new Promise(resolve => {
      server.close(() => resolve())
      server.closeAllConnections?.()
    })
  }

  base () {
    const host = this.host.includes(':') ? `[${this.host}]` : this.host
    return `http://${host}:${this.port}/${this.token}`
  }

  allow (url) {
    try {
      this.allowedHosts.add(new URL(url).host.toLowerCase())
    } catch {}
  }

  /** URL of an upstream resource through the proxy. */
  mediaUrl (url) {
    this.allow(url)
    return `${this.base()}/p/${encodeTarget(url)}/${fileName(url)}`
  }

  setSource ({ url, headers }) {
    this.headers = sanitizeHeaders(headers)
    this.allow(url)
    return this.mediaUrl(url)
  }

  /** Publishes the subtitle tracks; returns their URLs by track id. Versioned paths so receivers never reuse a stale file. */
  setTextTracks (tracks) {
    this.texts.clear()
    const urls = {}
    const version = Date.now().toString(36)
    for (const track of tracks || []) {
      const path = `t/${track.id}-${version}.vtt`
      this.texts.set(path, String(track.vtt || 'WEBVTT\n'))
      urls[track.id] = `${this.base()}/${path}`
    }
    return urls
  }

  upstreamHeaders (req) {
    const headers = { 'User-Agent': DEFAULT_USER_AGENT, ...this.headers }
    for (const name of FORWARDED) {
      const value = req?.headers?.[name]
      if (value && !Object.keys(headers).some(key => key.toLowerCase() === name)) headers[name] = value
    }
    return headers
  }

  cors (res, req) {
    res.setHeader('Access-Control-Allow-Origin', '*')
    res.setHeader('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
    res.setHeader('Access-Control-Allow-Headers', req?.headers?.['access-control-request-headers'] || 'Range, Content-Type, Accept, Origin')
    res.setHeader('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges, Content-Type')
    res.setHeader('Access-Control-Max-Age', '600')
  }

  async handle (req, res) {
    this.cors(res, req)
    const url = new URL(req.url, 'http://proxy')
    const parts = url.pathname.split('/').filter(Boolean)
    if (parts[0] !== this.token) {
      res.writeHead(404)
      return res.end()
    }
    if (req.method === 'OPTIONS') {
      res.writeHead(204)
      return res.end()
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405)
      return res.end()
    }
    const path = parts.slice(1).join('/')
    if (parts[1] === 't') {
      const text = this.texts.get(path)
      if (text == null) {
        res.writeHead(404)
        return res.end()
      }
      const body = Buffer.from(text, 'utf8')
      res.writeHead(200, { 'Content-Type': 'text/vtt; charset=utf-8', 'Content-Length': body.length, 'Cache-Control': 'no-cache' })
      return res.end(req.method === 'HEAD' ? undefined : body)
    }
    if (parts[1] !== 'p' || !parts[2]) {
      res.writeHead(404)
      return res.end()
    }
    let target
    try {
      target = new URL(decodeTarget(parts[2]))
    } catch {
      res.writeHead(400)
      return res.end()
    }
    if ((target.protocol !== 'http:' && target.protocol !== 'https:') || !this.allowedHosts.has(target.host.toLowerCase())) {
      res.writeHead(403)
      return res.end()
    }
    await this.forward(req, res, target.href)
  }

  async forward (req, res, target) {
    const controller = new AbortController()
    res.on('close', () => controller.abort())
    let response
    try {
      response = await fetch(target, { headers: this.upstreamHeaders(req), redirect: 'follow', signal: controller.signal })
    } catch (error) {
      if (controller.signal.aborted) return
      debug('Upstream request failed', target, error?.message)
      res.writeHead(502)
      return res.end()
    }
    if (response.url) this.allow(response.url)
    const contentType = response.headers.get('content-type') || ''
    const reader = response.body?.getReader()
    let first = null
    if (reader) {
      try {
        const chunk = await reader.read()
        first = chunk.done ? null : Buffer.from(chunk.value)
      } catch (error) {
        if (controller.signal.aborted) return
        throw error
      }
    }
    const playlist = response.ok && (isPlaylistStart(first) || /mpegurl/i.test(contentType))
    if (playlist) {
      const chunks = first ? [first] : []
      for (;;) {
        const chunk = await reader.read()
        if (chunk.done) break
        chunks.push(Buffer.from(chunk.value))
      }
      const text = Buffer.concat(chunks).toString('utf8')
      const body = Buffer.from(rewritePlaylist(text, response.url || target, (absolute) => this.mediaUrl(absolute)), 'utf8')
      res.writeHead(200, {
        'Content-Type': 'application/vnd.apple.mpegurl',
        'Content-Length': body.length,
        'Cache-Control': 'no-cache'
      })
      return res.end(req.method === 'HEAD' ? undefined : body)
    }

    const headers = { 'Cache-Control': 'no-cache' }
    if (contentType) headers['Content-Type'] = contentType
    for (const name of ['content-length', 'content-range', 'accept-ranges', 'last-modified', 'etag']) {
      const value = response.headers.get(name)
      if (value) headers[name.replace(/(^|-)\w/g, c => c.toUpperCase())] = value
    }
    // fetch decodes compressed bodies, so the upstream length no longer matches what is sent.
    if (response.headers.get('content-encoding')) delete headers['Content-Length']
    if (response.status === 206 && !headers['Accept-Ranges']) headers['Accept-Ranges'] = 'bytes'
    res.writeHead(response.status, headers)
    if (req.method === 'HEAD' || !reader) {
      controller.abort()
      return res.end()
    }
    if (first) res.write(first)
    const rest = new ReadableStream({
      async pull (stream) {
        try {
          const chunk = await reader.read()
          if (chunk.done) stream.close()
          else stream.enqueue(chunk.value)
        } catch (error) {
          stream.error(error)
        }
      },
      cancel () {
        reader.cancel().catch(() => {})
      }
    })
    const node = Readable.fromWeb(rest)
    node.on('error', () => res.destroy())
    node.pipe(res)
  }

  /**
   * Looks at the source before casting: HLS (with the segment format of its first variant) or a progressive file
   * (with its content type).
   */
  async probe ({ url, headers }) {
    const fetchHeaders = { 'User-Agent': DEFAULT_USER_AGENT, ...sanitizeHeaders(headers) }
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 20_000)
    try {
      const response = await fetch(url, { headers: fetchHeaders, redirect: 'follow', signal: controller.signal })
      if (!response.ok) throw new Error(`The video server answered ${response.status}`)
      const contentType = response.headers.get('content-type') || ''
      const reader = response.body?.getReader()
      const chunk = reader ? await reader.read() : { done: true }
      const first = chunk.done ? null : Buffer.from(chunk.value)
      if (!isPlaylistStart(first) && !/mpegurl/i.test(contentType) && !/\.m3u8?($|[?#])/i.test(url)) {
        reader?.cancel().catch(() => {})
        return { kind: 'file', contentType: fileContentType(contentType, response.url || url) }
      }
      const chunks = first ? [first] : []
      for (;;) {
        const next = await reader.read()
        if (next.done) break
        chunks.push(Buffer.from(next.value))
      }
      let text = Buffer.concat(chunks).toString('utf8')
      const variants = variantUrls(text, response.url || url)
      if (variants.length) {
        const variant = await fetch(variants[0], { headers: fetchHeaders, redirect: 'follow', signal: controller.signal })
        if (variant.ok) text = await variant.text()
      }
      return { kind: 'hls', ...segmentFormat(text) }
    } finally {
      clearTimeout(timer)
    }
  }
}
