# Watch Together: parity (Svelte → SwiftUI)

Sources ported: `common/routes/w2g/WatchTogetherPage.svelte`, `common/routes/w2g/components/{w2g.js, events.js, session.js, Lobby.svelte, Message.svelte, User.svelte}`, plus the libraries that define the wire protocol: `p2pt` (github:ThaUnknown/p2pt#modernise, `p2pt.js`), `bittorrent-tracker@11.2.2` (`lib/client/websocket-tracker.js`, `tracker.js`), `@thaunknown/simple-peer@10.0.11` (`lite.js`), `uint8-util@2.2.6`.

Swift files (all in `ios-native/Tsumi/WatchTogether/`):

| File | Role |
|---|---|
| `W2GJSON.swift` | JSON value with JS-string semantics (UTF-16 code units), `JSON.stringify`-compatible writer, parser, hex/random helpers, main-thread hop helpers |
| `W2GPeerLink.swift` | One WebRTC connection (simple-peer equivalent, trickle off) + delegate proxy |
| `W2GTracker.swift` | WebTorrent WebSocket tracker client (signaling) |
| `W2GSwarm.swift` | P2PT equivalent: info hash, peer id, links per peer, message framing/chunking |
| `W2GModels.swift` | `W2GUser`, `W2GMember`, `W2GChatMessage`, `W2GMessageGroup`, `W2GPlayerState`, `W2GSharedMedia`, `W2GNotice`, `W2GMediaPayload` (media/episode/key mapping) |
| `WatchTogetherClient.swift` | `@MainActor @Observable` lobby client (W2GClient + session.js + page module logic), `shared` singleton, deep links |
| `WatchTogetherView.swift` | SwiftUI screen (page, lobby, messages, members) |

Package: `stasel/WebRTC` `exactVersion: 156.0.0` (binary xcframework of Google libwebrtc M156, product `WebRTC`), declared in `ios-native/project.yml`.

Status legend: **Done** = same behavior; **Partial** = works with a documented difference; **N/A** = not applicable on iOS. The hooks that used to be marked **App** are wired by the app (see "Wiring" below), so those rows are Done.

Updated 2026-11-14: audit L56 (multi-line composer), stale wiring notes, title helper.

## Feature table

| # | Svelte feature (file) | Swift | Status |
|---|---|---|---|
| 1 | Signaling server list: openwebtorrent, webtorrent.dev, files.fm:7073 (w2g.js `#signalingServers`) | `WatchTogetherClient.signalingServers` | Done (identical order) |
| 2 | Create lobby with random 16-hex code (w2g.js constructor, util.js `generateRandomHexCode`) | `createLobby()`, `W2GHex.randomCode(16)` | Done |
| 3 | Join lobby by code (w2g.js constructor `code`) | `join(code:)` | Done |
| 4 | `isHost = !code` (w2g.js) | `isHost` | Done |
| 5 | `inviteLink` = `tsumi://w2g/CODE` (w2g.js) | `inviteLink` | Done |
| 6 | Self user = `Helper.getUser()` or `{ id: <16 hex> }` (w2g.js) | `currentUser` closure → `W2GUser(viewer:)` / `W2GUser.anonymous()` | Done (`currentUser` = `ProfilesService.shared.viewer`, AppWiring) |
| 7 | AniList viewer `{ id, name, avatar: { medium, large } }`, MAL viewer `{ id, name, picture }` as `init` payload (al/mal clients) | `W2GUser.json` | Done (default AniList avatar / MAL kaomoji when missing, like the JS clients) |
| 8 | Peers store keyed by id, self included (w2g.js `peers`) | `members` (self first, remote by P2PT peer id) | Done |
| 9 | Messages store `{ message, user, type, date }` (w2g.js) | `messages: [W2GChatMessage]` | Done |
| 10 | `shareMedia({ media, episode })` with `mediaKey` dedupe (w2g.js) | `shareMedia(media:episode:)`, `W2GMediaPayload.key` | Done (+ semantic dedupe by AniList/TMDB id so a re-share after a remote start never echoes) |
| 11 | `mediaKey`: `${media.id}:${ep}` with `ep = season:localEpisode??number` for objects (w2g.js) | `W2GMediaPayload.key(mediaId:episode:)` | Done (JS template-string semantics, incl. `undefined`/`null`) |
| 12 | `mediaIndexChanged({ index })` only when changed (w2g.js) | `mediaIndexChanged(_:)` | Done (player `onIndexChange`, ShellPlayback) |
| 13 | `playerStateChanged({ paused, time })` with change detection (w2g.js `_playerStateChanged`) | `playerStateChanged(paused:time:)` | Done (time floored like PlayerPage `Math.floor(currentTime)`; player `onLocalStateChange`, ShellPlayback) |
| 14 | `message(text)`: append outgoing + broadcast (w2g.js) | `sendMessage(_:)` | Done (trimmed, max 2048) |
| 15 | On peer connect: send `init` with self; host also sends media (if any), index, player (w2g.js `#onPeerconnect`, `#sendInitialSessionState`) | `peerConnected`, `sendInitialSessionState` | Done |
| 16 | Incoming data: parse string JSON, ignore malformed (w2g.js `#onMsg`) | `received(_:from:)` | Done |
| 17 | `init` → peers[peer.id] = { user } (w2g.js) | `receivedInit` | Done |
| 18 | `media` → ignore without `media.id` or same key; store with recomputed key; emit (w2g.js) | `receivedMedia` → `onRemoteMedia(Media, EpisodeRef)` | Done (→ `ShellPlayback.playRemote`, AppWiring) |
| 19 | `index` → ignore null, emit when changed (w2g.js) | `onRemoteIndex(Int)` | Done (→ `ShellPlayback.applyRemoteIndex`, AppWiring) |
| 20 | `player` → ignore null time, emit when changed (w2g.js) | `onRemotePlayer(Bool, Double)` | Done (→ `PlayerController.applyRemoteState`, AppWiring) |
| 21 | `message` → incoming, user fallback `{ id: peer.id }` (w2g.js) | `receivedChat` | Done |
| 22 | Unknown event types ignored (w2g.js) | `received` default | Done |
| 23 | Peer close → removed from peers (w2g.js `#onPeerclose`) | `peerClosed` | Done |
| 24 | Broadcast only to peers that sent `init` (w2g.js `#sendToPeers`) | `broadcast` | Done (+ a connected peer that never sends `init` is listed as Anonymous after 8 s, see protocol note 9) |
| 25 | `destroy()` (w2g.js) | `leave()` | Done |
| 26 | Event envelope `{ payload, type }`, types init/media/index/player/message (events.js) | `encodeEvent`, `received` | Done (same key order) |
| 27 | `SHARED_MEDIA_FIELDS` + `pickMedia` (session.js) | `W2GMediaPayload.json(from:)` | Done (fields built from Core `Media`; fields Core does not model are omitted, like `undefined`) |
| 28 | `shareNowPlaying` guard (media id + lobby open) (session.js) | `shareMedia` guard | Done |
| 29 | Lobby state shared app-wide (session.js `state`) | `WatchTogetherClient.shared` | Done |
| 30 | Player ↔ lobby emitter: `player`/`index` in, `playerupdate`/`setindex` out (session.js `w2gEmitter`, PlayerPage.svelte) | closures + `playerStateChanged` / `mediaIndexChanged`, wired in AppWiring / ShellPlayback (Watch Together episode switches are not shared back, `suppressShareUntil`) | Done |
| 31 | Received payload → native `Media` (AniList id → `Media.anilistKey`, `tmdb-<id>` → `Media.tmdbKey(id, format TV/MOVIE)`, idMal, idTmdb, title, cover, banner, format, status, season, genres...) | `W2GMediaPayload.media(from:)` | Done |
| 32 | Outgoing id like tmdb.js `normalizeMedia`: AniList id if any, else `"tmdb-<id>"`; episode number or `{ number, season, localEpisode }` | `payloadId(for:)`, `episodeJSON` | Done |
| 33 | `joinLobby`: destroy previous lobby, create client, wire events (WatchTogetherPage.svelte) | `start(code:)` | Done |
| 34 | Remote `media` → toast "Starting <title> - Episode N" + `w2g-play` (WatchTogetherPage.svelte, ExtensionModal.svelte) | `notice` banner + `onNotice` (app toast unless the lobby is on screen) + `onRemoteMedia`; title from `AniListService.title` (anilistClient.title) | Done |
| 35 | Auto-copy invite on create (`if (!code) invite()`) | `start` → `copyInvite()` | Done |
| 36 | Invite: copy `tsumi://w2g/CODE` to clipboard (WatchTogetherPage.svelte `invite`) | `copyInvite()` (UIPasteboard) + header `ShareLink` | Done (+ share sheet) |
| 37 | Deep link `tsumi://w2g/CODE` → join + navigate (IPC `w2glink`, electron/capacitor protocol.js) | `handle(url:)`, `join(link:)`, `onShowLobby` | Done (`ShellDeepLinks.handle`; `shiru://` accepted like Capacitor) |
| 38 | Join input "Lobby Code or Link", regex `/([A-z0-9]{16})/i`, joins as soon as it matches (WatchTogetherPage.svelte `checkInvite`) | `W2GStartView`, `WatchTogetherClient.lobbyCode(in:)` | Done (+ Paste button) |
| 39 | Create Lobby card/button (WatchTogetherPage.svelte) | `W2GStartView.createCard` | Done |
| 40 | "Watch Together" title, start page vs lobby (WatchTogetherPage.svelte) | `WatchTogetherView` | Done |
| 41 | Leave button (Lobby.svelte `cleanup`) | `W2GLobbyView.inputBar` | Done |
| 42 | Invite button (Lobby.svelte) | `W2GLobbyView.inputBar` | Done |
| 43 | Message textarea, max 2048, Enter sends / Shift+Enter newline, auto rows (Lobby.svelte) | `TextField(axis: .vertical)` growing to 6 lines, 2048 cap; Return sends (the line break a vertical field types is caught in the draft observer and the text before it is sent); Shift+Return keeps the line break (`onKeyPress`, hardware keyboard); pasted line breaks are kept | Done (device check: if the field swallows Shift+Return before `onKeyPress`, it sends like Return) |
| 44 | Send button (Lobby.svelte) | `W2GLobbyView.inputBar` | Done |
| 45 | `groupMessages`: last 50, grouped while sender unchanged (Lobby.svelte) | `W2GMessageGroup.group` | Done |
| 46 | "N Member(s)" + member list (Lobby.svelte) | `W2GMemberStrip` (compact) / `W2GMemberList` (regular) | Done |
| 47 | Avatar `avatar.medium || picture || default` (Message.svelte, User.svelte) | `W2GAvatarView` | Done |
| 48 | Name or "Anonymous", time `toLocaleTimeString()` (Message.svelte) | `W2GMessageGroupView` (`.standard` time incl. seconds) | Done |
| 49 | Bubbles incoming left / outgoing right in accent color, selectable (Message.svelte) | `W2GMessageGroupView` | Done |
| 50 | Profile link: anilist.co/user/<name> if `avatar.medium`, else myanimelist.net/profile/<name> (User.svelte) | `W2GUser.profileURL`, `W2GMemberRow` | Done |
| 51 | Discord "Ask to join" secret → `w2glink` (electron discord.js) | – | N/A (desktop only) |
| 52 | P2PT `responseWaiting` (reply-to messages) | – | N/A (W2G never uses replies; see protocol note 8 for the interop guard) |
| 53 | Tracker status (P2PT `trackerconnect` / `getTrackerStats`) | `connectedTrackers`, `totalTrackers`, header status badge | Done (UI extra) |

Counts: **53 items: 51 Done, 0 Partial, 2 N/A.** Rows 6, 12, 13, 18, 19, 20, 30, 34 and 37 depend on the app hooks, which are wired (see below).

## Wire protocol implemented (verified against the JS sources; signaling round-trip checked live on 2026-11-14 against tracker.openwebtorrent.com and tracker.webtorrent.dev; tracker.files.fm:7073 refused the WebSocket that day, same for the JS app)

1. **Swarm id.** `info_hash = SHA-1(UTF-8(lobbyCode))` (p2pt.js `setIdentifier` → uint8-util `hash(str, 'hex')`), 20 bytes. The lobby code is used exactly as typed/matched (no case folding), like the JS.
2. **Peer id.** 20 random bytes (`randomBytes(20)`); remote peers are identified by the 40-char lowercase hex of their peer_id (`bin2hex`).
3. **Binary strings.** `info_hash`, `peer_id`, `to_peer_id`, `offer_id` travel as JS "binary strings": one char per byte (U+0000..U+00FF), JSON-encoded like `JSON.stringify` (control chars as `\u00xx`, 0x80–0xFF as raw UTF-8). `W2GJSON` keeps strings as UTF-16 code units for this reason.
4. **Tracker messages** (text frames on `URLSessionWebSocketTask`, one socket per tracker):
   - Announce on connect (and on every reconnect): `{"numwant":5,"uploaded":0,"downloaded":0,"action":"announce","info_hash":…,"peer_id":…[,"trackerid":…],"offers":[{"offer":{"type":"offer","sdp":…},"offer_id":<20 random bytes>} ×5]}`. No `event` field (P2PT never sends one).
   - Responses are only handled for `action == "announce"` and matching `info_hash`; messages carrying our own `peer_id` are ignored; `failure reason` aborts handling.
   - `interval` (or `min interval`) seconds → re-announce timer with 5 fresh offers (restarted on every response carrying it; clamped to ≥ 10 s on iOS).
   - `tracker id` is remembered and sent back as `trackerid`.
   - Relayed offer `{offer, offer_id, peer_id}` → create an answering link, reply `{"action":"announce","info_hash","peer_id","to_peer_id":<offerer>,"answer":{"type":"answer","sdp"},"offer_id":<echoed>}` (+ `trackerid`).
   - Relayed answer `{answer, offer_id, peer_id}` → matched to our pending offer by `offer_id` (hex), remote description applied.
   - Unanswered offers are destroyed after 50 s (`OFFER_TIMEOUT`).
   - Socket close/error → pending offers destroyed, reconnect after `min(2^retries × 10 s, 1 h) + random variance`, then announce. iOS uses a 0–5 s variance instead of 0–5 min, reconnects immediately on `appBecameActive()`, and sends a WebSocket ping every 30 s (none of these change the messages).
5. **WebRTC (simple-peer, trickle off).** ICE servers `stun:stun.l.google.com:19302` + `stun:global.stun.twilio.com:3478`, unified plan, no media. The local offer/answer is sent once: when ICE gathering completes, or 5 s after the first candidate (`ICECOMPLETE_TIMEOUT`); the SDP sent is `localDescription.sdp` (all candidates inline) with `a=ice-options:trickle\r\n` removed (`filterTrickle`). Signal objects are `{ type, sdp }`. Remote SDPs are applied with `setRemoteDescription`; an offer triggers `createAnswer`. ICE `failed`/`closed` or channel `closed` destroys the link.
6. **Data channel.** The initiator creates one channel labelled with 20 random bytes in hex, default options (ordered, reliable, not negotiated); the answerer adopts the remote channel (`ondatachannel`). A link counts as connected when its channel is `open`. Messages are sent as text frames (P2PT sends strings); received frames are decoded as UTF-8 whatever their binary flag (simple-peer/P2PT do the same).
7. **P2PT framing.** Each payload string is split into chunks of at most 16000 UTF-16 code units (`MAX_MESSAGE_LENGTH`); every chunk is sent as `"^" + JSON.stringify({ id, msg, c, last? })` with `id` a random integer in 100000…199999 (same for all chunks), `c` the chunk index and `last: true` on the final chunk. Receiving: frames not starting with `^` are ignored; chunks are stored per (peer, id) and joined in index order on `last`; if `o` is truthy the joined text is parsed as JSON (P2PT object messages). W2G payloads are always strings: `JSON.stringify({ payload, type })`.
8. **Reply-id guard.** P2PT resolves `responseWaiting[peer][id]` instead of emitting `msg` when an incoming id equals an id it previously sent to that peer. iOS never reuses, towards a peer, an id that peer used towards us (tracked per peer, reset on peerclose like P2PT).
9. **Peers and backups.** Several links to the same peer id are kept (one per tracker/offer pair); `peerconnect` fires when the first link opens, `peerclose` when the last one closes; sends use any open link. iOS stops answering new offers from a peer that already has 3 open/connecting links (refusing an offer is invisible to P2PT), but never kills a link the remote side already answered. Known P2PT quirk: its one-time `peerconnect` is bound to the first `peer` object of an id, so if that one fails while a later one connects, the JS side never sends `init`; iOS lists such a connected-but-silent peer as Anonymous after 8 s so lobby events still reach it.
10. **W2G events** (`{"payload": …, "type": …}`): `init` → viewer object or `{ id }`; `media` → `{ media: <trimmed media>, episode: <number | {number, season?, localEpisode?}>, key: "<media.id>:<ep>" }`; `index` → `{ index }`; `player` → `{ time, paused }` (time in whole seconds from the JS player); `message` → string.

## Wiring (done by the app)

All hooks are set in `UI/Shell/AppWiring.swift` (`configureWatchTogether`, lines 28-50) and the shell:

- `currentUser` = `ProfilesService.shared.viewer`; `onRemoteMedia` → `ShellPlayback.playRemote`; `onRemotePlayer` → `PlayerPresentation.shared.controller?.applyRemoteState`; `onRemoteIndex` → `ShellPlayback.applyRemoteIndex`; `onNotice` → `ShellPlayback.showWatchTogetherNotice` (toast unless the lobby is visible, where the in-screen banner shows); `onShowLobby` → `ShellNavigation.showTab(.watchTogether)`.
- Player (`UI/Shell/ShellPlayback.swift`): `onEpisodeStarted` → `shareMedia(media:episode:)` (skipped for an episode a peer asked for), `onLocalStateChange` → `playerStateChanged(paused:time:)`, `onIndexChange` → `mediaIndexChanged(_:)`, `isWatchTogetherActive` → `isInLobby`.
- Deep links (`UI/Shell/ShellNavigation.swift` `ShellDeepLinks`): `tsumi://w2g/…` → `handle(url:)`, routed `watchTogether` links → `join(link:)`; `scenePhase == .active` → `appBecameActive()` (`ShellLifecycle`).
- `Info.plist` has `NSLocalNetworkUsageDescription`.
