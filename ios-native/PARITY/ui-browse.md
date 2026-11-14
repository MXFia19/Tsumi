# Parity: Browse screens (home, search, schedule, details) and cards

Svelte sources covered (abbreviation used in the tables):

| Abbr. | File |
|---|---|
| HP | `common/routes/home/HomePage.svelte` (UI part; data part in `services.md` §8) |
| HS | `common/routes/home/components/HomeSection.svelte` |
| BN | `common/components/banner/Banner.svelte` |
| FB | `common/components/banner/FullBanner.svelte` |
| CA | `common/components/cards/Card.svelte` |
| SC | `common/components/cards/SmallCard.svelte` |
| FC | `common/components/cards/FullCard.svelte` |
| PC | `common/components/cards/PreviewCard.svelte` |
| EC | `common/components/cards/EpisodeCard.svelte` |
| EPC | `common/components/cards/EpisodePreviewCard.svelte` |
| ERR | `common/components/cards/ErrorCard.svelte` |
| SK | `common/components/skeletons/*` |
| AU | `common/components/AudioLabel.svelte` (labels of the cards) |
| SP | `common/routes/search/SearchPage.svelte` |
| SB | `common/routes/search/components/SearchBar.svelte` |
| SCH | `common/routes/SchedulePage.svelte` (UI part; data part in `services.md` §9) |
| DM | `common/modals/details/DetailsModal.svelte` |
| DT | `common/modals/details/components/Details.svelte` |
| EL | `common/modals/details/components/EpisodeList.svelte` |
| TL | `common/modals/details/components/ToggleList.svelte`, `ToggleFooter.svelte`, `ToggleTitle.svelte` |
| FO | `common/modals/details/components/Following.svelte`, `User.svelte` |
| SCO | `common/components/Scoring.svelte` |
| TR | `common/modals/TrailerModal.svelte` |
| ST | `common/components/Status.svelte` |

Swift code: `ios-native/Tsumi/UI/Browse/`

| File | Types |
|---|---|
| `BrowseStyle.swift` | `BrowsePalette` (css.css colors, status colors), `BrowseText` (HTML cleanup, synopsis markdown, entities, dates), `BrowseImageCache` + `BrowseImage` (SmartImage: first URL that loads, memory cache), `BrowseShimmer`, `BrowseSkeletonBar`, `BrowseChip`, `BrowseListStatusDot`, `BrowseProgressBar`, `BrowseSectionDivider`, `BrowsePressableStyle`, `BrowseFlowLayout`, `BrowseCardMode`, `BrowseGenreIcons`, `BrowseMarkdownBlock`, `BrowseRotatedCover`, `BrowseDiagonalStripes` |
| `BrowseMediaInfo.swift` | `BrowseMediaInfo` (labels: title, year, season, episodes, play text, images, links, adult filter), `BrowseExternalLink`, `BrowseActions` (open details, playMedia, play episode, favourite, copy link), `BrowseFavouriteStore` (observable favourite revision) |
| `BrowseCards.swift` | `BrowseCardStyle`, `BrowseMediaCard` (Card), `BrowseMediaMenuItems`, `BrowseFavouriteMenuButton`, `BrowseAiringLine`, `BrowseAiringBadge`, `BrowseDubFeed`, `BrowseAudioLabel`, `BrowseSmallCard`, `BrowseFullCard`, `BrowseMediaChips`, `BrowsePreviewCard` |
| `BrowseEpisodeCards.swift` | `BrowseEpisodeCardData` (feed item or trace.moe match), `BrowseEpisodeCardState`, `BrowseEpisodeCard`, `BrowseEpisodeCardContent`, `BrowseEpisodeMetaLine`, `BrowseEpisodeThumbnail`, `BrowseEpisodePreviewCard` |
| `BrowseSkeletons.swift` | `BrowseSmallCardSkeleton`, `BrowseFullCardSkeleton`, `BrowseEpisodeCardSkeleton`, `BrowseBannerSkeleton`, `BrowseEpisodeRowSkeleton`, `BrowseErrorCard` |
| `BrowseListEditor.swift` | `BrowseListEditorButton`, `BrowseListEditor` (Scoring) |
| `BrowseTrailer.swift` | `BrowseTrailerSheet`, `BrowseYouTubePlayer` (WKWebView) |
| `BrowseFilters.swift` | `BrowseSearchFilters` (search object, persistence, loader variables), `BrowseOption`, `BrowseFilterOptions`, `BrowseFilterContext`, `BrowseFilterBadge`, `BrowseFilterBadgesView`, `BrowseTriState`, `BrowseTriStateRow`, `BrowseTagPicker`, `BrowseFilterSheet` |
| `HomeView.swift` | **`HomeView`**, `BrowseHomeModel`, `BrowseSectionRowModel`, `BrowseHomeSectionRow` |
| `HomeBanner.swift` | `BrowseBannerModel`, `BrowseHeroBanner`, `BrowseBannerIndicators`, `BrowseBannerIndicator`, `BrowseBannerPage`, `BrowseBannerInfo`, `BrowseBannerButtons`, `BrowseFavouriteButton` |
| `SearchView.swift` | **`SearchView`**, `BrowseSearchModel`, `BrowseSearchHeader`, `BrowseSourceMenu`, `BrowseSearchField`, `BrowseCardModeButtons`, `BrowseIconButton`, `BrowseIconLabel`, `BrowseSearchResults` |
| `ScheduleView.swift` | **`ScheduleView`**, `BrowseScheduleModel`, `BrowseScheduleHeader`, `BrowseScheduleContent`, `BrowseScheduleDayHeader` |
| `MediaDetailView.swift` | **`MediaDetailView(media:)`**, `BrowseDetailModel`, `BrowseDetailScreen`, `BrowseDetailTop` |
| `MediaDetailHeader.swift` | `BrowseDetailHeader`, `BrowseDetailStats`, `BrowseDetailActions`, `BrowseShareLinkButton`, `BrowseFollowingRow`, `BrowseUserAvatar`, `BrowseUserCard`, `BrowseDetailInfoStrip`, `BrowseNextAiringLine`, `BrowseDetailChips`, `BrowseDetailSynopsis`, `BrowseMarkdownBlocksView` |
| `MediaDetailEpisodes.swift` | `BrowseDetailEpisodes`, `BrowseEpisodeRow` |
| `MediaDetailSections.swift` | `BrowseDetailBottom`, `BrowseExpandableList`, `BrowseToggleList`, `BrowseCharacterRow`, `BrowseStaffRow`, `BrowsePersonCard`, `BrowseExternalLinks` |

Status: **done** = same behavior; **partial** = works, gap described; **n.a.** = not applicable on iOS (reason given);
**extra** = not in the Svelte files, asked for the native app.
Settings that Core `SettingsValues` does not model: `cards` (small / full) is stored with `@AppStorage("tsumi.browse.cards")`;
`cardAudio` is read from `ServiceSettingsExtras.cardAudio`; `toggleList` is read from `AppSettings.shared.values.toggleList`.

## 1. Home page (HP, HS)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 1.1 | Hero banner data (getTitles: bannerProvider mix / anime / western, hentai banner) | HP 22-102 | `BrowseBannerModel.load` → `HomeSectionsService.banner()` | done |
| 1.2 | Banner refresh every 5 minutes | HP 20 | `HomeView` `.task` loop (`load(force: true)`) | done |
| 1.3 | Banner and sections rebuilt when the settings change | HP 259-263 | `.task(id: BrowseBannerModel.settingsKey)`; sections from `HomeSectionsService.sections` (rebuilt by the service) | done |
| 1.4 | Sections in settings.homeSections order (mapSections, remap-sections) | HP 104-121 | `ForEach(Services.shared.sections.sections)` | done |
| 1.5 | Hidden sections skipped (logged out / MAL "missed" sections) | HP 272 | the service only lists visible sections | done |
| 1.6 | refreshSections when the user lists change (list sections) and when episode feeds change (RSS + Continue Watching) | HP 145-185 | `HomeSectionsService.revision` (lists, settings) in the `.task(id:)` key of each row; feed changes use the per-feed key of 1.7 | done |
| 1.7 | feedChanged: reload a feed section only when its feed changed | HP 187-219 | `HomeSectionsService.feedRevisions` / `feedRevision(forSection:)` (bumped from `changedFeeds`) appended to the row key: only the Recent Subs / Dubs / Hentai row of the changed feed reloads | done |
| 1.8 | resolveData comparison: keep the rendered cards when the reloaded first page is the same | HP 128-142 | `BrowseSectionRowModel.applyFirstPage` (ids compared, loaded pages kept) | done |
| 1.9 | hideBanner: banner layer fades after 100 px of scroll | HP 236-251 | the banner scrolls with the content | n.a. (no fixed background layer on iOS) |
| 1.10 | isPreviousRSS: negative margin after episode rows | HP 221-228 | rows are stacked normally | n.a. (desktop overlap layout) |
| 1.11 | Section title click → Search page with the section loader, variables and title (clearNext) | HS 33-36 | `AppRouter.shared.showAll(sectionTitle:)` → `BrowseSearchModel.openSection` | done |
| 1.12 | deferredLoad: first page loaded when the row becomes visible | HS 22-31 | rows in a plain `VStack` (an outer `LazyVStack` of heterogeneous rows mis-estimated the height and let the page scroll into empty space), row `.task(id:)` | partial: every row loads its first page when Home appears |
| 1.13 | 50 items loaded, 15 rendered, more rendered while scrolling | HS 1-4, 74-77 | `LazyHStack` renders lazily; next pages are loaded at the end of the row (`loadMore`) | done (also loads pages after the first 50, asked for the native app) |
| 1.14 | Skeleton cards while loading (fakecards) | HS 4, 144 | `BrowseSmallCardSkeleton` / `BrowseFullCardSkeleton` / `BrowseEpisodeCardSkeleton` | done |
| 1.15 | ErrorCard when the section is empty or failed | HS 147-149 | `BrowseErrorCard` (+ Retry button) | done |
| 1.16 | Card type: episode cards for RSS sections, settings.cards for media | HS 145, CA 12 | `row.kind == .episodes`, `@AppStorage(BrowseCardMode.storageKey)` | done |
| 1.17 | Chevron carousel buttons (desktop only, hidden on Android) | HS 38-62, 138-139 | native horizontal scroll | n.a. (touch scrolling, like Android) |
| 1.18 | dragScroll, scrollbar hidden | HS 142 | `ScrollView(.horizontal, showsIndicators: false)` | done |
| 1.19 | previewLength from card width (ResizeObserver), first / last card preview offsets | HS 79-95, 112-125 | lazy stacks, context menu previews | n.a. (layout mechanics of the web cards) |
| 1.20 | Section end gradient | HS 126-137 | — | n.a. (cosmetic overlay) |
| 1.21 | Pull to refresh | — | `.refreshable` (rows reload their first page, banner reloaded) | extra |

## 2. Banner (BN, FB)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 2.1 | Skeleton while loading (BannerSk) | BN 36-37 | `BrowseBannerSkeleton` | done |
| 2.2 | ErrorCard when the request failed | BN 44-46 | `BrowseErrorCard` with Retry | done |
| 2.3 | shuffleAndFilter: titles with a banner or a trailer (cover with hentaiBanner), first 20 shuffled, 10 kept | BN 8-30 | `BrowseBannerModel.shuffleAndFilter` | done |
| 2.4 | Height 70vh (80vh on wide screens) | BN 50-58 | fixed 540 pt | done |
| 2.5 | Banner image fallbacks: banner, YouTube maxres / hq thumbnails, cover, 404 image | FB 20-36 | `BrowseImage(BrowseMediaInfo.bannerURLs)` (dark placeholder instead of the 404 image) | done |
| 2.6 | Rotated cover for the hentai banner without banner | FB 32-35 | `BrowseBannerPage` → `BrowseRotatedCover` (no banner, no trailer, adult = hentai, hentaiBanner) | done |
| 2.7 | App icon in the top corner (mobile) | FB 96-104 | — | n.a. (the shell navigation bar shows the app chrome) |
| 2.8 | mediaCache subscription (list entry / favourite updates) | FB 40-50 | `BrowseMediaInfo.current` (MediaStore + list revision) | done |
| 2.9 | Auto-advance every 15 s, timer restarted on manual selection | FB 60-79 | `.task(id: model.index)` | done |
| 2.10 | Swipe left / right | FB 81-87 | paged `TabView` | done |
| 2.11 | Logo image (drop shadow) or title | FB 116-124 | `BrowseBannerInfo.titleView` | done |
| 2.12 | Details: format, "progress / N Episodes" while watching, N Episodes or N Minutes, cardAudio label, Rated 18+, season year | FB 125-156 | `BrowseBannerInfo.detailsLine` | done |
| 2.13 | Description (HTML stripped, 4 lines) | FB 157-163 | `BrowseText.plain`, 3 lines on phones | done |
| 2.14 | Genres | FB 164-172 | joined line | done |
| 2.15 | Watch Now / Continue Now / Rewatch Now → playMedia | FB 174-188 | `BrowseBannerButtons` → `BrowseActions.playMedia` | done |
| 2.16 | View Details | FB 189-195 | `BrowseActions.open` | done |
| 2.17 | Scoring when logged in (AniList media) | FB 196-198 | `BrowseListEditorButton` | done |
| 2.18 | Favourite heart (AniList account) | FB 199-224 | `BrowseFavouriteButton` | done |
| 2.19 | Progress badges (active one fills in 15 s, click selects) | FB 226-245 | `BrowseBannerIndicators` (fill computed from a `TimelineView`, no 15 s `withAnimation` in `onAppear`) | done |
| 2.20 | Radial gradient, fade-in animation | FB 251-378 | linear gradient, page transition | done (cosmetic difference) |

## 3. Media cards (CA, SC, FC, PC, AU)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 3.1 | Card dispatch: episode / full / small (card.type or settings.cards) | CA 1-46 | `BrowseMediaCard(style:)`, `BrowseEpisodeCard` | done |
| 3.2 | Click opens the details (fileEdit variant for torrents) | SC 25-28, FC 22-25 | `AppRouter.shared.open(media)` | done (fileEdit n.a.: no torrent file editing in the native app) |
| 3.3 | Preview on hover / focus (cardPreview setting), click when previews are off | SC 30-77 | long press: context menu with `BrowsePreviewCard` (menu without preview when cardPreview is off) | done |
| 3.4 | Focus / blur / outside click handling | SC 37-76 | context menu dismissal; hardware keyboard: cards are `.focusable()` and Return opens the details (`onKeyPress`) | n.a. (keyboard / pointer focus preview) |
| 3.5 | Airing line "Episode N in 1d 2h" (scheduleList), refreshed every minute | SC 79-89, 111-118 | `BrowseAiringLine` (`TimelineView` 30 s) + air time; "Episode a ~ b" ranges, "Episode N is Suspended" | done |
| 3.6 | AIRING badge when "out for", pulse animation | SC 108, 159-174 | `BrowseAiringBadge` with a pulsing ring (`phaseAnimator`, scoped to the ring) | done (pulse on the badge instead of the whole card) |
| 3.7 | Cover with cover color placeholder and 404 fallback | SC 121, FC 42 | `BrowseImage(coverURLs, placeholder: coverColor)` | done |
| 3.8 | AudioLabel on covers (cardAudio): sub episodes, dub / partial dub, progress, adult | AU 76-119 | `BrowseAudioLabel`: aired dub episode count (`AnimeScheduleService.loadedDubAiredCount`), dubEpisodes rules, partial label, sub count max(playable, dub) | done |
| 3.9 | context-type: relation type or "N likes" of recommendations | SC 126-135 | `typeLabel` (relation type) or `likes` (thumb up / down + "N likes", ratings from `MediaDetailsService.recommendationRatings`) | done |
| 3.10 | List status circle (statusColorMap colors) | SC 136-139 | `BrowseListStatusDot` + `BrowsePalette.status` | done |
| 3.11 | Title (title language / AniList userPreferred), 2 lines | SC 136-141 | `BrowseMediaInfo.title` | done |
| 3.12 | Year: seasonYear, TBA, Kitsu start year, current year when releasing, N/A | SC 142-148 | `BrowseMediaInfo.yearText` | partial: Kitsu fallback replaced by `startDate` year |
| 3.13 | Format label with icons | SC 149-152 | footer | done |
| 3.14 | FullCard: cover, title with status circle | FC 34-55 | `BrowseFullCard` | done |
| 3.15 | FullCard badges: format, "progress / max Episodes" or minutes, Rated 18+, season year / In Production / Not Released, rating %, reviews | FC 56-96 | `BrowseMediaChips` | partial: no Kitsu season fallback |
| 3.16 | FullCard airing line (scheduleList) | FC 97-105 | `BrowseAiringLine` | done |
| 3.17 | FullCard description and first 3 genres in the cover color | FC 107-120 | `BrowseFullCard.description / genres` | done |
| 3.18 | Hover scale | FC 155-158 | `BrowsePressableStyle` (press scale) | done |
| 3.19 | PreviewCard banner with image fallbacks | PC 50-53 | `BrowsePreviewCard` | done |
| 3.20 | PreviewCard muted trailer autoplay + mute button | PC 54-80 | trailer in the details sheet | n.a. (context menu previews are static, no web view) |
| 3.21 | PreviewCard play button (text by list entry, disabled for unreleased anime) | PC 22-42, 87-91 | menu item `BrowseMediaMenuItems` (+ the play label in the preview) | done |
| 3.22 | PreviewCard Scoring and Favourite | PC 92-104 | "List Editor" (sheet) and "Favourite / Unfavourite" menu items | done |
| 3.23 | PreviewCard badges and description | PC 106-158 | `BrowseMediaChips`, description | done |
| 3.24 | "View Details" and "Choose Extension" (force: extension picker) | — | menu items | extra |

## 4. Episode cards (EC, EPC)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 4.1 | Thumbnail rule: episode image hidden while the list progress is behind (spoilers), banner / cover fallback | EC 40, EPC 23 | `BrowseEpisodeCardState.thumbnailURLs` | done |
| 4.2 | Rotated cover for hentai titles without image | EC 166 | `BrowseEpisodeThumbnail` → `BrowseRotatedCover` (no episode image, no banner, Hentai genre) | done |
| 4.3 | Failed resolve icon (data.failed) | EC 167-171 | — | n.a. (feed entries come resolved from the services; file resolution is not in the native app) |
| 4.4 | Play icon, duration (× episode range for batches) | EC 172-184 | `BrowseEpisodeThumbnail` (`durationMinutes` × range of batch feed entries) | done |
| 4.5 | Progress bar (completed = full, live watch progress) | EC 185-194 | `BrowseProgressBar` + `AnimeProgressService.episodeProgress` | done |
| 4.6 | Completed episodes dimmed | EC 162, 216 | opacity 0.3 | done |
| 4.7 | Title with status circle | EC 197-203 | `BrowseEpisodeCardContent.titleRow` | done |
| 4.8 | Episode title (episode metadata, Kitsu fallback) | EC 204-214 | `EpisodeFeedItem.episodeTitle` (metadata resolved by the services) | done |
| 4.9 | "Episode N" / "Episodes a ~ b" / "Movie" / "Season N" / "Batch" | EC 218-234 | `BrowseEpisodeCardState.episodeLabel` (ranges from `EpisodeFeedItem.lastEpisode` / `AiredEpisode.airedLast`, "Season N" from `BrowseEpisodeCardData.releaseTitle`) | done |
| 4.10 | Audio text (Sub / Dub / Partial Dub, cardAudio) | EC 235-238, AU 123-126 | `BrowseEpisodeCardState.audioLabel`, only with `ServiceSettingsExtras.cardAudio` | done |
| 4.11 | since(date), refreshed every minute | EC 141-149, 239-247 | `BrowseEpisodeMetaLine` (`TimelineView` 60 s) | done |
| 4.12 | "Confidence: N%" of image search results | EC 248-256 | `secondaryText` | done |
| 4.13 | Click: prompt when earlier episodes are not watched ("You Haven't Watched Any Episodes Yet!" / "Your Current Progress Is At Episode N", "Continue Anyway?") | EC 47-53, EPC 199-213 | `.alert` with Continue Anyway? / View Details | done |
| 4.14 | Click plays the episode (play-anime → playAnime) | EC 12-14, 51 | `BrowseActions.play(media, episodeNumber:)` | done |
| 4.15 | Hover / long press: EpisodePreviewCard; right click: details | EC 54-63, 159 | context menu (preview + Play / Choose Extension / View Details) | done |
| 4.16 | EpisodePreviewCard: thumbnail, progress, duration | EPC 29-58 | `BrowseEpisodePreviewCard` | done |
| 4.17 | EpisodePreviewCard: trace.moe video preview | EPC 31-40 | — | n.a. (static context menu preview) |
| 4.18 | EpisodePreviewCard: title, episode title, label, audio, since | EPC 60-118 | `BrowseEpisodePreviewCard.header` | done |
| 4.19 | EpisodePreviewCard summary (episode summary, Kitsu synopsis, media description) | EPC 120-131 | `EpisodeFeedItem.summary` (ani.zip / Kitsu metadata, TMDB / TVmaze overview), media description fallback | done |
| 4.20 | EpisodePreviewCard year / format footer | EPC 132-144 | footer | done |

## 5. Error card and skeletons (ERR, SK)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 5.1 | "Ooops!" + "Looks like there's nothing here." | ERR 6-30 | `BrowseErrorCard(kind: .empty)` | done |
| 5.2 | "No results found." | ERR 13-15 | `.noResults` | done |
| 5.3 | "No Extensions Found" (extension errors) | ERR 16-17, 27-28 | — | n.a. (extension results are handled by the Extensions module) |
| 5.4 | Error messages / "Looks like something went wrong!" (+ catch) | ERR 18-63 | `.failed(message)` (+ Retry) | done |
| 5.5 | SmallCardSk, FullCardSk, EpisodeCardSk, BannerSk, EpisodeListSk | SK | `BrowseSmallCardSkeleton`, `BrowseFullCardSkeleton`, `BrowseEpisodeCardSkeleton`, `BrowseBannerSkeleton`, `BrowseEpisodeRowSkeleton` | done |
| 5.6 | ChangelogSk, ExtensionCardSk | SK | — | n.a. (other screens) |

## 6. Search page (SP, SB)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 6.1 | Loader: section load (see all) or createFallbackLoad with isSearch | SP 52-58 | `BrowseSearchModel.fetch` (`HomeSection.load(page:perPage:variables:)` / `HomeSectionsService.searchMedia`) | done |
| 6.2 | Input debounce 500 ms, results reset on change | SP 59-65 | `.task(id: model.runKey)` + 500 ms sleep | done |
| 6.3 | loadTillFull / infinite scroll (800 px threshold) | SP 67-111 | sentinel `onAppear` (re-created per page) → `loadMore` | done |
| 6.4 | ErrorCard after the results / empty / failed states | SP 159-161 | `BrowseErrorCard` (+ Retry) | done |
| 6.5 | Grid sizes for small / full / episode cards | SP 165-190 | adaptive `LazyVGrid` columns | done |
| 6.6 | Row markers for the previews | SP 24-47 | — | n.a. (web preview positioning) |
| 6.7 | onDestroy: RSS section search (disableSearch) reset when leaving the page | SP 114-118 | `SearchView.onDisappear` → `BrowseSearchModel.leavePage()` | done |
| 6.8 | Offline margin (Status bar) | SP 124 | — | n.a. (shell) |
| 6.9 | AppRouter pending search: section "see all" | — | `SearchView.consumePendingSearch` → `openSection` | done |
| 6.10 | AppRouter pending search: preset query (genre / tag chips; `onList` mapped to Show / Hide My Anime) | — | `apply(query:)` → `BrowseSearchFilters(query:)` | done |
| 6.11 | Source select Both / Anime / Western | SB 167-178 | `BrowseSourceMenu` (locked for sections) | done |
| 6.12 | Title input ("Any") | SB 179-198 | `BrowseSearchField` (+ clear button) | done |
| 6.13 | Genres / tags dropdown with include / exclude, headers Anime Genres / Western Genres / Tags | SB 27-48, 199-207 | `BrowseTagPicker` (tap: include → exclude → clear, searchable) | done |
| 6.14 | Hentai genre and adult tags only with adult = hentai | anime.js genreList / tagList | `AnimeCatalog.genres / tags` | done |
| 6.15 | Season select + year dropdown (next year → 1940) | SB 208-227 | `BrowseFilterSheet.seasonSection` | done |
| 6.16 | Format include / exclude | SB 228-236 | `formatSection` | done |
| 6.17 | Status include / exclude | SB 237-245 | `statusSection` | done |
| 6.18 | Sort (Trending, Popularity, Title, Score, Release Date + user sorts of list sections) | SB 246-276 | `BrowseFilterContext.sortOptions` | done |
| 6.19 | clearTags: user sort without AniList clears and locks genres / tags ("Cannot use with sort") | SB 132-142, 203 | `BrowseFilterSheet.tagsLocked` | done |
| 6.20 | Advanced search toggle (small screens) | SB 277-287 | filter sheet (`slider.horizontal.3` button with a count badge) | done |
| 6.21 | Hide My Anime (click) / Show My Anime (right click), 5 statuses, disabled when logged out or for list sections | SB 113-128, 289-298 | icon button + context menu, toggles in the sheet | done |
| 6.22 | Dubbed Audio (hideSubs) | SB 128-131, 299-307 | icon button / sheet toggle | done |
| 6.23 | Image Search (file, pasted image or image URL → traceAnime, toasts, results as episode cards) | SB 144-157, 308-317, anime.js 24-103 | `PhotosPicker` → `traceAnime(imageData:)`; long press "Paste Image or URL" → `traceFromPasteboard` (`traceAnime(imageURL:)`) | done |
| 6.24 | Reset Filters (enabled with filters / section, FilterX icon) | SB 63-80, 319-330 | `BrowseSearchModel.reset` | done |
| 6.25 | Filter badges in badgeKeys order, genre icons, exclusions in red, display names; section title badge only for user-list sections | SB 1-3, 332-352 | `BrowseFilterBadge.badges`, `BrowseFilterBadgesView`, `BrowseSearchModel.badges` (title gated on `context.userList`) | done |
| 6.26 | removeBadge (title leaves the section and resets user sorts; genre / tag edits hide the title; hide / show statuses) | SB 90-112 | `BrowseSearchModel.remove` | done |
| 6.27 | Small / large card mode (settings.cards), hidden for sections, also on Schedule | SB 158-161, 356-357, 371-372 | `BrowseCardModeButtons` + `@AppStorage` (Search and Schedule headers) | done (stored outside Core settings) |
| 6.28 | scheduleList hides season / status / sort / image search | SB 208, 237, 246, 312 | `BrowseFilterContext.isSchedule` | done |
| 6.29 | disableSearch locks every input (RSS sections) | SB 188-330 | `context.disableSearch` | done |
| 6.30 | lastSearched persistence | sections.js 12-23 | UserDefaults `tsumi.browse.lastSearched` (normal searches only) | done |
| 6.31 | fileEdit mode (torrent file editing) | SB 288, 312 | — | n.a. (no torrent files in the native app) |
| 6.32 | Invalid input styling | SB 381-387 | — | n.a. (no free inputs that can be invalid) |
| 6.33 | Adult toggle | — | adult content follows the global `adult` setting (services apply it to every query) | n.a. (no per-search adult switch in SearchBar.svelte) |

## 7. Schedule page (SCH)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 7.1 | lastSchedule persisted filters (default: anime, TV) | SCH 11-18 | UserDefaults `tsumi.browse.lastSchedule`, `BrowseSearchFilters.scheduleDefault` | done |
| 7.2 | fetchAllScheduleEntries: sub / dub schedule, hide / show my anime, AniList filters, dub rules, western pages, dedup, sort; suspended dubs and episode ranges | SCH 20-115, anime.js 848-878 | `HomeSectionsService.schedule(_:page:)`; `AiringEpisode.lastEpisode` / `delayedIndefinitely` | done |
| 7.3 | Title search (AniList `search` variable of the schedule ids) | SCH 41 | local title / synonym match | partial: filtered locally (ScheduleFilter has no text) |
| 7.4 | Excluded formats | SCH 41 | local exclusion (`formatsNot`) | done |
| 7.5 | Anime only on page 1, western pages after | SCH 87-96 | `BrowseScheduleModel.loadMore` | done |
| 7.6 | Search bar subset: source, title, genres / tags, format, hide / show my anime, dubbed audio, reset, card size | SB with scheduleList | `BrowseScheduleHeader` (+ `BrowseCardModeButtons`) + `BrowseFilterSheet(context: isSchedule)` | done |
| 7.7 | Cards with the airing countdown (scheduleList), "Suspended" for suspended dubs | SC 79-89, anime.js 847-850 | `BrowseMediaCard(airing:)`; suspended entries in a last "Suspended" group | done |
| 7.8 | Entries grouped by day with their time | — | `BrowseScheduleModel.days`, one `LazyVGrid` with pinned day headers | extra |
| 7.9 | Tap opens the details | SC 25 | `BrowseMediaCard` | done |
| 7.10 | Pull to refresh | — | `.refreshable` → `retry()` | extra |

## 8. Details (DM, DT)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 8.1 | Opened from the modal store, media taken from mediaCache (refreshed after list edits) | DM 28-44 | `MediaDetailView(media:)` → `BrowseDetailModel`; header, actions, episodes and bottom read `BrowseDetailModel.live` (MediaStore copy + list revision) | done |
| 8.2 | Close button (×), Escape | DM 191-196, 365-367 | close overlay → `AppRouter.closeDetails()` + `dismiss()`, `.keyboardShortcut(.cancelAction)` (Esc) | done |
| 8.3 | Scroll to top / focus when another title opens | DM 176-187 | `.id(media.id)` recreates the screen | done |
| 8.4 | Banner layer with fallbacks, fading after 100 px | DM 397-411, 892-918 | `BrowseDetailHeader` banner (scrolls with the content) | done (fade n.a.) |
| 8.5 | Cover with color and AudioLabel | DM 418-434 | `BrowseDetailHeader.cover` | done |
| 8.6 | Title (select-all) | DM 436-440 | `.textSelection(.enabled)` | done |
| 8.7 | Alternative titles | DT english / romaji / native | header line (english / romaji / native / synonyms) + details strip | done |
| 8.8 | Rating %, Format, Episodes (max or ?) or Length, Reviews | DM 441-494 | `BrowseDetailStats` | done |
| 8.9 | Play button (Watch / Continue / Rewatch Now), disabled when not released | DM 495-504, 198-212 | `BrowseDetailActions` → `playMedia` (+ long press: Choose Extension) | done |
| 8.10 | Scoring (logged in, AniList media) | DM 506-508 | `BrowseListEditorButton` | done |
| 8.11 | Favourite (AniList account) | DM 509-533 | `BrowseFavouriteButton`; every heart / menu item observes `BrowseFavouriteStore` | done |
| 8.12 | Trailer button + TrailerModal | DM 534 | `trailerButton` → `BrowseTrailerSheet` | done |
| 8.13 | Share AniList / TMDB / MyAnimeList (clipboard, right click opens) | DM 535-597 | `BrowseShareLinkButton` (Share to Clipboard, Share sheet, Open in Browser) | done |
| 8.14 | Following | DM 599 | `BrowseFollowingRow` (profiles loaded when a popover opens) | done |
| 8.15 | Details strip | DM 603 | `BrowseDetailInfoStrip` | done |
| 8.16 | Tags with rank (AniList), horizontal | DM 604-617 | `BrowseDetailChips` (tap → search the tag) | done |
| 8.17 | Genres with icons, horizontal | DM 618-635 | `BrowseDetailChips` (tap → search the genre) | done |
| 8.18 | Synopsis (marked + DOMPurify) | DM 236-321, 636-652 | `BrowseText.markdownBlocks` → `BrowseMarkdownBlocksView` (headings, lists, quotes, rules, tables) when the text has blocks, else `BrowseText.attributed`; Show More | done |
| 8.19 | Episodes title with Reverse (mobile) / order button (desktop) | DM 653-678, 847-866 | `BrowseDetailEpisodes.header` | done |
| 8.20 | Relations (no CHARACTER / non anime / MUSIC / filtered adult / missing ids, by season year) | DM 692-731 | `BrowseDetailBottom.relations` | done |
| 8.21 | Recommendations (adult filters, sorted by rating, likes label) | DM 732-771 | `recommendationsSection` sorted by `BrowseDetailModel.recommendationLikes` (`MediaDetailsService.recommendationRatings`), "N likes" on the cards | done |
| 8.22 | TMDB relations (collection) | DM 773-797 | same rows (`Media.relations` from TMDB) | done |
| 8.23 | TMDB recommendations | DM 798-818 | same row | done |
| 8.24 | TMDB enrichment (genres, tags, description, status, trailer, banner, studios, staff, characters, rating, external ids) | DM 92-160 | `MediaDetailsService.details`; content rating in the strip, studios / networks / providers, links | done |
| 8.25 | 'play-anime' events (episode cards, IPC) → handlePlay | DM 214-234 | `BrowseActions.play` called directly | done |
| 8.26 | Column height sync (desktop two columns) | DM 330-345, 822-866 | regular width ≥ 700 pt: details and episode list side by side, each in its own scroll view (`BrowseDetailScreen.wideLayout`) | done |
| 8.27 | Characters and staff rows | — | `BrowseCharacterRow`, `BrowseStaffRow` | extra |
| 8.28 | Next airing countdown | — | `BrowseNextAiringLine` | extra |
| 8.29 | Popularity and episode duration | — | details strip | extra |
| 8.30 | External links (AniList, MyAnimeList, TMDB, IMDb), studios, streaming providers | — | `BrowseExternalLinks` | extra |
| 8.31 | Details.svelte: Season (Kitsu fallback, "In Production") | DT 64-75 | `BrowseMediaInfo.seasonText` | partial: `startDate` year instead of Kitsu |
| 8.32 | Details.svelte: Status, Studio (TMDB network), Source, Country, Adult | DT 17-63 | `BrowseDetailInfoStrip.items` | done |
| 8.33 | Details.svelte: English / Romaji / Native | DT 25-27 | strip items | done |

## 9. Episode list (EL)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 9.1 | AniList episode list (load) | EL 91-208 | `MediaDetailsService.quickEpisodes` (ani.zip / Kitsu / schedule behind 10 s timeouts, shown at once) then `enrichEpisodes` (Jikan titles, filler / recap, one request per Jikan page, pages kept for the session); 30 s limit → error card with Retry | done |
| 9.2 | TMDB episodes (movie, every season with SxEy titles) | EL 210-258 | same service | done |
| 9.3 | Skeletons while loading (episode count, max 15, 1 when not released) | EL 315-319 | `BrowseEpisodeRowSkeleton` (max 6) | done |
| 9.4 | Incremental rendering (15 at a time on scroll) | EL 64-76, 276-299 | `LazyVStack` for the rows only (the rest of the details is a plain `VStack`) | done |
| 9.5 | Visibility: aired episodes plus the next one (every episode when finished), same dub date as the previous one | EL 329 | `BrowseDetailModel.displayedEpisodes` | done |
| 9.6 | Unreleased episodes: blurred / striped, not clickable | EL 330, 337-339, 444-452 | `BrowseDiagonalStripes` overlay, blur 0.6, 50 % saturation, taps ignored | done |
| 9.7 | Completed episodes (progress ≥ episode, zero episode offset) | EL 331, 337 | opacity + full progress bar | done |
| 9.8 | Next episode (target) border | EL 332, 337 | white border | done |
| 9.9 | Filler / Recap badge and border | EL 333, 349-353 | "Filler" / "Recap" badge + border (`EpisodeInfo.isFiller` / `isRecap` from Jikan) | done |
| 9.10 | Watch progress per episode (liveAnimeProgress) | EL 334, 365-372 | `AnimeProgressService.progress(mediaKey:)` | done |
| 9.11 | Duplicate titles hidden (matchPhrase with earlier episodes) | EL 335 | `BrowseDetailModel.duplicateTitleIds` (strict matchPhrase 0.1 = same title after `ServiceText.clean`) | done |
| 9.12 | "N. title" unless the number is in the title or single episode | EL 357-358 | `displayTitle` | done |
| 9.13 | Length "Xm" | EL 359-363 | title row | done |
| 9.14 | Summary without "(Source: …)", unreleased summary highlighted | EL 373-375, 455-457 | `BrowseText.episodeSummary` | done |
| 9.15 | Date: since(airdate), In Production, season year, month year, Released, Unknown | EL 403-419 | `BrowseEpisodeRow.dateText` | done |
| 9.16 | Dub / Sub airing rows (dubAiring, cardAudio) | EL 13-48, 376-402 | `AnimeScheduleService.dubEpisodeAirings` / `dubbedEpisode` → "Dub: …" / "Sub: …" labels in `BrowseEpisodeRow`; an earlier dub date moves the sub date | done |
| 9.17 | Click plays {number, season, localEpisode} | EL 337 | `BrowseActions.play(media, episode: episode.ref)` | done |
| 9.18 | Right click → extension picker (force) | EL 337 | long press (haptic) / accessibility action "Choose Extension" | done |
| 9.19 | Reverse order | DM 653-678 | `model.reversed` | done |
| 9.20 | Season picker for TMDB shows | — | `seasonPicker` | extra |
| 9.21 | Scroll to top on media change | EL 264 | view recreated per media | done |

## 10. Toggle lists, following, list editor, trailer (TL, FO, SCO, TR, ST)

| # | Svelte feature | Source | Swift | Status |
|---|---|---|---|---|
| 10.1 | ToggleTitle (title between lines) | TL ToggleTitle | `BrowseSectionDivider` | done |
| 10.2 | ToggleList horizontal row (toggleList off, the Android default) | TL 79-90 | `BrowseToggleList` | done |
| 10.3 | ToggleList wrapped grid with Show More / Show Less (toggleList on) + ToggleFooter | TL 23-90, ToggleFooter | `BrowseExpandableList` (Relations, Recommendations): `AppSettings.values.toggleList` wraps the cards, first row shown, title / round button toggle | done |
| 10.4 | Following only with an AniList viewer | FO Following 9 | `BrowseDetailModel.loadFollowing` | done |
| 10.5 | Following: viewer excluded, deduplicated by name | FO Following 13 | `AniListService.following` | done |
| 10.6 | 11 overlapping avatars then "+N" | FO Following 14-28 | `BrowseFollowingRow` | done |
| 10.7 | User avatar or initials | FO User 16-22, 52-58 | `BrowseUserAvatar` | done |
| 10.8 | User popover (hover / focus) | FO User 24-50, 62-133 | tap shows `BrowseUserCard` | done |
| 10.9 | Popover: status name or "Not on List", Progress, Score | FO User 93-103 | `BrowseUserCard` chips | done |
| 10.10 | Popover: share / open the profile URL | FO User 72-75 | menu (Share to Clipboard, Open in Browser) | done |
| 10.11 | Popover: banner, profile color, "Following You", join date, BLOCKED, moderator roles, donator badge, statistics | FO User 59-131 | `BrowseUserCard(profile:)` with `MediaDetailsService.followingProfiles` (user fields of the anilist.js following query, requested on first popover) | done |
| 10.12 | Scoring button (Bookmark / PencilLine), disabled when logged out | SCO 207-215 | `BrowseListEditorButton` | done |
| 10.13 | Status select ("Not on List" hidden once a status is chosen) | SCO 225-237 | `BrowseListEditor.statusSection` | done |
| 10.14 | Episode input capped to the episode count (12 for releasing titles without count), "/ total" | SCO 176-191, 238-247 | `episodeSection` (field + stepper) | done |
| 10.15 | Score slider 0-10 with names (Masterpiece … Not Rated) | SCO 30-42, 248-259 | `scoreSection` | done |
| 10.16 | Delete (when on the list) / Save ("Not on List" deletes), no-change warning, toasts, profile sync | SCO 44-174, 261-266 | `MediaListService.save / delete` | done |
| 10.17 | Rewatch count | — | `rewatchSection` (passed as `repeatCount`) | extra |
| 10.18 | Closes on outside click | SCO 193-205 | sheet | done |
| 10.19 | Trailer button shown only when a trailer is found (AniList / Jikan, TMDB) | TR 40-41, 52-56 | `MediaDetailsService.trailer(for:)` | done |
| 10.20 | Trailer header (title, close) | TR 45-48 | `BrowseTrailerSheet` | done |
| 10.21 | youtube-nocookie embed (autoplay, cc_lang_pref=ja), thumbnail while loading | TR 49-69 | `BrowseYouTubePlayer` (WKWebView, inline autoplay, app referrer) over the thumbnail | done |
| 10.22 | Reset when the title changes | TR 17-26 | `.id(media.id)` | done |
| 10.23 | Offline / AniList outage status bar | ST | — | n.a. (app-wide bar, belongs to the shell; `ServiceNetworkMonitor.isOnline` is available) |

## Counts

| Status | Rows |
|---|---|
| done | 178 |
| partial | 5 |
| n.a. | 18 |
| extra | 10 |
| **total** | **211** |

## Wiring notes for the shell

- Names used by the shell: `HomeView()`, `SearchView()`, `ScheduleView()`, `MediaDetailView(media:)`. None of them adds a
  `NavigationStack`; they set `.navigationTitle` (inline) only. `MediaDetailView` has its own close button (calls
  `AppRouter.shared.closeDetails()` and `dismiss()`).
- Playback starts with `PlaybackRequestCoordinator.shared.play(...)`. Playing from the details sheet needs the
  coordinator's sheets (and the player cover) to be presentable while the details sheet is up; the browse views do not
  attach `.playbackRequestPresenter()` / `.playerPresentationHost()` themselves (the shell layers of
  `UI/Shell/ShellPresenters.swift` present them over the details sheet).
- The details sheet presents its own sheets (list editor, trailer); genre / tag chips call `AppRouter.shared.search(_:)`,
  which closes the details and switches to the Search tab.
