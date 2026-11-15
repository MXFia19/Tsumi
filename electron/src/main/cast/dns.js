// Minimal DNS message codec for mDNS service discovery (RFC 1035, RFC 6762): encodes questions and decodes the
// A / AAAA / PTR / SRV / TXT records that Cast devices answer with. Pure (Buffer only), tested by dns.test.mjs.

export const TYPE = { A: 1, PTR: 12, TXT: 16, AAAA: 28, SRV: 33, ANY: 255 }

const CLASS_IN = 1
// Top bit of the question class: "unicast response requested" (QU) in mDNS. Top bit of a record class: cache flush.
const CLASS_FLAG = 0x8000

function encodeName (name) {
  const labels = String(name).replace(/\.$/, '').split('.').filter(Boolean)
  const parts = []
  for (const label of labels) {
    const bytes = Buffer.from(label, 'utf8')
    if (bytes.length > 63) throw new Error(`DNS label too long: ${label}`)
    parts.push(Buffer.from([bytes.length]), bytes)
  }
  parts.push(Buffer.from([0]))
  return Buffer.concat(parts)
}

/**
 * @param {{ name: string, type: number, unicastResponse?: boolean }[]} questions
 * @param {number} [id] message id (0 for mDNS; legacy unicast responders echo it)
 */
export function encodeQuery (questions, id = 0) {
  const header = Buffer.alloc(12)
  header.writeUInt16BE(id & 0xffff, 0)
  header.writeUInt16BE(0, 2) // standard query
  header.writeUInt16BE(questions.length, 4)
  const parts = [header]
  for (const question of questions) {
    parts.push(encodeName(question.name))
    const tail = Buffer.alloc(4)
    tail.writeUInt16BE(question.type, 0)
    tail.writeUInt16BE(CLASS_IN | (question.unicastResponse ? CLASS_FLAG : 0), 2)
    parts.push(tail)
  }
  return Buffer.concat(parts)
}

/** Reads a (possibly compressed) domain name. Returns the name and the offset right after it in the message. */
export function decodeName (buf, offset) {
  const labels = []
  let position = offset
  let end = -1
  let jumps = 0
  for (;;) {
    if (position >= buf.length) throw new Error('DNS name out of range')
    const length = buf[position]
    if (length === 0) {
      position += 1
      break
    }
    if ((length & 0xc0) === 0xc0) {
      if (position + 1 >= buf.length) throw new Error('DNS pointer out of range')
      if (end === -1) end = position + 2
      position = ((length & 0x3f) << 8) | buf[position + 1]
      if (++jumps > 64) throw new Error('DNS compression loop')
      continue
    }
    if ((length & 0xc0) !== 0) throw new Error('Unsupported DNS label type')
    position += 1
    if (position + length > buf.length) throw new Error('DNS label out of range')
    labels.push(buf.toString('utf8', position, position + length))
    position += length
  }
  return { name: labels.join('.'), end: end === -1 ? position : end }
}

function decodeTxt (buf, start, end) {
  const strings = []
  const data = {}
  let position = start
  while (position < end) {
    const length = buf[position]
    position += 1
    const chunk = buf.subarray(position, Math.min(position + length, end))
    position += length
    strings.push(chunk)
    const text = chunk.toString('utf8')
    const separator = text.indexOf('=')
    if (separator > 0) data[text.slice(0, separator).toLowerCase()] = text.slice(separator + 1)
    else if (text) data[text.toLowerCase()] = true
  }
  return { strings, data }
}

function decodeRecord (buf, offset) {
  const { name, end } = decodeName(buf, offset)
  if (end + 10 > buf.length) throw new Error('DNS record out of range')
  const type = buf.readUInt16BE(end)
  const klass = buf.readUInt16BE(end + 2)
  const ttl = buf.readUInt32BE(end + 4)
  const length = buf.readUInt16BE(end + 8)
  const start = end + 10
  const stop = start + length
  if (stop > buf.length) throw new Error('DNS record data out of range')
  const record = { name, type, class: klass & ~CLASS_FLAG, flush: !!(klass & CLASS_FLAG), ttl, data: null }
  switch (type) {
    case TYPE.A:
      if (length === 4) record.data = `${buf[start]}.${buf[start + 1]}.${buf[start + 2]}.${buf[start + 3]}`
      break
    case TYPE.AAAA:
      if (length === 16) {
        const groups = []
        for (let i = 0; i < 16; i += 2) groups.push(buf.readUInt16BE(start + i).toString(16))
        record.data = groups.join(':')
      }
      break
    case TYPE.PTR:
      record.data = decodeName(buf, start).name
      break
    case TYPE.SRV:
      if (length >= 7) {
        record.data = {
          priority: buf.readUInt16BE(start),
          weight: buf.readUInt16BE(start + 2),
          port: buf.readUInt16BE(start + 4),
          target: decodeName(buf, start + 6).name
        }
      }
      break
    case TYPE.TXT:
      record.data = decodeTxt(buf, start, stop)
      break
    default:
      record.data = buf.subarray(start, stop)
  }
  return { record, end: stop }
}

/** Decodes a DNS message. Throws on truncated or malformed input. */
export function decodePacket (buf) {
  if (!buf || buf.length < 12) throw new Error('DNS message too short')
  const id = buf.readUInt16BE(0)
  const flags = buf.readUInt16BE(2)
  const counts = [buf.readUInt16BE(4), buf.readUInt16BE(6), buf.readUInt16BE(8), buf.readUInt16BE(10)]
  let offset = 12
  const questions = []
  for (let i = 0; i < counts[0]; i++) {
    const { name, end } = decodeName(buf, offset)
    if (end + 4 > buf.length) throw new Error('DNS question out of range')
    questions.push({ name, type: buf.readUInt16BE(end), class: buf.readUInt16BE(end + 2) & ~CLASS_FLAG })
    offset = end + 4
  }
  const sections = [[], [], []]
  for (let s = 0; s < 3; s++) {
    for (let i = 0; i < counts[s + 1]; i++) {
      const { record, end } = decodeRecord(buf, offset)
      sections[s].push(record)
      offset = end
    }
  }
  return {
    id,
    flags,
    isResponse: !!(flags & 0x8000),
    questions,
    answers: sections[0],
    authorities: sections[1],
    additionals: sections[2]
  }
}
