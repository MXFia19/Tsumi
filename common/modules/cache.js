import { generalDefaults, historyDefaults, queryDefaults, notifyDefaults } from './util.js'
import { staleKeys, staleMappingKeys, QUERY_LIMITS, UNPRUNED_QUERIES } from './cachepolicy.js'
import { parseDateOnly } from './dates.js'
import { writable } from 'simple-store-svelte'
import equal from 'fast-deep-equal/es6'
import rfdc from 'rfdc'
import Debug from 'debug'
const debug = Debug('ui:cache')
const deepClone = rfdc({ proto: false, circles: false, ownProps: true })

let currentDB = null
const version = 1

/** TMDB answers of older versions, kept forever in the general store (details, seasons, collections, release dates). */
const LEGACY_TMDB_GENERAL = /^tmdb-(details-|season-|collection-|release-dates-)/
/** TMDB images of older versions, written to the history store by mistake (caches.MEDIA did not exist). */
const LEGACY_TMDB_HISTORY = /^tmdb-banner-/
/** Longest wait for the MyAnimeList lists before an AniList answer is cached without their entries (filled later). */
const FILL_TIMEOUT = 10_000
const TIMED_OUT = Symbol('timed out')

/**
 * Map of user IDs to their corresponding batch writer instances.
 *
 * @type {Map<string, object>}
 */
const batchWriters = new Map()

/**
 * A collection of cache configurations used in the application.
 * Each entry represents a cache with its unique key and optional database configuration.
 *
 * @constant
 * @type {Object<string, {key: string, database?: boolean}>}
 */
export const caches = Object.freeze({
  GENERAL: { key: 'general', database: true },
  QUERIES: { key: 'queries', database: true },
  MAPPINGS: { key: 'mappings', database: true },
  USER_LISTS: { key: 'user_lists', database: true },
  MEDIA_CACHE: { key: 'medias', database: true },
  HISTORY: { key: 'history', database: true },
  NOTIFICATIONS: { key: 'notifications', database: true },
  COMPOUND: { key: 'compound' },
  EXTENSIONS: { key: 'extensions' },
  EPISODES: { key: 'episodes' },
  FOLLOWING: { key: 'following' },
  RECOMMENDATIONS: { key: 'recommendations' },
  SEARCH_IDS: { key: 'searchIDS' },
  SEARCH: { key: 'search' },
  RSS: { key: 'rss' }
})

/**
 * Opens the IndexedDB database.
 * @param {string} dbName - The name of the database to open.
 * @returns {Promise<IDBDatabase>} - A promise that resolves to the database instance.
 */
function open (dbName) {
  if (currentDB) return currentDB
  currentDB = new Promise((resolve, reject) => {
    const request = indexedDB.open(String(dbName), version)
    request.onerror = (event) => { currentDB = null; reject(event.target.error) }
    request.onsuccess = (event) => resolve(event.target.result)
    request.onupgradeneeded = event => {
      const _database = event.target.result
      for (const { key, database } of Object.values(caches)) {
        if (database && !_database.objectStoreNames.contains(key)) {
          _database.createObjectStore(key, { keyPath: 'key' })
        }
      }
    }
  })
  return currentDB
}

/**
 * Loads all values from a specified cache (object store).
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @returns {Promise<Array>} - A promise that resolves to an array of all stored values.
 */
async function loadAll (userID, cache) {
  try {
    const database = await open(userID)
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(cache.key, 'readonly')
      const objectStore = transaction.objectStore(cache.key)
      const request = objectStore.getAll()
      request.onerror = (event) => reject(event.target.error)
      request.onsuccess = (event) => {
        resolve(event.target.result.reduce((acc, item) => {
          acc[item.key] = item.value
          return acc
        }, {}))
      }
    })
  } catch (error) {
    console.error(`Failed to load cache ${cache.key} for user ${userID}:`, error)
    throw error
  }
}

/**
 * Retrieves a specific value from a cache using a key.
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @param {string} key - The key to retrieve the associated value for.
 * @returns {Promise<*>} - A promise that resolves to the value associated with the key, or null if not found.
 */
async function get (userID, cache, key) {
  const database = await open(userID)
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(cache.key, 'readonly')
    const objectStore = transaction.objectStore(cache.key)
    const request = objectStore.get(key)
    request.onerror = (error) => reject(error.target.error)
    request.onsuccess = (error) => resolve(error.target.result ? error.target.result.value : null)
  })
}

/**
 * Stores or updates a value in a specified cache.
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @param {string} key - The key to associate with the value.
 * @param {*} value - The value to store.
 * @returns {Promise<void>} - A promise that resolves when the operation is complete.
 */
async function set (userID, cache, key, value) {
  const database = await open(userID)
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(cache.key, 'readwrite')
    const objectStore = transaction.objectStore(cache.key)
    const request = objectStore.put({ key, value })
    request.onerror = (event) => reject(event.target.error)
    request.onsuccess = () => resolve()
  })
}

/**
 * Deletes specific keys from a specified cache.
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @param {string[]} keys - An array of keys to delete.
 * @returns {Promise<void>} - A promise that resolves when all specified keys are deleted.
 */
async function remove (userID, cache, keys) {
  if (!keys || keys.length === 0) return
  const database = await open(userID)
  const transaction = database.transaction(cache.key, 'readwrite')
  const objectStore = transaction.objectStore(cache.key)
  keys.forEach(k => objectStore.delete(k))
  return waitForTransaction(transaction)
}

/**
 * Clears all data from a specified cache.
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @returns {Promise<void>} - A promise that resolves when the cache is cleared.
 */
async function reset (userID, cache) {
  const database = await open(userID)
  const transaction = database.transaction(cache.key, 'readwrite')
  transaction.objectStore(cache.key).clear()
  return waitForTransaction(transaction)
}

/**
 * Deletes the entire database and all caches for a user.
 * @param {string} userID - The unique ID of the user (database name).
 * @returns {Promise<void>} - A promise that resolves when the database is deleted.
 */
async function purge (userID) {
  if (currentDB) {
    try { (await currentDB).close() } catch {}
    currentDB = null
  }
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(String(userID))
    request.onerror = (event) => reject(event.target.error)
    request.onsuccess = () => resolve()
  })
}

/**
 * Writes multiple entries into the specified IndexedDB cache in a single transaction.
 *
 * This function only updates IndexedDB. It does NOT update the in-memory cache.
 * Callers are responsible for keeping memory and disk in sync if needed.
 *
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The name of the cache (object store).
 * @param {Array<[string, any]>} entries - An array of [key, value] pairs to insert/update.
 * @returns {Promise<void>} A promise that resolves when the transaction completes.
 */
async function putMany (userID, cache, entries) {
  if (!entries.length) return
  const database = await open(userID)
  const transaction = database.transaction(cache.key, 'readwrite')
  const objectStore = transaction.objectStore(cache.key)
  for (const [key, value] of entries) objectStore.put({ key, value })
  return waitForTransaction(transaction)
}

/**
 * Attempts to recover individual entries from a corrupted cache store.
 * Iterates through all keys and tries to read each one individually, collecting successful reads and logging failures.
 *
 * @param {string} userID - The unique ID of the user (database name).
 * @param {keyof typeof caches} cache - The cache to recover from.
 * @returns {Promise<Object>} An object containing successfully recovered key-value pairs.
 */
async function recoverCache (userID, cache) {
  const recovered = {}
  const corruptedKeys = []
  try {
    const database = await open(userID)
    const transaction = database.transaction(cache.key, 'readonly')
    const objectStore = transaction.objectStore(cache.key)
    const keysRequest = objectStore.getAllKeys()
    const keys = await new Promise((resolve, reject) => {
      keysRequest.onsuccess = () => resolve(keysRequest.result)
      keysRequest.onerror = () => reject(keysRequest.error)
    })
    console.error(`Found ${keys.length} keys in ${cache.key}, attempting individual recovery...`)
    for (const key of keys) {
      try {
        recovered[key] = await new Promise((resolve, reject) => {
          const getRequest = objectStore.get(key)
          getRequest.onsuccess = () => {
            if (getRequest.result && getRequest.result.value !== undefined) resolve(getRequest.result.value)
            else reject(new Error('Empty or malformed entry'))
          }
          getRequest.onerror = () => reject(getRequest.error)
        })
        console.error(`Recovered ${cache.key}:${key}`)
      } catch (error) {
        corruptedKeys.push(key)
        console.error(`Failed to recover ${cache.key}:${key}:`, error.message)
      }
    }
    if (corruptedKeys.length > 0) console.error(`Recovered ${Object.keys(recovered).length}/${keys.length} entries from ${cache.key}. Corrupted keys:`, corruptedKeys)
    else console.error(`Successfully recovered all ${Object.keys(recovered).length} entries from ${cache.key}`)
  } catch (error) {
    console.error(`Could not access ${cache.key} for recovery:`, error)
  }
  return recovered
}

/**
 * Retrieves (or creates) a batch writer for the given user.
 *
 * @param {string} userID - The unique ID of the user (database name).
 * @returns {object} The batch writer instance associated with the user.
 */
function getBatchWriter (userID) {
  if (!batchWriters.has(userID)) batchWriters.set(userID, createBatchWriter(userID))
  return batchWriters.get(userID)
}

/**
 * Wraps an IndexedDB transaction in a Promise.
 * Resolves when the transaction completes successfully and rejects if the transaction aborts or errors.
 *
 * @param {IDBTransaction} transaction - The IndexedDB transaction to monitor.
 * @returns {Promise<void>} A promise that resolves on success, rejects on failure.
 */
function waitForTransaction (transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onabort = transaction.onerror = (error) => reject(error?.target?.error || new Error('IndexedDB transaction failed'))
  })
}

/**
 * Creates a batch writer for a given user that buffers cache writes and flushes them to IndexedDB after a delay.
 *
 * This groups multiple writes into a single IndexedDB transaction and retries failed writes by re-enqueuing them.
 *
 * @param {string} userID - The unique ID of the user (database name).
 * @param {number} [firstFlushDelay=10000] - Delay in ms before the first flush before flushing writes to IndexedDB.
 * @param {number} [subsequentFlushDelay=1500] - Delay in ms for subsequent flushes before flushing writes to IndexedDB.
 * @param {number} [resetDelay=5000] - Delay in ms after which retry counts are reset.
 * @returns {Object} Batch writer with methods {@link enqueue}, {@link flushNow}, and {@link pendingCount}.
 */
function createBatchWriter (userID, firstFlushDelay = 10_000, subsequentFlushDelay = 1_500, resetDelay = 5_000) {
  const pending = new Map()
  const retryMap = new Map()
  let flushTimer = null
  let batchAt = null
  let initialFlush = true

  /**
   * Clears retry counts, allowing failed writes to retry again.
   */
  function resetRetries () {
    retryMap.clear()
  }
  setInterval(resetRetries, resetDelay).unref?.()

  /**
   * Flushes all queued writes to IndexedDB in a single transaction.
   * If an error occurs, re-enqueues the writes for retry.
   */
  async function flush () {
    if (flushTimer) {
      clearTimeout(flushTimer)
      flushTimer = null
    }
    batchAt = null
    initialFlush = false
    if (pending.size === 0) return
    const snapshot = Array.from(pending.entries())
    pending.clear()
    const database = await open(userID)
    for (const [cacheKey, kvMap] of snapshot) {
      try {
        const transaction = database.transaction(cacheKey, 'readwrite')
        const store = transaction.objectStore(cacheKey)
        for (const [key, value] of kvMap.entries()) store.put({ key, value })
        await waitForTransaction(transaction)
        debug(`Flushed ${kvMap.size} entries to ${cacheKey}`)
      } catch (error) {
        debug(`Failed to flush ${cacheKey}, will retry`, error)
        for (const [k, v] of kvMap) {
          const mapKey = `${cacheKey}:${k}`
          const attempts = retryMap.get(mapKey) || 0
          if (attempts < 3) {
            retryMap.set(mapKey, attempts + 1)
            getBatchWriter(userID).enqueue({ key: cacheKey }, k, v)
          } else debug(`Max retries reached for ${mapKey}, dropping value`)
        }
      }
    }
  }

  return {
    /**
     * Enqueues a cache entry for a specific cache and key.
     * Starts the flush timer if this is the first entry in the batch.
     *
     * @param {keyof typeof caches} cache - The name of the cache (object store).
     * @param {string|number} key - The key to store in the cache.
     * @param {*} value - The value to store.
     */
    enqueue (cache, key, value) {
      const cacheKey = cache.key
      if (!pending.has(cacheKey)) pending.set(cacheKey, new Map())
      pending.get(cacheKey).set(String(key), value)
      if (!batchAt) {
        batchAt = Date.now()
        flushTimer = setTimeout(() => {
          flush().finally(() => {
            flushTimer = null
            batchAt = null
          })
        }, initialFlush ? firstFlushDelay : subsequentFlushDelay)
        flushTimer?.unref?.()
      }
    },
    /**
     * Immediately flushes all queued cache entries to IndexedDB.
     */
    async flushNow () {
      await flush()
    },
    /**
     * Drops the queued writes of the given caches (they are being reset).
     * @param {string[]} cacheKeys
     */
    discard (cacheKeys) {
      for (const cacheKey of cacheKeys) pending.delete(cacheKey)
    },
    /**
     * Returns the total number of queued cache entries across all caches.
     * @returns {number} Total pending cache entries.
     */
    pendingCount () {
      return [...pending.values()].reduce((n, m) => n + m.size, 0)
    }
  }
}

/** @type {import('simple-store-svelte').Writable<Record<number, import('./al.d.ts').Media>>} */
export let mediaCache

class Cache {
  /** @type {string} */
  cacheID = (JSON.parse(localStorage.getItem('ALviewer')) || JSON.parse(localStorage.getItem('MALviewer')))?.viewer?.data?.Viewer?.id || 'default'
  /** @type {import('svelte/store').Writable<GeneralDefaults>} */
  general
  /** @type {import('svelte/store').Writable<QueryDefaults>} */
  queries
  /** @type {import('simple-store-svelte').Writable<any>} */
  user_lists
  /** @type {import('simple-store-svelte').Writable<any>} */
  mappings
  /** @type {import('svelte/store').Writable<NotifyDefaults>} */
  notifications
  /** @type {import('svelte/store').Writable<any>} */
  history
  /** @type {Map<string, any>} */
  #pending = new Map()
  /** @type {import('svelte/store').Writable<string>} */
  status
  /** @type {AnilistClient} */
  anilistClient

  isReady
  subscribers = []

  /**
   * @type {Promise<void>}
   * A promise that resolves when the cache has been fully initialized.
   * Use this to ensure all required data is loaded and ready for use.
   */
  constructor () {
    this.isReady = this.#initialize()
  }

  /**
   * Initializes the cache by loading necessary data into memory.
   * @returns {Promise<void>}
   */
  async #initialize () {
    debug(`Loading caches with id: ${this.cacheID}...`)
    // `deep`: stores whose values are changed in place (settings, notifications, watch progress...): every update is
    // compared deeply with a copy of what was written. The other stores replace an entry with a new object when it
    // changes (updateMedia, #update, deleteEntry), so a reference check finds the changed entries without comparing
    // (or copying) the whole store: thousands of media made every update cost 150 ms to 1 s.
    const cacheTypes = [
      { key: caches.MEDIA_CACHE, writable: (data) => mediaCache = writable(data) },
      { key: caches.GENERAL, deep: true, writable: (data) => this.general = writable({ ...generalDefaults, ...deepClone(data) }) },
      { key: caches.QUERIES, writable: (data) => this.queries = writable({ ...queryDefaults, ...data }) },
      { key: caches.MAPPINGS, writable: (data) => this.mappings = writable(data) },
      { key: caches.USER_LISTS, writable: (data) => this.user_lists = writable(data) },
      { key: caches.NOTIFICATIONS, deep: true, writable: (data) => this.notifications = writable({ ...notifyDefaults, ...deepClone(data) }) },
      { key: caches.HISTORY, deep: true, writable: (data) => this.history = writable({ ...historyDefaults, ...deepClone(data) }) }
    ]

    /**
     * In-memory representation of all cache object stores.
     * Each entry maps a cache key to an object containing its stored key-value pairs.
     * This map is lazy-loaded on first access and kept in memory for fast lookups.
     *
     * @type {Map<string, Object>} - cacheKey -> { key: value }
     */
    const cacheMap = new Map()
    for (const { key } of cacheTypes) {
      try {
        let data
        try {
          data = await loadAll(this.cacheID, key)
        } catch (error) {
          console.error(`Normal load failed for ${key.key}, attempting recovery:`, error.message)
          const recovered = await recoverCache(this.cacheID, key)
          if (Object.keys(recovered).length > 0) {
            try {
              console.error(`Clearing corrupted ${key.key} and restoring ${Object.keys(recovered).length} recovered entries...`)
              await reset(this.cacheID, key)
              await putMany(this.cacheID, key, Object.entries(recovered))
              console.error(`Successfully restored ${key.key} with recovered data`)
            } catch (restoreError) {
              console.error(`Failed to restore ${key.key}, will use recovered data in-memory only:`, restoreError)
            }
          } else console.error(`No data could be recovered from ${key.key}, returning empty cache`)
          data = recovered
        }
        cacheMap.set(key.key, data)
      } catch (error) {
        console.error(`Critical error loading ${key.key}, using empty cache:`, error)
        cacheMap.set(key.key, {})
      }
    }
    this.#pruneLoaded(cacheMap)
    cacheTypes.forEach(({ key, writable }) => writable(cacheMap.get(key.key)))

    const batchWriter = getBatchWriter(this.cacheID)
    const removeKey = (key, subKey) => remove(this.cacheID, key, [subKey]).catch(error => debug(`Failed to remove ${subKey} from ${key.key}`, error))
    this.subscribers = cacheTypes.map(({ key, deep }) => {
      const store = key.key === caches.MEDIA_CACHE.key ? mediaCache : this[key.key]
      if (deep) {
        /** Copy of what was written, compared deeply with each new value. */
        const inMem = cacheMap.get(key.key) || {}
        return store.subscribe(value => {
          for (const [subKey, subValue] of Object.entries(value || {})) {
            const prevSubValue = inMem[subKey]
            if (prevSubValue !== subValue && !equal(prevSubValue, subValue)) {
              batchWriter.enqueue(key, subKey, subValue)
              inMem[subKey] = deepClone(subValue)
            }
          }
          for (const subKey of Object.keys(inMem)) {
            if (!(subKey in (value || {}))) {
              delete inMem[subKey]
              removeKey(key, subKey)
            }
          }
        })
      }
      cacheMap.delete(key.key) // the store holds the loaded data itself, no copy is kept
      /** Reference of each entry as last written (or loaded). */
      const written = new Map(Object.entries(store.value || {}))
      return store.subscribe(value => {
        for (const [subKey, subValue] of Object.entries(value || {})) {
          if (written.get(subKey) !== subValue || !written.has(subKey)) {
            batchWriter.enqueue(key, subKey, subValue)
            written.set(subKey, subValue)
          }
        }
        for (const subKey of written.keys()) {
          if (!(subKey in (value || {}))) {
            written.delete(subKey)
            removeKey(key, subKey)
          }
        }
      })
    })

    debug('Caches have successfully been loaded!')
  }

  /**
   * Startup pruning (policy in cachepolicy.js): TMDB answers of older versions (kept forever in the general and
   * history stores, now TTL entries of the mappings store), mapping and query entries expired for longer than the
   * grace period, and the least recently cached entries above the size limits. Changes are written right away.
   * Media and user lists are not pruned (cached queries point to media, lists are the offline fallback).
   * @param {Map<string, Object>} cacheMap cacheKey -> loaded { key: value }
   */
  #pruneLoaded (cacheMap) {
    const now = Date.now()
    const drop = (cache, keys) => {
      if (!keys.length) return
      const data = cacheMap.get(cache.key) || {}
      for (const key of keys) delete data[key]
      remove(this.cacheID, cache, keys).catch(error => debug(`Failed to prune ${cache.key}`, error))
      debug(`Pruned ${keys.length} entries from ${cache.key}`)
    }
    try {
      drop(caches.GENERAL, Object.keys(cacheMap.get(caches.GENERAL.key) || {}).filter(key => LEGACY_TMDB_GENERAL.test(key)))
      drop(caches.HISTORY, Object.keys(cacheMap.get(caches.HISTORY.key) || {}).filter(key => LEGACY_TMDB_HISTORY.test(key)))
      drop(caches.MAPPINGS, staleMappingKeys(cacheMap.get(caches.MAPPINGS.key), { now }))
      const queries = cacheMap.get(caches.QUERIES.key) || {}
      const rewritten = []
      for (const [name, entries] of Object.entries(queries)) {
        if (UNPRUNED_QUERIES.includes(name) || !entries || typeof entries !== 'object') continue
        const stale = staleKeys(entries, { now, limit: QUERY_LIMITS[name] ?? Infinity })
        if (!stale.length) continue
        const kept = { ...entries }
        for (const key of stale) delete kept[key]
        queries[name] = kept
        rewritten.push([name, kept])
        debug(`Pruned ${stale.length} entries from ${caches.QUERIES.key}:${name}`)
      }
      putMany(this.cacheID, caches.QUERIES, rewritten).catch(error => debug('Failed to write the pruned queries', error))
    } catch (error) {
      debug('Failed to prune the caches', error)
    }
  }

  /** Writes to the mappings store since its size was last checked. */
  #mappingWrites = 0

  /**
   * Size-limited eviction while the app runs: a query cache that grew a quarter past its limit, or the mappings store
   * every few hundred writes, is cut back to its limits (oldest entries first, see cachepolicy.js).
   * @param {keyof typeof caches} cache
   */
  #evict (cache) {
    if (cache === caches.MAPPINGS) {
      if (++this.#mappingWrites < 250) return
      this.#mappingWrites = 0
      const stale = staleMappingKeys(this.mappings.value)
      if (!stale.length) return
      this.mappings.update(current => {
        for (const key of stale) delete current[key]
        return current
      })
      debug(`Evicted ${stale.length} entries from ${cache.key}`)
      return
    }
    const limit = QUERY_LIMITS[cache.key]
    const entries = this.queries.value[cache.key]
    if (!limit || !entries || Object.keys(entries).length <= limit * 1.25) return
    const stale = staleKeys(entries, { limit })
    if (!stale.length) return
    this.queries.update(query => {
      const kept = { ...query[cache.key] }
      for (const key of stale) delete kept[key]
      query[cache.key] = kept
      return query
    })
    debug(`Evicted ${stale.length} entries from ${caches.QUERIES.key}:${cache.key}`)
  }

  /**
   * Releases all resources held by this cache and marks it as inactive.
   *
   * Unsubscribes listeners, clears pending operations and lookup maps,
   * nulls stored data to enable garbage collection, and logs its destruction.
   * After calling, this instance should not be used.
   */
  destroy () {
    this.subscribers.forEach((unsubscribe) => unsubscribe())
    this.#pending.clear()
    mediaCache = null
    this.general = null
    this.queries = null
    this.mappings = null
    this.user_lists = null
    this.notifications = null
    this.history = null
    debug(`Cache with ID ${this.cacheID} has been destroyed.`)
  }

  /**
   * Updates the cache for a specific key.
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {number|string} key The key for the specific cache entry (e.g., media ID).
   * @param {Object} data The cache object to store.
   * @warn Do not use this outside of {@link Cache}, use {@link cacheEntry} instead.
   */
  #update (cache, key, data) {
    if (cache === caches.USER_LISTS || cache === caches.MAPPINGS) {
      (cache === caches.USER_LISTS ? this.user_lists : this.mappings).update((query) => {
        query[key] = typeof data === 'function' ? data(query[key]) : data
        return query
      })
    } else {
      this.queries.update((query) => {
        const current = query[cache.key]?.[key]
        // A new object for the changed query cache: the store subscriber only writes entries whose reference changed.
        query[cache.key] = { ...(query[cache.key] || {}), [key]: typeof data === 'function' ? data(current) : data }
        return query
      })
    }
    if (cache !== caches.USER_LISTS) this.#evict(cache)
  }

  /**
   * Transfers all cached data from the current cache to a new cache ID and then purges the old cache.
   * Only keeps necessary info like settings, notifications and watch history, excluding caches like queries and user lists as they can't be used.
   * @param {string} newCacheID - The ID of the new cache to which data should be transferred.
   * @returns {Promise<void>} Resolves when the data has been successfully transferred and the old cache purged.
   */
  async abandon (newCacheID) {
    await purge(this.cacheID)
    this.cacheID = newCacheID
    for (const value of [[caches.GENERAL, this.general.value], [caches.NOTIFICATIONS, this.notifications.value], [caches.HISTORY, this.history.value]]) {
      for (const [key, keyValue] of Object.entries(value[1])) {
        await putMany(newCacheID, value[0], [[key, keyValue]])
      }
    }
  }

  /**
   * Resets all settings completely clearing the general cache.
   * See {@link generalDefaults} for all values that will be reset.
   */
  async resetSettings () {
    await reset(this.cacheID, caches.GENERAL)
    location.reload()
  }

  /**
   * Resets all watch history completely clearing the history cache.
   * See {@link historyDefaults} for all values that will be reset.
   */
  async resetHistory () {
    await reset(this.cacheID, caches.HISTORY)
    this.history.value = { ...historyDefaults }
  }

  /**
   * Resets all caches completely clearing the caches, excluding notifications.
   * To clear notifications see: {@link resetNotifications}.
   *
   * See {@link queryDefaults} for all values that will be reset.
   */
  async resetCaches () {
    const resetCaches = [caches.QUERIES, caches.MAPPINGS, caches.USER_LISTS, caches.MEDIA_CACHE]
    getBatchWriter(this.cacheID).discard(resetCaches.map(({ key }) => key))
    for (const cache of resetCaches) await reset(this.cacheID, cache)
    // TMDB answers (details, seasons, images...) are mappings entries; older versions kept them in these stores.
    await remove(this.cacheID, caches.GENERAL, Object.keys(this.general.value || {}).filter(key => LEGACY_TMDB_GENERAL.test(key)))
    await remove(this.cacheID, caches.HISTORY, Object.keys(this.history.value || {}).filter(key => LEGACY_TMDB_HISTORY.test(key)))
    location.reload()
  }

  /**
   * Resets all notifications completely clearing the notifications cache.
   * See {@link notifyDefaults} for all values that will be reset.
   */
  resetNotifications () {
    this.notifications.value = { ...notifyDefaults }
    window.dispatchEvent(new Event('notification-reset'))
  }

  /**
   * Immediately retrieves a cache entry directly from storage skipping the batch caching queue.
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key - The category to retrieve (e.g., 'lastAni').
   * @returns {Promise<any>} The cached data for the specified key, or `undefined` if it does not exist.
   */
  read (cache, key) {
    return get(this.cacheID, cache, key)
  }

  /**
   * Immediately writes a cache entry directly to storage skipping the batch caching queue, data will eventually be saved to the memory cache.
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key - The category to update (e.g., 'lastAni').
   * @param {Object} data The cache object to store.
   * @returns {Promise<void>} Resolves when the data has been successfully updated.
   */
  write (cache, key, data) {
    this.setEntry(cache, key, data)
    return set(this.cacheID, cache, key, data)
  }

  /**
   * Retrieves the cache entry for a specific key.
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key - The category to retrieve (e.g., 'lastAni').
   * @returns {any} The cached data for the specified key, or `undefined` if it does not exist.
   */
  getEntry (cache, key) {
    return (cache === caches.GENERAL ? this.general : cache === caches.NOTIFICATIONS ? this.notifications : this.history).value[key]
  }

  /**
   * Updates the cache for a specific key.
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key The category to update (e.g., 'lastAni').
   * @param {Object} data The cache object to store.
   */
  setEntry (cache, key, data) {
    (cache === caches.GENERAL ? this.general : cache === caches.NOTIFICATIONS ? this.notifications : this.history).update((query) => {
      const current = query[key]
      query[key] = typeof data === 'function' ? data(current) : data
      return query
    })
  }

  /**
   * Deletes a cache entry for a specific key.
   *
   * @param {keyof typeof caches} cache The name of the cache (object store).
   * @param {string} key The key to delete from the cache.
   * @returns {Promise<void>} Resolves when the entry has been successfully deleted.
   */
  async deleteEntry (cache, key) {
    const dataEntry = cache === caches.GENERAL ? this.general : cache === caches.NOTIFICATIONS ? this.notifications : cache === caches.HISTORY ? this.history : cache === caches.USER_LISTS ? this.user_lists : cache === caches.MAPPINGS ? this.mappings : cache === caches.MEDIA_CACHE ? mediaCache : null
    const store = dataEntry || this.queries
    store.update((query) => {
      const updated = { ...query }
      if (dataEntry) delete updated[key]
      else if (updated[cache.key]) {
        updated[cache.key] = { ...updated[cache.key] }
        delete updated[cache.key][key]
      }
      return updated
    })
    this.#pending.delete(`${cache.key}:${key}`)
    debug(`Deleted cache entry ${cache.key}:${key}`)
  }

  /**
   * Updates the media cache with the provided media entries.
   *
   * @param {Array<Object>} medias - An array of media objects to be cached. Each media object should have a unique identifier (`id`).
   * @param {Object} [fillLists] - An object containing user list data to attach to each media entry (e.g., `{ data: { MediaList: [...] } }`)
   * @param {boolean} [listsExpected] - The media come with MyAnimeList entries (`fillLists`): when the lists are unknown (request failed or too slow), the cached entries are kept instead of the empty AniList ones.
   * @returns {Promise<void>} Resolves when the media cache has been successfully updated.
   */
  async updateMedia (medias, fillLists, listsExpected = fillLists !== undefined && fillLists !== null) {
    if (!medias || !medias.length) return
    const listsKnown = Array.isArray(fillLists?.data?.MediaList)
    const filledMedias = listsKnown ? fillEntries(medias, fillLists) : medias /* attaches any alternative authorization userList information to the anilist media for tracking. */
    const mediaMap = new Map(filledMedias.filter(Boolean).map(m => [m.id, m]))
    mediaCache.update(current => {
      for (const [id, media] of mediaMap.entries()) {
        const cached = current[id] || {}
        // TMDB shows and movies can share an id ("tmdb-<id>", kept for Watch Together and iOS): never mix their fields.
        const existing = (media.isTmdb && cached.isTmdb && media.format && cached.format && (media.format === 'MOVIE') !== (cached.format === 'MOVIE')) ? {} : cached
        const updated = {
          ...existing,
          ...media,
          logo: media.logo || existing.logo,
          bannerImage: media.bannerImage || existing.bannerImage,
          airingSchedule: media.airingSchedule || existing.airingSchedule
        }
        if (listsExpected && !listsKnown && 'mediaListEntry' in existing) updated.mediaListEntry = existing.mediaListEntry
        // Unchanged media keep their object: the store subscriber only writes entries whose reference changed.
        if (media === cached || equal(updated, cached)) continue
        current[id] = updated
      }
      return current
    })
  }

  /**
   * MyAnimeList lists to attach to an answer: waits for them at most {@link FILL_TIMEOUT}, so AniList sections never
   * hang on MyAnimeList. When they arrive later, the list entries of the media are filled then.
   * @param {any} fillLists promise of the MyAnimeList lists
   * @param {Array<Object>} medias
   * @returns {Promise<Object | null>} the lists, null when they are unknown
   */
  async #listsToFill (fillLists, medias) {
    const lists = Promise.resolve(fillLists).catch(error => {
      debug('MyAnimeList lists unavailable, list entries are not filled', error)
      return null
    })
    let timer
    const result = await Promise.race([lists, new Promise(resolve => { timer = setTimeout(resolve, FILL_TIMEOUT, TIMED_OUT) })])
    clearTimeout(timer)
    if (result !== TIMED_OUT) return result
    debug('MyAnimeList lists are slow, list entries will be filled once they arrive')
    lists.then(late => {
      if (!Array.isArray(late?.data?.MediaList)) return
      const filled = fillEntries(medias.filter(Boolean).map(({ id, idMal }) => ({ id, idMal })), late)
      mediaCache.update(current => {
        for (const media of filled) {
          if (media.mediaListEntry && current[media.id]) current[media.id] = { ...current[media.id], mediaListEntry: media.mediaListEntry }
        }
        return current
      })
    })
    return null
  }

  /**
   * Returns media for the given ID, fetching it if missing.
   *
   * @param {number | string | null} id
   * @returns {Promise<Object | null>}
   */
  async requestMedia (id) {
    if (!id || typeof id === 'string') return null
    const media = mediaCache.value[id]
    if (media) return media
    if (!this.anilistClient) {
      const { anilistClient } = await import('@/modules/anilist.js')
      this.anilistClient = anilistClient
    }
    return this.anilistClient.requestMediaID(id)
  }

  /**
   * Returns cached media for the given ID, no attempt is made to fetch the media if it's not found.
   *
   * @param {number | string | null} id
   * @returns {Object | null}
   */
  getMedia (id) {
    if (!id) return null
    return mediaCache.value[id] ?? {}
  }

  /**
   * Retrieves a cached entry by its key, optionally ignoring the expiration time.
   *
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key - The unique key identifying the cached entry.
   * @param {boolean} [ignoreExpiry=false] - If true, the entry will be returned even if it has expired, defaults to `false`; meaning expired entries will not be returned.
   * @returns {Promise<Object|null>} The cached entry if found and valid; otherwise, `null`.
   */
  cachedEntry (cache, key, ignoreExpiry) {
    if (this.#pending.has(`${cache.key}:${key}`) && !ignoreExpiry) {
      debug(`Found pending query ${cache.key} for ${key}`)
      return this.#pending.get(`${cache.key}:${key}`)
    } else if (cache !== caches.MAPPINGS) {
      const cachedEntry = cache === caches.USER_LISTS ? this.user_lists.value[key] : (this.queries.value[cache.key] || {})[key]
      if (cachedEntry && cachedEntry.data && ((Date.now() < cachedEntry.expiry) || ignoreExpiry)) {
        debug(`Found cached ${cache.key} for ${key}`)
        const data = deepClone(cachedEntry.data)
        if (cache !== caches.RECOMMENDATIONS || this.general.value.settings.queryComplexity === 'Complex') { /* Remap media id's to their respective media in the cache */
          if (data.data?.Page?.media) data.data.Page.media = data.data.Page.media.map(mediaId => mediaCache.value[mediaId])
          if (data.data?.Media) data.data.Media = mediaCache.value[data.data.Media]
          if (data.data?.MediaListCollection && !key?.includes('token')) data.data.MediaListCollection.lists = (data.data.MediaListCollection.lists || []).map(list => ({ ...list, entries: list.entries.map(entry => ({ ...entry, media: mediaCache.value[entry.media] })) }))
        }
        return Promise.resolve(data)
      }
      return null
    } else {
      const cachedEntry = this.mappings.value[key]
      if (cachedEntry && cachedEntry.data && ((Date.now() < cachedEntry.expiry) || ignoreExpiry)) {
        return Promise.resolve(deepClone(cachedEntry.data))
      }
      return null
    }
  }

  /**
   * Caches an entry with the specified key, variables, data, and expiry time.
   * Only one instance of the function will be run, subsequent identical calls will return the initial call.
   *
   * @param {keyof typeof caches} cache - The name of the cache (object store).
   * @param {string} key - The unique key to identify the cached entry.
   * @param {Object} [vars] - The variables associated with the cached data if applicable, this can include filters, query parameters, or context-specific data.
   * @param {Object} data - The data to be cached, this is the primary content to store for the key. Preferably this should be a promise as it will be handled before caching.
   * @param {number | ((res: any) => number)} expiry - The expiration timestamp for the cache entry in milliseconds since the epoch, once the current time exceeds this value the entry is considered expired. A function gets the answer and returns the timestamp (TTL depending on the data, see cachepolicy.js); a timestamp that is not in the future means the answer is not cached.
   * @returns {Promise<Object>} A promise that resolves when the caching operation is complete.
   *
   */
  async cacheEntry (cache, key, vars, data, expiry) {
    if (this.#pending.has(`${cache.key}:${key}`)) {
      debug(`Found pending query ${cache.key} for ${key} during cache update...`)
      return this.#pending.get(`${cache.key}:${key}`)
    }
    const { fillLists, ...variables } = vars || {}
    const listsExpected = fillLists !== undefined && fillLists !== null
    const promiseData = (async () => {
      let res
      try {
        res = await data
      } catch (error) {
        debug('Detected an error in the promised data, returning cached data if available.', error)
        return this.cachedEntry(cache, key, true)
      }
      const cacheRes = deepClone(res)
      if (!this.status) {
        const { status } = await import('@/modules/networking.js')
        this.status = status
      }
      if (this.status.value.match(/offline/i) || (!variables?.mappings && (!res || ((res.errors?.length > 0) && !res.errors?.[0]?.title?.match(/record not found/i))))) return this.cachedEntry(cache, key, true) || res
      if (cache !== caches.RECOMMENDATIONS || this.general.value.settings.queryComplexity === 'Complex') {
        if (res?.data?.Page?.media) {
          cacheRes.data.Page.media = cacheRes.data.Page.media.map(media => media.id)
          await this.updateMedia(res.data.Page.media, listsExpected ? await this.#listsToFill(fillLists, res.data.Page.media) : undefined, listsExpected)
        } else if (res?.data?.Media) {
          cacheRes.data.Media = cacheRes.data.Media.id
          await this.updateMedia([res.data.Media], listsExpected ? await this.#listsToFill(fillLists, [res.data.Media]) : undefined, listsExpected)
        } else if (res?.data?.MediaListCollection && !variables.token) {
          const lists = res.data.MediaListCollection.lists || []
          cacheRes.data.MediaListCollection = { ...res.data.MediaListCollection, lists: lists.map(list => ({ ...list, entries: list.entries.map(entry => ({ ...entry, media: entry.media.id })) })) }
          await this.updateMedia(lists.flatMap(list => list.entries.map(entry => entry.media)))
        }
      }
      const expiresAt = typeof expiry === 'function' ? expiry(res) : expiry
      if (typeof expiry === 'function' && !(expiresAt > Date.now())) return res
      this.#update(cache, key, { data: cacheRes, expiry: expiresAt, cachedAt: Date.now() })
      return res
    })()
    this.#pending.set(`${cache.key}:${key}`, promiseData)
    promiseData.finally(() => this.#pending.delete(`${cache.key}:${key}`))
    return promiseData
  }
}

export const cache = new Cache()

/**
 * Ensures that the cache system has finished initializing before use.
 * THIS MUST BE CALLED BEFORE ACCESSING {@link cache}.
 *
 * @returns {Promise<void>} A promise that resolves once the cache is fully initialized and ready to use.
 */
export function cacheReady () {
  return cache.isReady
}

/**
 * Mapping from MyAnimeList status values to AniList status values.
 * Keys are MAL statuses, values are AniList equivalents.
 */
const MAL_TO_ANILIST = {
  watching: 'CURRENT',
  rewatching: 'REPEATING', /* rewatching is determined by is_rewatching boolean (no individual list) */
  plan_to_watch: 'PLANNING',
  completed: 'COMPLETED',
  dropped: 'DROPPED',
  on_hold: 'PAUSED'
}

/**
 * Mapping from AniList status values to MyAnimeList status values.
 * Generated automatically from {@link MAL_TO_ANILIST}, with 'REPEATING' mapped to 'watching'.
 */
const ANILIST_TO_MAL = Object.fromEntries(Object.entries(MAL_TO_ANILIST).map(([mal, ani]) => [ani, mal === 'rewatching' ? 'watching' : mal]))

/**
 * Maps anime status between MyAnimeList and AniList (bidirectional).
 *
 * @param {string} status - The status to map.
 * @returns {string|undefined} The mapped status, or undefined if not recognized.
 */
export function mapStatus (status) {
  return MAL_TO_ANILIST[status] ?? ANILIST_TO_MAL[status]
}

/**
 * Fills the queried AniList media entries with additional user list data from alternate authorizations (e.g., MyAnimeList).
 *
 * This function attaches user-specific data to each AniList media entry, such as progress, status, start/completion dates,
 * and custom list information, by matching the media's ID with entries from the provided user lists.
 *
 * @param {Array<Object>} medias - An array of AniList media objects to be filled with user list data.
 * @param {Object} userLists - The user list data, containing entries from alternate authorizations like MyAnimeList.
 * @param {Object} userLists.data - The user list data structure containing a list of media entries.
 * @param {Array<Object>} userLists.data.MediaList - An array of media list entries from alternate authorizations.
 * @returns {Array<Object>} The updated array of AniList media objects with attached user list data.
 */
function fillEntries (medias, userLists) {
  debug(`Filling MyAnimeList entry data for ${medias?.length} media(s)`)
  const malEntries = userLists?.data?.MediaList || []
  const malMap = new Map(malEntries.map(({ node }) => [node.id, node.my_list_status]))
  return medias.map(media => {
    const status = malMap.get(media.idMal)
    if (!status) return media
    const mediaListEntry = malListEntry(media.id, status)
    // The answer returned to the caller gets the entry too (as before), but a cached media object is never changed in
    // place: the media cache only saves entries whose reference changed (see updateMedia).
    if (mediaCache?.value?.[media.id] !== media) media.mediaListEntry = mediaListEntry
    return { ...media, mediaListEntry }
  })
}

/**
 * AniList-shaped list entry of a MyAnimeList list status (my_list_status). Start and finish dates are calendar days
 * ("2024-05-10"), read as written: new Date() made them a day earlier west of UTC, and that date was sent back to
 * MyAnimeList on the next update.
 * @param {number} mediaId AniList media id
 * @param {any} status MyAnimeList my_list_status
 * @returns {any} null when there is no status
 */
export function malListEntry (mediaId, status) {
  if (!status) return null
  const rewatched = status.num_times_rewatched ?? status.number_times_rewatched
  return {
    id: mediaId,
    progress: status.num_episodes_watched,
    repeat: Number.isInteger(rewatched) ? rewatched : undefined, // only sent back to MyAnimeList when known
    status: mapStatus(status.is_rewatching ? 'rewatching' : status.status),
    customLists: [],
    score: status.score,
    startedAt: parseDateOnly(status.start_date) || undefined,
    completedAt: parseDateOnly(status.finish_date) || undefined
  }
}
