// Worker side of the Sora module sandbox (host side: sandbox.js).
//
// A module runs in a dedicated Web Worker created from a data: URL: its own thread (an endless loop cannot freeze the
// app, the host terminates the worker) and an opaque origin with no window, DOM, localStorage, IndexedDB or Electron
// bridge of the app. Before the module code runs, every API that could reach the network or the app's storage by
// itself is removed; fetch and fetchv2 are replaced by functions that ask the host (postMessage), which applies the
// network rules (network.js) and performs the request.
//
// Self-contained on purpose: sandbox.js sends its source to the worker (sandboxRuntime.toString()), so the function
// must not use anything declared outside its own body (no imports, no module-level constants).
export function sandboxRuntime () {
  'use strict'
  const scope = self
  const hasOwn = Object.prototype.hasOwnProperty
  const post = scope.postMessage.bind(scope)
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
  const NativeHeaders = scope.Headers
  const NativeRequest = scope.Request
  const NativeResponse = scope.Response
  const NativeBlob = scope.Blob

  /* ---------- lock down: no direct network, storage or nested workers ---------- */
  const REMOVED = [
    'fetch', 'XMLHttpRequest', 'XMLHttpRequestUpload', 'XMLHttpRequestEventTarget', 'WebSocket', 'WebSocketStream',
    'EventSource', 'WebTransport', 'importScripts', 'Worker', 'SharedWorker', 'ServiceWorker', 'FontFace', 'fonts',
    'indexedDB', 'IDBFactory', 'caches', 'CacheStorage', 'BroadcastChannel', 'RTCPeerConnection',
    'webkitRTCPeerConnection', 'RTCDataChannel', 'webkitRequestFileSystem', 'webkitRequestFileSystemSync',
    'webkitResolveLocalFileSystemURL', 'webkitResolveLocalFileSystemSyncURL', 'postMessage'
  ]
  // The sandbox refuses to run modules when one of these is still reachable.
  const REQUIRED = ['fetch', 'XMLHttpRequest', 'WebSocket', 'WebSocketStream', 'EventSource', 'WebTransport', 'importScripts', 'Worker', 'SharedWorker', 'indexedDB', 'caches']
  for (const name of REMOVED) {
    for (let target = scope; target; target = Object.getPrototypeOf(target)) {
      if (!hasOwn.call(target, name)) continue
      try { delete target[name] } catch {}
      if (hasOwn.call(target, name)) {
        try { Object.defineProperty(target, name, { value: undefined, writable: false, configurable: false }) } catch {}
      }
    }
  }
  const leaked = REQUIRED.filter(name => {
    try { return scope[name] !== undefined } catch { return false }
  })

  /* ---------- page globals the Svelte app gave modules (they used to run in the page) ---------- */
  if (typeof scope.window === 'undefined') scope.window = scope
  const makeStorage = () => {
    let data = {}
    const storage = {
      getItem: (key) => hasOwn.call(data, String(key)) ? data[String(key)] : null,
      setItem: (key, value) => { data[String(key)] = String(value) },
      removeItem: (key) => { delete data[String(key)] },
      clear: () => { data = {} },
      key: (index) => Object.keys(data)[index] ?? null
    }
    Object.defineProperty(storage, 'length', { get: () => Object.keys(data).length })
    return storage
  }
  // In memory only: one call = one fresh worker, as on iOS.
  scope.localStorage = makeStorage()
  scope.sessionStorage = makeStorage()

  /* ---------- network through the host ---------- */
  const describe = (error) => {
    if (error === undefined || error === null) return 'Unknown error'
    if (typeof error === 'string') return error
    if (typeof error === 'object' && error.message) return String(error.message)
    try { return String(error) } catch { return 'Unknown error' }
  }
  const abortError = () => {
    try { return new DOMException('The operation was aborted.', 'AbortError') } catch {
      const error = new Error('The operation was aborted.')
      error.name = 'AbortError'
      return error
    }
  }

  const normHeaders = (headers) => {
    const out = {}
    if (!headers || typeof headers !== 'object') return out
    if (Array.isArray(headers)) {
      for (const pair of headers) {
        if (pair && pair.length >= 2 && pair[1] !== undefined && pair[1] !== null) out[String(pair[0])] = String(pair[1])
      }
      return out
    }
    if (typeof headers.forEach === 'function' && typeof headers.get === 'function') {
      headers.forEach((value, key) => { out[String(key)] = String(value) })
      return out
    }
    for (const key in headers) {
      if (!hasOwn.call(headers, key)) continue
      const value = headers[key]
      if (value !== undefined && value !== null && typeof value !== 'function') out[key] = String(value)
    }
    return out
  }
  const hasHeader = (headers, name) => Object.keys(headers).some(key => key.toLowerCase() === name)

  // Request bodies cross to the host as a string or an ArrayBuffer (+ the content type the browser would set).
  const encodeBody = async (body, kind) => {
    if (body === undefined || body === null) return null
    if (typeof body === 'string') return { body }
    if (body instanceof URLSearchParams) return { body: body.toString(), type: 'application/x-www-form-urlencoded;charset=UTF-8' }
    const binary = body instanceof ArrayBuffer || ArrayBuffer.isView(body) || body instanceof NativeBlob ||
      (typeof FormData !== 'undefined' && body instanceof FormData) || (typeof ReadableStream !== 'undefined' && body instanceof ReadableStream)
    if (binary) {
      const request = new NativeRequest('https://sandbox.invalid/', { method: 'POST', body, duplex: 'half' })
      return { body: await request.arrayBuffer(), type: request.headers.get('content-type') }
    }
    // fetchv2 always sent objects as JSON; fetch turns them into a string like the browser does.
    return { body: kind === 'fetchv2' ? JSON.stringify(body) : String(body) }
  }

  let nextRequest = 0
  const pending = new Map()
  const send = async (kind, url, method, headers, body, { signal, redirect } = {}) => {
    if (signal && signal.aborted) throw abortError()
    const encoded = method === 'GET' || method === 'HEAD' ? null : await encodeBody(body, kind)
    if (encoded && encoded.type && !hasHeader(headers, 'content-type')) headers['Content-Type'] = encoded.type
    return new Promise((resolve, reject) => {
      const id = ++nextRequest
      const onAbort = () => {
        if (!pending.has(id)) return
        pending.delete(id)
        post({ type: 'abort', id })
        reject(abortError())
      }
      pending.set(id, {
        resolve: (value) => { if (signal) signal.removeEventListener('abort', onAbort); resolve(value) },
        reject: (error) => { if (signal) signal.removeEventListener('abort', onAbort); reject(error) }
      })
      if (signal) signal.addEventListener('abort', onAbort, { once: true })
      const message = { type: 'request', id, kind, url: String(url), method, headers, body: encoded ? encoded.body : null, redirect: redirect || null }
      post(message, encoded && encoded.body instanceof ArrayBuffer ? [encoded.body] : [])
    })
  }

  const decode = (buffer, encoding) => {
    try {
      return new TextDecoder(encoding || 'utf-8').decode(buffer)
    } catch {
      return new TextDecoder('utf-8').decode(buffer)
    }
  }

  // fetchv2 responses: headers as a plain object (Set-Cookie included when the proxy forwards it), as before.
  const plainHeaders = (pairs) => {
    const plain = {}
    for (const [key, value] of pairs || []) plain[String(key).toLowerCase()] = String(value)
    if (plain['x-set-cookie']) {
      let value
      try {
        const cookies = JSON.parse(plain['x-set-cookie'])
        value = Array.isArray(cookies) ? cookies.join(', ') : cookies
      } catch {
        value = plain['x-set-cookie']
      }
      plain['set-cookie'] = value
      plain['Set-Cookie'] = value
    }
    const hidden = (name, fn) => Object.defineProperty(plain, name, { value: fn, enumerable: false, configurable: true, writable: true })
    hidden('get', (name) => { const value = plain[String(name).toLowerCase()]; return value === undefined ? null : value })
    hidden('has', (name) => hasOwn.call(plain, String(name).toLowerCase()))
    hidden('forEach', (cb, thisArg) => { Object.keys(plain).forEach(key => { if (key !== 'Set-Cookie') cb.call(thisArg, plain[key], key, plain) }) })
    return plain
  }

  const makeResponse = (meta, kind, encoding) => {
    const buffer = meta.body instanceof ArrayBuffer ? meta.body : new ArrayBuffer(0)
    const status = Number(meta.status) || 0
    const headers = kind === 'fetchv2' ? plainHeaders(meta.headers) : new NativeHeaders(meta.headers || [])
    if (kind === 'fetch' && status >= 200 && status <= 599) {
      // A real Response (body stream, formData...), with the url / redirected of the request.
      const nullBody = status === 101 || status === 204 || status === 205 || status === 304
      const response = new NativeResponse(nullBody ? null : buffer, { status, statusText: String(meta.statusText || ''), headers })
      Object.defineProperty(response, 'url', { value: String(meta.url || '') })
      Object.defineProperty(response, 'redirected', { value: !!meta.redirected })
      return response
    }
    const contentType = () => (typeof headers.get === 'function' ? headers.get('content-type') : null) || ''
    const response = {
      ok: status >= 200 && status < 300,
      status,
      statusText: String(meta.statusText || ''),
      url: String(meta.url || ''),
      redirected: !!meta.redirected,
      type: String(meta.type || 'basic'),
      bodyUsed: false,
      headers,
      text: async () => decode(buffer, encoding),
      json: async () => JSON.parse(decode(buffer, encoding)),
      arrayBuffer: async () => buffer.slice(0),
      bytes: async () => new Uint8Array(buffer.slice(0)),
      blob: async () => new NativeBlob([buffer], { type: contentType() }),
      clone: () => makeResponse(meta, kind, encoding)
    }
    return response
  }

  const looksLikeOptions = (value) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false
    if (value.headers && typeof value.headers === 'object') return true
    return hasOwn.call(value, 'method') || hasOwn.call(value, 'body')
  }

  // fetchv2(url, headers, method, body) or fetchv2(url, { headers, method, body }); Sora hosts also pass
  // (redirect, encoding) as 5th / 6th arguments (encoding decodes text(), e.g. 'windows-1251').
  scope.fetchv2 = async function fetchv2 (url, headers, method, body, redirect, encoding) {
    let h = headers
    let m = method
    let b = body
    // redirect false (or an options object with redirect 'manual' / 'error'): the 3xx answer is the result, with its
    // Location header, like the iOS app (SoraPrelude.swift fetchv2).
    let follow = redirect
    if (looksLikeOptions(h)) {
      m = m || h.method
      b = b !== undefined ? b : h.body
      if (follow === undefined && h.redirect) follow = h.redirect !== 'manual' && h.redirect !== 'error'
      h = h.headers
    }
    const reply = await send('fetchv2', url, String(m || 'GET').toUpperCase(), normHeaders(h), b, { redirect: follow === false ? 'manual' : null })
    if (reply.error !== undefined) throw new Error(reply.error)
    return makeResponse(reply.response || {}, 'fetchv2', typeof encoding === 'string' ? encoding : null)
  }

  // fetch(url | Request, init): init wins over the Request's own method / headers / body.
  scope.fetch = async function fetch (input, init) {
    const options = init || {}
    const request = input instanceof NativeRequest ? input : null
    const url = request ? request.url : (input && typeof input === 'object' && input.href ? input.href : input)
    const method = String(options.method || (request ? request.method : 'GET')).toUpperCase()
    const headers = normHeaders(options.headers !== undefined ? options.headers : (request ? request.headers : undefined))
    let body = options.body
    if (body === undefined && request && method !== 'GET' && method !== 'HEAD') body = await request.arrayBuffer()
    const reply = await send('fetch', url, method, headers, body, { signal: options.signal || (request ? request.signal : null), redirect: options.redirect || (request ? request.redirect : null) })
    if (reply.error !== undefined) throw new TypeError(reply.error)
    return makeResponse(reply.response || {}, 'fetch', null)
  }

  /* ---------- calls ---------- */
  const postResult = (callId, result) => {
    try {
      post({ type: 'result', callId, result })
    } catch {
      // Not cloneable (functions, DOM shim nodes...): send what JSON keeps, as the old JSON.stringify path did.
      let plain = null
      try {
        const json = JSON.stringify(result)
        plain = json === undefined ? null : JSON.parse(json)
      } catch (error) {
        post({ type: 'error', callId, message: 'The extension returned a value that cannot be read: ' + describe(error) })
        return
      }
      post({ type: 'result', callId, result: plain })
    }
  }

  const run = async ({ callId, script, functionName, args }) => {
    try {
      if (leaked.length) throw new Error('Extension sandbox unavailable (' + leaked.join(', ') + ' still reachable)')
      if (!/^[A-Za-z_$][\w$]*$/.test(String(functionName))) throw new Error('Invalid extension function name')
      // Same evaluation as before (module code + call in one async function body): top-level await and function
      // declarations keep working, and every call starts from a fresh evaluation of the module.
      const fn = new AsyncFunction('__tsumiArgs', String(script) + '\n;return await ' + functionName + '(...__tsumiArgs)')
      postResult(callId, await fn(Array.isArray(args) ? args : []))
    } catch (error) {
      post({ type: 'error', callId, message: describe(error) })
    }
  }

  scope.addEventListener('message', (event) => {
    const data = event.data
    if (!data || typeof data !== 'object') return
    if (data.type === 'response') {
      const entry = pending.get(data.id)
      if (!entry) return
      pending.delete(data.id)
      entry.resolve(data)
    } else if (data.type === 'call') {
      run(data)
    }
  })

  post({ type: 'ready', leaked })
}
