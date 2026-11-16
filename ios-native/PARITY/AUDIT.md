# Independent parity audit: Svelte app vs native iOS app

Date: 2026-11-14, branch `nettoyage`. Read-only review of `common/` and `capacitor/src` against `ios-native/Tsumi/`. The other PARITY files were used only as an index; every row below was checked in code. Svelte paths are relative to `common/` and Swift paths to `ios-native/Tsumi/`. Desktop-only features (Electron, Discord RPC, tray / exit action, external player, DoH, ANGLE, updater, devtools, log files) are counted as n.a.

## Summary

About 555 user-visible features, settings and flows were checked across the player, extensions, browse UI, services / accounts / notifications / Watch Together, and the shell / settings.

| Result | Count |
|---|---|
| OK | ~425 |
| n.a. on iOS | ~50 |
| Problems | **72** (17 missing, 26 partial, 29 different) |
| High | **1** |
| Medium | **10** |
| Low | **61** |

The core flows are wired end to end:
- browse → details → extension → player
- progress saving and list auto-complete at the threshold
- AniList / MAL OAuth with token refresh
- deep links
- notifications while the app is open
- all five Watch Together event types, both sent and handled

Every SwiftUI view type is referenced and every tab and sheet can be reached. The single high item is a cache bug, not a missing screen.

One reviewer finding was rejected: "search sends TRENDING_DESC where Svelte sends no sort". Svelte's `alRequest` already defaults `sort` to `TRENDING_DESC` (`modules/anilist.js:254`), so the two apps behave the same.

## Problems

Type: M = missing, P = partial, D = different behavior.

### High

| # | Feature | Type | Svelte ref | Swift location | Fix |
|---|---|---|---|---|---|
| H1 | Disk cache file names collide | D | `modules/cache.js:719-796` (keyed by the full JSON string) | `Core/Cache.swift:22-27` (file name = `base64(key).prefix(200)`, so only the first ~150 bytes of the key count) | Name files by SHA-256 of the full key, or store the key in `Entry` and compare it on read. |

How H1 breaks:
- `searchAllIDs` (`Services/AniListService.swift:544-574`) pages through the same id list. Each page key is `"al.ids."` + sorted JSON beginning with `{"id":[...]`, so with about 20 or more ids every page maps to the same file.
- The last page written overwrites the earlier ones.
- After a relaunch (memory cache empty, TTL 24-30 min, or offline), reading page 1 returns the last page with `hasNextPage = false`, and the earlier pages are lost.
- Affected: Continue Watching and list sections, Recent Subs / Dubs, schedule, and notification checks.

### Medium

| # | Feature | Type | Svelte ref | Swift location | Fix |
|---|---|---|---|---|---|
| M1 | In-app miniplayer (keeps playing while you browse; also the fallback when PiP fails) | P | `App.svelte:81-88,125-140`, `components/Miniplayer.svelte`, `routes/player/PlayerPage.svelte:917-935` | PiP only: `Player/PlayerController.swift:1614-1637`, `Player/PlayerPresentation.swift` | Add a floating SwiftUI mini player reusing the player layer for when PiP is unavailable or off. Today, leaving the player without PiP stops playback. |
| M2 | ASS/SSA typesetting (styles, `\pos`, signs, karaoke, fonts) | P | `modules/subtitles.js:158-184` (libass) | `Player/PlayerSubtitles.swift:199-273` (plain text; drawings and positioned lines dropped) | Render ASS with libass on an overlay layer, or at least keep position and colours. |
| M3 | Next / previous episode from the player | D | `PlayerPage.svelte:750,764` → `playAnime` → default extension or the picker; the picker is the fallback on failure (`modals/extension/ExtensionModal.svelte:8-18`) | `UI/Shell/ShellPlayback.swift:174-187,245-259` | Swift silently re-resolves with the same extension's top result, so a result the user picked by hand (e.g. a dub variant) is lost, and a failure only shows "Failed to load Episode N". Remember the chosen result and fall back to `PlaybackRequestCoordinator.play` (picker). |
| M4 | Export / Import / Reset cover all settings | P | `routes/settings/tabs/AppTab.svelte:7-17,67-70,151`: the whole settings blob, including `extensions`, `cardAudio`, `hentaiAnnounce`, `playerChapterSkip`, `cards` | `UI/Shell/ShellAppSettingsView.swift:147-161` and `UI/Shell/SettingsView.swift:316-325` only handle `SettingsValues` | Installed extensions (`Extensions/ExtensionManager.swift`, key `tsumi.extensions.v1`), `cardAudio`, `hentaiAnnounce`, the NOTONLIST release flag, chapter source, auto-PiP and card type are never exported or imported; extensions and card type are not reset. Move them into `SettingsValues`, or add them to export / import / reset. |
| M5 | Import from Clipboard accepts Svelte / desktop exports | D | `AppTab.svelte:7-17` (any JSON; merged with defaults on load) | `ShellAppSettingsView.swift:147-154` (strict `JSONDecoder` on `SettingsValues`) | A desktop export (array-shaped `customSections`, `westernSections`, `homeSections`) or any partial JSON fails with "Failed to import settings". Add a tolerant decoder that maps the Svelte shapes. |
| M6 | Saved settings survive an app update that adds a key | D | `modules/settings.js:62` (`{...defaults, ...storedSettings}`) | `Core/Settings.swift:100-106` (synthesized `Codable`, no custom `init(from:)`) | When a key is missing, decoding throws and every setting silently resets to defaults (including the home layout; `applySvelteLayoutOnce` has already run). Add `init(from:)` with `decodeIfPresent` and defaults. |
| M7 | List edits synced to other profiles keep their dates | D | `components/Scoring.svelte:84,105`; `modules/helper.js:202,229,232` (`...variables` carries the entry's dates) | `Services/MediaListService.swift:491,500` (`fuzzyDates(startedAt: nil, completedAt: nil, …)`) | Synced profiles get today as the start / completion date, which overwrites their real dates. Pass the current entry's `startedAt` / `completedAt`. |
| M8 | AniList outage detection | M | `modules/networking.js:39,60-93` (one "AniList Outage" toast, later error toasts muted, outage status bar `components/Status.svelte`) | none: `Services/AniListService.swift:343-346` posts an error for every non-2xx; `ShellConnectionBanner` only tracks the network path | Detect the "temporarily disabled" 403, show one outage banner or toast, and mute repeats. |
| M9 | Per-episode Dub / Sub airing rows in the episode list (when Card Audio is on) | M | `modals/details/components/EpisodeList.svelte:13-48,376-402` | none; `Services/AnimeScheduleService.swift:856` `dubEntry(for:)` has 0 callers | Port `dubbedEpisode` and render it in the episode rows when `ServiceSettingsExtras.cardAudio` is on. |
| M10 | Dub schedule: suspended shows and episode ranges | D | `modules/anime/anime.js:848-878` ("Suspended", "Episode a ~ b") | `Services/AnimeScheduleService.swift:836-850` | Suspended entries get a fake node 6 years ahead, so they show a ~2032 countdown, and ranges are lost. Carry `delayedIndefinitely` and the range into `AiringEpisode` and show "Suspended". |

### Low

| # | Feature | Type | Svelte ref | Swift location | Fix |
|---|---|---|---|---|---|
| L1 | Details opened over the player | D | Svelte keeps playing (`modules/navigation.js:48`, `playPage` never set) | `UI/Shell/ShellPresenters.swift:130,151` → `setExternalOverlay` pauses | Don't pause for the details sheet if parity is wanted. |
| L2 | Episode title when the episode list arrives late | P | `components/MediaHandler.svelte:96-152` | `Player/PlayerController.swift:431-434` (`setEpisodeList` only replaces the list) | Fill `session.episodeTitle` when it is nil and refresh Now Playing. |
| L3 | Seekbar thumbnails on HLS | M | `PlayerPage.svelte:1536-1552` | `PlayerController.swift:531` (no generator for HLS) | Cache frames from `videoOutput` while playing. |
| L4 | Episode 0 handling (`hasLast`, "of N", watched accent) | P | `PlayerPage.svelte:458-473`; `MediaHandler.svelte:49-57` | `PlayerController.swift:250-254,293-302` | Pass a `zeroEpisode` flag into the session. |
| L5 | Controls auto-hide delay | D | 1.5 s (`PlayerPage.svelte:1251`) | 3 s (`Player/PlayerView.swift:286`) | Document it, or align. |
| L6 | Skip button while the controls are hidden | D | hidden (`.immersed .skip`) | always shown (`PlayerView.swift:118-120`) | Document it, or hide it. |
| L7 | Auto-skip intro / outro | D | reads a non-existent `playerAutoSkip`, so it never fires (`PlayerPage.svelte:1391`) | reads `playerSkip` (`PlayerController.swift:1436`) | Swift does what the setting says; keep it and fix the Svelte key. |
| L8 | Pause On Lost Focus | D | `PlayerPage.svelte:718-734` | Bypassed when auto-PiP starts (`PlayerController.swift:903`); auto-PiP defaults to on (`Player/PlayerModels.swift:253-256`) | Default auto-PiP to off, or tie it to `playerPause`. |
| L9 | Playback speed kept between episodes | D | `PlayerPage.svelte:1112-1141` (kept for the app session) | Resets to 1 for each controller (`PlayerController.swift:63`) | Store the rate in `PlayerPreferences`. |
| L10 | Completion and skip checks after a seek while paused | P | `PlayerPage.svelte:2003-2004` (run on every `timeupdate`) | Only while playing (`PlayerController.swift:884-886`) | Also run both checks when a seek completes. |
| L11 | Saved progress after a playback error | D | reset to 0 (`PlayerPage.svelte:516-522`) | kept (`PlayerController.swift:763-778`) | Intentional; document it. |
| L12 | Stats overlay (presented frames, frame time) | P | `PlayerPage.svelte:2037-2044` | `PlayerController.swift:1749-1774` | Only partly possible with AVPlayer; document it. |
| L13 | Screenshot includes subtitles | P | `PlayerPage.svelte:884-895` | Video frame only (`PlayerController.swift:1715-1729`) | Draw the active subtitle cues onto the image. |
| L14 | Keyboard: rebinding, O toggles, key repeat, focus after sheets | P | `PlayerPage.svelte:1959` | `Player/PlayerOverlays.swift:225`, `PlayerView.swift:47,70-72` | Add the `.repeat` phase and restore keyboard focus after every dismissal. |
| L15 | Drag and drop of subtitle files | M | `modules/clipboard.js:16-17`, `subtitles.js:109-113` | none | Add `.dropDestination(for: URL.self)` on `PlayerView`. |
| L16 | Browser globals for Sora modules (DOMParser, `crypto`, `window`, Headers / Response, FormData, Blob) | P | `modules/extension.js:129-149` (runs in the WebView) | `Extensions/SoraPrelude.swift` | Add shims, at least `crypto.getRandomValues`, a `window` / `self` alias and Headers. |
| L17 | Episode number when matching falls back to the first episode | D | `modals/extension/DefaultLoadingModal.svelte:290-295`, `ExtensionResults.svelte:279-283` | `Extensions/PlaybackResolver.swift:195-205` | Use the matched episode's number when the reference has no season. |
| L18 | Closing the loading dialog | D | Auto-play keeps running and still opens the player (`DefaultLoadingModal.svelte:49-51`) | Cancels resolution (`Extensions/PlaybackRequestCoordinator.swift:211-214,267-272`) | Document it. |
| L19 | Picker header image fallbacks | P | `modals/extension/components/ExtensionResults.svelte:358-381` | `Extensions/ExtensionPickerView.swift:54-61` (no fallback when a URL 404s) | Use the hq thumbnail and a real fallback chain. |
| L20 | Collapsed result group size | D | One grid row (`ExtensionResults.svelte:449-451`) | Always 5 cards (`ExtensionPickerView.swift:140`) | Cosmetic. |
| L21 | Catalog cards (preview, play, list status, context menu) | P | `routes/catalogs/CatalogPage.svelte:110-112` | `Extensions/CatalogsView.swift:376-395` (poster and title only) | Reuse the standard browse card. |
| L22 | Catalog item that maps to an anime opens AniList details | P | `modules/stremio.js:222` → `tmdb.js:154-157` | `Extensions/StremioAddon.swift:363-367` (keeps the TMDB `Media`) | Open the AniList entry when `anilistId` is set. |
| L23 | Servers with an unusable URL | D | Kept (`modules/streaming.js:139-164`) | Dropped before counting (`Extensions/StreamResponse.swift:128-150`) | Document it. |
| L24 | Extension error toasts | D | `toast.error` (`ExtensionResults.svelte:149,230,286`) | Inline banner (`ExtensionPickerView.swift:28-31`) | Cosmetic. |
| L25 | Delete extension from the context menu | D | ConfirmButton (`routes/settings/tabs/ExtensionTab.svelte:206`) | Deletes immediately (`Extensions/ExtensionSettingsView.swift:229-233`) | Add a confirmation dialog. |
| L26 | Pull-to-refresh race (iOS-only bug) | D | n/a | `Extensions/ExtensionManager.swift:53-59,90-93`, `Extensions/ExtensionCalls.swift:37-39` | A cancelled old load clears the new load's state, so playing right after a refresh can report "Default extension not found". Guard with a per-task token. |
| L27 | Episode card Sub / Dub text gated by Card Audio | D | `components/cards/EpisodeCard.svelte:205-207` | `UI/Browse/BrowseEpisodeCards.swift` `audioLabel` (no gate) | Gate it on `ServiceSettingsExtras.cardAudio`. |
| L28 | Card Type setting (small / full) | P | `InterfaceTab.svelte:70-75` | `@AppStorage("tsumi.browse.cards")`; no settings row; not reset (`SettingsView.swift:316-325`) | Add the picker to Interface settings and reset it in `resetAll`. |
| L29 | Card-size buttons on Schedule | M | `routes/search/components/SearchBar.svelte:371-372` | `UI/Browse/ScheduleView.swift` header | Reuse `cardModeButtons`. |
| L30 | Tapping a card | D | First tap shows the preview, second opens details (`modules/click.js:218-260`) | Tap opens details, long press shows the preview (`UI/Browse/BrowseCards.swift`) | Intentional iOS idiom; document it. |
| L31 | Details refresh after a list edit | P | `modals/details/DetailsModal.svelte:37-44` (mediaCache subscription) | `UI/Browse/MediaDetailView.swift` (`media` is a snapshot) | Read the live media from the store in the header. |
| L32 | Recommendations order and "N likes" | P | `DetailsModal.svelte:762`, `components/cards/SmallCard.svelte:126-135` | `UI/Browse/MediaDetailSections.swift:57`, `BrowseCards.swift:226` | Fetch the rating, sort by it, show likes. |
| L33 | "Recap" badge in the episode list | M | `EpisodeList.svelte:333,350-353` | `UI/Browse/MediaDetailEpisodes.swift` (Filler only) | Add `isRecap` from Jikan. |
| L34 | Episode titles that only repeat the series title are hidden | P | `EpisodeList.svelte:335` (`matchPhrase`, 0.1 fuzzy) | `MediaDetailView.swift:62-69` (exact match only) | Use `ServiceText.matchPhrase`. |
| L35 | Dub episode count on the cover audio label | P | `components/AudioLabel.svelte:27-33` | `BrowseCards.swift:170-191` (icon only) | Count the aired dub episodes. |
| L36 | Rotated cover for hentai titles with no banner | M | `components/banner/FullBanner.svelte:32-35`, `EpisodeCard.svelte:147` | `UI/Browse/HomeBanner.swift`, `BrowseEpisodeCards.swift` | Rotate the cover fallback. |
| L37 | Kitsu fallback for year / season | M | `SmallCard.svelte:145-148`, `FullCard.svelte:74-90` | `UI/Browse/BrowseMediaInfo.swift:61-83` (uses `startDate` only) | Optional Kitsu lookup. |
| L38 | Synopsis headings, lists, tables | P | `DetailsModal.svelte:236-321` | `UI/Browse/BrowseStyle.swift:70-93` (inline markdown only) | Use full markdown parsing. |
| L39 | Episode preview card text | D | Episode summary (`EpisodePreviewCard.svelte:120-131`) | The media description (`BrowseEpisodeCards.swift`) | Add the summary to `EpisodeFeedItem`. |
| L40 | Unreleased episodes look | D | Striped and blurred (`EpisodeList.svelte:444-452`) | Dimmed with a clock icon (`MediaDetailEpisodes.swift`) | Cosmetic. |
| L41 | AIRING badge pulse | M | `SmallCard.svelte:159-174` | `BrowseAiringBadge` | Cosmetic. |
| L42 | Following popover fields (banner, colour, "Follows you", join date, donator, stats) | P | `modals/details/components/User.svelte:59-131` | `BrowseUserCard` | Extend `AniListFollowingEntry`. |
| L43 | Schedule title filter | D | Filters the AniList query (`routes/SchedulePage.svelte:41`) | Local filter, also applied to western items (`ScheduleView.swift:61-69`) | Acceptable; document it. |
| L44 | Section "see all" filters when leaving Search | D | Cleared (`routes/search/SearchPage.svelte:117`) | Kept (`UI/Browse/SearchView.swift`) | Call `leaveSection()` on disappear. |
| L45 | Section-title badge | D | Only for user-list sections (`SearchBar.svelte:350`) | Every section (`UI/Browse/BrowseFilters.swift:268`) | Gate on `context.userList`. |
| L46 | Reload only the home rows whose feed changed | P | `routes/home/HomePage.svelte:193-219` | `Services/HomeSectionsService.swift:199-210` (`changedFeeds` written, never read) | Reload only the changed rows. |
| L47 | Episode labels "Episodes a ~ b", "Season N", "Movie" | P | `EpisodeCard.svelte:218-234` | `BrowseEpisodeCards.swift` `episodeLabel` | Port the range and "Movie" rules. |
| L48 | iPad hardware keyboard in the browse UI (Esc closes details, arrow keys, Enter) | M | `modules/navigation.js`, `modules/click.js:422-571`, `DetailsModal.svelte:365` | none in `UI/Browse` | At least `.keyboardShortcut(.cancelAction)` on the details close button. |
| L49 | Two-column details layout on wide screens | M | `DetailsModal.svelte:330-345,822-866` | Single column | Size-class layout on iPad. |
| L50 | Image search from a pasted or dropped image or image URL | P | `modules/anime/anime.js:24-54`, `modules/clipboard.js` | Photo picker only (`SearchView.swift:220-226`); `AnimeHelpers.traceAnime(imageURL:)` has 0 callers, yet the toast still says "You can also paste an URL to an image." | Add a paste / drop entry, or fix the toast text. |
| L51 | Settings, sync, notifications and watch history per profile | D | `modules/cache.js:374` (`cacheID` = viewer id), `settings.js:55,226,246` | Global (`Core/Settings.swift:94`, `Services/AccountStore.swift`, `Services/AppNotificationsService.swift:168`, `Services/AnimeProgressService.swift:29`) | Key these stores by account id, or document it. |
| L52 | Notification action buttons (View Anime / Watch / Resume) and hero image | P | `capacitor/src/main/app.js:24-46,113-129` | `AppNotificationsService.swift:445-463` (no `UNNotificationCategory`, cover image only) | Register categories and prefer `heroImage`. |
| L53 | Global paste handler (token, `code=&state=`, AniList / MAL links) | P | `modules/settings.js:85-123` | `Services/Services.swift:104` (`parseWebLink`), only reached through deep links | Optional paste entry calling `Services.handle`. |
| L54 | Login reuses the browser session | D | System browser keeps cookies (`components/Profiles.svelte:49,56`) | `prefersEphemeralWebBrowserSession = true` (`Services/ProfilesService.swift:26`) | Set it to false. |
| L55 | Query Complexity setting | M | `AppTab.svelte:125-132`, `modules/anilist.js:409` | none (0 grep hits) | Add it, or keep "Complex" and document. |
| L56 | Multi-line Watch Together chat (Shift+Enter) | P | `routes/w2g/components/Lobby.svelte:70-77` | `WatchTogether/WatchTogetherView.swift:196-200` (single-line `TextField`) | `TextField(axis: .vertical)`. |
| L57 | Notification checks while the app is closed | M | Desktop tray keeps polling (`modules/anilist.js:203-206`, `modules/anime/animeschedule.js:55-61`); the Capacitor build had no background runner either | `AppNotificationsService.swift:242` `backgroundRefresh()` has 0 callers; `Info.plist:44-47` has only `audio` | Register a `BGAppRefreshTask` that awaits `backgroundRefresh()`. |
| L58 | Changelog tab | M | `routes/settings/tabs/ChangelogTab.svelte`, `routes/settings/components/Changelog.svelte:21` (GitHub releases API) | none; `ShellAppSettingsView.swift:5-8` says the feed no longer exists (not verified) | Restore it if the feed exists, otherwise drop it from the Svelte app too. |
| L59 | UI Scale | M | `InterfaceTab.svelte:33-41`, `modules/themes.js:27-29` | none | Rely on Dynamic Type and document it, or add a scale factor. |
| L60 | Custom theme (CSS Variables) | M | `InterfaceTab.svelte:42-47`, `modules/themes.js` | none | Optional accent colour setting; otherwise document. |
| L61 | Expandable Lists (`toggleList`, mobile-only in Svelte) | M | `InterfaceTab.svelte:55-60` | none (comment only, `UI/Browse/MediaDetailSections.swift:68`) | Add the toggle, or document that lists always scroll. |

## Settings keys never read by the Swift app

Every key in `SettingsValues` has at least one reader outside the settings screens (grep count per key, excluding `Core/Settings.swift` and the settings views). `audioLanguage` is read but has no settings row; Svelte has none either. Keys from Svelte `defaults` (`modules/util.js:556-607`) with no Swift reader:

**Parity gaps (rows above):**
- `queryComplexity` (L55)
- `toggleList` (L61)
- `uiScale` (L59)
- `presetTheme` / theme variables (L60)

**Read, but stored outside `SettingsValues`, so not exported, imported or reset (M4):**
- `cards`: `@AppStorage tsumi.browse.cards`
- `cardAudio`, `hentaiAnnounce`: `ServiceSettingsExtras`
- `playerChapterSkip`: removed (chapter source is automatic)
- `extensions`: `ExtensionManager`, `tsumi.extensions.v1`

**n.a. on iOS:**
- libass / WebGL options: `playerDeband`, `font`, `missingFont`, `disableSubtitleBlur`, `subtitleRenderHeight`
- Desktop only: `expandingSidebar`, `enableDoH`, `doHURL`, `enableRPC`, `closeAction`, `angle`, `disableMiniplayer`, `enableExternal`, `playerPath`

**Svelte-side dead keys (no reader in Svelte either):**
- `westernAnnounce`: card at `InterfaceTab.svelte:143-152`, no default, no reader
- `playerAutoSkip`: misspelled read, see L7

## Unreachable screens and unwired hooks

**Screens.** None are unreachable. A scripted check found every `View`, `ViewModifier` and `ToolbarContent` type referenced. ProfilesView, NotificationsView, ExtensionSettingsView, CatalogsView (a tab on iPad, pushed from Search on iPhone), and the loading, picker and server dialogs (`ShellPlaybackDialogHost`) are all presented.

**Hooks never assigned:**
- `PlayerController.onPlaybackEnded`: called at `PlayerController.swift:798`, assigned nowhere. Harmless, because autoplay is internal.
- `ProfilesService.authenticateOverride`: harmless.

**Service methods with 0 callers:**
- `AppNotificationsService.backgroundRefresh()` (L57)
- `AnimeScheduleService.dubEntry(for:)` (M9)
- `AnimeHelpers.traceAnime(imageURL:)` (L50)
- `AnimeHelpers.aniSkipChapters`: duplicate of the player's AniSkip
- `AniListService.searchCompound`
- `MALDubsService.isFullyDubbed`
- `AnimeMappingsService.episodeRange` and `loadedTmdbInfo`
- `HTTP.postJSON`
- `ExtensionManager.callDefault`, `callAll`, `isEnabled`
- `ExtensionCalls.extractDetails`
- `ExtensionStreamParser.servers`
- `StremioRequestCache.clear`
- `PlaybackRequestCoordinator.ready`, `consumeReady()` and `play(media:episodeNumber:)`
- `PlayerController.minimize()`

**Dead presenters, replaced by the Shell hosts:**
- `PlayerPresentationHost` / `.playerPresentationHost()` (`Player/PlayerPresentation.swift:53-75`)
- `PlaybackRequestHost` / `.playbackRequestPresenter()` (`Extensions/PlaybackRequestCoordinator.swift:275-291`)

**Never-populated fields:**
- `PlaybackSession.startTime`, `subtitleHeaders`, `isFiller` and `isRecap` are never set by `ShellPlayback` (`ShellPlayback.swift:158,179`), so the branches at `PlayerController.swift:467,484,494-497` never run. Filler still works through the episode list.
- `HomeSectionsService.changedFeeds` is written but never read (L46).
- `SearchRequest` / `HomeSectionsService.search(_:)` are unused.
- `ExtensionManager.loadErrors` / `loadingKeys` are filled but never shown. Svelte does not show load errors either.

## Needs a device check (not counted)

- **"Now Playing" restore while in PiP.** `ShellPlayback.restorePlayer` (`UI/Shell/ShellPlayback.swift:102-108`) stops PiP programmatically. If AVKit does not call the restore delegate in that case, `pictureInPictureDidStop` (`PlayerController.swift:1649-1656`) sees `isMinimized` and closes the player instead of restoring it.
  - Fix: set `restoringFromPiP = true` before `pip.stop()` on this path.

## Self-reported PARITY claims found false or stale

**services.md**
- 13.2 (disk cache, H1)
- 4.12, 4.15, 4.16 (sync dates, M7)
- 6.3, 6.12 (helpers never called)
- 10.7 (notification actions)

**extensions.md**
- 1.35 (extensions are outside the exported settings)
- 8.16 (the context-menu delete has no confirmation)
- 5.17 (episode number)
- 1.22 (browser globals incomplete)

**ui-browse.md**
- 1.7 (per-feed reload)
- 3.3 (tap behaviour)
- 4.10 (Card Audio gate)
- 6.23 (paste image / URL)
- 6.27 (Card Type)
- 7.2, 7.6 (suspended dubs, ranges, card-size buttons)

**player.md**
- 3.10, 4.9, 7.6, 7.7 and 8.1 describe Svelte behaviour that does not exist (the eye button is never shown, details do not pause, `handleTracks` has no caller, pause-on-blur is Electron-only)
- 2.20 is stale: the orientation lock is done

**ui-shell.md**
- 4.10 is stale only in the working tree: "Warnings / Successes" filtering matches Svelte in the uncommitted edit to `Services/ServiceSupport.swift:633-644`. The committed version (HEAD) still filters as All / Errors / None, so in HEAD the row is correct and the setting is wrong.

**watch-together.md**
- The "wiring left to the app" notes are stale: the hooks are wired in `UI/Shell/AppWiring.swift:28-50`
