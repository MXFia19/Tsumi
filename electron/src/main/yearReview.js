// Year in Review: saves the summary image rendered by the UI (common/modules/yearreview/shareImage.js)
// and copies it to the clipboard.
import { ipcMain, dialog, clipboard, nativeImage, BrowserWindow, app } from 'electron'
import { writeFile } from 'node:fs/promises'
import { join, basename } from 'node:path'

const MAX_BYTES = 40 * 1024 * 1024

/** PNG bytes sent by the renderer (Uint8Array / ArrayBuffer), or null. */
function pngBuffer (data) {
  if (!(data instanceof Uint8Array) && !(data instanceof ArrayBuffer)) return null
  const buffer = Buffer.from(data instanceof ArrayBuffer ? new Uint8Array(data) : data)
  if (!buffer.length || buffer.length > MAX_BYTES) return null
  // PNG signature
  if (buffer[0] !== 0x89 || buffer[1] !== 0x50 || buffer[2] !== 0x4e || buffer[3] !== 0x47) return null
  return buffer
}

function safeName (name) {
  const clean = basename(String(name || '')).replace(/[^\w .-]/g, '').trim() || 'tsumi-year-in-review.png'
  return clean.toLowerCase().endsWith('.png') ? clean : `${clean}.png`
}

function defaultPath (name) {
  try {
    return join(app.getPath('pictures'), name)
  } catch {
    return name
  }
}

ipcMain.handle('year-review:save-png', async (event, payload) => {
  const buffer = pngBuffer(payload?.data)
  if (!buffer) return { saved: false, error: 'Invalid image' }
  const window = BrowserWindow.fromWebContents(event.sender)
  const options = {
    title: 'Save your Year in Review',
    defaultPath: defaultPath(safeName(payload?.name)),
    filters: [{ name: 'PNG Image', extensions: ['png'] }]
  }
  const { filePath, canceled } = window ? await dialog.showSaveDialog(window, options) : await dialog.showSaveDialog(options)
  if (canceled || !filePath) return { saved: false }
  try {
    await writeFile(filePath, buffer)
    return { saved: true, path: filePath }
  } catch (error) {
    console.error(error)
    return { saved: false, error: error.message }
  }
})

ipcMain.handle('year-review:copy-png', (event, data) => {
  const buffer = pngBuffer(data)
  if (!buffer) return false
  const image = nativeImage.createFromBuffer(buffer)
  if (image.isEmpty()) return false
  clipboard.writeImage(image)
  return true
})
