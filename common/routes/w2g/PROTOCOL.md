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

## Events

### v1 events (unchanged, still required)

| type | payload | sent when |
|---|---|---|
| `init` | the viewer object (`{ id, name, avatar: { medium } , … }`) or `{ id }` | to each peer on connect |
| `media` | `{ media, episode, key }` (see `session.js` SHARED_MEDIA_FIELDS) | a title / episode is started; the host also sends it to newcomers |
| `index` | `{ index }` | the player's file index changes |
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
