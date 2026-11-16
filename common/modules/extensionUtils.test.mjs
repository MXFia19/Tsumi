// Extensions / Stremio pure helpers. Run with: node common/modules/extensionUtils.test.mjs
import assert from 'node:assert/strict'
import { hashString, extensionKey, LruCache, CatalogPager, pickStremioSubtitle, subtitleLanguageCode, animeMetaId } from './extensionUtils.js'

let passed = 0
let failed = 0
async function test (name, fn) {
  try {
    await fn()
    passed++
    console.log(`ok - ${name}`)
  } catch (error) {
    failed++
    console.error(`FAIL - ${name}\n${error?.stack || error}`)
  }
}

await test('hashString is stable and short', () => {
  assert.equal(hashString('abc'), hashString('abc'))
  assert.notEqual(hashString('https://a.example/x/manifest.json'), hashString('https://a.example/y/manifest.json'))
  assert.match(hashString(''), /^[0-9a-z]{1,7}$/)
})

await test('extensionKey: same addon, two configurations', () => {
  const a = extensionKey({ type: 'stremio', id: 'com.stremio.torrentio.addon', url: 'https://torrentio.strem.fun/providers=yts' })
  const b = extensionKey({ type: 'stremio', id: 'com.stremio.torrentio.addon', url: 'https://torrentio.strem.fun/providers=eztv' })
  assert.notEqual(a, b)
  assert.ok(a.startsWith('stremio-com.stremio.torrentio.addon-'))
  assert.ok(!a.includes('providers'), 'the key never contains the configured URL')
  // Sora modules: no version in the key, so an update keeps it.
  const sora = extensionKey({ name: 'AnimeWorld', url: 'https://example.com/aw.json' })
  assert.equal(sora, extensionKey({ name: 'AnimeWorld', url: 'https://example.com/aw.json' }))
  assert.ok(sora.startsWith('AnimeWorld-'))
})

await test('LruCache evicts the least recently used', () => {
  const cache = new LruCache(2)
  cache.set('a', 1).set('b', 2)
  assert.equal(cache.get('a'), 1) // a is now the most recent
  cache.set('c', 3)
  assert.equal(cache.has('b'), false)
  assert.equal(cache.get('a'), 1)
  assert.equal(cache.get('c'), 3)
  assert.equal(cache.size, 2)
  cache.delete('a')
  assert.equal(cache.size, 1)
})

// Fake addons over a catalog of `total` items (ids 0..total-1).
const metas = (from, to) => Array.from({ length: Math.max(0, to - from) }, (_, i) => ({ type: 'movie', id: `tt${from + i}` }))
const pagedAddon = (total, pageSize) => {
  const calls = []
  // Maps skip to its own page number, like many addons: page = floor(skip / pageSize).
  const fetchBatch = async (skip) => {
    calls.push(skip)
    const page = Math.floor(skip / pageSize)
    return metas(page * pageSize, Math.min(total, (page + 1) * pageSize))
  }
  return { fetchBatch, calls }
}
const ids = (page) => page.items.map(meta => Number(meta.id.slice(2)))

await test('CatalogPager: addon pages of 60, app pages of 50, nothing skipped or repeated', async () => {
  const addon = pagedAddon(200, 60)
  const pager = new CatalogPager(addon.fetchBatch)
  const seen = []
  let page
  for (let n = 1; n <= 5; n++) {
    page = await pager.page(n, 50)
    seen.push(...ids(page))
  }
  assert.deepEqual(seen, Array.from({ length: 200 }, (_, i) => i))
  assert.equal(page.hasNextPage, false)
  assert.deepEqual(addon.calls, [0, 60, 120, 180, 200], 'skip is the real number of items received')
})

await test('CatalogPager: addon batches of 100 honoring skip', async () => {
  const calls = []
  const pager = new CatalogPager(async (skip) => { calls.push(skip); return metas(skip, Math.min(130, skip + 100)) })
  assert.deepEqual(ids(await pager.page(1, 50)), Array.from({ length: 50 }, (_, i) => i))
  const second = await pager.page(2, 50)
  assert.deepEqual(ids(second), Array.from({ length: 50 }, (_, i) => 50 + i))
  assert.equal(second.hasNextPage, true)
  const third = await pager.page(3, 50)
  assert.deepEqual(ids(third), Array.from({ length: 30 }, (_, i) => 100 + i))
  assert.equal(third.hasNextPage, false)
  assert.deepEqual(calls, [0, 100, 130])
})

await test('CatalogPager: page 1 starts over, pages can be skipped to', async () => {
  const addon = pagedAddon(300, 100)
  const pager = new CatalogPager(addon.fetchBatch)
  assert.deepEqual(ids(await pager.page(3, 50)).slice(0, 2), [100, 101])
  assert.deepEqual(ids(await pager.page(1, 50)).slice(0, 2), [0, 1])
  assert.deepEqual(ids(await pager.page(2, 50)).slice(0, 2), [50, 51])
})

await test('CatalogPager: addon ignoring skip ends instead of repeating', async () => {
  let calls = 0
  const pager = new CatalogPager(async () => { calls++; return metas(0, 30) })
  const first = await pager.page(1, 50)
  assert.equal(first.items.length, 30)
  assert.equal(first.hasNextPage, false)
  assert.deepEqual((await pager.page(2, 50)).items, [])
  assert.equal(calls, 2)
})

await test('CatalogPager: catalog without skip support loads one batch', async () => {
  let calls = 0
  const pager = new CatalogPager(async () => { calls++; return metas(0, 80) }, { canSkip: false })
  const first = await pager.page(1, 50)
  assert.equal(first.items.length, 50)
  assert.equal(first.hasNextPage, true, 'the 30 items left are shown on page 2')
  const second = await pager.page(2, 50)
  assert.equal(second.items.length, 30)
  assert.equal(second.hasNextPage, false)
  assert.equal(calls, 1)
})

await test('CatalogPager: an error keeps what was received', async () => {
  let fail = true
  const pager = new CatalogPager(async (skip) => {
    if (skip === 40 && fail) { fail = false; throw new Error('HTTP 500') }
    return metas(skip, Math.min(100, skip + 40))
  })
  await assert.rejects(pager.page(1, 50), /HTTP 500/)
  const retry = await pager.page(1, 50)
  assert.deepEqual(ids(retry), Array.from({ length: 50 }, (_, i) => i))
})

await test('subtitleLanguageCode', () => {
  assert.equal(subtitleLanguageCode('fre'), 'fr')
  assert.equal(subtitleLanguageCode('fra'), 'fr')
  assert.equal(subtitleLanguageCode('pt-BR'), 'pt')
  assert.equal(subtitleLanguageCode('eng'), 'en')
  assert.equal(subtitleLanguageCode('nb'), 'no')
  assert.equal(subtitleLanguageCode('English'), '')
  assert.equal(subtitleLanguageCode(''), '')
})

await test('pickStremioSubtitle follows the Preferred Subtitle Language', () => {
  const subs = [
    { url: 'https://s/fr.srt', lang: 'fre' },
    { url: 'https://s/en.srt', lang: 'eng' },
    { url: 'https://s/es.srt', lang: 'Spanish' }
  ]
  assert.equal(pickStremioSubtitle(subs, 'eng'), 'https://s/en.srt')
  assert.equal(pickStremioSubtitle(subs, 'fre'), 'https://s/fr.srt')
  assert.equal(pickStremioSubtitle(subs, 'spa'), 'https://s/es.srt', 'language names work too')
  assert.equal(pickStremioSubtitle(subs, 'lat'), 'https://s/es.srt')
  // Not available in the wanted language: no subtitle, so the automatic online subtitles can add one.
  assert.equal(pickStremioSubtitle(subs, 'ger'), null)
  assert.equal(pickStremioSubtitle(subs, ''), null, 'None')
  assert.equal(pickStremioSubtitle([{ lang: 'eng' }], 'eng'), null, 'no URL')
  assert.equal(pickStremioSubtitle(undefined, 'eng'), null)
})

await test('animeMetaId', () => {
  assert.deepEqual(animeMetaId('kitsu:12'), { source: 'kitsu', id: 12 })
  assert.deepEqual(animeMetaId('mal:21:5'), { source: 'mal', id: 21 })
  assert.deepEqual(animeMetaId('AniList:20'), { source: 'anilist', id: 20 })
  assert.equal(animeMetaId('tt0944947'), null)
  assert.equal(animeMetaId('kitsu:abc'), null)
  assert.equal(animeMetaId(undefined), null)
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
