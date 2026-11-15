<div align="center">
  <img src="../docs/icon.png" alt="Tsumi" width="96">
  <h1>Tsumi</h1>
  <p>Watch your anime and shows, alone or with friends using Watch Together.</p>
  <p>
    <a href="https://github.com/MXFia19/Tsumi/releases/latest"><b>Latest release</b></a> ·
    <a href="https://mxfia19.github.io/Tsumi/"><b>Download page</b></a>
  </p>
</div>

Tsumi is a streaming app for anime and shows that plays the streams found by the extensions you add, and keeps your
lists in sync with AniList or MyAnimeList. This repository is a fork of Tsumi with a Windows app and a native iPhone
and iPad app.

## Features

Two apps with the same features: a **Windows app** (Electron) and a **native iPhone / iPad app** (SwiftUI, iOS 17+).
A feature marked *Windows* or *iPhone* exists on that app only.

### Watching

- **Extensions as sources**: Sora modules and Stremio addons; Stremio addon catalogs get their own page
- **Anime, shows and movies**: anime from AniList, Western shows and movies from TMDB
- **Server choice** during playback, with dub / sub preference (prefer dubs, preferred audio language)
- **Offline downloads**: download an episode from the episode list, the details page ("Download next episodes") or
  the player; a Downloads page with pause, resume, retry and storage used; downloaded episodes play without network
  with their subtitles. Direct files and HLS streams (quality setting); if a server is dead, the next server of the
  episode is used. List updates made offline are sent once back online
- **Chromecast** *(Windows)* and **AirPlay** *(iPhone)*
- **Picture in Picture** and a **miniplayer**

### Player

- **Subtitles**: ASS / SSA styles and fonts, preferred subtitle language, delay adjustment in 0.5 s steps
- **Online subtitles**: search subtitles for the episode (anime included) when the source has none or not in your
  language, or add them automatically
- **Skip intro / outro** (automatic option) and chapters
- **Autoplay the next episode**, auto-complete an episode on your list past a threshold
- Playback speed, audio tracks, seek duration, keyboard shortcuts and seek bar thumbnails *(Windows)*,
  video debanding *(Windows)*, external player *(Windows)*

### Tracking

- **AniList and MyAnimeList** accounts, several profiles, list and progress sync
- **Resume on another device**: start an episode on Windows and continue it on iPhone at the same second (the
  position is kept in the note of the AniList entry, or the comment on MyAnimeList)
- **Trakt**: scrobbling of shows and movies (anime optional) and resuming from Trakt
- **Year in Review**: episodes and hours watched, top anime, genres and studios, episodes per month, biggest binge
  day, with an image to share
- **Spoiler protection** (off by default): hides what comes after your progress for the list statuses you choose,
  from episode thumbnails (Minimal) to descriptions and spoiler tags (Moderate), titles, synopsis and rating (Strict)
  and durations (Hermit)

### Discover

- **Home** with customizable sections (anime and Western TMDB sections, order, hero banner), **search**
- **Airing schedule** and **notifications** for new episodes, AniList notifications, sub / dub release announcements

### Watch Together

Peer-to-peer lobbies between Windows and iPhone, joined with a code or an invite link.

- Synced playback with a **host**, sync check, a countdown before starting, and who paused or seeked
- **Chat** in the lobby and in the player, reactions, **pause requests**
- **Voice chat**: mute, push-to-talk, a volume per member, the video gets quieter while someone speaks
- **Shared queue** ("Up next"): members add episodes, the host orders it, it plays on its own at the end of an
  episode
- See **who watches what**, "Watch on my own" while staying in the chat, **join the playback in progress**, the
  host can invite anyone not watching

### Discord

- **Rich Presence** with the title, episode and cover, also when the Discord app is closed (Discord account linked
  in the settings)
- Buttons: the title on AniList (or TMDB), then MyAnimeList or the download page, or **Join Watch Together** in a
  lobby
- **Adult content** hidden from the status by default (generic "Watching something", or no activity)

### iPhone

- **Home Screen and Lock Screen widgets**: Continue Watching, Next Episode countdown
- **Lock Screen countdown** to the next episode (Live Activity, Dynamic Island)
- Background refresh for new episode notifications

### App

- **Updates**: the Windows app updates itself; the iPhone app shows when a new version is out (the Feather source
  updates too)
- Interface scale, accent colour, title language, card styles, custom CSS variables *(Windows)*
- Settings import / export, DNS over HTTPS *(Windows)*

## Download

| Platform | Get it |
| --- | --- |
| Windows 10 / 11 (64-bit) | `win-Tsumi-vX.Y.Z-installer.exe` from the [latest release](https://github.com/MXFia19/Tsumi/releases/latest) |
| iPhone / iPad (iOS 17+) | the Feather source below, or `Tsumi.ipa` from the [latest release](https://github.com/MXFia19/Tsumi/releases/latest/download/Tsumi.ipa) |

The [download page](https://mxfia19.github.io/Tsumi/) always links the files of the latest release.

The Windows installer is not code-signed: if SmartScreen warns about it, click **More info**, then **Run anyway**.

### Installing on iPhone

The app is not on the App Store: the `.ipa` is unsigned and is signed on install by a sideloading app.

**Feather (recommended).** In Feather, open **Sources**, tap **+** and add:

```
https://mxfia19.github.io/Tsumi/source.json
```

(or open the [download page](https://mxfia19.github.io/Tsumi/) on the iPhone and tap **Add to Feather**), then install
Tsumi from the source. New versions show up in the same source. AltStore and SideStore can use the same source URL.

**Sideloadly.** Download `Tsumi.ipa` on your computer, open [Sideloadly](https://sideloadly.io/), connect the iPhone,
drop the `.ipa` and sign in with your Apple ID. With a free Apple ID the app must be signed again every 7 days.

## Build from source

The Discord Social SDK (used for Discord presence) is proprietary and is **not** in this repository. CI downloads it
from an encrypted release asset. Without it:

- the **Windows** app builds and runs; Discord presence then goes through the Discord app (local RPC);
- the **iOS** app does not build: get the Discord Social SDK 1.10.19337 from the
  [Discord Developer Portal](https://discord.com/developers/) and copy `discord_partner_sdk.xcframework` to
  `ios-native/Vendor/` and `cdiscord.h` to `ios-native/Vendor/CDiscord/`.

Trakt sync needs your own Trakt API application: set its Client ID as `TRAKT_CLIENT_ID` in the environment of the
build (optional, Trakt is unavailable without it). No client secret is used: both apps sign in with PKCE. Register
`https://mxfia19.github.io/Tsumi/trakt/` as the redirect URI of the Trakt app: this page (`docs/trakt/`) hands the
sign-in back to the app through `tsumi://trakt/callback`.

### Windows app

Requirements: Node.js 22, pnpm 10, Git.

```bash
git clone https://github.com/MXFia19/Tsumi.git
cd Tsumi
pnpm install
pnpm run dev            # development: webpack + Electron
```

To build the installer (`electron/dist/`), as [`main.yml`](workflows/main.yml) does:

```bash
# Native shutdown handler (prebuilt, no Visual Studio needed)
dest=$(ls -d node_modules/.pnpm/@paymoapp+electron-shutdown-handler@*/node_modules/@paymoapp/electron-shutdown-handler)
mkdir -p "$dest/build/Release" && cp electron/prebuilt/PaymoWinShutdownHandler.node "$dest/build/Release/"
# Electron with extra codecs (HEVC, AC3...): electron-v39.2.7-win32-x64.zip from the electron-codecs-39.2.7 release
gh release download electron-codecs-39.2.7 --repo MXFia19/Tsumi --pattern "electron-v39.2.7-win32-x64.zip" --dir electron-dist
cd electron
NODE_ENV=production pnpm run web:build
pnpm exec electron-builder --win nsis --x64 --publish never --config.npmRebuild=false --config.electronDist=../electron-dist
```

### iPhone app

Requirements: a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `ios-native/project.yml`.

```bash
cd ios-native
# Discord Social SDK in Vendor/ (see above), then:
xcodegen generate
open Tsumi.xcodeproj    # run it with your own signing team
```

An unsigned `.ipa` is built like [`ios-native.yml`](workflows/ios-native.yml) does: `xcodebuild archive` with
`CODE_SIGNING_ALLOWED=NO`, then the `.app` zipped in a `Payload/` folder.

## Releases

Bump the version in `electron/package.json` and `ios-native/project.yml`, push, then push a tag with the same version
(`git tag v1.2.3 && git push origin v1.2.3`). [`release.yml`](workflows/release.yml) builds both apps, publishes the
GitHub release (installer, `latest.yml` and `.blockmap` for the Windows updater, `Tsumi.ipa`) and adds the version to
the Feather source (`docs/source.json`). The download page and the source are served by GitHub Pages from `docs/`.

## Credits

- [Tsumi](https://github.com/50n50) by 50n50: the original Tsumi, with Sora extensions
- [Shiru](https://github.com/RockinChaos/Shiru) by RockinChaos, which Tsumi is built on
- [Miru / Hayase](https://hayase.watch/) by ThaUnknown, the project at the origin of Shiru
- [TheUnknownEngima/Tsumi](https://github.com/TheUnknownEngima/Tsumi), the fork this repository comes from

## Trakt

Trakt sync (scrobbling and resuming across devices) uses the [Trakt API](https://trakt.tv).
Tsumi uses Trakt but is not endorsed or certified by Trakt.

## License

[GPL-3.0-or-later](../LICENSE).

Tsumi does not host any content and is not affiliated with the providers of the streams that extensions find.
