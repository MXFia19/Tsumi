import Foundation

// Watch Together data: lobby members, chat messages and the shared media payload.
// Payload shapes match common/routes/w2g/components (w2g.js, session.js) so that an iPhone and
// the desktop/web app understand each other.

/// A lobby participant as sent in the `init` event: the AniList/MyAnimeList Viewer object of the
/// JS app (`{ id, name, avatar: { medium, large } }` / `{ id, name, picture }`), or `{ id }` for an
/// anonymous user (16 random hex chars).
struct W2GUser: Hashable {
  var id: String
  var name: String?
  var avatar: URL?
  /// AniList user (has `avatar.medium`) → anilist.co profile, else MyAnimeList (User.svelte).
  var isAniList: Bool
  /// The JSON number id when the source sent a number (AniList/MAL ids), to re-encode as is.
  var numericId: Int?
  /// v2 `init.displayName`: name typed by an anonymous user, shown instead of the id.
  var typedName: String?

  static let defaultAvatar = URL(string: "https://s4.anilist.co/file/anilistcdn/user/avatar/large/default.png")
  static let defaultMALPicture = "https://cdn.myanimelist.net/images/kaomoji_mal_white.png"

  init(id: String, name: String? = nil, avatar: URL? = nil, isAniList: Bool = false, numericId: Int? = nil, typedName: String? = nil) {
    self.id = id
    self.name = name
    self.avatar = avatar
    self.isAniList = isAniList
    self.numericId = numericId
    self.typedName = typedName
  }

  /// Anonymous participant (`{ id: generateRandomHexCode(16) }`).
  static func anonymous() -> W2GUser {
    W2GUser(id: W2GHex.randomCode(16))
  }

  /// The signed-in account (Helper.getUser()).
  init(viewer: Viewer) {
    id = String(viewer.id)
    numericId = viewer.id
    name = viewer.name
    switch viewer.service {
    case .anilist:
      isAniList = true
      avatar = viewer.avatar ?? W2GUser.defaultAvatar
    case .myanimelist:
      isAniList = false
      avatar = viewer.avatar ?? URL(string: W2GUser.defaultMALPicture)
    }
  }

  /// Remote `init` payload; anything malformed falls back to `{ id: peerId }`.
  init(json: W2GJSON, fallbackId: String) {
    var resolvedId = fallbackId
    var number: Int?
    if let value = json["id"] {
      switch value {
      case .number:
        number = value.intValue
        resolvedId = W2GJSON.jsTemplateString(value)
      case .string(let units) where !units.isEmpty:
        resolvedId = String(decoding: units, as: UTF16.self)
      default:
        break
      }
    }
    id = resolvedId
    numericId = number
    name = json["name"]?.stringValue
    typedName = W2GSync.cleanDisplayName(json["displayName"]?.stringValue)
    let medium = json["avatar"]?["medium"]?.stringValue
    let large = json["avatar"]?["large"]?.stringValue
    let picture = json["picture"]?.stringValue
    isAniList = !(medium ?? "").isEmpty
    avatar = URL.lenient(medium) ?? URL.lenient(large) ?? URL.lenient(picture)
  }

  /// `init` event payload for this user.
  var json: W2GJSON {
    var idValue = W2GJSON.text(id)
    if let numericId { idValue = W2GJSON.int(numericId) }
    guard let name, !name.isEmpty else { return W2GJSON.dict([("id", idValue)]) }
    var fields: [(String, W2GJSON?)] = []
    if isAniList {
      let url: String = (avatar ?? W2GUser.defaultAvatar)?.absoluteString ?? ""
      var avatarFields: [(String, W2GJSON?)] = []
      avatarFields.append(("medium", W2GJSON.text(url)))
      avatarFields.append(("large", W2GJSON.text(url)))
      fields.append(("avatar", W2GJSON.dict(avatarFields)))
      fields.append(("name", W2GJSON.text(name)))
      fields.append(("id", idValue))
    } else {
      let picture: String = avatar?.absoluteString ?? W2GUser.defaultMALPicture
      fields.append(("id", idValue))
      fields.append(("name", W2GJSON.text(name)))
      fields.append(("picture", W2GJSON.text(picture)))
    }
    return W2GJSON.dict(fields)
  }

  /// sync.js memberName: AniList / MAL name, else the typed display name, else "Guest <id prefix>".
  var displayName: String {
    W2GSync.memberName(name: name, typedName: typedName, id: id)
  }

  /// Profile link opened from the member list (User.svelte).
  var profileURL: URL? {
    guard let name, !name.isEmpty else { return nil }
    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    let base = isAniList ? "https://anilist.co/user/" : "https://myanimelist.net/profile/"
    return URL(string: base + encoded)
  }
}

struct W2GMember: Identifiable, Hashable {
  /// Remote P2PT peer id (hex), or "self" for the local user.
  var id: String
  var user: W2GUser
  var isSelf: Bool
  /// `init.protocol` (1 for a v1 client that sends none); nil while the peer has not sent `init`.
  var protocolVersion: Int? = nil
  /// `init.client` ("tsumi-desktop", "tsumi-android", "tsumi-ios").
  var client: String? = nil
  /// The peer sent `init` (false for a connected peer listed after the introduction grace).
  var introduced: Bool = true
  /// When its first `init` arrived (ms, local clock): v2.3 "No signal" 10 s later without `status`.
  var introducedAt: Double? = nil
  /// v2.4 `init.features` ("voice", "queue").
  var features: [String] = []

  /// PROTOCOL "Identity": the `init` id, else the transport id.
  var userId: String { user.id }
}

struct W2GChatMessage: Identifiable, Hashable {
  enum Direction: String, Hashable {
    case incoming
    case outgoing
    /// Local line (joins, leaves, actions, requests, reactions), never sent.
    case system
  }

  let id: UUID
  var text: String
  var user: W2GUser
  var direction: Direction
  var date: Date
  /// Reaction of a system line ("Alice reacted 🔥").
  var emoji: String?

  init(text: String, user: W2GUser, direction: Direction, date: Date = Date()) {
    id = UUID()
    self.text = text
    self.user = user
    self.direction = direction
    self.date = date
    emoji = nil
  }

  /// System chat line.
  init(system text: String, emoji: String? = nil, date: Date = Date()) {
    id = UUID()
    self.text = text
    user = W2GUser(id: "")
    direction = .system
    self.date = date
    self.emoji = emoji
  }

  var isSystem: Bool { direction == .system }
}

/// Consecutive messages of one user (Lobby.svelte groupMessages).
struct W2GMessageGroup: Identifiable, Hashable {
  var id: UUID
  var user: W2GUser
  var messages: [String]
  var direction: W2GChatMessage.Direction
  var date: Date

  var isSystem: Bool { direction == .system }

  /// Last 50 messages, grouped while the sender does not change; system lines stay on their own.
  static func group(_ messages: [W2GChatMessage]) -> [W2GMessageGroup] {
    var groups: [W2GMessageGroup] = []
    for message in messages.suffix(50) {
      if let last = groups.last, !last.isSystem, !message.isSystem, last.user.id == message.user.id {
        groups[groups.count - 1].messages.append(message.text)
      } else {
        groups.append(W2GMessageGroup(id: message.id, user: message.user, messages: [message.text], direction: message.direction, date: message.date))
      }
    }
    return groups
  }
}

/// `player` event payload ({ time, paused }).
struct W2GPlayerState: Equatable {
  var paused: Bool = true
  var time: Double = 0

  var json: W2GJSON {
    .dict([("time", .number(time)), ("paused", .bool(paused))])
  }
}

/// What the lobby is watching (`{ media, episode, key }` of the `media` event).
struct W2GSharedMedia {
  /// The key everyone compares (`status.mediaKey`): the sender's `key` for a received title.
  var key: String
  /// Our own key for the same title, which another client may format differently.
  var localKey: String
  var mediaJSON: W2GJSON
  var episodeJSON: W2GJSON
  /// The payload mapped onto the native model (nil only if the payload had no usable id).
  var media: Media?
  var episode: EpisodeRef

  var payload: W2GJSON {
    .dict([("media", mediaJSON), ("episode", episodeJSON), ("key", .text(key))])
  }

  /// Same title and episode, even if the ids were written differently (AniList vs TMDB).
  func matches(media other: Media, episode otherEpisode: EpisodeRef, payloadId: W2GJSON) -> Bool {
    guard episode.number == otherEpisode.number,
          (episode.season ?? 0) == (otherEpisode.season ?? 0),
          (episode.localEpisode ?? episode.number) == (otherEpisode.localEpisode ?? otherEpisode.number) else { return false }
    if W2GJSON.jsTemplateString(mediaJSON["id"]) == W2GJSON.jsTemplateString(payloadId) { return true }
    guard let media else { return false }
    if let a = media.anilistId, let b = other.anilistId, a == b { return true }
    if let a = media.tmdbId, let b = other.tmdbId, a == b { return true }
    return media.id == other.id
  }
}

/// Transient banner (the JS app shows a toast).
struct W2GNotice: Identifiable, Equatable {
  let id = UUID()
  var title: String
  var message: String
}

// MARK: - v2 (PROTOCOL.md)

/// What the local player is doing, read by the client for `status` (built by the app from the PlayerController).
struct W2GLocalPlayback {
  var state: W2GPlaybackState
  var time: Double
  var rate: Double
  var media: Media
  var episode: EpisodeRef
  /// v2.1 `status.source`: "Extension · Server", "" when unknown.
  var source: String
}

/// A lobby state for the local player: someone's action, a host snap-back, auto-sync, resync or countdown.
struct W2GPlayerCommand {
  var time: Double
  var paused: Bool
  var action: W2GAction
  /// userId of the person who caused it.
  var by: String
  var rate: Double
  /// The time is exact (v2 sender or local correction); v1 senders send whole seconds.
  var isPrecise: Bool
}

/// A member row: host crown, sync badge, ping.
struct W2GMemberView: Identifiable, Equatable {
  var userId: String
  var user: W2GUser
  var name: String
  var isSelf: Bool
  var isHost: Bool
  var badge: W2GBadge
  var protocolVersion: Int?
  var client: String?
  var rtt: Double?
  /// v2.2 what the member watches: "Title · Episode 5" ("" when unknown or not in the player).
  var watching: String = ""
  /// v2.1 `status.source`: "Extension · Server".
  var source: String = ""
  /// v2.1 "Invite to watch" is offered on this row.
  var canInvite: Bool = false
  /// v2.4: the member's app has voice chat.
  var hasVoice: Bool = false
  /// v2.4: in voice, muted, speaking, our mix for it.
  var voice: W2GMemberVoice = .off

  var id: String { userId }

  /// Host transfer needs a v2 client (a v1 client could not change the mode, kick or answer requests).
  var canBeHost: Bool { (protocolVersion ?? 1) >= W2GSync.protocolVersion }
}

/// A request waiting for the host's answer.
struct W2GHostRequest: Identifiable, Equatable {
  var id: String
  var kind: W2GRequestKind
  var time: Double?
  var userId: String
  var name: String
  /// ms, local clock.
  var expiresAt: Double

  var prompt: String { W2GSync.requestPrompt(name: name, kind: kind, time: time) }
}

/// The 3-2-1 overlay: everyone is at `time`, paused, and plays when it ends.
struct W2GCountdown: Equatable {
  let id = UUID()
  var time: Double
  var seconds: Int
  /// ms, local clock.
  var endsAt: Double
  var by: String
}

/// Chat message shown over the video while the panel is closed.
struct W2GChatBubble: Identifiable, Equatable {
  let id = UUID()
  var name: String
  var text: String
}

/// "Request pause" / "Request play" / "Request jump to 12:34" button of a notice.
struct W2GNoticeRequest: Equatable {
  var kind: W2GRequestKind
  var time: Double?
  var label: String
}

/// Short notice over the video ("Alice paused at 12:34", "Only the host controls playback").
struct W2GOverlayNotice: Identifiable, Equatable {
  let id = UUID()
  var text: String
  var request: W2GNoticeRequest?
}

/// Emoji rising over the video.
struct W2GFloatingReaction: Identifiable, Equatable {
  let id = UUID()
  var emoji: String
  /// Distance from the trailing edge, as a fraction of the width.
  var inset: Double
  var createdAt = Date()
}

/// v2.1 `invite` received: "Alice invites you to watch <title> · <episode>" with Join / Dismiss (no timeout).
struct W2GInvite: Identifiable, Equatable {
  let id = UUID()
  /// userId of the sender (a new invite from the same sender replaces this one).
  var from: String
  /// `invite.by`.
  var by: String
  var name: String
  var title: String
  var episodeLabel: String
  /// The media to play, like a received `media` event (sender's key kept verbatim).
  var shared: W2GSharedMedia
  /// The sender's position and state when it sent the invite.
  var time: Double
  var paused: Bool
  /// ms, local clock.
  var receivedAt: Double

  var prompt: String { "\(name) invites you to watch \(title) \u{00B7} \(episodeLabel)" }

  static func == (lhs: W2GInvite, rhs: W2GInvite) -> Bool { lhs.id == rhs.id }
}

/// v2.3 Join card: "{reference name} is watching {title · episode}" [Join].
struct W2GJoinOffer: Equatable {
  /// userId of the reference member.
  var referenceId: String
  var name: String
  /// "Title · Episode 5" of the lobby media.
  var label: String
  /// The lobby media key.
  var key: String

  var text: String { "\(name) is watching \(label)" }
}

/// An accepted invite waiting for the file to load, then seeking to the inviter's (or host's) expected time.
struct W2GInviteJoin {
  var key: String
  var by: String
  var time: Double
  var paused: Bool
  /// ms, local clock (when the invite was received).
  var receivedAt: Double
  /// ms, local clock (when Join was tapped); the join is dropped if the file never loads.
  var acceptedAt: Double
}

// MARK: - Media payload (session.js pickMedia, w2g.js mediaKey, tmdb.js normalizeMedia)

enum W2GMediaPayload {
  /// session.js SHARED_MEDIA_FIELDS.
  static let sharedFields = ["id", "idMal", "idTmdb", "isTmdb", "format", "episodes", "status", "title", "coverImage", "bannerImage", "season", "seasonYear", "duration", "averageScore", "genres"]

  /// `media.id` as the JS app writes it: AniList id (number), or "tmdb-<id>" for TMDB-only titles.
  static func payloadId(for media: Media) -> W2GJSON {
    if let anilistId = media.anilistId { return .int(anilistId) }
    if let tmdbId = media.tmdbId { return .text("tmdb-\(tmdbId)") }
    if media.id.hasPrefix("al-"), let number = Int(media.id.dropFirst(3)) { return .int(number) }
    if media.id.hasPrefix("tmdb-"), let last = media.id.split(separator: "-").last, let number = Int(last) {
      return .text("tmdb-\(number)")
    }
    return .text(media.id)
  }

  /// Trimmed JS-shaped media object (only SHARED_MEDIA_FIELDS, undefined fields omitted).
  static func json(from media: Media) -> W2GJSON {
    var title: [(String, W2GJSON?)] = []
    title.append(("romaji", optionalText(media.title.romaji)))
    title.append(("english", optionalText(media.title.english)))
    title.append(("native", optionalText(media.title.native)))
    title.append(("userPreferred", optionalText(media.title.userPreferred)))

    let large: URL? = media.images.coverLarge ?? media.images.cover
    let medium: URL? = media.images.cover ?? media.images.coverLarge
    var cover: [(String, W2GJSON?)] = []
    cover.append(("extraLarge", optionalText(large?.absoluteString)))
    cover.append(("medium", optionalText(medium?.absoluteString)))
    cover.append(("color", optionalText(media.images.color)))

    var fields: [(String, W2GJSON?)] = []
    fields.append(("id", payloadId(for: media)))
    fields.append(("idMal", optionalInt(media.malId)))
    fields.append(("idTmdb", optionalInt(media.tmdbId)))
    if media.source == .tmdb { fields.append(("isTmdb", W2GJSON.bool(true))) }
    if media.format != .unknown { fields.append(("format", W2GJSON.text(media.format.rawValue))) }
    fields.append(("episodes", optionalInt(media.episodes)))
    if media.status != .unknown { fields.append(("status", W2GJSON.text(media.status.rawValue))) }
    fields.append(("title", W2GJSON.dict(title)))
    fields.append(("coverImage", W2GJSON.dict(cover)))
    fields.append(("bannerImage", optionalText(media.images.banner?.absoluteString)))
    fields.append(("season", optionalText(media.season?.rawValue)))
    fields.append(("seasonYear", optionalInt(media.seasonYear)))
    fields.append(("duration", optionalInt(media.duration)))
    fields.append(("averageScore", optionalInt(media.averageScore)))
    let genres: [W2GJSON] = media.genres.map { W2GJSON.text($0) }
    fields.append(("genres", W2GJSON.array(genres)))
    return W2GJSON.dict(fields)
  }

  private static func optionalText(_ value: String?) -> W2GJSON? {
    guard let value else { return nil }
    return W2GJSON.text(value)
  }

  private static func optionalInt(_ value: Int?) -> W2GJSON? {
    guard let value else { return nil }
    return W2GJSON.int(value)
  }

  /// Episode as shareNowPlaying sends it: a number, or `{ number, season, localEpisode }` for
  /// season-based (TMDB) shows.
  static func episodeJSON(_ episode: EpisodeRef) -> W2GJSON {
    guard episode.season != nil || episode.localEpisode != nil else { return W2GJSON.int(episode.number) }
    var fields: [(String, W2GJSON?)] = []
    fields.append(("number", W2GJSON.int(episode.number)))
    fields.append(("season", optionalInt(episode.season)))
    fields.append(("localEpisode", optionalInt(episode.localEpisode)))
    return W2GJSON.dict(fields)
  }

  static func episodeRef(from json: W2GJSON?) -> EpisodeRef? {
    guard let json else { return nil }
    switch json {
    case .number:
      guard let number = json.intValue else { return nil }
      return EpisodeRef(number: number)
    case .string:
      guard let text = json.stringValue, let number = Int(text) else { return nil }
      return EpisodeRef(number: number)
    case .object:
      let local = json["localEpisode"]?.intValue
      guard let number = json["number"]?.intValue ?? local else { return nil }
      return EpisodeRef(number: number, season: json["season"]?.intValue, localEpisode: local)
    default:
      return nil
    }
  }

  /// w2g.js mediaKey({ media, episode }).
  static func key(mediaId: W2GJSON?, episode: W2GJSON?) -> String {
    let episodePart: String
    if let episode, episode.isObject {
      let season = episode["season"].flatMap { $0.isNull ? nil : $0 }
      let local = episode["localEpisode"].flatMap { $0.isNull ? nil : $0 }
      let seasonText = season.map { W2GJSON.jsTemplateString($0) } ?? ""
      episodePart = "\(seasonText):\(W2GJSON.jsTemplateString(local ?? episode["number"]))"
    } else {
      episodePart = W2GJSON.jsTemplateString(episode)
    }
    return "\(W2GJSON.jsTemplateString(mediaId)):\(episodePart)"
  }

  /// Maps a received JS media object onto the native model, as well as the payload allows.
  static func media(from json: W2GJSON) -> Media? {
    guard let idValue = json["id"], idValue.isTruthy else { return nil }
    let titleJSON = json["title"]
    let title = MediaTitle(
      romaji: titleJSON?["romaji"]?.stringValue,
      english: titleJSON?["english"]?.stringValue,
      native: titleJSON?["native"]?.stringValue,
      userPreferred: titleJSON?["userPreferred"]?.stringValue
    )
    let coverJSON = json["coverImage"]
    let extraLarge = coverJSON?["extraLarge"]?.stringValue
    let large = coverJSON?["large"]?.stringValue
    let medium = coverJSON?["medium"]?.stringValue
    let images = MediaImages(
      cover: URL.lenient(medium) ?? URL.lenient(large) ?? URL.lenient(extraLarge),
      coverLarge: URL.lenient(extraLarge) ?? URL.lenient(large) ?? URL.lenient(medium),
      banner: URL.lenient(json["bannerImage"]?.stringValue),
      logo: nil,
      color: coverJSON?["color"]?.stringValue
    )
    let format = json["format"]?.stringValue.flatMap { MediaFormat(rawValue: $0) } ?? .unknown
    let status = json["status"]?.stringValue.flatMap { MediaStatus(rawValue: $0) } ?? .unknown
    let tmdbId = json["idTmdb"]?.intValue
    let tmdbType: TMDBType = format == .movie ? .movie : .tv

    var anilistId: Int?
    var tmdbOnlyId: Int?
    var rawKey: String?
    switch idValue {
    case .number:
      anilistId = idValue.intValue
    case .string:
      let text = idValue.stringValue ?? ""
      if text.hasPrefix("tmdb-"), let number = Int(text.dropFirst(5)) {
        tmdbOnlyId = number
      } else if let number = Int(text) {
        anilistId = number
      } else {
        rawKey = text
      }
    default:
      return nil
    }

    let key: String
    let source: MediaSource
    if let anilistId {
      key = Media.anilistKey(anilistId)
      source = .anilist
    } else if let tmdb = tmdbOnlyId ?? tmdbId {
      key = Media.tmdbKey(tmdb, tmdbType)
      source = .tmdb
    } else if let rawKey {
      key = rawKey
      source = json["isTmdb"]?.isTruthy == true ? .tmdb : .anilist
    } else {
      return nil
    }

    var media = Media(id: key, source: source, title: title, images: images, format: format, status: status)
    media.anilistId = anilistId
    media.malId = json["idMal"]?.intValue
    media.tmdbId = tmdbOnlyId ?? tmdbId
    if media.tmdbId != nil { media.tmdbType = tmdbType }
    media.episodes = json["episodes"]?.intValue
    media.duration = json["duration"]?.intValue
    media.season = json["season"]?.stringValue.flatMap { MediaSeason(rawValue: $0) }
    media.seasonYear = json["seasonYear"]?.intValue
    media.averageScore = json["averageScore"]?.intValue
    media.genres = (json["genres"]?.arrayValue ?? []).compactMap { $0.stringValue }
    return media
  }
}
