import { getDownloadManager, hlsJsPath } from './manager.js'

// Local playback of the downloads on the stream proxy (streamProxy.js): http://localhost:<port>/downloads/<id>/<file>.
// sendFile answers Range requests, so seeking works for direct files; hls.js reads the local playlists.

const SEND_OPTIONS = {
  dotfiles: 'allow',
  acceptRanges: true,
  headers: {
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-cache'
  }
}

/**
 * @param {import('express').Express} expressApp
 */
export function registerDownloadRoutes (expressApp) {
  expressApp.get('/downloads/hls.js', (req, res) => {
    res.sendFile(hlsJsPath(), { ...SEND_OPTIONS, headers: { ...SEND_OPTIONS.headers, 'Content-Type': 'application/javascript' } }, (error) => {
      if (error && !res.headersSent) res.status(404).end()
    })
  })

  expressApp.get(/^\/downloads\/([^/]+)\/(.+)$/, (req, res) => {
    const manager = getDownloadManager()
    let id
    let file
    try {
      id = decodeURIComponent(req.params[0])
      file = decodeURIComponent(req.params[1])
    } catch {
      return res.status(400).end()
    }
    const path = manager?.filePath(id, file)
    if (!path) return res.status(404).end()
    const headers = /\.m3u8$/i.test(path) ? { ...SEND_OPTIONS.headers, 'Content-Type': 'application/vnd.apple.mpegurl' } : SEND_OPTIONS.headers
    res.sendFile(path, { ...SEND_OPTIONS, headers }, (error) => {
      if (error && !res.headersSent) res.status(error.status || 404).end()
    })
  })
}
