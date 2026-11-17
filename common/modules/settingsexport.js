// Settings copied out of the app (Settings > App: Export to Clipboard, App and Device Info, the "Current Settings"
// debug log line). The Watch Together TURN login never leaves the device. The export (a backup or a move to another
// device, like the iOS export) keeps the extensions; the support texts (device info, logs) show only their host, since
// manifest URLs often carry a private token or the user's configuration (the Extensions tab shows their host only).
// Pure functions (see settingsexport.test.mjs).
import { maskUrl } from './sandbox/network.js'

/** Settings left out of an export: the TURN login (iOS ShellSettingsTransfer.privateKeys). */
export const DEVICE_SETTINGS = ['w2gTurnUsername', 'w2gTurnCredential']

const HIDDEN = '(hidden)'

/**
 * A settings backup / share (Export to Clipboard): without the DEVICE_SETTINGS.
 * @param {Record<string, any> | null | undefined} settings
 */
export function exportableSettings (settings) {
  const copy = { ...(settings || {}) }
  for (const key of DEVICE_SETTINGS) delete copy[key]
  return copy
}

/**
 * Settings for support (App and Device Info, debug log): the TURN login hidden, each extension with its name, version
 * and host only.
 * @param {Record<string, any> | null | undefined} settings
 */
export function redactedSettings (settings) {
  const copy = { ...(settings || {}) }
  for (const key of ['w2gTurnUsername', 'w2gTurnCredential']) {
    if (copy[key]) copy[key] = HIDDEN
  }
  if (copy.extensions && typeof copy.extensions === 'object') {
    copy.extensions = Object.fromEntries(Object.entries(copy.extensions).map(([key, extension]) => [key, {
      host: maskUrl(extension?.url),
      enabled: extension?.enabled,
      name: extension?.manifest?.sourceName || extension?.manifest?.name,
      version: extension?.manifest?.version
    }]))
  }
  return copy
}

/**
 * Settings to save on import: the DEVICE_SETTINGS the imported data leaves out (an export made by this version) keep
 * the device's own values, instead of falling back to the defaults.
 * @param {Record<string, any>} imported validated imported settings
 * @param {Record<string, any> | null | undefined} current settings of the device
 */
export function withDeviceSettingsKept (imported, current) {
  const merged = { ...imported }
  for (const key of DEVICE_SETTINGS) {
    if (!Object.hasOwn(merged, key) && current && Object.hasOwn(current, key)) merged[key] = current[key]
  }
  return merged
}
