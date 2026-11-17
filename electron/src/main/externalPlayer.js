import { ipcMain } from 'electron'
import { spawn } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import { basename, isAbsolute, join } from 'node:path'
import { getProxyUrl, startStreamProxy } from './streamProxy.js'
import { sanitizeHeaders } from './cast/proxy.js'
import { isWebUrl } from './security.js'
import { store } from './util.js'
import { playerKind, playerArgs, readMpvMessages, closedPosition, MPV_OBSERVE } from './externalPlayerArgs.js'

const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
const SUBTITLE_TIMEOUT = 20_000
const SUBTITLE_MAX_BYTES = 10 * 1024 * 1024

/**
 * persist.json key of the program picked in the main process dialog (Settings > Player, dialog.js 'player'). It is the
 * only program 'external-player:launch' starts: a path sent by the page is never used, so a compromised page cannot
 * start any other program (mshta.exe with a URL...).
 */
const PLAYER_PATH_KEY = 'externalPlayerPath'

/** Program picked in Settings (absolute path), '' when none. */
export function getPlayerPath () {
  const path = store.get(PLAYER_PATH_KEY)
  return typeof path === 'string' && isAbsolute(path) ? path : ''
}

/** @param {string} path program the user picked in the dialog */
export function setPlayerPath (path) {
  store.set(PLAYER_PATH_KEY, typeof path === 'string' && isAbsolute(path) ? path : '')
}

/** mpv JSON IPC server of one launch: a named pipe on Windows, a socket file elsewhere. */
function mpvIpcPath () {
  const id = crypto.randomBytes(8).toString('hex')
  return process.platform === 'win32' ? `\\\\.\\pipe\\tsumi-mpv-${id}` : join(os.tmpdir(), `tsumi-mpv-${id}.sock`)
}

/**
 * Follows the position of an mpv started with --input-ipc-server=`ipcPath` (mpv creates the server once it started:
 * the connection is tried again for about 15 s). `report` gets connected / position / duration / ended.
 * `finish()` (when the player exited) waits a little for the last messages, then closes the connection.
 * @param {string} ipcPath
 * @param {{ connected?: boolean, position?: number | null, duration?: number | null, ended?: boolean }} report
 */
function watchMpv (ipcPath, report) {
  /** @type {import('node:net').Socket | null} */
  let socket = null
  let timer = null
  let attempts = 0
  let rest = ''
  let done = false
  const connect = () => {
    timer = null
    if (done) return
    const connection = net.connect(ipcPath)
    socket = connection
    connection.setEncoding('utf8')
    connection.once('connect', () => {
      report.connected = true
      connection.write(MPV_OBSERVE)
    })
    connection.on('data', (chunk) => {
      rest = readMpvMessages(report, rest + chunk)
    })
    connection.on('error', () => {
      connection.destroy()
      if (!report.connected && !done && ++attempts < 60) timer = setTimeout(connect, 250)
    })
  }
  timer = setTimeout(connect, 150)
  return {
    /** @returns {Promise<void>} */
    finish () {
      done = true
      clearTimeout(timer)
      return new Promise(resolve => {
        const close = () => {
          socket?.destroy()
          resolve()
        }
        if (!socket || socket.destroyed || !report.connected) return close()
        // The end of the file and the last position are written just before mpv exits.
        const timeout = setTimeout(close, 500)
        socket.once('close', () => {
          clearTimeout(timeout)
          close()
        })
      })
    }
  }
}

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
 * 'external-player:closed' ({ id, code, position?, duration?, estimated? }, see closedPosition) when the last started
 * player exits. 'external-player:path' gives the program picked in Settings, the only one ever started.
 */
export default class ExternalPlayer {
  /** @type {import('node:child_process').ChildProcess | null} */
  child = null
  destroyed = false
  launches = 0

  /** @param {import('electron').BrowserWindow} window */
  constructor (window) {
    this.window = window
    ipcMain.handle('external-player:launch', async (event, options) => {
      try {
        const id = await this.launch(options || {})
        return { ok: true, id }
      } catch (error) {
        return { ok: false, error: error?.message || String(error) }
      }
    })
    ipcMain.handle('external-player:path', () => getPlayerPath())
    // Settings > Player "Reset Location": the main process forgets the program too.
    ipcMain.on('external-player:forget', () => setPlayerPath(''))
  }

  /**
   * Starts the program picked in Settings (getPlayerPath; the page's `path`, sent by older versions, is ignored).
   * @param {{ url?: string, headers?: Record<string, string>, title?: string, subtitleUrl?: string, startTime?: number }} options
   * @returns {Promise<number>} id of the launch, sent back with 'external-player:closed'
   */
  async launch ({ url, headers, title, subtitleUrl, startTime }) {
    const path = getPlayerPath()
    if (!path) throw new Error('No external player is set. Pick one in Settings.')
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

    // mpv tells where it is over JSON IPC; the other players only how long they stayed open (closedPosition).
    const ipcPath = kind === 'mpv' ? mpvIpcPath() : null
    const child = spawn(program, playerArgs(kind, { url: source, title, subtitle, startTime, ipcPath }), { shell: false, stdio: 'ignore', windowsHide: false })
    try {
      await new Promise((resolve, reject) => {
        child.once('spawn', resolve)
        child.once('error', reject)
      })
    } catch (error) {
      if (subtitleFile) fsp.rm(subtitleFile, { force: true }).catch(() => {})
      throw new Error(`Could not start the player: ${error?.code || error?.message || error}`)
    }
    const id = ++this.launches
    const startedAt = Date.now()
    const report = { connected: false, position: null, duration: null, ended: false }
    const mpv = ipcPath ? watchMpv(ipcPath, report) : null
    child.on('error', error => console.warn('External player error:', error?.message || error))
    this.child = child
    child.once('exit', async (code) => {
      if (subtitleFile) fsp.rm(subtitleFile, { force: true }).catch(() => {})
      const elapsed = (Date.now() - startedAt) / 1000
      await mpv?.finish()
      // A player started later replaced this one: its own exit is the one the renderer waits for.
      if (this.child !== child) return
      this.child = null
      if (this.destroyed || this.window.isDestroyed()) return
      this.window.webContents.send('external-player:closed', { id, code, ...closedPosition(report, { startTime, elapsed }) })
    })
    return id
  }

  destroy () {
    // The player keeps running after the app quits (it may play a file that needs no proxy).
    this.destroyed = true
  }
}
