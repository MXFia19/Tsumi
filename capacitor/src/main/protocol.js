import { Browser } from '@capacitor/browser'
import { IPC } from '../preload/preload.js'
import { App } from '@capacitor/app'

export default class Protocol {
  // schema: tsumi://key/value (shiru:// is still accepted for older links and login redirects)
  protocolMap = {
    alauth: token => this.sendToken(token),
    malauth: token => this.sendMalToken(token),
    anime: id => IPC.emit('open-anime', {id}),
    malanime: id => IPC.emit('open-anime', {id, mal: true}),
    search: id => this.play(id),
    w2g: link => IPC.emit('w2glink', link),
    schedule: () => IPC.emit('schedule'),

    update: () => IPC.emit('quit-and-install'),
    show: () => IPC.emit('window-show')
  }

  protocolRx = /(?:tsumi|shiru):\/\/([a-z0-9]+)\/(.*)/i

  constructor() {
    App.getLaunchUrl().then(res => {
      if (location.hash !== '#skipAlLogin') {
        location.hash = '#skipAlLogin'
        if (res) this.handleProtocol(res.url)
      } else location.hash = ''
    })
    App.addListener('appUrlOpen', ({ url }) => this.handleProtocol(url))
  }

  /**
   * @param {string} line
   */
  sendToken(line) {
    let token = line.split('access_token=')[1].split('&token_type')[0]
    if (token) {
      if (token.endsWith('/')) token = token.slice(0, -1)
      IPC.emit('altoken', token)
    }
  }

  /**
   * @param {string} line
   */
  sendMalToken(line) {
    let code = line.split('code=')[1].split('&state')[0]
    let state = line.split('&state=')[1]
    if (code && state) {
      if (code.endsWith('/')) code = code.slice(0, -1)
      if (state.endsWith('/')) state = state.slice(0, -1)
      if (state.includes('%')) state = decodeURIComponent(state)
      IPC.emit('maltoken', code, state)
    }
  }

  /**
   * @param {string} id - The media id.
   */
  play(id) {
    IPC.emit('play-anime', id)
    IPC.emit('window-show')
  }

  /**
   * @param {string} text
   */
  handleProtocol(text) {
    const match = text.match(this.protocolRx)
    if (match) this.protocolMap[match[1]]?.(match[2])
  }
}