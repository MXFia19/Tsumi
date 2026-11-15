import SwiftUI
import UIKit

// Settings > Player > "Sync Settings" (common/routes/settings/components/SyncSettings.svelte): cross-device resume
// through the note of the list entry (PlaybackSyncService) and the Trakt account (TraktService).

/// "Sync playback position across devices".
@MainActor
struct ShellSyncSettingsSection: View {
  var body: some View {
    _ = AppSettings.shared.values
    return Section {
      ShellSettingToggle(
        title: "Sync playback position across devices",
        description: "Keeps the position of the episode you are watching in the note of its AniList entry (the comments on MyAnimeList), so you can stop on one device and resume at the same second on another one.\nTsumi only adds, updates and removes its own \"[Tsumi]\" line: the rest of your note is never changed. The line is removed once the episode is completed. Only for titles on your list.",
        isOn: ShellBind.value(\.syncPlaybackPosition)
      )
    } header: {
      Text("Sync Settings")
    }
  }
}

/// Trakt account (sign-in with PKCE in an ASWebAuthenticationSession) and scrobbling switches.
@MainActor
struct ShellTraktSettingsSection: View {
  var body: some View {
    let trakt = TraktService.shared
    _ = AppSettings.shared.values
    return Section {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Trakt")
            .font(.body.weight(.semibold))
          Text(statusText(trakt))
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        controls(trakt)
      }
      .padding(.vertical, 2)
      if let error = trakt.lastError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if trakt.isConnected {
        ShellSettingToggle(
          title: "Scrobble to Trakt",
          description: "Tells Trakt what you are watching (shows and movies): it shows \"watching now\" on your profile, marks them watched past 80%, and saves your progress when you pause or leave the player.",
          isOn: ShellBind.value(\.traktScrobble)
        )
        ShellSettingToggle(
          title: "Scrobble Anime to Trakt",
          description: "Also scrobbles anime, matched to their Trakt show and episode through the TVDB / TMDB mappings of ani.zip. Some anime have no mapping or a different episode numbering and are skipped.",
          isOn: ShellBind.value(\.traktScrobbleAnime)
        )
        .disabled(!AppSettings.shared.values.traktScrobble)
      }
    } header: {
      Text("Trakt")
    } footer: {
      // The notice is required by the Trakt API Use Policy.
      Text("Connect your Trakt account to scrobble the shows and movies you watch, and to resume them where you left off on another device.\nTsumi uses Trakt but is not endorsed or certified by Trakt.")
    }
  }

  private func statusText(_ trakt: TraktService) -> String {
    switch trakt.state {
    case .unavailable:
      return "Trakt is not available in this build."
    case .disconnected:
      return "Not connected"
    case .linking:
      return "Waiting for Trakt…"
    case .connected:
      return trakt.userName.isEmpty ? "Connected" : "Connected as \(trakt.userName)"
    }
  }

  @ViewBuilder
  private func controls(_ trakt: TraktService) -> some View {
    switch trakt.state {
    case .unavailable:
      EmptyView()
    case .disconnected:
      Button("Connect") { trakt.link() }
        .buttonStyle(.bordered)
    case .linking:
      HStack(spacing: 10) {
        ProgressView()
        Button("Cancel") { trakt.cancelLink() }
          .buttonStyle(.borderless)
      }
    case .connected:
      Button("Disconnect", role: .destructive) { trakt.unlink() }
        .buttonStyle(.bordered)
    }
  }
}
