import dgram from 'node:dgram'
import os from 'node:os'
import { EventEmitter } from 'node:events'
import Debug from 'debug'
import { encodeQuery, decodePacket, TYPE } from './dns.js'

const debug = Debug('electron:cast:mdns')

const MDNS_ADDRESS = '224.0.0.251'
const MDNS_PORT = 5353
export const CAST_SERVICE = '_googlecast._tcp.local'

/** Cast device advertised on the LAN, built from its PTR / SRV / TXT / A records. */
export function deviceFromRecords (instance, srv, txt, address) {
  if (!srv || !address) return null
  const data = txt || {}
  const id = String(data.id || instance)
  return {
    id,
    name: String(data.fn || instance.replace(`.${CAST_SERVICE}`, '').replace(/-[0-9a-f]{32}$/i, '') || 'Cast device'),
    model: data.md ? String(data.md) : '',
    status: data.rs ? String(data.rs) : '',
    host: address,
    port: srv.port || 8009
  }
}

/** IPv4 addresses of the network interfaces that can reach a LAN (no loopback, no link-local). */
function lanAddresses () {
  const addresses = []
  for (const list of Object.values(os.networkInterfaces())) {
    for (const entry of list || []) {
      const family = typeof entry.family === 'string' ? entry.family : `IPv${entry.family}`
      if (family !== 'IPv4' || entry.internal || entry.address.startsWith('169.254.')) continue
      addresses.push(entry.address)
    }
  }
  return [...new Set(addresses)]
}

/**
 * Finds Cast devices (_googlecast._tcp) with mDNS. Queries go out on every LAN interface from an ephemeral port
 * (legacy unicast: devices answer straight to that socket, no conflict with other mDNS responders on port 5353),
 * and a shared 5353 socket listens for multicast answers and announcements as a fallback.
 * Emits 'devices' with the current list whenever it changes.
 */
export default class CastDiscovery extends EventEmitter {
  /** @type {Map<string, { srv?: any, txt?: any, seen: number }>} */
  instances = new Map()
  /** @type {Map<string, { address: string, seen: number }>} */
  hosts = new Map()
  /** @type {Map<string, any>} */
  devices = new Map()
  sockets = []
  timer = null
  running = false
  queries = 0

  start () {
    if (this.running) {
      this.query()
      return
    }
    this.running = true
    this.queries = 0
    this.prune()
    this.openSockets()
    this.query()
    // Ask a few times quickly (UDP is lossy), then every 15 s while the picker is open.
    this.timer = setInterval(() => {
      if (this.queries < 4 || this.queries % 5 === 0) this.query()
      else this.queries++
    }, 3000)
  }

  /** Forgets devices not heard of for 10 minutes (switched off, other network). */
  prune () {
    const limit = Date.now() - 10 * 60_000
    for (const [key, entry] of this.instances) if (entry.seen < limit) this.instances.delete(key)
    for (const [key, entry] of this.hosts) if (entry.seen < limit) this.hosts.delete(key)
    for (const [id, device] of this.devices) if (!this.instances.has(device.instance)) this.devices.delete(id)
  }

  stop () {
    this.running = false
    clearInterval(this.timer)
    this.timer = null
    for (const socket of this.sockets) {
      try { socket.close() } catch {}
    }
    this.sockets = []
  }

  list () {
    return [...this.devices.values()].sort((a, b) => a.name.localeCompare(b.name))
  }

  get (id) {
    return this.devices.get(id) || null
  }

  openSockets () {
    for (const address of lanAddresses()) {
      const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
      socket.on('message', (message, rinfo) => this.handle(message, rinfo))
      socket.on('error', (error) => {
        debug(`Query socket ${address} failed`, error.message)
        try { socket.close() } catch {}
        this.sockets = this.sockets.filter(s => s !== socket)
      })
      socket.bind(0, address, () => {
        try {
          socket.setMulticastInterface(address)
          socket.setMulticastTTL(255)
        } catch (error) {
          debug('setMulticastInterface failed', address, error.message)
        }
        socket.ready = true
        this.sendQuery(socket, [{ name: CAST_SERVICE, type: TYPE.PTR }])
      })
      socket.iface = address
      this.sockets.push(socket)
    }

    // Passive listener on the mDNS port (shared with other responders thanks to SO_REUSEADDR).
    const listener = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    listener.on('message', (message, rinfo) => this.handle(message, rinfo))
    listener.on('error', (error) => {
      debug('mDNS listener failed', error.message)
      try { listener.close() } catch {}
      this.sockets = this.sockets.filter(s => s !== listener)
    })
    listener.bind(MDNS_PORT, () => {
      for (const address of lanAddresses()) {
        try { listener.addMembership(MDNS_ADDRESS, address) } catch (error) { debug('addMembership failed', address, error.message) }
      }
    })
    listener.passive = true
    this.sockets.push(listener)
  }

  sendQuery (socket, questions) {
    if (!socket.ready || socket.passive) return
    const packet = encodeQuery(questions)
    socket.send(packet, 0, packet.length, MDNS_PORT, MDNS_ADDRESS, (error) => {
      if (error) debug('mDNS query failed', socket.iface, error.message)
    })
  }

  query (questions = [{ name: CAST_SERVICE, type: TYPE.PTR }]) {
    this.queries++
    for (const socket of this.sockets) this.sendQuery(socket, questions)
  }

  handle (message, rinfo) {
    let packet
    try {
      packet = decodePacket(message)
    } catch (error) {
      return
    }
    if (!packet.isResponse) return
    const now = Date.now()
    const records = [...packet.answers, ...packet.additionals]
    const touched = new Set()
    for (const record of records) {
      const name = record.name.toLowerCase()
      if (record.type === TYPE.PTR && name === CAST_SERVICE) {
        const instance = String(record.data)
        if (record.ttl === 0) {
          this.instances.delete(instance.toLowerCase())
          touched.add(instance.toLowerCase())
          continue
        }
        const entry = this.instances.get(instance.toLowerCase()) || { seen: now, name: instance }
        entry.seen = now
        this.instances.set(instance.toLowerCase(), entry)
        touched.add(instance.toLowerCase())
      } else if (record.type === TYPE.SRV && name.endsWith(CAST_SERVICE)) {
        const entry = this.instances.get(name) || { seen: now, name: record.name }
        entry.srv = record.data
        entry.seen = now
        this.instances.set(name, entry)
        touched.add(name)
      } else if (record.type === TYPE.TXT && name.endsWith(CAST_SERVICE)) {
        const entry = this.instances.get(name) || { seen: now, name: record.name }
        entry.txt = record.data?.data
        entry.seen = now
        this.instances.set(name, entry)
        touched.add(name)
      } else if (record.type === TYPE.A && record.data) {
        this.hosts.set(name, { address: record.data, seen: now })
        for (const [key, entry] of this.instances) {
          if (entry.srv?.target?.toLowerCase() === name) touched.add(key)
        }
      }
    }
    // Some devices only answer with the A record of the sender's address: use the packet source as a fallback.
    for (const key of touched) this.update(key, rinfo?.address)
  }

  update (key, sourceAddress) {
    const entry = this.instances.get(key)
    if (!entry) {
      for (const [id, device] of this.devices) {
        if (device.instance === key) {
          this.devices.delete(id)
          this.emit('devices', this.list())
        }
      }
      return
    }
    if (!entry.srv || !entry.txt) {
      // Ask for the missing records directly.
      this.query([{ name: entry.name, type: TYPE.SRV }, { name: entry.name, type: TYPE.TXT }])
      return
    }
    const target = entry.srv.target?.toLowerCase()
    let address = target && this.hosts.get(target)?.address
    if (!address && target) this.query([{ name: entry.srv.target, type: TYPE.A }])
    if (!address) address = sourceAddress
    const device = deviceFromRecords(entry.name, entry.srv, entry.txt, address)
    if (!device) return
    device.instance = key
    const previous = this.devices.get(device.id)
    this.devices.set(device.id, device)
    if (!previous || previous.host !== device.host || previous.port !== device.port || previous.name !== device.name || previous.status !== device.status) {
      debug(`Cast device: ${device.name} (${device.model}) at ${device.host}:${device.port}`)
      this.emit('devices', this.list())
    }
  }
}
