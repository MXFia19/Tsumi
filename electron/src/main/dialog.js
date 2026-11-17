import { ipcMain, dialog } from 'electron'
import { writeFile } from 'fs/promises'
import { setPlayerPath } from './externalPlayer.js'

export default class Dialog {
  constructor () {
    ipcMain.on('player', async ({ sender }) => {
      const { filePaths, canceled } = await dialog.showOpenDialog({
        title: 'Select video player executable',
        properties: ['openFile'],
        // Only a program can be started (externalPlayer.js checkExecutable).
        ...(process.platform === 'win32' ? { filters: [{ name: 'Programs', extensions: ['exe', 'com'] }] } : {})
      })
      if (canceled) return
      if (filePaths.length) {
        const path = filePaths[0]
        // The main process keeps the program the user picked here: it is the only one external-player:launch starts.
        setPlayerPath(path)
        sender.send('player', path)
      }
    })
    ipcMain.on('log-contents', async (sender, log) => {
      try {
        const { filePath, canceled } = await dialog.showSaveDialog({
          title: 'Select export location for the log file',
          defaultPath: `tsumi-log-${new Date().toISOString().replace(/[:.]/g, '-')}.log`,
          filters: [{ name: 'Log File', extensions: ['log'] }]
        })
        if (canceled || !filePath) return
        await writeFile(filePath, log, { encoding: 'utf8', mode: 0o644 })
        sender.send('log-exported', { error: false })
      } catch (error) {
        console.error(error)
        sender.send('log-exported', { error: true })
      }
    })
  }
}
