export default class Event {
  payload = null
  type = ''
  constructor (type, payload) {
    this.type = type
    this.payload = payload
  }
}

/** Wire event types, see ../PROTOCOL.md. */
export const EventTypes = {
  // v1
  SessionInitEvent: 'init',
  MediaEvent: 'media',
  MediaIndexEvent: 'index',
  PlayerStateEvent: 'player',
  MessageEvent: 'message',
  // v2
  HostEvent: 'host',
  StatusEvent: 'status',
  PingEvent: 'ping',
  PongEvent: 'pong',
  RequestEvent: 'request',
  RequestReplyEvent: 'requestReply',
  KickEvent: 'kick',
  ReactionEvent: 'reaction',
  CountdownEvent: 'countdown'
}

/** Type of the chat lines created locally (joins, leaves, actions, requests). Never sent. */
export const SYSTEM_MESSAGE = 'system'
