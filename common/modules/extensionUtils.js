import { preferredLanguage, normalizeLanguage, languageName } from './onlinesubs/core.js'

// Pure helpers of the extensions (extension.js) and Stremio addons (stremio.js), unit tested by extensionUtils.test.mjs.

/** Short stable hash of a string (FNV-1a 32 bits, base 36). */
export function hashString (text) {
  let hash = 0x811c9dc5
  const value = String(text ?? '')
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return (hash >>> 0).toString(36)
}

/**
 * Settings key of a newly installed extension. The version is not part of it (an update keeps the same key, so the
 * default / starred choice survives), and the address is: two configurations of the same Stremio addon (same id,
 * different configured URL) or two copies of a module from different places are two extensions.
 * @param {{ type?: string, id?: string, name?: string, url: string }} extension
 */
export function extensionKey ({ type, id, name, url }) {
  const label = String((type === 'stremio' ? id : name) || 'extension').replace(/\s+/g, ' ').trim()
  return `${type === 'stremio' ? 'stremio-' : ''}${label}-${hashString(url)}`
}

/**
 * Small LRU map: reading an entry makes it the most recent one, and the oldest entries go once there are more than
 * `max`. Used for the Stremio request cache, which used to keep every catalog / meta response for the whole session.
 */
export class LruCache {
  constructor (max = 100) {
    this.max = max
    this.map = new Map()
  }

  get (key) {
    if (!this.map.has(key)) return undefined
    const value = this.map.get(key)
    this.map.delete(key)
    this.map.set(key, value)
    return value
  }

  set (key, value) {
    this.map.delete(key)
    this.map.set(key, value)
    while (this.map.size > this.max) this.map.delete(this.map.keys().next().value)
    return this
  }

  has (key) {
    return this.map.has(key)
  }

  /** Reads an entry without making it the most recent one. */
  peek (key) {
    return this.map.get(key)
  }

  delete (key) {
    return this.map.delete(key)
  }

  clear () {
    this.map.clear()
  }

  get size () {
    return this.map.size
  }
}

/**
 * Fixed-size pages over a Stremio catalog paged with "skip".
 *
 * Stremio clients ask for the next items with skip = number of items received so far, and addons decide their own
 * batch size (some turn skip into their own page number). So the cursor is the real count received, never
 * (page - 1) * perPage, and the items beyond one page are kept for the next page instead of being dropped.
 * A batch made only of items already seen ends the catalog (addons that ignore skip would repeat forever).
 */
export class CatalogPager {
  /**
   * @param {(skip: number) => Promise<any[]>} fetchBatch
   * @param {{ canSkip?: boolean, maxRequests?: number, idOf?: (meta: any) => string }} [options]
   */
  constructor (fetchBatch, { canSkip = true, maxRequests = 6, idOf = (meta) => `${meta?.type}:${meta?.id}` } = {}) {
    this.fetchBatch = fetchBatch
    this.canSkip = canSkip
    this.maxRequests = maxRequests
    this.idOf = idOf
    this.chain = Promise.resolve()
    this.reset(null)
  }

  reset (perPage) {
    this.perPage = perPage
    this.cursor = 0
    this.buffer = []
    this.pages = []
    this.ended = false
    this.seen = new Set()
  }

  /**
   * Page `number` (1-based) of `perPage` items. Page 1 starts over (fresh list); later pages load in order.
   * @returns {Promise<{ items: any[], hasNextPage: boolean }>}
   */
  page (number, perPage) {
    const run = this.chain.then(() => this._load(number, perPage))
    this.chain = run.catch(() => {})
    return run
  }

  async _load (number, perPage) {
    if (number <= 1 || perPage !== this.perPage) this.reset(perPage)
    while (this.pages.length < number) {
      const last = this.pages[this.pages.length - 1]
      if (last && !last.hasNextPage) return { items: [], hasNextPage: false }
      this.pages.push(await this._next(perPage))
    }
    return this.pages[number - 1]
  }

  async _next (perPage) {
    for (let requests = 0; this.buffer.length < perPage && !this.ended && requests < this.maxRequests; requests++) {
      const batch = await this.fetchBatch(this.cursor)
      if (!Array.isArray(batch) || !batch.length) {
        this.ended = true
        break
      }
      this.cursor += batch.length
      const fresh = batch.filter(meta => {
        const id = this.idOf(meta)
        if (this.seen.has(id)) return false
        this.seen.add(id)
        return true
      })
      if (!fresh.length || !this.canSkip) this.ended = true
      this.buffer.push(...fresh)
    }
    const items = this.buffer.splice(0, perPage)
    return { items, hasNextPage: this.buffer.length > 0 || !this.ended }
  }
}

// ISO 639-2 (bibliographic and terminology) codes found in subtitle lists -> ISO 639-1.
const ISO_639_2 = Object.fromEntries((
  'eng:en jpn:ja chi:zh zho:zh por:pt pob:pt spa:es spl:es lat:es ger:de deu:de pol:pl cze:cs ces:cs dan:da gre:el ' +
  'ell:el fin:fi fre:fr fra:fr hun:hu ita:it kor:ko dut:nl nld:nl nor:no nob:no nno:no rum:ro ron:ro rus:ru slo:sk ' +
  'slk:sk swe:sv ara:ar ind:id idn:id heb:he tur:tr vie:vi tha:th hin:hi ukr:uk bul:bg hrv:hr srp:sr slv:sl est:et ' +
  'lav:lv lit:lt may:ms msa:ms per:fa fas:fa cat:ca baq:eu eus:eu glg:gl fil:tl tgl:tl'
).split(' ').map(pair => pair.split(':')))

/** ISO 639-1 code of a subtitle language tag ("fre", "fr-FR", "pt-BR", "eng"); '' when unknown. */
export function subtitleLanguageCode (lang) {
  const primary = String(lang || '').trim().toLowerCase().split(/[-_\s]/)[0]
  if (ISO_639_2[primary]) return ISO_639_2[primary]
  return /^[a-z]{2}$/.test(primary) ? normalizeLanguage(primary) : ''
}

/**
 * Subtitle URL of a Stremio stream to load with the video: the one in the Preferred Subtitle Language setting, else
 * none. Loading another language (it used to take French, else the first one) also stopped the automatic online
 * subtitles, which only run when the video has no subtitle track. Setting None: no subtitle.
 * @param {{ url?: string, lang?: string, label?: string }[]} subtitles
 * @param {string} setting settings.subtitleLanguage ('eng', 'fre'... or '')
 */
export function pickStremioSubtitle (subtitles, setting) {
  if (!setting || !Array.isArray(subtitles)) return null
  const wanted = preferredLanguage(setting)
  const name = languageName(wanted).toLowerCase()
  const named = (text) => String(text || '').trim().toLowerCase().startsWith(name)
  const match = subtitles.find(sub => typeof sub?.url === 'string' && sub.url &&
    (subtitleLanguageCode(sub.lang) === wanted || named(sub.lang) || named(sub.label)))
  return match?.url || null
}

/** Anime ids of Stremio anime addons: "kitsu:1", "mal:21", "anilist:20" (an episode suffix ":5" is ignored). */
export function animeMetaId (id) {
  const match = String(id || '').match(/^(kitsu|mal|anilist):(\d+)(?::|$)/i)
  return match ? { source: match[1].toLowerCase(), id: Number(match[2]) } : null
}
