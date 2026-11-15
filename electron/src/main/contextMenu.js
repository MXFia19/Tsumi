import { Menu, clipboard, shell } from 'electron'
import { contextMenuEntries } from './contextMenuTemplate.js'

/**
 * Right-click menu of a window (Shiru 6.9.0, #32): Cut / Copy / Paste / Select All in text fields, Copy on selected
 * text, Copy Link / Open Link in Browser, Copy Image / Copy Image Address, and Inspect when devtools are allowed.
 * Electron only emits `context-menu` when the page did not cancel the DOM `contextmenu` event (Blink shows the menu
 * from the event's default action), so the app's own right-click handlers (on:contextmenu|preventDefault on episode
 * cards, sidebar links, dropdowns...) keep working and never show this menu as well.
 * @param {import('electron').BrowserWindow} window
 * @param {{ inspect?: boolean }} [options] inspect: always offer Inspect (development); otherwise it is offered once
 * the devtools were opened (Settings > App > Open Devtools)
 */
export function setupContextMenu (window, { inspect = false } = {}) {
  const contents = window.webContents
  let devtoolsUsed = inspect
  contents.on('devtools-opened', () => { devtoolsUsed = true })
  contents.on('context-menu', (_event, params) => {
    const entries = contextMenuEntries(params, { inspect: devtoolsUsed || contents.isDevToolsOpened() })
    if (!entries.length || window.isDestroyed()) return
    const run = (action, value) => {
      if (contents.isDestroyed()) return
      switch (action) {
        case 'replaceMisspelling':
          contents.replaceMisspelling(value)
          break
        case 'copyLink':
        case 'copyImageAddress':
          clipboard.writeText(value)
          break
        case 'openLink':
          shell.openExternal(value)
          break
        case 'copyImage':
          contents.copyImageAt(params.x, params.y)
          break
        case 'inspect':
          // Detached like the other devtools of the app (the window is frameless).
          if (!contents.isDevToolsOpened()) contents.openDevTools({ mode: 'detach' })
          contents.inspectElement(params.x, params.y)
          break
      }
    }
    const template = entries.map(entry => 'label' in entry ? { label: entry.label, click: () => run(entry.action, entry.value) } : entry)
    Menu.buildFromTemplate(template).popup({ window })
  })
}
