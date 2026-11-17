import express from 'express'
import crypto from 'node:crypto'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { app } from 'electron'
import Debug from 'debug'
import { registerDownloadRoutes } from './downloads/routes.js'
import { isPlaylistStart, rewritePlaylist } from './cast/hls.js'
import { sanitizeHeaders } from './cast/proxy.js'
import { isLoopbackHost, isWebUrl } from './security.js'
import {
  DEFAULT_USER_AGENT, MAX_RESPONSE_BYTES, moduleFetch, decodersFor, byteLimit, tooLargeError, readHead, readRest, bodyChunks
} from './proxyUpstream.js'

const debug = Debug('electron:streaming-proxy')

/** Largest playlist rewritten by /proxy (a long VOD playlist is a few MB at most). */
const MAX_PLAYLIST_BYTES = 32 * 1024 * 1024

let server = null
let expressApp = null

/**
 * Every route of the proxy starts with this unguessable path segment (new on each launch). With the Host check below,
 * a web page open in a browser of this computer can neither use the proxy (to reach the LAN with any header) nor read
 * the downloads. The page of the app gets it with electron:getProxyBase / electron:getProxyPort (app.js).
 */
export const proxyToken = crypto.randomBytes(24).toString('hex')

function port () {
  return server?.address()?.port || null
}

/** "http://localhost:<port>/<token>", or null while the proxy is not running. */
export function proxyBase () {
  const current = port()
  return current ? `http://localhost:${current}/${proxyToken}` : null
}

/**
 * URL of a stream through the proxy, which adds `headers` to the upstream requests (also for the segments of an HLS
 * playlist). Returns the URL itself when the proxy is not running.
 * @param {string} streamUrl
 * @param {Record<string, string>} [headers]
 */
export function getProxyUrl (streamUrl, headers = {}) {
  const base = proxyBase()
  if (!base) return streamUrl
  return `${base}/proxy?url=${encodeURIComponent(streamUrl)}&headers=${encodeURIComponent(JSON.stringify(headers || {}))}`
}

/** Fetch of an upstream URL tied to the client connection: aborted when the player closes it (seek, stop...). */
function upstreamController (res) {
  const controller = new AbortController()
  res.on('close', () => {
    if (!res.writableFinished) controller.abort()
  })
  return controller
}

export async function startStreamProxy () {
  if (server) return port()

  return new Promise((resolve, reject) => {
    try {
      expressApp = express()

      // Only requests addressed to localhost: a DNS name that resolves to 127.0.0.1 (DNS rebinding) is refused.
      // No CORS headers anywhere: the app page has webSecurity off, so it reads the answers anyway, while other
      // origins can't.
      expressApp.use((req, res, next) => {
        if (!isLoopbackHost(req.headers.host, port())) return res.status(403).end()
        next()
      })

      const router = express.Router()
      router.use(express.json({ limit: '10mb' }))

      // Requests of the Sora modules (fetchv2, common/modules/extension.js): any method, and the headers a page cannot
      // set (User-Agent, Cookie, Referer...). The network rules of the modules apply here, where the connection is made
      // (proxyUpstream.js): no local address, also after a redirect or through a public name that resolves to one,
      // unless the module itself is local (allowLocal, sent by the renderer from where the module was installed). The
      // body is streamed with the same cap as in the renderer and the upstream request stops when the renderer's does.
      // Headers of the answer: X-Final-Url (after redirects), X-Redirected, X-Location (the Location of a redirect
      // left to the module, redirect: 'manual'; a real Location would make the renderer's fetch follow it),
      // X-Set-Cookie. A request that could not be made answers 502 with X-Proxy-Error and { error }.
      router.post('/fetch', async (req, res) => {
        const { url, headers: reqHeaders, method, body: reqBody, redirect, allowLocal } = req.body || {}
        if (typeof url !== 'string' || !isWebUrl(url)) {
          return res.status(400).json({ error: 'Missing or invalid url' })
        }

        const controller = upstreamController(res)
        const fail = (error) => {
          if (res.headersSent) return res.destroy()
          res.status(502).setHeader('X-Proxy-Error', '1')
          res.json({ error: error?.message || 'Request failed' })
        }
        const redirectMode = redirect === 'manual' || redirect === 'error' ? redirect : 'follow'
        let upstream
        try {
          upstream = await moduleFetch({
            url,
            method,
            headers: reqHeaders && typeof reqHeaders === 'object' ? reqHeaders : {},
            body: reqBody == null ? null : typeof reqBody === 'string' ? reqBody : JSON.stringify(reqBody),
            redirect: redirectMode,
            allowLocal: allowLocal === true,
            signal: controller.signal
          })
        } catch (error) {
          // The renderer gave up (module timeout, cancelled search): nothing to answer.
          if (controller.signal.aborted) return
          debug('Fetch proxy error:', error?.message)
          return fail(error)
        }

        const { response } = upstream
        const declared = Number(response.headers['content-length'])
        if (Number.isFinite(declared) && declared > MAX_RESPONSE_BYTES) {
          response.destroy()
          return fail(tooLargeError())
        }
        res.status(response.statusCode)
        res.setHeader('Content-Type', response.headers['content-type'] || 'application/octet-stream')
        res.setHeader('X-Final-Url', upstream.url)
        if (upstream.redirected) res.setHeader('X-Redirected', '1')
        if (redirectMode === 'manual' && response.headers.location) res.setHeader('X-Location', response.headers.location)
        // Set-Cookie of the answer, so extensions can read the cookies.
        const setCookie = response.headers['set-cookie'] || []
        if (setCookie.length) res.setHeader('X-Set-Cookie', JSON.stringify(setCookie))

        try {
          // Decoded here like fetch does (the renderer gets plain bytes), counted after decoding like readCapped.
          const decoders = decodersFor(response.headers['content-encoding'], { method: response.req?.method, status: response.statusCode })
          await pipeline(response, ...decoders, byteLimit(MAX_RESPONSE_BYTES), res)
        } catch (error) {
          // pipeline destroyed both ends: the renderer's request fails (body over the cap, broken connection), or the
          // renderer had already given up.
          if (error?.name !== 'AbortError') debug('Fetch proxy body error:', error?.message)
        }
      })

      router.get('/proxy', async (req, res) => {
        // Express already decoded the query once: decoding again would break signed links (%2F, %2B...).
        const { url, headers } = req.query
        if (typeof url !== 'string' || !isWebUrl(url)) {
          return res.status(400).json({ error: 'Missing or invalid url parameter' })
        }
        let streamHeaders = {}
        try {
          streamHeaders = typeof headers === 'string' && headers ? sanitizeHeaders(JSON.parse(headers)) : {}
        } catch {
          return res.status(400).json({ error: 'Invalid headers parameter' })
        }

        const fetchHeaders = { 'User-Agent': DEFAULT_USER_AGENT, ...streamHeaders }
        // Forward Range header for video seeking support
        if (req.headers.range) fetchHeaders.Range = req.headers.range

        const controller = upstreamController(res)
        try {
          const response = await fetch(url, { headers: fetchHeaders, redirect: 'follow', signal: controller.signal })

          if (!response.ok && response.status !== 206) {
            response.body?.cancel().catch(() => {})
            return res.status(response.status).json({ error: `Stream request failed: ${response.status}` })
          }

          const contentType = response.headers.get('content-type') || 'application/octet-stream'
          res.setHeader('Content-Type', contentType)
          res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate')

          // The final URL after redirects: relative playlist entries resolve against it, not against the requested one.
          const finalUrl = response.url || url
          // A playlist is recognized by its first bytes (#EXTM3U, which every HLS playlist starts with and hls.js
          // requires), like the Cast proxy does: not by its URL (a segment "seg-1.ts?pl=index.m3u8" would be decoded as
          // text and broken) nor by its content type (playlists served as text/plain would not be rewritten, and their
          // relative segments would then resolve against the proxy URL).
          const reader = response.body?.getReader()
          const start = reader ? await readHead(reader) : { head: Buffer.alloc(0), done: true }

          if (isPlaylistStart(start.head)) {
            // Playlists are rewritten so their variants, segments, keys and maps come back through the proxy too.
            const text = (await readRest(reader, start, MAX_PLAYLIST_BYTES)).toString('utf-8')
            const body = Buffer.from(rewritePlaylist(text, finalUrl, absolute => getProxyUrl(absolute, streamHeaders)), 'utf-8')
            res.setHeader('Content-Type', 'application/vnd.apple.mpegurl')
            res.setHeader('Content-Length', body.length)
            res.send(body)
            return
          }

          res.status(response.status)
          const contentLength = response.headers.get('content-length')
          const contentRange = response.headers.get('content-range')
          const acceptRanges = response.headers.get('accept-ranges')
          // fetch decodes compressed bodies, so the upstream length no longer matches what is sent.
          if (contentLength && !response.headers.get('content-encoding')) res.setHeader('Content-Length', contentLength)
          if (contentRange) res.setHeader('Content-Range', contentRange)
          if (acceptRanges) res.setHeader('Accept-Ranges', acceptRanges)

          if (!reader || req.method === 'HEAD') {
            controller.abort()
            return res.end()
          }
          await pipeline(Readable.from(bodyChunks(reader, start)), res)
        } catch (error) {
          // The player closed the connection (seek, stop, next episode): nothing to answer.
          if (controller.signal.aborted) return
          debug('Proxy error:', error?.message)
          if (!res.headersSent) res.status(502).json({ error: error.message })
          else res.destroy()
        }
      })

      registerDownloadRoutes(router)

      router.get('/health', (req, res) => {
        res.json({ status: 'ok' })
      })

      expressApp.use(`/${proxyToken}`, router)

      server = expressApp.listen(0, 'localhost', () => {
        debug(`Proxy server listening on port ${port()}`)
        resolve(port())
      })

      server.on('error', reject)
    } catch (error) {
      debug('Failed to start proxy:', error)
      reject(error)
    }
  })
}

export async function stopStreamProxy () {
  if (!server) return

  return new Promise((resolve) => {
    server.close(() => {
      debug('Proxy server stopped')
      server = null
      expressApp = null
      resolve()
    })
    server.closeAllConnections?.()
  })
}

app.on('before-quit', async () => {
  await stopStreamProxy()
})
