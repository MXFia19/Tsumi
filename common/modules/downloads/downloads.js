import { writable } from 'simple-store-svelte'
import { toast } from 'svelte-sonner'
import { IPC, ELECTRON } from '@/modules/bridge.js'
import { SUPPORTS } from '@/modules/support.js'
import { settings } from '@/modules/settings.js'
import { extensionManager, callExtensionFunction } from '@/modules/extension.js'
import { parseStreamResponse } from '@/modules/streaming.js'
import { sessionServer } from '@/modules/session.js'
import { anilistClient } from '@/modules/anilist.js'
import { status } from '@/modules/networking.js'
import { page } from '@/modules/navigation.js'
import Helper from '@/modules/helper.js'
import { files, nowPlaying } from '@/components/MediaHandler.svelte'
import { shareNowPlaying } from '@/routes/w2g/components/session.js'
import { bestResult, matchEpisode, normalizeSubtitles, preferredSubtitle, orderServerIndexes } from '@/modules/downloads/resolve.js'
import Debug from 'debug'
const debug = Debug('ui:downloads')

// Offline downloads, renderer side. The Electron main process (electron/src/main/downloads/) keeps the list,
// downloads the files and serves them locally; this module resolves a fresh stream with the extensions each time
// a download starts, mirrors the list for the UI, plays downloaded episodes and queues the list updates made
// offline (Helper.updateEntry) until the connection is back.

/** Downloads need the Electron main process (not the legacy Android build). */
export const downloadsSupported = !!window.IPC && !!window.electron && !SUPPORTS.isAndroid

/** Every download, oldest first. */
export const downloads = writable([])
/** Download folder in use and the default one. */
export const downloadInfo = writable({ folder: '', defaultFolder: '' })

class FinalError extends Error {
  final = true
}

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms))

function applyUpdate ({ updated = [], removed = [] } = {}) {
  const map = new Map(downloads.value.map(item => [item.id, item]))
  for (const item of updated) map.set(item.id, item)
  for (const id of removed) map.delete(id)
  downloads.set([...map.values()].sort((a, b) => a.createdAt - b.createdAt))
}

function downloadConfig (value = settings.value) {
  return {
    folder: value.downloadFolder || '',
    maxConcurrent: Number(value.downloadMaxConcurrent) || 2,
    quality: value.downloadQuality || 'highest'
  }
}

async function refreshInfo () {
  try {
    downloadInfo.set(await IPC.invoke('downloads:info'))
  } catch {}
}

if (downloadsSupported) {
  IPC.on('downloads:update', applyUpdate)
  IPC.on('downloads:resolve', (request) => resolveForMain(request))
  IPC.invoke('downloads:list').then(list => downloads.set(Array.isArray(list) ? list : [])).catch(() => {})
  let lastConfig = ''
  settings.subscribe(value => {
    const config = downloadConfig(value)
    const key = JSON.stringify(config)
    if (key === lastConfig) return
    const first = !lastConfig
    lastConfig = key
    IPC.emit(first ? 'downloads:ready' : 'downloads:config', config)
    refreshInfo()
  })
}

// ---- Lookups

/** Download of an episode (any status), undefined when there is none. */
export function findDownload (list, mediaId, episode) {
  const number = Number(typeof episode === 'object' ? episode?.number : episode)
  const season = typeof episode === 'object' ? episode?.season : null
  const local = typeof episode === 'object' ? episode?.localEpisode : null
  return list.find(item => {
    if (String(item.mediaId) !== String(mediaId)) return false
    if (season != null && local != null && item.episode?.season != null) return Number(item.episode.season) === Number(season) && Number(item.episode.localEpisode) === Number(local)
    return Number(item.episode?.number) === number
  })
}

export function isDownloadActive (item) {
  return item && ['queued', 'resolving', 'downloading'].includes(item.status)
}

// ---- Adding

function episodeOf (episode) {
  if (episode && typeof episode === 'object') {
    return { number: Number(episode.number) || 0, season: episode.season ?? null, localEpisode: episode.localEpisode ?? null }
  }
  return { number: Number(episode) || 0, season: null, localEpisode: null }
}

function unsupportedToast () {
  toast.error('Downloads are not available', { description: 'Downloading episodes needs the desktop app.' })
}

/**
 * Queues episodes of one title. `options.source` keeps the extension / search result to use, `options.seed` an
 * already resolved stream (player), used only when a fresh resolution fails.
 * @param {any} media
 * @param {Array<number | { number: number, season?: number, localEpisode?: number, title?: string, image?: string }>} episodes
 */
export async function downloadEpisodes (media, episodes, options = {}) {
  if (!downloadsSupported) return unsupportedToast()
  if (!media || !episodes?.length) return
  if (!extensionManager.getEnabled().length && !options.seed) {
    toast.error('No extension enabled', { description: 'Downloads use your extensions to find the episode. Add or enable one in Settings > Extensions.' })
    return
  }
  const requests = episodes.map(episode => ({
    media,
    episode: episodeOf(episode),
    episodeTitle: (typeof episode === 'object' && episode?.title) || options.episodeTitle || null,
    episodeImage: (typeof episode === 'object' && episode?.image) || options.episodeImage || null,
    source: options.source || null,
    seed: options.seed || null
  }))
  try {
    const added = await IPC.invoke('downloads:add', requests)
    const fresh = added.filter(entry => !entry.existing).length
    const title = anilistClient.title(media)
    if (fresh) {
      toast.success(fresh === 1 ? 'Download queued' : `${fresh} downloads queued`, {
        description: requests.length === 1 ? `${title} - Episode ${requests[0].episode.number}` : title,
        action: { label: 'Downloads', onClick: () => page.navigateTo(page.DOWNLOADS) }
      })
    } else {
      toast('Already in your downloads', { description: title, action: { label: 'Downloads', onClick: () => page.navigateTo(page.DOWNLOADS) } })
    }
  } catch (error) {
    debug('Failed to queue downloads', error)
    toast.error('Failed to queue the download', { description: error?.message || String(error) })
  }
}

export function downloadEpisode (media, episode, options = {}) {
  return downloadEpisodes(media, [episode], options)
}

/** "Download this episode" of the player: the file playing (its extension / result and stream as a fallback). */
export function downloadFromPlayer (file, server) {
  const media = file?.media?.media
  if (!media) {
    toast.error('Can\'t download this file', { description: 'Only episodes played from an extension can be downloaded.' })
    return
  }
  const url = server?.streamUrl || file.url
  const headers = server?.headers || file.streamHeaders || {}
  return downloadEpisode(media, file.episodeRef || { number: file.media.episode }, {
    episodeTitle: file.media.episodeTitle || null,
    source: file.extensionKey ? { extensionKey: file.extensionKey, href: file.sourceHref || null, title: file.sourceTitle || null, serverTitle: server?.title || null } : null,
    seed: url ? { url, headers, subtitles: normalizeSubtitles(file.subtitle), serverTitle: server?.title || null, at: Date.now() } : null
  })
}

// ---- Actions

export function downloadAction (action, id) {
  return IPC.invoke('downloads:action', { action, id }).catch(error => debug('Download action failed', action, error))
}

export function openDownloadFolder (id) {
  IPC.emit('downloads:open-folder', id || null)
}

export function chooseDownloadFolder () {
  return IPC.invoke('downloads:choose-folder')
}

// ---- Fresh stream for the main process

async function waitForExtensions (key, timeout = 20_000) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    const loaded = !key || extensionManager.extensions.has(key)
    if (loaded && !extensionManager.loading.size) return
    if (!key && !extensionManager.loading.size) return
    await sleep(250)
  }
}

function pickExtension (key) {
  const enabled = extensionManager.getEnabled()
  return (key && enabled.find(ext => ext.key === key)) ||
    enabled.find(ext => ext.key === settings.value.defaultExtension) ||
    enabled.find(ext => ext.key === settings.value.starredExtension) ||
    enabled[0] || null
}

function parseList (raw) {
  const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw
  return Array.isArray(parsed) ? parsed : []
}

/**
 * extractEpisodes → episode → extractStreamUrl → server, from the remembered search result when there is one,
 * else from the best search result of the extension (DefaultLoadingModal steps).
 */
export async function resolveFreshStream (media, episode, source) {
  await waitForExtensions(source?.extensionKey)
  const ext = pickExtension(source?.extensionKey)
  if (!ext) throw new FinalError('No extension enabled to find this episode. Add or enable one in Settings > Extensions.')
  const extensionName = ext.manifest?.sourceName || ext.key
  let href = ext.key === source?.extensionKey ? source?.href : null
  let resultTitle = ext.key === source?.extensionKey ? source?.title : null
  if (!href) {
    const title = anilistClient.title(media)
    const results = parseList(await callExtensionFunction(ext, 'searchResults', title, ...(ext.type === 'stremio' ? [media] : [])))
    const best = bestResult(results, title)
    if (!best?.href) throw new FinalError(`${title} was not found on ${extensionName}.`)
    href = best.href
    resultTitle = best.title || null
  }
  const episodes = parseList(await callExtensionFunction(ext, 'extractEpisodes', href))
  if (!episodes.length) throw new FinalError(`No episodes found on ${extensionName}.`)
  const target = matchEpisode(episodes, episode)
  if (!target?.href) throw new FinalError(`Episode ${episode?.number} was not found on ${extensionName}.`)
  const raw = await callExtensionFunction(ext, 'extractStreamUrl', target.href)
  let streamData
  try {
    streamData = parseStreamResponse(raw)
  } catch {
    const url = typeof raw === 'string' ? raw : raw?.url || raw?.streamUrl
    if (url) streamData = { url, headers: {}, subtitle: null, servers: [] }
  }
  if (!streamData?.url) throw new Error(`${extensionName} returned no stream for this episode.`)
  const servers = (streamData.servers || []).filter(server => server?.streamUrl)
  const [index = 0, ...others] = orderServerIndexes(servers, source?.serverTitle, sessionServer.value)
  const server = servers[index]
  return {
    url: server?.streamUrl || streamData.url,
    headers: server?.headers || streamData.headers || {},
    // The other servers of the episode, tried in this order when the first one is dead.
    alternatives: others.map(other => ({
      url: servers[other].streamUrl,
      headers: servers[other].headers || {},
      serverTitle: servers[other].title || `Server ${other + 1}`
    })),
    subtitles: normalizeSubtitles(streamData.subtitle),
    source: {
      extensionKey: ext.key,
      extensionName,
      href,
      title: resultTitle,
      serverTitle: server ? (server.title || `Server ${index + 1}`) : null
    }
  }
}

async function resolveForMain ({ id, media, episode, source } = {}) {
  try {
    const stream = await resolveFreshStream(media, episode, source)
    IPC.emit('downloads:resolved', { id, stream })
  } catch (error) {
    debug('Download resolution failed', id, error)
    IPC.emit('downloads:resolved', { id, error: error?.message || String(error), final: !!error?.final })
  }
}

// ---- Offline playback

/** Plays a finished download from the local server (no network needed). */
export async function playDownload (item) {
  if (item?.status !== 'completed' || !item.mediaFile) return false
  const port = await ELECTRON.getProxyPort?.()
  if (!port) {
    toast.error('Can\'t play the download', { description: 'The local media server is not running.' })
    return false
  }
  const base = `http://localhost:${port}/downloads/${encodeURIComponent(item.id)}/`
  const media = item.media
  const episode = item.episode?.number
  const subtitle = preferredSubtitle(item.subtitles, settings.value.subtitleLanguage)
  nowPlaying.set({ media, episode })
  shareNowPlaying(media, item.episode?.season != null ? item.episode : episode)
  files.set([{
    name: `${anilistClient.title(media)} - Episode ${episode}.mp4`,
    url: base + item.mediaFile,
    streamHeaders: {},
    streamServers: [],
    subtitle: subtitle ? base + subtitle.file : null,
    length: item.sizeOnDisk || 0,
    media: {
      media,
      episode,
      episodeTitle: item.episodeTitle || undefined,
      parseObject: { anime_title: anilistClient.title(media), episode_number: episode }
    },
    activeServerIndex: 0,
    sourceName: item.source?.extensionName ? `${item.source.extensionName} (downloaded)` : 'Downloaded',
    offline: true,
    downloadId: item.id,
    episodeRef: item.episode,
    extensionKey: item.source?.extensionKey,
    sourceHref: item.source?.href
  }])
  page.navigateTo(page.PLAYER)
  return true
}

/** playAnime hook: a downloaded episode plays from disk instead of the extensions. */
export function playDownloadedIfAvailable (media, episode) {
  if (!downloadsSupported || !media) return false
  const item = findDownload(downloads.value, media.id, episode)
  if (item?.status !== 'completed') return false
  playDownload(item)
  return true
}

// ---- List progress made offline

const QUEUE_KEY = 'tsumi-offline-progress'

function readQueue () {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY)) || []
  } catch {
    return []
  }
}

function writeQueue (queue) {
  localStorage.setItem(QUEUE_KEY, JSON.stringify(queue))
}

/** Helper.updateEntry, or kept until the connection is back when offline. */
export function updateEntryOrQueue (filemedia) {
  if (status.value === 'offline' || !navigator.onLine) {
    if (!filemedia?.media?.id || !Helper.isAuthorized()) return
    const queue = readQueue().filter(entry => !(entry.mediaId === filemedia.media.id && entry.episode <= filemedia.episode))
    queue.push({ mediaId: filemedia.media.id, episode: filemedia.episode, media: { id: filemedia.media.id }, at: Date.now() })
    writeQueue(queue)
    debug('Offline: list update queued', filemedia.media.id, filemedia.episode)
    return
  }
  return Helper.updateEntry(filemedia)
}

let flushing = false
async function flushQueue () {
  if (flushing || status.value === 'offline') return
  const queue = readQueue()
  if (!queue.length) return
  flushing = true
  try {
    for (const entry of queue.sort((a, b) => a.at - b.at)) {
      await Helper.updateEntry({ media: entry.media, episode: entry.episode })
      writeQueue(readQueue().filter(other => !(other.mediaId === entry.mediaId && other.episode === entry.episode && other.at === entry.at)))
    }
  } catch (error) {
    debug('Failed to send the offline list updates', error)
  } finally {
    flushing = false
  }
}

status.subscribe(value => {
  if (value !== 'offline') setTimeout(flushQueue, 5_000)
})
