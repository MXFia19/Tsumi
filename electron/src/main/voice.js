import { ipcMain, session, systemPreferences } from 'electron'

/**
 * Same origin as the app page: same scheme, and for http(s) the same host and port. The packaged app is a file:// page
 * (its URL origin is "null"), the development one http://localhost:5000.
 * @param {string | undefined} url
 * @param {string | undefined} appUrl
 */
function sameOrigin (url, appUrl) {
  try {
    const a = new URL(url ?? '')
    const b = new URL(appUrl ?? '')
    if (a.protocol !== b.protocol) return false
    return a.protocol === 'file:' || a.host === b.host
  } catch {
    return false
  }
}

/**
 * Watch Together voice chat (common/routes/w2g/PROTOCOL.md v2.4): the microphone is granted to the app page of the main
 * window only while the renderer is in voice ('w2g:voice' true from "Join voice", false when it leaves). Not to an
 * embedded frame (YouTube trailers...) nor another origin, and the grant ends when the page reloads, navigates or
 * crashes (the page that asked is gone). Cameras and screen capture are never granted. Every other permission keeps
 * Electron's default (granted), as before this handler.
 * @param {import('electron').BrowserWindow} mainWindow
 */
export function setupVoicePermission (mainWindow) {
  let voiceActive = false
  const contents = mainWindow.webContents

  ipcMain.handle('w2g:voice', async ({ sender, senderFrame }, enabled) => {
    // Only the app page itself (the top frame of the main window) turns it on.
    const fromApp = sender === contents && (!senderFrame || senderFrame.parent === null)
    voiceActive = !!enabled && fromApp
    if (voiceActive && process.platform === 'darwin') {
      try {
        if (systemPreferences.getMediaAccessStatus('microphone') !== 'granted') return await systemPreferences.askForMediaAccess('microphone')
      } catch {
        return false
      }
    }
    return voiceActive
  })

  // A reload, a navigation of the main frame or a crash ends the voice session the page asked for.
  const reset = () => { voiceActive = false }
  contents.on('did-navigate', reset)
  contents.on('render-process-gone', reset)
  contents.on('destroyed', reset)

  session.defaultSession.setPermissionRequestHandler((webContents, permission, callback, details) => {
    if (permission !== 'media') return callback(true)
    const media = /** @type {{ mediaTypes?: string[], isMainFrame?: boolean, requestingUrl?: string }} */ (details)
    const types = media.mediaTypes ?? []
    const audioOnly = types.length > 0 && types.every(type => type === 'audio')
    const appFrame = webContents === contents && media.isMainFrame === true && sameOrigin(media.requestingUrl, webContents.getURL())
    callback(voiceActive && audioOnly && appFrame)
  })
}
