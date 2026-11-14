import { app, safeStorage } from 'electron'
import { EventEmitter } from 'node:events'
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { loadDiscordSdk, ClientStatus, ErrorType, ActivityType } from './discordSdk.js'

// Discord application of Tsumi, used by both presence paths (Social SDK and the Discord app's local RPC).
export const APPLICATION_ID = '1571278531135279258'

const LIBRARY = 'discord_partner_sdk.dll'
const RETRY_MIN = 30_000
const RETRY_MAX = 15 * 60_000

/** @typedef {'unavailable' | 'unlinked' | 'linking' | 'connecting' | 'connected' | 'linked'} SocialState */
/** @typedef {{ available: boolean, state: SocialState, name: string, error: string }} SocialStatus */

/** Where the SDK library is: packaged app (electron-builder extraResources), then development (electron/discord-social-sdk). */
function libraryPath () {
  const candidates = [
    join(process.resourcesPath || '', 'discord-social-sdk', LIBRARY),
    join(__dirname, '..', 'discord-social-sdk', LIBRARY)
  ]
  return candidates.find(path => existsSync(path))
}

/**
 * Text accepted by the SDK: 2 to `max` characters, or undefined to leave the field unset.
 * @param {any} value
 * @param {number} max
 */
function text (value, max) {
  if (typeof value !== 'string') return undefined
  let result = value.trim().slice(0, max)
  if (/[\uD800-\uDBFF]$/.test(result)) result = result.slice(0, -1) // don't cut a surrogate pair
  if (!result) return undefined
  return result.length < 2 ? result.padEnd(2, '​') : result
}

/** @param {any} value */
function timestamp (value) {
  const time = value instanceof Date ? value.getTime() : value
  return typeof time === 'number' && Number.isFinite(time) && time > 0 ? Math.round(time) : undefined
}

/**
 * Maps the activity built by the renderer (Discord RPC shape, see PlayerPage.svelte) to the SDK fields.
 * @param {any} activity
 * @param {string} fallbackPartyId
 */
export function toSdkActivity (activity, fallbackPartyId) {
  const assets = activity.assets || {}
  let largeImage = typeof assets.large_image === 'string' ? assets.large_image.trim() : undefined
  if (largeImage && /^https?:\/\//.test(largeImage)) {
    // External image URLs are accepted directly (300 characters at most); otherwise the app's "icon" asset.
    if (/[^\x21-\x7E]/.test(largeImage)) largeImage = encodeURI(largeImage)
    if (largeImage.length > 300) largeImage = 'icon'
  } else if (largeImage) {
    largeImage = largeImage.slice(0, 300)
  }

  /** @type {{ id: string, current: number, max: number } | undefined} */
  let party
  const size = activity.party?.size
  if (Array.isArray(size) && size.length === 2) {
    const current = Math.max(1, Math.round(Number(size[0])) || 1)
    party = {
      id: text(activity.party.id, 128) || fallbackPartyId,
      current,
      max: Math.max(current, Math.round(Number(size[1])) || 0)
    }
  }

  /** @type {{ label: string, url: string }[]} */
  const buttons = []
  for (const button of Array.isArray(activity.buttons) ? activity.buttons : []) {
    const label = text(button?.label, 32)
    const url = typeof button?.url === 'string' ? button.url : ''
    if (label && /^https?:\/\//.test(url) && url.length <= 512) buttons.push({ label, url })
    if (buttons.length === 2) break
  }

  return {
    type: Object.values(ActivityType).includes(activity.type) ? activity.type : ActivityType.Watching,
    details: text(activity.details, 128),
    state: text(activity.state, 128),
    largeImage: largeImage || undefined,
    largeText: text(assets.large_text, 128),
    start: timestamp(activity.timestamps?.start),
    end: timestamp(activity.timestamps?.end),
    party,
    buttons
  }
}

/**
 * Rich presence through the Discord Social SDK, once the user linked their Discord account: it works even when the
 * Discord app is closed. Without the SDK library (development builds, other systems), `available` stays false and
 * the Discord app's local RPC is used alone.
 *
 * Emits 'status' (status: SocialStatus, routeChanged: boolean) when the state changes; routeChanged is true when
 * presence starts or stops going through the SDK.
 */
export default class DiscordSocial extends EventEmitter {
  /** @type {ReturnType<typeof loadDiscordSdk> | null} */
  sdk = null
  /** @type {ReturnType<ReturnType<typeof loadDiscordSdk>['createClient']> | null} */
  client = null
  available = false
  /** Rich presence is enabled in the settings: connect only then. */
  enabled = false
  /** @type {SocialState} */
  state = 'unavailable'
  name = ''
  error = ''
  /** Refresh token, also saved encrypted (safeStorage) in userData. */
  /** @type {string | null} */
  token = null
  tokenPath = join(app.getPath('userData'), 'discord-social-token')
  /** Incremented by unlink, so a link or refresh still running doesn't apply its result. */
  generation = 0
  refreshing = false
  /** @type {NodeJS.Timeout | undefined} */
  retryTimer
  retryDelay = RETRY_MIN
  /** @type {NodeJS.Timeout | undefined} */
  callbackTimer
  /** Party id when the renderer gives a party size without id (the SDK needs one). */
  partyId = 'tsumi-' + randomBytes(6).toString('hex')

  constructor () {
    super()
    try {
      const path = libraryPath()
      if (!path) return
      this.sdk = loadDiscordSdk(require('koffi'), path)
      this.client = this.sdk.createClient(BigInt(APPLICATION_ID))
    } catch (error) {
      console.warn('Discord Social SDK not available, presence only goes through the Discord app:', error instanceof Error ? error.message : error)
      this.sdk = null
      this.client = null
      return
    }
    const sdk = this.sdk
    this.available = true
    this.client.onStatusChanged((status, error, detail) => this.handleStatus(status, error, detail))
    // Called before the access token expires: get a new one, the session goes on.
    this.client.onTokenExpiration(() => this.refresh())
    // SDK callbacks only run from Discord_RunCallbacks, on this thread.
    this.callbackTimer = setInterval(() => sdk.runCallbacks(), 100)
    this.loadToken()
    this.state = this.token ? 'linked' : 'unlinked'
  }

  get connected () {
    return this.state === 'connected'
  }

  /** @returns {SocialStatus} */
  status () {
    return { available: this.available, state: this.state, name: this.connected ? this.name : '', error: this.error }
  }

  /**
   * @param {SocialState} state
   * @param {string} [error]
   */
  setState (state, error = '') {
    if (this.state === state && this.error === error) return
    const wasConnected = this.connected
    this.state = state
    this.error = error
    this.emit('status', this.status(), wasConnected !== this.connected)
  }

  /** Follows the Rich Presence setting: connected only while it isn't disabled. @param {boolean} enabled */
  setEnabled (enabled) {
    if (!this.client || this.enabled === enabled) return
    this.enabled = enabled
    if (enabled) {
      if (this.token) this.refresh()
    } else {
      this.stopRetry()
      if (this.connected) this.client.clearRichPresence()
      this.client.disconnect()
      if (this.state !== 'linking') this.setState(this.token ? 'linked' : 'unlinked')
    }
  }

  /** Links the Discord account: OAuth2 with PKCE in the Discord app or the browser, then connects. */
  async link () {
    const client = this.client
    if (!client || !this.sdk || this.token || this.state === 'linking') return
    const generation = ++this.generation
    this.stopRetry()
    this.setState('linking')
    try {
      const { code, redirectUri, verifier } = await client.authorize(this.sdk.defaultPresenceScopes())
      if (generation !== this.generation) return
      const tokens = await client.getToken(code, verifier, redirectUri)
      if (generation !== this.generation) return
      this.retryDelay = RETRY_MIN
      await this.useTokens(tokens, generation)
    } catch (error) {
      if (generation !== this.generation) return
      /** @type {any} */
      const failure = error
      console.warn('Discord account linking failed:', failure?.message || failure)
      if (this.token) return this.scheduleRetry()
      const aborted = failure?.result?.type === ErrorType.Aborted
      this.setState('unlinked', aborted ? '' : `Linking failed: ${String(failure?.message || failure).slice(0, 200)}`)
    }
  }

  /** Clears the presence, disconnects and forgets the token (also revoked on Discord's side, best effort). */
  unlink () {
    const client = this.client
    if (!client) return
    this.generation++
    this.stopRetry()
    if (this.state === 'linking') client.abortAuthorize()
    if (this.connected) client.clearRichPresence()
    client.disconnect()
    const token = this.token
    this.deleteToken()
    this.name = ''
    this.setState('unlinked')
    // Removes Tsumi from the account's authorized apps; the local link is gone either way.
    if (token) client.revokeToken(token).catch(error => console.warn('Discord token revocation failed:', error?.message || error))
  }

  /** Gets a new access token from the saved refresh token, then connects (startup, expiry, reconnection). */
  async refresh () {
    const client = this.client
    if (!client || !this.token || this.refreshing) return
    const generation = this.generation
    this.refreshing = true
    this.stopRetry()
    if (this.enabled && !this.connected) this.setState('connecting')
    try {
      const tokens = await client.refreshToken(this.token)
      if (generation !== this.generation) return
      await this.useTokens(tokens, generation)
    } catch (error) {
      if (generation !== this.generation) return
      /** @type {any} */
      const failure = error
      const result = failure?.result
      console.warn('Discord token refresh failed:', failure?.message || failure)
      if (result?.type === ErrorType.HTTPError && result.status >= 400 && result.status < 500 && result.status !== 429) {
        // invalid_grant: the link was removed on Discord's side, or the token expired. The user must link again.
        this.deleteToken()
        if (this.connected) client.clearRichPresence()
        client.disconnect()
        this.setState('unlinked', 'The Discord link expired or was removed, link your account again.')
      } else {
        this.scheduleRetry()
      }
    } finally {
      this.refreshing = false
    }
  }

  /**
   * @param {{ accessToken: string, refreshToken: string }} tokens
   * @param {number} generation
   */
  async useTokens (tokens, generation) {
    const client = this.client
    if (!client) return
    this.saveToken(tokens.refreshToken)
    await client.updateToken(tokens.accessToken)
    if (generation !== this.generation) return
    if (!this.enabled) return this.setState('linked')
    if (client.status() === ClientStatus.Disconnected) {
      this.setState('connecting')
      client.connect()
    }
  }

  /**
   * @param {number} status Discord_Client_Status
   * @param {number} error Discord_Client_Error
   * @param {number} detail
   */
  handleStatus (status, error, detail) {
    const client = this.client
    if (!client) return
    if (status === ClientStatus.Ready) {
      if (!this.token || !this.enabled) return
      this.retryDelay = RETRY_MIN
      this.name = client.currentUserName() || 'your Discord account'
      this.setState('connected')
    } else if (status === ClientStatus.Disconnected) {
      if (this.state !== 'connected' && this.state !== 'connecting') return
      if (error) console.warn(`Discord SDK disconnected: ${this.sdk?.errorName(error)} (${detail})`)
      // Connection lost, or the token was refused (expired or revoked while offline): refresh and reconnect later.
      this.scheduleRetry()
    } else if (this.connected) {
      // Reconnecting: presence goes back through the Discord app until the SDK is ready again.
      this.setState('connecting')
    }
  }

  scheduleRetry () {
    if (!this.token) return this.setState('unlinked')
    if (!this.enabled) return this.setState('linked')
    this.setState('connecting', 'Can\'t reach Discord, trying again soon.')
    clearTimeout(this.retryTimer)
    this.retryTimer = setTimeout(() => this.refresh(), this.retryDelay)
    this.retryDelay = Math.min(this.retryDelay * 2, RETRY_MAX)
  }

  stopRetry () {
    clearTimeout(this.retryTimer)
    this.retryTimer = undefined
  }

  /** @param {any} activity activity built by the renderer */
  setActivity (activity) {
    if (!this.client || !this.connected) return
    this.client.updateRichPresence(toSdkActivity(activity, this.partyId)).catch(error => {
      console.warn('Discord SDK rich presence update failed:', error?.message || error)
    })
  }

  clearActivity () {
    if (this.client && this.connected) this.client.clearRichPresence()
  }

  loadToken () {
    try {
      if (existsSync(this.tokenPath)) this.token = safeStorage.decryptString(readFileSync(this.tokenPath))
    } catch (error) {
      console.warn('Could not read the saved Discord token:', error instanceof Error ? error.message : error)
    }
  }

  /** @param {string} token */
  saveToken (token) {
    this.token = token
    // Without OS encryption (some Linux setups), the link only lasts for this session.
    if (!safeStorage.isEncryptionAvailable()) return
    try {
      writeFileSync(this.tokenPath, safeStorage.encryptString(token))
    } catch (error) {
      console.warn('Could not save the Discord token:', error instanceof Error ? error.message : error)
    }
  }

  deleteToken () {
    this.token = null
    try {
      rmSync(this.tokenPath, { force: true })
    } catch (error) {
      console.warn('Could not delete the Discord token:', error instanceof Error ? error.message : error)
    }
  }

  /** On quit: the presence disappears with the session. */
  shutdown () {
    const client = this.client
    if (!client) return
    this.stopRetry()
    clearInterval(this.callbackTimer)
    if (this.connected) client.clearRichPresence()
    client.disconnect()
  }
}
