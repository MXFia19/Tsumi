import Foundation

// Watch Together v2.4 (PROTOCOL.md "v2.4 additions: voice chat and the shared queue"): the pure part, ported one to
// one from common/routes/w2g/components/sync.js (`normalizeFeatures`, `normalizeVoice`, `voiceOffers`,
// `voiceLinkAction`, `acceptsVoiceOffer`, `voiceRetryDelay`, `voiceTransmitting`, `speakingStep`, `duckLevel`,
// `normalizeQueue*`, `sameQueueEntry`, `queueReduce`, `queueChanges`, `queueItemLabel`, `describeQueueChange`,
// `nextEpisodeOf`, `nextEpisodeTarget`, `acceptsQueue`, `appliesCountdown`), same thresholds and texts.

extension W2GSync {
  /// `init.features` sent by this client.
  static let features = ["voice", "queue"]

  /// A transmitting microphone whose peak level reaches this is speaking...
  static let voiceSpeakingLevel: Double = 0.05
  /// ... until it stayed below for this long.
  static let voiceSpeakingHoldMs: Double = 600
  /// Ducking: the video plays at this fraction of its volume while someone speaks.
  static let voiceDuckLevel: Double = 0.3
  /// No trickle: the description is sent this long after the first candidate if gathering is not complete...
  static let voiceGatherAfterCandidateSeconds: Double = 3
  /// ... and after this long at most.
  static let voiceGatherMaxSeconds: Double = 8
  /// A link not connected this long after the offer failed.
  static let voiceConnectTimeoutSeconds: Double = 20
  /// The offerer retries a failed link after this delay, at most `voiceMaxRetries` times in a row.
  static let voiceRetrySeconds: Double = 3
  static let voiceMaxRetries = 5
  /// Queue limits.
  static let queueMaxItems = 50
  static let queueMaxPending = 20
  /// Auto-advance: "Up next" waits this long before playing the first item.
  static let queueAdvanceSeconds: Double = 5
  /// Length of the countdown the host starts once a queued item is loaded.
  static let queueCountdownSeconds = 5

  /// v2.4: a `countdown` is applied only on the lobby media, or while playing nothing.
  static func appliesCountdown(localKey: String, lobbyKey: String?) -> Bool {
    guard !localKey.isEmpty, let lobbyKey, !lobbyKey.isEmpty else { return true }
    return sameMediaKey(localKey, lobbyKey)
  }

  /// `init.features`, cleaned: distinct short strings, empty when missing or malformed.
  static func normalizeFeatures(_ value: W2GJSON?) -> [String] {
    guard let items = value?.arrayValue else { return [] }
    var result: [String] = []
    for item in items {
      guard let text = item.stringValue, !text.isEmpty, text.utf16.count <= 32, !result.contains(text) else { continue }
      result.append(text)
      if result.count == 16 { break }
    }
    return result
  }

  // MARK: Voice

  /// `voice` payload, cleaned: `speaking` is false unless joined and not muted.
  static func normalizeVoice(_ payload: W2GJSON?) -> W2GVoiceState {
    let joined = payload?["joined"]?.boolValue == true
    let muted = payload?["muted"]?.boolValue == true
    return W2GVoiceState(joined: joined, muted: muted, speaking: joined && !muted && payload?["speaking"]?.boolValue == true)
  }

  /// Of two members in voice, the one with the smaller userId (JS string order) sends the offer.
  static func voiceOffers(selfId: String, otherId: String) -> Bool {
    jsLess(selfId, otherId)
  }

  /// What to do with the audio link to one member.
  static func voiceLinkAction(selfJoined: Bool, memberJoined: Bool, memberHasVoice: Bool, hasLink: Bool, selfOffers: Bool) -> W2GVoiceLinkAction {
    guard selfJoined && memberJoined && memberHasVoice else { return hasLink ? .close : .none }
    if hasLink { return .none }
    return selfOffers ? .offer : .wait
  }

  /// An incoming offer is taken when both are in voice and the sender is the offerer.
  static func acceptsVoiceOffer(selfJoined: Bool, memberJoined: Bool, selfId: String, senderId: String) -> Bool {
    selfJoined && memberJoined && voiceOffers(selfId: senderId, otherId: selfId)
  }

  /// Delay before the offerer re-offers a failed link (seconds), nil when it gave up.
  static func voiceRetryDelay(failures: Int) -> Double? {
    failures <= voiceMaxRetries ? voiceRetrySeconds : nil
  }

  /// The microphone sends sound: in voice, with a microphone, not muted, and the hold-to-talk button held if on.
  static func voiceTransmitting(joined: Bool, hasMic: Bool, muted: Bool, pushToTalk: Bool, held: Bool) -> Bool {
    joined && hasMic && !muted && (!pushToTalk || held)
  }

  /// Speaking detection on our own microphone (peak level 0-1), called about every 100 ms.
  static func speakingStep(_ memory: W2GSpeakingMemory, level: Double?, transmitting: Bool, now: Double) -> W2GSpeakingMemory {
    guard transmitting else { return W2GSpeakingMemory() }
    if let level, level.isFinite, level >= voiceSpeakingLevel {
      return W2GSpeakingMemory(speaking: true, lastLoudAt: now)
    }
    let lastLoudAt = memory.lastLoudAt
    return W2GSpeakingMemory(speaking: now - lastLoudAt < voiceSpeakingHoldMs, lastLoudAt: lastLoudAt)
  }

  /// Video volume factor: lowered while we are in voice and another member we hear is speaking.
  static func duckLevel(enabled: Bool, selfJoined: Bool, members: [W2GDuckCandidate]) -> Double {
    guard enabled, selfJoined else { return 1 }
    let heard = members.contains { $0.joined && $0.speaking && !$0.localMuted && $0.volume > 0 }
    return heard ? voiceDuckLevel : 1
  }

  // MARK: Queue

  /// `String(value)` of an id: a non-empty string or a finite number (max 64), nil otherwise.
  static func queueId(_ value: W2GJSON?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string(let units):
      guard !units.isEmpty else { return nil }
      return String(String(decoding: units, as: UTF16.self).prefix(64))
    case .number(let number):
      guard number.isFinite else { return nil }
      return String(W2GJSON.jsNumberString(number).prefix(64))
    default:
      return nil
    }
  }

  /// Trimmed text, at most `max` characters, "" when not a string.
  static func queueText(_ value: W2GJSON?, max: Int) -> String {
    guard let text = value?.stringValue else { return "" }
    return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
  }

  /// Episode of a queue item: a number, or `{ number, season?, localEpisode? }`; nil when unusable.
  static func normalizeQueueEpisode(_ value: W2GJSON?) -> W2GJSON? {
    guard let value else { return nil }
    // v2.5: episode, season and local episode numbers are within 0…maxEpisode.
    func valid(_ json: W2GJSON?) -> Double? {
      guard let number = json?.doubleValue, number >= 0, number <= maxEpisode else { return nil }
      return number
    }
    switch value {
    case .number:
      return valid(value) != nil ? value : nil
    case .string:
      guard let text = value.stringValue, !text.isEmpty, text.count <= 7, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(text), number <= maxEpisode else { return nil }
      return .number(number)
    case .object:
      let number = valid(value["number"]) ?? valid(value["localEpisode"])
      guard let number else { return nil }
      var fields: [(String, W2GJSON?)] = [("number", .number(number))]
      if let season = valid(value["season"]) { fields.append(("season", .number(season))) }
      if let local = valid(value["localEpisode"]) { fields.append(("localEpisode", .number(local))) }
      return W2GJSON.dict(fields)
    default:
      return nil
    }
  }

  /// "season:episode" identity of an episode value, the same for `5` and `{ number: 5 }`.
  static func episodeIdentity(_ value: W2GJSON?) -> String? {
    guard let episode = normalizeQueueEpisode(value) else { return nil }
    if case .number(let number) = episode { return ":" + W2GJSON.jsNumberString(number) }
    let season = episode["season"].map { W2GJSON.jsTemplateString($0) } ?? ""
    return season + ":" + W2GJSON.jsTemplateString(episode["localEpisode"] ?? episode["number"])
  }

  /// Same title and episode, even when two apps wrote the key differently ("21:5" / "21::5").
  static func sameQueueEntry(key: String, mediaId: W2GJSON?, episode: W2GJSON?, as other: W2GQueueItem) -> Bool {
    if !key.isEmpty && !other.key.isEmpty && sameMediaKey(key, other.key) { return true }
    guard let id = queueId(mediaId), id == queueId(other.mediaJSON["id"]) else { return false }
    guard let identity = episodeIdentity(episode) else { return false }
    return identity == episodeIdentity(other.episodeJSON)
  }

  /// `queue` payload, cleaned (no duplicate id, within the limits); nil when not an object.
  static func normalizeQueue(_ payload: W2GJSON?) -> W2GQueue? {
    guard let payload, payload.isObject else { return nil }
    var seen = Set<String>()
    func clean(_ list: W2GJSON?, max: Int) -> [W2GQueueItem] {
      var items: [W2GQueueItem] = []
      for raw in list?.arrayValue ?? [] {
        guard let item = W2GQueueItem(json: raw), !seen.contains(item.id) else { continue }
        seen.insert(item.id)
        items.append(item)
      }
      return Array(items.prefix(max))
    }
    let items = clean(payload["items"], max: queueMaxItems)
    let pending = clean(payload["pending"], max: queueMaxPending)
    let policy: W2GQueuePolicy = payload["policy"]?.stringValue == "approval" ? .approval : .open
    // v2.5: a whole number in range (Int(1e300) trapped and crashed the app).
    let rev = payload["rev"]?.doubleValue.map { Int(min(max($0, 0), Double(Int32.max)).rounded(.towardZero)) } ?? 0
    return W2GQueue(items: items, pending: pending, policy: policy, rev: rev)
  }

  /// One change of the queue, applied by the host. Returns the new queue (rev + 1), nil when nothing changed.
  static func queueReduce(_ queue: W2GQueue, _ change: W2GQueueChange) -> W2GQueue? {
    var next = queue
    switch change {
    case .add(let raw, let by, let byName, let byHost):
      guard var item = W2GQueueItem(json: raw) else { return nil }
      let all = queue.items + queue.pending
      if all.contains(where: { $0.id == item.id || sameQueueEntry(key: item.key, mediaId: item.mediaJSON["id"], episode: item.episodeJSON, as: $0) }) { return nil }
      item.addedBy = by
      if !byName.isEmpty { item.addedByName = String(byName.prefix(64)) }
      item.votes = []
      if byHost || queue.policy == .open {
        guard queue.items.count < queueMaxItems else { return nil }
        next.items.append(item)
      } else {
        guard queue.pending.count < queueMaxPending else { return nil }
        next.pending.append(item)
      }
    case .vote(let id, let by, let up):
      guard let index = queue.items.firstIndex(where: { $0.id == id }) else { return nil }
      let has = queue.items[index].votes.contains(by)
      guard has != up else { return nil }
      if up {
        next.items[index].votes.append(by)
      } else {
        next.items[index].votes.removeAll { $0 == by }
      }
    case .remove(let id, let by, let byHost):
      let allowed: (W2GQueueItem) -> Bool = { $0.id == id && (byHost || $0.addedBy == by) }
      next.items.removeAll(where: allowed)
      next.pending.removeAll(where: allowed)
      guard next.items.count != queue.items.count || next.pending.count != queue.pending.count else { return nil }
    case .move(let id, let delta):
      guard let index = queue.items.firstIndex(where: { $0.id == id }) else { return nil }
      let target = max(0, min(queue.items.count - 1, index + delta))
      guard target != index else { return nil }
      let item = next.items.remove(at: index)
      next.items.insert(item, at: target)
    case .answer(let id, let accepted):
      guard let index = queue.pending.firstIndex(where: { $0.id == id }) else { return nil }
      let item = next.pending.remove(at: index)
      if accepted && queue.items.count < queueMaxItems { next.items.append(item) }
    case .policy(let policy):
      guard policy != queue.policy else { return nil }
      next.policy = policy
    }
    next.rev = queue.rev + 1
    return next
  }

  /// What a new `queue` adds to the chat, compared with the previous one (none for the first one).
  static func queueChanges(previous: W2GQueue?, next: W2GQueue, selfId: String, cancelled: Set<String>) -> [W2GQueueChangeLine] {
    guard let previous else { return [] }
    let before = Set(previous.items.map { $0.id })
    let beforePending = Set(previous.pending.map { $0.id })
    let nowIds = Set((next.items + next.pending).map { $0.id })
    var changes: [W2GQueueChangeLine] = []
    for item in next.items where !before.contains(item.id) { changes.append(W2GQueueChangeLine(kind: .added, item: item)) }
    for item in next.pending where !beforePending.contains(item.id) && !before.contains(item.id) {
      changes.append(W2GQueueChangeLine(kind: .suggested, item: item))
    }
    for item in previous.pending where !nowIds.contains(item.id) && item.addedBy == selfId && !cancelled.contains(item.id) {
      changes.append(W2GQueueChangeLine(kind: .declined, item: item))
    }
    return changes
  }

  /// Chat line of a queue change.
  static func describeQueueChange(_ change: W2GQueueChangeLine, selfId: String) -> String {
    let label = change.item.label
    let name = change.item.addedBy == selfId ? "You" : (change.item.addedByName.isEmpty ? "Someone" : change.item.addedByName)
    switch change.kind {
    case .added: return "\(name) added \(label) to Up next"
    case .suggested: return "\(name) suggested \(label)"
    case .declined: return "The host declined your suggestion: \(label)"
    }
  }

  /// The episode after `episode`; nil past the known episode count (a movie has none).
  static func nextEpisode(of episode: W2GJSON?, episodes: Int?) -> W2GJSON? {
    guard let value = normalizeQueueEpisode(episode) else { return nil }
    if case .number(let number) = value {
      let next = number + 1
      if let episodes, episodes > 0, next > Double(episodes) { return nil }
      return .number(next)
    }
    let number = (value["number"]?.doubleValue ?? 0) + 1
    var fields: [(String, W2GJSON?)] = [("number", .number(number))]
    if let season = value["season"]?.doubleValue { fields.append(("season", .number(season))) }
    if let local = value["localEpisode"]?.doubleValue { fields.append(("localEpisode", .number(local + 1))) }
    return W2GJSON.dict(fields)
  }

  /// "Add next episode": after the last queued (or suggested) episode of the lobby title, else after the lobby media.
  static func nextEpisodeTarget(lobbyMedia: W2GJSON?, lobbyEpisode: W2GJSON?, queue: W2GQueue) -> (media: W2GJSON, episode: W2GJSON)? {
    guard let media = lobbyMedia, let mediaId = queueId(media["id"]) else { return nil }
    func number(_ value: W2GJSON?) -> Double {
      guard let episode = normalizeQueueEpisode(value) else { return -Double.infinity }
      if case .number(let number) = episode { return number }
      return episode["number"]?.doubleValue ?? -Double.infinity
    }
    var base = lobbyEpisode
    for item in queue.items + queue.pending where queueId(item.mediaJSON["id"]) == mediaId {
      if number(item.episodeJSON) > number(base) { base = item.episodeJSON }
    }
    let isMovie = media["format"]?.stringValue == "MOVIE"
    let count = media["episodes"]?.intValue
    let episodes: Int? = isMovie && !((count ?? 0) > 1) ? 1 : count
    guard let episode = nextEpisode(of: base, episodes: episodes) else { return nil }
    return (media: media, episode: episode)
  }

  /// A `queue` is taken from the current host, or from anyone while no host is known or it is provisional.
  static func acceptsQueue(senderId: String, hostId: String?, tentative: Bool) -> Bool {
    guard let hostId else { return true }
    return tentative || senderId == hostId
  }
}

// MARK: - v2.4 values

/// A member's last `voice` (`{ joined, muted, speaking }`).
struct W2GVoiceState: Equatable {
  var joined = false
  var muted = false
  var speaking = false

  /// Our `voice` payload while not in voice.
  static let off = W2GVoiceState(joined: false, muted: true, speaking: false)

  var json: W2GJSON {
    .dict([("joined", .bool(joined)), ("muted", .bool(muted)), ("speaking", .bool(speaking))])
  }
}

enum W2GVoiceLinkAction: Equatable {
  /// We create the link.
  case offer
  /// The member will offer.
  case wait
  case close
  case none
}

struct W2GSpeakingMemory: Equatable {
  var speaking = false
  var lastLoudAt: Double = -Double.infinity
}

/// Another member, for ducking.
struct W2GDuckCandidate: Equatable {
  var joined: Bool
  var speaking: Bool
  var localMuted: Bool
  var volume: Double
}

/// Local mute / volume of a member's voice (only for us).
struct W2GVoiceMix: Equatable {
  var muted = false
  /// 0-1
  var volume: Double = 1
}

/// Voice of a member row.
struct W2GMemberVoice: Equatable {
  var joined = false
  var muted = false
  var speaking = false
  /// The audio link with that member is connected (nil for ourselves or without a link).
  var connected: Bool?
  var mix = W2GVoiceMix()

  static let off = W2GMemberVoice()
}

/// Our own voice state, for the views.
struct W2GVoiceView: Equatable {
  var joined = false
  var starting = false
  var hasMic = false
  var muted = false
  var pushToTalk = false
  var held = false
  var transmitting = false
  var speaking = false
  var error: String?
}

enum W2GQueuePolicy: String {
  case open
  case approval
}

/// One "Up next" item (PROTOCOL.md v2.4 "Item").
struct W2GQueueItem: Identifiable, Equatable {
  var id: String
  /// The shared media shape of the `media` event, kept verbatim.
  var mediaJSON: W2GJSON
  /// A number or `{ number, season?, localEpisode? }`.
  var episodeJSON: W2GJSON
  var key: String
  var title: String
  var cover: String
  var addedBy: String
  var addedByName: String
  var votes: [String]

  /// Cleaned from a payload; nil without an id, a media with an id, an episode or a key.
  init?(json: W2GJSON) {
    guard json.isObject, let id = W2GSync.queueId(json["id"]) else { return nil }
    // v2.5: the shared media shape only (W2GSync.cleanMedia), like every media a peer sends.
    guard let media = W2GSync.cleanMedia(json["media"]), W2GSync.queueId(media["id"]) != nil else { return nil }
    guard let episode = W2GSync.normalizeQueueEpisode(json["episode"]) else { return nil }
    let key = W2GSync.queueText(json["key"], max: 200)
    guard !key.isEmpty else { return nil }
    self.id = id
    mediaJSON = media
    episodeJSON = episode
    self.key = key
    title = W2GSync.queueText(json["title"], max: 120)
    // v2.6: an http(s) image URL of at most 500 characters, like every other image, else none.
    cover = W2GSync.cleanURL(json["cover"], max: 500) ?? ""
    addedBy = W2GSync.queueId(json["addedBy"]) ?? ""
    addedByName = W2GSync.queueText(json["addedByName"], max: 64)
    var votes: [String] = []
    for vote in json["votes"]?.arrayValue ?? [] {
      guard let value = W2GSync.queueId(vote), !votes.contains(value) else { continue }
      votes.append(value)
      if votes.count == 64 { break }
    }
    self.votes = votes
  }

  /// Payload; `votes` only in `queue`.
  func json(withVotes: Bool = true) -> W2GJSON {
    var fields: [(String, W2GJSON?)] = []
    fields.append(("id", .text(id)))
    fields.append(("media", mediaJSON))
    fields.append(("episode", episodeJSON))
    fields.append(("key", .text(key)))
    fields.append(("title", .text(title)))
    fields.append(("cover", .text(cover)))
    fields.append(("addedBy", .text(addedBy)))
    fields.append(("addedByName", .text(addedByName)))
    if withVotes { fields.append(("votes", .array(votes.map { W2GJSON.text($0) }))) }
    return W2GJSON.dict(fields)
  }

  /// The media as the native model, for playing it.
  var media: Media? { W2GMediaPayload.media(from: mediaJSON) }
  var episode: EpisodeRef { W2GMediaPayload.episodeRef(from: episodeJSON) ?? EpisodeRef(number: 1) }
  var coverURL: URL? { URL(string: cover) }

  /// "Episode 5", "S2 E5" or "Movie".
  var episodeLabel: String {
    let ref = episode
    return W2GSync.nowPlayingEpisode(
      isMovie: mediaJSON["format"]?.stringValue == "MOVIE",
      episodes: mediaJSON["episodes"]?.intValue,
      number: ref.number,
      season: ref.season,
      localEpisode: ref.localEpisode
    )
  }

  /// "Title · Episode 5"
  var label: String {
    W2GSync.formatSource([title.isEmpty ? "a title" : title, episodeLabel])
  }

  static func == (lhs: W2GQueueItem, rhs: W2GQueueItem) -> Bool {
    lhs.id == rhs.id && lhs.key == rhs.key && lhs.title == rhs.title && lhs.cover == rhs.cover
      && lhs.addedBy == rhs.addedBy && lhs.addedByName == rhs.addedByName && lhs.votes == rhs.votes
  }
}

struct W2GQueue: Equatable {
  var items: [W2GQueueItem] = []
  var pending: [W2GQueueItem] = []
  var policy: W2GQueuePolicy = .open
  var rev = 0

  var json: W2GJSON {
    .dict([
      ("items", .array(items.map { $0.json() })),
      ("pending", .array(pending.map { $0.json() })),
      ("policy", .text(policy.rawValue)),
      ("rev", .int(rev))
    ])
  }
}

/// One change the host applies to the queue (sync.js queueReduce).
enum W2GQueueChange {
  case add(item: W2GJSON, by: String, byName: String, byHost: Bool)
  case vote(id: String, by: String, up: Bool)
  case remove(id: String, by: String, byHost: Bool)
  case move(id: String, delta: Int)
  case answer(id: String, accepted: Bool)
  case policy(W2GQueuePolicy)
}

struct W2GQueueChangeLine: Equatable {
  enum Kind: Equatable {
    case added
    case suggested
    case declined
  }

  var kind: Kind
  var item: W2GQueueItem
}

/// Result of "Add to Watch Together queue" (session.js queueResultText).
enum W2GQueueAddResult: Equatable {
  case added
  case suggested
  case duplicate
  case unavailable

  var text: String {
    switch self {
    case .added: return "Added to Up next"
    case .suggested: return "Suggested to the host"
    case .duplicate: return "Already in Up next"
    case .unavailable: return "The lobby has no queue"
    }
  }
}

/// Host: "Up next: …" counting down before the first item plays.
struct W2GAdvance: Equatable {
  var item: W2GQueueItem
  /// ms, local clock.
  var endsAt: Double
}
