# Parity: spoiler protection

Settings > Interface > Spoiler Protection, adapted from the "Spoiler Control" of Shiru 6.6.0. Off by default; off
looks exactly like before (episode cards of the feeds keep their old rule: no episode image for the titles you watch,
rewatch, paused or plan before you reach the episode).

Rules: `common/modules/spoilers.js` (pure, tested by `common/modules/spoilers.test.mjs`) and
`ios-native/Tsumi/Core/SpoilerProtection.swift` (same functions, defaults and texts). Change both together.

- Settings: `spoilers` (`off` | `minimal` | `moderate` | `strict` | `hermit`, default `off`) and `spoilerStatus`
  (list statuses as AniList values, `NOTONLIST` for titles not on the list; default `["CURRENT", "REPEATING"]`;
  Completed is not offered: nothing is left to spoil). Same keys on both apps (`util.js` `defaults`,
  `Settings.swift` `SettingsValues`).
- A title is protected when the level is not off and its list status is selected. Episode content is hidden only
  for episodes after the list progress (episode number counted like the progress: +1 when the series has an
  episode 0). Each level includes the levels before it:

| Level | Hides (protected titles) |
|---|---|
| Minimal | thumbnails of unwatched episodes (blurred in the details episode list, banner / cover on the episode cards and in the iPhone player episode list), episode preview clips *(Windows)* |
| Moderate | + descriptions of unwatched episodes, review count, AniList tags marked `isMediaSpoiler` |
| Strict | + titles of unwatched episodes ("Episode N" in the lists, "Hidden to avoid spoilers" on the cards, no title in Downloads), synopsis, average rating, tags marked `isGeneralSpoiler` |
| Hermit | + durations of unwatched episodes, length of movies / single episodes ("24 Minutes", "Length", "Duration") |

Hidden text shows "Hidden to avoid spoilers" (italic, muted). Like Shiru, nothing can be revealed in place: change the
setting to see it.

| Where | Svelte | Swift |
|---|---|---|
| Setting | `routes/settings/components/SpoilerSettings.svelte` (in `InterfaceTab.svelte`) | `UI/Shell/ShellSpoilerSettingsView.swift` (in `ShellInterfaceSettingsView`) |
| Details episode list | `modals/details/components/EpisodeList.svelte` (`hidesEpisode`, `.img-spoiler`) | `UI/Browse/MediaDetailEpisodes.swift` (`EpisodeSpoilers`) |
| Episode cards of the feeds | `components/cards/EpisodeCard.svelte` (`hidesEpisodeThumbnail`) | `UI/Browse/BrowseEpisodeCards.swift` `BrowseEpisodeCardState` |
| Episode preview card | `components/cards/EpisodePreviewCard.svelte` | `BrowseEpisodePreviewCard` |
| Full / preview cards (Continue Watching and every section) | `components/cards/FullCard.svelte`, `PreviewCard.svelte` | `UI/Browse/BrowseCards.swift` (`BrowseFullCard`, `BrowseMediaChips`, `BrowsePreviewCard`), `BrowseMediaInfo.episodesText(showDuration:)` |
| Home banner | `components/banner/FullBanner.svelte` | `UI/Browse/HomeBanner.swift` `BrowseBannerInfo` |
| Details header, tags, synopsis | `modals/details/DetailsModal.svelte` | `UI/Browse/MediaDetailHeader.swift` (`BrowseDetailStats`, `BrowseDetailInfoStrip`, `BrowseDetailChips`, `BrowseDetailSynopsis`) |
| Tag spoiler flags | `modules/anilist.js` `queryObjects` `tags { isGeneralSpoiler, isMediaSpoiler }` | `AniListService.baseMediaFields`, `MediaExtras.generalSpoilerTags` / `mediaSpoilerTags` |
| Downloads | `routes/downloads/DownloadsPage.svelte` `episodeText` | `Downloads/DownloadsView.swift` `episodeLine` |
| Player episode list | — (the Windows player lists files, with the series banner and cover only) | `Player/PlayerEpisodeListSheet.swift` (not the episode playing) |

Checked, nothing to hide: notifications (both apps show the series cover / banner and "Episode N"), the player's
now playing title (the episode being watched), Watch Together "Up next" (title and episode number), media session /
Now Playing artwork (series cover), widgets (series cover).
