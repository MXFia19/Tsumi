import { installDom } from './dom.js'
import { sandboxRuntime } from './runtime.js'

// Host side of the Sora module sandbox (worker side: runtime.js).
//
// Every call runs in a new dedicated Web Worker made from a data: URL (opaque origin): the module code never runs in
// the app's page, so it cannot read localStorage (AniList / MAL tokens), the DOM or the Electron bridge, and an endless
// loop only blocks its own thread. The worker has no network API of its own: its fetch / fetchv2 send a message here
// and `onRequest` (extension.js) performs the request after checking it. The call is rejected and the worker
// terminated after `timeout` ms, or when `signal` aborts.
//
// Why a Worker and not a sandboxed iframe: in Electron a sandboxed iframe of the page runs on the page's own thread
// (checked: a 3 s loop in it froze the page's timers), so a module stuck in while(true) would freeze the whole app and
// the host timer meant to stop it could never fire. A worker has its own thread and terminate() always works.

const MAX_REQUESTS_PER_CALL = 500
const MAX_PARALLEL_REQUESTS = 12

let workerUrl = null
/** The worker script: the DOM shim, then the runtime (both self-contained functions, see their files). */
function sandboxWorkerUrl () {
  if (!workerUrl) {
    const source = `(${installDom.toString()})(self);\n(${sandboxRuntime.toString()})();\n`
    workerUrl = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(source)
  }
  return workerUrl
}

export function abortError () {
  try {
    return new DOMException('The operation was aborted.', 'AbortError')
  } catch {
    const error = new Error('The operation was aborted.')
    error.name = 'AbortError'
    return error
  }
}

let nextCall = 0

/**
 * Runs `functionName(...args)` of a module script in a fresh sandbox.
 * @param {object} options
 * @param {string} options.script module source
 * @param {string} options.functionName searchResults, extractDetails, extractEpisodes, extractStreamUrl...
 * @param {any[]} [options.args] structured-cloneable arguments
 * @param {number} [options.timeout] ms before the worker is terminated
 * @param {AbortSignal} [options.signal]
 * @param {(request: { kind: 'fetch' | 'fetchv2', url: string, method: string, headers: Record<string, string>, body: string | ArrayBuffer | null, redirect: string | null }, signal: AbortSignal) => Promise<{ status: number, statusText: string, url: string, redirected: boolean, type: string, headers: [string, string][], body: ArrayBuffer }>} options.onRequest
 * @param {(...args: any[]) => void} [options.log]
 */
export function runSandboxed ({ script, functionName, args = [], timeout = 30000, signal, onRequest, log = () => {} }) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError())
    let worker
    try {
      worker = new Worker(sandboxWorkerUrl(), { name: `extension ${functionName}` })
    } catch (error) {
      return reject(new Error(`Extension sandbox failed to start: ${error?.message || error}`))
    }
    const callId = ++nextCall
    const network = new AbortController() // aborts the requests in flight when the call ends
    const requests = new Map() // request id -> AbortController
    const queue = []
    let active = 0
    let total = 0
    let ready = false
    let done = false

    const finish = (error, value) => {
      if (done) return
      done = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      worker.terminate()
      network.abort()
      queue.length = 0
      if (error) reject(error)
      else resolve(value)
    }
    const timer = setTimeout(() => finish(new Error('Extension execution timeout')), timeout)
    const onAbort = () => finish(abortError())
    signal?.addEventListener('abort', onAbort, { once: true })

    const respond = (message, transfer = []) => {
      if (done) return
      try {
        worker.postMessage(message, transfer)
      } catch (error) {
        log('Sandbox response failed', error)
      }
    }

    const perform = async (request) => {
      const controller = new AbortController()
      const abort = () => controller.abort()
      network.signal.addEventListener('abort', abort, { once: true })
      requests.set(request.id, controller)
      active++
      try {
        const response = await onRequest(request, controller.signal)
        respond({ type: 'response', id: request.id, response }, response?.body instanceof ArrayBuffer ? [response.body] : [])
      } catch (error) {
        respond({ type: 'response', id: request.id, error: controller.signal.aborted ? 'The operation was aborted.' : (error?.message || 'Network request failed') })
      } finally {
        active--
        requests.delete(request.id)
        network.signal.removeEventListener('abort', abort)
        if (queue.length && !done) perform(queue.shift())
      }
    }

    worker.onmessage = ({ data }) => {
      if (done || !data || typeof data !== 'object') return
      switch (data.type) {
        case 'ready':
          ready = true
          if (data.leaked?.length) log('Sandbox lockdown incomplete', data.leaked)
          return
        case 'request':
          if (++total > MAX_REQUESTS_PER_CALL) return respond({ type: 'response', id: data.id, error: `Too many requests (over ${MAX_REQUESTS_PER_CALL} in one call)` })
          if (active >= MAX_PARALLEL_REQUESTS) queue.push(data)
          else perform(data)
          return
        case 'abort': {
          const index = queue.findIndex(request => request.id === data.id)
          if (index !== -1) queue.splice(index, 1)
          requests.get(data.id)?.abort()
          return
        }
        case 'result':
          if (data.callId === callId) finish(null, data.result)
          return
        case 'error':
          if (data.callId === callId) finish(new Error(String(data.message || 'Extension failed')))
      }
    }
    worker.onerror = (event) => {
      event.preventDefault?.()
      // Before 'ready' the runtime itself failed; later it is an uncaught error of the module (timer callback...),
      // which only gets logged, as it did in the page: the call still ends with its result or its timeout.
      if (!ready) finish(new Error(`Extension sandbox failed to start${event.message ? `: ${event.message}` : ''}`))
      else log('Uncaught error in extension', event.message)
    }
    worker.onmessageerror = () => log('Unreadable message from the extension sandbox')

    try {
      worker.postMessage({ type: 'call', callId, script: String(script), functionName, args })
    } catch (error) {
      finish(new Error(`Extension arguments cannot be sent to the sandbox: ${error?.message || error}`))
    }
  })
}
