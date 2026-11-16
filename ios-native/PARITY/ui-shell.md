# Parity: App shell (navigation, settings, profiles, notifications, toasts) and block wiring

Svelte sources covered (abbreviation used in the tables):

| Abbr. | File |
|---|---|
| APP | `common/App.svelte` |
| RT | `common/routes/Router.svelte` |
| SB | `common/components/navigation/Sidebar.svelte` (+ `SidebarLink.svelte`) |
| NB | `common/components/navigation/Navbar.svelte` (+ `NavbarLink.svelte`) |
| NAV | `common/modules/navigation.js` (page / modal / history) |
| ST | `common/components/Status.svelte` (+ `modules/networking.js` status) |
| SP | `common/routes/settings/SettingsPage.svelte` |
| SC | `common/routes/settings/components/SettingCard.svelte`, `components/inputs/ClampedNumber.svelte`, `components/inputs/ConfirmButton.svelte`, `components/CustomDropdown.svelte` |
| PT | `common/routes/settings/tabs/PlayerTab.svelte` |
| IT | `common/routes/settings/tabs/InterfaceTab.svelte` |
| HS | `common/routes/settings/components/HomeSections.svelte` |
| ET | `common/routes/settings/tabs/ExtensionTab.svelte` (UI ported by the Extensions block) |
| AT | `common/routes/settings/tabs/AppTab.svelte` |
| CT | `common/routes/settings/tabs/ChangelogTab.svelte` + `components/Changelog.svelte` |
| UM | `common/modals/UpdateModal.svelte` |
| PR | `common/components/Profiles.svelte` |
| NM | `common/modals/NotificationsModal.svelte` (UI part; data in `PARITY/services.md` §10) |
| TO | svelte-sonner `<Toaster>` of APP, `modules/clipboard.js` `copyToClipboard`, `toast(...)` calls |
| SET | `common/modules/settings.js` (setDefaults, resetSettings, paste handler) |
| PROT | `capacitor/src/main/protocol.js`, `electron/src/main/protocol.js` |

Swift code: `ios-native/Tsumi/UI/Shell/` + `ios-native/Tsumi/App/TsumiApp.swift`, `App/RootView.swift`.

| File | Types |
|---|---|
| `App/TsumiApp.swift` | `TsumiApp` (`@UIApplicationDelegateAdaptor(ShellAppDelegate.self)`), `TsumiAppearance` (UI scale, accent colour), `TsumiAppearanceStyle` |
| `App/RootView.swift` | `RootView` (tabs, banner, presenters, launch, toasts janitor, `onOpenURL`, `scenePhase`), `ShellTabs` |
| `AppWiring.swift` | `AppWiring` (one-time wiring), `ShellExtensionBridge` (ExtensionContext closures), `ShellLaunch`, `ShellLifecycle`, `ShellAppDelegate`, `ShellBackgroundRefresh` |
| `ShellNavigation.swift` | `ShellLayer`, `ShellRootSheet`, `ShellMediaItem`, `ShellRoute`, `ShellState`, `ShellLayers`, `ShellNavigation`, `ShellDeepLinks`, `ShellPasteHandler`, `ShellPresentationTiming` |
| `ShellPresenters.swift` | `ShellPlaybackDialogHost`, `ShellRootPresenters`, `ShellRootSheetContent`, `ShellDetailsContainer`, `ShellPlayerHost`, `ShellPlayerCover`, `ShellPlayerDetailsSheet` |
| `ShellPlayback.swift` | `ShellPlayback` (play entry points, player launch and hooks), `ShellEpisodeResolver`, `ShellEpisodeListLoader`, `ShellNotificationMedia` |
| `ShellToolbar.swift` | `ShellTabStack`, `ShellRouteDestination`, `ShellCatalogsScreen`, `ShellMainToolbar`, `ShellNowPlayingButton`, `ShellCatalogsButton`, `ShellNotificationsButton`, `ShellProfileButton`, `ShellAvatar`, `ShellServiceBadge` |
| `ShellToasts.swift` | `ShellToastHost`, `ShellToastStack`, `ShellToastCard`, `ShellToastJanitor`, `ShellPathWatcher`, `ShellConnectionMonitor`, `ShellConnectionBanner`, `ShellPalette` |
| `SettingsView.swift` | `SettingsView`, `ShellSettingsRoute`, `ShellSettingsDestination`, `ShellExtensionsSettingsScreen`, `ShellSettingText`, `ShellSettingCard`, `ShellSettingToggle`, `ShellSettingPicker`, `ShellOption`, `ShellClampedNumberField`, `ShellBind`, `ShellAppInfo`, `ShellSettingsDefaults` |
| `ShellPlayerSettingsView.swift` | `ShellPlayerSettingsView`, `ShellPlaybackSettingsSection`, `ShellPictureInPictureSection` |
| `ShellInterfaceSettingsView.swift` | `ShellInterfaceSettingsView`, `ShellInterfaceOptionsSection`, `ShellNotificationSettingsSection`, `ShellReleasesNotifyEditor`, `ShellHomeScreenSettingsSection` |
| `ShellHomeSectionsSettings.swift` | `ShellHomeSectionCatalog`, `ShellHomeSectionsView`, `ShellHomeSectionRow`, `ShellAnimeSectionsView`, `ShellAnimeSectionEditor`, `ShellWesternSectionsView`, `ShellWesternSectionEditor`, `ShellMultiSelectView` |
| `ShellAppSettingsView.swift` | `ShellAppSettingsView`, `ShellResetAction`, `ShellResetSection`, `ShellSettingsManagementSection`, `ShellNotificationPermissionSection`, `ShellDebugSettingsSection`, `ShellClipboard`, `ShellQueryComplexityRow`, `ShellSettingsTransfer` |
| `ProfilesView.swift` | `ProfilesView`, `ShellCurrentProfileHeader`, `ShellOtherProfilesList`, `ShellOtherProfileRow`, `ShellProfileActions`, `ShellLoginBox`, `ShellProfileBoxButton`, `ShellPasteTokenField`, `ShellWebLoginSheet`, `ShellWebLoginView`, `ShellWebLoginCoordinator` |
| `NotificationsView.swift` | `NotificationsView`, `ShellNotificationSort`, `ShellNotificationState`, `ShellNotificationRow`, `ShellNotificationCover`, `ShellNotificationContent`, `ShellNotificationBadges`, `ShellNotificationPrompt`, `ShellErrorCard` |

Status: **done** = same behavior; **partial** = works, gap described; **different** = intentional, documented difference; **n.a.** = not applicable on iOS (reason given).

## Presentation model (why the shell has its own hosts)

App.svelte stacks every modal over the page and the player layer. On iOS a sheet can only be presented by the
controller that is on top, so the shell tracks four layers (`ShellLayers.top`): `root` (tabs), `rootSheet`
(details / notifications / profiles sheet), `player` (full screen player) and `playerSheet` (details over the
player). The playback dialogs (`PlaybackRequestSheetView`: default loading, extension results, server picker) and
the toasts are hosted by the top layer only (`ShellPlaybackDialogHost`, `ShellToastHost`), with exactly the
binding / `sheetDidDismiss()` semantics of `.playbackRequestPresenter()`. The player is presented by
`ShellPlayerHost` from the same `PlayerPresentation.shared` state as `.playerPresentationHost()`, adding the
details sheet over the player. `.playbackRequestPresenter()` / `.playerPresentationHost()` are therefore not
attached (attaching them as well would present the same dialogs twice). Before presenting the player, the shell
closes the sheets and waits for UIKit transitions to finish (`ShellPresentationTiming`); a playing player is
dismissed before the next one is presented (PlayerView does not restart for a new controller in place).

## 1. Root navigation (APP, RT, SB, NB, NAV)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 1.1 | Pages Home / Search / Schedule / Catalogs / Watch Together / Settings (Router `$page` switch) | RT, SB | `ShellTabs` `TabView` bound to `AppRouter.selectedTab`, one `NavigationStack` per tab (`ShellTabStack`) | done |
| 1.2 | Sidebar order and icons (Home, Search, CalendarSearch, Clapperboard, Users, Settings) | SB | Tab items `house`, `magnifyingglass`, `calendar`, `movieclapper`, `person.2`, `gearshape` | done |
| 1.3 | Mobile navbar (no Catalogs entry) vs desktop sidebar | NB, SB | iPhone / compact iPad: 5 tabs (Navbar pages, no "More" tab); iPad regular: 6 tabs | done |
| 1.4 | Catalogs reachable on small screens | SB (desktop only) | Clapperboard toolbar button on the Search tab pushes `CatalogsView`; `AppRouter.show(.catalogs)` is redirected there (`ShellNavigation.normalize`) | done (iOS addition: the Svelte phone layout had no entry) |
| 1.5 | Active page highlight (`active` state of SidebarLink / NavbarLink) | SL, NL | Tab bar selection | done |
| 1.6 | `page.navigateTo` closes the modals | NAV 76 | `ShellNavigation.showTab` (clears root sheets) + `AppRouter.show` | done |
| 1.7 | Notifications entry, Bell / BellDot (unread) with glow | SB, NB | `ShellNotificationsButton` (`bell` / multicolor `bell.badge`, VoiceOver count) in every tab toolbar | done |
| 1.8 | Profiles / Login entry with the user avatar (`Helper.getUserAvatar`) | SB | `ShellProfileButton` (`ShellAvatar`, label "Profiles" or "Login") | done |
| 1.9 | "Now Playing" entry (ListVideo): back to the player | SB, NB | `ShellNowPlayingButton` while the player is minimized to Picture in Picture → `ShellPlayback.restorePlayer` | done |
| 1.10 | "Last Watched" entry (History) after the player closed (`nowPlaying.display`) | SB, NB | `ShellState.lastWatched` (set by the player `onClose`) → opens its details | done |
| 1.11 | Now Playing while on the player page toggles the details modal | SB | Player "Now Playing [O]" → `onOpenDetails` → details sheet over the player | done |
| 1.12 | Update Downloading / Update Available entries | SB | — | n.a. (no in-app updater on iOS) |
| 1.13 | App logo (navigates Home), expandable sidebar, hover states, safe-area / macOS traffic-light spacing | SB, SL | — | n.a. (desktop sidebar chrome) |
| 1.14 | `modal.open/close/toggle` of DetailsModal, NotificationsModal, Profiles | NAV, APP | `AppRouter.presentedMedia / showNotifications / showProfiles` → one root sheet (`ShellRootSheet`, item replacement handles details ↔ notifications switches) | done |
| 1.15 | DetailsModal content replaced in place when another title is opened | APP handleAnime | Root sheet identity stays `details`; `MediaDetailView` is re-created by its `.id` | done |
| 1.16 | Modals stacked over modals (ExtensionModal over DetailsModal / NotificationsModal) | APP | Playback dialogs hosted by the top layer (`ShellPlaybackDialogHost`) | done |
| 1.17 | Back / forward history (mouse back / forward buttons, Alt+Left / Alt+Right, BrowserBack / BrowserForward keys: `modules/navkeys.js`), Android back button, `modal.focused` | NAV 241-420 | Native navigation stacks, swipe back, sheet swipe-down | n.a. (platform navigation) |
| 1.18 | Global player layer (MediaHandler) over every page | APP | `ShellPlayerHost` full screen cover on the root | done |
| 1.19 | Miniplayer while browsing (draggable, padding of pages) | APP, RT | Picture in Picture (player module) + "Now Playing" entry | partial (system PiP window instead of the in-app miniplayer) |
| 1.20 | Details modal over the player pauses it (pagePause) and resumes after | APP, PP | `ShellPlayerDetailsSheet` → `setExternalOverlay(presented: true/false)` | done |
| 1.21 | Navigating to a page from the details over the player shows the page with the miniplayer | APP | The details close, the player stays in front | partial (no programmatic miniplayer) |
| 1.22 | MinimizeModal (desktop close prompt), Menubar (window controls / drag region), "Debug Mode" ribbon | APP | — | n.a. (desktop window) |
| 1.23 | `IPC.emit('main-ready')`, `window-show`, fullscreen listeners, `pl-safe-area` classes | APP | — | n.a. (desktop / Android bridge) |
| 1.24 | Right-click menu: Cut / Copy / Paste / Select All, Copy Link / Open Link in Browser, Copy Image / Copy Image Address, Inspect (`electron/src/main/contextMenu.js`) | Electron main | System edit menu of text fields and selections | n.a. (desktop window; iOS has the system edit menu) |

## 2. Connection status (ST)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 2.1 | "Offline" bar (WifiOff) while offline | ST | `ShellConnectionBanner` (`wifi.slash`) as a top safe-area inset, `ShellConnectionMonitor` (NWPathMonitor) | done |
| 2.2 | "Connection Restored" (Earth, green) after reconnecting, hidden after a delay | ST, APP statusTransition 2.5 s | `showRestored` for 2.5 s (`globe`) | done |
| 2.3 | "AniList Outage" (CloudAlert) | ST, networking.js | `ShellConnectionBanner` (`exclamationmark.icloud`) from `ServiceNetworkMonitor.isAniListDown`; "Connection Restored" when it ends (`ShellConnectionMonitor.aniListStatusChanged`) | done |
| 2.4 | Height / padding transitions | ST | Move + opacity transition | done |

## 3. Deep links and app events (PROT, APP)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 3.1 | `tsumi://` and legacy `shiru://` schemes | PROT 5, 17 | Info.plist schemes + `RootView.onOpenURL` → `ShellDeepLinks.handle` → `Services.handle(url:)` | done |
| 3.2 | `alauth` / `malauth` login callbacks | PROT 6-7, 32-50 | Consumed by `Services.handle` / `ProfilesService.handleCallback` (logins normally return through ASWebAuthenticationSession) | done |
| 3.3 | `anime/<id>` → `open-anime` → handleAnime (searchIDSingle, close then open details) | PROT 8, APP 7-15 | `ShellDeepLinks.route(.anime)` → `Services.media(for:)` → `ShellNavigation.openDetails` | done |
| 3.4 | `malanime/<id>` (idMal) | PROT 9 | `.malAnime` → same | done |
| 3.5 | `search/<id>` → play-anime (DetailsModal handlePlay without episode: progress + 1, else playMedia) | PROT 10, 52-58; DetailsModal 216-242 | `ShellPlayback.playFromLink` | done |
| 3.6 | `w2g/<code>` → `w2glink` (join + show the lobby) | PROT 11 | `WatchTogetherClient.handle(url:)` first (+ `.watchTogether` fallback → `join(link:)`), `onShowLobby` → Watch Together tab | done |
| 3.7 | `schedule` → Schedule page (IPC 'schedule') | PROT 12, APP 19 | `ShellNavigation.showTab(.schedule)` | done |
| 3.8 | `update` (quit and install), `show` (window-show) | PROT 14-15 | — | n.a. (desktop updater / window) |
| 3.9 | Launch URL (`App.getLaunchUrl`, electron second-instance / command line) | PROT 19-27 | SwiftUI delivers the launch URL to `onOpenURL` | done |
| 3.10 | Notification activation `tsumi://anime/<id>` and action buttons (View Anime / Start Watching / Resume / Watch) | NM 83, capacitor app.js 24-46, 113-129 | `AppNotificationsService.onOpenURL` → `ShellDeepLinks.handle` (set in `didFinishLaunching` so cold-start taps are routed); the watch actions open `tsumi://search/<id>` → `ShellPlayback.playFromLink` | done |
| 3.11 | Clipboard paste handler: `access_token=` / `code=&state=` login fallback, anilist.co / myanimelist.net links | SET 85-123 | "Paste token" field of the login box (`ShellPasteTokenField` → `ShellPasteHandler`): tokens / pin URLs / MAL codes → `ProfilesService.login(pasted:)`, links → `Services.handle(url:)` → `ShellDeepLinks.route` | done (an explicit field: iOS has no global paste event and reading the pasteboard unasked shows the paste prompt) |
| 3.12 | `IPC.on('handle-protocol')` (pasted protocol text) | PROT electron 68 | Covered by 3.1 | done |

## 4. Toasts (TO)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 4.1 | Toasts posted by the modules (printError, listToast, login, W2G...) | TO | `ServiceMessages.shared.messages` shown by `ShellToastHost` | done |
| 4.2 | `visibleToasts={2}` (newest on top) | APP Toaster | `ShellToastStack` shows the last 2 | done |
| 4.3 | `position='top-right'` | APP Toaster | Top, centered, max width 520 (top-trailing look on iPad) | done |
| 4.4 | `theme='dark' richColors` (success / warning / error / info colors) | APP Toaster | `ShellToastCard` icon, tint and background per kind | done |
| 4.5 | `duration={10_000}`, timers of hidden toasts keep running | APP Toaster | `ShellToastJanitor` dismisses every message 10 s after it was posted | done |
| 4.6 | `closeButton` | APP Toaster | `xmark` button; tap or swipe up also dismisses | done |
| 4.7 | Hidden while the player is fullscreen without modal | APP toastOptions | Not shown on the `player` layer, shown over the details on the `playerSheet` layer | done |
| 4.8 | Extra top margin on the Settings page | APP toastOptions | — | n.a. (layout) |
| 4.9 | Toasts shown above every modal | APP | Hosted by the top layer (root, root sheet, details over the player) | done |
| 4.10 | Toast level setting (All / Warnings / Successes / Errors / None) | AT, helper.js | Setting UI done (§9.13); filtering is `ServiceMessages.post` (`includes('Errors' / 'Successes' / 'Warnings')` like the Svelte checks) | done |
| 4.11 | `copyToClipboard` toast "Copied to clipboard" / "Copied <detail> to clipboard" | clipboard.js | `ShellClipboard.copy` | done |
| 4.12 | Watch Together toasts ("Starting <title> - Episode N", invite copied) | WatchTogetherPage | `onNotice` → toast, except while the lobby screen (which shows its own banner) is visible | done |

## 5. Settings page (SP, SC)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 5.1 | Groups Player / Interface / Extensions / Profiles / App with icons (Play, AppWindow, Puzzle, User, LayoutDashboard) | SP 47-71 | `SettingsView` rows (`play.fill`, `macwindow`, `puzzlepiece.extension`, `person`, `square.grid.2x2`) | done |
| 5.2 | "Profiles" group opens the profiles modal (`action`) | SP 61-65 | Row button → `AppRouter.showProfiles` | done |
| 5.3 | "Restart may be required for some settings to take effect." / "If you don't know what settings do what, use defaults." | SP 132-137 | Footer section of `SettingsView` | done |
| 5.4 | Version line `v<version> <platform> <arch> <session>` | SP 138-143 | `ShellAppInfo.versionLine` (`v<CFBundleShortVersionString> iOS <system version> (<build>)`) | done |
| 5.5 | `IPC version`, debug log of the settings at load | SP 22-31 | Version read from the bundle | n.a. (no IPC / debug module) |
| 5.6 | DoH emit, Discord RPC emit, ANGLE query at load, `player` executable listener | SP 9, 32-33, 76-84 | — | n.a. (desktop only) |
| 5.7 | Responsive tabs (sidebar on large screens, top bar on small), miniplayer padding, shadow overlay | SP | Native list + navigation pushes | n.a. (layout) |
| 5.8 | SettingCard: title, muted pre-wrapped description, control | SC | `ShellSettingCard`, `ShellSettingToggle`, `ShellSettingPicker`, `ShellSettingText` | done |
| 5.9 | ClampedNumber (min / max / step clamp) | SC | `ShellClampedNumberField` (clamps and rounds on return / focus loss) | done |
| 5.10 | ConfirmButton (confirm / cancel step) | SC | `.confirmationDialog` "Confirm Reset" / "Cancel" | done |
| 5.11 | CustomDropdown multi-select (genres, tags, formats, TMDB genres) | SC | `ShellMultiSelectView` (searchable list with checkmarks, "Clear Selection") and toggle menus for formats | done |

## 6. Settings > Player (PT)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 6.1 | Headings "Player Settings" / "Subtitle Settings" / "Language Settings" / "Playback Settings" | PT | Form sections "Language Settings", "Playback Settings" | done |
| 6.2 | Default Subtitle Font (local fonts, remove) | PT 39-48 | — | n.a. (no libass renderer, player 7.19) |
| 6.3 | Find Missing Subtitle Fonts | PT 49-54 | — | n.a. (same) |
| 6.4 | Fast Subtitle Rendering | PT 56-61 | — | n.a. (same) |
| 6.5 | Subtitle Render Resolution Limit | PT 62-70 | — | n.a. (same) |
| 6.6 | Preferred Subtitle Language (None + 24 languages, same codes) | PT 73-101 | `ShellSettingPicker` → `subtitleLanguage` | done |
| 6.6b | Automatic Online Subtitles | PT Language Settings | toggle → `onlineSubtitlesAuto` | done |
| 6.7 | Autoplay Next Episode | PT 104-109 | toggle → `playerAutoplay` | done |
| 6.8 | Pause On Lost Focus | PT 110-115 | toggle → `playerPause` | done |
| 6.9 | Auto-Complete Episodes | PT 116-121 | toggle → `playerAutocomplete` | done |
| 6.10 | Auto-Complete Threshold (1-100 %, only when auto-complete is on) | PT 122-131 | `ShellClampedNumberField` → `playerAutocompleteThreshold` | done |
| 6.11 | Deband Video | PT 132-137 | — | n.a. (AVPlayer, player 1.15) |
| 6.12 | Seek Duration (0.2-360 s, step 0.1) | PT 138-145 | `ShellClampedNumberField` → `playerSeek` | done |
| 6.13 | Chapter Source Preference (Embedded / Aniskip) | — | — | removed on both apps (automatic: file chapters, AniSkip, TheIntroDB) |
| 6.14 | Auto-Skip Intro/Outro | PT 152-157 | toggle → `playerSkip` | done |
| 6.15 | Enable External Player / External Video Player executable | PT 159-178 | — | n.a. (desktop / Android; the player offers VLC / Infuse from its menu) |
| 6.16 | (iOS) Auto Picture in Picture | player 8.7 | toggle → `PlayerPreferences.autoPictureInPicture` | done (iOS addition) |

## 7. Settings > Interface (IT)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 7.1 | Discord Rich Presence (`enableRPC`, `rpcSecondButton`) | IT 20-29 | Settings > Discord (`ShellDiscordSettingsView`): the two pickers plus the Discord account (Link / Cancel / Reconnect / Unlink, status) | done (2026-11-15; the iOS presence needs a linked Discord account) |
| 7.2 | Scale (UI scale slider + reset) | IT 33-42 | "Scale" picker (50-200 %) → `uiScale`, applied by `TsumiAppearance` as a Dynamic Type size on the root (100 % keeps the iOS text size) | done (discrete steps; only Dynamic Type text and controls scale) |
| 7.3 | CSS Variables + Open Devtools | IT 43-48 | "Accent Color" (`ColorPicker`, Reset) → `accentColor`, applied as `.tint` on the root | partial (accent colour only; no free-form variables or devtools) |
| 7.4 | Expandable Sidebar | IT 49-54 | — | n.a. (no sidebar) |
| 7.5 | Expandable Lists (mobile) | IT 55-62 | toggle → `SettingsValues.toggleList` (read by the Browse details lists) | done |
| 7.6 | Preferred Title Language (Japanese / English), hidden when logged into AniList | IT 63-70 | `ShellInterfaceOptionsSection` picker → `titleLang` (romaji / english), hidden when `ProfilesService.isAniList` | done |
| 7.7 | Card Type (Small / Full) | IT 71-76 | picker → `@AppStorage(BrowseCardMode.storageKey)` (the key the Home / Search / Schedule card buttons use), reset with the settings | done |
| 7.8 | Card Preview (mobile: only with small cards) | IT 77-84 | toggle → `cardPreview`, hidden with full cards | done |
| 7.9 | Card Audio | IT 85-90 | toggle → `SettingsValues.cardAudio` (`ServiceSettingsExtras.cardAudio` forwards to it) | done |
| 7.10 | Prefer Dubs (long description) | IT 91-96 | toggle → `preferDubs` | done |
| 7.11 | Adult Content (None / Adult / Hentai) | IT 97-103 | picker → `adult` | done |
| 7.12 | Hentai Banner (only with Hentai) | IT 104-111 | toggle → `hentaiBanner` | done |
| 7.12a | Spoiler Protection (Off / Minimal / Moderate / Strict / Hermit) and its list statuses (shown when not Off) | `routes/settings/components/SpoilerSettings.svelte` (in IT after Hentai Banner) | `ShellSpoilerSettingsSection` + `ShellSpoilerStatusEditor` → `spoilers`, `spoilerStatus` (rules in `PARITY/spoilers.md`) | done |
| 7.13 | ANGLE Backend | IT 112-128 | — | n.a. (desktop rendering) |
| 7.14 | System Notifications | IT 130-135 | toggle → `systemNotify`; turning it on asks the iOS permission (`requestAuthorization`) | done |
| 7.15 | AniList Notifications (All / Limited / None, AniList only) | IT 136-144 | picker → `aniNotify`, shown when `ProfilesService.isAniList` | done |
| 7.16 | Sub / Dub Announcements (All / Following / None) | IT 145-156 | pickers → `subAnnounce`, `dubAnnounce` | done |
| 7.17 | Hentai Announcements (only with Hentai) | IT 145-156 | picker → `SettingsValues.hentaiAnnounce` | done |
| 7.18 | Western Announcements | IT 145-156 | — | n.a. (`westernAnnounce` has no default and no reader in the Svelte modules; not in Core) |
| 7.19 | Releases Notifications: list of statuses, change, remove, Add Status (disabled when all used), "Not on List" | IT 157-172 | `ShellReleasesNotifyEditor` → `releasesNotify` + `SettingsValues.releasesNotifyNotOnList` | done (Add Status picks from a menu instead of adding an empty "Select a status" row) |
| 7.20 | Hide My Anime (when logged in) | IT 175-182 | toggle → `hideMyAnime`, shown when authorized | done |
| 7.21 | Hero Content (Balanced / Anime / Western) | IT 183-189 | picker → `bannerProvider` | done |
| 7.22 | Anime Sections editor (name, genres, tags, delete, Add Section `['New Section', [], [], [], []]`) | IT 190-226 | `ShellAnimeSectionsView` + `ShellAnimeSectionEditor` (`AnimeCatalog.genres / tags`, Hentai items only with the Hentai setting) | done (new names are made unique: "New Section 2"...) |
| 7.23 | Western Sections editor (name, TMDB genres, Both / TV Shows / Movies, delete, Add Section) | IT 227-262 | `ShellWesternSectionsView` + `ShellWesternSectionEditor` (`AnimeCatalog.tmdbGenres`) | done |
| 7.24 | Renaming / deleting a custom section | IT | The home layout entry is renamed / removed too, duplicate names are refused ("A section with this name already exists.") | done (the Svelte app left a dangling layout row) |
| 7.25 | Sections And Order card | IT 263-268 | `ShellHomeSectionsView` (§8) | done |

## 8. Sections And Order (HS)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 8.1 | Allowed sections = every section of the sections manager | HS 8 | `HomeSectionsService.availableTitles` | done |
| 8.2 | Row: section select listing unused sections + current | HS 197-205 | Title menu (`[current] + remaining`) | done |
| 8.3 | Changing the section resets the row to that section's [title, sort, format] defaults | HS 198 | `ShellHomeSectionCatalog.defaultSetting(for:)` (sections.js defaults: N/A for feeds, static sorts and western sections; list sorts; TV/MOVIE formats) | done |
| 8.4 | Sort select: Trending, Popularity, Title, Score, Release Date | HS 210-215 | Sort menu (`sortOptions(for:)`) | done |
| 8.5 | List-only sorts: Completed Date (Completed), Start Date (not Planning), Last Updated, Your Progress (not Completed / Planning), Your Score (Completed / Dropped) | HS 216-232 | `sortOptions(for:)` | done |
| 8.6 | Sort disabled for N/A sections | HS 207-209 | `.disabled(sort contains "N/A")` | done |
| 8.7 | Format multi-select (TV Show, Movie, TV Short, Special, OVA, ONA) | HS 235-237 | Toggle menu that stays open (`menuActionDismissBehavior(.disabled)`) | done |
| 8.8 | Delete row | HS 238-240 | Swipe to delete / edit mode | done |
| 8.9 | Drag & drop reorder (mouse, touch, keyboard Space / arrows / Escape, ghost row) | HS 20-170 | `.onMove` with `EditButton` (system drag handles, VoiceOver actions) | done |
| 8.10 | Add Section (random remaining section, disabled when all used) | HS 244 | "Add Section" menu listing the remaining sections, disabled when none | done (the user picks instead of a random one) |
| 8.11 | Header labels Section / Sort / Format | HS 182-189 | Row layout (title, sort, format) | done |
| 8.12 | Default layout of settings.js (14 base sections + custom / western ones not in it) | SET 22-52 | `ShellSettingsDefaults.svelteLayout`; applied once when the stored layout is still Core's 8 section default (`applySvelteLayoutOnce`) and by "Reset to Defaults" | done |

## 9. Settings > App (AT, CT, UM)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 9.1 | About This App (version, platform, description) | AT 90-96 | `ShellAppSettingsView` first card | done |
| 9.2 | Update Downloading / Update Available buttons | AT 93-95 | — | n.a. (no updater) |
| 9.3 | Exit Action (Prompt / Minimize / Exit) | AT 97-107 | — | n.a. (desktop window) |
| 9.4 | Query Complexity (Complex / Simple) | AT 108-115 | `ShellQueryComplexityRow` → `queryComplexity` (services 1.4) | done |
| 9.5 | Reset Notifications (confirm) → cache.resetNotifications | AT 116-121 | `AppNotificationsService.reset()` | done |
| 9.6 | Reset History (confirm) → cache.resetHistory (progress, subtitle choices, volume boost) | AT 122-127 | `AnimeProgressService.reset()` + clears the player's last-subtitle store | done (volume boost n.a., player 2.18) |
| 9.7 | Reset Caches (confirm) → cache.resetCaches + forced restart | AT 128-133 | `Services.clearCaches()` with a progress indicator; data reloads without a restart | done |
| 9.8 | Import from Clipboard (JSON, reload; "Failed to import settings" toast) | AT 7-17, 136 | `ShellSettingsTransfer.importJSON`: tolerant `SettingsValues` decoding (missing keys keep their default, unknown keys ignored, Svelte array-shaped `homeSections` / `customSections` / `westernSections`, 'NOTONLIST' in `releasesNotify`), a `{ settings }` / `{ appInfo: { settings } }` wrapper, `cards`, `playerChapterSkip`, `autoPictureInPicture`, and `extensions` (iOS entries → `ExtensionManager.replaceInstalled`, Svelte entries → `addExtension(url)`); refused only when no known key is present | done |
| 9.9 | Export to Clipboard | AT 137 | `ShellSettingsTransfer.exportJSON`: `SettingsValues` + `cards`, `playerChapterSkip`, `autoPictureInPicture`, `extensions` (`{ key: { url, enabled, manifest, kind, order } }`), 'NOTONLIST' folded into `releasesNotify` | done |
| 9.10 | Reset to Defaults (confirm) → cache.resetSettings | AT 138-140, SET resetSettings | `ShellSettingsDefaults.resetAll()` (Core values with the Svelte layout, `PlayerPreferences.resetAll()`, card type, `ExtensionManager.removeAll()`) | done |
| 9.11 | DNS over HTTPS (toggle, URL) | AT 144-157 | — | n.a. (desktop) |
| 9.12 | Logging Levels (None / All / Interface) | AT 160-167 | — | n.a. (no debug module; system logging) |
| 9.13 | Toast Levels (All / Warnings / Successes / Errors / None) | AT 168-175 | picker → `toasts` | done (see 4.10) |
| 9.14 | App and Device Info → Copy To Clipboard | AT 176-178, 74-87 | `ShellDebugSettingsSection.copyDeviceInfo` (version, build, platform, system, model, settings) | done |
| 9.15 | Log Output (Export Logs / Reset Logs + toasts) | AT 179-187, 18-41 | — | n.a. (desktop log file) |
| 9.16 | Open UI Devtools | AT 188-192 | — | n.a. |
| 9.17 | (iOS) notification permission state, Allow / Open Settings | — | `ShellNotificationPermissionSection` | done (iOS addition) |
| 9.18 | Changelog tab (last 5 releases, current version) | CT, Changelog.svelte | — | n.a. (L58: the repository is private, so the GitHub releases API has no public feed to show) |
| 9.19 | Update modal (changelog of the update, Update Now / What's New, notifications, periodic checks) | UM | — | n.a. (no updater; feed gone) |

## 10. Extensions settings (ET)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 10.1 | Extensions tab content | ET | `ExtensionSettingsView()` pushed from Settings (`ShellExtensionsSettingsScreen`), see `PARITY/extensions.md` §8 | done |
| 10.2 | CatalogPage "Open Settings" goes to the extensions settings | CatalogPage | `ShellNavigation.openSettings(.extensions)` (Settings tab + pushed screen) | done |

## 11. Profiles (PR)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 11.1 | Modal with close button | PR 70-77 | `ProfilesView` sheet, `xmark` toolbar button, swipe down | done |
| 11.2 | Current profile: large avatar (fallback image), AniList / MyAnimeList icon with title, name | PR 78-84 | `ShellCurrentProfileHeader` (`ShellAvatar`, `ShellServiceBadge` "Logged in with AniList / MyAnimeList") | done |
| 11.3 | "Other Profiles" header when there are other profiles | PR 86-90 | `ShellOtherProfilesList` | done |
| 11.4 | Other profile row: avatar, service icon, name, tap = switch ("Switch to Profile: <name>") | PR 92-98 | `ShellOtherProfileRow` → `ProfilesService.switchTo` | done |
| 11.5 | "Sync List Entries" switch (not for profiles needing reauth) | PR 101-105 | `Toggle` → `toggleSync` / `isSynced` | done |
| 11.6 | "Authenticate" (ClockAlert) for a profile needing reauth (confirmMAL) | PR 106-109 | `clock.badge.exclamationmark` → `reauthenticate()` | done |
| 11.7 | Logout of another profile (dropProfile) | PR 110-112 | `rectangle.portrait.and.arrow.right` → `drop` | done |
| 11.8 | Reauth profile row highlighted (error color) | PR 93, CSS | Red row background | done |
| 11.9 | Login box when no profile at all ("Log In" title) or after "Add Profile" | PR 116-133 | `ShellLoginBox` (title only without profiles) | done |
| 11.10 | AniList button (implicit grant, client 35971) | PR 47-49, 122-126 | `ProfilesService.loginAniList()` → `ShellWebLoginSheet` (web view; the token is caught on the AniList pin page) | done (BUG-login fixed) |
| 11.11 | MyAnimeList button (PKCE plain, random state) | PR 51-57, 127-131 | `ProfilesService.loginMAL()` → same sheet (code + state caught in any redirect) | done |
| 11.12 | At most 5 other profiles ("Add Profile" / login hidden at 5) | PR 115, 134 | `others.count < maxOtherProfiles`, `canAddProfile` | done |
| 11.13 | "Add Profile" (Plus) → modal.open(PROFILE, true) | PR 134-139 | `addingProfile` state → login box | done |
| 11.14 | Current profile needing reauth: "Authenticate" | PR 141-148 | `ShellProfileActions` red "Authenticate" | done |
| 11.15 | "Sign Out" (swapProfiles(null)) | PR 149-155 | `logout()` | done |
| 11.16 | "Login Canceled" toast when the auth window is closed | PR 59-64 | Cancel / swipe down closes the login sheet silently | different (a cancel is not an error) |
| 11.17 | Page reload after a profile change | SET swapProfiles | `ProfilesService.accountChanged` (services 3.8); the UI observes the services | done |
| 11.18 | Login in progress | — | Progress overlay, view disabled while `isLoggingIn` | done (iOS addition) |
| 11.19 | `IPC open-auth` windows, Android `open` | PR 48, 56 | `ShellWebLoginSheet` (WKWebView, default persistent data store so the login is remembered, Cancel button) | done |
| 11.20 | Paste token fallback (settings.js paste handler) | SET 85-123 | `ShellPasteTokenField` in the login box: raw AniList token, pin page URL / `access_token=...`, MAL `code=&state=`, or a link | done |

## 12. Notifications modal UI (NM)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 12.1 | Title "Notifications" + close button | NM 188-191 | `NotificationsView` navigation title, `xmark` | done |
| 12.2 | Search input "Filter notifications by their titles", hidden without notifications | NM 192-202 | `searchField` (only when there are notifications) | done |
| 12.3 | 500 ms debounced filter (matchPhrase title + matchKeys media titles / synonyms) | NM 165-173 | `applySearch` (500 ms) → `AppNotificationsService.filtered` | done (fuzzy matching approximated by the services, 10.15) |
| 12.4 | "found no results" ErrorCard ("Ooops!" / "No results found.") | NM 204-206, ErrorCard | `ShellErrorCard(["No results found."])` | done |
| 12.5 | Empty state ErrorCard "Nothing To See Here!" / "Settings > Interface > Notifications Settings" | NM 287-290 | `ShellErrorCard` | done |
| 12.6 | Media of each notification (cache.requestMedia) | NM 209 | `ShellNotificationRow.task` → `ShellNotificationMedia.resolve` (MediaStore, batched AniList request) | done |
| 12.7 | Status flags: announcement, delayed, repeating, notWatching, behind, completed | NM 210-215 | `ShellNotificationState` (same formulas) | done |
| 12.8 | Left border color by status (current, repeating, completed, behind / delayed, announcement, not watching) with the CSS precedence | NM CSS | `ShellNotificationState.borderColor` | done |
| 12.9 | Read notifications at 50 % opacity | NM CSS | `.opacity(0.5)` | done |
| 12.10 | Hero image (banner / trailer thumbnail) with gradient | NM 224-229 | `heroBackground` (AsyncImage + gradient) | done |
| 12.11 | Cover icon (404 fallback) | NM 230-232 | `ShellNotificationCover` | done |
| 12.12 | Title (2 lines), message, `since` time | NM 234-269 | `ShellNotificationContent` (`ServiceText.since`) | done |
| 12.13 | Play button when the notification has an episode (play-anime direct, modal stays open) | NM 238-243 | Play button → `ShellPlayback.playNotification` (dialog shown over the notifications sheet) | done |
| 12.14 | Read / unread button (MailCheck / MailOpen), disabled when completed | NM 244-251 | `envelope.badge` / `envelope.open` → `setRead`, disabled when completed | done |
| 12.15 | Badges: Announcement / Movie / Delayed + Episode N or Batch / Season N; Dub / Sub | NM 256-275 | `ShellNotificationBadges` | done |
| 12.16 | Click: "behind" → prompt first; else read + close + play (handlePlay direct: episode, progress + 1, playMedia; nothing for unreleased anime) | NM 150-158, 216-220; DetailsModal 216-232 | `NotificationsView.tap` → `ShellNavigation.afterClosingRootSheets` → `ShellPlayback.playNotification` | done |
| 12.17 | Prompt "You Haven't Watched Any Episodes Yet!" / "Your Current Progress Is At Episode N" + "Continue Anyway?" | NM 276-286 | `ShellNotificationPrompt` (tap outside the button dismisses it, like hover / blur exit) | done |
| 12.18 | Right click = read + close + open details (open-anime) | NM 221 | Long press context menu "View Details" (+ Play, Mark as Read / Unread) | done |
| 12.19 | Mark All As Read / Mark All As Unread (disabled while searching) | NM 293-302 | `markAllButton` → `markAll(read:)` | done |
| 12.20 | Opening marks watched episodes as read (markWatchedAsRead) | NM 36-40 | `.task` → `markWatchedAsRead()` | done |
| 12.21 | Re-sort on close (unread first) | NM 39, 159-161 | Order frozen at opening (`ShellNotificationSort`, same sort), applied again on the next opening | done |
| 12.22 | Incremental rendering (25 per scroll) | NM 175-185 | LazyVStack | n.a. (lazy by nature) |
| 12.23 | `notification-unread` IPC (tray / app badge) | NM 22-27 | App badge kept by the services | done (services 10.2) |

## 13. Block wiring

### 13.1 Launch and lifecycle

| # | Hook | Swift | Status |
|---|---|---|---|
| W1 | `Services.shared.start()` once at launch | `ShellLaunch.start()` from `ShellAppDelegate.didFinishLaunching` and `RootView.task` (idempotent) | done |
| W2 | `ExtensionManager.shared` touched at launch | `ShellLaunch.start()` | done |
| W3 | `AppWiring.configure()` once | `ShellLaunch.start()` (before `Services.start()` so the notification router exists) | done |
| W4 | `UIApplicationDelegateAdaptor` returning `PlayerOrientation.supportedMask` | `ShellAppDelegate.application(_:supportedInterfaceOrientationsFor:)` | done |
| W5 | `.onOpenURL` → `Services.handle(url:)` / `WatchTogetherClient.handle(url:)` | `ShellDeepLinks.handle` | done |
| W6 | `scenePhase == .active` → `WatchTogetherClient.appBecameActive()` | `ShellLifecycle` | done |
| W7 | `scenePhase == .background` → `AppNotificationsService.flush()` (queued notifications delivered before suspension) | `ShellLifecycle` | done |
| W8 | `AppNotificationsService.onOpenURL` (notification taps) | `AppWiring.configure` → `ShellDeepLinks.handle` | done |
| W9 | Background refresh (`BGAppRefreshTask` → `backgroundRefresh()`) | `ShellBackgroundRefresh`: registered in `ShellAppDelegate.didFinishLaunching`, scheduled on `.background`, runs `backgroundRefresh()` then `flushAndWait()`; Info.plist `BGTaskSchedulerPermittedIdentifiers` (`org.tsumi.app.refresh`) + `fetch` | done |
| W10 | `ProfilesService.authenticateOverride` (optional) | not set (ASWebAuthenticationSession default) | done (optional hook intentionally unused) |

### 13.2 Extensions (`PARITY/extensions.md` "app" rows and public API)

| # | Hook | Swift | Status |
|---|---|---|---|
| W11 | `ExtensionContext.animeToTMDB` (anilistToTmdb: TMDB id, movie, TVDB season, episode offset) | `ShellExtensionBridge` → `AnimeMappingsService.tmdbInfo` | done |
| W12 | `ExtensionContext.tmdbIMDbId` (getDetails externalIds.imdb_id) | `TMDBService.details` (`imdbId`, `externalIds["imdb_id"]`) | done |
| W13 | `ExtensionContext.tmdbFindByIMDb` (`/find`) | `TMDBService.find(externalId:source: "imdb_id")` | partial (the service returns the first match, TV preferred, so one id is passed) |
| W14 | `ExtensionContext.tmdbSeasons` | `TMDBService.details(id:type: .tv).seasons` | done |
| W15 | `ExtensionContext.tmdbToAnilistId` (synchronous) | `AnimeMappingsService.loadedAnilistId` (index preloaded by `Services.start()`) | done |
| W16 | `ExtensionContext.displayTitle` (anilistClient.title: userPreferred when logged into AniList, else title language) | `AniListService.title` | done |
| W17 | Dialog presenter attached once | `ShellPlaybackDialogHost` on the top layer (replaces `.playbackRequestPresenter()`, see "Presentation model") | done |
| W18 | `PlaybackRequestCoordinator.onReady` → player (extensions 5.18 launchPlayer) | `ShellPlayback.start` | done |
| W19 | shareNowPlaying after launch (extensions 5.19) | player `onEpisodeStarted` → `WatchTogetherClient.shareMedia` | done |
| W20 | `w2g-play` → playAnime (extensions 4.4) | `onRemoteMedia` → `ShellPlayback.playRemote` → `PlaybackRequestCoordinator.play(media:episode:force: false)` (cached / AniList media; skipped when that episode already plays or loads) | done |
| W21 | CatalogsView card click (extensions 9.14) | `CatalogsView(onSelect:)` → `ShellNavigation.openDetailsWhenSettled` | done |
| W22 | `CatalogsView(onOpenSettings:)` | `ShellNavigation.openSettings(.extensions)` | done |
| W23 | `ExtensionSettingsView()` in Settings | `ShellExtensionsSettingsScreen` | done |
| W24 | Catalogs entry in the navigation (extensions 9.17) | Catalogs tab (iPad) / Search toolbar (iPhone) | done |

### 13.3 Player (`PARITY/player.md` "app" rows and wiring notes)

| # | Hook | Swift | Status |
|---|---|---|---|
| W25 | `PlaybackSession` from `ResolvedPlayback` (servers, selectedIndex, subtitleURL) | `ShellPlayback.makeController` | done |
| W26 | Episode title (player 3.5) | From `MediaDetailsService.episodes(for:)` (waited up to 1.2 s before presenting) | done |
| W27 | Episode list (player 4.14) | `PlayerController(session:episodeList:)`, or `setEpisodeList` when it arrives later | done |
| W28 | `loadEpisode` (player 4.3: next / previous / episode list / setindex) | `ShellEpisodeResolver.resolve`: same extension (search → best result → episode match → stream), remembered or same-named server, default extension if that one is gone | partial (no extension picker / server selector inside the player; the series is re-searched, so a manually picked non-best result is not reused) |
| W29 | `resumePosition` (loadAnimeProgress) | `AnimeProgressService.record(mediaKey:episode:)?.currentTime` | done |
| W30 | `onProgress` (player 5.5, setAnimeProgress) | `AnimeProgressService.set(mediaKey:episode:currentTime:safeDuration:)` | done |
| W31 | `onAutocomplete` (player 5.9, Helper.updateEntry) | `MediaListService.updateAfterWatching(_:episode:)` | done |
| W32 | `onPlaybackEnded` | not needed (autoplay is internal to the player) | done |
| W33 | `onEpisodeStarted` (player 10.6) | `shareMedia` (not for an episode a peer asked for through setindex) | done |
| W34 | `onClose` | "Last Watched" entry | done |
| W35 | `onMinimize` / `onRestoreFromPictureInPicture` | `PlayerPresentation.present` wrappers + "Now Playing" restore | done |
| W36 | `onOpenDetails` + `setExternalOverlay` (player 3.10, 4.9) | `ShellNavigation.openDetails` → `ShellPlayerDetailsSheet` (overlay on appear, released on dismiss) | done |
| W37 | `onLocalStateChange` → `playerStateChanged(paused:time:)` (W2G 13) | `ShellPlayback.wire` | done |
| W38 | `onIndexChange` → `mediaIndexChanged` (W2G 12) | `ShellPlayback.wire` | done |
| W39 | `isWatchTogetherActive` (player 10.5) | `WatchTogetherClient.isInLobby` | done |
| W40 | `applyRemoteState` (W2G 20) | `onRemotePlayer` → `PlayerPresentation.shared.controller?.applyRemoteState` | done |
| W41 | `applyRemoteIndex` (W2G 19) | `onRemoteIndex` → `ShellPlayback.applyRemoteIndex` | done |
| W42 | Player host attached once | `ShellPlayerHost` (replaces `.playerPresentationHost()`, same `PlayerPresentation` state) | done |
| W43 | `PlayerPreferences.chapterSource` in Settings (player 6.14) | — | removed (chapter source is automatic) |
| W44 | `PlayerPreferences.autoPictureInPicture` in Settings | Settings > Player | done |
| W45 | Card progress bars from `AnimeProgressService` (player 5.6) | Browse block | n.a. here |

### 13.4 Watch Together (`PARITY/watch-together.md` "App" rows)

| # | Hook | Swift | Status |
|---|---|---|---|
| W46 | `currentUser` (row 6) | `ProfilesService.shared.viewer` | done |
| W47 | `onRemoteMedia` (rows 18, 34) | W20 | done |
| W48 | `onRemotePlayer` (row 20) | W40 | done |
| W49 | `onRemoteIndex` (row 19) | W41 | done |
| W50 | `onNotice` (row 34) | Toast (not while the lobby screen is visible) | done |
| W51 | `onShowLobby` (row 37) | `ShellNavigation.showTab(.watchTogether)` | done |
| W52 | Player ↔ lobby emitter (row 30) | W37, W38, W40, W41 | done |
| W53 | `handle(url:)` from `.onOpenURL` (row 37) | W5 | done |
| W54 | `appBecameActive()` | W6 | done |
| W55 | `WatchTogetherView()` page | Watch Together tab | done |

### 13.5 Services (`PARITY/services.md` "Wiring needed in the app")

| # | Hook | Swift | Status |
|---|---|---|---|
| W56 | Deep link navigation from `TsumiDeepLink` | `ShellDeepLinks.route` | done |
| W57 | `ServiceMessages` display | §4 | done |
| W58 | Profiles UI (login, switch, sync, drop, reauth, logout) | §11 | done |
| W59 | Notifications UI (`items`, `unreadCount`, `filtered`, `markAll`, `setRead`, `markWatchedAsRead`, `reset`, `requestAuthorization`) | §12, §9.5, §7.14, §9.17 | done |
| W60 | `HomeSectionsService.availableTitles` / `defaultLayout` / `section(titled:)` in Settings | §8 | done |
| W61 | cardAudio, hentaiAnnounce, releasesNotifyNotOnList in Settings (now `SettingsValues` keys; `ServiceSettingsExtras` forwards) | §7 | done |
| W62 | `Services.clearCaches()`, `AnimeProgressService.reset()` | §9 | done |
| W63 | `MediaListService.startEpisode(for:)` / `entry(for:)` for shell play entry points | `ShellPlayback.playMedia / playFromLink / playNotification` | done |

## Counts

| Status | Feature rows (§1-§12) | Wiring rows (§13) | Total |
|---|---|---|---|
| done | 146 | 60 | 206 |
| partial | 3 | 2 | 5 |
| different | 1 | 0 | 1 |
| n.a. | 30 | 1 | 31 |
| **total** | **180** | **63** | **243** |

## Issues found in other blocks (not modified here)

- `ResolvedPlayback` has no href of the chosen search result, so the next episode re-searches the series with
  the same extension and takes the best scored result (W28). Adding `sourceHref` would let the shell reuse the
  exact series.
- `PlayerPreferences` has no reset API for the last-subtitle store: "Reset History" removes the UserDefaults key
  `tsumi.player.lastSubtitle` directly.
- `PlayerView` does not restart when `PlayerPresentation.present` swaps the controller while the cover is up
  (same view identity, `onAppear` not called again): with `.playerPresentationHost()` a second playback started
  over a playing one would stay black. The shell avoids it (dismiss, then present; `.id` per controller).
- `TMDBService.find` returns a single match; `ExtensionIMDbMatch` could carry every TV / movie id (W13).
- `AppNotificationsService` has no public re-sort (Svelte sorts when the modal closes); the view sorts itself.
- `ServiceNetworkMonitor` is now observable (`isOnline`, `isAniListDown`); the shell still runs its own
  NWPathMonitor for the Offline bar.
