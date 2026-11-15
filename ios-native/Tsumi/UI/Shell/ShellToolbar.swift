import SwiftUI

// Tab stacks and the navigation entries that Sidebar.svelte / Navbar.svelte show next to the pages:
// Now Playing / Last Watched, Notifications (Bell / BellDot), Profiles / Login (avatar).

/// One tab: its own NavigationStack (bound to ShellState so the shell can push screens), the shell
/// routes and the shared toolbar.
@MainActor
struct ShellTabStack<Content: View>: View {
  let tab: AppTab
  let compact: Bool
  let content: Content

  init(tab: AppTab, compact: Bool, @ViewBuilder content: () -> Content) {
    self.tab = tab
    self.compact = compact
    self.content = content()
  }

  var body: some View {
    let state = ShellState.shared
    let tab = self.tab
    _ = state.path(for: tab)
    return NavigationStack(
      path: Binding<NavigationPath>(
        get: { state.path(for: tab) },
        set: { state.setPath($0, for: tab) }
      )
    ) {
      content
        .navigationDestination(for: ShellRoute.self) { route in
          ShellRouteDestination(route: route)
        }
        .toolbar {
          ShellMainToolbar(tab: tab, compact: compact)
        }
    }
  }
}

@MainActor
struct ShellRouteDestination: View {
  let route: ShellRoute

  var body: some View {
    switch route {
    case .catalogs:
      ShellCatalogsScreen()
    case .downloads:
      DownloadsView()
    }
  }
}

/// CatalogPage.svelte: card click opens the details, "Open Settings" goes to Settings > Extensions.
@MainActor
struct ShellCatalogsScreen: View {
  var body: some View {
    CatalogsView(
      onSelect: { media in ShellNavigation.openDetailsWhenSettled(media) },
      onOpenSettings: { ShellNavigation.openSettings(.extensions) }
    )
    .navigationBarTitleDisplayMode(.inline)
  }
}

@MainActor
struct ShellMainToolbar: ToolbarContent {
  let tab: AppTab
  let compact: Bool

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarLeading) {
      ShellNowPlayingButton()
      ShellDownloadsButton()
      if compact && tab == .search {
        ShellCatalogsButton()
      }
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
      ShellNotificationsButton()
      ShellProfileButton()
    }
  }
}

/// "Now Playing" (player minimized to Picture in Picture) or "Last Watched" (player closed).
@MainActor
struct ShellNowPlayingButton: View {
  var body: some View {
    let presentation = PlayerPresentation.shared
    let minimized = presentation.controller != nil && !presentation.isPresented
    let lastWatched = ShellState.shared.lastWatched
    return Group {
      if minimized {
        Button {
          ShellPlayback.restorePlayer()
        } label: {
          Image(systemName: "list.and.film")
        }
        .accessibilityLabel("Now Playing")
      } else if let lastWatched {
        Button {
          ShellNavigation.openDetails(MediaStore.shared.media(lastWatched.id) ?? lastWatched)
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Last Watched")
      }
    }
  }
}

/// Catalogs entry on compact width (pushed on the Search stack).
@MainActor
struct ShellCatalogsButton: View {
  var body: some View {
    Button {
      var path = ShellState.shared.path(for: .search)
      path.append(ShellRoute.catalogs)
      ShellState.shared.setPath(path, for: .search)
    } label: {
      Image(systemName: "movieclapper")
    }
    .accessibilityLabel("Catalogs")
  }
}

/// Notifications (modal.toggle(NOTIFICATIONS)); BellDot while something is unread.
@MainActor
struct ShellNotificationsButton: View {
  var body: some View {
    let unread = AppNotificationsService.shared.unreadCount
    return Button {
      AppRouter.shared.showNotifications = true
    } label: {
      if unread > 0 {
        Image(systemName: "bell.badge")
          .symbolRenderingMode(.multicolor)
      } else {
        Image(systemName: "bell")
      }
    }
    .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
  }
}

/// Profiles / Login with the current avatar (modal.toggle(PROFILE)).
@MainActor
struct ShellProfileButton: View {
  var body: some View {
    let viewer = ProfilesService.shared.viewer
    return Button {
      AppRouter.shared.showProfiles = true
    } label: {
      ShellAvatar(url: viewer?.avatar, size: 28)
    }
    .accessibilityLabel(viewer == nil ? "Login" : "Profiles")
  }
}

/// Round avatar with the default profile picture as fallback.
@MainActor
struct ShellAvatar: View {
  let url: URL?
  let size: CGFloat

  var body: some View {
    AsyncImage(url: url) { phase in
      if let image = phase.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(Color.secondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }
}

/// Small AniList / MyAnimeList badge (anilist_icon.png / myanimelist_icon.png of Profiles.svelte).
@MainActor
struct ShellServiceBadge: View {
  let service: Viewer.Service

  var body: some View {
    let isAniList = service == .anilist
    return Text(isAniList ? "AniList" : "MAL")
      .font(.caption2.weight(.bold))
      .foregroundStyle(Color.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(isAniList ? ShellPalette.color(0x02A9FF) : ShellPalette.myAnimeList, in: Capsule())
      .accessibilityLabel(isAniList ? "Logged in with AniList" : "Logged in with MyAnimeList")
  }
}
