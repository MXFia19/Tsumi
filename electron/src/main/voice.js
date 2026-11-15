import { ipcMain, session, systemPreferences } from 'electron'

/**
 * Watch Together voice chat (common/routes/w2g/PROTOCOL.md v2.4): the microphone is granted to the main window only
 * while the renderer is in voice ('w2g:voice' true from "Join voice", false when it leaves). Cameras and screen
 * capture are never granted. Every other permission keeps Electron's default (granted), as before this handler.
 * @param {import('electron').BrowserWindow} mainWindow
 */
export function setupVoicePermission (mainWindow) {
  let voiceActive = false

  ipcMain.handle('w2g:voice', async ({ sender }, enabled) => {
    voiceActive = !!enabled && sender === mainWindow.webContents
    if (voiceActive && process.platform === 'darwin') {
      try {
        if (systemPreferences.getMediaAccessStatus('microphone') !== 'granted') return await systemPreferences.askForMediaAccess('microphone')
      } catch {
        return false
      }
    }
    return voiceActive
  })

  session.defaultSession.setPermissionRequestHandler((webContents, permission, callback, details) => {
    if (permission !== 'media') return callback(true)
    const types = /** @type {{ mediaTypes?: string[] }} */ (details).mediaTypes ?? []
    const audioOnly = types.length > 0 && types.every(type => type === 'audio')
    callback(voiceActive && audioOnly && webContents === mainWindow.webContents)
  })
}
