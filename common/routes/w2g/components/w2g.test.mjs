// Watch Together: two (or more) W2GClient instances in one process, linked by a fake P2PT transport.
// Run with: node common/routes/w2g/components/w2g.test.mjs
// The app modules w2g.js imports (settings, helper, voice engine, P2PT...) are replaced by small fakes through a module
// resolve hook; sync.js and events.js are the real ones.
import assert from 'node:assert/strict'
import * as nodeModule from 'node:module'

if (typeof nodeModule.registerHooks !== 'function') {
  // module.registerHooks: Node 22.15 / 23.5 and later.
  console.log('skipped: this Node has no module.registerHooks')
  process.exit(0)
}

const STORE = `
export function writable (initial) {
  let current = initial
  const subscribers = new Set()
  return {
    get value () { return current },
    set value (next) { current = next; for (const fn of subscribers) fn(current) },
    set (next) { this.value = next },
    update (fn) { this.value = fn(current) },
    subscribe (fn) { subscribers.add(fn); fn(current); return () => subscribers.delete(fn) }
  }
}`

// One shared network: every fake P2PT of a lobby code is linked to the others; messages wait in a queue until flush().
const P2PT = `
import { EventEmitter } from 'node:events'
const net = globalThis.__w2gNet
export default class P2PT extends EventEmitter {
  constructor (trackers, code) {
    super()
    this.code = code
    this.id = 'peer' + String(++net.count).padStart(4, '0')
    this.peers = {}
    this.responseWaiting = {}
    net.last = this
  }
  start () {
    const list = net.swarms.get(this.code) ?? []
    net.swarms.set(this.code, list)
    for (const other of list) net.link(this, other)
    list.push(this)
  }
  send (peer, msg) {
    net.queue.push({ from: this, to: peer.id, msg })
    return Promise.resolve()
  }
  requestMorePeers () {}
  destroy () {
    for (const id of Object.keys(this.peers)) net.unlink(this, net.byId(this.code, id))
    net.swarms.set(this.code, (net.swarms.get(this.code) ?? []).filter(item => item !== this))
  }
}`

const VOICE = `
import { EventEmitter } from 'node:events'
import { writable } from 'simple-store-svelte'
export const voiceDuck = writable(1)
export class VoiceEngine extends EventEmitter {
  joined = false
  starting = false
  hasMic = false
  muted = false
  pushToTalk = false
  held = false
  transmitting = false
  error = null
  get payload () { return { joined: false, muted: true, speaking: false } }
  refresh () {}
  linkStates () { return {} }
  async join () {}
  leave () {}
  setMuted () {}
  setHeld () {}
  setMix () {}
  mixOf () { return { muted: false, volume: 1 } }
  destroy () {}
  resetRetries () {}
  signal () {}
  connect () {}
  close () {}
  hasLink () { return false }
  forget () {}
}`

const FAKES = {
  p2pt: P2PT,
  'simple-store-svelte': STORE,
  debug: 'export default function Debug () { return () => {} }',
  '@/routes/w2g/components/voice.js': VOICE,
  '@/modules/helper.js': 'export default { getUser: () => globalThis.__w2gUser ?? null }',
  '@/modules/settings.js': "import { writable } from 'simple-store-svelte'\nexport const settings = writable({ w2gAutoSync: true, w2gVoiceDucking: true, w2gWatchOnMyOwn: false })",
  '@/modules/support.js': 'export const SUPPORTS = { isAndroid: false }',
  '@/modules/util.js': "import { randomBytes } from 'node:crypto'\nexport function generateRandomHexCode (len) { return randomBytes(Math.ceil(len / 2)).toString('hex').slice(0, len) }"
}
const COMMON = new URL('../../../', import.meta.url)

nodeModule.registerHooks({
  resolve (specifier, context, nextResolve) {
    if (Object.hasOwn(FAKES, specifier)) return { url: 'data:text/javascript,' + encodeURIComponent(FAKES[specifier]), format: 'module', shortCircuit: true }
    if (specifier.startsWith('@/')) return { url: new URL(specifier.slice(2), COMMON).href, format: 'module', shortCircuit: true }
    return nextResolve(specifier, context)
  }
})

// ---------------------------------------------------------------- the fake network

const net = globalThis.__w2gNet = {
  count: 0,
  swarms: new Map(),
  queue: [],
  /** Delivered events: { from, to, type, payload } (transport ids). */
  log: [],
  last: null,
  byId (code, id) {
    return (this.swarms.get(code) ?? []).find(item => item.id === id)
  },
  channel (owner, remote) {
    return { id: remote.id, channelName: 'c0', connected: true, destroy: () => net.unlink(owner, remote) }
  },
  link (a, b) {
    const ab = this.channel(a, b)
    const ba = this.channel(b, a)
    a.peers[b.id] = { c0: ab }
    b.peers[a.id] = { c0: ba }
    a.emit('peerconnect', ab)
    b.emit('peerconnect', ba)
  },
  unlink (a, b) {
    if (!a || !b || !a.peers[b.id]) return
    const ab = a.peers[b.id].c0
    const ba = b.peers[a.id]?.c0
    delete a.peers[b.id]
    delete b.peers[a.id]
    a.emit('peerclose', ab)
    if (ba) b.emit('peerclose', ba)
  },
  /** Delivers every queued message (and what they cause) in order. */
  flush () {
    for (let guard = 0; this.queue.length; guard++) {
      if (guard > 10_000) throw new Error('message loop')
      const { from, to, msg } = this.queue.shift()
      const target = this.byId(from.code, to)
      const channel = target?.peers[from.id]?.c0
      if (!channel) continue
      try {
        const event = JSON.parse(msg)
        this.log.push({ from: from.id, to, type: event.type, payload: event.payload })
      } catch {}
      target.emit('data', channel)
      target.emit('msg', channel, msg)
    }
  },
  sent (from, type) {
    return this.log.filter(item => item.from === from.id && item.type === type)
  }
}

// A controllable clock (timers still run on the real one, the test is over long before they matter).
let clock = 1_700_000_000_000
Date.now = () => clock
const advance = ms => { clock += ms }

const { W2GClient } = await import('./w2g.js')

let passed = 0
let failed = 0
async function test (name, fn) {
  const clients = []
  try {
    await fn(clients)
    passed++
    console.log(`ok - ${name}`)
  } catch (error) {
    failed++
    console.error(`FAIL - ${name}\n${error?.stack || error}`)
  } finally {
    for (const item of clients) item.client.destroy()
    net.queue.length = 0
    net.log.length = 0
    net.swarms.clear()
  }
}

/** A client with what it emitted for the app, and its transport. */
function member (clients, user, code) {
  globalThis.__w2gUser = user
  const client = new W2GClient(code)
  const transport = net.last
  const emitted = { media: [], player: [], index: [], kicked: 0 }
  client.on('media', shared => emitted.media.push(shared))
  client.on('player', state => emitted.player.push(state))
  client.on('index', index => emitted.index.push(index))
  client.on('kicked', () => emitted.kicked++)
  const item = { client, transport, emitted }
  clients.push(item)
  return item
}

/** A raw peer of the lobby: sends whatever the test wants, like an older app or someone copying ids. */
function rawPeer (code) {
  const transport = new (net.last.constructor)([], code)
  transport.start()
  return {
    transport,
    send (to, type, payload) {
      net.queue.push({ from: transport, to: to.transport.id, msg: JSON.stringify({ type, payload }) })
    }
  }
}

/** What the app does when the player starts a shared media: share it, load it, report it ready. */
function playLocally ({ client }, { media, episode }, time = 0) {
  client.shareMedia({ media, episode })
  client.setLocalStatus({ state: 'loading', time: 0, mediaKey: client.launchedKey })
  client.setLocalStatus({ state: 'playing', time, mediaKey: client.launchedKey })
  client.playerReady()
}

const lines = client => client.messages.value.filter(entry => entry.type === 'system').map(entry => entry.message)

await test('a streamed and a downloaded copy of one episode are one media key: no ping-pong, Join seeks', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  const guest = member(clients, { id: 202, name: 'Gus' }, host.client.code)
  net.flush()
  advance(6_000)
  // The host streams: playAnime passes { number: 5 }. Canonical key "21:5".
  playLocally(host, { media: { id: 21, format: 'TV' }, episode: { number: 5 } }, 100)
  net.flush()
  assert.equal(host.client.media.key, '21:5')
  // The guest is not in the player: nothing starts, the Join card is offered.
  assert.equal(guest.emitted.media.length, 0)
  const offer = guest.client.joinOffer()
  assert.equal(offer?.key, '21:5')
  advance(2_000)
  guest.client.joinPlayback()
  assert.equal(guest.emitted.media.length, 1)
  // The guest has it downloaded: the download path passes the bare number 5.
  playLocally(guest, { media: guest.emitted.media[0].media, episode: 5 })
  net.flush()
  // No `media` back from the guest (the host would reload, then share again...).
  assert.equal(net.sent(guest.transport, 'media').length, 0)
  assert.equal(host.emitted.media.length, 0)
  // Join: the guest seeks to the host's expected position (100 s + 2 s since its status).
  const sync = guest.emitted.player.at(-1)
  assert.equal(sync?.action, 'sync')
  assert.ok(Math.abs(sync.time - 102) < 0.5, `seek to ${sync?.time}`)
  // Each side shows the other on the same episode.
  const badge = host.client.describeMembers().find(row => !row.isSelf).badge.kind
  assert.notEqual(badge, 'other')
})

await test('an older app writing "21::5" is on the same episode (media, status, player)', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  net.flush()
  const old = rawPeer(host.client.code)
  net.flush()
  // A v2.5 desktop app without session id, that wrote streamed episodes as "21::5".
  old.send(host, 'init', { id: 'old1', name: 'Olaf', protocol: 2, client: 'tsumi-desktop' })
  net.flush()
  advance(6_000)
  playLocally(host, { media: { id: 21 }, episode: 5 }, 50)
  net.flush()
  old.send(host, 'status', { state: 'playing', time: 50, mediaKey: '21::5', rate: 1, sentAt: clock, following: true })
  old.send(host, 'media', { media: { id: 21 }, episode: { number: 5 }, key: '21::5' })
  net.flush()
  // Not another title: the host keeps its media and its player.
  assert.equal(host.client.media.key, '21:5')
  assert.equal(host.emitted.media.length, 0)
  const row = host.client.describeMembers().find(item => item.name === 'Olaf')
  assert.notEqual(row.badge.kind, 'other')
  assert.equal(row.canInvite, false)
  // Its `player` on "21::5" applies to our "21:5".
  old.send(host, 'player', { time: 80, paused: true, by: 'old1', action: 'pause', mediaKey: '21::5' })
  net.flush()
  assert.equal(host.emitted.player.at(-1)?.time, 80)
})

await test('host mode: a non-host launching another episode does not change or send the lobby media', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  const guest = member(clients, { id: 202, name: 'Gus' }, host.client.code)
  net.flush()
  advance(6_000)
  playLocally(host, { media: { id: 21, episodes: 12 }, episode: 5 }, 10)
  host.client.setMode('host')
  net.flush()
  assert.equal(guest.client.media?.key, '21:5')
  assert.equal(guest.client.controlLocked, true)
  // The guest starts something else on its own.
  playLocally(guest, { media: { id: 99, episodes: 3 }, episode: 1 })
  net.flush()
  assert.equal(net.sent(guest.transport, 'media').length, 0)
  assert.equal(guest.client.media.key, '21:5')
  assert.equal(guest.client.launchedKey, '99:1')
  // So it still gets the Join card back to the host's episode, and "Add next episode" is the host's title.
  assert.equal(guest.client.joinOffer()?.key, '21:5')
  assert.equal(guest.client.nextEpisodeOffer()?.media.id, 21)
})

await test('a channel copying the host ids has no authority, keeps its first identity, and the host still migrates', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  const guest = member(clients, { id: 202, name: 'Gus' }, host.client.code)
  net.flush()
  advance(6_000)
  host.client.setMode('host')
  playLocally(host, { media: { id: 21 }, episode: 5 }, 10)
  playLocally(guest, { media: { id: 21 }, episode: 5 }, 10)
  net.flush()
  const before = guest.emitted.player.length
  // The host's ids are broadcast (`host`, `init`): a third channel claims them.
  const copy = rawPeer(host.client.code)
  net.flush()
  copy.send(guest, 'init', { id: host.client.selfId, name: 'Hana', protocol: 2, sessionId: host.client.sessionId })
  net.flush()
  const rows = guest.client.describeMembers()
  const shadow = rows.find(row => row.shadow)
  assert.ok(shadow, 'the copy is a separate member')
  assert.equal(shadow.isHost, false)
  assert.equal(rows.find(row => row.isHost)?.userId, host.client.selfKey)
  // Its playback events and kicks are not the host's.
  copy.send(guest, 'player', { time: 999, paused: true, by: host.client.selfId, action: 'pause', mediaKey: '21:5' })
  copy.send(guest, 'kick', { userId: guest.client.selfId })
  copy.send(guest, 'host', { hostId: host.client.selfId, hostSession: host.client.sessionId, mode: 'everyone' })
  net.flush()
  assert.equal(guest.emitted.player.slice(before).some(state => state.time === 999), false)
  assert.equal(guest.emitted.kicked, 0)
  assert.equal(guest.client.mode, 'host')
  // `init` again with other session ids: still the same member (no flood of "joined" lines).
  const joined = lines(guest.client).filter(line => line === 'Hana joined').length
  for (let i = 0; i < 10; i++) copy.send(guest, 'init', { id: host.client.selfId, name: 'Hana', protocol: 2, sessionId: `fake${i}session` })
  net.flush()
  assert.equal(lines(guest.client).filter(line => line === 'Hana joined').length, joined)
  // The real host leaves: the copy does not inherit the role, the guest is elected (the copy is never a candidate).
  host.client.destroy()
  clients.splice(clients.indexOf(host), 1)
  net.flush()
  assert.equal(guest.client.isHost, true)
})

await test('the lobby state sent to a newcomer is remembered, not applied', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  net.flush()
  advance(6_000)
  playLocally(host, { media: { id: 21 }, episode: 5 }, 300)
  net.flush()
  const late = member(clients, { id: 303, name: 'Lia' }, host.client.code)
  net.flush()
  // media, index and player arrived within 5 s of the host's init: nothing starts or seeks.
  assert.equal(late.client.media?.key, '21:5')
  assert.equal(late.emitted.media.length, 0)
  assert.equal(late.emitted.player.length, 0)
  assert.equal(late.emitted.index.length, 0)
})

await test('Join / invite to the episode already playing does not load it again, it seeks at once', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  const guest = member(clients, { id: 202, name: 'Gus' }, host.client.code)
  net.flush()
  advance(6_000)
  playLocally(host, { media: { id: 21 }, episode: 5 }, 40)
  net.flush()
  // The guest watches on its own, the same episode (its own key "21:5").
  guest.client.setFollowing(false)
  playLocally(guest, { media: { id: 21 }, episode: { number: 5 } }, 0)
  net.flush()
  assert.equal(host.client.invite(guest.client.selfKey), true)
  net.flush()
  const before = guest.emitted.player.length
  assert.equal(guest.client.joinInvite(host.client.selfKey), true)
  assert.equal(guest.emitted.media.length, 0)
  const sync = guest.emitted.player.slice(before).at(-1)
  assert.equal(sync?.action, 'sync')
  assert.ok(Math.abs(sync.time - 40) < 0.5, `seek to ${sync?.time}`)
})

await test('the init of a member is rate limited per channel', async (clients) => {
  const host = member(clients, { id: 101, name: 'Hana' })
  net.flush()
  const peer = rawPeer(host.client.code)
  net.flush()
  for (let i = 0; i < 20; i++) peer.send(host, 'init', { id: 'abc0123456789def', displayName: `Name ${i}`, protocol: 2, sessionId: 'sess0001' })
  net.flush()
  const row = host.client.describeMembers().find(item => !item.isSelf)
  // The first five (the burst) are taken, the rest dropped.
  assert.equal(row.name, 'Name 4')
})

console.log(`\n${passed} passed, ${failed} failed`)
if (failed) process.exitCode = 1
