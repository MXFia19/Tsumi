import { Client } from '@xhayper/discord-rpc'
import { ipcMain } from 'electron'
import { debounce } from '@/modules/util.js'
import DiscordSocial, { APPLICATION_ID } from './discordSocial.js'

export default class Discord {
  defaultStatus = {
    activity: {
      timestamps: { start: Date.now() },
      details: 'Watching media on Tsumi',
      state: 'Browsing the library',
      assets: {
        large_image: 'icon',
        large_text: 'Tsumi — Media Streaming'
      },
      instance: true,
      type: 3
    }
  }

  // Local RPC with the Discord app: only works while the Discord app is running.
  discord = new Client({ transport: { type: 'ipc' }, clientId: APPLICATION_ID })
  // Discord Social SDK: once the user linked their account, presence goes through it, even with the Discord app closed.
  social = new DiscordSocial()
  // An activity was set through the local RPC (cleared when presence moves to the SDK, so it isn't shown twice).
  rpcActivity = false

  /** @type {string} */
  enableRPC = 'disabled'
  /** @type {Discord['defaultStatus'] | undefined} */
  cachedPresence

  /** @param {import('electron').BrowserWindow} window */
  constructor (window) {
    ipcMain.on('discord', (event, data) => {
      this.cachedPresence = data
      this.debouncedDiscordRPC(this.enableRPC === 'full' ? this.cachedPresence : undefined, this.enableRPC === 'disabled')
    })

    ipcMain.on('discord-rpc', (event, data) => {
      if (this.enableRPC !== data) {
        this.enableRPC = data
        this.social.setEnabled(data !== 'disabled')
        if (data !== 'disabled') {
          if (!this.discord?.user) this.loginRPC()
          else this.debouncedDiscordRPC(this.enableRPC === 'full' ? this.cachedPresence : undefined)
        } else if (this.discord?.user) {
          this.debouncedDiscordRPC(undefined, true)
        }
      }
    })

    ipcMain.on('discord-clear', () => this.debouncedDiscordRPC(undefined, true))

    ipcMain.handle('discord-social:status', () => this.social.status())
    ipcMain.on('discord-social:link', () => this.social.link())
    ipcMain.on('discord-social:unlink', () => this.social.unlink())
    this.social.on('status', (status, routeChanged) => {
      if (!window.isDestroyed()) window.webContents.send('discord-social:status', status)
      // Presence moved between the SDK and the Discord app: show it on the new path right away.
      if (routeChanged && this.enableRPC !== 'disabled') this.setDiscordRPC(this.enableRPC === 'full' ? this.cachedPresence : undefined)
    })

    this.discord.on('ready', async () => {
      this.setDiscordRPC(this.enableRPC === 'full' ? this.cachedPresence : undefined)
      this.discord.subscribe('ACTIVITY_JOIN_REQUEST')
      this.discord.subscribe('ACTIVITY_JOIN')
      this.discord.subscribe('ACTIVITY_SPECTATE')
    })

    this.discord.on('disconnected', () => { if (this.enableRPC !== 'disabled') this.loginRPC() })

    this.discord.on('ACTIVITY_JOIN', ({ secret }) => window.webContents.send('w2glink', secret))
    this.debouncedDiscordRPC = debounce((status, clearActivity) => this.setDiscordRPC(status, clearActivity), 4_500)
  }

  loginRPC () {
    this.discord.login().catch(() => setTimeout(() => this.loginRPC(), 5_000).unref?.())
  }

  clearRPCActivity () {
    this.rpcActivity = false
    this.discord.user?.clearActivity(process.pid).catch(() => {})
  }

  setDiscordRPC (data = this.defaultStatus, clearActivity = false) {
    if (clearActivity) {
      this.social.clearActivity()
      if (this.discord?.user) this.clearRPCActivity()
    } else if (this.social.connected && data?.activity && this.enableRPC !== 'disabled') {
      this.social.setActivity(data.activity)
      // Same application on both paths: don't leave the local RPC activity in the Discord app as well.
      if (this.rpcActivity && this.discord?.user) this.clearRPCActivity()
    } else if (this.discord.user && data && this.enableRPC !== 'disabled') {
      /** @type {(value: any, limit: number) => any} */
      const toLimitedText = (value, limit) => typeof value === 'string' ? value.slice(0, limit) : value
      /** @type {(value: any) => any} */
      const normalizeImageField = (value, key) => {
        if (typeof value !== 'string') return value
        if (key === 'large_image') return value.slice(0, 512)
        if (value.startsWith('mp:')) return toLimitedText(value, 1024)
        if (/^https?:\/\//.test(value)) return `mp:${encodeURI(value).slice(0, 1024)}`
        return toLimitedText(value, 128)
      }
      /** @type {any} */
      const activity = data?.activity ? { ...data.activity } : null
      if (!activity) return

      activity.details = toLimitedText(activity.details, 128)
      activity.state = toLimitedText(activity.state, 128)
      if (activity.assets) {
        activity.assets = {
          ...activity.assets,
          large_image: normalizeImageField(activity.assets.large_image, 'large_image'),
          large_text: toLimitedText(activity.assets.large_text, 128)
        }
        if (activity.assets.small_image) delete activity.assets.small_image
        if (activity.assets.small_text) delete activity.assets.small_text
      }
      if (Array.isArray(activity.buttons)) {
        /** @type {any[]} */
        const rpcButtons = activity.buttons
        activity.buttons = rpcButtons
          .filter((/** @type {any} */ button) => /^https?:\/\//.test(button?.url || ''))
          .slice(0, 2)
          .map((/** @type {any} */ button) => ({
            ...button,
            label: toLimitedText(button.label, 32),
            url: toLimitedText(button.url, 512)
          }))
        if (!activity.buttons.length) activity.buttons = undefined
      }

      this.rpcActivity = true
      this.discord.request('SET_ACTIVITY', { pid: process.pid, activity }).catch((error) => {
        console.warn('Discord RPC SET_ACTIVITY failed:', error?.message || error)
      })
    }
  }

  destroy () {
    this.social.shutdown()
  }
}
