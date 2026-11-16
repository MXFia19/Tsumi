# Watch Together protocol (v2)

This is the contract shared by the Svelte app (`common/routes/w2g/`, desktop and Capacitor) and the native iOS app (`ios-native/Tsumi/WatchTogether/`). Both apps must implement the whole document, so any client can join any lobby.

## Transport (unchanged)

- Participants find each other through P2PT on the public WebSocket trackers, using the lobby code as the identifier. They then talk over WebRTC data channels in a full mesh: everyone connects to everyone.
- Every message is one JSON text frame `{ "type": string, "payload": any }`.
- Unknown `type`s and unknown payload fields MUST be ignored, never treated as errors. v1 clients ignore every v2-only event, and a v2 client keeps working with a v1 peer (see "Compatibility").
- Time values are in seconds (number, may be fractional), unless the name ends in `At`. `…At` values are milliseconds since the epoch on the sender's clock, and are only compared with the same sender's other values.

## Identity

- A participant's `userId` is the `id` of its `init` payload: the AniList / MAL viewer id when logged in, otherwise a random 16-character hex id kept for the session. Compare ids as strings (`String(id)`).
- A data-channel peer is mapped to a `userId` by the `init` it sent. Before that `init` arrives, use the peer's transport id.
- v2.5: two devices of one account share a `userId`. Each lobby instance also sends a random `init.sessionId`, and clients tell members apart by their member key (see "v2.5 additions"). Events still name members by `userId` on the wire.

## Events

### v1 events (unchanged, still required)

| type | payload | sent when |
|---|---|---|
| `init` | the viewer object (`{ id, name, avatar: { medium } , … }`) or `{ id }` | to each peer on connect |
| `media` | `{ media, episode, key }` (see `session.js` SHARED_MEDIA_FIELDS) | a title / episode is started; the host also sends it to newcomers |
| `index` | `{ index }` | the player's position changes: a file index on desktop, an episode-list index on iOS (see v2.5 `index.kind`) |
| `player` | `{ time, paused }` | local play, pause or seek |
| `message` | chat text (string) | chat |

### v2 additions

`init` gains optional fields:
- `displayName`: a name typed by an anonymous user, shown instead of the id.
- `client`: `"tsumi-desktop" | "tsumi-android" | "tsumi-ios"`.
- `protocol`: `2`.

`player` gains optional fields. v1 senders omit them, and receivers then use the sender's `userId` as `by` and infer `action`:
- `by`: the `userId` of the person who caused the change.
- `action`: `"play" | "pause" | "seek" | "sync"`. `"sync"` is a correction that must not be announced.
- `rate`: the playback rate.

New events:

| type | payload | who sends | effect |
|---|---|---|---|
| `host` | `{ hostId, mode }` (`mode`: `"everyone"` or `"host"`) | the current host | Sets the lobby host and the control mode. Sent to each new peer right after `init`, and to everyone when it changes. |
| `status` | `{ state, time, mediaKey, rate, sentAt }` (`state`: `"playing" \| "paused" \| "buffering" \| "loading" \| "idle"`) | everyone | Heartbeat used by the sync check. See "Sync check" for when it is sent. |
| `ping` | `{ id, sentAt }` | everyone | The receiver answers right away with `pong`, echoing the payload. |
| `pong` | `{ id, sentAt }` (echoed) | everyone | Round-trip time = now − `sentAt`, measured on the original sender's clock. |
| `request` | `{ id, kind, time? }` (`kind`: `"pause" \| "play" \| "seek"`) | anyone but the host | Asks the host for a change; everyone shows it in the chat as a system line. |
| `requestReply` | `{ id, accepted, by }` | the host | Answers a `request`. If accepted, the host performs the action itself, which sends a normal `player` event. |
| `kick` | `{ userId }` | the host | The target leaves the lobby and shows "You were removed from the lobby". The others close its channel and ignore its `init` for the rest of the session. |
| `reaction` | `{ emoji }` | everyone | A floating emoji over the video and a chat line. One of 😂 😮 😍 😢 👏 🔥 👀 ❤️ only; drop anything else. |
| `countdown` | `{ time, seconds, startAt }` | the host, or anyone in `everyone` mode | Everyone seeks to `time` and pauses, shows a 3-2-1 overlay for `seconds` (1–10), then plays. It is used for "Start together" and "Resync everyone". |
| `system` | none (local only, never sent) | — | Chat lines created locally: joins, leaves, actions, requests. |

## Host and control mode

- The lobby creator is the first host. A joiner has no host until it receives `host`. While `hostId` is unknown, the joiner behaves as in `everyone` mode.
- Accept `host` only from the current host, or from anyone while no host is known.
- **Host migration:** when the host's channel closes (`peerclose`), every remaining client picks the smallest `userId` among itself and its connected peers (string comparison). The client that picks itself becomes host and broadcasts `host { hostId: self, mode: <previous mode> }`.
- **Transfer:** the host sends `host` with another `hostId`.
- **`mode: "everyone"`** (default): anyone's play / pause / seek is broadcast and applied, as in v1.
- **`mode: "host"`**: only the host's `player` events are applied; receivers ignore `player` events whose `by` is not the host.
  - A non-host who plays, pauses or seeks locally does NOT broadcast it. The client snaps the player back to the host's expected position and state (see "Sync check"), and shows "Only the host controls playback" with a "Request pause" (or "Request play") action, which sends `request`.
- **Host actions:**
  - control mode toggle
  - transfer host
  - kick
  - "Start together" (sends `countdown` from the current time)
  - "Resync everyone" (sends `player` with `action: "sync"`)
  - accept or decline requests

## Who did what

Each applied `player` event with a `by` and an action other than `sync` shows a short notice over the video (about 3 s) and adds a system chat line:
- "Alice paused at 12:34"
- "Alice resumed"
- "Alice jumped to 12:34 (+1:30)"

A local action shows "You paused" etc. only in the chat, not over the video. Joins and leaves are system chat lines: "Alice joined", "Alice left".

## Sync check

**Heartbeat.** Each client in the player sends `status` every 3 s while playing, and immediately on every state change (play, pause, seek done, buffering start / end, media change). It sends `ping` to every peer every 10 s and keeps the last round-trip time per peer.

**Expected time.** For a member M with last `status` s received at local time r:

  expected(M) = s.time + (s.state == "playing" ? (now − r)/1000 × s.rate + rtt(M)/2000 : 0)

**Drift** = expected(M) − localTime. Each member's badge shows:
- "In sync": same `mediaKey`, |drift| ≤ 1.5 s, same play / pause state
- "+N s ahead" / "N s behind": otherwise, rounded to 0.1 s
- "Buffering", "Loading", "Not in the player" (`idle`), "Other episode" (different `mediaKey`)
- "No signal": no `status` for 10 s

**Auto-sync.** A setting, on by default. A non-host whose drift against the host stays above 2 s, with both clients playing the same `mediaKey` for two consecutive heartbeats, seeks to expected(host), at most once every 10 s.
- This is a silent `sync` correction: it is not announced, and a non-host never broadcasts it as a `player` event.
- In `everyone` mode the reference is the host as well.
- The player and the lobby both have a manual "Resync" button that does the same thing at once.

## UI requirements (both apps)

**In the player** (only while in a lobby):
- A Watch Together button, with an unread-messages badge, opens a panel with:
  - the member list (host crown, sync badge, kick / transfer for the host);
  - the chat history with system lines;
  - a message field;
  - the reaction row;
  - "Request pause" / "Request play" for non-hosts in `host` mode;
  - host tools: mode toggle, Start together, Resync everyone;
  - Resync.
- **Incoming chat:** while the panel is closed, a new message shows as a bubble over the video for 5 s ("Alice: hello").
- **Host requests:** the host sees each incoming request as a small prompt with Accept / Decline. It times out after 15 s and counts as declined.
- **Overlays:** the action notices and floating reactions described above, plus the countdown overlay.

**In the lobby page:**
- the same member list with crown, badges and host actions;
- the control mode indicator;
- a display-name field when not logged in;
- system lines in the chat.

## Compatibility with v1 peers

- A v1 peer sends `player` without `by`. Use its `userId`.
- A v1 peer never sends `status`, so show "No signal" (or "Old version") instead of a drift, and skip auto-sync against it. If the host is v1, auto-sync is off.
- In `host` mode a v1 non-host may still broadcast `player`. It is ignored as described above, and the v1 peer is snapped back by the next host `player` event.

## Clarifications (agreed while implementing both apps)

1. "Resync everyone" sends `player` with `action: "sync"` (the host's time and paused state), not a countdown.
2. `status` is sent every 3 s in every state, not only while playing. A member with no `status` for 10 s is "No signal", but a paused or idle peer that still answers pings counts as alive for 25 s.
3. `countdown.startAt` is on the sender's clock, so receivers count down from (local receive time − rtt/2). `seconds` is rounded and clamped to 1–10 (default 3).
4. `rate` is shared but not applied to the local player.
5. Host migration: if the elected client (smallest id) is someone else, the host is provisional, and a `host` claim from anyone is accepted until one arrives. If two clients claim host, the smaller `userId` keeps it.
6. The media key compared by the sync check is the sender's `media.key`, used verbatim.
7. The host role cannot be transferred to a v1 peer (no `protocol: 2` in its `init`).
8. Outside the player, other members' badges show "Playing" / "Paused" instead of a drift.
9. Seeks and autoplay while an episode is loading are not broadcast. Once loaded, the player snaps to the host if both are on the same episode.
10. Your own actions appear only in the chat ("You paused at 12:34"). Remote ones get the 3 s notice plus a chat line.
11. v1 peers show "Old version" and are skipped by auto-sync.

## v2.1 additions: presence, source and invite

All of these are additive: older v2 clients ignore the new field and event.

### `status.source`

`status` gains an optional `source` field: a short human-readable string for what the sender is playing from. The format is the extension or addon name, then the server or stream label if known, joined with " · ", e.g. `"AnimePahe · Server 2"`. Leave it empty when unknown. It is informational only, and never compared for sync.

### Presence announcements (no new event)

Each client derives these from the `status` changes of every other member. Each one is a system chat line plus a 3 s notice over the video while in the player. The UI wording is localized as the rest of the app; the English text below is the reference.

| from → to | announcement |
|---|---|
| `playing` / `paused` / `buffering` / `loading` → `idle` | "Alice stopped watching" |
| `idle` → `loading` / `playing` / `paused` | "Alice is watching again" (or "Alice started watching" if it is the first status) |
| `mediaKey` changes, while the new state is not `idle` | "Alice switched to {episode label}", e.g. "Episode 5" or "S2 E5" when a season is known, or "another title" when the media differs |
| `source` changes, with the same `mediaKey` and both values non-empty | "Alice changed source: {source}" |
| `buffering` lasts more than 8 s | "Alice is buffering…", once per buffering period |
| `No signal` lasts 10 s (no status and no pong) | "Alice lost connection", once until a status arrives again |

Rules:
- Announcements are debounced: the same member and kind announces at most once every 5 s.
- Your own changes are never announced.
- A member's first `status` after joining announces nothing except "started watching". Joins and leaves keep their existing lines.

### `invite` (new event)

| type | payload | who sends | effect |
|---|---|---|---|
| `invite` | `{ to, media, episode, key, time, paused, by }` | anyone in `everyone` mode, the host only in `host` mode | `to` is the target `userId`. `media` / `episode` / `key` have the same shape as the `media` event. `time` / `paused` are the sender's current position. Broadcast to everyone; every client except `to` ignores it. |

On the target:
- The invite shows as a prompt that does not time out but can be dismissed: "Alice invites you to watch {title} · {episode label}" with "Join" and "Dismiss". It shows over the player if the target is in it, otherwise as an app-wide prompt or toast with a Join action.
- A new invite from the same sender replaces the previous one.
- Join plays that media and episode through the same path as a received `media` event, even when the key equals the one already shared. Once loaded, it seeks to the inviter's expected time (the inviter's `time` plus elapsed time if not paused), or to the host's expected time if the host is in the same episode.
- A system line on the target: "Alice invited you to watch".
- A system line on the sender only: "You invited Bob".

On the sender:
- Every member row (lobby page and player panel) shows an "Invite to watch" button when that member is `idle`, "Other episode", or has had no signal for 10 s, provided the sender is in the player with a media.
- In `host` mode the button only shows for the host.

## v2.2 additions: independent watching and "who watches what"

These additions are backward compatible: a missing field means the v2.1 behaviour.

### `status.following` and `status.nowPlaying`

`status` gains two optional fields:
- `following` (boolean, default `true` when absent): whether the sender follows the lobby's playback.
- `nowPlaying` (`{ mediaId, title, episode }` or `null`): what the sender has open.
  - `mediaId` is the `media.id` of the shared media shape.
  - `title` is the display title in the sender's language.
  - `episode` is a short episode label such as "Episode 5", "S2 E5" or "Movie".
  - It is `null` when the sender is not in the player.

### Independent mode (a per-lobby toggle, "Watch on my own")

Both the player panel and the lobby page have the toggle. It is off by default, and each client remembers the last choice for the next lobby.

While `following` is false, the client:
- does not apply incoming `media`, `index`, `player` or `countdown` events;
- is never auto-synced and never snapped back, and host mode doesn't restrict its controls;
- does not broadcast its own `media`, `index` or `player` events, so it never drags the others;
- keeps sending `status` (with `following: false` and `nowPlaying`), chat, reactions and pings;
- may send `invite` to suggest what it is watching.

When the toggle is turned back on:
- If the local media key equals the lobby's shared `media.key`, resync to the host right away.
- Otherwise, show a "Rejoin {title · episode}" action. It starts the lobby media through the same path as a received `media` event, then syncs. Nothing changes until it is used.

If the host turns `following` off, the host role moves first, as a normal transfer. It goes to the smallest `userId` among the connected v2 peers whose last `status` has `following` not false. If there is no such peer, the client stays host.

### What everyone sees

- **Member rows** (lobby page and player panel) show what each member watches: `nowPlaying.title · nowPlaying.episode`, plus the `source` when known.
- **Independent members** show the badge "Watching on their own" instead of a drift. They are skipped by auto-sync and by host election (unless nobody follows), and they still get the "Invite to watch" button.

Presence announcements, in addition to v2.1, with the same debounce:

| change | announcement |
|---|---|
| `following` true → false | "Alice is watching on their own" |
| `following` false → true | "Alice is back in sync" |
| `mediaKey` changes while `following` is false | "Alice is watching {title · episode}" (replaces "switched to") |

## v2.3 additions: joining the current playback and inviting from anywhere

### Status from every member

Every v2 client sends `status` every 3 s from the moment it is in a lobby, not only while in the player. Outside the player it sends `state: "idle"` and `nowPlaying: null`, so members who aren't watching are known at once. A v2 member that has sent no `status` 10 s after its `init` is "No signal".

### Lobby media and "watching"

The **lobby media** is the last `media` event sent or received: `{ media, episode, key }`. The host sends it to each newcomer right after `init` and `host`, as before.

The lobby is **watching** when the host's last `status` has a `mediaKey` equal to the lobby key and a state of `playing`, `paused`, `buffering` or `loading`. If the host is idle or independent, it is watching when any following member's status matches the same way. That member (the host, or else the first such member by smallest `userId`) is the **reference** for the position.

### Join the current playback (late joiners and anyone not watching)

When the lobby is watching and the local client is not on the lobby media (local state `idle`, a different local `mediaKey`, or independent):
- **Lobby page:** a card at the top, "{reference name} is watching {title · episode}", with a **Join** button.
- **Player panel:** the same card while it's open. Outside the panel, show it as a dismissible prompt only when the client is following (not independent).
- **First connection:** when the client joins a lobby that is already watching, show it once as an app-wide prompt (toast with a Join action), wherever the user is.

**Join** works like a joined invite:
1. It plays the lobby media through the same path as a received `media` event, even when the key is unchanged.
2. Once loaded, it seeks to the reference's expected time and takes its play/pause state.
3. It sets `following` to true if the client was independent.

Nothing ever starts on its own: the user always presses Join.

### Invites from anywhere

`canInvite` no longer requires the inviter to be in the player:
- **Offered media:** the inviter's own media if it is in the player with one, otherwise the lobby media while the lobby is watching. With no media to offer there is no button.
- **Eligible members:** a member whose state is `idle`, whose `mediaKey` differs from the offered key, who is independent, or who is "No signal" (including a v2 member with no `status` 10 s after its `init`).
- **`host` mode:** only the host can invite. In `everyone` mode anyone can.
- **Payload time and paused state:** the inviter's own playback when it is playing the offered media, otherwise the reference's expected time and state.

**Host tool "Invite everyone not watching":** sends one `invite` to each eligible member, 200 ms apart. It is shown in the player panel and on the lobby page while the host has a media to offer and at least one member is eligible.

## v2.4 additions: voice chat and the shared queue ("Up next")

Everything here is additive. A v2.3 client ignores the new events and fields, never joins voice and never has a queue; a v2.4 client keeps working with it.

### `init.features`

`init` gains an optional `features` array of strings. A v2.4 client sends `["voice", "queue"]`. A missing or malformed value means no feature.
- `"voice"`: the member can join voice. Voice links are only made with members that announce it.
- `"queue"`: the member understands the queue events. The queue only exists when the host announces it. With a host without `"queue"` (v2.3), the queue UI is hidden on everyone's side.

`protocol` stays `2`: the features say what a v2 client can do.

### Voice chat

#### Events

| type | payload | who sends | effect |
|---|---|---|---|
| `voice` | `{ joined, muted, speaking }` (booleans) | everyone | The sender's voice state, sent to every peer when it changes and to each new peer right after `init` (with `status`). `muted` and `speaking` mean nothing while `joined` is false. `speaking` is always false while `muted`. |
| `voiceSignal` | `{ id, sdp: { type: "offer" \| "answer", sdp } }` | members in voice | Signaling of the audio link between the sender and the receiver. It is sent to that peer only, never broadcast. `id` is chosen by the offerer and echoed in the answer. |

#### Audio links

Audio does not go through the data channel connections. P2PT creates them with the `lite` build of simple-peer, which has no media support, and it keeps up to three backup connections per peer, so two clients could pick different ones. Each pair of members who are both in voice has one dedicated `RTCPeerConnection`, signaled through `voiceSignal`:
- The same STUN servers as the data channels: `stun:stun.l.google.com:19302` and `stun:global.stun.twilio.com:3478`. Unified plan, one audio transceiver (Opus), no data channel.
- **Who offers:** of two members who are both `joined`, the one with the smaller `userId` (string comparison) sends the offer. The other one only answers, so two offers never cross.
- **No trickle:** a description is sent once ICE gathering is complete, or 3 s after the first candidate, or after 8 s at most. Every candidate is in the SDP.
- The answerer sets the offer, adds its microphone track to the audio transceiver (or answers receive-only without a microphone), then answers.
- An offer received while a link with that member exists replaces that link. An answer whose `id` is not the pending offer is ignored. An offer from a member who is not `joined` here, or received while we are not `joined`, is ignored.
- **Retry:** when a link fails (ICE `failed`, or not connected 20 s after the offer), both sides close it. While both are still `joined`, the offerer sends a new offer after 3 s, at most 5 times in a row (the count resets once a link connects).
- **Closing:** a link is closed when either side leaves voice (`voice` with `joined: false`), when the member leaves the lobby or is kicked, and when we leave the lobby.

#### Microphone, mute, push-to-talk

- **Join voice** is opt-in, a toggle on the lobby page and in the player panel. It is never on by default, not even in the next lobby.
- The microphone is captured with echo cancellation, noise suppression and automatic gain control on. Without a microphone (denied or missing), the member still joins and listens, with `muted: true`.
- **Mute:** the microphone track is disabled, so it sends silence, and `muted` is true.
- **Push-to-talk** (setting, off by default): the microphone is muted except while the push-to-talk key (desktop, configurable, `T` by default) or the hold-to-talk button (iOS) is held. `muted` says whether the member is transmitting right now.
- **Speaking:** each client measures its own processed microphone level: the peak amplitude from 0 to 1 over about 100 ms. It sets `speaking` to true as soon as the level reaches 0.05 while transmitting, and back to false after 600 ms below that. A `voice` is sent on each change.

#### Listening

- Every remote voice is played. **Per-member mute and volume** (0–100 %) are local only and kept for the lobby. They don't change what the others hear.
- **Ducking** (setting, on by default): while we are in voice and at least one other member in voice is `speaking`, isn't muted locally and doesn't have its volume at 0, the video plays at 30 % of its volume. It goes back to normal when nobody speaks. The user's own volume setting is never changed.
- Leaving voice (toggle off, leaving the lobby, being kicked) stops the microphone, closes every link and sends `voice` with `joined: false`. On iOS, the audio session goes back to what the player uses.

#### UI

- **Member rows** (lobby page and player panel) show an "in voice" mark, a muted mark, and a speaking ring around the avatar. While we are in voice, a member in voice gets a menu with Mute and a volume slider.
- **Voice controls** (lobby page and player panel): Join voice / Leave voice, Mute / Unmute, and "Hold T to talk" or a hold button when push-to-talk is on.
- **Player overlay:** while we are in voice, a microphone button sits next to the Watch Together button. It mutes and unmutes, or is the hold-to-talk button on iOS with push-to-talk on. While the panel is closed, the names of the members speaking show over the video.

### Shared queue ("Up next")

The host owns the queue. Everyone else keeps a copy of the last `queue` it received from the host, so a new host can take it over.

#### Item

```
{
  id,          // string, random, chosen by the member who adds it
  media,       // the shared media shape of the `media` event (session.js SHARED_MEDIA_FIELDS):
               //   AniList id, or "tmdb-<id>" with idTmdb / isTmdb, and format ("MOVIE" for a movie)
  episode,     // as in `media`: a number, or { number, season, localEpisode }
  key,         // the adder's media key of media + episode, used verbatim like `media.key`
  title,       // display title in the adder's language (max 120)
  cover,       // cover image URL or "" (max 500)
  addedBy,     // userId of the member who added it
  addedByName, // that member's display name, kept for when it leaves
  votes        // userIds that up-voted it, only in `queue`
}
```

#### Events

| type | payload | who sends | effect |
|---|---|---|---|
| `queue` | `{ items: Item[], pending: Item[], policy: "open" \| "approval", rev }` | the host | The whole queue. It is sent to everyone after each change, and to each new peer after `host` and the lobby media. `rev` grows by one with each change. Accepted only from the current host, or from anyone while no host is known or the host is provisional. |
| `queueAdd` | `{ item }` (no `votes`) | anyone | Sent to the host only. The host appends it to `items` when the policy is `open`, or to `pending` when it is `approval`. It is ignored when the same episode is already there as an item or a suggestion (same `key`, or same `media.id` and the same episode, since apps may write the key differently), or when the list is full (50 items, 20 pending). The host sets `addedBy` to the sender's `userId` and `addedByName` to its name. |
| `queueVote` | `{ id, up }` | anyone | Sent to the host only. Adds (`up: true`) or removes the sender's vote on an item. |
| `queueRemove` | `{ id }` | the member who added the item | Sent to the host only. Removes that member's own item or suggestion. |

Everything else only the host can do. It changes its own copy, then broadcasts `queue`:
- reorder (move up, move down);
- remove any item;
- accept or decline a suggestion (accepted ones go to the end of `items`);
- switch the policy: "Members need approval" (`approval`) or not (`open`, the default);
- **Play now**.

The host's own additions always go straight to `items`.

#### Play now and auto-advance

**Play now** (host only, following): the host removes the item from the queue and makes it the lobby media. It sends `media` with the item's `media`, `episode` and `key` (`key` used verbatim), and starts it itself through the same path as a received `media`. Followers already watching move to it, as with any `media`. The others get the Join card. Once the host's player has loaded it, the host starts the existing countdown: `countdown` from its position, 5 s. Members still loading snap to the host when they're ready, as before.

**Auto-advance:** when the host's episode ends while it follows the lobby and `items` isn't empty, the host sees "Up next: {title · episode}" with a 5 s countdown, **Play now** and **Cancel**. When the countdown ends, it does Play now with the first item. With an empty queue, the end of an episode behaves as before.

A `countdown` is only applied by a member whose player is on the lobby media (or isn't playing anything), never to another episode.

#### Host changes and late joiners

- The host sends `queue` to each newcomer, so late joiners get the current queue.
- A member who becomes host (transfer or migration) keeps its last copy, including `pending`, and broadcasts it as a `queue` at once.

#### System lines

Each client compares each new `queue` with the previous one. It adds "Alice added {title · episode} to Up next" for each new item and "Alice suggested {title · episode}" for each new suggestion ("You added…" for our own). When one of our suggestions is gone without being added, it adds "The host declined your suggestion: {title · episode}". The first `queue` after joining announces nothing.

#### UI

- **Where:** the queue shows on the lobby page and in the player panel. Each row has the cover, title, episode label ("Episode 5", "S2 E5", "Movie"), "added by {name}", the vote count with the member's own vote toggle, and the host tools (move up, move down, Play now, remove). The adder can remove its own item.
- **Pending:** suggestions waiting for approval are listed for everyone. The host gets Accept / Decline. The suggester can cancel its own.
- **Adding:** members add with "Add to Watch Together queue" on each episode of the episode list and on the details page, while in a lobby whose host supports the queue. The lobby page and the player panel have "Add next episode", which queues the episode after the lobby media (or after the last queued episode of the same title).
- **Host toggle:** "Members need approval".
- **Prompt:** while the panel is closed, the host gets a notice for each new suggestion.

## v2.5 additions: limits, validation, devices of one account, host rules

Everything here is additive: the new fields are optional and ignored by older clients, and a v2.5 client keeps working with them.

### Limits and validation

Every incoming event goes through one validation layer before it is used (desktop `sync.js` `validateEvent`, iOS `W2GSyncV25.swift` `validateEvent`). An event that does not fit is dropped, never half-applied. Unknown types are dropped too.

- **Size:** an event is at most 256 000 UTF-16 units of JSON text, checked before parsing.
- **Transport (P2PT chunks):** a chunk index `c` is a whole number below 64; a message is at most 256 000 units; at most 4 messages per peer are being reassembled at once (the oldest goes), each dropped 30 s after its first chunk; all peers together buffer at most 2 000 000 units. Chunks are reassembled per peer, and a message with a missing chunk is dropped. (P2PT's own handler kept chunks at any index a peer chose: one chunk with `c: 4294967294` froze the app.)
- **Times** (`player.time`, `status.time`, `countdown.time`, `request.time`, `invite.time`): a number in 0…10 000 000 s. Anything else drops the event.
- **Episodes** (`media`, `invite`, queue items): a number, or `{ number, season?, localEpisode? }`, each in 0…1 000 000. A missing episode is allowed in `media` and `invite`.
- **`index.index`:** a whole number in 0…9 999, never an object.
- **Ids** (`userId`, `hostId`, `by`, `to`, request, item and offer ids): a non-empty string of at most 64 characters, or a finite number. `sessionId`: 4 to 64 letters, digits, `-` or `_`.
- **Text:** names and display names at most 32 characters; chat messages at most 2048; media keys at most 200 (a longer `mediaKey` counts as none); SDPs at most 64 000; `queue.rev` a whole number (clamped).
- **Media:** only the shared media shape is kept (session.js SHARED_MEDIA_FIELDS) with the right types; ids are numbers or short text ids (`[A-Za-z0-9:._-]`, e.g. `tmdb-123`); image URLs must be http(s).
- **`init`** is reduced to `{ id, name?, displayName?, avatar?: { medium?, large? }, picture?, client?, protocol?, features, sessionId? }`, and v2.5 clients only send that (not the whole AniList or MyAnimeList viewer).
- **Rate limit:** `message`, `reaction`, `request`, `invite`, `queueAdd`, `queueVote` and `queueRemove` from one member: a burst of 20, then 5 per second. The others are dropped.
- **Names:** another member whose name is "You" is shown as "You (abcd)" (the first characters of its id), so it can't pass for us in system lines.

### Devices of one account: `init.sessionId`

- `init.sessionId`: a random id (16 hex characters) of this lobby instance, new for each lobby joined.
- **Member key:** `userId + "#" + sessionId`, or the `userId` alone for a client without `sessionId`. Clients key members by it: member list, `status`, RTT, presence, voice, invites, requests. "#" sorts below the characters of the ids, so keys sort like their `userId`s and elections agree with older clients.
- `host` gains `hostSession`: the `sessionId` of the named host. Without it (older sender), the host is the sender when it names its own `userId`, else the smallest member key with that `userId`.
- `invite` gains `toSession`: only that device of the account takes it.
- Voice offerer: of two members that both send a `sessionId`, the smaller member key offers; with an older client, the smaller `userId` (what it compares).
- `kick` still names a `userId`: every device of that account is removed. A host can't kick another device of its own account.
- `player.by`, `requestReply.by`, queue `addedBy` and votes stay `userId`s.

### Host rules

- **Authority comes from the sender's data channel**, not from a payload field. In `host` mode, a `player`, `media`, `index` or `countdown` is only applied when it comes from the host's own channel (`player.by` only says whose name to show). `kick`, `requestReply` and `queue` are only taken from the host's channel, as before.
- **Two hosts:** a host that receives a rival claim and yields (the smaller member key keeps the role) broadcasts `host { hostId: winner }`, so the members who still follow it (they only take `host` from their current host) move to the winner.
- **Migration:** a v1 client (no `protocol`) is never elected. If the elected client does not claim the role with `host` within 10 s, it is skipped and the election runs again among the others (ourselves included). A confirmed host resets the skipped list.
- **A host that came back** as a new channel of an older app (same member key while its previous channel is not closed yet) does not know it is host: a member that sees it sends it `host { hostId: it }`.
- **iOS:** a host that goes to the background while not playing hands the role over first (as "Watch on my own" does), since iOS suspends the app soon after.

### Sync

- `player`, `countdown` and `index` gain `mediaKey`: the sender's `status.mediaKey` when it sent the event. A receiver whose player is on another media key ignores the event (no check when either side has none). Without `mediaKey` (older sender), a receiver whose player is on another media than the lobby's ignores `player`, as before.
- **`index.kind`:** `"file"` (desktop: position in the player's file list) or `"episode"` (iOS: position in the player's episode list). Without `kind`, it is `"episode"` when the sender's `init.client` is `"tsumi-ios"`, else `"file"`. Each client only applies the kind it uses (desktop `"file"`, iOS `"episode"`) and ignores the other.
- **Position of the host:** the host's last applied `player` event only stands for its position when the host sends no `status` at all (v1). A v2 host that is idle, loading or silent has no position, so nobody is snapped back to an old time. The last `player` event is also forgotten when the lobby media changes.
- **Playback rate:** a member on the same episode at another rate shows "Different speed (1.25×)", and auto-sync leaves it alone (each jump would drift again). The rate is still not applied to the local player.
- **RTT:** a pong sample above 5 s, or for a ping sent before the app was frozen or suspended (two ticks more than 5 s apart), is dropped. The others are smoothed: rtt = rtt + (sample − rtt) × 0.3.
- **Missed `peerconnect`:** when the first message of a peer arrives on a data channel the client never introduced itself on, it does so then (`init`, `status`, `voice`, ping, and the lobby state when host).

### Voice

- The retry limit (5 offers in a row, 3 s apart) holds whatever asks for a link: only the retry timer offers a failed link again. The count resets when the member joins voice again (its `voice.joined` goes from false to true) or when we join voice again.

### TURN server (optional)

A setting on both apps (`w2gTurnUrl`, `w2gTurnUsername`, `w2gTurnCredential`), empty by default. When it holds `turn:` or `turns:` URLs (several may be separated by commas or spaces), that TURN server is added to the STUN servers of the data channels and of the audio links, from the next lobby. It helps members behind CGNAT or strict firewalls.

### Lobby codes

A code or link is read as its first run of exactly 16 hex characters, in lower case (`tsumi://w2g/CODE/`, `…/w2g/?c=CODE`, a code pasted in capitals). Opening the link of the lobby we are already in only shows it.
