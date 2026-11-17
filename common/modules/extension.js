import { writable } from 'simple-store-svelte'
import { settings } from '@/modules/settings.js'
import { ELECTRON } from '@/modules/bridge.js'
import { isStremioManifest, loadStremioAddon, callStremioFunction, normalizeManifestUrl, addonBaseUrl } from '@/modules/stremio.js'
import { runSandboxed, abortError } from '@/modules/sandbox/sandbox.js'
import { checkModuleUrl, checkManifestUrl, isLocalUrl, maskUrl, moduleDomains, readCapped, scriptUrlCandidates } from '@/modules/sandbox/network.js'
import { installKey, shortHash } from '@/modules/extensionUtils.js'
import Debug from 'debug'

const debug = Debug('ui:extension:manager')

// A module call (search, episodes, stream) that has not answered by then is stopped.
const EXTENSION_TIMEOUT = 30000

let cachedProxyPort = null
async function getProxyPort () {
  if (cachedProxyPort !== null) return cachedProxyPort
  try {
    cachedProxyPort = await ELECTRON.getProxyPort?.()
    return cachedProxyPort
  } catch {
    return null
  }
}

/** Fetch endpoint of the main process proxy (electron/src/main/streamProxy.js). */
function proxyFetchUrl (port) {
  return `http://localhost:${port}/fetch`
}

export async function extensionFetch (url, options = {}) {
  const headers = options.headers || {}
  const method = (options.method || 'GET').toUpperCase()
  const body = options.body || null

  try {
    const fetchOptions = { headers, method }
    if (body != null && method !== 'GET' && method !== 'HEAD') {
      fetchOptions.body = typeof body === 'string' ? body : JSON.stringify(body)
    }
    const response = await fetch(url, fetchOptions)
    return response
  } catch (error) {
    debug('fetch failed:', error)
    return null
  }
}

/** Text of a manifest / script, capped like module responses. */
async function getText (url) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return new TextDecoder().decode(await readCapped(response))
}

/**
 * Network rules of one module: it may reach the user's machine or local network only when it is served from there
 * itself (a module being developed on localhost).
 */
function modulePolicy (extension) {
  return { allowLocal: isLocalUrl(extension?.url) || isLocalUrl(extension?.scriptUrl) }
}

/**
 * A request of a sandboxed module (fetch / fetchv2 in the worker, see sandbox/runtime.js), after the network rules.
 * fetchv2 goes through the main process proxy when it is running, so the headers a page cannot set (User-Agent,
 * Referer, Cookie) work; fetch behaves like the browser fetch modules used to call.
 */
async function moduleRequest (request, signal, policy) {
  const url = checkModuleUrl(request.url, policy)
  const method = String(request.method || 'GET').toUpperCase()
  const headers = request.headers && typeof request.headers === 'object' ? request.headers : {}
  const body = method === 'GET' || method === 'HEAD' ? null : (request.body ?? null)
  const proxyPort = request.kind === 'fetchv2' && (body === null || typeof body === 'string') ? await getProxyPort() : null

  const redirect = request.redirect === 'manual' || request.redirect === 'error' ? request.redirect : 'follow'
  let response
  if (proxyPort) {
    // The main process applies the network rules itself, on every redirect and on the address each name resolves to
    // (electron/src/main/streamProxy.js /fetch): it gets the module's policy and redirect mode.
    response = await fetch(proxyFetchUrl(proxyPort), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: url.href, headers, method, ...(body !== null ? { body } : {}), redirect, allowLocal: !!policy?.allowLocal }),
      signal
    })
    // Refused (local address...) or failed (connection, too large): the module's request fails, as a direct fetch would.
    if (response.headers.get('x-proxy-error')) {
      const reason = await response.json().then(data => data?.error, () => null)
      throw new Error(reason || `Request failed (${response.status})`)
    }
  } else {
    response = await fetch(url.href, { method, headers, body: body ?? undefined, redirect, credentials: 'omit', signal })
    // A redirect can lead anywhere: the module never reads a local address it could not request itself.
    if (response.redirected && response.url) {
      try {
        checkModuleUrl(response.url, policy)
      } catch (error) {
        try { await response.body?.cancel() } catch {}
        throw error
      }
    }
  }
  // Through the proxy: the final URL and the Location of a redirect left to the module come in X- headers.
  const location = proxyPort ? response.headers.get('x-location') : null
  return {
    status: response.status,
    statusText: response.statusText,
    url: proxyPort ? (response.headers.get('x-final-url') || url.href) : (response.url || url.href),
    redirected: proxyPort ? response.headers.has('x-redirected') : response.redirected,
    type: response.type,
    headers: location ? [...response.headers, ['location', location]] : [...response.headers],
    body: await readCapped(response)
  }
}

// Arguments cross to the sandbox as JSON values (what the module code used to receive through JSON.stringify).
function plainArgs (args) {
  return args.map(arg => {
    const json = JSON.stringify(arg)
    return json === undefined ? undefined : JSON.parse(json)
  })
}

function runModule (extension, functionName, args, signal) {
  const policy = modulePolicy(extension)
  return runSandboxed({
    script: extension.script,
    functionName,
    args: plainArgs(args),
    timeout: EXTENSION_TIMEOUT,
    signal,
    onRequest: (request, requestSignal) => moduleRequest(request, requestSignal, policy),
    log: (...messages) => debug(`[${extension.manifest?.sourceName || extension.key || 'module'}]`, ...messages)
  })
}

/** Runs a function of a module script in the sandbox (no local network access). */
export async function executeExtensionFunction (scriptCode, functionName, ...args) {
  return runModule({ script: scriptCode }, functionName, args)
}

/** Settles with `promise`, or rejects with an AbortError as soon as `signal` aborts. */
function raceSignal (promise, signal) {
  if (!signal) return promise
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortError())
    if (signal.aborted) return onAbort()
    signal.addEventListener('abort', onAbort, { once: true })
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort))
  })
}

export async function loadExtension (manifestUrl) {
  const resolvedManifestUrl = checkManifestUrl(normalizeManifestUrl(manifestUrl))

  // Errors show the host only: Stremio manifest URLs often carry the user's configuration or a private token.
  let manifest
  try {
    manifest = JSON.parse(await getText(resolvedManifestUrl))
  } catch (error) {
    throw new Error(`Failed to load the manifest from ${maskUrl(resolvedManifestUrl)}: ${error.message}`)
  }

  // Stremio addons have no script: they are queried over HTTP instead.
  if (isStremioManifest(manifest)) {
    return { ...loadStremioAddon(resolvedManifestUrl, manifest), url: resolvedManifestUrl }
  }

  if (!manifest || !manifest.sourceName || !manifest.scriptUrl) {
    throw new Error('Invalid manifest: expected a Sora module (sourceName + scriptUrl) or a Stremio addon')
  }

  // http(s) only, https first (scriptUrlCandidates).
  const candidates = scriptUrlCandidates(manifest.scriptUrl, resolvedManifestUrl)
  let lastError
  for (const scriptUrl of candidates) {
    try {
      return { manifest, script: await getText(scriptUrl), url: resolvedManifestUrl, scriptUrl }
    } catch (error) {
      lastError = error
    }
  }
  throw new Error(`Failed to load the script from ${maskUrl(candidates[candidates.length - 1])}: ${lastError?.message}`)
}

/**
 * Calls a function of an extension. Sora modules run in the sandbox (sandbox/sandbox.js); Stremio addons are plain
 * HTTP requests. `signal` stops the call (the module's worker is terminated).
 * @param {any} extension
 * @param {string} functionName
 * @param {any[]} [args]
 * @param {{ signal?: AbortSignal }} [options]
 */
export async function callExtension (extension, functionName, args = [], { signal } = {}) {
  if (signal?.aborted) throw abortError()
  if (extension?.type === 'stremio') {
    return raceSignal(callStremioFunction(extension, functionName, ...args), signal)
  }

  if (!extension?.script) {
    throw new Error('Extension not loaded')
  }

  try {
    const result = await runModule(extension, functionName, args, signal)

    if (typeof result === 'string') {
      try {
        return JSON.parse(result)
      } catch {
        return result
      }
    }

    return result
  } catch (error) {
    if (error?.name !== 'AbortError') debug(`Failed to call ${functionName} on extension:`, error)
    throw error
  }
}

export function callExtensionFunction (extension, functionName, ...args) {
  return callExtension(extension, functionName, args)
}

/** Hosts an extension says it contacts, shown before installing it. */
function extensionDomains (loaded) {
  if (loaded.type === 'stremio') {
    try {
      return [new URL(loaded.stremio.base).hostname]
    } catch {
      return []
    }
  }
  return moduleDomains(loaded.manifest, loaded.script, loaded.scriptUrl)
}

function sameManifestUrl (a, b) {
  try {
    return checkManifestUrl(normalizeManifestUrl(a)) === checkManifestUrl(normalizeManifestUrl(b))
  } catch {
    return false
  }
}

class ExtensionManager {
  constructor () {
    this.extensions = new Map()
    this.loading = new Map()
    // key -> { state: 'loading' | 'ready' | 'error', error?: string, updatedFrom?: string } (shown in Settings)
    this.status = new Map()
    this.enabled = writable({})
    this.subscribers = new Set()
    settings.subscribe(value => {
      if (value.extensions) {
        this.syncFromSettings(value.extensions)
      }
    })
    // Extensions that failed to load (offline at start, server down) are loaded again once the connection is back.
    window.addEventListener('online', () => this.retryFailed())
  }

  notify () {
    this.subscribers.forEach(cb => cb())
  }

  subscribe (cb) {
    this.subscribers.add(cb)
    cb()
    return () => this.subscribers.delete(cb)
  }

  /** Settings key for a loaded extension: the entry it updates, else a new key (installKey, same scheme as iOS). */
  keyFor (loaded, addressHash) {
    return installKey(
      { type: loaded.type === 'stremio' ? 'stremio' : 'sora', name: loaded.manifest?.sourceName, version: loaded.manifest?.version, url: loaded.url, addressHash },
      Object.entries(settings.value.extensions || {}),
      sameManifestUrl
    )
  }

  /**
   * Loads an extension without installing it, for the install dialog: what it is, the hosts it says it uses, and the
   * installed entry it would update (same manifest URL, or same Sora module name).
   */
  async previewExtension (manifestUrl) {
    const loaded = await loadExtension(manifestUrl)
    // Short hash of the addon address, only used in the key when name-version is already taken.
    const addressHash = await shortHash(addonBaseUrl(loaded.url))
    const key = this.keyFor(loaded, addressHash)
    const existingKey = settings.value.extensions?.[key] ? key : null
    return {
      loaded,
      addressHash,
      existingKey,
      installedVersion: existingKey ? settings.value.extensions[existingKey].manifest?.version || null : null,
      domains: extensionDomains(loaded),
      insecureScript: !!loaded.scriptUrl?.startsWith('http:') && !isLocalUrl(loaded.scriptUrl)
    }
  }

  /** Installs a previewed extension; an installed entry it matches is updated in place (same key). */
  installExtension (preview) {
    const { loaded } = preview
    const key = this.keyFor(loaded, preview.addressHash)
    this.extensions.set(key, loaded)
    this.status.set(key, { state: 'ready' })
    settings.set({
      ...settings.value,
      extensions: {
        ...settings.value.extensions,
        [key]: {
          url: loaded.url,
          enabled: true,
          manifest: loaded.manifest,
          // An update of an installed module keeps "Link results to AniList / TMDB".
          ...(typeof settings.value.extensions?.[key]?.linkResults === 'boolean' ? { linkResults: settings.value.extensions[key].linkResults } : {})
        }
      }
    })
    this.notify()
    return key
  }

  async addExtension (manifestUrl) {
    try {
      return this.installExtension(await this.previewExtension(manifestUrl))
    } catch (error) {
      console.error('Failed to add extension:', error?.message || error)
      throw error
    }
  }

  async removeExtension (key) {
    this.extensions.delete(key)
    this.status.delete(key)

    const updated = { ...settings.value.extensions }
    delete updated[key]
    settings.set({
      ...settings.value,
      extensions: updated
    })
    this.notify()
  }

  toggleExtension (key, enabled) {
    if (settings.value.extensions?.[key]) {
      settings.set({
        ...settings.value,
        extensions: {
          ...settings.value.extensions,
          [key]: {
            ...settings.value.extensions[key],
            enabled
          }
        }
      })
      this.notify()
    }
  }

  /**
   * "Link results to AniList / TMDB" of a Sora module: off, its search results open as they are
   * (sora/searchsource.js, sora/resultpage.js).
   */
  setLinkResults (key, link) {
    if (!settings.value.extensions?.[key]) return
    settings.set({
      ...settings.value,
      extensions: {
        ...settings.value.extensions,
        [key]: {
          ...settings.value.extensions[key],
          linkResults: !!link
        }
      }
    })
    this.notify()
  }

  setDefault (key) {
    settings.set({
      ...settings.value,
      defaultExtension: key
    })
    this.notify()
  }

  unsetDefault () {
    settings.set({
      ...settings.value,
      defaultExtension: null
    })
    this.notify()
  }

  setStar (key) {
    settings.set({
      ...settings.value,
      starredExtension: key
    })
    this.notify()
  }

  unsetStar () {
    settings.set({
      ...settings.value,
      starredExtension: null
    })
    this.notify()
  }

  /**
   * The stored manifest follows the one served (a module update changes its version, name, icon...), under the same
   * key: no duplicate entry, and the default / starred choice stays.
   * @returns {{ updatedFrom?: string }}
   */
  updateStoredManifest (key, loaded) {
    const config = settings.value.extensions?.[key]
    if (!config || JSON.stringify(config.manifest) === JSON.stringify(loaded.manifest)) return {}
    settings.set({
      ...settings.value,
      extensions: {
        ...settings.value.extensions,
        [key]: { ...config, manifest: loaded.manifest }
      }
    })
    const before = config.manifest?.version
    return before && before !== loaded.manifest?.version ? { updatedFrom: before } : {}
  }

  load (key, url) {
    if (this.loading.has(key)) return this.loading.get(key)
    this.status.set(key, { state: 'loading' })
    const promise = loadExtension(url)
      .then(loaded => {
        if (!settings.value.extensions?.[key]) return // removed meanwhile
        this.extensions.set(key, loaded)
        this.status.set(key, { state: 'ready', ...this.updateStoredManifest(key, loaded) })
      })
      .catch(error => {
        debug(`Failed to load extension ${key}:`, error)
        this.status.set(key, { state: 'error', error: error?.message || 'Failed to load' })
      })
      .finally(() => {
        this.loading.delete(key)
        this.notify()
      })
    this.loading.set(key, promise)
    this.notify()
    return promise
  }

  async syncFromSettings (extensionConfigs) {
    for (const [key, config] of Object.entries(extensionConfigs)) {
      if (!this.extensions.has(key) && !this.loading.has(key) && config?.url && this.status.get(key)?.state !== 'error') {
        this.load(key, config.url)
      }
    }
  }

  /** Loads one extension again (Retry button of Settings). */
  retry (key) {
    const config = settings.value.extensions?.[key]
    if (!config?.url) return Promise.resolve()
    this.extensions.delete(key)
    return this.load(key, config.url)
  }

  retryFailed () {
    for (const [key, status] of this.status) {
      if (status.state === 'error') this.retry(key)
    }
  }

  getStatus (key) {
    return this.status.get(key) || (this.extensions.has(key) ? { state: 'ready' } : null)
  }

  getEnabled () {
    const result = []
    for (const [key, ext] of this.extensions) {
      const config = settings.value.extensions?.[key]
      if (config?.enabled) {
        result.push({ key, ...ext })
      }
    }
    return result
  }

  async callDefault (functionName, ...args) {
    const defaultKey = settings.value.defaultExtension
    if (!defaultKey) throw new Error('No default extension set')

    const extension = this.extensions.get(defaultKey)
    if (!extension) throw new Error(`Extension ${defaultKey} not loaded`)

    return callExtensionFunction(extension, functionName, ...args)
  }

  async callAll (functionName, ...args) {
    const enabled = this.getEnabled()
    const results = []

    for (const ext of enabled) {
      try {
        const result = await callExtensionFunction(ext, functionName, ...args)
        results.push({ extension: ext.key, result })
      } catch (error) {
        debug(`Error calling ${functionName} on ${ext.key}:`, error)
      }
    }

    return results
  }
}

export const extensionManager = new ExtensionManager()

export const manager = {
  subscribe: (cb) => extensionManager.subscribe(cb),
  addExtension: (url) => extensionManager.addExtension(url),
  previewExtension: (url) => extensionManager.previewExtension(url),
  installExtension: (preview) => extensionManager.installExtension(preview),
  removeExtension: (key) => extensionManager.removeExtension(key),
  toggleExtension: (key, enabled) => extensionManager.toggleExtension(key, enabled),
  setLinkResults: (key, link) => extensionManager.setLinkResults(key, link),
  setDefault: (key) => extensionManager.setDefault(key),
  unsetDefault: () => extensionManager.unsetDefault(),
  setStar: (key) => extensionManager.setStar(key),
  unsetStar: () => extensionManager.unsetStar(),
  retry: (key) => extensionManager.retry(key),
  getStatus: (key) => extensionManager.getStatus(key),
  getEnabled: () => extensionManager.getEnabled(),
  callDefault: (...args) => extensionManager.callDefault(...args),
  callAll: (...args) => extensionManager.callAll(...args)
}
