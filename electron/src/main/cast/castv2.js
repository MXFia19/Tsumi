import tls from 'node:tls'
import { EventEmitter } from 'node:events'
import Debug from 'debug'

const debug = Debug('electron:cast:channel')

// Cast v2 protocol: TLS on port 8009, every message is a 4-byte big-endian length followed by a protobuf
// CastMessage (cast_channel.proto). The protobuf is small enough to be encoded by hand.

export const NS = {
  CONNECTION: 'urn:x-cast:com.google.cast.tp.connection',
  HEARTBEAT: 'urn:x-cast:com.google.cast.tp.heartbeat',
  RECEIVER: 'urn:x-cast:com.google.cast.receiver',
  MEDIA: 'urn:x-cast:com.google.cast.media'
}

function encodeVarint (value) {
  const bytes = []
  let v = value >>> 0
  while (v > 0x7f) {
    bytes.push((v & 0x7f) | 0x80)
    v >>>= 7
  }
  bytes.push(v)
  return Buffer.from(bytes)
}

function encodeField (field, wireType) {
  return encodeVarint((field << 3) | wireType)
}

function encodeString (field, value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value), 'utf8')
  return Buffer.concat([encodeField(field, 2), encodeVarint(bytes.length), bytes])
}

/**
 * CastMessage { protocol_version = 1 (CASTV2_1_0), source_id = 2, destination_id = 3, namespace = 4,
 * payload_type = 5 (STRING = 0, BINARY = 1), payload_utf8 = 6, payload_binary = 7 }
 */
export function encodeCastMessage ({ source, destination, namespace, data }) {
  const binary = Buffer.isBuffer(data)
  const payload = binary ? data : (typeof data === 'string' ? data : JSON.stringify(data))
  return Buffer.concat([
    encodeField(1, 0), encodeVarint(0),
    encodeString(2, source),
    encodeString(3, destination),
    encodeString(4, namespace),
    encodeField(5, 0), encodeVarint(binary ? 1 : 0),
    binary ? encodeString(7, payload) : encodeString(6, payload)
  ])
}

function readVarint (buf, offset) {
  let result = 0
  let shift = 0
  let position = offset
  for (;;) {
    if (position >= buf.length) throw new Error('Truncated varint')
    const byte = buf[position++]
    result += (byte & 0x7f) * 2 ** shift
    if (!(byte & 0x80)) break
    shift += 7
    if (shift > 49) throw new Error('Varint too long')
  }
  return { value: result, end: position }
}

export function decodeCastMessage (buf) {
  const message = { protocolVersion: 0, source: '', destination: '', namespace: '', payloadType: 0, data: null }
  let offset = 0
  while (offset < buf.length) {
    const key = readVarint(buf, offset)
    offset = key.end
    const field = Math.floor(key.value / 8)
    const wireType = key.value & 7
    if (wireType === 0) {
      const value = readVarint(buf, offset)
      offset = value.end
      if (field === 1) message.protocolVersion = value.value
      else if (field === 5) message.payloadType = value.value
    } else if (wireType === 2) {
      const length = readVarint(buf, offset)
      const start = length.end
      const end = start + length.value
      if (end > buf.length) throw new Error('Truncated field')
      const bytes = buf.subarray(start, end)
      offset = end
      if (field === 2) message.source = bytes.toString('utf8')
      else if (field === 3) message.destination = bytes.toString('utf8')
      else if (field === 4) message.namespace = bytes.toString('utf8')
      else if (field === 6) message.data = bytes.toString('utf8')
      else if (field === 7) message.data = Buffer.from(bytes)
    } else if (wireType === 5) {
      offset += 4
    } else if (wireType === 1) {
      offset += 8
    } else {
      throw new Error(`Unsupported wire type ${wireType}`)
    }
  }
  if (typeof message.data === 'string') {
    try { message.data = JSON.parse(message.data) } catch {}
  }
  return message
}

/** Splits the TLS byte stream into CastMessages (length-prefixed). */
export class FrameParser {
  buffer = Buffer.alloc(0)

  /** @returns {Buffer[]} complete frames */
  push (chunk) {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk
    const frames = []
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32BE(0)
      if (length > 64 * 1024 * 1024) throw new Error('Cast frame too large')
      if (this.buffer.length < 4 + length) break
      frames.push(this.buffer.subarray(4, 4 + length))
      this.buffer = this.buffer.subarray(4 + length)
    }
    return frames
  }
}

export function frame (message) {
  const body = encodeCastMessage(message)
  const header = Buffer.alloc(4)
  header.writeUInt32BE(body.length, 0)
  return Buffer.concat([header, body])
}

/**
 * One TLS connection to a Cast device. Emits 'message' ({ source, destination, namespace, data }) and 'close'
 * (reason). Keeps the connection alive with PINGs and closes it when the device stops answering.
 */
export class CastChannel extends EventEmitter {
  socket = null
  parser = new FrameParser()
  requestId = Math.floor(Math.random() * 1e6) + 1
  pending = new Map()
  heartbeat = null
  lastSeen = 0
  closed = false
  senderId = 'sender-0'

  /** @param {string} host @param {number} port */
  connect (host, port = 8009, timeout = 10_000) {
    return new Promise((resolve, reject) => {
      // Cast devices use self-signed certificates: the identity check of the official senders (device auth) is
      // not needed to play media on the LAN.
      const socket = tls.connect({ host, port, rejectUnauthorized: false, timeout })
      this.socket = socket
      let settled = false
      socket.once('secureConnect', () => {
        settled = true
        socket.setTimeout(0)
        socket.setKeepAlive(true, 5000)
        this.lastSeen = Date.now()
        this.startHeartbeat()
        resolve()
      })
      socket.on('data', (chunk) => this.onData(chunk))
      socket.on('timeout', () => socket.destroy(new Error('Connection timed out')))
      socket.on('error', (error) => {
        debug('Socket error', error.message)
        if (!settled) {
          settled = true
          reject(error)
        }
        this.close(error.message)
      })
      socket.on('close', () => {
        if (!settled) {
          settled = true
          reject(new Error('Connection closed'))
        }
        this.close('closed')
      })
    })
  }

  get localAddress () {
    return this.socket?.localAddress?.replace(/^::ffff:/, '') || null
  }

  onData (chunk) {
    let frames
    try {
      frames = this.parser.push(chunk)
    } catch (error) {
      this.close(error.message)
      return
    }
    for (const body of frames) {
      let message
      try {
        message = decodeCastMessage(body)
      } catch (error) {
        debug('Bad message', error.message)
        continue
      }
      this.lastSeen = Date.now()
      const data = message.data
      if (message.namespace === NS.HEARTBEAT) {
        if (data?.type === 'PING') this.send(NS.HEARTBEAT, { type: 'PONG' }, message.source)
        continue
      }
      const requestId = data?.requestId
      if (requestId && this.pending.has(requestId)) {
        const pending = this.pending.get(requestId)
        this.pending.delete(requestId)
        clearTimeout(pending.timer)
        pending.resolve(data)
      }
      this.emit('message', message)
    }
  }

  send (namespace, data, destination = 'receiver-0', source = this.senderId) {
    if (this.closed || !this.socket) return false
    this.socket.write(frame({ source, destination, namespace, data }))
    return true
  }

  /** Sends a request with a requestId and resolves with the device answer carrying the same id. */
  request (namespace, data, destination = 'receiver-0', timeout = 15_000) {
    const requestId = this.requestId++
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new Error('Cast connection closed'))
      const timer = setTimeout(() => {
        this.pending.delete(requestId)
        reject(new Error(`Cast device did not answer ${data.type}`))
      }, timeout)
      this.pending.set(requestId, { resolve, reject, timer })
      this.send(namespace, { ...data, requestId }, destination)
    })
  }

  startHeartbeat () {
    clearInterval(this.heartbeat)
    this.heartbeat = setInterval(() => {
      if (Date.now() - this.lastSeen > 20_000) {
        this.close('The Cast device stopped responding')
        return
      }
      this.send(NS.HEARTBEAT, { type: 'PING' })
    }, 5000)
  }

  close (reason = 'closed') {
    if (this.closed) return
    this.closed = true
    clearInterval(this.heartbeat)
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(new Error(reason === 'closed' ? 'Cast connection closed' : reason))
    }
    this.pending.clear()
    try { this.socket?.destroy() } catch {}
    this.emit('close', reason)
  }
}
