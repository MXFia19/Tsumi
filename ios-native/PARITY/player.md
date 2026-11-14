# Parity: Video player

Svelte sources covered: `common/routes/player/PlayerPage.svelte` (PP), `common/components/MediaHandler.svelte` (MH),
`common/modules/subtitles.js` (SUB), `common/modules/streaming.js` (STR), `common/modals/manager/ManagerModal.svelte`
(MM) + `modals/manager/components/FileCard.svelte` (FC), `common/routes/settings/tabs/PlayerTab.svelte` (PT),
`common/modules/anime/animeprogress.js` (AP), the player helpers of `common/modules/anime/anime.js` (AN:
`getChaptersAniSkip`, `constructChapters`, `getMediaMaxEp`), `common/modules/episodes.js` `getSingleEpisode` (EP)
and the player side of Watch Together (`routes/w2g/WatchTogetherPage.svelte`, `components/w2g.js`).
Line numbers refer to the files at the time of the port.

Swift code: `ios-native/Tsumi/Player/` —
`PlayerController.swift` (playback logic), `PlayerView.swift` (screen, gestures, keyboard),
`PlayerControls.swift` (controls overlay, seekbar), `PlayerOverlays.swift` (subtitles, prompts, panels),
`PlayerEpisodeListSheet.swift` (episode list), `PlayerSubtitles.swift` (subtitle parsing),
`PlayerChapters.swift` (chapters, AniSkip, Jikan filler flags), `PlayerSystem.swift` (video layer, AirPlay,
Picture in Picture, Now Playing, orientation, audio session), `PlayerModels.swift` (input/output types, helpers),
`PlayerPresentation.swift` (optional full screen host + PiP minimize/restore).

Status: **done** = same behavior; **partial** = works, gap described; **n.a.** = not applicable on iOS (reason
given); **app** = the player exposes the hook, the app/other module wires it.

## Summary

| Status | Count |
|---|---|
| done | 100 |
| partial | 19 |
| n.a. | 22 |
| app (hook exposed, wired by the app) | 11 |
| **total** | **152** |

## 1. Stream loading and servers (PP + STR)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 1.1 | `loadStream`: HLS (.m3u8) via hls.js, MP4 via `<video src>` | STR 53-116 | `PlayerController.loadServer` (`AVURLAsset` + `AVPlayerItem`, HLS and MP4 natively) | done |
| 1.2 | Stream headers through the Electron proxy (`getProxyUrl`) | STR 9-14, 41-51 | `assetOptions(for:)`: `AVURLAssetHTTPHeaderFieldsKey` (+ `AVURLAssetHTTPUserAgentKey`) | done (no proxy needed) |
| 1.3 | hls.js loaded from CDN, `Hls.isSupported` fallback to native | STR 16-39, 73-83 | AVPlayer plays HLS natively | n.a. (native HLS) |
| 1.4 | `stopStream` (destroy hls, clear src) | STR 118-127 | `tearDownItem`, `close()` → `replaceCurrentItem(nil)` | done |
| 1.5 | `parseStreamResponse` / `getStreamServers` | STR 129-194 | Extensions module (`StreamResult` → `PlaybackSession`) | n.a. here (extensions agent) |
| 1.6 | `setCurrent`: servers list + active index from the file | PP 382-426 | `PlaybackSession.servers` / `selectedServer`, `begin(_:)` | done |
| 1.7 | Server menu "Servers" with `server.title` or "Server N", radio check | PP 2381-2413 | `PlayerControlsOverlay.serverMenu`, `serverName(_:)` | done |
| 1.8 | `switchServer(index)` keeps the position | PP 428-451 | `switchServer(to:)` (`PendingSeek.exact`, resumes playback) | done |
| 1.9 | Fallback to direct `src` when hls load fails | PP 393-396, 438-441 | Automatic "try next server" on initial failure (`handleFailure` → `nextUntriedServer`) + "Try Next Server" button | done (improved) |
| 1.10 | `waitForVideo` polling | PP 366-380 | Not needed (player owned by the controller) | n.a. |
| 1.11 | External subtitle URL from the extension (`file.subtitle`) | PP 400-405 | `PlaybackSession.subtitleURL` → `loadExternalSubtitle` | done |
| 1.12 | Subtitle fetched through the proxy with the stream headers | PP 273-290 | `HTTP.data(url, headers:)` with `subtitleHeaders` or the server headers | done |
| 1.13 | `updateFiles` / `handleCurrent` reset per file (time, chapters, skippable, completed, subs) | PP 292-311, 338-364 | `begin(_:)` resets all per-episode state | done |
| 1.14 | `fileEdit` → `updateCurrent` (re-resolve after File Manager edits) | PP 135-144 | — | n.a. (no file renaming: extension streams carry their media) |
| 1.15 | Deband (`VideoDeband`, KeyA, setting) | PP 321-335, 1002-1009; PT 132-137 | — | n.a. (WebGL filter; no AVPlayer equivalent without a custom compositor) |

## 2. Playback controls and state (PP)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 2.1 | Play/pause (`playPause`), big middle button + bottom button | PP 681-717, 2214-2227, 2282-2295 | `togglePlayPause()`, center button | done |
| 2.2 | Ended state shows replay icon (RotateCw) and restarts | PP 2220-2226 | `hasEnded` → "arrow.clockwise", `play()` seeks to 0 | done |
| 2.3 | `seek(time)`, `forward`/`rewind` by `playerSeek` | PP 840-851 | `seek(by:)`, `forward()`, `rewind()` | done |
| 2.4 | Middle rewind / forward buttons (touch) | PP 2180-2186, 2240-2246 | `centerControls` | done |
| 2.5 | Double-tap left/right to seek | — (new) | `PlayerView.doubleTapSeek` with cumulative feedback | done (native addition) |
| 2.6 | Tap toggles controls on touch (`toggleImmerse`), click = play/pause on desktop | PP 2156-2173, CSS 3201-3236 | `tapZone` single tap | done |
| 2.7 | Auto-hide controls (`immersePlayer`/`resetImmerse`: 1.5 s playing, stays while paused) | PP 1231-1263 | `scheduleHide` (3 s, never while paused/scrubbing) | partial (3 s instead of 1.5 s, better for touch) |
| 2.8 | Buffering spinner after 150 ms (`showBuffering`/`hideBuffering`) | PP 1265-1280, 2247-2250 | `setBuffering` (150 ms delay), spinner | done |
| 2.9 | Seekbar with progress, buffer, drag to seek (`handleMouseDown/Up`) | PP 573-587, 2262-2280 | `PlayerScrubber` (live coarse seek while dragging, precise seek on release) | done |
| 2.10 | Seekbar accent "completed" color when watched or list progress ≥ episode | PP 2270 | `isEpisodeWatched` → green accent | done |
| 2.11 | Seekbar chapters (perfect-seekbar segments + names) | PP 1460-1517, 2277 | `scrubberSegments` (marks, skippable chapters highlighted), chapter name in the scrub bubble | done |
| 2.12 | Seekbar thumbnails (`createThumbnail`, `generateThumbnails`) | PP 1519-1677 | `requestPreview` with `AVAssetImageGenerator` | partial (MP4 only; HLS has no generator support) |
| 2.13 | Time display `toTS(elapsed) / toTS(remaining)`, h:mm:ss above 1 h | PP 2364-2369; util `toTS` | `PlayerTime.format`, `timeLabel` | done |
| 2.14 | Playback rate display "x1.5" when ≠ 1 | PP 2370-2372 | bottom bar label | done |
| 2.15 | Playback rate keybinds `[` `]` `\` (±0.1, reset) | PP 1112-1141 | `adjustRate(by:)`, `setRate(1)`; plus a speed menu | done |
| 2.16 | Volume slider + persistence (cache 'volume') | PP 110, 117, 2314-2351 | `player.volume` from/to `AppSettings.values.volume`, ↑/↓ keys | partial (no on-screen slider: hidden on touch in Svelte too; hardware buttons drive system volume) |
| 2.17 | Mute (KeyM, button) | PP 802-804, 2315-2326 | `toggleMute()` (KeyM) | done |
| 2.18 | Volume boost above 100 % (WebAudio gain, KeyV, per-media memory) | PP 146-171, 768-801, 2327-2362 | — | n.a. (AVPlayer volume is capped at 1.0) |
| 2.19 | Fullscreen toggle (KeyF, button, dblclick) | PP 805-811, 2776-2788 | Player is always presented full screen | n.a. |
| 2.20 | Orientation lock to landscape in fullscreen | PP 242-267 | `PlayerOrientation.lockLandscape()` / `unlock()` | partial (hard lock needs the app delegate to return `PlayerOrientation.supportedMask`) |
| 2.21 | "Toggle Video Cover" fitWidth (KeyW) | PP 936, 1036-1042, CSS | `toggleVideoFill()`, pinch gesture, More menu | done |
| 2.22 | `checkError`: network / decode / unsupported messages | PP 1739-1791 | `PlayerFailure.from` (same titles/texts) + `PlayerErrorView` (Reload, Try Next Server, Close) | done |
| 2.23 | Error → "dismiss toast to reload the video" | PP 1750-1769 | "Reload" button (`retry()`, keeps position) | done |
| 2.24 | `saveAnimeProgress(true)` resets the saved time to 0 on errors | PP 516-522 | Not ported: the position is kept for reload / next server | partial (intentional) |
| 2.25 | "Audio Codec Unsupported" toast when no audio track | PP 172-177 | — | n.a. (AVPlayer reports undecodable media through the item error) |
| 2.26 | Exit button (X) → `closePlayer` (stop, exit PiP, clear now playing, go back) | PP 38-52, 2064-2070 | `close()` → `onClose` | done |
| 2.27 | Stats overlay (KeyI): FPS, frames, frame time, viewport, resolution, buffer, speed, name, batch files | PP 1315-1365, 2026-2061 | `toggleStats()` / `PlayerStatsView` (FPS, dropped frames, viewport, resolution, bitrate, buffer health, speed, name) | partial (no presented frames / frame time; batch file list n.a.) |
| 2.28 | Screenshot to clipboard with burned subtitles (KeyX) | PP 877-907 | `takeScreenshot()` (`AVPlayerItemVideoOutput` → `UIPasteboard`) | partial (overlay subtitles not burned in) |
| 2.29 | Keybinds overlay (` key, button) with rebinding (svelte-keybinds) | PP 937-1142, 1952-1981, 2548-2554 | `PlayerKeybindsOverlay` + hardware keyboard via `onKeyPress` (`handleKey`) | partial (fixed keys, no rebinding) |
| 2.30 | Keybind Space / N / B / M / P / S / W / C / I / O / H / ← / → / ↑ / ↓ / [ / ] / \ / ` / X | PP 939-1141 | `PlayerView.handleKey` | done |
| 2.31 | Keybind A (deband), F (fullscreen), V (gain) | PP 1002-1009, 1024-1030, 1057-1063 | — | n.a. (see 1.15, 2.18, 2.19) |
| 2.32 | Seekbar arrow keys (`handleSeekbarKey`) | PP 1793-1810 | covered by the global ←/→ | done |
| 2.33 | Cast (PresentationRequest, commented out) | PP 228-239, 868-876, 1174-1229 | AirPlay (`PlayerAirPlayButton`, `allowsExternalPlayback`) | done (AirPlay replaces Cast) |
| 2.34 | `menubarOffset` (Windows title bar) | PP 1679-1700 | — | n.a. (desktop only) |
| 2.35 | Video tracks menu (`selectVideo`) | PP 860-867, 2604-2643 | AVPlayer picks the HLS variant automatically | n.a. |
| 2.36 | Status bar / home indicator hidden in fullscreen | PP 258-265 | `.statusBarHidden`, `.persistentSystemOverlays(.hidden)`, idle timer disabled while playing | done |

## 3. Title, episode info and now playing (PP + MH)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 3.1 | Title line (`nowPlaying.title` / AniList title / file name) | PP 2072-2084 | `displayTitle` (`MediaTitle.display(titleLang)`) | done |
| 3.2 | "Episode X of Y" (`getMediaMaxEp`, zero episode, range) + " - episode title" | PP 2085-2095 | `episodeLine` (+ "Season S · Episode E" for TMDB) | done |
| 3.3 | Episode title duplicated on the title line | PP 2081-2083 | Shown once (second line) | partial (intentional, narrow screens) |
| 3.4 | Episode title hidden when it already contains the number (regex) | PP 2086, 2093 | `PlayerText.containsStandalone` | done |
| 3.5 | Episode title resolution (AniList streamingEpisodes, animappings, Kitsu, Jikan) | MH 96-152 | `PlaybackSession.episodeTitle` | app (Services resolves the title) |
| 3.6 | "The Movie" fallback / "web"/"movie" titles for single-episode media | MH 132, 138 | `episodeTitle` computed property | done |
| 3.7 | `setMediaSession` metadata: "title - episode - episodeTitle - Tsumi" + cover artwork | MH 410-426 | `PlayerNowPlaying.setMetadata` (title, "Episode N - Title", album "Tsumi", cover artwork) | done |
| 3.8 | `mediaSession.setPositionState` | PP 1281-1285 | `updateNowPlayingPlayback` (elapsed, duration, rate) | done |
| 3.9 | Media session actions play/pause/next/previous/seekforward/seekbackward | PP 1287-1294 | `MPRemoteCommandCenter` (play, pause, toggle, next, previous, skip ±`playerSeek`, scrub position) | done |
| 3.10 | Now Playing details button / KeyO (`modal.ANIME_DETAILS`) | PP 953-961, 2555-2563 | `onOpenDetails` hook (eye button, More menu, KeyO) | app |
| 3.11 | `checkForZero` (episode 0 offset) | MH 49-57 | — | partial (episode numbers are used as given by the app) |
| 3.12 | `handleRanged`: several episodes in one file → episode range | MH 67-94 | — | n.a. (extension streams are single episodes) |
| 3.13 | `findPreferredPlaybackMedia`, `handleFiles`, `cleanFiles`, `sortFiles`, `remapByTitle`, `highestOccurrence` (torrent batch resolution) | MH 157-397 | — | n.a. (torrent/local file batches are not part of the iOS app) |
| 3.14 | "Failed to identify the media" resolve prompt (`resolvePrompt`) | PP 1306-1314, 2098-2123 | — | n.a. (media always known for extension streams) |
| 3.15 | Discord Rich Presence (`setDiscordRPC`) | PP 130-133, 1823-1928 | — | n.a. (desktop only) |

## 4. Episodes, autoplay and the episode list (PP + MM + FC)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 4.1 | `checkAvail` → `hasNext` / `hasLast` (aired episodes, max episodes) | PP 455-473 | `nextEpisodeRef` / `previousEpisodeRef` (episode list first, else media counts) | done |
| 4.2 | Next / previous buttons (middle and bottom) | PP 2203-2238, 2296-2313 | center controls (hidden when unavailable) | done |
| 4.3 | `playNext` / `playLast` (`playAnime(media, ep ± 1)` reopens the extension flow) | PP 739-767 | `playNext()` / `playPrevious()` → `loadEpisode` hook | app (closure loads the stream) |
| 4.4 | Autoplay next on `ended` when `playerAutoplay` and not in Watch Together | PP 735-738, 2013 | `handleEnded` (+ `isWatchTogetherActive` hook) | done |
| 4.5 | Skip at the end of the last chapter plays next when autoplay is on | PP 822-826 | `skip()` | done |
| 4.6 | Filler / recap prompt ("This episode has been marked as a Filler, do you want to skip?" Yes/No) | PP 650-661, 1295-1305, 2124-2150 | `startAutoPlay` + `PlayerFillerPrompt` (`PlaybackSession.isFiller/isRecap`, episode list, else Jikan `PlayerEpisodeFlagsLookup`) | done |
| 4.7 | `getSingleEpisode` (Jikan filler/recap) | EP 62-73 | `PlayerEpisodeFlagsLookup.jikan` (overridable `episodeFlagsLookup`) | done |
| 4.8 | `autoPlay` only when the player page is visible (no modal) or PiP | PP 662-676 | `setExternalOverlay(presented:)` defers autoplay | done |
| 4.9 | `pagePause`: pause when details/overlays open over the player, resume after | PP 588-649 | `setExternalOverlay(presented:)` | app (the app calls it around its details sheet) |
| 4.10 | File Manager modal: "Now Playing" current card, filter field, other files, open with KeyH / More menu | MM 1-66; PP 962-973, 2531-2546 | `PlayerEpisodeListSheet` ("Episodes": now playing card, filter, episode rows, KeyH, list button) | partial (lists episodes instead of files) |
| 4.11 | FileCard badges Now Playing / Locked / Failed / Movie / Episode | FC 64-116 | Now Playing / Filler / Watched badges, episode label, thumbnail | partial (Locked/Failed n.a.: no file resolution) |
| 4.12 | FileCard episode number editing and "verify series" | FC 29-61, 76, 88-111 | — | n.a. (no file → media resolution to fix) |
| 4.13 | FileCard "behind" prompt: "You Haven't Watched Any Episodes Yet!" / "Your Current Progress Is At Episode N" + "Continue Anyway?" | FC 20-24, 117-127 | `confirmationDialog` in `PlayerEpisodeListSheet` | done |
| 4.14 | Episode list data | — | `episodeList: [EpisodeInfo]` (init / `setEpisodeList`) | app |
| 4.15 | `playFile(index)` from the stats batch list | PP 2046-2059 | — | n.a. (no batches) |

## 5. Progress and list autocompletion (PP + AP)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 5.1 | `loadAnimeProgress`: resume 5 s before the saved time | PP 475-514; AP 47-53 | `PlaybackSession.startTime` or `resumePosition` hook → `PendingSeek.restore` (−5 s) | done |
| 5.2 | Resume near the very end | PP 512-513 | Restarts from 0 when the saved time is in the last 3 % | partial (intentional improvement) |
| 5.3 | `saveAnimeProgress` every 10 s while playing, skipped while buffering | PP 516-554 | `handleTick` / `saveProgress` → `onProgress(PlayerProgressSnapshot)` | done |
| 5.4 | Save on play/pause/seek (`updatew2g`) and on close | PP 67-70, 1999-2001 | `emitLocalState` / `close()` | done |
| 5.5 | `setAnimeProgress` storage (name or mediaId + episode) | AP 56-74 | `onProgress` hook (Services `AnimeProgressService.set`) | app |
| 5.6 | `liveAnimeProgress` / `liveAnimeEpisodeProgress` (card progress bars) | AP 22-44 | `PlayerProgressSnapshot.percent` | app (cards read the progress store) |
| 5.7 | `checkCompletion` at `playerAutocompleteThreshold`% when `playerAutocomplete` | PP 1708-1737 | `checkCompletion()` → `onAutocomplete(media, episode)` once per episode | done |
| 5.8 | Completion only when episodes known or the episode aired | PP 1723-1725 | same condition (+ movies) | done |
| 5.9 | `Helper.updateEntry` (AniList/MAL progress update, "Failed to Update Progress" toast) | helper.js 150-200 | `onAutocomplete` hook | app (Services list update) |
| 5.10 | External player: 70 % cap + completion by watched time | PP 678-713, 1715-1717 | — | n.a. (external players do not report back on iOS) |
| 5.11 | Completion callback when the episode ends | PP 2013 | `onPlaybackEnded(media, episode)` | done |

## 6. Chapters and intro/outro skipping (PP + AN)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 6.1 | Embedded chapters (WPC 'chapters' from the torrent/mkv parser) | PP 1371-1378 | `PlayerChapterLoader.embeddedChapters` (AVAsset chapter metadata) | partial (MP4/MOV chapter tracks; MKV is not playable by AVPlayer) |
| 6.2 | `findChapters`: AniSkip when no embedded chapters or source = aniskip | PP 1379-1388 | `loadChapters()` / `findAniSkipChapters()` | done |
| 6.3 | `getChaptersAniSkip` (accurate + rough request, by MAL id + episode, statusCode 500 guard) | AN 151-168 | `PlayerAniSkip.chapters` | done |
| 6.4 | `constructChapters` (Intro/Episode/Preview filler chapters, gaps) | AN 105-148 | `PlayerChapterLogic.construct` | done (sorts by start first: the Svelte `sort((a, b) => a - b)` was a no-op) |
| 6.5 | `sanitiseChapters` (negative times, order, boundary overlap, zero-length, last end, first start) | PP 1460-1517 | `PlayerChapterLogic.sanitise` | done |
| 6.6 | Timestamp-like names → "Chapter N" | PP 1506-1510 | `PlayerChapterLogic.displayNames` | done |
| 6.7 | `mergeMicroSkippable` | PP 1426-1458 | `PlayerChapterLogic.mergeMicroSkippable` | done |
| 6.8 | `skippableChaptersRx` / `isChapterSkippable` (Intro, Opening, Outro, Ending, Credits, Preview, Recap; > 180 s ignored) | PP 1398-1419 | `PlayerChapterLogic.matchName` / `skippableName` | done |
| 6.9 | `checkSkippableChapters` → "Skip {name}" button | PP 1390-1397, 2251-2260 | `checkSkippableChapters`, `PlayerView.skipButton` | done |
| 6.10 | Skip button hidden while controls are hidden (immersed) | PP CSS 2960-2966 | Always visible while skippable | partial (intentional, touch UX) |
| 6.11 | `skip()` logic (chapter end, +85 s in long chapters, 90 s at start, end near the end) and KeyS "Skip Intro/90s" | PP 812-839, 1031-1035 | `skip()`, KeyS, More menu "Skip Intro/90s" | done |
| 6.12 | Auto skip | PP 1391 | `playerSkip` ("Auto-Skip Intro/Outro"), once per chapter | done (the Svelte code read `playerAutoSkip`, a key that does not exist, so its auto-skip never ran) |
| 6.13 | "Chapter Source" menu (Embedded / Aniskip) | PP 2454-2515 | More menu → `setChapterSource(_:)` | done |
| 6.14 | "Chapter Source Preference" setting (`playerChapterSkip`) | PT 146-151 | `PlayerPreferences.chapterSource` (UserDefaults, not in Core settings) | app (settings screen binds to it) |

## 7. Audio and subtitle tracks (PP + SUB)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 7.1 | Audio tracks menu "Audio Tracks" when > 1 | PP 2564-2603 | `audioMenu` (`AVMediaSelectionGroup` audible options) | done |
| 7.2 | `checkAudio`: preferred `audioLanguage`, else Japanese | PP 172-189 | `selectPreferredAudio()` (`PlayerLanguage.matches`, ISO 639-2 → BCP 47) | done |
| 7.3 | `selectAudio` (+ seek −0.2 s freeze workaround) | PP 852-859 | `selectAudio(_:)` | done (workaround not needed) |
| 7.4 | Subtitle menu with "OFF" and every track (language - name) | PP 2644-2722 | `subtitleMenu` (OFF, embedded legible options, external tracks) | done |
| 7.5 | Embedded subtitle tracks (mkv tracks via the torrent parser) | SUB 49-103 | HLS/MP4 legible `AVMediaSelectionOption`s, rendered by AVPlayer | done |
| 7.6 | Preferred subtitle language selection (single track, language, name, English, first) | SUB 84-101 | `applySubtitlePreference()` | done |
| 7.7 | "Preferred Subtitle Language" setting (`subtitleLanguage`, None) | PT 73-101 | read from `AppSettings.values.subtitleLanguage` | done |
| 7.8 | `checkSubtitle`: last subtitle per media ('lastSubtitle', OFF or track name) | PP 192-226, 2668-2714 | `PlayerPreferences.lastSubtitle` / `setLastSubtitle`, applied before the language preference | done |
| 7.9 | `cycleSubtitles` (KeyC) | PP 556-565, 1050-1056 | `cycleSubtitles()` (+ notice with the track name) | done |
| 7.10 | Subtitle offset input (`subDelay` → renderer `timeOffset`) | PP 567-571, 2723-2747 | `setSubtitleDelay(_:)`, `PlayerSubtitleOffsetPanel` (±0.1 s, ±1 s, reset) | partial (external subtitles only; AVPlayer cannot offset embedded ones) |
| 7.11 | "Add Subtitles" file input (.srt,.vtt,.ass,.ssa,.sub,.txt) from the subtitle menu and More menu | PP 1812-1821, 2373-2380, 2440-2453 | `fileImporter` → `importSubtitleFile(at:)` | done |
| 7.12 | Paste subtitles (clipboard text starting with [Script Info], subtitle files) | SUB 104-120 | "Paste Subtitles" → `pasteSubtitles()` (any supported format) | done |
| 7.13 | `addSingleSubtitleFile` naming ("Subtitles" for the URL, file name otherwise) and auto-select | SUB 127-156 | `addExternalTrack` (unique names, user files selected) | done |
| 7.14 | `convertSubText` SRT and VTT | SUB 186-220 | `PlayerSubtitleParser.parseTimed` (cue settings, `line:` → top) | done |
| 7.15 | MicroDVD `.sub` with fps line | SUB 221-232 | `parseMicroDVD` | done |
| 7.16 | Format detection when the extension is wrong | SUB 240-244 | `parse(text:fileExtension:)` fallback detection | done |
| 7.17 | ASS/SSA rendering with libass (JASSUB): styles, positioning, karaoke, fonts | SUB 158-184, 247-276 | `parseASS`: override tags stripped, drawings and positioned signs dropped, top alignment kept, italic | partial (plain text overlay, no typesetting) |
| 7.18 | VTT/HTML tags → ASS overrides, entities | SUB 247-261 | `cleanMarkup` (tags stripped, italics kept, entities decoded, `{\an8}` → top) | done |
| 7.19 | Default font / missing fonts / fast rendering / render resolution settings | PT 40-70; SUB 8-21, 158-184 | System font overlay | n.a. (no libass renderer) |
| 7.20 | `renderer.resize()` timing workarounds | PP 199, 220, 563, ... | — | n.a. (SwiftUI layout) |

## 8. Background, Picture in Picture, miniplayer (PP)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 8.1 | "Pause On Lost Focus" (`playerPause`, `handleVisibility`, resume when visible) | PP 718-734; PT 110-115 | `handleDidEnterBackground` / `handleWillEnterForeground` | done |
| 8.2 | Keep playing when `playerPause` is off | PP 721 | Background audio: AVAudioSession `.playback` + video layer detached in background | done |
| 8.3 | Not paused while in PiP | PP 721, 607 | PiP / AirPlay skip the background pause | done |
| 8.4 | Picture in Picture toggle (KeyP, "Popout Window" button) | PP 908-935, 1017-1023, 2761-2775 | `togglePictureInPicture()` (`AVPictureInPictureController` on the `AVPlayerLayer`) | done |
| 8.5 | PiP state follows play/pause (`updatePiPState`) | PP 908-916 | native (same AVPlayer) | done |
| 8.6 | Miniplayer (player keeps playing while browsing; PiP failure falls back to it) | PP 72-80, 917-935, MediaHandler `miniplayer` prop | PiP + `onMinimize` / `onRestoreFromPictureInPicture` (`PlayerPresentation` dismisses and re-presents the player) | partial (system PiP window replaces the in-app miniplayer) |
| 8.7 | Auto Picture in Picture when leaving the app | — (new) | `canStartPictureInPictureAutomaticallyFromInline` (`PlayerPreferences.autoPictureInPicture`) | done (native addition) |
| 8.8 | Audio interruptions (calls) | — | `handleInterruption` resumes when allowed | done (native addition) |

## 9. External player (PP + PT)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 9.1 | "External Player" option (More menu) / `setCurrent(current, true)` | PP 2516-2530 | More menu → VLC / Infuse (`openInExternalPlayer`) | partial (headers not forwarded, no watched-time report) |
| 9.2 | "Enable External Player" / executable path settings, WPC IPC, Android launch | PT 159-178; PP 116-129, 408-425, 678-713 | — | n.a. (desktop/Android only) |
| 9.3 | `safeduration` from media duration / `durationMap` for external playback | PP 122-129 | `safeDuration` (real duration, else current time) | done |

## 10. Watch Together hooks (PP + w2g)

| # | Svelte feature | Ref | Swift | Status |
|---|---|---|---|---|
| 10.1 | `updatew2g` → w2gEmitter 'player' `{ time: floor(currentTime), paused }` on play/pause/seeked | PP 67-70, 1999-2001 | `onLocalStateChange((paused:, time:))` from `emitLocalState` (deduplicated like `_playerStateChanged`) | done |
| 10.2 | 'playerupdate' → apply remote time/paused | PP 54-57; w2g.js 98-106 | `applyRemoteState(paused:time:)` (seeks only beyond 1.5 s, no echo, queued while loading) | done |
| 10.3 | 'index' emitted on file change | PP 745, 759 | `onIndexChange(Int)` (episode list index, else episode number) | done |
| 10.4 | 'setindex' → `playFile` | PP 58-60 | `applyRemoteIndex(_:)` | done |
| 10.5 | No autoplay of the next episode during a session | PP 737 | `isWatchTogetherActive` hook | app |
| 10.6 | Share the started title (`shareNowPlaying`, 'media' event) | ExtensionResults `launchPlayer` | `onEpisodeStarted(PlaybackSession)` | app |

## 11. Settings read by the player (PT, `common/modules/util.js` defaults)

| # | Setting | Ref | Swift | Status |
|---|---|---|---|---|
| 11.1 | `playerAutoplay` ("Autoplay Next Episode") | PT 104-109 | `handleEnded`, `skip()` | done |
| 11.2 | `playerPause` ("Pause On Lost Focus") | PT 110-115 | `handleDidEnterBackground` | done |
| 11.3 | `playerAutocomplete` / `playerAutocompleteThreshold` | PT 116-131 | `checkCompletion()` | done |
| 11.4 | `playerSeek` ("Seek Duration") | PT 138-145 | `forward`/`rewind`, double tap, remote skip interval | done |
| 11.5 | `playerSkip` ("Auto-Skip Intro/Outro") | PT 152-157 | `checkSkippableChapters` | done |
| 11.6 | `playerChapterSkip` | PT 146-151 | `PlayerPreferences.chapterSource` | done (see 6.14) |
| 11.7 | `subtitleLanguage` / `audioLanguage` | PT 73-101; PP 180 | `applySubtitlePreference` / `selectPreferredAudio` | done |
| 11.8 | `volume` | PP 110, 117 | `configurePlayer`, `adjustVolume` | done |
| 11.9 | `playerDeband`, `font`, `missingFont`, `disableSubtitleBlur`, `subtitleRenderHeight`, `enableExternal`, `playerPath` | PT 40-70, 132-137, 159-178 | — | n.a. (see 1.15, 7.19, 9.2) |

## Wiring notes for the app step

- Create `PlayerController(session:episodeList:)` on the main actor, set the hooks, then
  `PlayerPresentation.shared.present(controller)` with `.playerPresentationHost()` attached to the root view
  (or present `PlayerView(controller:)` in your own `fullScreenCover`; it closes the player when it disappears
  unless it was minimized to Picture in Picture, see `closesWhenViewDisappears`).
- Extensions `ResolvedPlayback` maps 1:1: `PlaybackSession(media:, episode:, servers:, selectedServer: selectedIndex, subtitleURL:)`.
- `loadEpisode` should run the extension flow for the requested `EpisodeRef` (default extension, else picker)
  and return the new `PlaybackSession`; throw `CancellationError` when the user cancels.
- `onProgress` → `AnimeProgressService.set(mediaKey: media.id, episode:, currentTime:, safeDuration:)`;
  `resumePosition` → `AnimeProgressService.record(mediaKey:episode:)?.currentTime`.
- `onAutocomplete` → list progress update (Helper.updateEntry equivalent).
- Orientation lock: return `PlayerOrientation.supportedMask` from the app delegate's
  `application(_:supportedInterfaceOrientationsFor:)`.
- Settings screen: bind "Chapter Source Preference" to `PlayerPreferences.chapterSource` (and optionally an
  "Auto Picture in Picture" toggle to `PlayerPreferences.autoPictureInPicture`).
