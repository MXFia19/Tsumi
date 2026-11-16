import { app, ipcMain, safeStorage, shell } from 'electron'
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { TRAKT_AUTH, TRAKT_REDIRECT_URI, createPkce, authorizeUrl, parseCallback, callbackErrorMessage, oauthErrorCode } from './traktAuth.js'

/* global __TRAKT_CLIENT_ID__ */
// Injected at build time from the TRAKT_CLIENT_ID environment variable (electron/webpack.config.cjs, DefinePlugin).
// Empty: Trakt is not available in this build. There is no client secret: the sign-in uses PKCE.
const CLIENT_ID = typeof __TRAKT_CLIENT_ID__ === 'string' ? __TRAKT_CLIENT_ID__ : ''

const API = 'https://api.trakt.tv'
/** Trakt allows one POST / PUT / DELETE per second per user. */
const WRITE_SPACING_MS = 1_100
/** The renderer gets this long to send its last positions when the app quits. */
const QUIT_FLUSH_MS = 3_000
/** A sign-in started in the browser is abandoned after this long. */
const LINK_TIMEOUT_MS = 10 * 60_000

/** @param {number} ms */
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

/**
 * @typedef {{ access: string, refresh: string, expiresAt: number, user: string }} TraktToken
 * @typedef {'unavailable' | 'disconnected' | 'linking' | 'connected'} TraktState
 */

/**
 * Trakt account of the app: sign-in with the authorization code flow and PKCE (the authorize page opens in the
 * browser, Trakt redirects to https://mxfia19.github.io/Tsumi/trakt/, which opens tsumi://trakt/callback, routed here
 * by protocol.js), tokens encrypted with safeStorage in userData, refresh, and every API request of the renderer
 * (common/modules/sync/trakt.js) so the tokens never reach the page.
 */
export default class Trakt {
  available = !!CLIENT_ID
  /** @type {TraktToken | null} */
  token = null
  tokenPath = join(app.getPath('userData'), 'trakt-token')
  /** @type {TraktState} */
  state = 'unavailable'
  error = ''
  /**
   * Sign-in waiting for the browser. The verifier and state belong to this attempt only: kept in memory, never sent to
   * the page.
   * @type {{ url: string, expiresAt: number, verifier: string, state: string, timer: ReturnType<typeof setTimeout> } | null}
   */
  linking = null
  /** Incremented by link / cancel / unlink, so a running exchange doesn't apply its result. */
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
    ipcMain.on('trakt:open', () => { if (this.linking?.url) shell.openExternal(this.linking.url).catch(() => {}) })
    ipcMain.handle('trakt:request', (event, { method, path, body } = {}) => this.request(method, path, body))
  }

  status () {
    return {
      available: this.available,
      state: this.state,
      user: this.token?.user || '',
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
   * OAuth request (token exchange, refresh, revoke): auth.trakt.tv, with the Client ID only.
   * @param {string} path
   * @param {any} body
   */
  postAuth (path, body) {
    return fetch(TRAKT_AUTH + path, { method: 'POST', headers: this.headers(false), body: JSON.stringify(body) })
  }

  /** Starts a sign-in: opens the authorize page of Trakt in the browser and waits for tsumi://trakt/callback. */
  link () {
    if (!this.available || this.state === 'linking') return
    this.generation++
    this.error = ''
    const { verifier, challenge, state } = createPkce()
    const url = authorizeUrl({ clientId: CLIENT_ID, state, challenge })
    const timer = setTimeout(() => this.endLink('Trakt did not answer in time, try again.'), LINK_TIMEOUT_MS)
    timer.unref?.()
    this.linking = { url, expiresAt: Date.now() + LINK_TIMEOUT_MS, verifier, state, timer }
    this.setState('linking')
    shell.openExternal(url).catch(error => {
      if (this.linking?.state === state) this.endLink(`Could not open the browser: ${error instanceof Error ? error.message : error}`)
    })
  }

  /**
   * Stops waiting for the browser.
   * @param {string} [error]
   */
  endLink (error = '') {
    if (this.linking) clearTimeout(this.linking.timer)
    this.linking = null
    this.error = error
    this.setState(this.token ? 'connected' : 'disconnected')
  }

  /**
   * tsumi://trakt/callback?code=...&state=... (protocol.js, opened by the redirect page). Ignored when no sign-in is
   * waiting or when the state is another one (an old or forged link).
   * @param {string} link
   */
  async callback (link) {
    const result = parseCallback(link)
    const linking = this.linking
    if (!result || !linking || !result.state || result.state !== linking.state) return
    ipcMain.emit('window-show')
    clearTimeout(linking.timer)
    this.linking = null // the code and the verifier are single-use
    if (result.error || !result.code) {
      this.endLink(callbackErrorMessage(result.error))
      return
    }
    const generation = ++this.generation
    try {
      const res = await this.postAuth('/oauth/token', {
        code: result.code,
        client_id: CLIENT_ID,
        redirect_uri: TRAKT_REDIRECT_URI,
        grant_type: 'authorization_code',
        code_verifier: linking.verifier
      })
      const answer = await res.json().catch(() => null)
      if (generation !== this.generation) return
      if (!res.ok) {
        this.endLink(`Trakt refused the sign-in (${oauthErrorCode(answer) || res.status}), try again.`)
        return
      }
      if (!answer?.access_token || !answer?.refresh_token) {
        this.endLink('Trakt sent an unreadable answer, try again.')
        return
      }
      this.saveToken(answer)
      await this.loadUser()
      if (generation !== this.generation) return
      this.endLink()
    } catch (error) {
      if (generation !== this.generation) return
      this.endLink(`Could not reach Trakt: ${error instanceof Error ? error.message : error}`)
    }
  }

  cancel () {
    if (this.state !== 'linking') return
    this.generation++
    this.endLink()
  }

  unlink () {
    this.generation++
    const token = this.token
    if (this.linking) clearTimeout(this.linking.timer)
    this.linking = null
    this.error = ''
    this.deleteToken()
    if (this.available) this.setState('disconnected')
    if (token) this.postAuth('/oauth/revoke', { token: token.access, client_id: CLIENT_ID }).catch(() => {})
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
   * Refreshes the access token (refresh tokens are single-use: the answer replaces both); on a refused refresh token
   * the account is disconnected.
   * @returns {Promise<boolean>}
   */
  refresh () {
    if (this.refreshing) return this.refreshing
    const token = this.token
    if (!token) return Promise.resolve(false)
    // A disconnect (or a new sign-in) while the request runs wins: its answer must not bring the old account back.
    const current = () => this.token === token
    const refreshing = (async () => {
      try {
        const res = await this.postAuth('/oauth/token', {
          refresh_token: token.refresh,
          client_id: CLIENT_ID,
          redirect_uri: TRAKT_REDIRECT_URI,
          grant_type: 'refresh_token'
        })
        if (!current()) return false
        if (res.ok) {
          const user = token.user
          const answer = await res.json()
          if (!current()) return false
          this.saveToken(answer, user)
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
        if (this.refreshing === refreshing) this.refreshing = null
      }
    })()
    this.refreshing = refreshing
    return refreshing
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
    // A refresh still running belongs to the removed token (refresh() ignores its answer).
    this.refreshing = null
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
