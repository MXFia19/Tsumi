import { EventEmitter } from 'events'

import P2PT from 'p2pt'

import Event, { EventTypes } from '@/routes/w2g/components/events.js'
import Helper from '@/modules/helper.js'
import { generateRandomHexCode } from '@/modules/util.js'
import { writable } from 'simple-store-svelte'
import Debug from 'debug'
const debug = Debug('ui:w2g')

/**
 * @typedef {Record<string, {user: import('@/modules/al.d.ts').Viewer | {id: string }, peer?: import('p2pt').Peer<any>}>} PeerList
 * @typedef {{ media: object, episode: number | { number: number, season?: number, localEpisode?: number }, key: string }} SharedMedia
 */

/** Unique id of a title + episode, used to avoid re-sharing what everyone already plays. */
function mediaKey ({ media, episode }) {
  const ep = typeof episode === 'object' && episode !== null
    ? `${episode.season ?? ''}:${episode.localEpisode ?? episode.number}`
    : String(episode)
  return `${media?.id}:${ep}`
}

/**
 * Watch Together lobby: participants find each other through public WebSocket
 * signaling servers (P2PT), then talk directly over WebRTC. Nothing but small
 * JSON events (who is here, what is playing, play/pause/time, chat) is exchanged.
 */
export class W2GClient extends EventEmitter {
  static #signalingServers = [
    'wss://tracker.openwebtorrent.com',
    'wss://tracker.webtorrent.dev',
    'wss://tracker.files.fm:7073/announce',
    'wss://tracker.btorrent.xyz/'
  ]

  player = {
    paused: true,
    time: 0
  }

  /** @type {{ index: number }} position in the player's file list */
  index = { index: 0 }
  /** @type {SharedMedia | null} what the lobby is currently watching */
  media = null
  isHost = false
  #p2pt
  code
  /** @type {import('simple-store-svelte').Writable<{message: string, user: import('@/modules/al.d.ts').Viewer | {id: string }, type: 'incoming' | 'outgoing', date: Date}[]>} */
  messages = writable([])

  self = Helper.getUser() || { id: generateRandomHexCode(16) }
  /** @type {import('simple-store-svelte').Writable<PeerList>} */
  peers = writable({ [this.self.id]: { user: this.self } })

  get inviteLink () {
    return `tsumi://w2g/${this.code}`
  }

  /**
   * @param {string} [code] lobby code, omit to create a new lobby
   */
  constructor (code) {
    super()
    this.isHost = !code

    this.code = code ?? generateRandomHexCode(16)

    debug(`W2GClient: ${this.code}, ${this.isHost}`)

    this.#p2pt = new P2PT(W2GClient.#signalingServers, this.code)

    this.#wireEvents()
    this.#p2pt.start()
  }

  /**
   * A title/episode was started locally: share it so the others start it too.
   * @param {{ media: object, episode: SharedMedia['episode'] }} shared
   */
  shareMedia ({ media, episode }) {
    const next = { media, episode, key: mediaKey({ media, episode }) }
    debug(`shareMedia: ${this.media?.key} -> ${next.key}`)
    if (this.media?.key === next.key) return
    this.media = next
    this.#sendToPeers(new Event(EventTypes.MediaEvent, next))
  }

  /** @param {{ index: number }} index */
  mediaIndexChanged (index) {
    debug(`mediaIndexChanged: ${JSON.stringify(this.index)} ${JSON.stringify(index)}`)
    if (this.index?.index !== index?.index) {
      this.index = index
      this.#sendToPeers(new Event(EventTypes.MediaIndexEvent, index))
    }
  }

  _playerStateChanged (state) {
    debug(`_playerStateChanged: ${this.player?.paused} ${state?.paused} ${this.player?.time} ${state?.time}`)
    if (!state) return false
    if (this.player.paused !== state.paused || this.player.time !== state.time) {
      this.player = state
      return true
    }
    return false
  }

  playerStateChanged (state) {
    debug(`playerStateChanged: ${JSON.stringify(state)}`)
    if (this._playerStateChanged(state)) this.#sendToPeers(new Event(EventTypes.PlayerStateEvent, state))
  }

  message (message) {
    debug(`message: ${message}`)
    this.messages.update(messages => [...messages, ({
      message,
      user: this.self,
      type: 'outgoing',
      date: new Date()
    })])
    this.#sendToPeers(new Event(EventTypes.MessageEvent, message))
  }

  #wireEvents () {
    this.#p2pt.on('peerconnect', this.#onPeerconnect.bind(this))
    this.#p2pt.on('msg', this.#onMsg.bind(this))
    this.#p2pt.on('peerclose', this.#onPeerclose.bind(this))
  }

  /**
   * @param {import('p2pt').Peer} peer
   * @param {import('./events.js').default} event
   */
  #sendEvent (peer, event) {
    debug(`#sendEvent: ${peer.id} ${JSON.stringify(event)}`)
    this.#p2pt?.send(peer, JSON.stringify(event))
  }

  /**
   * Brings a newly connected participant up to date. Should be called only on 'peerconnect'.
   * @param {import('p2pt').Peer} peer
   */
  #sendInitialSessionState (peer) {
    if (this.media) this.#sendEvent(peer, new Event(EventTypes.MediaEvent, this.media))
    this.#sendEvent(peer, new Event(EventTypes.MediaIndexEvent, this.index))
    this.#sendEvent(peer, new Event(EventTypes.PlayerStateEvent, this.player))
  }

  #onPeerconnect (peer) {
    debug(`#onPeerconnect: ${peer.id}`)
    this.#sendEvent(peer, new Event(EventTypes.SessionInitEvent, this.self))

    if (this.isHost) this.#sendInitialSessionState(peer)
  }

  /**
   * @param {import('p2pt').Peer} peer
   * @param {Event | string} data
   */
  #onMsg (peer, data) {
    debug(`#onMsg: ${peer.id} ${JSON.stringify(data)}`)
    try {
      data = typeof data === 'string' ? JSON.parse(data) : data
    } catch (error) {
      debug('Ignoring malformed message', error)
      return
    }

    switch (data?.type) {
      case EventTypes.SessionInitEvent:
        this.peers.update(peers => {
          peers[peer.id] = {
            peer,
            user: data.payload
          }
          return peers
        })
        break
      case EventTypes.MediaEvent: {
        const shared = data.payload
        if (!shared?.media?.id || shared.key === this.media?.key) break
        this.media = { ...shared, key: mediaKey(shared) }
        this.emit('media', this.media)
        break
      }
      case EventTypes.MediaIndexEvent: {
        if (data.payload?.index == null) break
        if (this.index?.index !== data.payload.index) {
          this.index = data.payload
          this.emit('index', data.payload.index)
        }
        break
      }
      case EventTypes.PlayerStateEvent: {
        if (data.payload?.time == null) break
        if (this._playerStateChanged(data.payload)) this.emit('player', data.payload)
        break
      }
      case EventTypes.MessageEvent: {
        // A message can arrive before the sender introduced itself.
        const user = this.peers.value[peer.id]?.user || { id: peer.id }
        this.messages.update(messages => [...messages, ({ message: data.payload, user, type: 'incoming', date: new Date() })])
        break
      }
      default:
        debug('Ignoring unknown message type', data)
    }
  }

  #onPeerclose (peer) {
    debug(`#onPeerclose: ${peer.id}`)
    this.peers.update(peers => {
      delete peers[peer.id]
      return peers
    })
  }

  /** @param {import('./events.js').default} event */
  #sendToPeers (event) {
    if (!this.#p2pt) return
    for (const { peer } of Object.values(this.peers.value)) {
      if (peer) this.#sendEvent(peer, event)
    }
  }

  destroy () {
    debug('destroy')
    this.#p2pt?.destroy()
    this.removeAllListeners()
    this.#p2pt = null
    this.isHost = false
    this.peers.value = {}
  }
}
