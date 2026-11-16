import { readFile } from 'node:fs/promises'
import os from 'node:os'
import { app, ipcMain } from 'electron'
import log from 'electron-log'
import { autoUpdater } from 'electron-updater'
import { redact } from './security.js'

log.initialize({ spyRendererConsole: true })
log.transports.file.level = 'debug'
log.transports.file.maxSize = 10_000_000 // 10MB
autoUpdater.logger = log

/** @param {unknown} value */
function redactValue (value) {
  if (typeof value === 'string') return redact(value)
  if (value instanceof Error) {
    const copy = new Error(redact(value.message))
    copy.name = value.name
    copy.stack = redact(value.stack || '')
    return copy
  }
  return value
}

// Users export this log to report problems (Settings > App > Export Logs), and it also receives the renderer console:
// tokens, Authorization headers and the query of stream links (where their tokens are) never reach it.
log.hooks.push(message => ({ ...message, data: message.data.map(redactValue) }))

// Errors nothing caught in this process go to the log, instead of Electron's "A JavaScript error occurred in the main
// process" dialog (a failed network request somewhere must not interrupt the user).
log.errorHandler.startCatching({ showDialog: false })

export default class Debug {
  constructor () {
    // Redacted again on export: the file may hold lines written before the redaction existed.
    ipcMain.on('get-log-contents', async ({ sender }) => {
      try {
        ipcMain.emit('log-contents', sender, redact(await readFile(log.transports.file.getFile().path, 'utf8')))
      } catch (error) {
        console.warn('Could not read the log file:', error?.message || error)
        sender.send('log-exported', { error: true })
      }
    })
    ipcMain.on('reset-log-contents', async ({ sender }) => sender.send('log-reset', { success: await log.transports.file.getFile().clear() }))
    ipcMain.on('get-device-info', async ({ sender }) => {
      const { model, speed } = os.cpus()[0]
      const deviceInfo = {
        features: app.getGPUFeatureStatus(),
        info: await app.getGPUInfo('complete'),
        cpu: { model, speed },
        ram: os.totalmem()
      }
      sender.send('device-info', JSON.stringify(deviceInfo))
    })
  }
}
