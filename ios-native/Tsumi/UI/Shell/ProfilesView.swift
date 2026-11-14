import SwiftUI

// Profiles modal (common/components/Profiles.svelte): current profile, other profiles (switch, sync list
// entries, authenticate, logout), AniList / MyAnimeList login, "Add Profile" (at most 5 other profiles),
// "Authenticate" for an expired MyAnimeList session and "Sign Out".

@MainActor
struct ProfilesView: View {
  /// modal.open(modal.PROFILE, true): the login buttons are shown even with a current profile.
  @State private var addingProfile = false

  var body: some View {
    let service = ProfilesService.shared
    return NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          ShellCurrentProfileHeader()
          ShellOtherProfilesList()
          ShellProfileActions(addingProfile: $addingProfile)
        }
        .padding(20)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
      }
      .background(Color.black)
      .disabled(service.isLoggingIn)
      .overlay {
        if service.isLoggingIn {
          ProgressView()
            .controlSize(.large)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            AppRouter.shared.showProfiles = false
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .presentationDragIndicator(.visible)
  }
}

/// Current profile: large avatar, service badge, name.
@MainActor
struct ShellCurrentProfileHeader: View {
  var body: some View {
    let current = ProfilesService.shared.current
    return Group {
      if let current {
        VStack(spacing: 10) {
          ShellAvatar(url: current.viewer.avatar, size: 130)
            .overlay(alignment: .bottomTrailing) {
              ShellServiceBadge(service: current.viewer.service)
            }
          Text(current.viewer.name)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current Profile, \(current.viewer.name)")
      }
    }
  }
}

/// "Other Profiles": tap to switch, sync switch or Authenticate, Logout.
@MainActor
struct ShellOtherProfilesList: View {
  var body: some View {
    let others = ProfilesService.shared.others
    return Group {
      if !others.isEmpty {
        VStack(spacing: 4) {
          Text("Other Profiles")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ShellPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          ForEach(others) { profile in
            ShellOtherProfileRow(profile: profile)
          }
        }
      }
    }
  }
}

@MainActor
struct ShellOtherProfileRow: View {
  let profile: AccountProfile

  var body: some View {
    let service = ProfilesService.shared
    let profile = self.profile
    return HStack(spacing: 12) {
      Button {
        service.switchTo(profile)
      } label: {
        HStack(spacing: 12) {
          ShellAvatar(url: profile.viewer.avatar, size: 48)
            .overlay(alignment: .bottomTrailing) {
              ShellServiceBadge(service: profile.viewer.service)
                .scaleEffect(0.8)
            }
          Text(profile.viewer.name)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Switch to Profile: \(profile.viewer.name)")
      if profile.reauth {
        Button {
          Task { @MainActor in _ = await service.reauthenticate() }
        } label: {
          Image(systemName: "clock.badge.exclamationmark")
            .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
        .accessibilityLabel("Authenticate")
      } else {
        Toggle(
          "Sync List Entries",
          isOn: Binding(
            get: { service.isSynced(profile) },
            set: { _ in service.toggleSync(profile) }
          )
        )
        .labelsHidden()
        .accessibilityLabel("Sync List Entries")
      }
      Button {
        service.drop(profile)
      } label: {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.white)
      .accessibilityLabel("Logout")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(profile.reauth ? ShellPalette.error : ShellPalette.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

/// Login buttons / Add Profile / Authenticate / Sign Out.
@MainActor
struct ShellProfileActions: View {
  @Binding var addingProfile: Bool

  var body: some View {
    let service = ProfilesService.shared
    let current = service.current
    let others = service.others
    let showLogin = (addingProfile || (current == nil && others.isEmpty)) && others.count < ProfilesService.maxOtherProfiles
    return VStack(spacing: 6) {
      if showLogin {
        ShellLoginBox(showTitle: current == nil && others.isEmpty) {
          addingProfile = false
        }
      } else if service.canAddProfile {
        ShellProfileBoxButton(title: "Add Profile", icon: "plus", tint: ShellPalette.card) {
          addingProfile = true
        }
      }
      if let current {
        if current.reauth {
          ShellProfileBoxButton(title: "Authenticate", icon: "clock.badge.exclamationmark", tint: ShellPalette.error) {
            Task { @MainActor in _ = await service.reauthenticate() }
          }
        }
        ShellProfileBoxButton(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right", tint: ShellPalette.card) {
          service.logout()
        }
      }
    }
  }
}

/// AniList and MyAnimeList login buttons (confirmAnilist / confirmMAL).
@MainActor
struct ShellLoginBox: View {
  let showTitle: Bool
  let onSuccess: () -> Void

  var body: some View {
    let service = ProfilesService.shared
    return VStack(spacing: 12) {
      if showTitle {
        Text("Log In")
          .font(.title3.weight(.bold))
          .foregroundStyle(Color.white)
      }
      Button {
        Task { @MainActor in
          if await service.loginAniList() { onSuccess() }
        }
      } label: {
        Text("AniList")
          .font(.headline)
          .foregroundStyle(Color.white)
          .frame(width: 180, height: 40)
          .background(ShellPalette.color(0x02A9FF), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log in with AniList")
      Button {
        Task { @MainActor in
          if await service.loginMAL() { onSuccess() }
        }
      } label: {
        Text("MyAnimeList")
          .font(.headline)
          .foregroundStyle(Color.white)
          .frame(width: 180, height: 40)
          .background(ShellPalette.myAnimeList, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log in with MyAnimeList")
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity)
    .background(ShellPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

@MainActor
struct ShellProfileBoxButton: View {
  let title: String
  let icon: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
