import SwiftUI

// Settings > Discord: "Rich Presence Settings" of InterfaceTab.svelte (enableRPC, rpcSecondButton) plus the
// Discord account the presence goes through on iOS (Discord Social SDK, Discord/DiscordPresence.swift).

@MainActor
struct ShellDiscordSettingsView: View {
  var body: some View {
    Form {
      ShellRichPresenceSettingsSection()
      ShellDiscordAccountSection()
    }
    .navigationTitle("Discord")
  }
}

/// "Rich Presence Settings" group.
@MainActor
struct ShellRichPresenceSettingsSection: View {
  var body: some View {
    _ = AppSettings.shared.values
    return Section {
      ShellSettingPicker(
        title: "Discord Rich Presence",
        description: "Enables the use of Discord rich presence to display app activity.\nFull enables complete rich presence support showing anime details, limited reduces what is seen not showing the currently played anime and episode, disabled completely disables rich presence.",
        options: [ShellOption("full", "Full"), ShellOption("limited", "Limited"), ShellOption("disabled", "Disabled")],
        selection: ShellBind.value(\.enableRPC)
      )
      ShellSettingPicker(
        title: "Second Discord Button",
        description: "One button opens the title on AniList (or TMDB for shows and movies). During Watch Together, the other one is always \"Join Watch Together\".\nOutside Watch Together, choose what the second button opens.",
        options: [ShellOption("mal", "MyAnimeList"), ShellOption("download", "Download Tsumi")],
        selection: ShellBind.value(\.rpcSecondButton)
      )
      ShellSettingPicker(
        title: "Adult Content on Discord",
        description: "What your Discord status shows while you watch adult content (hentai).\nHide the title shows \"Watching something\" without the title, cover or links, hide activity shows nothing, show normally shows it like anything else.",
        options: [ShellOption("title", "Hide the title"), ShellOption("hidden", "Hide activity"), ShellOption("off", "Show normally")],
        selection: ShellBind.value(\.rpcHideAdult)
      )
    } header: {
      Text("Rich Presence Settings")
    }
  }
}

/// Discord account: status, Link / Cancel / Reconnect / Unlink.
@MainActor
struct ShellDiscordAccountSection: View {
  var body: some View {
    let discord = DiscordPresence.shared
    let account = discord.account
    return Section {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Discord Account")
            .font(.body.weight(.semibold))
          Text(account.label)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
        Spacer(minLength: 8)
        controls(account, discord: discord)
      }
      .padding(.vertical, 2)
      if let error = discord.lastError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Account")
    } footer: {
      Text("On iOS the rich presence is set through your Discord account: link it once (in the Discord app, or in a web sheet when it is not installed), Tsumi then reconnects by itself at launch. Friends see it on Discord while Tsumi is open.")
    }
  }

  @ViewBuilder
  private func controls(_ account: DiscordPresence.Account, discord: DiscordPresence) -> some View {
    switch account {
    case .notLinked:
      Button("Link") { discord.link() }
        .buttonStyle(.bordered)
    case .linking:
      HStack(spacing: 10) {
        ProgressView()
        Button("Cancel") { discord.cancelLinking() }
          .buttonStyle(.borderless)
      }
    case .connecting:
      HStack(spacing: 10) {
        ProgressView()
        Button("Unlink", role: .destructive) { discord.unlink() }
          .buttonStyle(.borderless)
      }
    case .connected:
      Button("Unlink", role: .destructive) { discord.unlink() }
        .buttonStyle(.bordered)
    case .disconnected:
      HStack(spacing: 10) {
        Button("Reconnect") { discord.reconnect() }
          .buttonStyle(.bordered)
        Button("Unlink", role: .destructive) { discord.unlink() }
          .buttonStyle(.borderless)
      }
    }
  }
}
