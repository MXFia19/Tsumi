import { join, dirname } from 'node:path'
import { mkdirSync, readFileSync, unlinkSync, existsSync, openSync, writeSync, fsyncSync, closeSync, renameSync, rmSync } from 'node:fs'

class Store {
  /**
   * @param {string} path
   * @param {string} fileName
   * @param {{}} defaults
   */
  constructor (path, fileName, defaults) {
    this.path = join(path, fileName)
    this.data = parseDataFile(this.path, defaults || {})
  }

  /**
   * @param {string} key
   */
  get (key) {
    return this.data[key]
  }

  /**
   * @param {string} key
   * @param {string} val
   */
  set (key, val) {
    this.data[key] = val
    writeAtomic(this.path, JSON.stringify(this.data))
  }

  /**
   * Resets the store to its default values.
   */
  reset () {
    this.data = {}
    writeAtomic(this.path, JSON.stringify(this.data))
  }

  /**
   * Deletes the JSON file completely.
   */
  delete () {
    if (existsSync(this.path)) unlinkSync(this.path)
  }
}

/**
 * Replaces the file without ever leaving it half written: it is rewritten on every window move or resize, and a crash
 * or power loss during a plain write would leave it empty (back to the defaults: crash counter, window state, ANGLE).
 * The text goes to a temporary file, flushed to disk, then renamed over the old one (like downloads.json).
 * A failed write (disk full, file locked) is logged: the store keeps the value in memory and the next write tries again.
 * @param {string} path
 * @param {string} text
 */
export function writeAtomic (path, text) {
  const temp = `${path}.tmp`
  try {
    const fd = openSync(temp, 'w')
    try {
      writeSync(fd, text)
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    renameSync(temp, path)
  } catch (error) {
    console.warn(`Could not save ${path}: ${error?.code || error?.message || error}`)
    try {
      rmSync(temp, { force: true })
    } catch {}
  }
}

/**
 * @param {import("fs").PathOrFileDescriptor} filePath
 * @param {any} defaults
 */
function parseDataFile (filePath, defaults) {
  try {
    if (!existsSync(dirname(filePath))) mkdirSync(dirname(filePath), { recursive: true })
    return { ...defaults || {}, ...JSON.parse(readFileSync(filePath).toString()) }
  } catch (error) {
    return defaults || {}
  }
}

export default Store
