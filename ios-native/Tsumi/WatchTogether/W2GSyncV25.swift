import Foundation

// Watch Together v2.5 (common/routes/w2g/PROTOCOL.md "v2.5 additions"): the pure part, ported one to one from
// common/routes/w2g/components/sync.js (`validateEvent` and its cleaners, the transport limits, `memberKey`, `pairIds`,
// `resolveHostKey`, `nextRtt`, `rateStep`, `parseLobbyCode`, `iceServers`, `indexKind`, `sameEpisode`, `remoteName`,
// `differentRate`), same limits and texts.

extension W2GSync {
  /// Longest event, in UTF-16 code units of its JSON text, checked before parsing.
  static let maxEventUnits = 256_000
  /// P2PT chunk index `c` must be below this (chunks are 16000 units).
  static let maxChunks = 64
  /// Messages being reassembled at once per peer...
  static let maxPendingMessages = 4
  /// ... each dropped when its last chunk did not come within this time ...
  static let chunkTimeoutMs: Double = 30_000
  /// ... and every peer together buffers at most this many units.
  static let maxBufferedUnits = 2_000_000
  /// Media positions (seconds) are taken in 0…maxTimeSeconds (about 115 days).
  static let maxTimeSeconds: Double = 1e7
  /// Episode, season and local episode numbers are taken in 0…maxEpisode.
  static let maxEpisode: Double = 1e6
  /// `index` is a whole number in 0…maxIndex.
  static let maxIndex = 9_999
  /// Longest chat message.
  static let maxChatLength = 2048
  /// Longest SDP of a `voiceSignal`.
  static let maxSdpLength = 64_000
  /// Longest media key.
  static let maxKeyLength = 200
  /// A tentative host that did not claim the role this long after the election is skipped (the election runs again).
  static let tentativeHostMs: Double = 10_000
  /// Round-trip samples above this are dropped (a pong held up while the app was suspended)...
  static let maxRttMs: Double = 5_000
  /// ... the others are smoothed, with this weight for the new sample.
  static let rttSmoothing: Double = 0.3
  /// Events a member makes by hand: a burst of `rateBurst`, then `ratePerSecond` per second, per member.
  static let userEvents: Set<String> = ["message", "reaction", "request", "invite", "queueAdd", "queueVote", "queueRemove"]
  static let rateBurst: Double = 20
  static let ratePerSecond: Double = 5

  // MARK: Identity

  /// v2.5 member key: who a member is on this device. Two devices of one account share a userId, but each sends its own
  /// `init.sessionId`; an older client sends none and its key is its userId. "#" sorts below the characters of the ids,
  /// so keys sort like their userIds and elections stay the same.
  static func memberKey(userId: String, sessionId: String?) -> String {
    guard let sessionId, !sessionId.isEmpty else { return userId }
    return userId + "#" + sessionId
  }

  /// The two ids compared between two members to pick the voice offerer: their keys when both send a session id, else
  /// their userIds (what an older client compares).
  static func pairIds(selfId: String, selfSession: String?, otherId: String, otherSession: String?) -> (String, String) {
    if let selfSession, !selfSession.isEmpty, let otherSession, !otherSession.isEmpty {
      return (memberKey(userId: selfId, sessionId: selfSession), memberKey(userId: otherId, sessionId: otherSession))
    }
    return (selfId, otherId)
  }

  /// Member key of the host a `host` event names: with `hostSession` that device; without (older sender) the sender when
  /// it names its own userId, else the smallest key with that userId (ourselves included), else the userId.
  static func resolveHostKey(hostId: String, hostSession: String?, senderKey: String, senderUserId: String, members: [(key: String, userId: String)]) -> String {
    if let hostSession, !hostSession.isEmpty { return memberKey(userId: hostId, sessionId: hostSession) }
    if senderUserId == hostId { return senderKey }
    return electHost(members.filter { $0.userId == hostId }.map { $0.key }) ?? hostId
  }

  /// sync.js remoteName: another member's name, which can't pass for us ("You paused at…").
  static func remoteName(_ user: W2GUser) -> String {
    let name = user.displayName
    guard name.lowercased() == "you" else { return name }
    return "\(name) (\(user.id.isEmpty ? "guest" : String(user.id.prefix(4))))"
  }

  // MARK: Sync

  /// "1.25×"
  static func formatRate(_ rate: Double) -> String {
    let value = (normalizeRate(rate) * 100).rounded() / 100
    return W2GJSON.jsNumberString(value) + "\u{00D7}"
  }

  /// Two playback rates differ (a member at 1.25× drifts on its own, auto-sync can't fix it).
  static func differentRate(_ a: Double, _ b: Double) -> Bool {
    abs(normalizeRate(a) - normalizeRate(b)) > 0.001
  }

  /// v2.5 RTT after a `pong`: nil (keep the previous one) when the sample is negative, above maxRttMs, or for a ping
  /// sent before `resumedAt` (the app was suspended in between); otherwise smoothed with the previous value.
  static func nextRtt(previous: Double?, sentAt: Double, now: Double, resumedAt: Double) -> Double? {
    let sample = now - sentAt
    guard sample.isFinite, sample >= 0, sample <= maxRttMs, sentAt >= resumedAt else { return nil }
    guard let previous, previous.isFinite else { return sample }
    return previous + (sample - previous) * rttSmoothing
  }

  /// Token bucket of one member for `userEvents` (v2.6: W2GSync.rateLimits has the other buckets).
  static func rateStep(_ bucket: W2GRateBucket?, now: Double) -> W2GRateBucket {
    rateStep(bucket, now: now, limit: W2GRateLimit(burst: rateBurst, perSecond: ratePerSecond))
  }

  /// v2.5 meaning of an `index`: "file" (position in the desktop player's file list) or "episode" (position in this
  /// app's episode list). Without `kind`, what the sender's app meant: "episode" for the iOS app, "file" otherwise.
  static func indexKind(_ kind: String?, client: String?) -> String {
    if kind == "file" || kind == "episode" { return kind ?? "file" }
    return client == clientName ? "episode" : "file"
  }

  /// A `player`, `countdown` or `index` sent from another episode than ours is not applied. No check without a sent
  /// `mediaKey` (older app) or while our player plays nothing. v2.6: keys are compared canonically.
  static func sameEpisode(_ sentKey: String?, _ localKey: String) -> Bool {
    guard let sentKey, !sentKey.isEmpty, !localKey.isEmpty else { return true }
    return sameMediaKey(sentKey, localKey)
  }

  // MARK: Lobby code, ICE servers

  /// Lobby code in a typed code, an invite link (tsumi://w2g/CODE, …/w2g/?c=CODE) or any text: the first run of exactly
  /// 16 hex characters, in lower case (codes are generated in lower case and P2PT's swarm id is case sensitive).
  static func parseLobbyCode(_ text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: "(?:^|[^a-fA-F0-9])([a-fA-F0-9]{16})(?![a-fA-F0-9])") else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          let matchRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[matchRange]).lowercased()
  }

  /// `turn:` / `turns:` URLs of the TURN setting (several may be separated by commas or spaces).
  static func turnURLs(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).filter { item in
      let lower = item.lowercased()
      return !item.isEmpty && item.utf16.count <= 500 && (lower.hasPrefix("turn:") || lower.hasPrefix("turns:")) && item.count > 6
    }
  }

  // MARK: Validation

  /// A wire id (`userId`, `hostId`, request, item and offer ids): a non-empty string of at most 64 UTF-16 units or a
  /// finite number, as text. nil otherwise.
  static func wireId(_ value: W2GJSON?) -> String? {
    guard let value else { return nil }
    switch value {
    case .number(let number):
      return number.isFinite ? W2GJSON.jsNumberString(number) : nil
    case .string(let units):
      guard !units.isEmpty, units.count <= 64 else { return nil }
      return String(decoding: units, as: UTF16.self)
    default:
      return nil
    }
  }

  /// v2.5 `init.sessionId` (also `host.hostSession`, `invite.toSession`): 4 to 64 letters, digits, `-` or `_`.
  static func cleanSessionId(_ value: W2GJSON?) -> String? {
    guard let text = value?.stringValue, (4...64).contains(text.utf16.count) else { return nil }
    let allowed = text.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
    }
    return allowed ? text : nil
  }

  /// A media position in 0…maxTimeSeconds, nil otherwise.
  static func cleanTime(_ value: W2GJSON?) -> Double? {
    guard let time = value?.doubleValue, time >= 0, time <= maxTimeSeconds else { return nil }
    return time
  }

  /// An http(s) URL of at most `max` UTF-16 units, nil otherwise.
  static func cleanURL(_ value: W2GJSON?, max: Int = 1000) -> String? {
    guard let raw = value?.stringValue else { return nil }
    let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = url.lowercased()
    guard url.utf16.count <= max, lower.hasPrefix("http://") || lower.hasPrefix("https://"), url.count > 8 else { return nil }
    guard url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
    return url
  }

  /// A media key: "" when missing or longer than maxKeyLength.
  static func cleanKey(_ value: W2GJSON?) -> String {
    guard let value else { return "" }
    switch value {
    case .number(let number):
      return number.isFinite ? W2GJSON.jsNumberString(number) : ""
    case .string(let units):
      return units.count <= maxKeyLength ? String(decoding: units, as: UTF16.self) : ""
    default:
      return ""
    }
  }

  private static func matches(_ text: String, max: Int, extra: Set<Character>) -> Bool {
    guard !text.isEmpty, text.count <= max else { return false }
    return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
  }

  /// The shared media shape (session.js SHARED_MEDIA_FIELDS) rebuilt from what a peer sent: the known fields with the
  /// right types, http(s) URLs only. nil without a usable id (AniList number, or a short text id like "tmdb-123").
  static func cleanMedia(_ value: W2GJSON?) -> W2GJSON? {
    guard let value, value.isObject, let idValue = value["id"] else { return nil }
    var fields: [(String, W2GJSON?)] = []
    switch idValue {
    case .number(let number) where number.isFinite:
      fields.append(("id", idValue))
    case .string:
      let text = idValue.stringValue ?? ""
      guard matches(text, max: 64, extra: [":", ".", "_", "-"]), !reservedIds.contains(text) else { return nil }
      fields.append(("id", idValue))
    default:
      return nil
    }
    for field in ["idMal", "idTmdb", "episodes", "seasonYear", "duration", "averageScore"] {
      if let number = value[field]?.doubleValue { fields.append((field, .number(number))) }
    }
    if let flag = value["isTmdb"]?.boolValue { fields.append(("isTmdb", .bool(flag))) }
    for field in ["format", "status", "season"] {
      if let text = value[field]?.stringValue, matches(text, max: 32, extra: ["_"]), text.allSatisfy({ !$0.isNumber }) {
        fields.append((field, .text(text)))
      }
    }
    if let title = value["title"], title.isObject {
      var titles: [(String, W2GJSON?)] = []
      for field in ["romaji", "english", "native", "userPreferred"] {
        if let units = title[field]?.utf16Value { titles.append((field, .string(Array(units.prefix(300))))) }
      }
      fields.append(("title", .dict(titles)))
    }
    if let cover = value["coverImage"], cover.isObject {
      var covers: [(String, W2GJSON?)] = []
      for field in ["extraLarge", "large", "medium"] {
        if let url = cleanURL(cover[field]) { covers.append((field, .text(url))) }
      }
      if let color = cover["color"]?.stringValue, color.hasPrefix("#"), (4...9).contains(color.count), color.dropFirst().allSatisfy({ $0.isHexDigit }) {
        covers.append(("color", .text(color)))
      }
      fields.append(("coverImage", .dict(covers)))
    }
    if let banner = cleanURL(value["bannerImage"]) { fields.append(("bannerImage", .text(banner))) }
    if let genres = value["genres"]?.arrayValue {
      let kept = genres.compactMap { item -> W2GJSON? in
        guard let units = item.utf16Value, units.count <= 64 else { return nil }
        return .string(units)
      }
      fields.append(("genres", .array(Array(kept.prefix(32)))))
    }
    return .dict(fields)
  }

  /// `Number(value)` for fields that may come as text; nil when missing or not a number.
  static func looseNumber(_ value: W2GJSON?) -> Double? {
    guard let value else { return nil }
    switch value {
    case .number(let number):
      return number.isFinite ? number : nil
    case .string:
      let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard let number = Double(text), number.isFinite else { return nil }
      return number
    case .bool(let flag):
      return flag ? 1 : 0
    default:
      return nil
    }
  }

  /// Episode of a `media` / `invite`: `.some(episode)` when valid, `.some(nil)` when none was sent, nil when malformed
  /// (the event is dropped).
  private static func eventEpisode(_ value: W2GJSON?) -> W2GJSON?? {
    guard let value, !value.isNull else { return .some(nil) }
    guard let episode = normalizeQueueEpisode(value) else { return nil }
    return .some(episode)
  }

  /// v2.5 validation of every incoming event (PROTOCOL.md "Limits and validation"): the payload cleaned to the types,
  /// ranges and lengths the clients use, or nil to drop the event (unknown types too: they are ignored).
  static func validateEvent(type: String, payload: W2GJSON) -> W2GJSON? {
    switch type {
    case "init":
      return cleanInit(payload)
    case "media":
      guard let media = cleanMedia(payload["media"]), let episode = eventEpisode(payload["episode"]) else { return nil }
      return .dict([("media", media), ("episode", episode), ("key", .text(cleanKey(payload["key"])))])
    case "index":
      guard let number = payload["index"]?.doubleValue, number == number.rounded(), number >= 0, number <= Double(maxIndex) else { return nil }
      var fields: [(String, W2GJSON?)] = [("index", .int(Int(number)))]
      if let kind = payload["kind"]?.stringValue, kind == "file" || kind == "episode" { fields.append(("kind", .text(kind))) }
      let mediaKey = cleanKey(payload["mediaKey"])
      if !mediaKey.isEmpty { fields.append(("mediaKey", .text(mediaKey))) }
      return .dict(fields)
    case "player":
      guard let time = cleanTime(payload["time"]) else { return nil }
      var fields: [(String, W2GJSON?)] = [("time", .number(time)), ("paused", .bool(payload["paused"]?.isTruthy ?? false))]
      if let by = wireId(payload["by"]) { fields.append(("by", .text(by))) }
      if let action = payload["action"]?.stringValue, W2GAction(rawValue: action) != nil { fields.append(("action", .text(action))) }
      if let rate = payload["rate"]?.doubleValue { fields.append(("rate", .number(normalizeRate(rate)))) }
      let mediaKey = cleanKey(payload["mediaKey"])
      if !mediaKey.isEmpty { fields.append(("mediaKey", .text(mediaKey))) }
      return .dict(fields)
    case "message":
      guard let units = payload.utf16Value, !units.isEmpty else { return nil }
      return .string(Array(units.prefix(maxChatLength)))
    case "host":
      guard let hostId = wireId(payload["hostId"]) else { return nil }
      var fields: [(String, W2GJSON?)] = [("hostId", .text(hostId)), ("mode", .text(W2GMode.normalize(payload["mode"]?.stringValue).rawValue))]
      if let session = cleanSessionId(payload["hostSession"]) { fields.append(("hostSession", .text(session))) }
      return .dict(fields)
    case "status":
      return cleanStatus(payload)
    case "ping", "pong":
      guard let sentAt = payload["sentAt"]?.doubleValue else { return nil }
      var fields: [(String, W2GJSON?)] = []
      if let id = wireId(payload["id"]) { fields.append(("id", .text(id))) }
      fields.append(("sentAt", .number(sentAt)))
      return .dict(fields)
    case "request":
      guard let id = wireId(payload["id"]), let kind = payload["kind"]?.stringValue, W2GRequestKind(rawValue: kind) != nil else { return nil }
      var fields: [(String, W2GJSON?)] = [("id", .text(id)), ("kind", .text(kind))]
      if kind == W2GRequestKind.seek.rawValue {
        guard let time = cleanTime(payload["time"]) else { return nil }
        fields.append(("time", .number(time)))
      }
      return .dict(fields)
    case "requestReply":
      guard let id = wireId(payload["id"]) else { return nil }
      var fields: [(String, W2GJSON?)] = [("id", .text(id)), ("accepted", .bool(payload["accepted"]?.isTruthy ?? false))]
      if let by = wireId(payload["by"]) { fields.append(("by", .text(by))) }
      return .dict(fields)
    case "kick":
      guard let userId = wireId(payload["userId"]) else { return nil }
      return .dict([("userId", .text(userId))])
    case "reaction":
      guard let emoji = normalizeReaction(payload["emoji"]?.stringValue) else { return nil }
      return .dict([("emoji", .text(emoji))])
    case "countdown":
      guard let time = cleanTime(payload["time"]) else { return nil }
      var fields: [(String, W2GJSON?)] = [("time", .number(time)), ("seconds", .int(normalizeCountdownSeconds(looseNumber(payload["seconds"]))))]
      if let startAt = payload["startAt"]?.doubleValue { fields.append(("startAt", .number(startAt))) }
      let mediaKey = cleanKey(payload["mediaKey"])
      if !mediaKey.isEmpty { fields.append(("mediaKey", .text(mediaKey))) }
      return .dict(fields)
    case "invite":
      guard let to = wireId(payload["to"]), let media = cleanMedia(payload["media"]), let time = cleanTime(payload["time"]),
            let episode = eventEpisode(payload["episode"]) else { return nil }
      var fields: [(String, W2GJSON?)] = [
        ("to", .text(to)), ("media", media), ("episode", episode), ("key", .text(cleanKey(payload["key"]))),
        ("time", .number(time)), ("paused", .bool(payload["paused"]?.isTruthy ?? false))
      ]
      if let by = wireId(payload["by"]) { fields.append(("by", .text(by))) }
      if let session = cleanSessionId(payload["toSession"]) { fields.append(("toSession", .text(session))) }
      return .dict(fields)
    case "voice":
      return normalizeVoice(payload).json
    case "voiceSignal":
      guard let id = wireId(payload["id"]), let sdpType = payload["sdp"]?["type"]?.stringValue, sdpType == "offer" || sdpType == "answer",
            let sdp = payload["sdp"]?["sdp"]?.utf16Value, !sdp.isEmpty, sdp.count <= maxSdpLength else { return nil }
      return .dict([("id", .text(id)), ("sdp", .dict([("type", .text(sdpType)), ("sdp", .string(sdp))]))])
    case "queue":
      return normalizeQueue(payload)?.json
    case "queueAdd":
      guard let raw = payload["item"], let item = W2GQueueItem(json: raw) else { return nil }
      return .dict([("item", item.json(withVotes: false))])
    case "queueVote":
      guard let id = wireId(payload["id"]) else { return nil }
      return .dict([("id", .text(id)), ("up", .bool(payload["up"]?.boolValue == true))])
    case "queueRemove":
      guard let id = wireId(payload["id"]) else { return nil }
      return .dict([("id", .text(id))])
    default:
      return nil
    }
  }

  /// `init`: who the member is, nothing more (not the whole AniList / MyAnimeList viewer of older apps).
  private static func cleanInit(_ payload: W2GJSON) -> W2GJSON? {
    guard payload.isObject, let idValue = payload["id"] else { return nil }
    var fields: [(String, W2GJSON?)] = []
    switch idValue {
    case .number(let number) where number.isFinite:
      fields.append(("id", idValue))
    // v2.6: never one of the Object.prototype names (a JavaScript peer would look it up in a plain object).
    case .string(let units) where !units.isEmpty && units.count <= 64 && !reservedIds.contains(String(decoding: units, as: UTF16.self)):
      fields.append(("id", idValue))
    default:
      return nil
    }
    let name = queueText(payload["name"], max: maxNameLength)
    if !name.isEmpty { fields.append(("name", .text(name))) }
    let typed = queueText(payload["displayName"], max: maxNameLength)
    if !typed.isEmpty { fields.append(("displayName", .text(typed))) }
    let medium = cleanURL(payload["avatar"]?["medium"])
    let large = cleanURL(payload["avatar"]?["large"])
    if medium != nil || large != nil {
      fields.append(("avatar", .dict([("medium", medium.map { W2GJSON.text($0) }), ("large", large.map { W2GJSON.text($0) })])))
    }
    if let picture = cleanURL(payload["picture"]) { fields.append(("picture", .text(picture))) }
    if let client = payload["client"]?.stringValue, client.utf16.count <= 32 { fields.append(("client", .text(client))) }
    if let version = payload["protocol"]?.doubleValue, version >= 1, version <= 99 { fields.append(("protocol", .number(version))) }
    fields.append(("features", .array(normalizeFeatures(payload["features"]).map { W2GJSON.text($0) })))
    if let session = cleanSessionId(payload["sessionId"]) { fields.append(("sessionId", .text(session))) }
    return .dict(fields)
  }

  private static func cleanStatus(_ payload: W2GJSON) -> W2GJSON? {
    guard let state = W2GPlaybackState.normalize(payload["state"]?.stringValue), let time = cleanTime(payload["time"]) else { return nil }
    var fields: [(String, W2GJSON?)] = [
      ("state", .text(state.rawValue)),
      ("time", .number(time)),
      ("mediaKey", .text(cleanKey(payload["mediaKey"]))),
      ("rate", .number(normalizeRate(payload["rate"]?.doubleValue)))
    ]
    if let sentAt = payload["sentAt"]?.doubleValue { fields.append(("sentAt", .number(sentAt))) }
    fields.append(("source", .text(formatSource([payload["source"]?.stringValue]))))
    fields.append(("following", .bool(payload["following"]?.boolValue != false)))
    if let nowPlaying = payload["nowPlaying"], nowPlaying.isObject {
      var now: [(String, W2GJSON?)] = []
      if let id = nowPlaying["mediaId"] {
        switch id {
        case .number(let number) where number.isFinite: now.append(("mediaId", id))
        case .string(let units) where units.count <= 64: now.append(("mediaId", id))
        default: break
        }
      }
      now.append(("title", .text(queueText(nowPlaying["title"], max: 120))))
      now.append(("episode", .text(queueText(nowPlaying["episode"], max: 120))))
      fields.append(("nowPlaying", .dict(now)))
    } else {
      fields.append(("nowPlaying", .null))
    }
    return .dict(fields)
  }
}

/// Token bucket of one member (W2GSync.rateStep).
struct W2GRateBucket: Equatable {
  var tokens: Double
  var at: Double
  var allowed: Bool
}
