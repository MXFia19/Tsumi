import { app, ipcMain } from 'electron'
import { openExternal } from './util.js'
import { isSignInLinkKey, protocolParams } from './security.js'
import path from 'path'

if (process.defaultApp) {
  if (process.argv.length >= 2) {
    app.setAsDefaultProtocolClient('tsumi', process.execPath, [path.resolve(process.argv[1])])
  }
} else {
  app.setAsDefaultProtocolClient('tsumi')
}

/** "What's New" of the update notification (tsumi://changelog/). */
const RELEASES_URL = 'https://github.com/MXFia19/Tsumi/releases'

export default class Protocol {
  // schema: tsumi://key/value
  protocolMap = {
    alauth: token => this.sendToken(token),
    malauth: token => this.sendMalToken(token),
    anime: id => this.window.webContents.send('open-anime', { id }),
    malanime: id => this.window.webContents.send('open-anime', { id, mal: true }),
    search: id => this.play(id),
    w2g: link => this.window.webContents.send('w2glink', link),
    // Trakt sign-in: tsumi://trakt/callback?code=...&state=... (docs/trakt/index.html), handled by trakt.js in this process.
    trakt: link => this.onTrakt?.(link),
    schedule: () => this.window.webContents.send('schedule'),
    update: () => ipcMain.emit('quit-and-install'),
    changelog: () => openExternal(RELEASES_URL),
    show: () => ipcMain.emit('window-show')
  }

  protocolRx = /tsumi:\/\/([a-z0-9]+)[/#]?(.*)/i

  /**
   * @param {import('electron').BrowserWindow} window
   * @param {(link: string) => void} [onTrakt] receives the rest of tsumi://trakt/ links ("callback?code=...&state=...")
   */
  constructor (window, onTrakt) {
    this.window = window
    this.onTrakt = onTrakt

    app.on('open-url', (event, url) => {
      event.preventDefault()
      this.handleProtocol(url)
    })

    // Links the app was launched with (Windows / Linux pass them as arguments). The renderer asks for 'version' once it
    // listens, and again after every reload (profile swap, sign-in...): the launch link is only handled the first time,
    // otherwise a reload would rejoin an old Watch Together lobby or reopen an anime.
    if (process.argv.length >= 2 && !process.defaultApp) {
      ipcMain.once('version', () => {
        for (const line of process.argv) {
          this.handleProtocol(line)
        }
      })
    }

    app.on('second-instance', (event, commandLine) => {
      // Someone tried to run a second instance, we should focus our window.
      ipcMain.emit('window-show')
      for (const line of commandLine) {
        this.handleProtocol(line)
      }
    })

    ipcMain.on('handle-protocol', (event, text) => {
      this.handleProtocol(text)
    })
  }

  /** The sign-in was denied or the link carries no credentials: the renderer shows "Login Canceled". */
  authCanceled () {
    if (!this.window.isDestroyed()) this.window.webContents.send('auth-canceled')
  }

  /**
   * AniList implicit grant: tsumi://alauth#access_token=...&token_type=Bearer&expires_in=...
   * @param {string} line
   */
  sendToken (line) {
    const token = protocolParams(line).get('access_token')
    if (token) this.window.webContents.send('altoken', token)
    else this.authCanceled()
  }

  /**
   * MyAnimeList authorization code: tsumi://malauth?code=...&state=... (or ?error=access_denied&state=... when denied).
   * @param {string} line
   */
  sendMalToken (line) {
    const params = protocolParams(line)
    const code = params.get('code')
    const state = params.get('state')
    if (code && state) this.window.webContents.send('maltoken', code, state)
    else this.authCanceled()
  }

  /**
   * @param {string} id - The media id.
   */
  play (id) {
    this.window.webContents.send('play-anime', id)
    ipcMain.emit('window-show')
  }

  /**
   * @param {string} text
   * @param {{ fromSignIn?: boolean }} [options] fromSignIn: the link ends a sign-in the user started in the app's own
   *   sign-in window (app.js finishAuth). Links from anywhere else (command line, second instance, the renderer) never
   *   set it.
   */
  handleProtocol (text, { fromSignIn = false } = {}) {
    if (typeof text !== 'string' || !text) return

    // Handle tsumi:// scheme
    const match = text.match(this.protocolRx)
    const key = match?.[1].toLowerCase()
    if (!key || !Object.hasOwn(this.protocolMap, key)) return match
    // A sign-in link from a web page or another app (tsumi://alauth#access_token=<someone else's token>) would sign the
    // app into that account, and the user's progress would then go to it (login CSRF). On PC the AniList and
    // MyAnimeList sign-ins always come back through the sign-in window, so such links are only accepted from there.
    if (isSignInLinkKey(key) && !fromSignIn) {
      console.warn('Ignored a sign-in link that did not come from the sign-in window')
      return match
    }
    this.protocolMap[key](match[2])
    return match
  }
}
