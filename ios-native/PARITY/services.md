# Parity: Data / services layer

Svelte sources covered (abbreviation used in the tables, line numbers at the time of the port):

| Abbr. | File |
|---|---|
| AL | `common/modules/anilist.js` (+ `al.d.ts`) |
| MAL | `common/modules/myanimelist.js` (+ `mal.d.ts`) |
| SET | `common/modules/settings.js` (tokens, profiles, MAL OAuth, swapProfiles) |
| HLP | `common/modules/helper.js` |
| PRO | `common/components/Profiles.svelte` |
| PROT | `capacitor/src/main/protocol.js` (and `electron/src/main/protocol.js`) |
| TMDB | `common/modules/tmdb.js` |
| AN | `common/modules/anime/anime.js` |
| SCH | `common/modules/anime/animeschedule.js` |
| DUB | `common/modules/anime/animedubs.js` |
| AP | `common/modules/anime/animeprogress.js` |
| EP | `common/modules/episodes.js` |
| SEC | `common/modules/sections.js` |
| HOME | `common/routes/home/HomePage.svelte` (data part) |
| SP | `common/routes/SchedulePage.svelte` (data part) |
| NOT | `common/modals/NotificationsModal.svelte` (data part) |
| DET | `common/modals/details/DetailsModal.svelte`, `components/EpisodeList.svelte`, `components/Following.svelte`, `common/components/Scoring.svelte`, `common/modals/TrailerModal.svelte` (data parts) |
| CACHE | `common/modules/cache.js` |
| NET | `common/modules/networking.js` |
| APP | `common/App.svelte` (`handleAnime`) |

Swift code: `ios-native/Tsumi/Services/`

| File | Types |
|---|---|
| `Services.swift` | `Services` (container, `start()`, deep links), `TsumiDeepLink` |
| `ServiceSupport.swift` | `ServiceError`, `ServiceLocked`, `ServiceRateLimiter`, `ServiceInflight`, `ServiceAnyBox`, `FuzzyDate`, `ServiceDates`, `AnimeSeasonClock`, `ServiceJSON`, `ServiceText`, `ServiceNetworkMonitor`, `ServiceSettingsExtras`, `ServiceMessages` (toasts) |
| `MediaStore.swift` | `MediaStore` (mediaCache), `MediaExtras`, `AiringNode`, `StreamingEpisodeInfo`, `RelationEdgeInfo`, `CustomListFlag`, `TMDBSeasonInfo`, `ServiceListOverlay` |
| `AniListService.swift` | `AniListService`, `AniListVariables`, `AniListParser`, `ListEntryInput`, `SavedListEntry`, `AniListNotificationItem`, `AniListFollowingEntry`, `AniListCompoundTitle`, `AniListMediaBatcher` |
| `MyAnimeListService.swift` | `MyAnimeListService`, `MALStatusMap` |
| `AccountStore.swift` | `AccountProfile`, `AccountStore`, `TsumiKeychain` |
| `ProfilesService.swift` | `ProfilesService` (login / profiles), `TsumiWebAuthenticator` |
| `MediaListService.swift` | `MediaListService` (helper.js), `UserListItem`, `UserLists`, `ListFilter`, `UserListSorts` |
| `TMDBService.swift` | `TMDBService`, `TMDBDetails`, `TMDBSeasonEpisode`, `TMDBScheduleEntry`, `TMDBSearchQuery`, `TMDBEpisodeRef`, `TMDBPerson`, `TMDBCastMember`, `TMDBArtwork` |
| `AnimeMappingsService.swift` | `AnimeMappingsService`, `AnimapEntry`, `AnimapIndex`, `AniZipMappings`, `AniZipEpisode`, `AniZipIds`, `KitsuEpisode`, `JikanEpisode` |
| `AnimeHelpers.swift` | `AnimeHelpers`, `AnimeCatalog`, `ZeroEpisodeInfo`, `TraceMoeMatch`, `SkipChapter` |
| `MALDubsService.swift` | `MALDubsService`, `MALDubLists` |
| `AnimeScheduleService.swift` | `AnimeScheduleService`, `ReleaseFeed`, `ScheduleMedia`, `DubScheduleEntry`, `AiredFeedEntry`, `ScheduleManifest`, `ScheduleFilter` |
| `AnimeProgressService.swift` | `AnimeProgressService`, `EpisodeProgressRecord` |
| `HomeSectionsService.swift` | `HomeSectionsService`, `HomeSection`, `HomeSectionKind`, `HomeSectionPage`, `SectionQuery`, `SearchRequest` |
| `MediaDetailsService.swift` | `MediaDetailsService` (details, episode list, trailer, following) |
| `AppNotificationsService.swift` | `AppNotificationsService`, `MediaNotification`, `ReleaseNotifyStore`, `TsumiNotificationDelegate` |

Status: **done** = same behavior; **partial** = works, gap described; **n.a.** = not applicable on iOS (reason given).
Shared types added outside Core (Core was not modified): see the second table above. Settings missing from
Core `SettingsValues` are stored by `ServiceSettingsExtras` (UserDefaults): `releasesNotifyNotOnList`
('NOTONLIST'), `hentaiAnnounce`, `cardAudio`.

## 1. AniList client (AL)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 1.1 | `seasons`, `currentSeason`, `currentYear` | AL 17-20 | `AnimeSeasonClock.ordered / currentSeason / currentYear / nextSeason` | done |
| 1.2 | `getDistanceFromTitle` (Levenshtein, synonyms +2) | AL 26-33 | `AniListParser.distance`, `ServiceText.levenshtein` | done |
| 1.3 | `queryObjects` media fields (titles, dates, tags, cover, airing schedule, list entry, relations, streaming episodes, trailer, stats...) | AL 35-134 | `AniListService.mediaFields` + `AniListParser.media` → `Media` + `MediaExtras` | done |
| 1.4 | `queryComplexObjects` (studios, recommendations) with `queryComplexity` | AL 136-153 | always included in `mediaFields` | partial: the "Simple" query complexity option does not exist in Core settings, Complex is always used (the Svelte default) |
| 1.5 | Bottleneck limiter (90 / min, 10 concurrent, 100 ms) | AL 156-162 | `ServiceRateLimiter(capacity: 90, interval: 60, minSpacing: 0.1)` | done (no concurrency cap, spacing only) |
| 1.6 | `failed` handler: 429 Retry-After +1 s, 500 retry, offline stop, error toast | AL 173-185 | `AniListService.request` (pause limiter, up to 4 attempts, offline throws, `ServiceMessages` toast) | done |
| 1.7 | `handleRequest`: fetch, JSON, error toasts "Search Failed" | AL 212-242 | `AniListService.request` | done |
| 1.8 | `alRequest`: default `page 1 / perPage 50 / sort TRENDING_DESC`, `sort: 'OMIT'`, Authorization token | AL 248-277 | `AniListVariables` defaults (`sort == nil` = OMIT), `request(token:)` | done (sends `Bearer <token>`, the documented AniList format) |
| 1.9 | String ids return `{data: null}` | AL 249 | ids are typed `Int`, TMDB media never reach AniList | n.a. (typed ids) |
| 1.10 | `userLists` store loaded at start from cache then refreshed, refresh every 15 min | AL 187-202 | `MediaListService.start()` (cached lists → refresh → every 15 min) | done |
| 1.11 | AniList notifications check at start and every 5 min | AL 193, 204-206 | `AppNotificationsService.start()` polling task | done (foreground only, see 13.14) |
| 1.12 | `viewer` query (avatar, name, id, custom lists) | AL 280-300 | `AniListService.viewer(token:)` | done |
| 1.13 | `findNewNotifications` (aniNotify all / limited / none, preferDubs filter, AIRING vs RELATED_MEDIA_ADDITION messages, lastAni) | AL 302-337 | `AppNotificationsService.checkAniList()` | done |
| 1.14 | `getNotifications` (cached 4 min) | AL 344-393 | `AniListService.notifications()` | done |
| 1.15 | `getUserLists` (MediaListCollection, forceSingleCompletedList, user sort handling, 3 attempts with 5 s wait, cached 14 min, other profiles by userID/token) | AL 396-428 | `AniListService.userLists(userId:token:)` + `MediaListService.refresh()` (DiskCache 14 min) | done |
| 1.16 | `sortListEntries` (STARTED_ON / FINISHED_ON / PROGRESS / USER_SCORE / UPDATED_TIME, empty values last) | AL 438-474 | `MediaListService.sort(_:by:)` | done |
| 1.17 | `entry` (SaveMediaListEntry status / progress / repeat / scoreRaw / dates) | AL 476-503 | `AniListService.saveEntry` | done (the returned score is requested in POINT_10 so the cache keeps a 0-10 score) |
| 1.18 | `delete` (DeleteMediaListEntry) | AL 505-517 | `AniListService.deleteEntry(listEntryId:)` | done |
| 1.19 | `updateListEntry` / `deleteListEntry` (local list + mediaCache update without refetch) | AL 519-552 | `MediaListService.updateLocal / removeLocal` + `MediaStore.setListEntry` | done |
| 1.20 | `alSearchCompound` (aliased multi search, best title distance, cached 60-90 min) | AL 557-628 | `AniListService.searchCompound` | done (no iOS caller yet: the file name resolver is not part of the native app) |
| 1.21 | `search` (adult filters, Hentai exclusion, cached 75-100 min, fallback search on error, MAL list fill) | AL 630-658 | `AniListService.search` + `AniListVariables.withAdultFilters` | done |
| 1.22 | `searchIDSingle` by id / idMal (cached 80-100 min) | AL 660-681 | `AniListService.media(id:)`, `media(malId:)` | done |
| 1.23 | `searchIDS` (page of ids, cached 24-30 min, skipCache) | AL 684-714 | `AniListService.searchIDs(_:skipCache:)` | done |
| 1.24 | `searchAllIDS` (all pages, dedup ids, cached 34-46 min) | AL 717-739 | `AniListService.searchAllIDs` | done (each page cached individually) |
| 1.25 | `episodes` (airingSchedules of a media, cached 75-100 min) | AL 742-756 | `AniListService.airingSchedule(id:)` | done |
| 1.26 | `episodeDate` (cached 90-100 min) | AL 759-770 | `AniListService.episodeDate(id:episode:)` | done |
| 1.27 | `following` (cached 200-300 min) | AL 773-816 | `AniListService.following(mediaId:)` (also drops the viewer and duplicate names like Following.svelte) | done |
| 1.28 | `recommendations` (from the complex media when available) | AL 819-837 | `AniListService.recommendationIds(id:)` | done |
| 1.29 | `favourite` (ToggleFavourite, optimistic) | AL 839-850 | `AniListService.toggleFavourite(id:)`, `isFavourite` | done |
| 1.30 | `title` (userPreferred when logged into AniList, else titleLang) | AL 853-859 | `AniListService.title(_:)` | done |
| 1.31 | `reviews` (score distribution total or "?") | AL 862-865 | `AniListService.reviews(_:)` | done |
| 1.32 | `requestMediaID` / `processQueuedMediaIDs` (1.5 s debounced batch, dedup promises) | AL 868-918 | `AniListService.requestMedia(id:)` + `AniListMediaBatcher` | done |
| 1.33 | `fallbackSearch` (offline filtering / sorting / paging of mediaCache) | AL 926-1017 | `AniListService.fallbackSearch` + `AniListParser.fallbackOrder` | done |
| 1.34 | Graveyard methods (searchName, alSearch, searchAiringSchedule, customList, searchIDStatus) | AL 1019-1106 | — | n.a. (dead code in the Svelte app) |

## 2. MyAnimeList client (MAL, SET)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 2.1 | Client id (base64) | MAL 13 | `MyAnimeListService.clientID` | done |
| 2.2 | `queryFields` | MAL 15-38 | `MyAnimeListService.queryFields` | done |
| 2.3 | Limiter 20 / 4 s, 2 concurrent, 1 s spacing, failed handler (Retry-After, 500) | MAL 41-68 | `ServiceRateLimiter(capacity: 20, interval: 4, minSpacing: 1)` in `request` | done |
| 2.4 | User lists loaded at start and refreshed every 15 min | MAL 70-77 | `MediaListService.start()` | done |
| 2.5 | `malRequest` (Bearer token, form body) | MAL 84-98 | `MyAnimeListService.request` | done |
| 2.6 | `handleRequest`: skip failed refresh / reauth profiles, refresh before `refresh_in`, invalid_token → refresh + retry, error toasts | MAL 109-170 | `MyAnimeListService.request` | done |
| 2.7 | `refreshToken` (failedRefresh list) | MAL 172-183 | `MyAnimeListService.refreshToken` (deduplicated) | done |
| 2.8 | `malEntry` (sets mediaCache entry) | MAL 185-190 | `MediaListService.performSave` (MAL branch) | done |
| 2.9 | `getUserLists` (paged 1000, nsfw, custom `_nan` sorts by start / finish / progress) | MAL 193-247 | `MyAnimeListService.userLists` + `MediaListService.sort` | done (custom and server sorts applied locally) |
| 2.10 | `viewer` (default kaomoji picture) | MAL 250-262 | `MyAnimeListService.viewer(token:)` | done |
| 2.11 | `entry` (PUT my_list_status, date swap when start > finish, is_rewatching, refetch lists) | MAL 264-308 | `MyAnimeListService.saveEntry` + `MediaListService.scheduleMALRefresh` | done |
| 2.12 | `delete` (DELETE my_list_status, refetch lists) | MAL 310-322 | `MyAnimeListService.deleteEntry` | done (an empty 200 body now counts as success; the Svelte app treated it as a failure and kept the cached entry) |
| 2.13 | `handleMalToken`: PKCE code exchange (plain challenge) + viewer + 14 day refresh_in | SET 137-169 | `MyAnimeListService.exchangeCode` + `ProfilesService.handleMALCode` | done |
| 2.14 | `refreshMalToken` (refresh_token grant, reauth flag, toast for the current profile, updates current or other profile) | SET 171-222 | `MyAnimeListService.performRefresh` + `AccountStore.replaceProfile / markReauth` | done |

## 3. Accounts, login and profiles (SET, PRO, PROT)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 3.1 | `alToken` / `malToken` persisted (localStorage ALviewer / MALviewer) | SET 10-12 | `AccountStore` (`Snapshot.current`, Keychain item `accounts.v1`) | done |
| 3.2 | `profiles` store (other profiles) | SET 75-79 | `AccountStore.others`, `ProfilesService.others` | done |
| 3.3 | `sync` store (synced profile ids) | SET 55-59 | `AccountStore.syncIds`, `ProfilesService.toggleSync` | done |
| 3.4 | `isAuthorized` | SET 81-83 | `AccountStore.isAuthorized`, `ProfilesService.isAuthorized` | done |
| 3.5 | Paste handler: `access_token=` / `code=&state=` / anilist.co & myanimelist.net anime links | SET 85-123 | `ProfilesService.handleCallback(_:)`, `Services.parseWebLink`, `Services.handle(url:)` | partial: available as API, the UI must forward pasted text / URLs |
| 3.6 | `handleToken` (viewer check, error toast, swapProfiles) | SET 125-134 | `ProfilesService.handleAniListToken` | done |
| 3.7 | `swapProfiles` (same viewer → update, existing other → update, else push current to others; null → first other or logout) | SET 224-252 | `ProfilesService.swapProfiles` (+ `logout`, `switchTo`) | done |
| 3.8 | `location.reload()` after a profile change | SET 251 | `ProfilesService.accountChanged` (clears list entries, reloads lists, rebuilds sections, restarts polling) | done |
| 3.9 | `cache.abandon` (per-user cache) | SET 226, 246 | per-account cache keys (`lists.v1.<account>`, `al.notifications.<viewer>`) + `MediaStore.clearListEntries` | partial: shared API caches are not wiped on account switch (only user-specific data) |
| 3.10 | `setViewer` (AniList profile = has avatar) | SET 254-264 | `AccountProfile.viewer.service` | done |
| 3.11 | AniList login: implicit grant, client id `MzU5NzE=` (35971), redirect `tsumi://alauth` | PRO 47-49, PROT 6, 32-38 | `ProfilesService.loginAniList` (ASWebAuthenticationSession, scheme `tsumi`) | done |
| 3.12 | MAL login: random 10 char state, 50 char plain PKCE challenge, redirect `tsumi://malauth` | PRO 51-57, PROT 7, 40-50 | `ProfilesService.loginMAL`, `pendingMALStates` | done |
| 3.13 | "Login Canceled" toast when the auth window is closed | PRO 59-64 | `ProfilesService.runLogin` (ASWebAuthenticationSessionError.canceledLogin) | done |
| 3.14 | Current profile, other profiles, AniList / MAL badge | PRO 87-104 | `ProfilesService.current / others`, `AccountProfile.isAniList` | done (UI by the screens step) |
| 3.15 | Switch / drop (logout) another profile | PRO 31-39 | `ProfilesService.switchTo`, `drop` | done |
| 3.16 | Sync list entries switch | PRO 41-45 | `ProfilesService.toggleSync`, `isSynced` | done |
| 3.17 | "Authenticate" for profiles needing reauth | PRO 99-103, 133-139 | `AccountProfile.reauth`, `ProfilesService.reauthenticate()` | done |
| 3.18 | At most 5 other profiles ("Add Profile") | PRO 106 | `ProfilesService.canAddProfile`, `maxOtherProfiles` | done |
| 3.19 | Sign Out | PRO 140-146 | `ProfilesService.logout()` | done |
| 3.20 | `IPC 'open' / 'open-auth'` auth windows | PRO 48, 56 | ASWebAuthenticationSession (ephemeral) | n.a. (desktop / Android windows) |
| 3.21 | Protocol links `anime`, `malanime`, `search`, `w2g`, `schedule` | PROT 4-16 | `Services.handle(url:)` → `TsumiDeepLink`, `Services.media(for:)` | done |
| 3.22 | Protocol `update`, `show` | PROT 14-15 | — | n.a. (desktop updater / window) |
| 3.23 | `App.svelte handleAnime` (open by AniList or MAL id) | APP 7-15 | `Services.media(for:)` | done |

## 4. List helper (HLP, Scoring.svelte, AN setStatus / playMedia)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 4.1 | `statusName` | HLP 14-21 | Core `ListStatus.label` | done |
| 4.2 | `sortMap` (AniList user sort → MAL sort) | HLP 23-36 | `MALStatusMap.sortMap` | done |
| 4.3 | `statusMap` / `mapStatus` (bidirectional, REPEATING → watching) | HLP 38-40, CACHE 815-838 | `MALStatusMap.toMAL / fromMAL` | done |
| 4.4 | `airingMap` | HLP 42-51 | `MALStatusMap.airing` | done |
| 4.5 | `getFuzzyDate` (start today when watching, complete today when completed, fix start > completion) | HLP 53-67 | `MediaListService.fuzzyDates` | done |
| 4.6 | `sanitiseObject` | HLP 69-75 | typed structs (`SectionQuery`, `AniListVariables` omit empty values) | n.a. (typed variables) |
| 4.7 | `isAniAuth / isMalAuth / isAuthorized / getClient / getUser / getUserAvatar` | HLP 77-99 | `AccountStore`, `ProfilesService.viewer` (Core `Viewer.avatar`) | done |
| 4.8 | `isUserSort` | HLP 101-103 | `UserListSorts.isUserSort`, `MediaListService.isUserSort` | done |
| 4.9 | `userLists` (refetch with a user sort) | HLP 105-109 | `MediaListService.items(_:sort:)` (sorted locally from the cached lists) | done |
| 4.10 | `entry` (current client or other profile token, mediaCache update, 'notification-read') | HLP 111-133 | `MediaListService.performSave` + `AppNotificationsService.markRead` | done |
| 4.11 | `delete` | HLP 135-148 | `MediaListService.delete` | done |
| 4.12 | `updateEntry` (auto progress after watching: failed resolve toast, CANCELLED skip, zero episode, single episode / movie, completion, rewatch count, change detection, profile sync) | HLP 150-242 | `MediaListService.updateAfterWatching(_:episode:failed:)` | done (dates use the final status, so a completion date is set; the Svelte app passed the pre-completion status) |
| 4.13 | `listToast` (success / error, toasts setting) | HLP 244-264 | `ServiceMessages.post` (All / Errors / None) | done |
| 4.14 | `getPaginatedMediaList` (AniList filters: search, genres, tags, season, year, format(_not), status(_not), continueWatching, dub only; user sort local paging; MAL node filters with TV_SHORT < 20 min; id search with idMal order) | HLP 266-357 | `MediaListService.paginatedMedia(page:perPage:filter:items:)` | partial: title search uses an approximate Fuse.js matcher (`ServiceText.matchKeys`) |
| 4.15 | Scoring `saveEntry` (no change warning, x10 AniList score, custom lists kept, description toast, profile sync) | Scoring.svelte 70-112 | `MediaListService.save(_:status:progress:score:repeatCount:)` | done (custom lists are not re-sent: the Svelte mutation never used `$lists` either) |
| 4.16 | Scoring `deleteEntry` (warning toast, profile sync by list entry id / MAL id) | Scoring.svelte 50-69 | `MediaListService.delete(_:)` | done |
| 4.17 | Scoring score names / max episodes label | Scoring.svelte 23-35 | `AnimeHelpers.maxEpisode` (labels are UI) | done |
| 4.18 | `setStatus` | AN 760-772 | `MediaListService.setStatus(_:media:progress:)` | done |
| 4.19 | `playMedia` start episode (zero episode, continue after progress, completed → Rewatching from 0) | AN 738-758 | `MediaListService.startEpisode(for:)` | done (the playback itself is the Extensions/Player modules) |

## 5. TMDB (TMDB)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 5.1 | API key (base64) | TMDB 7 | `TMDBService.apiKey` | done |
| 5.2 | `TMDB_GENRES`, name → id, `tmdbGenreList` | TMDB 9-46 | `TMDBService.genres`, `AnimeCatalog.tmdbGenres` | done |
| 5.3 | Limiter 40 / s, 429 Retry-After | TMDB 49-72 | `ServiceRateLimiter(capacity: 40, interval: 1, minSpacing: 0.025)` in `get` | done |
| 5.4 | `getTvdbToken` (TVDB login) | TMDB 77-98 | — | n.a. (never called in the Svelte app) |
| 5.5 | `fetchAnimeMap` (animap: tmdbToAnilist, anilistToTmdb with TVDB season / offset) | TMDB 100-130 | `AnimeMappingsService.animapIndex()` (cached 24 h, compact index) | done |
| 5.6 | `handleRequest` (lowercased endpoint, api_key) | TMDB 132-143 | `TMDBService.get` | done |
| 5.7 | `normalizeMedia` (titles, posters w342 / w500, backdrop w1280, logo, format, score x10, genres, year, status rules, mapped anime id) | TMDB 149-190 | `TMDBService.normalize(_:index:)` → Core `Media` (`tmdb-<type>-<id>`, `anilistId` when mapped) | done |
| 5.8 | `search` (movie / tv discover or weekly trending, genre mapping per type, sort mapping, year, exclude ja/zh/ko, interleave, popularity sort, AniList merge of mapped anime) | TMDB 192-325 | `TMDBService.search(_:)` | partial: a mapped anime returns the AniList media with the TMDB ids / backdrop / logo (the Svelte merge kept TMDB titles and cover) |
| 5.9 | `getSchedule` (on the air or popular, western only, details, TVmaze next episode fallback, airing node, sorted) | TMDB 327-405 | `TMDBService.schedule(page:)` | done |
| 5.10 | `injectMediaImages` / `injectTmdbImages` (TMDB backdrop + logo for AniList and TMDB media, TVDB `/find` fallback, cached) | TMDB 407-480 | `TMDBService.injectImages(_:)` (cache 30 days, key includes the media type) | done |
| 5.11 | `getMediaForRSS` / `_getMediaForRSS` ("Western - Recent TV Episodes") | TMDB 482-519 | `TMDBService.recentEpisodes(page:perPage:)` → `EpisodeFeedItem` | done |
| 5.12 | `fromPending` | TMDB 521-525 | — | n.a. (async pages instead of promise placeholders) |
| 5.13 | `getDetails` (videos, credits, recommendations, similar, external ids, keywords, providers, ratings, images, seasons, networks, studios, collection) | TMDB 527-589 | `TMDBService.details(id:type:)` → `TMDBDetails` | done (cached 3 days instead of forever) |
| 5.14 | `getSeasonEpisodes` | TMDB 591-617 | `TMDBService.seasonEpisodes(id:season:)` | done (cached 1 day instead of forever) |
| 5.15 | `getCollection` | TMDB 619-637 | `TMDBService.collection(id:)` | done (cached 7 days) |
| 5.16 | `getRelations` (collection movies as PREQUEL / SEQUEL) | TMDB 639-657 | `TMDBService.relations(id:type:)` | done |
| 5.17 | `getRecommendations` (recommendations + similar, dedup) | TMDB 659-675 | `TMDBService.recommendations(id:type:)` | done |
| 5.18 | `getTrailer` | TMDB 677-686 | `TMDBService.trailer(for:)` | done |
| 5.19 | `textSearch` (search/multi without anime) | TMDB 688-720 | `TMDBService.textSearch(_:page:)` | done |
| 5.20 | DetailsModal TMDB enrichment (genres, tags, description, status, trailer, banner, studios, staff, characters, rating, external ids) | DET DetailsModal 92-160 | `TMDBService.apply(_:to:)`, `MediaDetailsService.details(for:)` | done |
| 5.21 | (Stremio needs) anilistToTmdb lookup, IMDb / TMDB `find` | stremio.js 144, 162 | `AnimeMappingsService.tmdbInfo(anilistId:)`, `TMDBService.find(externalId:source:)` | done (available to the Extensions module) |

## 6. Anime helpers and mappings (AN, EP, DUB)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 6.1 | Clipboard image / image URL paste → trace.moe | AN 24-54 | `AnimeHelpers.traceAnime(imageURL:)`, `traceAnime(imageData:mimeType:)` | partial: API only, the paste handling belongs to the UI |
| 6.2 | `traceAnime` (search ids, episode metadata, similarity sort, search page results) | AN 56-103 | `AnimeHelpers.traceAnime` → `[TraceMoeMatch]` | done |
| 6.3 | `constructChapters` / `getChaptersAniSkip` | AN 105-168 | `AnimeHelpers.aniSkipChapters(malId:episode:duration:)` | done (the Player module also has its own `PlayerAniSkip`) |
| 6.4 | `getMediaMaxEp` (total and playable) | AN 170-174 | `AnimeHelpers.maxEpisode(_:playable:extras:)` | done |
| 6.5 | `anitomyscript` (file name parsing) | AN 177-222 | — | n.a. (local files / torrents are not part of the native app) |
| 6.6 | `hasZeroEpisode` (streaming "Episode 0", prequel special title check, ani.zip S0/S1 specials) | AN 231-251 | `AnimeHelpers.hasZeroEpisode(_:mappings:)` → `ZeroEpisodeInfo` | done |
| 6.7 | `durationMap`, `formatMap` | AN 253-275 | `AnimeCatalog.duration(for:)`, `formatLabel(_:)` | done |
| 6.8 | `statusColorMap`, `genreIcons` | AN 277-306 | — | n.a. (UI colors / icons, screens step) |
| 6.9 | `genreList` (Hentai with adult), `tagList` (adult tags with adult) | AN 308-736 | `AnimeCatalog.genres`, `tags` | done |
| 6.10 | `getEpisodeMetadataForMedia` (ani.zip, else Kitsu, memoized) + `kitsuToAniEpisodes` | AN 775-815 | `AnimeMappingsService.episodeMetadata(for:)` | done |
| 6.11 | `episodeByAirDate` | AN 823-845 | `AnimeHelpers.episodeByAirDate` | done |
| 6.12 | `getAiringInfo`, `episode` (Episode X ~ Y label), `airingAt` | AN 847-878 | `AnimeHelpers.airingInfo(_:nodes:delayedIndefinitely:)`, `airingEpisodeLabel` | done (dub schedule: pass the nodes of `AnimeScheduleService.dubEntry(for:)`) |
| 6.13 | `nextAiring`, `lastAired` | AN 880-892 | `AnimeHelpers.nextAiring`, `lastAired` | done |
| 6.14 | `isSubbedProgress` | AN 894-912 | `AnimeScheduleService.isSubbedProgress` | done (guards against missing MAL ids that the Svelte comparison matched as equal) |
| 6.15 | `getKitsuMappings` (dedup, cache 60-90 min / 14-21 days, stale fallback) | AN 914-963 | `AnimeMappingsService.kitsuId(anilistId:)` | done |
| 6.16 | ani.zip limiter (200 / 30 s) + `getAniMappings` (dedup, cache rules, stale fallback) | AN 965-1034 | `AnimeMappingsService.aniZip(anilistId:)` | done |
| 6.17 | `checkError` (silent on 404 / 521) | AN 1036-1042 | mapping failures are silent | done |
| 6.18 | Episodes limiter (60 / min, 333 ms) + failed handler | EP 11-34 | `AnimeMappingsService.episodesLimiter`, retries in `jikanPage` | done |
| 6.19 | `getEpisodeData` (Jikan page 1, or the last page when paginated) | EP 36-61 | `AnimeMappingsService.jikanEpisodes(malId:)` | done |
| 6.20 | `getSingleEpisode` (filler / recap / title / aired) | EP 63-74 | `AnimeMappingsService.jikanEpisode(malId:episode:)` | done |
| 6.21 | `getKitsuEpisodes` | EP 76-83 | `AnimeMappingsService.kitsuEpisodes(anilistId:)` | done (same first-page request as the Svelte app) |
| 6.22 | `getMedia` (Jikan root, used for the trailer fallback) | EP 85-88 | `AnimeMappingsService.jikanTrailer(malId:)` | done |
| 6.23 | `handleArray` (batch "1 ~ 3" ranges) | EP 90-95 | `AnimeMappingsService.episodeRange(_:)` | partial: string ranges only (array episodes come from file parsing, n.a.) |
| 6.24 | `requestEpisodes` (dedup, cache 1-3 days, offline cache) | EP 97-138 | `AnimeMappingsService.jikanPage` | done |
| 6.25 | MAL dubs list (hourly refresh, cached 100-200 min, stale fallback, error toast) | DUB 11-72 | `MALDubsService.lists(force:)`, hourly loop in `Services.start()` | done |
| 6.26 | `isDubMedia` (MAL id in dubbed / incomplete, or language / file name keywords) | DUB 28-37 | `MALDubsService.isDubMedia(malId:language:fileName:)`, `isDubbed(malId:)` | done |

## 7. AniSchedule feeds and release notifications (SCH)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 7.1 | `lastUpdated` manifest store (persisted) | SCH 35-36 | `ScheduleManifestStore` (DiskCache, long TTL) | done |
| 7.2 | `subAiringLists` / `dubAiringLists` (schedules) | SCH 25-26, 38-39 | `AnimeScheduleService.subAiringList()`, `dubAiringList()` | done |
| 7.3 | `subAiredLists` / `dubAiredLists` / `hentaiAiredLists` (episode feeds) | SCH 27-29, 40-42 | `AnimeScheduleService.airedList(_:)` | done |
| 7.4 | Per page results cache of the feeds | SCH 30-32, 334-341 | `State.pageCache` (signature of the feed) | done |
| 7.5 | Initial notification checks after 3 s | SCH 44-47 | `AnimeScheduleService.start()` | done |
| 7.6 | Manifest polling at the next 5 minute mark + 27-60 s jitter | SCH 55-61, 102 | `AnimeScheduleService.start()` loop | done (foreground only) |
| 7.7 | `checkManifestAndFeeds` (refresh changed schedules, notify, broadcast changed episode feeds) | SCH 67-100 | `AnimeScheduleService.checkForUpdates()` + `feedsChanged` notification → `HomeSectionsService.revision / changedFeeds` | done |
| 7.8 | `findNewDelayedEpisodes` (delayed dub episodes, releasesNotify, messages: suspended / partial dub / date) | SCH 107-154 | `AnimeScheduleService.findNewDelayedEpisodes()` | done |
| 7.9 | `findNewNotifications` (sub / dub / hentai announcements, subAnnounce / dubAnnounce / hentaiAnnounce all / limited, isFollowing by relations) | SCH 156-215 | `AnimeScheduleService.findNewNotifications()` | done (a type without announcements no longer stops the other types — the Svelte loop `return`ed; isFollowing checks every followed list instead of only the first one, and maps MAL ids correctly) |
| 7.10 | `getFeed` (raw GitHub feeds with timestamp, error toasts) | SCH 217-238 | `AnimeScheduleService.getFeed` | done |
| 7.11 | `feedFromManifest` | SCH 240-248 | `feedFromManifest` | done |
| 7.12 | `manifestChanged` (memoized 1 min, outage fallbacks) | SCH 250-278 | `manifestChanged(force:)` | done |
| 7.13 | `feedChanged` (download, stale fallback, cache 315 s, manifest value update under a lock) | SCH 280-311 | `feedChanged` + `ScheduleManifestStore` actor | done |
| 7.14 | `getMediaForRSS` / `_getMediaForRSS` ("Recent Subs / Dubs / Hentai": preferDubs filter, paging, missed episodes, AniList ids, episode metadata) | SCH 313-432 | `AnimeScheduleService.recentEpisodes(_:page:perPage:)` | partial: the preferDubs filter only looks at media already in the store (the Svelte app fetched every feed media) |
| 7.15 | Section format filter of the feed | SCH 330-331 | — | partial: not applied; the Svelte lookup used old section titles ("Subbed Releases") and never matched, so the visible behavior is the same |
| 7.16 | Release notifications (releasesNotify statuses + NOTONLIST, preferDubs, messages "The wait is over!", lastSub / lastDub / lastHentai) | SCH 386-424 | `AnimeScheduleService.notifyReleases` | done ('NOTONLIST' stored in `ServiceSettingsExtras.releasesNotifyNotOnList`) |
| 7.17 | `structureResolveResults` (episode metadata, play click, movies without episode number) | SCH 434-463 | `withEpisodeMetadata` → `EpisodeFeedItem.episodeTitle / thumbnail` | done (movie display rule left to the card) |
| 7.18 | `fromPending` | SCH 465-468 | — | n.a. (async pages) |

## 8. Home sections, search and banner (SEC, HOME)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 8.1 | `search` store persisted as `lastSearched` | SEC 12-23 | `SearchRequest` / `SectionQuery` are `Hashable` value types | partial: persistence of the last search is left to the Search screen |
| 8.2 | `hasNextPage` store | SEC 13 | `MediaPage.hasNextPage`, `HomeSectionPage.hasNextPage` | done |
| 8.3 | `SectionsManager` (add / clear / sections) | SEC 29-48 | `HomeSectionsService.sections`, `HomeSection` | done |
| 8.4 | `createFallbackLoad`: dubs only (idMal of dubbed), hide / show my anime (AniList ids or idMal, MAL idMal_not), anime only, western only (TMDB text or discover without anime), both (AniList 20 + TMDB interleaved, relevance / sort / weighted popularity), TMDB images | SEC 50-151 | `HomeSectionsService.searchMedia(_:page:perPage:)` (+ `search(_ request:)` for the Search page) | done (MAL "show my anime" uses idMal; the Svelte code put MAL ids in `id`) |
| 8.5 | `wrapResponse` / `fromPending` | SEC 153-166 | — | n.a. (async pages) |
| 8.6 | Sections rebuilt (3 s debounce) when homeSections / customSections / westernSections change | SEC 172-191 | `HomeSectionsService.observeSettings` (withObservationTracking, 1 s debounce) | done |
| 8.7 | `createSection` (sort from settings unless static, formats from settings) | SEC 194-195 | `HomeSectionsService.baseQuery` | done ("N/A" sorts fall back to the section default) |
| 8.8 | Anime - Recent Dubs / Anime - Recent Subs / Hentai Releases (adult) / Western - Recent TV Episodes | SEC 198-211 | RSS sections (`kind: .episodes`) | done |
| 8.9 | Sequels You Missed (completed list SEQUEL relations, exclude listed, FINISHED / RELEASING; hidden for MAL / logged out) | SEC 212-230 | `HomeSectionsService.missed(sequels: true)` | done |
| 8.10 | Stories You Missed (other relations except SEQUEL / CHARACTER / OTHER) | SEC 231-249 | `HomeSectionsService.missed(sequels: false)` | done |
| 8.11 | Continue Watching (watching + rewatching, preferDubs caught-up dub filter, MAL caught-up airing filter, continueWatching filter, TMDB images) | SEC 250-298 | `HomeSectionsService.continueWatching` | done |
| 8.12 | Watching / Rewatching / Completed / Planning / Paused / Dropped lists | SEC 299-400 | `HomeSectionsService.userList` | done (MAL Rewatching uses `is_rewatching`; the Svelte filter matched every "watching" entry) |
| 8.13 | Anime - Popular This Season, Upcoming Next Season, Trending now, All Time Popular (hideMyAnime, status_not) | SEC 402-405 | `searchSection` catalog entries | done |
| 8.14 | Custom "Anime Sections" (genres / tags) | SEC 406 | `settings.customSections` → `searchSection` | done (excluded genres / tags are applied too; the Svelte code ignored them) |
| 8.15 | Western sections (TMDB genres, Movies / TV Shows / Both) | SEC 408-430 | `settings.westernSections` → TMDB loader | done |
| 8.16 | `mapSections` (order = settings.homeSections) | HOME 114-121 | `HomeSectionsService.rebuild()` | done |
| 8.17 | Default home layout of settings.js (14 sections) | SET 22-52 | `HomeSectionsService.defaultLayout` | partial: Core `HomeSectionSetting.defaults` (8 sections) stays the default; the full list is exposed for the Settings screen |
| 8.18 | `getTitles` banner (bannerProvider mix / anime / western, hentai banner, current season trending not on list, 2 TMDB trending pages, images, interleave) | HOME 22-102 | `HomeSectionsService.banner()` | partial: the 5 minute refresh timer is the Home screen's job |
| 8.19 | `refreshSections` when user lists or schedules change; `feedChanged` WPC refresh | HOME 149-219 | `HomeSectionsService.revision`, `changedFeeds` (bumped by `MediaListService` and `AnimeScheduleService.feedsChanged`) | done |
| 8.20 | `isPreviousRSS` (layout) | HOME 221-228 | `HomeSection.isRSS` | done (layout decision is UI) |
| 8.21 | Available sections for the settings picker | SEC 196-431 | `HomeSectionsService.availableTitles`, `section(titled:)` | done |

## 9. Schedule page data (SP)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 9.1 | `lastSchedule` persisted filters | SP 11-17 | `ScheduleFilter` (Hashable) | partial: persistence left to the Schedule screen |
| 9.2 | Anime airing list (sub schedule or dub schedule), hide / show my anime, AniList filters (format, genres, tags) | SP 19-44 | `AnimeScheduleService.scheduleEntries` / `animeSchedule` | done |
| 9.3 | Dub schedule rules (skip finished partial dubs, predicted next episode +7 days or suspended, episode count checks, dedup) | SP 46-66 | `animeSchedule` (dubs branch) | done (the airing time comes from the dub schedule nodes; the Svelte final filter re-read the AniList nodes as dates) |
| 9.4 | Western schedule (TMDB on the air, pages) | SP 75-77 | `TMDBService.schedule` | done |
| 9.5 | Mixed, dedup, sorted by next airing, anime only on page 1 | SP 70-98 | `scheduleEntries` → `[AiringEpisode]` | done |

## 10. Notifications (NOT, AL, SCH)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 10.1 | `notifications` store persisted | NOT 15 | `AppNotificationsService.items` (Application Support JSON) | done |
| 10.2 | `hasUnreadNotifications` + 'notification-unread' badge | NOT 16, 27 | `unreadCount`, `hasUnread`, app badge (`setBadgeCount`) | done |
| 10.3 | 'notification-app' event | AL 312, SCH 118 / 183 / 397 | `AppNotificationsService.dispatch(_:)` / `queue(_:systemNotify:)` | done |
| 10.4 | 15 s debounce queue | NOT 45-50 | `queue` + `debounceTask`, `flush()` | done |
| 10.5 | `dedupeNotifications` (id-episode-dub) | NOT 52-60 | `processIncoming` (`MediaNotification.id`) | done |
| 10.6 | `splitLocalAndSystem` (system notifications sorted, max 20) | NOT 62-77 | `processIncoming` + `deliver` | done |
| 10.7 | System notification (title, message, icon, activation `tsumi://anime/<id>`) | NOT 83, IPC 'notification' | `deliver` (UNUserNotificationCenter, cover attachment, `url` userInfo), `TsumiNotificationDelegate` → `onOpenURL` | done |
| 10.8 | `systemNotify` setting | NOT 40 | `dispatch` uses `AppSettings.values.systemNotify`; permission asked in `start()` | done |
| 10.9 | `addNotification` (delayed / released replacement, read when already watched) | NOT 86-98 | `add(_:)` | done |
| 10.10 | `sort` (newest, episode order, unread first) | NOT 100-112 | `AppNotificationsService.sorted` | done |
| 10.11 | `markAll` | NOT 114-116 | `markAll(read:)` | done |
| 10.12 | `markRead` ('notification-read' after a list update) | NOT 118-125 | `markRead(mediaId:episode:episodes:)` | done |
| 10.13 | `markWatchedAsRead` (when the modal opens) | NOT 127-148 | `markWatchedAsRead()` | done |
| 10.14 | `onclick` (view vs play) | NOT 150-157 | `MediaNotification.clickAction`, `deepLink` | done (navigation is UI) |
| 10.15 | `filterResults` search | NOT 165-168 | `filtered(_:)` | partial: approximate fuzzy matching |
| 10.16 | Incremental list rendering (25 per scroll) | NOT 175-185 | — | n.a. (SwiftUI lists are lazy) |
| 10.17 | 'notification-reset' / `cache.resetNotifications` | NOT 43, CACHE 581-584 | `reset()` (also clears `ReleaseNotifyStore`) | done |
| 10.18 | Notification bookkeeping (lastAni / lastSub / lastDub / lastHentai, delayedDubs, announced ids) | CACHE notifyDefaults | `ReleaseNotifyStore` (UserDefaults) | done |
| 10.19 | Checks while the app is closed (desktop tray) | AL 204, SCH 55 | `AppNotificationsService.backgroundRefresh()` | partial: polling runs while the app is in foreground; background delivery needs a BGAppRefreshTask (Info.plist `BGTaskSchedulerPermittedIdentifiers` + `fetch` background mode) wired by the app |

## 11. Playback progress (AP)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 11.1 | Storage (history `animeEpisodeProgress`) | AP 9-17 | `AnimeProgressService.records` (UserDefaults) | done |
| 11.2 | `liveAnimeProgress` (episode → percent) | AP 22-33 | `progress(mediaKey:)` (observable) | done |
| 11.3 | `liveAnimeEpisodeProgress` (nil when completed) | AP 36-44 | `episodeProgress(mediaKey:episode:completed:)` | done |
| 11.4 | `getAnimeProgress` (by name or media / episode, most recent) | AP 47-53 | `record(name:mediaKey:episode:)` | done |
| 11.5 | `setAnimeProgress` | AP 56-74 | `set(name:mediaKey:episode:currentTime:safeDuration:)` | done (the Player's `onProgress` hook calls it) |
| 11.6 | `cache.resetHistory` | CACHE 558-561 | `AnimeProgressService.reset()` | done |

## 12. Details modal data (DET)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 12.1 | Relations (ANIME) + recommendations resolved through searchAllIDS | DetailsModal 50-88 | `MediaDetailsService.details(for:)` → `Media.relations` / `recommendations` | done |
| 12.2 | Western details, recommendations, collection relations | DetailsModal 92-185 | `MediaDetailsService.details(for:)` (TMDB branch) | done |
| 12.3 | Favourite toggle | DetailsModal 212-214 | `MediaDetailsService.toggleFavourite`, `isFavourite` | done |
| 12.4 | Reviews count | DetailsModal 426-466 | `MediaDetailsService.reviews` | done |
| 12.5 | Following list | Following.svelte | `MediaDetailsService.following(for:)` | done |
| 12.6 | Trailer (AniList, Jikan fallback, TMDB) | TrailerModal 44, PreviewCard 56 | `MediaDetailsService.trailer(for:)` | done |
| 12.7 | Episode list `load` (ani.zip, Jikan fallback, airing dates validation, zero episode, Kitsu / streaming titles and thumbnails, duplicate image / summary removal, "will be released" texts, "The Movie", fillers, banner fallback) | EpisodeList 91-208 | `MediaDetailsService.episodes(for:)` → `[EpisodeInfo]` | partial: `dubbedEpisode` (dub airing per episode, only shown with the `cardAudio` setting) is not built; the unreachable `settled` branch is not ported |
| 12.8 | `loadTmdbEpisodes` (movie, seasons with SxEy titles) | EpisodeList 210-258 | `MediaDetailsService.tmdbEpisodes` | done |
| 12.9 | Play button text / handlePlay | DetailsModal 196-230 | `MediaListService.entry(for:)`, `startEpisode(for:)` | done (labels are UI) |

## 13. Caching, network, misc (CACHE, NET)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 13.1 | IndexedDB caches (queries, mappings, user lists, media, history, notifications) | CACHE 26-42 | Core `DiskCache` (API responses), `MediaStore`, Keychain, UserDefaults | done |
| 13.2 | `cachedEntry` / `cacheEntry` (expiry, stale fallback on errors / offline, remap ids to mediaCache) | CACHE 719-796 | DiskCache `get(allowExpired:)` / `set` + `MediaStore.ingest(overwrite: false)` | done |
| 13.3 | Pending request de-duplication | CACHE 758-794 | `ServiceInflight` | done |
| 13.4 | `updateMedia` (merge, keep logo / banner / airing schedule) | CACHE 662-681 | `MediaStore.ingest` | done |
| 13.5 | `requestMedia`, `getMedia` | CACHE 689-709 | `AniListService.requestMedia(id:)`, `MediaStore.media(_:)` | done |
| 13.6 | `fillEntries` (MAL list entries on AniList media) | CACHE 852-876 | `ServiceListOverlay.apply / applyDates`, `MediaStore.reapplyOverlay` | done |
| 13.7 | `resetCaches` | CACHE 569-575 | `Services.clearCaches()` | done |
| 13.8 | `resetSettings` | CACHE 549-552 | Core `AppSettings.reset()` | n.a. (Core) |
| 13.9 | Offline status (`status` store) | NET | `ServiceNetworkMonitor` (NWPathMonitor) | partial: no "AniList API disabled" status, only online / offline |
| 13.10 | `printError` toasts | NET | `ServiceMessages` (`messages`, `latest`, `dismiss`) | done (display is UI) |
| 13.11 | Toast setting (All / Errors / None) | util.js defaults | `ServiceMessages.post` | done |
| 13.12 | `matchKeys` / `matchPhrase` (Fuse.js + Levenshtein) | util.js 323-384 | `ServiceText.matchKeys`, `matchPhrase` | partial: approximate re-implementation without Fuse.js |
| 13.13 | `countdown`, `since`, `monthDay` | util.js 92-183 | `ServiceText.countdown / since / monthDay` | done |
| 13.14 | Timers (15 min lists, 5 min notifications / manifest, hourly dubs) | AL, SCH, DUB | Tasks started by `Services.start()` | done (foreground) |

## Counts

| Status | Rows |
|---|---|
| done | 198 |
| partial | 18 |
| n.a. | 13 |
| **total** | **229** |

## Wiring needed in the app (not in this folder)

- Call `Services.shared.start()` once at launch (e.g. `.task` on the root view).
- `.onOpenURL { url in Task { if let link = await Services.shared.handle(url: url) { /* navigate */ } } }`:
  `alauth` / `malauth` callbacks are consumed (only needed if a login redirect reaches the app outside the
  ASWebAuthenticationSession), other links return a `TsumiDeepLink`.
- `AppNotificationsService.shared.onOpenURL = { url in ... }` for notification taps (same router).
- Optional: `ProfilesService.shared.authenticateOverride` to use SwiftUI's `webAuthenticationSession`.
- Optional background refresh: register a BGAppRefreshTask (Info.plist) that awaits
  `AppNotificationsService.shared.backgroundRefresh()`.
- Player hooks: progress → `AnimeProgressService.shared.set(...)`, autocomplete →
  `MediaListService.shared.updateAfterWatching(_:episode:)`, start episode → `startEpisode(for:)`.
