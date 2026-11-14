import { IPC } from '../preload/preload.js'

export default class Dialog {
  constructor() {
    IPC.on('log-contents', async (log) => {
      try {
        await window.cordova.plugins.saveDialog.saveFile(new Blob([log], { type: 'application/octet-stream' }), `shiru-log-${new Date().toISOString().replace(/[:.]/g, '-')}.log`)
        IPC.emit('log-exported', { error: false })
      } catch (error) {
        console.error('Failed to export logs:', error)
        IPC.emit('log-exported', { error: true })
      }
    })
  }
}