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

- **Windows app** (Electron) and **native iPhone / iPad app** (SwiftUI, iOS 17+)
- **Extensions**: Sora modules and Stremio addons as sources, switch servers during playback
- **AniList and MyAnimeList**: browse, search, airing schedule, lists and progress sync; **Trakt** sync
- **Watch Together**: synced playback with friends, shared queue and voice chat, invite links
- **Discord Rich Presence** (on Windows it also works with the Discord app closed)
- **Downloads** to watch offline
- **Chromecast** and **online subtitles**
- **Home Screen widgets** on iPhone
- **Updates**: the Windows app updates itself; the iPhone app tells you when a new version is out

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

Trakt sync needs your own Trakt API application: set `TRAKT_CLIENT_ID` and `TRAKT_CLIENT_SECRET` in the environment of
the build (optional, Trakt is unavailable without them).

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

## License

[GPL-3.0-or-later](../LICENSE).

Tsumi does not host any content and is not affiliated with the providers of the streams that extensions find.
