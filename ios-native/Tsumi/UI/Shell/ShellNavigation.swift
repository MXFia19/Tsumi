import SwiftUI
import Observation
import UIKit

// App shell navigation state: which layer is on top (root, a root sheet, the player, a sheet over the player),
// the navigation paths of the tabs, and the helpers that open details / tabs / settings like
// common/modules/navigation.js (page.navigateTo clears the modals) and App.svelte (handleAnime).

/// Where something can be presented. Only the top layer hosts the playback dialogs and the toasts, so a
/// presentation never targets a view controller that is already presenting something else.
enum ShellLayer: Hashable {
  /// The tab view (no sheet, no player).
  case root
  /// A sheet of the root view (details, notifications, profiles).
  case rootSheet
  /// The full screen player.
  case player
  /// The details sheet shown over the player (Now Playing details, pagePause).
  case playerSheet
}

/// Sheets of the root view (DetailsModal, NotificationsModal, Profiles in App.svelte).
/// The details case keeps one identity so another title replaces the content in place.
enum ShellRootSheet: Identifiable, Hashable {
  case details(Media)
  case notifications
  case profiles

  var id: String {
    switch self {
    case .details: return "details"
    case .notifications: return "notifications"
    case .profiles: return "profiles"
    }
  }
}

/// Details sheet item over the player.
struct ShellMediaItem: Identifiable, Hashable {
  let media: Media
  var id: String { "details" }
}

/// Screens pushed by the shell itself on a tab stack.
enum ShellRoute: Hashable {
  /// Catalogs on compact width, where it is not a tab (the mobile Navbar.svelte has no Catalogs entry).
  case catalogs
}

/// Observable shell state shared by the root view, the toolbar and the wiring.
@MainActor
@Observable
final class ShellState {
  static let shared = ShellState()

  /// Navigation path of each tab stack (programmatic navigation: Settings > Extensions, Catalogs...).
  var paths: [AppTab: NavigationPath] = [:]
  /// Title of the last closed player ("Last Watched" entry of Sidebar.svelte, nowPlaying.display).
  var lastWatched: Media?

  /// A new player is replacing the current one: the closing details sheet must not resume the old one.
  @ObservationIgnored var replacingPlayer = false
  /// Episode switch requested by Watch Together (setindex): its start is not shared back to the lobby.
  @ObservationIgnored var suppressShareUntil = Date.distantPast

  private init() {}

  func path(for tab: AppTab) -> NavigationPath {
    paths[tab] ?? NavigationPath()
  }

  func setPath(_ path: NavigationPath, for tab: AppTab) {
    paths[tab] = path
  }
}

/// Which layer is currently on top (reads observable state, so views re-render when it changes).
@MainActor
enum ShellLayers {
  static var playerVisible: Bool {
    let presentation = PlayerPresentation.shared
    return presentation.isPresented && presentation.controller != nil
  }

  static var rootSheet: ShellRootSheet? {
    let router = AppRouter.shared
    if let media = router.presentedMedia { return .details(media) }
    if router.showNotifications { return .notifications }
    if router.showProfiles { return .profiles }
    return nil
  }

  static var top: ShellLayer {
    if playerVisible {
      return AppRouter.shared.presentedMedia != nil ? .playerSheet : .player
    }
    return rootSheet != nil ? .rootSheet : .root
  }

  /// Reads every value the presentation bindings depend on, so the calling body is re-evaluated when one
  /// changes (custom Binding getters are not observed by themselves).
  static func track() {
    let presentation = PlayerPresentation.shared
    _ = presentation.isPresented
    _ = presentation.controller
    let router = AppRouter.shared
    _ = router.presentedMedia
    _ = router.showNotifications
    _ = router.showProfiles
    _ = PlaybackRequestCoordinator.shared.presentation
  }
}

/// Navigation helpers (navigation.js page.navigateTo / modal.open, App.svelte handleAnime).
@MainActor
enum ShellNavigation {
  private static var pendingAction: (() -> Void)?
  private static var pendingToken = 0

  /// Closes the details, notifications and profiles sheets.
  static func clearRootSheets() {
    let router = AppRouter.shared
    if router.presentedMedia != nil { router.presentedMedia = nil }
    if router.showNotifications { router.showNotifications = false }
    if router.showProfiles { router.showProfiles = false }
  }

  /// handleAnime / modal.open(ANIME_DETAILS): replaces any root sheet with the details of `media`
  /// (shown over the player when the player is visible).
  static func openDetails(_ media: Media) {
    let router = AppRouter.shared
    if router.showNotifications { router.showNotifications = false }
    if router.showProfiles { router.showProfiles = false }
    router.open(media)
  }

  /// Opens the details once running presentations finished (e.g. a catalog grid sheet that is closing).
  static func openDetailsWhenSettled(_ media: Media) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 60_000_000)
      await ShellPresentationTiming.waitUntilSettled(maxDepth: ShellLayers.playerVisible ? 1 : 0, timeout: 1.5)
      ShellNavigation.openDetails(media)
    }
  }

  /// page.navigateTo(page): closes the modals and selects the tab.
  static func showTab(_ tab: AppTab) {
    clearRootSheets()
    AppRouter.shared.show(tab)
  }

  /// Settings tab, optionally on one of its screens (CatalogPage "Open Settings" → Extensions).
  static func openSettings(_ route: ShellSettingsRoute?) {
    var path = NavigationPath()
    if let route { path.append(route) }
    ShellState.shared.setPath(path, for: .settings)
    showTab(.settings)
  }

  /// Catalogs is a tab on regular width only; on compact width it is pushed on the Search stack.
  static func normalize(tab: AppTab, compact: Bool) {
    guard compact, tab == .catalogs else { return }
    var path = NavigationPath()
    path.append(ShellRoute.catalogs)
    ShellState.shared.setPath(path, for: .search)
    AppRouter.shared.selectedTab = .search
  }

  /// Runs `action` after the root sheets are closed (NotificationsModal onclick: close() then dispatch).
  static func afterClosingRootSheets(_ action: @escaping () -> Void) {
    guard ShellLayers.rootSheet != nil, !ShellLayers.playerVisible else {
      action()
      return
    }
    pendingToken += 1
    let token = pendingToken
    pendingAction = action
    clearRootSheets()
    // Fallback when the sheet's onDismiss does not come (sheet that never finished presenting).
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if token == ShellNavigation.pendingToken { ShellNavigation.runPendingAction() }
    }
  }

  /// onDismiss of the root sheet.
  static func rootSheetDidDismiss() {
    guard ShellLayers.rootSheet == nil else { return }
    runPendingAction()
  }

  private static func runPendingAction() {
    pendingToken += 1
    guard let action = pendingAction else { return }
    pendingAction = nil
    action()
  }
}

/// Deep links: capacitor/src/main/protocol.js and electron/src/main/protocol.js protocolMap,
/// plus notification taps (tsumi://anime/<id>).
@MainActor
enum ShellDeepLinks {
  static func handle(_ url: URL) {
    if DiscordPresence.isAuthCallback(url) {
      // discord-<app id>:/authorize/callback: consumed by the Discord SDK (account linking).
      return
    }
    if WatchTogetherClient.isLobbyLink(url) {
      // w2g: link → IPC 'w2glink' (joins and shows the lobby through onShowLobby).
      _ = WatchTogetherClient.shared.handle(url: url)
      return
    }
    Task { @MainActor in
      guard let link = await Services.shared.handle(url: url) else { return }
      await ShellDeepLinks.route(link)
    }
  }

  static func route(_ link: TsumiDeepLink) async {
    switch link {
    case .anime, .malAnime:
      // App.svelte handleAnime: searchIDSingle by id / idMal, then open the details.
      if let media = await Services.shared.media(for: link) {
        ShellNavigation.openDetails(media)
      }
    case .play:
      // protocol `search`: play-anime(id) → DetailsModal handlePlay(id).
      if let media = await Services.shared.media(for: link) {
        await ShellPlayback.playFromLink(media)
      }
    case .watchTogether(let value):
      _ = WatchTogetherClient.shared.join(link: value)
    case .schedule:
      ShellNavigation.showTab(.schedule)
    case .loginCallback:
      // alauth / malauth were consumed by ProfilesService (toasts on failure).
      break
    }
  }
}

/// settings.js paste handler: a token / MyAnimeList code signs in (`ProfilesService.login(pasted:)`), an
/// anilist.co / myanimelist.net anime link or a tsumi:// link goes through `Services.handle` like a deep link.
@MainActor
enum ShellPasteHandler {
  /// Returns true when the pasted text signed in.
  @discardableResult
  static func handle(_ text: String) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if ProfilesService.pastedAniListToken(trimmed) != nil || (trimmed.contains("code=") && trimmed.contains("state=")) {
      return await ProfilesService.shared.login(pasted: trimmed)
    }
    guard let url = URL.lenient(trimmed) else {
      unrecognized()
      return false
    }
    if WatchTogetherClient.isLobbyLink(url) {
      ShellDeepLinks.handle(url)
      return false
    }
    guard let link = await Services.shared.handle(url: url) else {
      unrecognized()
      return false
    }
    if case .loginCallback(success: let success) = link { return success }
    await ShellDeepLinks.route(link)
    return false
  }

  private static func unrecognized() {
    ServiceMessages.shared.post(.warning, "Nothing to Open", "The pasted text is not a login token or a link the app can open.")
  }
}

/// Waits for UIKit presentations to settle before presenting something new from SwiftUI state
/// (a sheet cannot be presented while another one is still being dismissed).
@MainActor
enum ShellPresentationTiming {
  /// Returns when no presentation transition runs and at most `maxDepth` controllers are presented
  /// above the window's root (or after `timeout`).
  static func waitUntilSettled(maxDepth: Int, timeout: TimeInterval = 2.5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let state = presentationState()
      if !state.transitioning && state.depth <= maxDepth { return }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private static func presentationState() -> (depth: Int, transitioning: Bool) {
    guard let root = keyRootViewController() else { return (0, false) }
    var depth = 0
    var transitioning = false
    var current: UIViewController = root
    while let presented = current.presentedViewController, depth < 12 {
      depth += 1
      if presented.isBeingPresented || presented.isBeingDismissed { transitioning = true }
      current = presented
    }
    if current.transitionCoordinator != nil { transitioning = true }
    return (depth, transitioning)
  }

  private static func keyRootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }), let root = window.rootViewController {
        return root
      }
    }
    for scene in scenes {
      if let root = scene.windows.first?.rootViewController { return root }
    }
    return nil
  }
}
