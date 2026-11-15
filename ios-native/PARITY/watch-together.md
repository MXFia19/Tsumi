# Watch Together: parity (Svelte → SwiftUI)

Sources ported: `common/routes/w2g/WatchTogetherPage.svelte`, `common/routes/w2g/components/{w2g.js, events.js, session.js, Lobby.svelte, Message.svelte, User.svelte}`, plus the libraries that define the wire protocol: `p2pt` (github:ThaUnknown/p2pt#modernise, `p2pt.js`), `bittorrent-tracker@11.2.2` (`lib/client/websocket-tracker.js`, `tracker.js`), `@thaunknown/simple-peer@10.0.11` (`lite.js`), `uint8-util@2.2.6`.

Swift files (all in `ios-native/Tsumi/WatchTogether/`):

| File | Role |
|---|---|
| `W2GJSON.swift` | JSON value with JS-string semantics (UTF-16 code units), `JSON.stringify`-compatible writer, parser, hex/random helpers, main-thread hop helpers |
| `W2GPeerLink.swift` | One WebRTC connection (simple-peer equivalent, trickle off) + delegate proxy |
| `W2GTracker.swift` | WebTorrent WebSocket tracker client (signaling) |
| `W2GSwarm.swift` | P2PT equivalent: info hash, peer id, links per peer, message framing/chunking, `block(_:)` (kick) |
| `W2GModels.swift` | `W2GUser`, `W2GMember`, `W2GChatMessage`, `W2GMessageGroup`, `W2GPlayerState`, `W2GSharedMedia`, `W2GNotice`, `W2GMediaPayload` (media/episode/key mapping), v2 view/value types (`W2GMemberView`, `W2GHostRequest`, `W2GCountdown`, overlay items, `W2GPlayerCommand`, `W2GLocalPlayback`) |
| `W2GSync.swift` | v2 pure logic, port of `sync.js`: constants, normalization, host election, expected time / drift, badges, auto-sync step, host reference, notice and request texts (no UI) |
| `WatchTogetherClient.swift` | `@MainActor @Observable` lobby client (W2GClient + session.js + page module logic), `shared` singleton, deep links, v2 protocol |
| `WatchTogetherView.swift` | SwiftUI screen (page, lobby, messages with system lines, members with crown / badge / host actions, mode, display name) |
| `W2GPlayerOverlay.swift` | v2 player UI (PlayerW2G.svelte): button + unread badge, side panel, bubbles, notices, reactions, countdown, host request prompts |

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

## v2 (PROTOCOL.md, 2026-11-14)

Contract: `common/routes/w2g/PROTOCOL.md`. Reference implementation: `common/routes/w2g/components/{sync.js, w2g.js, PlayerW2G.svelte, Lobby.svelte, User.svelte}`. The rules, thresholds and texts of `sync.js` are ported one to one in `W2GSync.swift` (same badge texts, same `describeAction` / `describeRequest` sentences, same `Guest xxxx` names), so both apps show the same thing and elect the same host.

| # | PROTOCOL section | Swift | Status |
|---|---|---|---|
| v2.1 | `init` + `displayName` (anonymous, max 32), `client: "tsumi-ios"`, `protocol: 2`; v1 peers (no `protocol`) recorded as 1 | `WatchTogetherClient.initPayload`, `receivedInit`, `W2GUser.typedName` | Done |
| v2.2 | Anonymous id kept for the app session | `w2gAnonymousId` | Done |
| v2.3 | `host { hostId, mode }`: creator is host; joiner has none until `host`; accepted only from the current host or while none is known; sent to each new peer right after `init` | `receivedHost`, `peerConnected`, `setLobby` | Done (+ provisional host after migration and rival-claim resolution like w2g.js) |
| v2.4 | Migration on host `peerclose`: smallest userId (JS string order) among self + introduced peers; self broadcasts `host` | `migrateHost`, `W2GSync.electHost` / `jsLess` | Done |
| v2.5 | Transfer, mode toggle, kick (close channel, ban userId, ignore its `init`) | `transferHost(to:)` (refused for v1 peers), `setMode(_:)`, `kick(_:)`, `ban`, `W2GSwarm.block` | Done |
| v2.6 | `player` + `by` / `action` / `rate`; v1: sender as `by`, action inferred, no-op seeks not announced; host mode ignores non-host `player` | `receivedPlayer`, `localPlayerAction`, `playerPayload` | Done (`rate` is passed along, not applied) |
| v2.7 | Host mode, non-host local action: not broadcast, snap back to expected(host), "Only the host controls playback" + Request pause / play / jump | `localPlayerAction` → `applyLocally` + `showBlocked`; system pauses (background, interruption) are not snapped back | Done |
| v2.8 | `status` every 3 s and on every state change (play, pause, seek done, buffering, media change, rate) | 0.25 s sampler of `PlayerController.syncSnapshot` + 3 s heartbeat in every state (like w2g.js) | Done |
| v2.9 | `ping` / `pong` every 10 s, RTT per userId | `pingAll`, `receivedPong` | Done |
| v2.10 | Expected time, drift, badges (In sync / ±N s / Buffering / Loading / Not in the player / Other episode / No signal / Old version), paused or idle members alive 25 s through pings | `W2GSync.expectedTime`, `syncBadge`, `selfBadge`, `memberViews(now:)` | Done |
| v2.11 | Auto-sync (setting, default on): drift > 2 s for two host heartbeats, both playing the same mediaKey, ≤ once / 10 s, silent; v1 host → off | `checkAutoSync`, `W2GSync.autoSyncStep`; setting `w2gAutoSync` (Settings > Player > Watch Together Settings) | Done |
| v2.12 | Loading a file is not a user action; once loaded, a non-host follows the host on the same episode | `PlayerController` (resume seek / autoplay / reload not reported), `onSyncReady` → `playerReady()` | Done |
| v2.13 | Resync (non-host) / Resync everyone (host, `player` `sync`) / Start together (`countdown`, 3 s, receiver counts from reception − rtt/2) | `resync()`, `resyncEveryone()`, `startTogether()`, `runCountdown` | Done |
| v2.14 | `request` / `requestReply`, host prompt Accept / Decline, 15 s timeout = declined, accepted request done as a local action | `request(_:time:)`, `receivedRequest`, `answerRequest`, `onPerformRequest` | Done |
| v2.15 | `reaction`, only the 8 emoji (bare ❤ accepted as ❤️) | `react(_:)`, `W2GSync.normalizeReaction` | Done |
| v2.16 | System lines: joins, leaves, actions ("You paused at 12:34" only in chat for own actions), requests, host/mode changes, reactions, kicks | `system(_:)`, `W2GChatMessage(system:)` | Done |
| v2.17 | `media.key` kept verbatim (sender's string) for `status.mediaKey` | `receivedMedia`, `mediaKey(for:episode:)`, `W2GSharedMedia.localKey` | Done |
| v2.18 | Player UI: button + unread badge, panel (members, chat, field, reactions, Request, host tools, Resync), bubbles 5 s, notices 3 s, floating reactions, countdown, request prompts | `W2GPlayerOverlay.swift`, `PlayerView.watchTogetherLayer`, `PlayerControlsOverlay.onShowWatchTogether` | Done (side panel; the controls hide while it is open; player shortcuts are off while it is open; hidden in the miniplayer) |
| v2.19 | Lobby page: member list with crown, badges, host actions; mode indicator; display name when not logged in; system lines | `W2GLobbyHeader`, `W2GMemberList` / `W2GMemberStrip`, `W2GDisplayNameField` (setting `w2gDisplayName`), `W2GMessageGroupView` | Done (+ host request prompts on the lobby screen) |
| v2.20 | Unknown events and fields ignored | `received` default | Done |

Player hooks added (`PlayerController`): `onSyncAction(PlayerSyncAction)` (user play / pause / seek with seek distance, rate and an `automatic` flag for system pauses), `onSyncReady()`, `syncSnapshot`, `applyRemoteState(paused:time:seekThreshold:)` (0.25 s for exact v2 times, 1.5 s for v1 whole seconds). `onLocalStateChange` is kept but no longer wired. Client hooks added: `onApplyPlayer`, `onPerformRequest`, `localPlayback` (AppWiring). In the full screen player, lobby toasts (`onNotice`) are shown as player notices.

Settings keys added to `SettingsValues` (same names as util.js): `w2gAutoSync` (default true), `w2gDisplayName` (default "").

## v2.1 (presence, source, invite) and v2.2 (independent watching), 2026-11-14

Pure rules in `W2GSync.swift`, aligned with `sync.js` v2.1 (`formatSource`, `parseMediaKey`, `formatEpisode`, `switchLabel`, `presenceOnStatus` / `presenceOnTick`, `describePresence`, `canInvite`, `acceptsInvite`, `inviteTarget`) plus the v2.2 rules (badge, auto-sync skip, host hand-off, election, `nowPlaying` episode label).

| # | PROTOCOL section | Swift | Status |
|---|---|---|---|
| v2.1.1 | `status.source` "Extension · Server" (max 80) | `PlayerController.sourceName` (set by ShellPlayback from the installed extension's name, updated on episode switches) + `syncSource` → `W2GLocalPlayback.source` → `sendStatus` | Done |
| v2.1.2 | Presence lines + 3 s notices: stopped / started / again / switched / source / buffering > 8 s / lost connection (10 s of No signal), 5 s debounce, never for ourselves | `presenceAfterStatus`, `presenceTick` (1 s), `announcePresence`; no "lost connection" right after the app resumes | Done |
| v2.1.3 | `invite { to, media, episode, key, time, paused, by }`: "Invite to watch" on rows (idle / other episode / no signal 10 s / watching on their own, v2 members, host only in host mode, we play a media) | `invite(_:)`, `W2GMemberView.canInvite`, `W2GInviteButton` (lobby rows and cards, player panel) | Done |
| v2.1.4 | Target: Join / Dismiss prompt (no timeout, one per sender) over the player, else app-wide; Join replays the media like a received `media` (even same key), then seeks to the host (same episode) or the inviter's expected time; system lines | `receivedInvite`, `acceptInvite`, `applyPendingInvite`, `W2GInvitePrompt`, `ShellWatchTogetherInvites` (in `ShellToastHost`) | Done |
| v2.2.1 | `status.following`, `status.nowPlaying { mediaId, title, episode }` (title in the app's title language, "Movie" / "Episode 5" / "S2 E5"; null outside the player) | `sendStatus`, `receivedStatus`, `W2GNowPlaying` | Done |
| v2.2.2 | "Watch on my own" toggle (player panel + lobby), remembered (`w2gWatchOnMyOwn`, same key as util.js) | `setFollowing(_:)`, `W2GPlayerPanel.independentToggle`, `W2GLobbyHeader` | Done |
| v2.2.3 | Independent: incoming `media` / `index` / `player` / `countdown` not applied; no auto-sync, no snap-back, host mode does not lock; own `media` / `index` / `player` not sent; status, chat, reactions, pings, invites still sent | `following` guards in the client | Done (the lobby's `media` is still remembered for Rejoin; remote actions still get their chat line) |
| v2.2.4 | Back on: same key → resync to the host at once; else "Rejoin {title · episode}" (starts the lobby media like a received `media`, then syncs) | `setFollowing(true)`, `rejoin()`, `rejoinLabel` | Done |
| v2.2.5 | Host turning independent hands the role to the smallest following v2 peer first (stays host if none); election skips independent members unless nobody follows | `W2GSync.handOffTarget`, `migrationCandidates` | Done |
| v2.2.6 | Rows show `title · episode` + source; badge "Watching on their own"; announcements "is watching on their own" / "is back in sync" / "is watching {title · episode}" | `W2GMemberRow`, `W2GMemberCard`, `syncBadge`, `describePresence` | Done |

UI fixes from the PC test: outgoing lobby bubbles and every accent-filled button (Request…, Accept, Join) use `W2GAccentStyle` (the accent colour, the default `AccentColor` asset being white, with black or white text by luminance); outgoing lines of the player panel are white on a light highlight. With the player panel open, host requests and invites are shown at the top of the panel (`W2GPromptStack`), so they are never under it.

Settings key added: `w2gWatchOnMyOwn` (default false, same name as util.js).

## v2.3 (joining the current playback, inviting from anywhere), 2026-11-15

Pure rules in `W2GSync.swift`, aligned with `sync.js` v2.3 (`lobbyReference`, `canJoinPlayback` → `offersJoin`, `canInvite`, `offeredMedia` / `invitePosition`, `autoStartsMedia`, INITIAL_STATE_MS = 5 s, the "Connecting…" badge).

| # | PROTOCOL section | Swift | Status |
|---|---|---|---|
| v2.3.1 | `status` every 3 s from every member, `idle` + `nowPlaying: null` outside the player; no `status` 10 s after `init` = "No signal" ("Connecting…" before) | heartbeat in every state; `W2GMember.introducedAt`; `syncBadge(…, introducedAt:)` | Done |
| v2.3.2 | Lobby media = last `media` sent or received; "watching" + reference (host on the lobby key, else — host idle / independent / without status — the smallest following member on it) | `sharedMedia`, `lobbyReferenceId()`, `W2GSync.lobbyReference` | Done |
| v2.3.3 | Join card "{reference} is watching {title · episode}": lobby page (top), player panel (open), dismissible prompt over the player while following, once app-wide on first connection | `joinOffer`, `floatingJoinOffer`, `appWideJoinOffer`, `W2GJoinCard`, `ShellWatchTogetherInvites` | Done |
| v2.3.4 | Join: lobby media through the `media` path (same key too), then the reference's expected time and state, `following` back on | `joinPlayback()`, `applyPendingJoin` (from `playerReady`) | Done |
| v2.3.5 | Nothing starts on its own: the lobby state sent to newcomers (5 s after the sender's `init`) and any `media` while not in the player are only remembered | `isSessionState(from:)`, `receivedMedia` / `index` / `player` gates | Done (the initial `player` / `index` are not applied either) |
| v2.3.6 | `canInvite` from anywhere: offered media = ours, else the lobby media while watching; eligible = idle / other key / independent / No signal (incl. 10 s after `init`); payload time = ours, else the reference's | `offeredKey()`, `W2GSync.canInvite`, `invite(_:)` | Done |
| v2.3.7 | Host tool "Invite everyone not watching" (200 ms apart) in the player panel and the lobby page | `canInviteEveryone`, `inviteEveryoneNotWatching()` | Done |
