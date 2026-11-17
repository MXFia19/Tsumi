// Upstream requests of the stream proxy (/fetch) and body helpers of /proxy. Run with: node electron/src/main/proxyUpstream.test.mjs
import assert from 'node:assert/strict'
import http from 'node:http'
import zlib from 'node:zlib'
import { Readable, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { hostKind } from '../../../common/modules/sandbox/network.js'
import {
  checkTarget, guardedLookup, redirectMethod, moduleFetch, decodersFor, byteLimit, readHead, readRest, bodyChunks, MAX_REDIRECTS
} from './proxyUpstream.js'

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

/** Reads a whole http.IncomingMessage. */
async function text (response) {
  const chunks = []
  for await (const chunk of response) chunks.push(chunk)
  return Buffer.concat(chunks).toString('utf8')
}

function streamOf (chunks) {
  return new ReadableStream({
    start (controller) {
      for (const chunk of chunks) controller.enqueue(new Uint8Array(Buffer.from(chunk)))
      controller.close()
    }
  })
}

// Local test server: /echo answers the request it got, /redirect?status=&to= redirects, /loop redirects to itself.
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/redirect') {
    res.writeHead(Number(url.searchParams.get('status')) || 302, { Location: url.searchParams.get('to') })
    return res.end('moved')
  }
  if (url.pathname === '/loop') {
    res.writeHead(302, { Location: '/loop' })
    return res.end()
  }
  if (url.pathname === '/gzip') {
    res.writeHead(200, { 'Content-Encoding': 'gzip', 'Content-Type': 'text/plain' })
    return res.end(zlib.gzipSync('compressed hello'))
  }
  const chunks = []
  req.on('data', chunk => chunks.push(chunk))
  req.on('end', () => {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Set-Cookie': ['a=1', 'b=2'] })
    res.end(JSON.stringify({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString('utf8') }))
  })
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const port = server.address().port
const base = `http://127.0.0.1:${port}`
const noPool = { agent: false }
/** A request of a module served from this machine (the test server is local). */
const fetchLocal = (request) => moduleFetch({ allowLocal: true, ...request }, noPool)

await test('checkTarget allows public http(s) and refuses local hosts, other schemes and invalid URLs', () => {
  assert.equal(checkTarget('https://example.com/a?b=1').href, 'https://example.com/a?b=1')
  for (const url of ['http://127.0.0.1/', 'http://localhost:8080/', 'http://192.168.1.10/', 'http://[::1]/', 'http://10.0.0.1/', 'http://169.254.169.254/', 'http://nas.local/', 'http://224.0.0.1/']) {
    assert.throws(() => checkTarget(url), /local network address/, url)
  }
  assert.throws(() => checkTarget('ftp://example.com/'), /http\(s\)/)
  assert.throws(() => checkTarget('file:///C:/Windows/win.ini'), /http\(s\)/)
  assert.throws(() => checkTarget('not a url'), /invalid URL/)
  assert.equal(checkTarget('http://192.168.1.10/x', { allowLocal: true }).hostname, '192.168.1.10')
})

await test('guardedLookup refuses names that resolve to a local address (every answer checked)', async () => {
  const answers = {
    'rebind.example': [{ address: '127.0.0.1', family: 4 }],
    'mixed.example': [{ address: '93.184.216.34', family: 4 }, { address: '10.0.0.5', family: 4 }],
    'v6.example': [{ address: '::ffff:192.168.0.1', family: 6 }],
    'ok.example': [{ address: '93.184.216.34', family: 4 }, { address: '2606:2800:220:1::1', family: 6 }]
  }
  const resolve = (hostname, options, callback) => callback(null, answers[hostname] || [])
  const lookup = guardedLookup({ resolve })
  const run = (hostname, options) => new Promise(resolve => lookup(hostname, options, (...args) => resolve(args)))
  for (const name of ['rebind.example', 'mixed.example', 'v6.example']) {
    const [error] = await run(name, {})
    assert.equal(error?.code, 'ELOCALADDRESS', name)
  }
  const [error, address, family] = await run('ok.example', {})
  assert.equal(error, null)
  assert.equal(address, '93.184.216.34')
  assert.equal(family, 4)
  const [allError, all] = await run('ok.example', { all: true })
  assert.equal(allError, null)
  assert.equal(all.length, 2)
  const [missing] = await run('none.example', {})
  assert.equal(missing?.code, 'ENOTFOUND')
})

await test('redirectMethod follows the Fetch standard', () => {
  assert.deepEqual(redirectMethod(302, 'POST'), { method: 'GET', dropBody: true })
  assert.deepEqual(redirectMethod(301, 'POST'), { method: 'GET', dropBody: true })
  assert.deepEqual(redirectMethod(303, 'PUT'), { method: 'GET', dropBody: true })
  assert.deepEqual(redirectMethod(303, 'HEAD'), { method: 'HEAD', dropBody: false })
  assert.deepEqual(redirectMethod(307, 'POST'), { method: 'POST', dropBody: false })
  assert.deepEqual(redirectMethod(308, 'PUT'), { method: 'PUT', dropBody: false })
  assert.deepEqual(redirectMethod(302, 'PUT'), { method: 'PUT', dropBody: false })
})

await test('moduleFetch sends the method, body, default and module headers', async () => {
  const { response, url, redirected } = await fetchLocal({ url: `${base}/echo`, method: 'post', headers: { 'user-agent': 'Module/1', Referer: 'https://site.example/' }, body: 'q=1' })
  assert.equal(response.statusCode, 200)
  assert.deepEqual(response.headers['set-cookie'], ['a=1', 'b=2'])
  const echo = JSON.parse(await text(response))
  assert.equal(echo.method, 'POST')
  assert.equal(echo.body, 'q=1')
  assert.equal(echo.headers['content-length'], '3')
  assert.equal(echo.headers['user-agent'], 'Module/1')
  assert.equal(echo.headers.referer, 'https://site.example/')
  assert.equal(echo.headers.accept, '*/*')
  assert.equal(url, `${base}/echo`)
  assert.equal(redirected, false)
})

await test('moduleFetch refuses local addresses unless the module is local', async () => {
  await assert.rejects(moduleFetch({ url: `${base}/echo` }, noPool), /local network address/)
  const { response } = await moduleFetch({ url: `${base}/echo`, allowLocal: true }, noPool)
  assert.equal(response.statusCode, 200)
  response.resume()
})

// For the next tests 127.0.0.1 (the test server) counts as a public address; every other local name stays local.
const kindOf = host => host === '127.0.0.1' ? 'public' : hostKind(host)

await test('moduleFetch checks the address a name resolves to, and connects to the address it checked', async () => {
  const resolve = (hostname, options, callback) => callback(null, [{ address: hostname === 'rebind.test' ? '127.0.0.2' : '127.0.0.1', family: 4 }])
  await assert.rejects(moduleFetch({ url: `http://rebind.test:${port}/echo` }, { kindOf, resolve, ...noPool }), /local network address \(rebind\.test\)/)
  const { response } = await moduleFetch({ url: `http://public.test:${port}/echo` }, { kindOf, resolve, ...noPool })
  assert.equal(JSON.parse(await text(response)).headers.host, `public.test:${port}`)
})

await test('moduleFetch checks every redirect', async () => {
  const to = encodeURIComponent(`http://localhost:${port}/echo`)
  await assert.rejects(moduleFetch({ url: `${base}/redirect?to=${to}` }, { kindOf, ...noPool }), /local network address \(localhost\)/)
  const lan = encodeURIComponent('http://192.168.1.1/admin')
  await assert.rejects(moduleFetch({ url: `${base}/redirect?to=${lan}` }, { kindOf, ...noPool }), /local network address \(192\.168\.1\.1\)/)
  const file = encodeURIComponent('file:///C:/Windows/win.ini')
  await assert.rejects(moduleFetch({ url: `${base}/redirect?to=${file}` }, { kindOf, ...noPool }), /http\(s\)/)
})

await test('moduleFetch follows redirects like fetch (method, body, cross-origin headers)', async () => {
  const post302 = await fetchLocal({ url: `${base}/redirect?status=302&to=/echo`, method: 'POST', body: 'x', headers: { 'Content-Type': 'text/plain' } })
  const echo302 = JSON.parse(await text(post302.response))
  assert.equal(echo302.method, 'GET')
  assert.equal(echo302.body, '')
  assert.equal(echo302.headers['content-type'], undefined)
  assert.equal(post302.redirected, true)
  assert.equal(post302.url, `${base}/echo`)

  const post307 = await fetchLocal({ url: `${base}/redirect?status=307&to=/echo`, method: 'POST', body: 'x' })
  const echo307 = JSON.parse(await text(post307.response))
  assert.equal(echo307.method, 'POST')
  assert.equal(echo307.body, 'x')

  const other = encodeURIComponent(`http://localhost:${port}/echo`)
  const cross = await fetchLocal({ url: `${base}/redirect?to=${other}`, headers: { Authorization: 'Bearer abc', Cookie: 'c=1', 'X-Keep': 'yes' } })
  const echoCross = JSON.parse(await text(cross.response))
  assert.equal(echoCross.headers.authorization, undefined)
  assert.equal(echoCross.headers.cookie, undefined)
  assert.equal(echoCross.headers['x-keep'], 'yes')

  const same = await fetchLocal({ url: `${base}/redirect?to=/echo`, headers: { Authorization: 'Bearer abc' } })
  assert.equal(JSON.parse(await text(same.response)).headers.authorization, 'Bearer abc')
})

await test('moduleFetch redirect modes: manual returns the 3xx, error fails, loops stop', async () => {
  const manual = await fetchLocal({ url: `${base}/redirect?status=301&to=/elsewhere`, redirect: 'manual' })
  assert.equal(manual.response.statusCode, 301)
  assert.equal(manual.response.headers.location, '/elsewhere')
  assert.equal(manual.redirected, false)
  manual.response.resume()
  await assert.rejects(fetchLocal({ url: `${base}/redirect?to=/echo`, redirect: 'error' }), /redirect/)
  await assert.rejects(fetchLocal({ url: `${base}/loop` }), /Too many redirects/)
  assert.equal(MAX_REDIRECTS, 20)
})

await test('moduleFetch stops when its signal aborts', async () => {
  const controller = new AbortController()
  controller.abort()
  await assert.rejects(fetchLocal({ url: `${base}/echo`, signal: controller.signal }), error => error.name === 'AbortError')
})

await test('decodersFor undoes gzip / deflate / br and leaves unknown encodings', async () => {
  const decode = async (data, encoding) => {
    const chunks = []
    await pipeline(Readable.from([data]), ...decodersFor(encoding), new Writable({ write (chunk, _e, callback) { chunks.push(chunk); callback() } }))
    return Buffer.concat(chunks).toString('utf8')
  }
  assert.equal(await decode(zlib.gzipSync('hello'), 'gzip'), 'hello')
  assert.equal(await decode(zlib.deflateSync('hello'), 'deflate'), 'hello')
  assert.equal(await decode(zlib.brotliCompressSync('hello'), 'br'), 'hello')
  assert.equal(await decode(zlib.gzipSync(zlib.brotliCompressSync('hello')), 'br, gzip'), 'hello')
  assert.equal(decodersFor('zstd').length, 0)
  assert.equal(decodersFor('').length, 0)
  assert.equal(decodersFor('identity').length, 0)
  assert.equal(decodersFor('gzip', { method: 'HEAD' }).length, 0)
  assert.equal(decodersFor('gzip', { status: 304 }).length, 0)

  const { response } = await fetchLocal({ url: `${base}/gzip` })
  const chunks = []
  await pipeline(response, ...decodersFor(response.headers['content-encoding']), new Writable({ write (chunk, _e, callback) { chunks.push(chunk); callback() } }))
  assert.equal(Buffer.concat(chunks).toString('utf8'), 'compressed hello')
})

await test('byteLimit fails once the cap is passed', async () => {
  const sink = () => new Writable({ write (_chunk, _e, callback) { callback() } })
  await pipeline(Readable.from([Buffer.alloc(5), Buffer.alloc(5)]), byteLimit(10), sink())
  await assert.rejects(pipeline(Readable.from([Buffer.alloc(6), Buffer.alloc(6)]), byteLimit(10), sink()), error => error.code === 'ETOOLARGE' && /too large/.test(error.message))
})

await test('readHead / readRest / bodyChunks keep every byte', async () => {
  // Small first chunks are gathered until the start can be recognized (or the body ends).
  const start = await readHead(streamOf(['#EXT', 'M3U\n', 'seg.ts\n']).getReader())
  assert.equal(start.head.toString(), '#EXTM3U\nseg.ts\n')
  assert.equal(start.done, true)

  const reader = streamOf(['#EXTM3U\n', 'a'.repeat(40), 'b'.repeat(10)]).getReader()
  const head = await readHead(reader)
  assert.equal(head.done, false)
  assert.equal(head.head.length, 48)
  assert.equal((await readRest(reader, head, 1000)).toString(), '#EXTM3U\n' + 'a'.repeat(40) + 'b'.repeat(10))

  const big = streamOf(['x'.repeat(40), 'y'.repeat(40)]).getReader()
  await assert.rejects(readRest(big, await readHead(big), 60), /too large/)

  const binary = streamOf([Buffer.from([0x47, 1, 2]), Buffer.alloc(40, 7), Buffer.from([9])]).getReader()
  const binaryStart = await readHead(binary)
  const all = []
  for await (const chunk of bodyChunks(binary, binaryStart)) all.push(Buffer.from(chunk))
  assert.equal(Buffer.concat(all).length, 44)
  assert.equal(Buffer.concat(all)[0], 0x47)
})

server.close()
console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exit(1)
