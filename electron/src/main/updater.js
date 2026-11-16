import { autoUpdater } from 'electron-updater'
import { ipcMain, shell } from 'electron'

export default class Updater {
  hasUpdate = false
  downloading = false

  window
  availableInterval
  downloadedInterval

  /**
   * @param {import('electron').BrowserWindow} window
   */
  constructor (window) {
    this.window = window
    autoUpdater.autoInstallOnAppQuit = false
    // "Install Updates On Quit" (App settings, sent by UpdateModal.svelte at launch and on every change).
    ipcMain.on('updater:install-on-quit', (event, enabled) => { autoUpdater.autoInstallOnAppQuit = enabled === true })
    // Releases of github.com/MXFia19/Tsumi ("publish" in electron/package.json): latest.yml of the latest release.
    // Failures (offline, rate limit...) are reported through the 'error' event.
    ipcMain.on('update', () => autoUpdater.checkForUpdates()?.catch(() => {}))
    autoUpdater.on('error', () => {
      // The download failed: stop announcing it (the renderer would show "downloading" forever). The next check
      // ('update', every 5 minutes) starts over.
      clearInterval(this.availableInterval)
      this.availableInterval = null
      this.downloading = false
      this.send('update-aborted')
    })
    autoUpdater.on('update-available', (info) => {
      if (!this.downloading) {
        this.downloading = true
        clearInterval(this.availableInterval)
        this.availableInterval = setInterval(() => {
          if (!this.hasUpdate) this.send('update-available', info.version)
        }, 1_000)
        this.availableInterval.unref?.()
      }
    })
    // Percentage of the download (the progress bar of the update button).
    autoUpdater.on('download-progress', (progress) => {
      const percent = Number(progress?.percent)
      if (Number.isFinite(percent)) this.send('update-progress', Math.min(100, Math.max(0, Math.round(percent))))
    })
    autoUpdater.on('update-downloaded', (info) => {
      if (!this.hasUpdate) {
        this.hasUpdate = true
        this.downloading = false
        clearInterval(this.availableInterval)
        this.availableInterval = null
        this.send('update-progress', 100)
        this.downloadedInterval = setInterval(() => {
          if (this.hasUpdate) this.send('update-downloaded', info.version)
        }, 1_000)
        this.downloadedInterval.unref?.()
      }
    })
  }

  /**
   * @param {string} channel
   * @param {...any} args
   */
  send (channel, ...args) {
    if (!this.window.isDestroyed()) this.window.webContents.send(channel, ...args)
  }

  install (forceRunAfter = false) {
    if (this.hasUpdate && forceRunAfter) {
      setImmediate(() => {
        try {
          this.window.close()
        } catch (e) {}
        clearInterval(this.downloadedInterval)
        autoUpdater.quitAndInstall(true, true)
      })
      if (process.platform === 'darwin') shell.openExternal('https://github.com/MXFia19/Tsumi/releases/latest')
      this.hasUpdate = false
      return true
    }
    return false
  }
}
