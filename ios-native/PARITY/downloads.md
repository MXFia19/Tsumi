# Parity: Offline downloads

Desktop sources: `common/modules/downloads/downloads.js` (DL: queue mirror, fresh stream resolution, offline playback,
offline list updates), `common/modules/downloads/resolve.js` (RES: title score, episode match, subtitles, server pick),
`electron/src/main/downloads/manager.js` (MGR: queue, direct / HLS download, files), `electron/src/main/downloads/hls.js`
(HLS: playlist planning), `electron/src/main/downloads/routes.js` (local serving), `common/routes/downloads/DownloadsPage.svelte`
(PAGE), `common/components/DownloadButton.svelte`, `common/components/DownloadNextButton.svelte`,
`common/routes/settings/components/DownloadSettings.svelte`.

Swift code: `ios-native/Tsumi/Downloads/` — `DownloadCenter.swift` (queue, sessions, resolution, offline playback),
`DownloadSessions.swift` (storage paths, background session delegate), `DownloadHLS.swift` (playlist planning),
`DownloadLocalServer.swift` (loopback server), `DownloadProgressQueue.swift` (offline list updates), `DownloadsView.swift`
(screen, episode button, Download Next menu, settings section, toolbar button), `DownloadModels.swift`.
Hooks in shared files: `PlaybackRequestCoordinator.play` (downloaded episode plays from disk), `ShellPlayback.wire`
(next / previous downloaded episode, offline list updates, player "Download Episode"), `PlayerController.onDownloadEpisode`
+ `PlayerControls` More menu, `MediaDetailEpisodes` (row button), `MediaDetailHeader` (Download Next), `ShellToolbar` /
`ShellNavigation` (`ShellRoute.downloads`), `ShellToasts` (offline banner opens the downloads), `AppWiring` (start,
background session events), `HTTP.data` (file URLs), `Settings.swift` (`downloadQuality`, `downloadMaxConcurrent`).

| Feature | Desktop | iOS | Status |
|---|---|---|---|
| Fresh stream at download start (same extension / search result / server, never another episode) | DL `resolveFreshStream` | `DownloadResolver.resolve` (PlaybackResolver strict) | done |
| Player stream used only when a fresh resolution fails (< 15 min) | MGR `freshSeed` | `DownloadCenter.resolve` (`seed`) | done |
| Direct file, resumable | Range requests, resumed after pause / quit | background URLSession download task, resume data | done |
| HLS quality (Download Quality setting) | variant picked by HLS `pickVariant` | same pick (`DownloadHLS.pickVariant`), AVAssetDownloadTask min bitrate | done |
| HLS with AES-128 keys / init segments / byte ranges | segments + keys + local playlist | segment-by-segment download + loopback server (AVFoundation does not keep AES-128 keys offline) | done |
| Clear HLS | segments + local playlist (hls.js) | AVAssetDownloadURLSession (.movpkg), headers via AVURLAsset options; falls back to segments if it fails | done |
| Separate audio rendition | local master + audio playlist | AVFoundation default rendition / local master (segments) | done |
| HLS subtitle renditions (EXT-X-MEDIA SUBTITLES) | not saved | not saved | partial (external subtitle files are saved) |
| DRM / DASH / web page / torrent refused with a message | MGR | `DownloadCenter.classify` / `DownloadHLS.drmReason` | done |
| Subtitles saved | every subtitle of the stream, the preferred language plays | the stream subtitle (French first, like the iOS parser) | done (iOS keeps one) |
| Cover + metadata.json next to the media | MGR | `saveExtras`, `writeMetadata` | done |
| Excluded from backup | n.a. (user folder) | Downloads folder + .movpkg `isExcludedFromBackup` | done |
| Queue, simultaneous downloads, auto-retry with a fresh link | MGR `pump`, `AUTO_RETRIES` | `pump`, `autoRetries` | done |
| Pause / resume / cancel / retry / delete | PAGE | `DownloadsView` | done |
| Downloads continue after a restart | resumed on launch | background sessions reattached on launch (`handleEventsForBackgroundURLSession`) | done |
| Downloads screen (cover, title, episode, size, progress, storage used) | sidebar page | toolbar button on every tab + offline banner (pushed screen, works offline) | done |
| Download folder setting | Settings > App (default Videos/Tsumi) | n.a. (app sandbox) | n.a. |
| Episode list button | `DownloadButton` | `DownloadEpisodeButton` | done |
| Download Next Episodes (details) | `DownloadNextButton` | `DownloadNextMenu` | done (TMDB shows: per episode) |
| Player "Download Episode" | More menu | More menu | done |
| A downloaded episode plays from disk (also next / previous) | `playAnime` hook | `PlaybackRequestCoordinator.play` + `loadEpisode` hooks | done |
| Local progress offline | animeprogress (local) | AnimeProgressService (local) | done |
| AniList / MAL list updates made offline sent when back online | DL `updateEntryOrQueue` (localStorage) | `DownloadProgressQueue` (UserDefaults) | done |
