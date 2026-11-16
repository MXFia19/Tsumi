import express from 'express'
import crypto from 'node:crypto'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { app } from 'electron'
import Debug from 'debug'
import { registerDownloadRoutes } from './downloads/routes.js'
import { rewritePlaylist } from './cast/hls.js'
import { sanitizeHeaders } from './cast/proxy.js'
import { isLoopbackHost, isWebUrl } from './security.js'

const debug = Debug('electron:streaming-proxy')

const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

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

      // General-purpose fetch proxy — supports all HTTP methods and custom headers
      // (including User-Agent, Cookie, Referer which are forbidden in browser fetch)
      router.post('/fetch', async (req, res) => {
        try {
          const { url, headers: reqHeaders, method, body: reqBody } = req.body || {}

          if (!url || !isWebUrl(url)) {
            return res.status(400).json({ error: 'Missing or invalid url' })
          }

          const fetchOptions = {
            method: (method || 'GET').toUpperCase(),
            headers: {
              'User-Agent': DEFAULT_USER_AGENT,
              ...(reqHeaders || {})
            }
          }

          if (reqBody != null && fetchOptions.method !== 'GET' && fetchOptions.method !== 'HEAD') {
            fetchOptions.body = typeof reqBody === 'string' ? reqBody : JSON.stringify(reqBody)
          }

          const response = await fetch(url, fetchOptions)

          const contentType = response.headers.get('content-type') || 'application/octet-stream'
          res.setHeader('Content-Type', contentType)

          // Forward Set-Cookie so extensions can read cookies from responses
          const setCookie = response.headers.getSetCookie?.() || []
          if (setCookie.length) {
            res.setHeader('X-Set-Cookie', JSON.stringify(setCookie))
          }

          res.status(response.status)
          const buffer = await response.arrayBuffer()
          res.send(Buffer.from(buffer))
        } catch (error) {
          debug('Fetch proxy error:', error?.message)
          if (!res.headersSent) {
            res.status(500).json({ error: error.message })
          }
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
          const isM3U8 = /\.m3u8?($|[?#])/i.test(new URL(finalUrl).pathname) || url.toLowerCase().includes('.m3u8') || /mpegurl/i.test(contentType)

          if (isM3U8) {
            // Playlists are rewritten so their variants, segments, keys and maps come back through the proxy too.
            const text = await response.text()
            const body = Buffer.from(rewritePlaylist(text, finalUrl, absolute => getProxyUrl(absolute, streamHeaders)), 'utf-8')
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

          if (!response.body || req.method === 'HEAD') {
            controller.abort()
            return res.end()
          }
          await pipeline(Readable.fromWeb(response.body), res)
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
