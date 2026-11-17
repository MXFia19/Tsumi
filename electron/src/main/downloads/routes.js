import { readFile } from 'node:fs/promises'
import { getDownloadManager, hlsJsPath } from './manager.js'
import { isPinnedHlsJs } from './hlsjs.js'

// Local playback of the downloads on the stream proxy (streamProxy.js): http://localhost:<port>/<token>/downloads/<id>/<file>.
// sendFile answers Range requests, so seeking works for direct files; hls.js reads the local playlists.
// No CORS header: only the app page (webSecurity off) reads these files, other origins must not.

const SEND_OPTIONS = {
  dotfiles: 'allow',
  acceptRanges: true,
  headers: {
    'Cache-Control': 'no-cache'
  }
}

/**
 * @param {import('express').Router} router routes behind the secret path segment of the proxy
 */
export function registerDownloadRoutes (router) {
  // The offline hls.js runs in the app page: served only when it is exactly the pinned file (checked on every request,
  // the file on disk could have been replaced since it was saved).
  router.get('/downloads/hls.js', async (req, res) => {
    const data = await readFile(hlsJsPath()).catch(() => null)
    if (!isPinnedHlsJs(data)) return res.status(404).end()
    res.set({ ...SEND_OPTIONS.headers, 'Content-Type': 'application/javascript' }).send(data)
  })

  // Express already decodes the captured groups (req.params): they are used as they are.
  router.get(/^\/downloads\/([^/]+)\/(.+)$/, (req, res) => {
    const manager = getDownloadManager()
    const id = req.params[0]
    const file = req.params[1]
    const path = manager?.filePath(id, file)
    if (!path) return res.status(404).end()
    const headers = /\.m3u8$/i.test(path) ? { ...SEND_OPTIONS.headers, 'Content-Type': 'application/vnd.apple.mpegurl' } : SEND_OPTIONS.headers
    res.sendFile(path, { ...SEND_OPTIONS, headers }, (error) => {
      if (error && !res.headersSent) res.status(error.status || 404).end()
    })
  })
}
