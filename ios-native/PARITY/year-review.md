# Parity: Year in Review (Svelte → SwiftUI)

Svelte sources: `common/modules/yearreview/stats.js` (pure statistics, node tests in `stats.test.mjs`),
`common/modules/yearreview/yearreview.js` (AniList data, cache, local history), `common/modules/yearreview/shareImage.js`
(summary PNG), `common/routes/yearreview/YearReview.svelte` (+ `components/ReviewContent.svelte`, `components/MonthChart.svelte`),
`YearReviewBanner.svelte`, `YearReviewProfileButton.svelte`, `electron/src/main/yearReview.js` (save / copy the PNG).

Swift files:

| File | Types |
|---|---|
| `Services/YearReviewStats.swift` | `YearReviewCalc` (port of stats.js), `YearReviewActivity`, `YearReviewMedia`, `YearReviewEntry`, `YearReviewStats`, `YearReviewLocalStats` and the ranked / day / streak value types |
| `Services/YearReviewService.swift` | `YearReviewAccount`, `YearReviewAPI` (queries, transport, parsing), `YearReviewPacer`, `YearReviewEntriesStore`, `YearReviewLoader`, `YearReviewLocal`, `YearReviewModel` |
| `UI/YearReview/YearReviewView.swift` | `YearReviewView` (full-screen cover), `YearReviewStyle`, `YearReviewNotice`, `YearReviewLoadingView` |
| `UI/YearReview/YearReviewSections.swift` | `YearReviewSections`, `YearReviewPanel`, `YearReviewHero`, `YearReviewStatGrid`, `YearReviewCoverTile`, `YearReviewMonthChart`, `YearReviewHighlights`, `YearReviewLocalSection` |
| `UI/YearReview/YearReviewShareCard.swift` | `YearReviewShareCard`, `YearReviewShareImages`, `YearReviewShareRenderer` |
| `UI/YearReview/YearReviewEntryPoints.swift` | `YearReviewHomeBanner`, `YearReviewProfileButton` |

Hooks in shared files: `UI/Browse/HomeView.swift` (`YearReviewHomeBanner()` under the hero banner), `UI/Shell/ProfilesView.swift`
(`YearReviewProfileButton()` under the current profile), `Info.plist` (`NSPhotoLibraryAddUsageDescription`, needed by the
"Save Image" action of the share sheet).

| # | Feature (Svelte) | Swift | Status |
|---|---|---|---|
| 1 | Episode counting from ListActivity ("watched episode a - b", "completed" adds the episodes left, rewatch cycle, overlaps counted once) (`computeYearStats`) | `YearReviewCalc.compute` | Done (same rules, same tie-breaks) |
| 2 | Entries completed in the year without a "completed" activity become one (`timeline`) | `YearReviewCalc.timeline` | Done |
| 3 | Progress before the year for completions without earlier progress (`mediaNeedingPrior`, `priorFromActivities`, PRIOR_QUERY) | `mediaNeedingPrior`, `priorFromActivities`, `YearReviewAPI.fetchPrior` | Done |
| 4 | Stats: episodes, hours, titles, started / completed / dropped, average score + top rated, top 5 anime, top genres, top studios, episodes per month, biggest binge day, active days, longest streak, first / last anime | `YearReviewStats` | Done |
| 5 | Main studios from `studios { edges { isMain node { name isAnimationStudio } } }` (`isMain: true` is ignored inside MediaListCollection) | `YearReviewAPI.media` | Done |
| 6 | Activities paged with `createdAt_greater` / `createdAt_lesser` (local-time year bounds), sort ID | `YearReviewAPI.fetchActivities` | Done |
| 7 | Rate limits: 429 waits Retry-After (+1 s) with a visible countdown, 5xx / network back off, X-RateLimit-Remaining ≤ 2 waits for the reset | `YearReviewAPI.request` | Done. PC requests also go through the app-wide AniList limiter; iOS spaces its own requests (`YearReviewPacer`, 0.7 s) because AniListService's limiter is private |
| 8 | Cache per user and year (IndexedDB `tsumi-year-review`), past years kept once fetched after the year ended, current year refreshed incrementally after 3 h (2-day overlap), Refresh = full re-fetch, stale data shown when a refresh fails | `YearReviewLoader` (DiskCache) | Done |
| 9 | List entries cached 6 h, one shared request for the picker and the review | `YearReviewEntriesStore` | Done |
| 10 | Year picker: current year + years of the list entries and of the local history | `YearReviewCalc.availableYears`, toolbar `Menu` | Done |
| 11 | Not AniList: explanation, MyAnimeList "not supported yet", Log in with AniList (opens Profiles) | `YearReviewNotice` | Done |
| 12 | Local history: TMDB shows / movies (`animeEpisodeProgress` records with a `tmdb-` id), titles / episodes ≥ 80 % / hours, top 5 with posters | `YearReviewLocal`, `YearReviewLocalSection` | Done. PC ids are `tmdb-<id>` (titles from the media cache); iOS keys are `tmdb-<tv|movie>-<id>` (MediaStore, then TMDB) |
| 13 | Summary image 1080 x 1350 (hero banner, big numbers, top 5 covers, genres / studio / binge day, footer) | `YearReviewShareCard` + `ImageRenderer` (360 x 450 pt, scale 3) | Done |
| 14 | PC: save (main-process save dialog) and copy to the clipboard | iOS: `ShareLink` (Save Image, Copy, apps) | Different (platform share UI) |
| 15 | Home banner in December (this year, "so far") and January (last year), AniList only, dismissible until next year (`localStorage.yearReviewBannerDismissed`) | `YearReviewHomeBanner` (`@AppStorage("tsumi.yearReview.bannerDismissed")`) | Done |
| 16 | Profiles modal button (current profile, AniList or MyAnimeList) | `YearReviewProfileButton` | Done |
| 17 | Overlay closes with Escape / mouse back button | Close button, swipe-down is not available on full-screen covers | n.a. (no keyboard / mouse back on iOS) |
