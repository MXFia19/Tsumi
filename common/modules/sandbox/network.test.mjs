// Network rules of the extensions, pure logic. Run with: node common/modules/sandbox/network.test.mjs
import assert from 'node:assert/strict'
import { hostKind, isLocalHost, isLocalUrl, checkModuleUrl, maskUrl, scriptUrlCandidates, checkManifestUrl, readCapped, moduleDomains } from './network.js'
import { installDom } from './dom.js'

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

const host = (url) => new URL(url).hostname

await test('hostKind: loopback', () => {
  for (const url of ['http://localhost/', 'http://LOCALHOST./', 'http://app.localhost/', 'http://127.0.0.1/', 'http://127.8.9.10:8080/', 'http://0.0.0.0/', 'http://[::1]/', 'http://[::]/']) {
    assert.equal(hostKind(host(url)), 'loopback', url)
  }
  // The URL parser normalizes numeric IPv4 forms: they cannot hide a loopback address.
  for (const url of ['http://2130706433/', 'http://0x7f000001/', 'http://0177.0.0.1/', 'http://127.1/']) {
    assert.equal(hostKind(host(url)), 'loopback', url)
  }
  assert.equal(hostKind(host('http://[::ffff:127.0.0.1]/')), 'loopback')
})

await test('hostKind: private and link-local', () => {
  for (const url of ['http://10.0.0.1/', 'http://172.16.5.4/', 'http://172.31.255.255/', 'http://192.168.1.1/', 'http://100.64.0.1/', 'http://[fd00::1]/', 'http://[fc12:3456::1]/', 'http://router/', 'http://nas.local/', 'http://box.lan/', 'http://printer.home.arpa/', 'http://svc.internal/', 'http://224.0.0.1/', 'http://255.255.255.255/']) {
    assert.equal(hostKind(host(url)), 'private', url)
  }
  for (const url of ['http://169.254.169.254/', 'http://[fe80::1]/', 'http://[::ffff:169.254.1.1]/']) {
    assert.equal(hostKind(host(url)), 'link-local', url)
  }
})

await test('hostKind: public', () => {
  for (const url of ['https://example.com/', 'https://api.ani.zip/', 'http://8.8.8.8/', 'http://172.32.0.1/', 'http://172.15.0.1/', 'http://192.169.0.1/', 'http://100.128.0.1/', 'http://[2606:4700::1111]/', 'http://[::ffff:8.8.8.8]/', 'https://xn--e1afmkfd.xn--p1ai/']) {
    assert.equal(hostKind(host(url)), 'public', url)
  }
  assert.equal(isLocalHost('example.org'), false)
  assert.equal(isLocalUrl('http://192.168.0.2:8080/manifest.json'), true)
  assert.equal(isLocalUrl('not a url'), false)
})

await test('checkModuleUrl: schemes and local hosts', () => {
  assert.equal(checkModuleUrl('https://example.com/a?b=1').href, 'https://example.com/a?b=1')
  assert.throws(() => checkModuleUrl('file:///C:/Windows/win.ini'), /only use http\(s\), not file/)
  assert.throws(() => checkModuleUrl('data:text/plain,hi'), /not data/)
  assert.throws(() => checkModuleUrl('ftp://example.com/'), /not ftp/)
  assert.throws(() => checkModuleUrl('/relative'), /invalid URL/)
  assert.throws(() => checkModuleUrl('http://127.0.0.1:4123/fetch'), /local network address \(127\.0\.0\.1\)/)
  assert.throws(() => checkModuleUrl('http://192.168.1.1/admin'), /local network/)
  assert.throws(() => checkModuleUrl('http://169.254.169.254/latest/meta-data'), /local network/)
  // A module served from the local network (development) may call it.
  assert.equal(checkModuleUrl('http://192.168.1.10:3000/api', { allowLocal: true }).host, '192.168.1.10:3000')
  assert.throws(() => checkModuleUrl('file:///etc/passwd', { allowLocal: true }), /not file/)
})

await test('maskUrl: host only, never the path or token', () => {
  assert.equal(maskUrl('https://torrentio.strem.fun/providers=yts|realdebrid=SECRETTOKEN/manifest.json'), 'torrentio.strem.fun')
  assert.equal(maskUrl('stremio://addon.example.com:8443/abc/manifest.json'), 'addon.example.com:8443')
  assert.equal(maskUrl('https://user:pass@example.com/x'), 'example.com')
  assert.equal(maskUrl('nonsense'), 'invalid address')
  assert.equal(maskUrl(''), 'invalid address')
})

await test('scriptUrlCandidates: http(s) only, https first', () => {
  assert.deepEqual(scriptUrlCandidates('https://cdn.example.com/m.js', 'https://example.com/m.json'), ['https://cdn.example.com/m.js'])
  assert.deepEqual(scriptUrlCandidates('script.js', 'https://example.com/mods/m.json'), ['https://example.com/mods/script.js'])
  assert.deepEqual(scriptUrlCandidates('http://example.com/m.js', 'https://example.com/m.json'), ['https://example.com/m.js', 'http://example.com/m.js'])
  assert.deepEqual(scriptUrlCandidates('http://localhost:8080/m.js', 'http://localhost:8080/m.json'), ['http://localhost:8080/m.js'])
  assert.throws(() => scriptUrlCandidates('file:///C:/evil.js', 'https://example.com/m.json'), /not file/)
  assert.throws(() => scriptUrlCandidates('data:text/javascript,alert(1)', 'https://example.com/m.json'), /not data/)
  assert.throws(() => scriptUrlCandidates('javascript:alert(1)', 'https://example.com/m.json'), /not javascript/)
})

await test('checkManifestUrl', () => {
  assert.equal(checkManifestUrl(' stremio://addon.example.com/manifest.json '), 'https://addon.example.com/manifest.json')
  assert.equal(checkManifestUrl('http://192.168.1.2:7000/manifest.json'), 'http://192.168.1.2:7000/manifest.json')
  assert.throws(() => checkManifestUrl('file:///C:/manifest.json'), /http\(s\)/)
  assert.throws(() => checkManifestUrl('manifest.json'), /full address/)
})

await test('readCapped: declared and streamed sizes', async () => {
  const small = await readCapped(new Response('hello'), 10)
  assert.equal(new TextDecoder().decode(small), 'hello')
  await assert.rejects(readCapped(new Response('x'.repeat(11)), 10), /too large/)
  await assert.rejects(readCapped(new Response('abc', { headers: { 'content-length': '999999999' } }), 1000), /too large/)
  let pulls = 0
  const endless = new ReadableStream({ pull (controller) { pulls++; controller.enqueue(new Uint8Array(1024)) } })
  await assert.rejects(readCapped(new Response(endless), 4096), /too large/)
  assert.ok(pulls < 10, 'stops reading once over the cap')
  assert.equal((await readCapped(new Response(null), 10)).byteLength, 0)
})

await test('moduleDomains: manifest hosts and script literals', () => {
  const domains = moduleDomains(
    { baseUrl: 'https://anime.example.com/', searchBaseUrl: 'https://search.example.com/q=%s' },
    'const a = "https://api.example.net/v1/"; fetchv2(`https://cdn.example.org:8443/x`); // http://evil.example.io',
    'https://raw.githubusercontent.com/u/r/main/m.js'
  )
  assert.deepEqual(domains, ['anime.example.com', 'api.example.net', 'cdn.example.org', 'evil.example.io', 'raw.githubusercontent.com', 'search.example.com'])
  assert.deepEqual(moduleDomains(null, ''), [])
})

await test('DOM shim parses HTML like the iOS prelude', () => {
  const g = {}
  installDom(g)
  const doc = new g.DOMParser().parseFromString('<ul><li class="ep" data-n="1"><a href="/e/1?a=1&amp;b=2">Ep 1</a><li class="ep" data-n="2"><a href="/e/2">Ep 2</a></ul>', 'text/html')
  const items = [...doc.querySelectorAll('li.ep a')].map(a => [a.textContent, a.getAttribute('href')])
  assert.deepEqual(items, [['Ep 1', '/e/1?a=1&b=2'], ['Ep 2', '/e/2']])
  assert.equal(doc.querySelector('li[data-n="2"]').textContent, 'Ep 2')
  assert.equal(typeof g.document.createElement, 'function')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
