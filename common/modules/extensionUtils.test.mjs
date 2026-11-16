// Extensions / Stremio pure helpers. Run with: node common/modules/extensionUtils.test.mjs
import assert from 'node:assert/strict'
import { shortHash, installKey, LruCache, CatalogPager, pickStremioSubtitle, subtitleLanguageCode, animeMetaId } from './extensionUtils.js'

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

await test('shortHash: first 4 bytes of SHA-256, hex (as on iOS)', async () => {
  assert.equal(await shortHash('abc'), 'ba7816bf')
  assert.equal(await shortHash(''), 'e3b0c442')
  assert.notEqual(await shortHash('https://a.example/x'), await shortHash('https://a.example/y'))
})

await test('installKey: same scheme as iOS', () => {
  const same = (a, b) => a === b
  const torrentio = { stremioId: 'com.stremio.torrentio.addon', sourceName: 'Torrentio', version: '0.0.15' }
  const installed = [
    ['Torrentio-0.0.15', { url: 'https://torrentio.strem.fun/providers=yts/manifest.json', manifest: torrentio }],
    ['AnimeWorld-1.0.0', { url: 'https://example.com/aw.json', manifest: { sourceName: 'AnimeWorld', version: '1.0.0' } }]
  ]
  // New extension: name-version, like before.
  assert.equal(installKey({ type: 'sora', name: 'Other', version: '2.1', url: 'https://o.example/m.json', addressHash: 'h' }, installed, same), 'Other-2.1')
  assert.equal(installKey({ type: 'sora', name: 'NoVersion', version: undefined, url: 'https://n.example/m.json', addressHash: 'h' }, installed, same), 'NoVersion-undefined')
  // Same address: that entry is updated (Stremio and Sora).
  assert.equal(installKey({ type: 'stremio', name: 'Torrentio', version: '0.0.16', url: 'https://torrentio.strem.fun/providers=yts/manifest.json', addressHash: 'h' }, installed, same), 'Torrentio-0.0.15')
  // A Sora module with the same name (new version, new address) updates its entry instead of adding a duplicate.
  assert.equal(installKey({ type: 'sora', name: 'AnimeWorld', version: '1.1.0', url: 'https://mirror.example/aw.json', addressHash: 'h' }, installed, same), 'AnimeWorld-1.0.0')
  // A second configuration of one Stremio addon: same name and version, so the key gets the address hash.
  assert.equal(installKey({ type: 'stremio', name: 'Torrentio', version: '0.0.15', url: 'https://torrentio.strem.fun/providers=eztv/manifest.json', addressHash: '1a2b3c4d' }, installed, same), 'Torrentio-0.0.15#1a2b3c4d')
  const more = [...installed, ['Torrentio-0.0.15#1a2b3c4d', { url: 'https://x/manifest.json', manifest: torrentio }]]
  assert.equal(installKey({ type: 'stremio', name: 'Torrentio', version: '0.0.15', url: 'https://y/manifest.json', addressHash: '1a2b3c4d' }, more, same), 'Torrentio-0.0.15#1a2b3c4d-2')
  // A Stremio addon never takes over a Sora module of the same name.
  assert.equal(installKey({ type: 'stremio', name: 'AnimeWorld', version: '9', url: 'https://aw-addon.example/manifest.json', addressHash: 'h' }, installed, same), 'AnimeWorld-9')
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
