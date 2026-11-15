import { app, ipcMain, safeStorage, shell } from 'electron'
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'

/* global __TRAKT_CLIENT_ID__, __TRAKT_CLIENT_SECRET__ */
// Injected at build time from the TRAKT_CLIENT_ID / TRAKT_CLIENT_SECRET environment variables
// (electron/webpack.config.cjs, DefinePlugin). Empty: Trakt is not available in this build.
const CLIENT_ID = typeof __TRAKT_CLIENT_ID__ === 'string' ? __TRAKT_CLIENT_ID__ : ''
const CLIENT_SECRET = typeof __TRAKT_CLIENT_SECRET__ === 'string' ? __TRAKT_CLIENT_SECRET__ : ''

const API = 'https://api.trakt.tv'
const REDIRECT_URI = 'urn:ietf:wg:oauth:2.0:oob'
/** Trakt allows one POST / PUT / DELETE per second per user. */
const WRITE_SPACING_MS = 1_100
/** The renderer gets this long to send its last positions when the app quits. */
const QUIT_FLUSH_MS = 3_000

/** @param {number} ms */
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

/**
 * @typedef {{ access: string, refresh: string, expiresAt: number, user: string }} TraktToken
 * @typedef {'unavailable' | 'disconnected' | 'linking' | 'connected'} TraktState
 */

const LINK_ERRORS = {
  404: 'This code is not valid, try again.',
  409: 'This code was already used, try again.',
  410: 'The code expired, try again.',
  418: 'Access was denied on Trakt.'
}

/**
 * Trakt account of the app: device code flow (code shown in Settings, trakt.tv/activate opened in the browser),
 * tokens encrypted with safeStorage in userData, refresh, and every API request of the renderer
 * (common/modules/sync/trakt.js) so the tokens never reach the page.
 */
export default class Trakt {
  available = !!(CLIENT_ID && CLIENT_SECRET)
  /** @type {TraktToken | null} */
  token = null
  tokenPath = join(app.getPath('userData'), 'trakt-token')
  /** @type {TraktState} */
  state = 'unavailable'
  error = ''
  /** @type {{ code: string, url: string, expiresAt: number } | null} */
  linking = null
  /** Incremented by cancel / unlink, so a running link doesn't apply its result. */
  generation = 0
  /** @type {Promise<boolean> | null} */
  refreshing = null
  writeChain = Promise.resolve()
  lastWrite = 0

  /** @param {import('electron').BrowserWindow} window */
  constructor (window) {
    this.window = window
    if (this.available) {
      this.loadToken()
      this.state = this.token ? 'connected' : 'disconnected'
    }
    ipcMain.handle('trakt:status', () => this.status())
    ipcMain.on('trakt:link', () => this.link())
    ipcMain.on('trakt:cancel', () => this.cancel())
    ipcMain.on('trakt:unlink', () => this.unlink())
    ipcMain.on('trakt:open', () => { if (this.linking?.url) shell.openExternal(this.linking.url) })
    ipcMain.handle('trakt:request', (event, { method, path, body } = {}) => this.request(method, path, body))
  }

  status () {
    return {
      available: this.available,
      state: this.state,
      user: this.token?.user || '',
      code: this.linking?.code || '',
      url: this.linking?.url || '',
      expiresAt: this.linking?.expiresAt || 0,
      error: this.error
    }
  }

  /** @param {TraktState} state */
  setState (state) {
    this.state = state
    if (!this.window.isDestroyed()) this.window.webContents.send('trakt:status', this.status())
  }

  /** @param {boolean} auth */
  headers (auth) {
    /** @type {Record<string, string>} */
    const headers = {
      'Content-Type': 'application/json',
      'User-Agent': `Tsumi/${app.getVersion()}`,
      'trakt-api-version': '2',
      'trakt-api-key': CLIENT_ID
    }
    if (auth && this.token) headers.Authorization = `Bearer ${this.token.access}`
    return headers
  }

  /**
   * @param {string} path
   * @param {any} body
   */
  post (path, body) {
    return fetch(API + path, { method: 'POST', headers: this.headers(false), body: JSON.stringify(body) })
  }

  async link () {
    if (!this.available || this.state === 'linking') return
    const generation = ++this.generation
    this.error = ''
    try {
      const res = await this.post('/oauth/device/code', { client_id: CLIENT_ID })
      if (!res.ok) throw new Error(`Trakt returned ${res.status}.`)
      const device = await res.json()
      if (generation !== this.generation) return
      this.linking = { code: device.user_code, url: device.verification_url, expiresAt: Date.now() + device.expires_in * 1000 }
      this.setState('linking')
      shell.openExternal(device.verification_url)
      await this.poll(device.device_code, (device.interval || 5) * 1000, generation)
    } catch (error) {
      if (generation !== this.generation) return
      this.error = `Could not reach Trakt: ${error instanceof Error ? error.message : error}`
      this.linking = null
      this.setState(this.token ? 'connected' : 'disconnected')
    }
  }

  /**
   * Polls /oauth/device/token until the user approved the code on trakt.tv (or it expired).
   * @param {string} deviceCode
   * @param {number} interval
   * @param {number} generation
   */
  async poll (deviceCode, interval, generation) {
    while (generation === this.generation && this.linking && Date.now() < this.linking.expiresAt) {
      await sleep(interval)
      if (generation !== this.generation) return
      let res
      try {
        res = await this.post('/oauth/device/token', { code: deviceCode, client_id: CLIENT_ID, client_secret: CLIENT_SECRET })
      } catch {
        continue
      }
      if (generation !== this.generation) return
      if (res.status === 200) {
        this.saveToken(await res.json())
        await this.loadUser()
        if (generation !== this.generation) return
        this.linking = null
        this.setState('connected')
        return
      }
      if (res.status === 400) continue // the user has not approved yet
      if (res.status === 429) {
        interval += 1_000 // slow down
        continue
      }
      this.error = LINK_ERRORS[res.status] || `Trakt returned ${res.status}, try again.`
      break
    }
    if (generation !== this.generation) return
    if (!this.error) this.error = LINK_ERRORS[410]
    this.linking = null
    this.setState(this.token ? 'connected' : 'disconnected')
  }

  cancel () {
    if (this.state !== 'linking') return
    this.generation++
    this.linking = null
    this.error = ''
    this.setState(this.token ? 'connected' : 'disconnected')
  }

  unlink () {
    this.generation++
    const token = this.token
    this.linking = null
    this.error = ''
    this.deleteToken()
    if (this.available) this.setState('disconnected')
    if (token) this.post('/oauth/revoke', { token: token.access, client_id: CLIENT_ID, client_secret: CLIENT_SECRET }).catch(() => {})
  }

  /** Name shown in Settings ("Connected as ..."). */
  async loadUser () {
    try {
      const res = await fetch(API + '/users/settings', { headers: this.headers(true) })
      if (!res.ok || !this.token) return
      const settings = await res.json()
      this.token.user = settings?.user?.username || settings?.user?.name || ''
      this.persist()
    } catch {}
  }

  /**
   * Refreshes the access token; on a refused refresh token the account is disconnected.
   * @returns {Promise<boolean>}
   */
  refresh () {
    if (this.refreshing) return this.refreshing
    const token = this.token
    if (!token) return Promise.resolve(false)
    this.refreshing = (async () => {
      try {
        const res = await this.post('/oauth/token', {
          refresh_token: token.refresh,
          client_id: CLIENT_ID,
          client_secret: CLIENT_SECRET,
          redirect_uri: REDIRECT_URI,
          grant_type: 'refresh_token'
        })
        if (res.ok) {
          const user = token.user
          this.saveToken(await res.json(), user)
          return true
        }
        if (res.status === 400 || res.status === 401) {
          this.deleteToken()
          this.error = 'The Trakt session expired, connect again.'
          this.setState('disconnected')
        }
        return false
      } catch {
        return false
      } finally {
        this.refreshing = null
      }
    })()
    return this.refreshing
  }

  /** Waits for the spacing Trakt asks between two writes of a user. */
  spaceWrite () {
    const turn = this.writeChain.then(async () => {
      const wait = this.lastWrite + WRITE_SPACING_MS - Date.now()
      if (wait > 0) await sleep(wait)
      this.lastWrite = Date.now()
    })
    this.writeChain = turn.catch(() => {})
    return turn
  }

  /**
   * Authenticated request for the renderer. Resolves to { status, data } (status 0: not possible / network error).
   * @param {string} method
   * @param {string} path
   * @param {any} [body]
   * @param {boolean} [retried]
   * @returns {Promise<{ status: number, data: any }>}
   */
  async request (method = 'GET', path = '', body, retried = false) {
    if (!this.available || !this.token || typeof path !== 'string' || !path.startsWith('/') || path.startsWith('/oauth')) return { status: 0, data: null }
    if (Date.now() > this.token.expiresAt - 60_000) await this.refresh()
    if (!this.token) return { status: 401, data: null }
    if (method !== 'GET') await this.spaceWrite()
    let res
    try {
      res = await fetch(API + path, { method, headers: this.headers(true), body: body === undefined ? undefined : JSON.stringify(body) })
    } catch (error) {
      return { status: 0, data: null }
    }
    if (res.status === 401 && !retried && await this.refresh()) return this.request(method, path, body, true)
    if (res.status === 429 && !retried) {
      await sleep((Number(res.headers.get('retry-after')) || 1) * 1000 + 100)
      return this.request(method, path, body, true)
    }
    let data = null
    try {
      if (res.status !== 204) data = await res.json()
    } catch {}
    return { status: res.status, data }
  }

  /**
   * @param {{ access_token: string, refresh_token: string, expires_in: number, created_at?: number }} oauth
   * @param {string} [user]
   */
  saveToken (oauth, user = '') {
    const created = (oauth.created_at || Math.floor(Date.now() / 1000)) * 1000
    this.token = { access: oauth.access_token, refresh: oauth.refresh_token, expiresAt: created + (oauth.expires_in || 86_400) * 1000, user }
    this.persist()
  }

  persist () {
    // Without OS encryption (some Linux setups), the account only lasts for this session.
    if (!this.token || !safeStorage.isEncryptionAvailable()) return
    try {
      writeFileSync(this.tokenPath, safeStorage.encryptString(JSON.stringify(this.token)))
    } catch (error) {
      console.warn('Could not save the Trakt token:', error instanceof Error ? error.message : error)
    }
  }

  loadToken () {
    try {
      if (!existsSync(this.tokenPath)) return
      const token = JSON.parse(safeStorage.decryptString(readFileSync(this.tokenPath)))
      if (token?.access && token?.refresh) this.token = token
    } catch (error) {
      console.warn('Could not read the saved Trakt token:', error instanceof Error ? error.message : error)
    }
  }

  deleteToken () {
    this.token = null
    try {
      rmSync(this.tokenPath, { force: true })
    } catch (error) {
      console.warn('Could not delete the Trakt token:', error instanceof Error ? error.message : error)
    }
  }

  /**
   * Before the app quits: the renderer writes the last playback position (AniList note, Trakt stop), at most
   * QUIT_FLUSH_MS (common/modules/sync/session.js answers 'app-before-quit:done').
   */
  beforeQuit () {
    if (this.window.isDestroyed()) return Promise.resolve()
    return new Promise(resolve => {
      const done = () => {
        clearTimeout(timer)
        ipcMain.removeListener('app-before-quit:done', done)
        resolve(undefined)
      }
      const timer = setTimeout(done, QUIT_FLUSH_MS)
      ipcMain.once('app-before-quit:done', done)
      this.window.webContents.send('app-before-quit')
    })
  }
}
