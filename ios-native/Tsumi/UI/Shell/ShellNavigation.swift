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
  /// Offline downloads (toolbar button / offline banner), pushed on the current tab.
  case downloads
  /// Page of a Sora module result opened as it is (no AniList / TMDB match), pushed on the Search stack.
  case soraResult(SoraSearchResult)
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
  /// Downloads screens on screen (ShellRouteDestination), so the offline banner does not push another one.
  @ObservationIgnored var downloadsOnScreen = 0
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

  /// View controllers the shell itself presents above the window root for the current layers (the root
  /// sheet, the player, the details over the player, a playback dialog). Anything presented above them is a
  /// screen's own sheet (filters, list editor, trailer, Year in Review, Watch Together queue, an alert...).
  static var knownDepth: Int {
    var depth: Int
    switch top {
    case .root: depth = 0
    case .rootSheet, .player: depth = 1
    case .playerSheet: depth = 2
    }
    if PlaybackRequestCoordinator.shared.presentation != nil { depth += 1 }
    return depth
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
    // A module result played as it is has no AniList / TMDB details (they would look up a title it is not).
    guard !media.isSoraResult else { return }
    let router = AppRouter.shared
    if router.showNotifications { router.showNotifications = false }
    if router.showProfiles { router.showProfiles = false }
    router.open(media)
  }

  /// Module page of a Sora module result (SoraResultView), pushed on the Search stack the result was tapped on.
  static func openSoraResult(_ result: SoraSearchResult) {
    let state = ShellState.shared
    var path = state.path(for: .search)
    path.append(ShellRoute.soraResult(result))
    state.setPath(path, for: .search)
    // "Open as is" of a toast that came after leaving the Search page (another tab, a sheet opened meanwhile).
    if AppRouter.shared.selectedTab != .search || ShellLayers.rootSheet != nil {
      showTab(.search)
    }
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

  /// The sheets that screens present themselves are invisible to ShellLayers, and nothing the shell presents
  /// shows while one is up (UIKit refuses a second presentation from the same controller), so a deep link, a
  /// Watch Together remote play or a Picture in Picture restore was dropped. Closes the ones above the layers
  /// the shell knows (ShellLayers.knownDepth) and waits for their dismissal.
  static func dismissLocalSheets() async {
    // State just changed (a root sheet or a playback dialog cleared) is applied by SwiftUI first, and a sheet
    // being dismissed finishes, so only the sheets nobody is closing are left above the known layers.
    try? await Task.sleep(nanoseconds: 60_000_000)
    await ShellPresentationTiming.waitUntilSettled(maxDepth: Int.max, timeout: 1)
    let known = ShellLayers.knownDepth
    guard ShellPresentationTiming.dismissPresented(above: known) else { return }
    await ShellPresentationTiming.waitUntilSettled(maxDepth: known, timeout: 1.5)
  }

  /// "Log in again": the profiles sheet hosts the login web view, but ShellLayers.rootSheet shows the details
  /// and notifications sheets before it, and a screen's own sheet covers the root. Those are closed first (the
  /// login otherwise ran unseen under them and popped up later).
  /// The prompts also show on the details over the player, and no root sheet is shown while the player is: the
  /// details are closed and the player minimized first (it keeps playing in the miniplayer), so the profiles sheet
  /// shows at once instead of after the player was closed.
  static func prepareProfilesSheet() async {
    let router = AppRouter.shared
    if ShellLayers.playerVisible {
      router.presentedMedia = nil
      router.showNotifications = false
      // The details sheet leaves the player first (dismissing both at once can drop one of the dismissals).
      await ShellPresentationTiming.waitUntilSettled(maxDepth: 1, timeout: 1.5)
      PlayerPresentation.shared.controller?.minimize()
      await ShellPresentationTiming.waitUntilSettled(maxDepth: 0, timeout: 1.5)
    } else if router.presentedMedia != nil || router.showNotifications {
      router.presentedMedia = nil
      router.showNotifications = false
    }
    await dismissLocalSheets()
  }

  /// Offline banner: the downloads, unless a Downloads screen is already shown (each tap pushed another one).
  static func openDownloads() {
    if ShellState.shared.downloadsOnScreen > 0 {
      clearRootSheets()
      return
    }
    DownloadNavigation.open()
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
/// plus notification taps (tsumi://anime/<id>, tsumi://movie/<tmdbId>).
@MainActor
enum ShellDeepLinks {
  static func handle(_ url: URL) {
    if DiscordPresence.isAuthCallback(url) {
      // discord-<app id>:/authorize/callback: consumed by the Discord SDK (account linking).
      return
    }
    if TraktPKCE.isCallback(url) {
      // tsumi://trakt/callback: normally caught by the sign-in session itself; otherwise completes the running
      // sign-in (TraktService checks its state), ignored when none is running.
      TraktService.shared.handleCallback(url)
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
    case .anime, .malAnime, .movie, .play, .schedule:
      // What these open would not show over a screen's own sheet.
      await ShellNavigation.dismissLocalSheets()
    case .watchTogether, .loginCallback:
      break
    }
    switch link {
    case .anime, .malAnime, .movie:
      // App.svelte handleAnime: searchIDSingle by id / idMal (TMDB details for a movie), then open the details.
      if let media = await Services.shared.media(for: link) {
        ShellNavigation.openDetails(media)
      } else if case .movie = link {
        // Nothing stored or kept for the movie and TMDB did not answer: what is open stays open.
        ShellNotificationMedia.movieFailed()
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

  /// Dismisses whatever is presented above the controller at `depth` (0 = the window root). Returns false when
  /// there is nothing above it, or the chain is not that deep yet (a presentation still to come).
  static func dismissPresented(above depth: Int) -> Bool {
    guard let root = keyRootViewController() else { return false }
    var current: UIViewController = root
    var level = 0
    while level < depth, let presented = current.presentedViewController {
      current = presented
      level += 1
    }
    guard level == depth, let extra = current.presentedViewController, !extra.isBeingDismissed else { return false }
    current.dismiss(animated: true)
    return true
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
