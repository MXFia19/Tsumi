import Foundation

// Watch Together v2.6 (common/routes/w2g/PROTOCOL.md "v2.6"): the pure part, ported one to one from
// common/routes/w2g/components/sync.js (`canonicalMediaKey`, `sameMediaKey`, `shadowKey`, `RATE_LIMITS`, `rateClass`,
// `rateStep` with limits, `RESERVED_IDS`), same values.

extension W2GSync {
  // MARK: Media keys

  /// A media key written the canonical way ("mediaId:episode" or "mediaId:season:episode"). Apps before v2.6 wrote an
  /// episode object without a season as "mediaId::episode" (empty season): that is "mediaId:episode".
  static func canonicalMediaKey(_ key: String) -> String {
    // sync.js key.replace(/::([^:]*)$/, ':$1'): the last "::" when no other ":" follows it.
    guard let range = key.range(of: "::", options: .backwards) else { return key }
    let rest = String(key[range.upperBound...])
    guard !rest.contains(":") else { return key }
    return String(key[..<range.lowerBound]) + ":" + rest
  }

  /// Two media keys name the same episode, however their writer formatted them ("21:5" / "21::5"). Two empty keys are
  /// the same too (nothing playing on either side): callers that need a key check it first.
  static func sameMediaKey(_ lhs: String, _ rhs: String) -> Bool {
    canonicalMediaKey(lhs) == canonicalMediaKey(rhs)
  }

  // MARK: Identity

  /// A member key belongs to the first open link that claimed it. Another link whose `init` names the same `id` and
  /// `sessionId` is a separate member under this key, with no authority: never the host, nor elected or given the role.
  static func shadowKey(_ key: String, transportId: String) -> String {
    key + "@" + transportId
  }

  /// Ids a JavaScript peer could use to reach Object.prototype through a lookup table: never a media or member id
  /// (sync.js RESERVED_IDS, the same list on every app).
  static let reservedIds: Set<String> = [
    "__proto__", "constructor", "prototype", "toString", "toLocaleString", "valueOf", "hasOwnProperty", "isPrototypeOf",
    "propertyIsEnumerable", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__"
  ]

  // MARK: Rate limits

  /// Token buckets per data link (sending `init` again does not reset them): `user` (userEvents), `init` (sent once
  /// on connect, then on a display name change), `ping` (one every 10 s), `voiceOffer` (each offer builds a peer
  /// connection; retried every 3 s at most 5 times).
  static let rateLimits: [String: W2GRateLimit] = [
    "user": W2GRateLimit(burst: rateBurst, perSecond: ratePerSecond),
    "init": W2GRateLimit(burst: 5, perSecond: 0.2),
    "ping": W2GRateLimit(burst: 5, perSecond: 1),
    "voiceOffer": W2GRateLimit(burst: 6, perSecond: 0.5)
  ]

  /// Which bucket of `rateLimits` a validated event uses, nil when it is not limited.
  static func rateClass(type: String, payload: W2GJSON) -> String? {
    if userEvents.contains(type) { return "user" }
    if type == "init" || type == "ping" { return type }
    if type == "voiceSignal", payload["sdp"]?["type"]?.stringValue == "offer" { return "voiceOffer" }
    return nil
  }

  /// Token bucket step with the given limits.
  static func rateStep(_ bucket: W2GRateBucket?, now: Double, limit: W2GRateLimit) -> W2GRateBucket {
    let refilled = bucket.map { $0.tokens + max(0, now - $0.at) / 1000 * limit.perSecond } ?? limit.burst
    let tokens = min(limit.burst, refilled)
    if tokens < 1 { return W2GRateBucket(tokens: tokens, at: now, allowed: false) }
    return W2GRateBucket(tokens: tokens - 1, at: now, allowed: true)
  }
}

/// One bucket of W2GSync.rateLimits.
struct W2GRateLimit: Equatable {
  var burst: Double
  var perSecond: Double
}
