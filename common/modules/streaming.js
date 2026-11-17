import { ELECTRON } from '@/modules/bridge.js'
import { toast } from 'svelte-sonner'
import Debug from 'debug'

const debug = Debug('ui:streaming')

let hlsLibrary
/** hls.js load in progress (loadHLSLibrary), shared by the streams that wait for it. */
let hlsLoading = null
let hlsErrorShown = false
/** "http://localhost:<port>/<token>" of the local proxy (electron/src/main/streamProxy.js), null until it runs. */
let proxyBase = null

// hls.js runs in the app page, which has the IPC bridge: it is pinned to one exact file. The browser runs it only when
// its SHA-384 matches (Subresource Integrity), so a compromised or altered CDN copy cannot run code here. The offline
// copy of the downloads is checked against the same hash by the main process before it is saved and served
// (electron/src/main/downloads/hlsjs.js holds the same URL and hash; hlsjs.test.mjs checks they agree).
const HLS_JS_URL = 'https://cdn.jsdelivr.net/npm/hls.js@1.4.5/dist/hls.min.js'
const HLS_JS_INTEGRITY = 'sha384-GuEz/RD9TfqZhxw9UmeaUmXVz/VDbz+NxBf7oRFs1rrMHPPA429NgphPL6PvdviR'
// A CDN that is blocked or does not answer fails after this, instead of the browser's own timeout (minutes).
const HLS_JS_TIMEOUT = 15000
const HLS_JS_OFFLINE_TIMEOUT = 5000

// Downloaded episodes are served by the local proxy itself (electron/src/main/downloads/routes.js).
const localDownloadRx = /^http:\/\/(localhost|127\.0\.0\.1):\d+\/(?:[0-9a-f]+\/)?downloads\//i

// Recoveries of a fatal hls.js error once playback started (counted again after each buffered fragment).
const NETWORK_RECOVERIES = 3
const MEDIA_RECOVERIES = 2

function getProxyUrl (streamUrl, headers = {}, base) {
  if (!base || localDownloadRx.test(streamUrl)) return streamUrl
  const encodedUrl = encodeURIComponent(streamUrl)
  const encodedHeaders = encodeURIComponent(JSON.stringify(headers || {}))
  return `${base}/proxy?url=${encodedUrl}&headers=${encodedHeaders}`
}

/** Host of a stream for the logs (never the full URL: links carry tokens). */
function streamHost (url) {
  try {
    return new URL(url).host
  } catch {
    return '?'
  }
}

/**
 * Adds a script to the page. `label` names it in errors (never the full URL: the local one carries the proxy token).
 * @param {string} src
 * @param {{ label: string, integrity?: string, timeout?: number }} options
 */
function loadScript (src, { label, integrity, timeout = 0 }) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script')
    let timer = null
    const fail = (error) => {
      clearTimeout(timer)
      script.onload = script.onerror = null
      script.remove()
      reject(error)
    }
    if (integrity) {
      // Subresource Integrity needs a CORS request (jsDelivr allows any origin).
      script.integrity = integrity
      script.crossOrigin = 'anonymous'
    }
    script.src = src
    script.async = true
    script.onload = () => {
      clearTimeout(timer)
      resolve()
    }
    // Also what the browser reports when the file does not match `integrity`.
    script.onerror = () => fail(new Error(`${label} could not be loaded${integrity ? ' (unreachable, or not the expected file)' : ''}`))
    if (timeout) timer = setTimeout(() => fail(new Error(`${label} did not answer within ${timeout / 1000} s`)), timeout)
    document.head.appendChild(script)
  })
}

/** hls.js: from the CDN, else the offline copy saved with the HLS downloads (served by the local proxy). */
async function loadHLSScript () {
  try {
    try {
      await loadScript(HLS_JS_URL, { label: 'hls.js from cdn.jsdelivr.net', integrity: HLS_JS_INTEGRITY, timeout: HLS_JS_TIMEOUT })
    } catch (error) {
      debug('hls.js CDN failed, trying the offline copy:', error.message)
      const base = await getProxyBaseInternal()
      if (!base) throw error
      try {
        await loadScript(`${base}/downloads/hls.js`, { label: 'the offline hls.js', timeout: HLS_JS_OFFLINE_TIMEOUT })
      } catch {
        // The offline copy exists only once an HLS episode was downloaded: the CDN error is the one to show.
        throw error
      }
    }
    hlsLibrary = window.Hls || null
    return hlsLibrary
  } catch (error) {
    debug('HLS.js unavailable, using native playback:', error)
    if (!hlsErrorShown) {
      hlsErrorShown = true
      toast.error('HLS Player Unavailable', {
        description: `${error.message}. HLS streams may not play: check the connection, or whether cdn.jsdelivr.net is blocked on this network.`,
        duration: 10000
      })
    }
    return null
  }
}

async function loadHLSLibrary () {
  if (hlsLibrary) return hlsLibrary
  if (typeof window === 'undefined') return null
  if (window.Hls) return (hlsLibrary = window.Hls)
  // One load at a time; after a failure the next stream tries again.
  if (!hlsLoading) hlsLoading = loadHLSScript().finally(() => { hlsLoading = null })
  return hlsLoading
}

async function getProxyBaseInternal () {
  if (proxyBase) return proxyBase

  try {
    proxyBase = (await ELECTRON.getProxyBase?.()) || null
  } catch (error) {
    debug('Could not get the proxy address:', error)
  }
  return proxyBase
}

/** Stops the hls.js instance attached to the element, if any. */
function destroyHls (video) {
  const instance = video._hlsInstance
  video._hlsInstance = null
  if (!instance) return
  try {
    instance.destroy()
  } catch (error) {
    debug('hls.js destroy failed:', error)
  }
}

/**
 * A fatal hls.js error that could not be recovered after playback started: the element would otherwise stay black
 * without a word. The player gets it through options.onError when it passes one; otherwise a toast offers to reload
 * the stream where it stopped.
 */
function reportFatal (video, streamUrl, options, data) {
  const reason = `${data.type || 'error'}${data.details ? ` (${data.details})` : ''}`
  const error = new Error(`The stream stopped: ${reason}`)
  if (typeof options.onError === 'function') {
    options.onError(error)
    return
  }
  const resumeAt = video.currentTime || 0
  toast.error('Stream Error', {
    description: `The video stream stopped and could not be recovered (${reason}). Dismiss this toast to reload it, or pick another server.`,
    duration: Infinity,
    onDismiss: () => {
      // Only while the player still shows this stream (not another episode or server loaded since).
      if (!video.isConnected || video._streamUrl !== streamUrl || video._hlsInstance) return
      loadStream(video, streamUrl, { ...options, startPosition: resumeAt }).catch(error => debug('Stream reload failed:', error))
    }
  })
}

/**
 * Plays a stream in a <video> element: through the local proxy (which adds the headers of the source), with hls.js
 * for HLS. A newer loadStream or stopStream on the same element wins: an older call that was still waiting returns a
 * promise that never settles, so its caller does not go on with a stream that is no longer shown.
 * @param {HTMLVideoElement & { _hlsInstance?: any, _streamUrl?: string | null, _streamLoad?: number }} video
 * @param {string} streamUrl
 * @param {{ headers?: Record<string, string>, lowLatency?: boolean, startPosition?: number, onError?: (error: Error) => void }} [options]
 */
export async function loadStream (video, streamUrl, options = {}) {
  if (!video) throw new Error('No video element provided')
  if (!streamUrl) throw new Error('No stream URL provided')

  const load = (video._streamLoad = (video._streamLoad || 0) + 1)
  const superseded = () => video._streamLoad !== load
  const pending = () => new Promise(() => {})

  const isHLS = streamUrl.toLowerCase().includes('.m3u8')

  if (!isHLS) {
    const base = await getProxyBaseInternal()
    if (superseded()) return pending()
    destroyHls(video)
    video._streamUrl = streamUrl
    video.src = getProxyUrl(streamUrl, options.headers, base)
    return
  }

  const Hls = await loadHLSLibrary()
  const base = await getProxyBaseInternal()
  if (superseded()) return pending()

  // A previous instance still attached to this element (fast server / episode switch) would keep loading and fight
  // over the media source.
  destroyHls(video)
  video._streamUrl = streamUrl

  // hls.js needs Media Source Extensions, which iPhones do not have: Safari/WKWebView
  // play HLS natively there.
  if (!Hls || !Hls.isSupported?.()) {
    debug('HLS.js unavailable or unsupported, using native playback')
    video.src = getProxyUrl(streamUrl, options.headers || {}, base)
    return
  }

  const hlsConfig = {
    debug: false,
    enableWorker: true,
    lowLatencyMode: !!options.lowLatency,
    testBandwidth: false,
    ...(options.startPosition > 0 ? { startPosition: options.startPosition } : {})
  }

  const hlsInstance = new Hls(hlsConfig)
  video._hlsInstance = hlsInstance
  const sourceUrl = getProxyUrl(streamUrl, options.headers || {}, base)
  debug(`Loading HLS source from ${streamHost(streamUrl)}${base ? ' through the local proxy' : ''}`)
  hlsInstance.loadSource(sourceUrl)
  hlsInstance.attachMedia(video)

  return new Promise((resolve, reject) => {
    let started = false
    let networkRecoveries = 0
    let mediaRecoveries = 0

    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {
      debug('Manifest parsed')
      started = true
      resolve()
    })

    hlsInstance.on(Hls.Events.FRAG_BUFFERED, () => {
      networkRecoveries = 0
      mediaRecoveries = 0
    })

    hlsInstance.on(Hls.Events.ERROR, (event, data) => {
      if (!data.fatal) {
        debug('Recoverable error:', data.type, data.details)
        return
      }
      // Another stream was loaded on this element since: this instance is gone.
      if (video._hlsInstance !== hlsInstance) return
      debug('Fatal error:', data.type, data.details)
      if (!started) {
        destroyHls(video)
        reject(new Error(`Error: ${data.type}`))
        return
      }
      // Playback had started: recover like the hls.js documentation recommends before giving up.
      if (data.type === Hls.ErrorTypes.NETWORK_ERROR && networkRecoveries < NETWORK_RECOVERIES) {
        networkRecoveries++
        debug(`Network error, reloading (${networkRecoveries}/${NETWORK_RECOVERIES})`)
        hlsInstance.startLoad()
        return
      }
      if (data.type === Hls.ErrorTypes.MEDIA_ERROR && mediaRecoveries < MEDIA_RECOVERIES) {
        mediaRecoveries++
        debug(`Media error, recovering (${mediaRecoveries}/${MEDIA_RECOVERIES})`)
        // A second media error in a row is often an audio codec mismatch.
        if (mediaRecoveries > 1) hlsInstance.swapAudioCodec()
        hlsInstance.recoverMediaError()
        return
      }
      destroyHls(video)
      reportFatal(video, streamUrl, options, data)
    })
  })
}

export function stopStream (video) {
  if (!video) return

  // A load still waiting for hls.js / the proxy must not attach its stream after this.
  video._streamLoad = (video._streamLoad || 0) + 1
  destroyHls(video)
  video._streamUrl = null

  video.src = ''
}

export function parseStreamResponse (response) {
  if (typeof response === 'string') {
    return {
      url: response,
      headers: {},
      subtitle: null,
      alternatives: []
    }
  }

  if (response?.streams && Array.isArray(response.streams)) {
    if (response.streams.length && typeof response.streams[0] === 'string') {
      const servers = []
      for (let i = 0; i < response.streams.length; i += 2) {
        if (i + 1 < response.streams.length) {
          servers.push({ title: response.streams[i], streamUrl: response.streams[i + 1], headers: response.headers || {} })
        }
      }
      if (servers.length) {
        return {
          url: servers[0].streamUrl,
          headers: servers[0].headers || {},
          subtitle: response.subtitles || response.subtitle || null,
          alternatives: servers.slice(1),
          servers
        }
      }
    }
    const firstStream = response.streams[0]
    return {
      url: firstStream.streamUrl,
      headers: firstStream.headers || {},
      subtitle: response.subtitles || response.subtitle || null,
      alternatives: response.streams.slice(1),
      servers: response.streams
    }
  }

  if (response?.streamUrl) {
    return {
      url: response.streamUrl,
      headers: response.headers || {},
      subtitle: response.subtitles || response.subtitle || null,
      alternatives: [],
      servers: [{ title: 'Server', streamUrl: response.streamUrl, headers: response.headers || {} }]
    }
  }

  throw new Error('Invalid stream response')
}

export function getStreamServers (response) {
  if (typeof response === 'string') {
    return [{ title: 'Server', streamUrl: response }]
  }

  if (response?.streams && Array.isArray(response.streams)) {
    return response.streams
  }

  if (response?.streamUrl) {
    return [{ title: 'Server', streamUrl: response.streamUrl, headers: response.headers }]
  }

  return []
}

export default parseStreamResponse
