import { contextBridge, ipcRenderer } from 'electron'

// Only the app's own page gets the IPC bridge. The main process already blocks navigations away from it
// (app.js, guardNavigation); this is the second lock: a foreign page that still ended up in the window must not be able
// to send IPC messages (open files, read logs, run the downloads...).
const trustedPage = location.protocol === 'file:' || (process.env.NODE_ENV === 'development' && location.origin === 'http://localhost:5000')

// Version of the app (app.getVersion() in the main process, passed as a renderer argument by app.js).
const appVersion = process.argv.find(arg => arg.startsWith('--tsumi-version='))?.slice('--tsumi-version='.length) || ''

if (trustedPage) {
  contextBridge.exposeInMainWorld('IPC', {
    emit: (event, data) => {
      ipcRenderer.send(event, data)
    },
    on: (event, callback) => {
      ipcRenderer.on(event, (event, ...args) => callback(...args))
    },
    once: (event, callback) => {
      ipcRenderer.once(event, (event, ...args) => callback(...args))
    },
    off: (event) => {
      ipcRenderer.removeAllListeners(event)
    },
    invoke: (event, data) => ipcRenderer.invoke(event, data)
  })
}
contextBridge.exposeInMainWorld('version', {
  arch: process.arch,
  platform: process.platform,
  session: process.env.XDG_SESSION_TYPE || '',
  app: appVersion
})
if (trustedPage) {
  contextBridge.exposeInMainWorld('electron', {
    isMinimized: () => ipcRenderer.invoke('electron:isMinimized'),
    isFullScreen: () => ipcRenderer.invoke('electron:isFullScreen'),
    onMinimize: (callback) => ipcRenderer.on('electron:onMinimize', (event, isMinimized) => callback(isMinimized)),
    onFullScreen: (callback) => ipcRenderer.on('electron:onFullScreen', (event, isFullScreen) => callback(isFullScreen)),
    getYouTube: () => ipcRenderer.invoke('electron:getYouTube'),
    getProxyPort: () => ipcRenderer.invoke('electron:getProxyPort')
  })
}
