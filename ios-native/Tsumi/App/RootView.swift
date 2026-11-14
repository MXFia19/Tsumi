import SwiftUI
import UIKit

/// Root of the app (App.svelte + Router.svelte + Sidebar.svelte / Navbar.svelte): one tab per page, each
/// in its own NavigationStack, the root sheets (details, notifications, profiles), the playback dialogs,
/// the full screen player, the toasts, deep links and the app lifecycle.
@MainActor
struct RootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// iPhone (any orientation) and iPad in a compact split view use the phone navigation (no "More" tab).
  private var compact: Bool {
    UIDevice.current.userInterfaceIdiom != .pad || sizeClass == .compact
  }

  var body: some View {
    ShellTabs(compact: compact)
      .safeAreaInset(edge: .top, spacing: 0) {
        ShellConnectionBanner()
      }
      .modifier(ShellRootPresenters())
      .task {
        await ShellLaunch.startFromView()
      }
      .task {
        await ShellToastJanitor.run()
      }
      .onOpenURL { url in
        ShellDeepLinks.handle(url)
      }
      .onChange(of: scenePhase) { _, phase in
        ShellLifecycle.scenePhaseChanged(phase)
      }
  }
}

/// Sidebar.svelte pages. Regular width (iPad): Home, Search, Schedule, Catalogs, Watch Together, Settings.
/// Compact width (iPhone): the Navbar.svelte pages (no Catalogs tab; Catalogs is pushed from Search).
@MainActor
struct ShellTabs: View {
  let compact: Bool

  var body: some View {
    let router = AppRouter.shared
    let compact = self.compact
    return TabView(
      selection: Binding<AppTab>(
        get: { router.selectedTab },
        set: { router.selectedTab = $0 }
      )
    ) {
      ShellTabStack(tab: .home, compact: compact) { HomeView() }
        .tabItem { Label("Home", systemImage: "house") }
        .tag(AppTab.home)
      ShellTabStack(tab: .search, compact: compact) { SearchView() }
        .tabItem { Label("Search", systemImage: "magnifyingglass") }
        .tag(AppTab.search)
      ShellTabStack(tab: .schedule, compact: compact) { ScheduleView() }
        .tabItem { Label("Schedule", systemImage: "calendar") }
        .tag(AppTab.schedule)
      if !compact {
        ShellTabStack(tab: .catalogs, compact: compact) { ShellCatalogsScreen() }
          .tabItem { Label("Catalogs", systemImage: "movieclapper") }
          .tag(AppTab.catalogs)
      }
      ShellTabStack(tab: .watchTogether, compact: compact) { WatchTogetherView() }
        .tabItem { Label("Watch Together", systemImage: "person.2") }
        .tag(AppTab.watchTogether)
      ShellTabStack(tab: .settings, compact: compact) { SettingsView() }
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .onAppear {
      ShellNavigation.normalize(tab: router.selectedTab, compact: compact)
    }
    .onChange(of: router.selectedTab) { _, tab in
      ShellNavigation.normalize(tab: tab, compact: compact)
    }
    .onChange(of: compact) { _, isCompact in
      ShellNavigation.normalize(tab: router.selectedTab, compact: isCompact)
    }
  }
}
