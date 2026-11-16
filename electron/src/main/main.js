import { app } from 'electron'
// First: from here on, uncaught errors of this process are logged (debugger.js) instead of shown in a dialog.
import './debugger.js'
import App from './app.js'

let main // Keep a global reference of the window object, if you don't, the window will, be closed automatically when the JavaScript object is garbage collected.

function createWindow () {
  main = new App()
}

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('ready', createWindow)

  app.on('activate', () => {
    if (main == null) createWindow()
    else main.showAndFocus()
  })
}
