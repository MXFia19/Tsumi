# Parity: Extensions (Sora modules, Stremio addons) and the playback-resolution flow

Svelte sources covered: `common/modules/extension.js`, `common/modules/stremio.js`,
`common/modules/streaming.js`, `common/modules/session.js`,
`common/modals/extension/ExtensionModal.svelte`, `DefaultLoadingModal.svelte`,
`ServerSelectorModal.svelte`, `components/ExtensionResults.svelte`,
`common/routes/settings/tabs/ExtensionTab.svelte`, `common/routes/catalogs/CatalogPage.svelte`
(plus the parts of `routes/home/components/HomeSection.svelte` the catalog rows rely on).

Swift code: `ios-native/Tsumi/Extensions/`.

Status: **done** = same behavior; **partial** = works, with the gap described;
**n.a.** = not applicable on iOS (reason given); **app** = the hook exists here, the app step wires it.

## Summary

| Status | Count |
|---|---|
| done | 171 |
| partial | 7 |
| n.a. | 8 |
| app (wired by the app step) | 4 |
| **total** | **190** |

## 1. `modules/extension.js` (Sora runtime + extension manager)

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 1.1 | `getProxyPort` / `cachedProxyPort` (Electron fetch proxy so extensions can send User-Agent, Cookie, Referer) | `SoraNetwork` (URLSession sends any header directly) | n.a. (no proxy needed on iOS) |
| 1.2 | `extensionFetch(url, options)` exported helper | - | n.a. (exported but used nowhere in the Svelte app) |
| 1.3 | `getExtension(url, isJson)`: GET, `HTTP <status> fetching <url>` error | `ExtensionLoader.fetch` | done |
| 1.4 | `AsyncFunction` wrapper: module code + `return await fn(args)` in one async function body (top-level `await` works, `const fn = async ...` modules work) | `SoraRuntime.run` (same wrapper evaluated in a fresh `JSContext`) | done |
| 1.5 | One fresh execution per call (no state kept between calls) | `SoraRuntime.call` (new `JSVirtualMachine` + `JSContext` per call) | done |
| 1.6 | Arguments passed as `JSON.stringify(arg)` | `SoraRuntime.encodeArguments` + `ExtensionJSON.quote` | done |
| 1.7 | 30 s timeout, error `Extension execution timeout` | `SoraRuntime.executionTimeout` | done |
| 1.8 | Cancellation when the caller goes away | `withTaskCancellationHandler` in `SoraRuntime.call` (pending URLSession tasks cancelled) | done (iOS addition) |
| 1.9 | `fetchv2(url, headers, method, body)` positional call style | `SoraPrelude` `g.fetchv2` | done |
| 1.10 | `fetchv2(url, { headers, method, body })` options call style (`__normArgs`) | `looksLikeOptions` in `SoraPrelude` (also accepts `{ method, body }` without `headers`) | done |
| 1.11 | Method upper-cased, default `GET` | `SoraPrelude` | done |
| 1.12 | Body sent only for non-GET/HEAD; string as-is, objects `JSON.stringify` | `encodeBody` + `SoraNetwork.start` (also ArrayBuffer/typed arrays/URLSearchParams) | done |
| 1.13 | All headers allowed (User-Agent, Cookie, Referer) | `SoraNetwork.start` (`setValue(forHTTPHeaderField:)`, no cookie jar so manual `Cookie` wins) | done |
| 1.14 | Proxy default User-Agent (desktop Chrome 131) when the module sets none | `SoraNetwork.defaultUserAgent` | done |
| 1.15 | Network failure through the proxy = HTTP 500 response with `{"error": message}` (fetchv2 never rejects) | `SoraNetwork.deliverFailure` | done |
| 1.16 | `__wrapResponse`: `ok`, `status`, `statusText` | `makeResponse` (JS) + `SoraNetwork.statusText` | done |
| 1.17 | `headers` as a plain object with lower-case keys | `makeHeaders` (plus non-enumerable `get`/`has`/`forEach` helpers) | done |
| 1.18 | `x-set-cookie` handling (JSON array joined with `, `, sets `set-cookie` and `Set-Cookie`) | `makeHeaders`; real `Set-Cookie` from URLSession also exposed as `set-cookie`/`Set-Cookie` | done |
| 1.19 | `text()`, `json()`, `arrayBuffer()`, `blob()` | `makeResponse` (bytes fetched lazily through `__tsumiBytes`) | done |
| 1.20 | Plain `fetch` available to modules (browser fetch) | `g.fetch` (Response-like object, rejects with TypeError on network error) | done |
| 1.21 | `console.log/error` (browser console) | `g.console` → `__tsumiLog` (printed in DEBUG builds) | done |
| 1.22 | `atob`/`btoa`, `setTimeout`/`setInterval`, `TextEncoder`/`TextDecoder`, `URL`/`URLSearchParams`, `AbortController` (browser globals) | `SoraPrelude` polyfills (JavaScriptCore has none of them) | done |
| 1.23 | Sora-host extras: fetchv2 5th/6th arguments (`redirect`, `encoding`), global `log()` | `SoraPrelude` + `SoraRedirectBlocker` + `SoraNetwork.decode` | done (iOS addition, harmless superset) |
| 1.24 | `networkFetch` (Sora app WebView interception API) | - | n.a. (not provided by the Svelte app either) |
| 1.25 | `loadExtension`: `stremio://` normalization, manifest fetch, error `Failed to load manifest from <url>: <msg>` | `ExtensionLoader.load` | done |
| 1.26 | Manifest URL resolved against `window.location.href` (relative URLs) | `ExtensionLoader.load` requires an absolute http(s) URL | n.a. (no page origin on iOS; relative URLs are meaningless) |
| 1.27 | Stremio manifest detection → `loadStremioAddon` | `ExtensionLoader.load` + `StremioAddon.isStremioManifest` | done |
| 1.28 | Sora manifest validation, error `Invalid manifest: expected a Sora module (sourceName + scriptUrl) or a Stremio addon` | `ExtensionManifest(soraJSON:)` (also accepts the common `scriptURL` spelling) | done |
| 1.29 | `scriptUrl` resolved relative to the manifest URL; error `Failed to load script from <url>: <msg>` | `ExtensionLoader.load` | done |
| 1.30 | Manifest fields kept (sourceName, iconUrl, version, language, streamType, quality, type, scriptUrl, ...) | `ExtensionManifest` | done |
| 1.31 | `callExtensionFunction`: Stremio → `callStremioFunction`, Sora → JS; `Extension not loaded` | `ExtensionCalls.call` | done |
| 1.32 | String results `JSON.parse`d, raw string kept when not JSON | `SoraRuntime.decodeResult` | done |
| 1.33 | `extractDetails` (Sora module format) | `ExtensionCalls.extractDetails` | done (not used by the Svelte UI) |
| 1.34 | `ExtensionManager.extensions` (loaded runtimes) / `loading` | `ExtensionManager.loaded` / `loadingKeys` | done |
| 1.35 | `settings.extensions[key] = { url, enabled, manifest }` persisted | `ExtensionManager.installed` (UserDefaults `tsumi.extensions.v1`, JSON, insertion order) | done |
| 1.36 | `addExtension(url)`: key `${sourceName}-${version}`, stored enabled with the raw URL, replaces same key | `ExtensionManager.addExtension` | done |
| 1.37 | `removeExtension(key)` | `ExtensionManager.removeExtension` | done |
| 1.38 | `toggleExtension(key, enabled)` | `ExtensionManager.toggleExtension` | done |
| 1.39 | `setDefault` / `unsetDefault` (`settings.defaultExtension`) | `ExtensionManager.setDefault/unsetDefault` → `AppSettings.shared.values.defaultExtension` | done |
| 1.40 | `setStar` / `unsetStar` (`settings.starredExtension`) | `ExtensionManager.setStar/unsetStar` → `AppSettings.shared.values.starredExtension` | done |
| 1.41 | `syncFromSettings`: (re)load every installed extension at launch, failures logged | `ExtensionManager.init` → `reload()` | done |
| 1.42 | Extension still usable when the launch reload fails (browser HTTP cache) | `ExtensionPayloadStore` (last script / Stremio manifest kept in Application Support) | done (explicit offline copy) |
| 1.43 | `subscribe` / `notify` | `@Observable` `ExtensionManager` | done |
| 1.44 | `getEnabled()` | `ExtensionManager.enabledExtensions()` | partial: ordered by install order (Svelte: by load completion order, which is random) |
| 1.45 | `callDefault(fn, ...args)` with `No default extension set` / `Extension <key> not loaded` | `ExtensionManager.callDefault` | done |
| 1.46 | `callAll(fn, ...args)` sequential, failures skipped | `ExtensionManager.callAll` | done |
| 1.47 | A play request right after launch waits for loads in progress | `ExtensionManager.awaitPendingLoads` | done (iOS addition; Svelte would report the default extension as missing) |

## 2. `modules/stremio.js` (Stremio addons)

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 2.1 | `REQUEST_TIMEOUT` 45 s, `Addon did not answer in time (<resource>)` | `StremioAddon.requestTimeout`, `StremioAddon.fetch` | done |
| 2.2 | `requestCache`: same URL within TTL shares one request; failures evicted; TTL 0 = no cache | `StremioRequestCache` (actor) | done |
| 2.3 | Default TTL 5 min, meta 30 min, streams 0 | `StremioAddon.request` callers | done |
| 2.4 | `Addon returned HTTP <status> for <resource>` | `StremioAddon.fetch` | done |
| 2.5 | `isStremioManifest` (no scriptUrl, string id, resources array) | `StremioAddon.isStremioManifest` | done |
| 2.6 | `normalizeManifestUrl` (`stremio://` → `https://`, trim) | `StremioAddon.normalizeManifestURL` | done |
| 2.7 | `addonBaseUrl` (strip `/manifest.json[?...]`, trailing slashes) | `StremioAddon.baseURL(forManifest:)` | done |
| 2.8 | `normalizeStremioManifest` (sourceName = name or id, icon = logo or icon, version default `0.0.0`, streamType `Stremio`, stremioId) | `ExtensionManifest(stremio:)` | done |
| 2.9 | `loadStremioAddon` ({ base, manifest }) | `StremioAddon(base:manifest:)` | done |
| 2.10 | `resourceInfo` (short and object resources, types/idPrefixes fallbacks to the manifest) | `StremioManifest.resourceInfo` | done |
| 2.11 | `supportsResource(manifest, name, type, id)` | `StremioManifest.supportsResource` | done |
| 2.12 | `encodeId` (each `:` part URI-encoded) | `StremioAddon.encodeId` | done |
| 2.13 | `extraPath` (`/k=v&k=v`, empty values skipped, insertion order) | `StremioAddon.extraPath` + `StremioExtraParam` | done |
| 2.14 | URL `{base}/{resource}/{type}/{id}{extra}.json` | `StremioAddon.resourceURL` | done |
| 2.15 | `encodeRef` / `decodeRef` (`stremio:` + JSON) | `StremioRef.encoded` / `StremioRef.decode` | done |
| 2.16 | `tmdbFromImdb` (`/find`, preferred type first, then any) | `StremioAddon.tmdbFromIMDb` via `ExtensionContext.tmdbFindByIMDb` | done |
| 2.17 | `resolveMediaIds` (TMDB id, movie/tv, AniList mapping season + episode offset) | `StremioAddon.resolveMediaIds` via `ExtensionContext.animeToTMDB` | done |
| 2.18 | `pickAddonId` (`tmdb:<id>` first, else IMDb id from TMDB details) | `StremioAddon.pickAddonId` via `ExtensionContext.tmdbIMDbId` (uses `Media.imdbId` when already known) | done |
| 2.19 | `catalogSupports` (extra / extraSupported) | `StremioCatalog.supports` | done |
| 2.20 | `catalogRequiresExtra` (isRequired / extraRequired) | `StremioCatalog.requiresExtra` | done |
| 2.21 | `listCatalogs(ext, { search })` | `StremioAddon.listCatalogs(search:)` | done |
| 2.22 | `searchCatalogs`: searchable catalogs of the types, in parallel, failures skipped, dedup by `type:id` | `StremioAddon.searchCatalogs` | done |
| 2.23 | `metaToMedia`: tmdb:/tt ids → TMDB media, year from releaseInfo/year, status from the year | `StremioAddon.metaToMedia` | done |
| 2.24 | Poster upgrade (`image.tmdb.org` `/wNNN/` → `/w500/`), background, genres, imdbRating → averageScore | `StremioAddon.metaToMedia` | done |
| 2.25 | `normalizeMedia` mapping TMDB → AniList id (`tmdbToAnilist`) | `Media.anilistId` from `ExtensionContext.tmdbToAnilistId` | partial: the media stays a TMDB `Media` with `anilistId` set (the Svelte app swapped the id); the app decides how to open it |
| 2.26 | `media.stremioId` | - | n.a. (no Core field; never read by the Svelte app) |
| 2.27 | `metasToPage` (parallel, failures dropped, order kept) | `StremioAddon.metasToPage` | done |
| 2.28 | `loadCatalogPage` (skip pagination, up to 6 batches per page, `hasNextPage`) | `StremioAddon.loadCatalogPage` | done |
| 2.29 | `searchResults` by id (title, cover, ref with season/offset) | `StremioAddon.searchResults` | done |
| 2.30 | `searchResults` fallback on catalog search (types from ids or media format) | `StremioAddon.searchResults` | done |
| 2.31 | `videosFromTmdb` (episodes from TMDB seasons) | `StremioAddon.videosFromTMDB` via `ExtensionContext.tmdbSeasons` | done |
| 2.32 | `extractEpisodes`: movie → single "Movie" entry | `StremioAddon.extractEpisodes` | done |
| 2.33 | `extractEpisodes`: addon meta videos (when `meta` supported), TMDB fallback | `StremioAddon.extractEpisodes` | done |
| 2.34 | Specials (season 0) removed, numbers from `episode ?? number`, sort by season then number | `StremioAddon.extractEpisodes` (stable sort) | done |
| 2.35 | AniList season/offset: keep the mapped season, renumber after the offset | `StremioAddon.extractEpisodes` | done |
| 2.36 | `streamTitle` (name lines + non-duplicate title/description lines, `Server N`) | `StremioAddon.streamTitle` | done |
| 2.37 | `pickSubtitle` (French first, else first) | `StremioAddon.pickSubtitle` | done |
| 2.38 | `extractStreamUrl`: only http(s) URLs, proxy request headers, subtitle | `StremioAddon.extractStreamUrl` | done |
| 2.39 | Errors `This addon only returned peer-to-peer or external links, which Tsumi cannot play` / `No streams found for this title` | `StremioAddon.extractStreamUrl` | done |
| 2.40 | `callStremioFunction` + `Stremio addons do not support <fn>` | `StremioAddon.call` | done |

## 3. `modules/streaming.js` and `modules/session.js`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 3.1 | `parseStreamResponse` plain string | `ExtensionStreamParser.parse` | done |
| 3.2 | `{ streams: [{ title, streamUrl, headers }], subtitles }` | `ExtensionStreamParser.parse` (also accepts `url` in place of `streamUrl`) | done |
| 3.3 | Flat `["DUB", url, "SUB", url]` arrays with shared `headers` | `ExtensionStreamParser.parse` | done |
| 3.4 | `{ streamUrl, headers, subtitles }` (one "Server") | `ExtensionStreamParser.parse` | done |
| 3.5 | `subtitles` or `subtitle` | `ExtensionStreamParser.subtitleURL` (string, array, object; French first in arrays) | done |
| 3.6 | `Invalid stream response` + callers' fallback (`raw` string, `raw.url`, `raw.streamUrl`) | `ExtensionStreamParser.streamData(from:)` | done |
| 3.7 | `getStreamServers` | `ExtensionStreamParser.servers` | done |
| 3.8 | Server title `title` or `Server N` | `ExtensionStream(parsed:)` | done |
| 3.9 | Servers with an unusable URL | `ExtensionStream(parsed:)` drops them (Swift `StreamServer.url` is non-optional) | partial: such entries are hidden instead of failing at play time |
| 3.10 | `loadStream` / `stopStream` / `getProxyUrl` / hls.js loading | - | n.a. (Player area: AVPlayer plays HLS natively; headers go to the player with `StreamServer.headers`) |
| 3.11 | `sessionServer` store (remembered server title for the session) | `StreamSessionMemory.preferredServerTitle` | done |

## 4. `modals/extension/ExtensionModal.svelte`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 4.1 | `playAnime(media, episode, force)` entry point | `PlaybackRequestCoordinator.shared.play(media:episode:force:)` | done |
| 4.2 | Episode as object or number, NaN → 1 | `play(media:episodeNumber:force:)` (clamped to ≥ 1) | done |
| 4.3 | Default extension set and not forced → compact loading dialog, else results modal | `PlaybackRequestCoordinator.play` | done |
| 4.4 | `w2g-play` event → `playAnime(cached media, episode)` | Watch Together calls `PlaybackRequestCoordinator.shared.play` | app |
| 4.5 | Results modal with close | `ExtensionPickerView` in the `.playbackRequestPresenter()` sheet | done |

## 5. `modals/extension/DefaultLoadingModal.svelte`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 5.1 | `titleScore` (100 exact, 90 containment, ≤ 80 word matches) | `PlaybackResolver.titleScore` | done |
| 5.2 | Status texts `Connecting to extension...`, `Searching...`, `Extracting episodes...`, `Loading stream...` | `PlaybackResolver.resolveWithDefault` → `DefaultLoadingModel.statusText` | done |
| 5.3 | Default extension must be enabled and loaded, else `Default extension not found or disabled` | `PlaybackResolver.resolveWithDefault` | done |
| 5.4 | Stremio addons get the media in `searchResults` | `PlaybackResolver.scoredResults` | done |
| 5.5 | `No results found from default extension` | `PlaybackResolutionError.noResults` | done |
| 5.6 | Best result = highest score (stable order) | `PlaybackResolver.scoredResults` | done |
| 5.7 | `No episodes found for this title` | `PlaybackResolutionError.noEpisodes` | done |
| 5.8 | Episode match: season + local number | `PlaybackResolver.matchEpisode` | done |
| 5.9 | Episode match: href regex `/<season>/<local>(/\|$)` | `PlaybackResolver.matchEpisode` | done |
| 5.10 | Episode match: inferred seasons (numbering restarts) | `PlaybackResolver.matchEpisode` | done |
| 5.11 | Episode match: unique local number | `PlaybackResolver.matchEpisode` | done |
| 5.12 | Episode match: absolute number when no season; first episode as last resort | `PlaybackResolver.matchEpisode` + callers | done |
| 5.13 | Stream parse + fallback, `No stream URL found` | `PlaybackResolver.fetchStream` + `PlaybackResolutionError.noStreamURL` | done |
| 5.14 | Several servers: remembered session server picked automatically | `PlaybackResolver.nextStep` | done |
| 5.15 | Several servers otherwise: loading dialog closed, server selector opened (back = just close) | `PlaybackRequestCoordinator.autoPlay` → `.server` presentation | done |
| 5.16 | Any failure → results modal with `defaultFailed` + `failReason` (`error.message`, else `Stream failed`) | `PlaybackRequestCoordinator.autoPlay` → `openPicker(defaultFailed: true, ...)` | done |
| 5.17 | `launchPlayer`: url/headers of the chosen server, `streamServers`, `subtitle`, `activeServerIndex`, file name `<title> - Episode <n>` | `ResolvedPlayback` (servers, selectedIndex, subtitleURL, displayName) | done |
| 5.18 | `launchPlayer`: `nowPlaying`, `files`, navigate to the player | `PlaybackRequestCoordinator.onReady` / `ready` | app |
| 5.19 | `launchPlayer`: `shareNowPlaying` (Watch Together) | `PlaybackRequestCoordinator.onReady` | app |
| 5.20 | `running` guard / re-run when data changes | one `Task` per request, previous one cancelled | done |
| 5.21 | Closing the dialog | cancels the resolution | partial: deliberate change, the Svelte app kept resolving and still opened the player after the dialog was closed |
| 5.22 | UI: spinner, title (2 lines), `Episode N`, status line | `DefaultLoadingView` | done (Svelte printed `[object Object]` for episode objects; iOS prints the number) |

## 6. `modals/extension/components/ExtensionResults.svelte`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 6.1 | No title → stop loading | `ExtensionPickerModel.searchExtensions` | done |
| 6.2 | Every enabled extension searched, starred first, in parallel | `ExtensionPickerModel.searchExtensions` (`withTaskGroup`) | done |
| 6.3 | Groups appear as each extension answers (completion order) | `ExtensionPickerModel.groups` appended from the task group | done |
| 6.4 | Results scored and sorted per extension; extension name/icon/starred flag | `PlaybackResolver.resultGroup` | done |
| 6.5 | Failing extension silently skipped (debug log) | `ExtensionPickerModel.searchExtensions` | done |
| 6.6 | `selectResult` ignored while another result is resolving | `ExtensionPickerModel.select` (`playingResultID`) | done |
| 6.7 | Toast `No episodes found for this title` | `PlaybackResolver.manualFailureMessage` → inline error banner | done (banner instead of toast) |
| 6.8 | Same season-aware episode matching as the default flow | `PlaybackResolver.resolveStream` | done |
| 6.9 | Toast `No stream URL found for this episode` | `PlaybackResolver.manualFailureMessage` | done (banner) |
| 6.10 | Several servers: session server or server selector over the results (back = close selector) | `ExtensionPickerModel.serverChoice` + nested `ServerPickerView` sheet | done |
| 6.11 | Toast `Stream failed: <message>` | `PlaybackResolver.manualFailureMessage` | done (banner) |
| 6.12 | `launchPlayer` (same as 5.17–5.19) then close the modal | `ExtensionPickerModel.onPlayback` → `PlaybackRequestCoordinator.deliver` | done |
| 6.13 | Header: title (one line, ellipsis) + close button | `ExtensionPickerView.header` | done |
| 6.14 | Header background: banner, trailer thumbnails, Kitsu cover, episode thumbnail, cover | `ExtensionPickerView.bannerURL` (banner → YouTube trailer thumbnail → cover) | partial: Kitsu/episode-metadata fallbacks need the anime services (not available in this folder) |
| 6.15 | `Default extension failed` banner with `<reason> Showing all results instead.` (default reason `Unable to auto-play from your default extension.`) | `ExtensionPickerView` | done |
| 6.16 | Loading: spinner + `Searching extensions...` | `ExtensionPickerView.content` | done |
| 6.17 | Empty: `Ooops!` + `No extensions enabled. Add extensions in Settings → Extensions.` / `No results found from any extension.` | `ExtensionPickerView.content` | done |
| 6.18 | Group header: icon, name, `Starred` badge, `N result(s)` | `ExtensionPickerView.groupSection` | done |
| 6.19 | Result card: cover (or Play placeholder), title (2 lines), `N% match` badge (green ≥ 80, yellow ≥ 50, grey) | `ExtensionPickerView.resultCard` | done |
| 6.20 | Spinner over the card being resolved; other cards disabled (opacity 0.6) | `ExtensionPickerView.resultCard` | done |
| 6.21 | Collapsed groups with `+ N More` / `Show Less` when > 5 results | `ExtensionPickerView.groupSection` | partial: collapsed state shows the first 5 cards (Svelte showed one grid row) |
| 6.22 | Cleanup on destroy | `ExtensionPickerModel.cancel` via `PlaybackRequestCoordinator` | done |

## 7. `modals/extension/ServerSelectorModal.svelte`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 7.1 | Back button (closes, calls `onBack`) | `ServerPickerView.onBack` | done |
| 7.2 | Title `Select Server` | `ServerPickerView` | done |
| 7.3 | `Remember selection for this session` checkbox | `ServerPickerView.remember` → `StreamSessionMemory` | done |
| 7.4 | One button per server with server icon, `title` or `Server N` | `ServerPickerView` | done |
| 7.5 | Pick: remember title if checked, close, `onSelect(index)` | `ServerPickerView.pick` | done |
| 7.6 | Close by clicking outside | sheet swipe-down (same as back) | done |

## 8. `routes/settings/tabs/ExtensionTab.svelte`

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 8.1 | Header `Extensions` + `Add Extension` button (toggles the dialog, clears the error) | `ExtensionSettingsView` | done |
| 8.2 | Add dialog: title `Add Extension`, close button, click outside closes | `ExtensionSettingsView.addDialog` (sheet) | done |
| 8.3 | Warning `Extensions are sandboxed and should be safe, but avoid adding unknown or untrusted sources.` (underlined words) | `ExtensionSettingsView.addDialog` | done |
| 8.4 | Error box with the failure message (`Failed to add extension` fallback) | `ExtensionSettingsView.addSource` | done |
| 8.5 | URL field placeholder `Sora module or Stremio addon manifest URL`, Enter submits | `ExtensionSettingsView.addDialog` (`onSubmit`) | done |
| 8.6 | `Add` button disabled while pending or empty; field disabled while pending | `ExtensionSettingsView.addDialog` | done |
| 8.7 | Success clears the field and closes the dialog | `ExtensionSettingsView.addSource` | done |
| 8.8 | Empty state `No Extensions Found` / `Click the Add Extension button above to get started.` | `ExtensionSettingsView.emptyCard` | done |
| 8.9 | `Default Extension` section (crown icon, explanation text) | `ExtensionSettingsView.defaultSection` | done |
| 8.10 | Default card: icon / unknown-file icon, name, language, URL, `Remove as Default` (X), badges version + streamType, dimmed when disabled | `ExtensionSettingsView.defaultCard` | done |
| 8.11 | Drop zone `Drag an extension here to set it as default` with highlight while dragging | `ExtensionSettingsView.dropZone` + `.dropDestination` | done (also a tap menu to choose, for one-handed use) |
| 8.12 | Drag an extension card onto the default zone/card → `setDefault` | `.draggable(key)` on cards + `.dropDestination` | done (plus a `Set as Default` context-menu item) |
| 8.13 | `Extensions` list: all but the default, starred first | `ExtensionSettingsView.otherExtensions` | done |
| 8.14 | Card: drag handle, icon, name, language, URL, starred border, dimmed when disabled | `ExtensionSettingsView.extensionCard` | done |
| 8.15 | Star / Unstar button (`Star — always show at the top of search results`) | `ExtensionSettingsView.toggleStar` | done |
| 8.16 | Delete with confirmation (ConfirmButton: confirm / cancel) | `ExtensionSettingsView.deleteControl` | done |
| 8.17 | Delete also unsets default / star | `ExtensionSettingsView.removeSource` | done |
| 8.18 | Enable switch | `ExtensionSettingsView.extensionCard` `Toggle` → `toggleExtension` | done |
| 8.19 | Badges: version, streamType, quality, type (not `stremio`) | `ExtensionSettingsView.badgeRow` | done |
| 8.20 | Pending state while adding/removing | `pendingSource` | done |

## 9. `routes/catalogs/CatalogPage.svelte` (+ HomeSection rows)

| # | Svelte feature | Swift | Status |
|---|---|---|---|
| 9.1 | Enabled Stremio addons only, refreshed when the manager changes | `CatalogsView.addons` (observes `ExtensionManager`) | done |
| 9.2 | Header icon + `Catalogs` | `CatalogsView.header` | done |
| 9.3 | Search box only when an addon can search; placeholder `Search in your addons` | `CatalogsView.header` | done |
| 9.4 | 500 ms debounce, Enter searches immediately, clear button (`Clear search`) | `CatalogsView.scheduleSearch` / `onSubmit` / `clearSearch` | done |
| 9.5 | No addon card: `No Stremio addon` + explanation + `Open Settings` | `CatalogsView.noAddonCard` + `onOpenSettings` closure | done |
| 9.6 | No section: `None of your addons can search.` / `Your Stremio addons have no catalogs to browse.` | `CatalogsView.body` | done |
| 9.7 | Browse sections: catalogs without required extra; title = catalog name or `Movies`/`Series`, `· <addon>` when several addons | `StremioCatalogSections.build` | done |
| 9.8 | Search sections: one searchable catalog per type, `<Type> · <addon>` | `StremioCatalogSections.build` | done |
| 9.9 | Section keys `addon\|type\|id\|search` | `StremioCatalogSection.id` | done |
| 9.10 | Row loads lazily when visible (50 items) | `StremioCatalogRowView` `.task` inside `LazyVStack` + `StremioCatalogPageModel` | done |
| 9.11 | Loading skeleton cards | `StremioCatalogRowView.placeholders` | done |
| 9.12 | Error card | `StremioCatalogRowView.failureCard` (with Retry) | done |
| 9.13 | Section title opens the full list (Search page) with pagination | `StremioCatalogGridView` sheet, infinite scroll with `loadMore` | done |
| 9.14 | Card click opens the title | `onSelect: (Media) -> Void` | app |
| 9.15 | Left/right carousel buttons, drag-scroll, hover previews (desktop) | native horizontal scrolling | n.a. (touch UI) |
| 9.16 | Card preview / list-status overlays of `Card.svelte` | `StremioCatalogCard` (poster + title) | partial: the rich Card component belongs to the main-screens step |
| 9.17 | Catalogs entry in the sidebar | - | n.a. here (navigation is the app step) |

## Public API for the app step

- `PlaybackRequestCoordinator.shared.play(media:episode:force:)` / `play(media:episodeNumber:force:)`;
  attach `.playbackRequestPresenter()` once on the root view; set
  `PlaybackRequestCoordinator.shared.onReady = { playback in ... }` (open the player with
  `playback.servers[playback.selectedIndex]` + `playback.subtitleURL`, share with Watch Together, update
  now-playing). `ready` / `consumeReady()` expose the same value for observation.
- `ResolvedPlayback { media, episode, servers, selectedIndex, subtitleURL, extensionKey, displayName }`.
- `ExtensionContext.shared` closures to wire: `animeToTMDB`, `tmdbIMDbId`, `tmdbFindByIMDb`,
  `tmdbSeasons`, `tmdbToAnilistId`, `displayTitle`.
- Screens: `ExtensionSettingsView()`, `CatalogsView(onSelect:onOpenSettings:)`.
- `ExtensionManager.shared` (installed list, `enabledExtensions()`, add/remove/toggle/default/star).
