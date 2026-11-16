import { ipcMain } from 'electron'
import { spawn } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import { basename, isAbsolute, join } from 'node:path'
import { getProxyUrl, startStreamProxy } from './streamProxy.js'
import { sanitizeHeaders } from './cast/proxy.js'
import { isWebUrl } from './security.js'
import { playerKind, playerArgs } from './externalPlayerArgs.js'

const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
const SUBTITLE_TIMEOUT = 20_000
const SUBTITLE_MAX_BYTES = 10 * 1024 * 1024

/**
 * Path of the program to start: the executable inside a macOS .app bundle (Contents/MacOS/<name>), the path otherwise.
 * @param {string} path
 */
async function resolveExecutable (path) {
  if (process.platform === 'darwin' && /\.app\/?$/i.test(path)) {
    const name = basename(path.replace(/\/+$/, '')).replace(/\.app$/i, '')
    for (const candidate of [name, name.toLowerCase()]) {
      const inner = join(path, 'Contents', 'MacOS', candidate)
      if (await fsp.stat(inner).then(stat => stat.isFile(), () => false)) return inner
    }
  }
  return path
}

/**
 * Throws a readable error when `path` is not a program that can be started without a shell.
 * @param {string} path
 */
async function checkExecutable (path) {
  let stat
  try {
    stat = await fsp.stat(path)
  } catch {
    throw new Error('The player program was not found. Pick it again in Settings.')
  }
  if (!stat.isFile()) throw new Error('The selected player is not a program file. Pick it again in Settings.')
  if (process.platform === 'win32') {
    // .bat / .cmd scripts would need a shell (cmd.exe) to start, which is never used here.
    if (!/\.(exe|com)$/i.test(path)) throw new Error('The selected player is not a program (.exe). Pick it again in Settings.')
  } else {
    try {
      await fsp.access(path, fs.constants.X_OK)
    } catch {
      throw new Error('The selected player is not executable. Pick it again in Settings.')
    }
  }
}

/**
 * Subtitle track for VLC, whose --sub-file wants a local file: downloaded (with the headers of the source) to a
 * temporary file, deleted when the player exits. Null when it can't be downloaded (the video still plays).
 * @param {string} url
 * @param {Record<string, string>} headers
 */
async function downloadSubtitle (url, headers) {
  try {
    const fetchHeaders = Object.keys(headers).some(name => name.toLowerCase() === 'user-agent') ? headers : { 'User-Agent': DEFAULT_USER_AGENT, ...headers }
    const response = await fetch(url, { headers: fetchHeaders, redirect: 'follow', signal: AbortSignal.timeout(SUBTITLE_TIMEOUT) })
    if (!response.ok) return null
    const buffer = Buffer.from(await response.arrayBuffer())
    if (!buffer.length || buffer.length > SUBTITLE_MAX_BYTES) return null
    const extension = (new URL(response.url || url).pathname.match(/\.(srt|vtt|ass|ssa|sub)$/i)?.[1] || 'srt').toLowerCase()
    const dir = join(os.tmpdir(), 'tsumi-subtitles')
    await fsp.mkdir(dir, { recursive: true })
    const file = join(dir, `${crypto.randomBytes(8).toString('hex')}.${extension}`)
    await fsp.writeFile(file, buffer)
    return file
  } catch {
    return null
  }
}

/**
 * External player of the PC app (renderer side: the player page). 'external-player:launch' starts the program the user
 * picked (Settings) with the stream: streams that need headers go through the local stream proxy, which adds them, so
 * any player can open the URL. mpv and VLC also get the title, the start position and the subtitles. Sends
 * 'external-player:closed' ({ code }) when the last started player exits.
 */
export default class ExternalPlayer {
  /** @type {import('node:child_process').ChildProcess | null} */
  child = null
  destroyed = false

  /** @param {import('electron').BrowserWindow} window */
  constructor (window) {
    this.window = window
    ipcMain.handle('external-player:launch', async (event, options) => {
      try {
        await this.launch(options || {})
        return { ok: true }
      } catch (error) {
        return { ok: false, error: error?.message || String(error) }
      }
    })
  }

  /**
   * @param {{ path?: string, url?: string, headers?: Record<string, string>, title?: string, subtitleUrl?: string, startTime?: number }} options
   */
  async launch ({ path, url, headers, title, subtitleUrl, startTime }) {
    if (typeof path !== 'string' || !path || !isAbsolute(path)) throw new Error('No external player is set. Pick one in Settings.')
    if (!isWebUrl(url)) throw new Error('This video cannot be opened in an external player.')
    const program = await resolveExecutable(path)
    await checkExecutable(program)

    const streamHeaders = sanitizeHeaders(headers)
    const needsProxy = Object.keys(streamHeaders).length > 0
    if (needsProxy) await startStreamProxy()
    // The external program can't send the headers the source requires (Referer, Origin...): the proxy does.
    const source = needsProxy ? getProxyUrl(url, streamHeaders) : url
    if (needsProxy && source === url) throw new Error('The local stream proxy is not running.')

    const kind = playerKind(program)
    let subtitle = null
    let subtitleFile = null
    if (isWebUrl(subtitleUrl) && kind !== 'other') {
      if (kind === 'vlc') subtitle = subtitleFile = await downloadSubtitle(subtitleUrl, streamHeaders)
      else subtitle = needsProxy ? getProxyUrl(subtitleUrl, streamHeaders) : subtitleUrl
    }

    const child = spawn(program, playerArgs(kind, { url: source, title, subtitle, startTime }), { shell: false, stdio: 'ignore', windowsHide: false })
    try {
      await new Promise((resolve, reject) => {
        child.once('spawn', resolve)
        child.once('error', reject)
      })
    } catch (error) {
      if (subtitleFile) fsp.rm(subtitleFile, { force: true }).catch(() => {})
      throw new Error(`Could not start the player: ${error?.code || error?.message || error}`)
    }
    child.on('error', error => console.warn('External player error:', error?.message || error))
    this.child = child
    child.once('exit', (code) => {
      if (subtitleFile) fsp.rm(subtitleFile, { force: true }).catch(() => {})
      // A player started later replaced this one: its own exit is the one the renderer waits for.
      if (this.child !== child) return
      this.child = null
      if (!this.destroyed && !this.window.isDestroyed()) this.window.webContents.send('external-player:closed', { code })
    })
  }

  destroy () {
    // The player keeps running after the app quits (it may play a file that needs no proxy).
    this.destroyed = true
  }
}
