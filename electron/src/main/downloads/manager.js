import { app, ipcMain, dialog, shell } from 'electron'
import { join, resolve, sep, dirname } from 'node:path'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import {
  isMasterPlaylist, isPlaylistText, parseMasterPlaylist, pickVariant, pickAudioRendition, planMediaPlaylist,
  buildLocalMaster, looksLikeHls, looksLikeDash
} from './hls.js'
import { sanitizeName, episodeLabel, downloadId, subtitleExtension, videoExtension, totalFromContentRange, httpErrorMessage } from './naming.js'

// Offline downloads (see common/modules/downloads.js for the renderer side).
// The renderer owns the extensions, so it resolves a fresh stream URL each time a download starts (source
// links expire); this process downloads the file (resumable with Range) or the HLS playlist (variant of the
// quality setting, segments, AES-128 keys and init segments, local playlists) into
// <download folder>/<title>/<episode>/, and serves the finished files on the local stream proxy
// (/downloads/<id>/<file>) so the player plays them without network.

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
const HLS_JS_URL = 'https://cdn.jsdelivr.net/npm/hls.js@1.4.5'
const SEGMENT_WORKERS = 4
const RESOLVE_TIMEOUT = 180_000
/** A stream already resolved by the player is used when a fresh resolution fails and it is younger than this. */
const SEED_MAX_AGE = 15 * 60_000
const AUTO_RETRIES = 2
const ACTIVE = ['resolving', 'downloading']
/** Files written in an episode folder (the only ones deleted with it). */
const OWN_FILE = /^(video\.|v-|a-|index\.m3u8$|audio\.m3u8$|subtitle-|cover\.|metadata\.json$)/
const STALL_TIMEOUT = 60_000

class DownloadError extends Error {
  constructor (message, { final = false } = {}) {
    super(message)
    this.final = final
  }
}

function friendlyError (error) {
  if (error instanceof DownloadError) return error.message
  const code = error?.code || error?.cause?.code
  if (code === 'ENOSPC') return 'Not enough disk space in the download folder.'
  if (code === 'EACCES' || code === 'EPERM') return 'The download folder is not writable. Pick another one in Settings.'
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN' || code === 'ECONNREFUSED' || code === 'ECONNRESET' || code === 'ETIMEDOUT' || /fetch failed|network/i.test(error?.message || '')) {
    return 'Network error while downloading. It will continue from where it stopped when you retry.'
  }
  return error?.message || 'Download failed'
}

function isRetryable (error) {
  if (error instanceof DownloadError) return !error.final
  const code = error?.code || error?.cause?.code
  return code !== 'ENOSPC' && code !== 'EACCES' && code !== 'EPERM'
}

const wait = (ms, signal) => new Promise((resolve, reject) => {
  const timer = setTimeout(resolve, ms)
  signal?.addEventListener('abort', () => {
    clearTimeout(timer)
    reject(signal.reason || new Error('aborted'))
  }, { once: true })
})

async function exists (path) {
  try {
    await fsp.access(path)
    return true
  } catch {
    return false
  }
}

async function directorySize (path) {
  let total = 0
  let entries = []
  try {
    entries = await fsp.readdir(path, { withFileTypes: true })
  } catch {
    return 0
  }
  for (const entry of entries) {
    const child = join(path, entry.name)
    if (entry.isDirectory()) total += await directorySize(child)
    else {
      try {
        total += (await fsp.stat(child)).size
      } catch {}
    }
  }
  return total
}

/** Media fields kept with a download (the player and the Downloads page work from them offline). */
function trimMedia (media) {
  if (!media || typeof media !== 'object') return null
  const copy = JSON.parse(JSON.stringify(media))
  for (const key of ['relations', 'recommendations', 'characters', 'staff', 'stats', 'reviews', 'externalLinks', 'rankings']) delete copy[key]
  return copy
}

function mediaTitle (media) {
  return media?.title?.userPreferred || media?.title?.english || media?.title?.romaji || media?.title?.native || media?.name || 'Untitled'
}

/** @type {DownloadManager | null} */
let instance = null
export function getDownloadManager () {
  return instance
}

export const hlsJsPath = () => join(app.getPath('userData'), 'Downloads Cache', 'hls.js')

export default class DownloadManager {
  /** @type {Map<string, any>} */
  items = new Map()
  /** @type {Map<string, { controller: AbortController }>} */
  running = new Map()
  /** @type {Map<string, { resolve: Function, reject: Function, timer: any }>} */
  pending = new Map()
  config = { folder: '', maxConcurrent: 2, quality: 'highest' }
  ready = false
  dirty = new Set()
  sendTimer = null
  saveTimer = null
  indexPath = join(app.getPath('userData'), 'downloads.json')

  /**
   * @param {import('electron').BrowserWindow} window
   */
  constructor (window) {
    instance = this
    this.window = window
    this.load()

    ipcMain.handle('downloads:list', () => this.snapshot())
    ipcMain.handle('downloads:add', (_event, requests) => this.add(requests))
    ipcMain.handle('downloads:action', (_event, { action, id } = {}) => this.action(action, id))
    ipcMain.handle('downloads:info', () => ({ folder: this.root(), defaultFolder: this.defaultRoot() }))
    ipcMain.handle('downloads:choose-folder', async () => {
      const { canceled, filePaths } = await dialog.showOpenDialog({ title: 'Select the download folder', defaultPath: this.root(), properties: ['openDirectory', 'createDirectory'] })
      return canceled ? null : filePaths[0] || null
    })
    ipcMain.on('downloads:config', (_event, config) => this.setConfig(config))
    ipcMain.on('downloads:ready', (_event, config) => {
      this.setConfig(config)
      this.ready = true
      // A reloaded renderer lost the resolutions it was running: ask again.
      for (const item of this.items.values()) {
        if (item.status === 'resolving' && this.pending.has(item.id)) this.requestResolve(item)
      }
      this.pump()
    })
    ipcMain.on('downloads:resolved', (_event, data) => this.resolved(data))
    ipcMain.on('downloads:open-folder', (_event, id) => {
      const item = id && this.items.get(id)
      const target = item ? item.dir : this.root()
      fs.mkdirSync(target, { recursive: true })
      shell.openPath(target)
    })
    app.on('will-quit', () => this.saveSync())
  }

  // ---- Persistence

  load () {
    try {
      const stored = JSON.parse(fs.readFileSync(this.indexPath, 'utf8'))
      for (const item of Array.isArray(stored) ? stored : []) {
        if (!item?.id) continue
        // Interrupted by a quit: continue on this launch (with a fresh link).
        if (ACTIVE.includes(item.status)) item.status = 'queued'
        item.speed = 0
        this.items.set(item.id, item)
      }
    } catch {}
  }

  serialize (item) {
    const { speed, ...rest } = item
    return rest
  }

  save () {
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => {
      fsp.writeFile(this.indexPath, JSON.stringify([...this.items.values()].map(item => this.serialize(item)))).catch(() => {})
    }, 1000)
    this.saveTimer.unref?.()
  }

  saveSync () {
    clearTimeout(this.saveTimer)
    try {
      fs.writeFileSync(this.indexPath, JSON.stringify([...this.items.values()].map(item => this.serialize(item))))
    } catch {}
  }

  async writeMetadata (item) {
    try {
      await fsp.writeFile(join(item.dir, 'metadata.json'), JSON.stringify(this.serialize({ ...item, seed: undefined }), null, 2))
    } catch {}
  }

  // ---- Renderer updates

  snapshot () {
    return [...this.items.values()].sort((a, b) => a.createdAt - b.createdAt)
  }

  changed (item, immediate = false) {
    item.updatedAt = Date.now()
    this.dirty.add(item.id)
    this.save()
    if (immediate) return this.flush()
    if (this.sendTimer) return
    this.sendTimer = setTimeout(() => this.flush(), 400)
    this.sendTimer.unref?.()
  }

  flush () {
    clearTimeout(this.sendTimer)
    this.sendTimer = null
    if (!this.dirty.size) return
    const updated = []
    const removed = []
    for (const id of this.dirty) {
      const item = this.items.get(id)
      if (item) updated.push(item)
      else removed.push(id)
    }
    this.dirty.clear()
    if (!this.window.isDestroyed()) this.window.webContents.send('downloads:update', { updated, removed })
  }

  // ---- Config

  defaultRoot () {
    return join(app.getPath('videos'), 'Tsumi')
  }

  root () {
    return this.config.folder || this.defaultRoot()
  }

  setConfig (config = {}) {
    const max = Math.round(Number(config.maxConcurrent))
    this.config = {
      folder: typeof config.folder === 'string' ? config.folder.trim() : '',
      maxConcurrent: Math.min(Math.max(Number.isFinite(max) ? max : 2, 1), 5),
      quality: typeof config.quality === 'string' ? config.quality : 'highest'
    }
    this.pump()
  }

  // ---- Queue

  /**
   * @param {Array<{ media: any, episode: { number: number, season?: number, localEpisode?: number }, episodeTitle?: string, episodeImage?: string, source?: any, seed?: any }>} requests
   */
  async add (requests = []) {
    const added = []
    for (const request of Array.isArray(requests) ? requests : []) {
      if (!request?.media) continue
      const episode = {
        number: Number(request.episode?.number) || 0,
        season: request.episode?.season ?? null,
        localEpisode: request.episode?.localEpisode ?? null
      }
      const id = downloadId(request.media.id, episode)
      const existing = this.items.get(id)
      if (existing && existing.status !== 'failed') {
        if (existing.status === 'paused') await this.action('resume', id)
        added.push({ id, existing: true, status: existing.status })
        continue
      }
      const title = mediaTitle(request.media)
      const item = existing || {
        id,
        createdAt: Date.now(),
        dir: await this.uniqueDir(join(this.root(), sanitizeName(title), episodeLabel(episode)), id)
      }
      Object.assign(item, {
        media: trimMedia(request.media),
        mediaId: request.media.id,
        title,
        episode,
        episodeTitle: request.episodeTitle || item.episodeTitle || null,
        episodeImage: request.episodeImage || item.episodeImage || null,
        source: request.source || item.source || null,
        seed: request.seed ? { ...request.seed, at: request.seed.at || Date.now() } : null,
        status: 'queued',
        error: null,
        attempts: 0,
        kind: item.kind || null,
        bytes: item.bytes || 0,
        totalBytes: item.totalBytes || 0,
        progress: item.progress || 0,
        speed: 0
      })
      this.items.set(id, item)
      this.changed(item)
      added.push({ id, existing: false, status: item.status })
    }
    this.flush()
    this.pump()
    return added
  }

  /** Episode folder; another title already using the same name gets " (2)". */
  async uniqueDir (dir, id) {
    let candidate = dir
    for (let index = 2; index < 50; index++) {
      const taken = [...this.items.values()].some(item => item.id !== id && resolve(item.dir) === resolve(candidate))
      let foreign = false
      try {
        const metadata = JSON.parse(await fsp.readFile(join(candidate, 'metadata.json'), 'utf8'))
        foreign = metadata?.id && metadata.id !== id
      } catch {}
      if (!taken && !foreign) return candidate
      candidate = `${dir} (${index})`
    }
    return candidate
  }

  async action (action, id) {
    const item = this.items.get(id)
    if (!item) return false
    switch (action) {
      case 'pause':
        if (this.running.has(id)) this.running.get(id).controller.abort(new DownloadError('Paused'))
        if (item.status !== 'completed') {
          item.status = 'paused'
          item.speed = 0
          this.rejectPending(id, new DownloadError('Paused'))
        }
        break
      case 'resume':
      case 'retry':
        if (item.status === 'completed' || this.running.has(id)) break
        item.status = 'queued'
        item.error = null
        item.attempts = 0
        break
      case 'cancel':
      case 'delete':
        if (this.running.has(id)) this.running.get(id).controller.abort(new DownloadError('Canceled'))
        this.rejectPending(id, new DownloadError('Canceled'))
        this.items.delete(id)
        this.dirty.add(id)
        this.save()
        await this.removeFiles(item)
        this.flush()
        this.pump()
        return true
      default:
        return false
    }
    this.changed(item, true)
    this.pump()
    return true
  }

  /** Deletes the files this downloader wrote (never anything else), then the empty episode / title folders. */
  async removeFiles (item) {
    if (!item?.dir) return
    const target = resolve(item.dir)
    if (dirname(target) === target) return
    try {
      for (const name of await fsp.readdir(target)) {
        if (OWN_FILE.test(name)) await fsp.rm(join(target, name), { force: true, maxRetries: 3, retryDelay: 200 })
      }
      if (!(await fsp.readdir(target)).length) await fsp.rmdir(target)
      const parent = dirname(target)
      if (parent !== resolve(this.root()) && !(await fsp.readdir(parent)).length) await fsp.rmdir(parent)
    } catch {}
  }

  pump () {
    if (!this.ready) return
    let free = this.config.maxConcurrent - this.running.size
    if (free <= 0) return
    const queued = [...this.items.values()].filter(item => item.status === 'queued' && !this.running.has(item.id)).sort((a, b) => a.createdAt - b.createdAt)
    for (const item of queued) {
      if (free-- <= 0) break
      this.run(item)
    }
  }

  // ---- Stream resolution (renderer)

  requestResolve (item) {
    if (this.window.isDestroyed()) return
    this.window.webContents.send('downloads:resolve', {
      id: item.id,
      media: item.media,
      episode: item.episode,
      source: item.source
    })
  }

  resolveStream (item) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(item.id)
        const seed = this.freshSeed(item)
        if (seed) resolve(seed)
        else reject(new DownloadError('Timed out while getting a fresh link from the extension.'))
      }, RESOLVE_TIMEOUT)
      timer.unref?.()
      this.pending.set(item.id, { resolve, reject, timer })
      this.requestResolve(item)
    })
  }

  freshSeed (item) {
    return item.seed?.url && Date.now() - (item.seed.at || 0) < SEED_MAX_AGE ? item.seed : null
  }

  resolved ({ id, stream, error, final } = {}) {
    const pending = this.pending.get(id)
    if (!pending) return
    clearTimeout(pending.timer)
    this.pending.delete(id)
    if (stream?.url) return pending.resolve(stream)
    const seed = this.items.get(id) && this.freshSeed(this.items.get(id))
    if (seed) return pending.resolve(seed)
    pending.reject(new DownloadError(error || 'Could not get a stream for this episode.', { final: !!final }))
  }

  rejectPending (id, error) {
    const pending = this.pending.get(id)
    if (!pending) return
    clearTimeout(pending.timer)
    this.pending.delete(id)
    pending.reject(error)
  }

  // ---- Download

  async run (item) {
    const controller = new AbortController()
    const { signal } = controller
    this.running.set(item.id, { controller })
    item.status = 'resolving'
    item.error = null
    item.speed = 0
    this.changed(item, true)
    try {
      // Not started yet: follow a download folder changed in the meantime.
      if (!item.kind && !(await exists(item.dir))) item.dir = await this.uniqueDir(join(this.root(), sanitizeName(item.title), episodeLabel(item.episode)), item.id)
      const stream = await this.resolveStream(item)
      signal.throwIfAborted()
      if (stream.source) item.source = { ...(item.source || {}), ...stream.source }
      item.seed = null
      item.status = 'downloading'
      this.changed(item, true)
      await fsp.mkdir(item.dir, { recursive: true })
      await this.writeMetadata(item)
      const extras = Promise.allSettled([this.downloadCover(item, signal), this.downloadSubtitles(item, stream, signal)])
      await this.downloadMedia(item, stream, signal)
      await extras
      item.status = 'completed'
      item.completedAt = Date.now()
      item.progress = 1
      item.speed = 0
      item.sizeOnDisk = await directorySize(item.dir)
      item.bytes = item.sizeOnDisk
      item.totalBytes = item.sizeOnDisk
      await this.writeMetadata(item)
      this.changed(item, true)
    } catch (error) {
      if (signal.aborted || !this.items.has(item.id)) return
      item.speed = 0
      if (isRetryable(error) && (item.attempts || 0) < AUTO_RETRIES) {
        // Retries with a fresh link (expired URLs are the usual cause).
        item.attempts = (item.attempts || 0) + 1
        item.status = 'queued'
        item.error = null
        this.changed(item, true)
        await wait(4000).catch(() => {})
      } else {
        item.status = 'failed'
        item.error = friendlyError(error)
        this.changed(item, true)
      }
    } finally {
      this.running.delete(item.id)
      this.save()
      this.pump()
    }
  }

  headers (stream, extra = {}) {
    return { 'User-Agent': UA, ...(stream.headers || {}), ...extra }
  }

  async downloadMedia (item, stream, signal) {
    const url = stream.url
    if (/^(magnet:|blob:|data:)/i.test(url)) throw new DownloadError('This kind of source (torrent / in-page stream) can\'t be downloaded.', { final: true })
    if (looksLikeDash(url)) throw new DownloadError('DASH streams (.mpd) can\'t be downloaded yet. Try another server or source.', { final: true })
    if (looksLikeHls(url)) {
      const { text, finalUrl } = await this.fetchText(url, stream, signal)
      return this.downloadHls(item, stream, text, finalUrl, signal)
    }
    return this.downloadFile(item, stream, signal)
  }

  speedTracker (item) {
    let windowStart = Date.now()
    let windowBytes = 0
    return (bytes) => {
      windowBytes += bytes
      const now = Date.now()
      if (now - windowStart >= 1000) {
        item.speed = Math.round(windowBytes / ((now - windowStart) / 1000))
        windowStart = now
        windowBytes = 0
        this.changed(item)
      }
    }
  }

  // Direct file: one request, resumed with Range after a pause / failure / quit.
  async downloadFile (item, stream, signal) {
    const partPath = join(item.dir, 'video.part')
    const track = this.speedTracker(item)
    for (let attempt = 0; ; attempt++) {
      let start = item.kind === 'file' && (await exists(partPath)) ? (await fsp.stat(partPath)).size : 0
      // A connection that stops sending data is dropped and resumed.
      const stall = new AbortController()
      const requestSignal = AbortSignal.any([signal, stall.signal])
      let stallTimer = setTimeout(() => stall.abort(new Error('network: stalled')), STALL_TIMEOUT)
      const response = await fetch(stream.url, { headers: this.headers(stream, start > 0 ? { Range: `bytes=${start}-` } : {}), signal: requestSignal, redirect: 'follow' }).finally(() => clearTimeout(stallTimer))
      if (response.status === 416 && start > 0 && item.totalBytes && start >= item.totalBytes) {
        await response.body?.cancel().catch(() => {})
        break
      }
      if (!response.ok) {
        await response.body?.cancel().catch(() => {})
        throw new DownloadError(httpErrorMessage(response.status))
      }
      const contentType = response.headers.get('content-type') || ''
      const length = Number(response.headers.get('content-length')) || 0
      // HLS playlists served without .m3u8 / with a generic type are recognized by their content.
      if (looksLikeHls(response.url, contentType) || (start === 0 && /text\/plain|octet-stream|binary/i.test(contentType) && length > 0 && length < 512 * 1024)) {
        const text = await response.text()
        if (isPlaylistText(text)) return this.downloadHls(item, stream, text, response.url, signal)
        throw new DownloadError(looksLikeHls(response.url, contentType) ? 'The source did not return a playable HLS playlist (expired or protected link).' : 'The source returned an unexpected file instead of a video.')
      }
      if (looksLikeDash(response.url, contentType)) {
        await response.body?.cancel().catch(() => {})
        throw new DownloadError('DASH streams (.mpd) can\'t be downloaded yet. Try another server or source.', { final: true })
      }
      if (/text\/html/i.test(contentType)) {
        await response.body?.cancel().catch(() => {})
        throw new DownloadError('The source returned a web page instead of a video (expired or protected link).')
      }
      const resumed = response.status === 206 && start > 0
      const total = response.status === 206 ? totalFromContentRange(response.headers.get('content-range')) : Number(response.headers.get('content-length')) || 0
      if (resumed && item.totalBytes && total && total !== item.totalBytes) {
        // The fresh link serves another file: start over.
        await response.body?.cancel().catch(() => {})
        await fsp.rm(partPath, { force: true })
        item.kind = null
        continue
      }
      if (!resumed) start = 0
      item.kind = 'file'
      item.extension = videoExtension(response.url, contentType)
      item.totalBytes = total || 0
      item.bytes = start
      this.changed(item, true)
      const body = Readable.fromWeb(response.body)
      stallTimer = setTimeout(() => stall.abort(new Error('network: stalled')), STALL_TIMEOUT)
      body.on('data', (chunk) => {
        item.bytes += chunk.length
        if (item.totalBytes) item.progress = Math.min(item.bytes / item.totalBytes, 0.999)
        track(chunk.length)
        stallTimer.refresh()
      })
      try {
        await pipeline(body, fs.createWriteStream(partPath, { flags: resumed ? 'a' : 'w' }), { signal: requestSignal })
        if (item.totalBytes && item.bytes < item.totalBytes) throw new Error('network: connection closed early')
        break
      } catch (error) {
        if (signal.aborted || !isRetryable(error) || attempt >= 4) throw error
        await wait(2000 * (attempt + 1), signal)
      } finally {
        clearTimeout(stallTimer)
      }
    }
    const file = `video.${item.extension || 'mp4'}`
    await fsp.rename(partPath, join(item.dir, file))
    item.mediaFile = file
  }

  async fetchText (url, stream, signal) {
    const response = await fetch(url, { headers: this.headers(stream), signal, redirect: 'follow' })
    if (!response.ok) throw new DownloadError(httpErrorMessage(response.status))
    const text = await response.text()
    if (!isPlaylistText(text)) {
      if (looksLikeDash(response.url, response.headers.get('content-type') || '')) throw new DownloadError('DASH streams (.mpd) can\'t be downloaded yet. Try another server or source.', { final: true })
      throw new DownloadError('The source did not return a playable HLS playlist (expired or protected link).')
    }
    return { text, finalUrl: response.url || url }
  }

  async downloadHls (item, stream, text, playlistUrl, signal) {
    let video
    let audio = null
    let master = null
    let variant = null
    let audioRendition = null
    if (isMasterPlaylist(text)) {
      master = parseMasterPlaylist(text, playlistUrl)
      variant = pickVariant(master.variants, this.config.quality)
      if (!variant) throw new DownloadError('The HLS playlist lists no playable quality.', { final: true })
      audioRendition = pickAudioRendition(master, variant)
      const media = await this.fetchText(variant.uri, stream, signal)
      if (isMasterPlaylist(media.text)) throw new DownloadError('Nested HLS master playlists are not supported.', { final: true })
      video = planMediaPlaylist(media.text, media.finalUrl, 'v')
      if (audioRendition) {
        const audioText = await this.fetchText(audioRendition.uri, stream, signal)
        audio = planMediaPlaylist(audioText.text, audioText.finalUrl, 'a')
      }
    } else {
      video = planMediaPlaylist(text, playlistUrl, 'v')
    }
    const drm = video.drm || audio?.drm
    if (drm) throw new DownloadError(drm, { final: true })
    if (!video.segmentCount) throw new DownloadError('The HLS playlist has no segments.', { final: true })

    const resources = [...video.resources, ...(audio?.resources || [])]
    // A fresh link with another segment list (other encode / server): the saved segments don't match.
    const signature = `${video.segmentCount}:${audio?.segmentCount || 0}:${Math.round(video.duration)}`
    if (item.kind === 'hls' && item.hlsSignature && item.hlsSignature !== signature) await this.clearSegments(item)
    item.kind = 'hls'
    item.hlsSignature = signature
    item.quality = variant?.height || null
    item.segmentsTotal = resources.length

    if (audio) {
      await fsp.writeFile(join(item.dir, 'video.m3u8'), video.playlist)
      await fsp.writeFile(join(item.dir, 'audio.m3u8'), audio.playlist)
      await fsp.writeFile(join(item.dir, 'index.m3u8'), buildLocalMaster({ variant, audio: audioRendition, independentSegments: master?.independentSegments }))
    } else {
      await fsp.writeFile(join(item.dir, 'index.m3u8'), video.playlist)
    }
    this.ensureHlsJs()

    const remaining = []
    let doneBytes = 0
    let done = 0
    for (const resource of resources) {
      const path = join(item.dir, resource.file)
      if (await exists(path)) {
        done++
        try {
          doneBytes += (await fsp.stat(path)).size
        } catch {}
      } else remaining.push(resource)
    }
    const track = this.speedTracker(item)
    const update = () => {
      item.segmentsDone = done
      item.bytes = doneBytes
      item.progress = resources.length ? Math.min(done / resources.length, 0.999) : 0
      item.totalBytes = done ? Math.round(doneBytes / done * resources.length) : 0
    }
    update()
    this.changed(item, true)

    let next = 0
    const worker = async () => {
      while (next < remaining.length) {
        signal.throwIfAborted()
        const resource = remaining[next++]
        const size = await this.fetchResource(resource, join(item.dir, resource.file), stream, signal)
        done++
        doneBytes += size
        track(size)
        update()
      }
    }
    await Promise.all(Array.from({ length: Math.min(SEGMENT_WORKERS, remaining.length || 1) }, worker))
    update()
    item.mediaFile = 'index.m3u8'
  }

  async clearSegments (item) {
    try {
      for (const name of await fsp.readdir(item.dir)) {
        if (/^(v|a)-/.test(name)) await fsp.rm(join(item.dir, name), { force: true })
      }
    } catch {}
  }

  /** One segment / key / init segment, written to a .part file then renamed (a present file is complete). */
  async fetchResource (resource, path, stream, signal) {
    for (let attempt = 0; ; attempt++) {
      try {
        const range = resource.range ? { Range: `bytes=${resource.range.start}-${resource.range.end}` } : {}
        const response = await fetch(resource.url, { headers: this.headers(stream, range), signal: AbortSignal.any([signal, AbortSignal.timeout(STALL_TIMEOUT)]), redirect: 'follow' })
        if (!response.ok) {
          await response.body?.cancel().catch(() => {})
          const error = new DownloadError(httpErrorMessage(response.status))
          error.status = response.status
          throw error
        }
        let buffer = Buffer.from(await response.arrayBuffer())
        // A server ignoring Range sends the whole file.
        if (resource.range && response.status === 200 && buffer.length > resource.range.end) buffer = buffer.subarray(resource.range.start, resource.range.end + 1)
        if (resource.kind === 'key' && buffer.length !== 16) throw new DownloadError('The stream key could not be downloaded (protected source).', { final: true })
        await fsp.writeFile(`${path}.part`, buffer)
        await fsp.rename(`${path}.part`, path)
        return buffer.length
      } catch (error) {
        if (signal.aborted || error?.final || attempt >= 3 || [401, 403, 404, 410].includes(error?.status)) throw error
        await wait(1500 * (attempt + 1), signal)
      }
    }
  }

  async downloadCover (item, signal) {
    const url = item.media?.coverImage?.extraLarge || item.media?.coverImage?.large || item.media?.coverImage?.medium || item.media?.poster
    if (!url || item.cover) return
    try {
      const response = await fetch(url, { signal, headers: { 'User-Agent': UA } })
      if (!response.ok) return
      const extension = /png/i.test(response.headers.get('content-type') || '') ? 'png' : /webp/i.test(response.headers.get('content-type') || '') ? 'webp' : 'jpg'
      await fsp.writeFile(join(item.dir, `cover.${extension}`), Buffer.from(await response.arrayBuffer()))
      item.cover = `cover.${extension}`
      this.changed(item)
    } catch {}
  }

  async downloadSubtitles (item, stream, signal) {
    const list = Array.isArray(stream.subtitles) ? stream.subtitles : []
    const saved = []
    for (const [index, subtitle] of list.slice(0, 12).entries()) {
      if (!subtitle?.url) continue
      try {
        const response = await fetch(subtitle.url, { headers: this.headers(stream), signal, redirect: 'follow' })
        if (!response.ok) continue
        const text = await response.text()
        if (!text.trim() || /^\s*</.test(text)) continue
        const extension = subtitleExtension(response.url || subtitle.url, response.headers.get('content-type') || '', text)
        const file = `subtitle-${index}.${extension}`
        await fsp.writeFile(join(item.dir, file), text)
        saved.push({ file, lang: subtitle.lang || '', label: subtitle.label || subtitle.lang || `Subtitles ${index + 1}` })
      } catch {}
    }
    if (saved.length || !item.subtitles?.length) item.subtitles = saved
    if (list.length && !saved.length) item.subtitleError = 'The subtitles could not be downloaded.'
    this.changed(item)
  }

  /** hls.js copy for offline HLS playback (the player loads it from a CDN otherwise). */
  async ensureHlsJs () {
    const path = hlsJsPath()
    if (this.hlsJsTask || (await exists(path))) return
    this.hlsJsTask = (async () => {
      try {
        const response = await fetch(HLS_JS_URL)
        if (!response.ok) return
        const text = await response.text()
        if (text.length < 10_000) return
        await fsp.mkdir(dirname(path), { recursive: true })
        await fsp.writeFile(path, text)
      } catch {} finally {
        this.hlsJsTask = null
      }
    })()
  }

  /** Absolute path of a file of a download, or null when outside its folder. */
  filePath (id, relativePath) {
    const item = this.items.get(id)
    if (!item?.dir || !relativePath) return null
    const base = resolve(item.dir)
    const target = resolve(base, relativePath)
    return target.startsWith(base + sep) ? target : null
  }
}
