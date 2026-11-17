import Foundation
import Observation
import UIKit

// Discord rich presence (PlayerPage.svelte setDiscordRPC / presenceButtons + electron/src/main/discord.js).
// The desktop app talks to the local Discord client over IPC; on iOS the presence goes through the user's
// Discord account with the Discord Social SDK (DiscordSDK.swift): the account is linked once (OAuth2 with PKCE:
// Authorize → GetToken → UpdateToken → Connect), the refresh token is kept in the Keychain and every launch
// refreshes it and connects silently. The player state is sampled once a second and the presence is sent when it
// changes (play / pause / seek / episode / settings), at most once every 5 seconds.

/// What the player is doing, for the rich presence (built by AppWiring from the PlayerController).
struct DiscordNowPlaying {
  var media: Media
  /// Absolute episode number (0 when unknown).
  var episode: Int
  var title: String
  /// Paused, or loading a file.
  var isPaused: Bool
  /// The full screen player is shown (false: miniplayer or Picture in Picture).
  var isPresented: Bool
  var time: Double
  var duration: Double
  var rate: Double
}

@MainActor
@Observable
final class DiscordPresence {
  static let shared = DiscordPresence()

  static let applicationId: UInt64 = 1_571_278_531_135_279_258
  /// Redirect `discord-<app id>:/authorize/callback` (Info.plist URL scheme), consumed by the SDK.
  static let callbackScheme = "discord-1571278531135279258"

  private static let tokenAccount = "discord.refreshToken"
  /// Discord_RunCallbacks period.
  private static let callbackInterval: TimeInterval = 0.1
  /// Same while linked but disconnected with nothing in flight: no answer is awaited, so once a second is enough
  /// until a reconnect starts (it switches back to `callbackInterval`).
  private static let disconnectedCallbackInterval: TimeInterval = 1
  /// Player sampling period.
  private static let checkInterval: TimeInterval = 1
  /// Throttle of UpdateRichPresence (the desktop app debounces 4.5 s).
  private static let minimumUpdateInterval: TimeInterval = 5
  /// Timestamp drift taken as a seek.
  private static let timestampTolerance: TimeInterval = 3
  /// The callback timer keeps running this long after the last pending work (clear, disconnect, revoke).
  private static let idleGrace: TimeInterval = 5

  enum Account: Equatable {
    case notLinked
    /// Authorization in the Discord app or the web sheet.
    case linking
    case connecting
    case connected(username: String?)
    /// Linked (token in the Keychain) but not connected: Discord unreachable or the connection dropped.
    case disconnected
  }

  private(set) var account: Account = .notLinked
  private(set) var lastError: String?

  /// What the player is doing now; nil without a player. Set by AppWiring.
  @ObservationIgnored var nowPlaying: (() -> DiscordNowPlaying?)?
  /// Code of the Watch Together lobby, nil outside a lobby. Set by AppWiring.
  @ObservationIgnored var watchTogetherCode: (() -> String?)?

  @ObservationIgnored private var sdk: DiscordSDKClient?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var started = false
  /// A token refresh or UpdateToken is in flight.
  @ObservationIgnored private var busy = false
  /// Bumped by link / cancel / unlink: answers of an older flow are ignored.
  @ObservationIgnored private var generation = 0
  /// Last Connect call: the status stays Disconnected for a moment after it.
  @ObservationIgnored private var connectRequestedAt = Date.distantPast
  @ObservationIgnored private var lastCheck = Date.distantPast
  @ObservationIgnored private var lastSent: DiscordActivityContent?
  /// `lastSent` is what Discord shows (false: nothing sent since the connection became ready).
  @ObservationIgnored private var presenceSynced = false
  @ObservationIgnored private var lastSentAt = Date.distantPast
  @ObservationIgnored private var browsingSince: Date?
  /// Start of the generic "Watching something" status shown for adult content (rpcHideAdult "title").
  @ObservationIgnored private var adultSince: Date?
  /// Since when the callback timer has had nothing to do (stopped after `idleGrace`).
  @ObservationIgnored private var idleSince: Date?
  /// The app went to the background since it was last active: the presence is sent again when it comes back.
  @ObservationIgnored private var leftForeground = false
  @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
  private let launchDate = Date()
  /// Party id outside Watch Together (the SDK wants one with the party size).
  private let partyId = "tsumi-" + UUID().uuidString.prefix(12).lowercased()

  private init() {}

  /// The redirect of the authorization. The SDK handles it itself (it hooks the app and scene URL delegate
  /// methods), so the deep link router only has to ignore it.
  static func isAuthCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == callbackScheme
  }

  // MARK: - Lifecycle

  /// First foreground launch: reconnects a linked account. Nothing is loaded when no account is linked.
  func start() {
    guard !started else { return }
    started = true
    guard Self.storedRefreshToken() != nil else { return }
    reconnect()
  }

  /// Back in the foreground: the connection may have dropped while the app was suspended, and the presence was
  /// cleared in the background (it is sent again at once).
  func appBecameActive() {
    guard started else { return }
    if leftForeground {
      leftForeground = false
      presenceSynced = false
      lastSentAt = .distantPast
      if sdk != nil { startTimer() }
    }
    guard !busy else { return }
    switch account {
    case .disconnected:
      reconnect()
    case .connected, .connecting:
      if let sdk, sdk.status == .disconnected, Date().timeIntervalSince(connectRequestedAt) > 15 {
        reconnect()
      }
    case .notLinked, .linking:
      break
    }
  }

  // MARK: - Account

  /// Link: Authorize (Discord app or web sheet) → GetToken → UpdateToken → Connect.
  func link() {
    guard account == .notLinked else { return }
    generation += 1
    let generation = self.generation
    lastError = nil
    account = .linking
    let sdk = ensureSDK()
    sdk.authorize { [weak self] result, code, redirectUri, verifier in
      guard let self, generation == self.generation else { return }
      guard result.successful, !code.isEmpty else {
        self.account = .notLinked
        self.lastError = result.isAborted ? nil : "Linking failed: \(result.message)"
        return
      }
      sdk.getToken(code: code, verifier: verifier, redirectUri: redirectUri) { [weak self] result, tokens in
        guard let self, generation == self.generation else { return }
        guard let tokens else {
          self.account = .notLinked
          self.lastError = "Linking failed: \(result.message)"
          return
        }
        self.account = .connecting
        self.accept(tokens, generation: generation)
      }
    }
  }

  /// "Cancel" while linking (the user left the Discord app or the web sheet without answering).
  func cancelLinking() {
    guard account == .linking else { return }
    generation += 1
    sdk?.abortAuthorize()
    account = .notLinked
  }

  /// Refreshes the stored token and connects (launch, "Reconnect", back in the foreground).
  func reconnect() {
    guard !busy else { return }
    guard let token = Self.storedRefreshToken() else {
      account = .notLinked
      return
    }
    lastError = nil
    account = .connecting
    refreshAndConnect(token)
  }

  /// Unlink: clears the presence, disconnects, revokes and deletes the token.
  func unlink() {
    let previous = account
    let token = Self.storedRefreshToken()
    generation += 1
    busy = false
    Self.deleteRefreshToken()
    account = .notLinked
    lastError = nil
    lastSent = nil
    presenceSynced = false
    guard let sdk else { return }
    if previous == .linking {
      sdk.abortAuthorize()
    }
    sdk.clearRichPresence()
    sdk.disconnect()
    if let token {
      sdk.revokeToken(token)
    }
  }

  private func ensureSDK() -> DiscordSDKClient {
    // The callback timer may have stopped (unlinked, presence disabled): every flow starts it again.
    startTimer()
    if let sdk { return sdk }
    let client = DiscordSDKClient(applicationId: Self.applicationId)
    client.addLogHandler()
    client.setStatusHandler { [weak self] status, error in
      self?.statusChanged(status, error: error)
    }
    client.setTokenExpirationHandler { [weak self] in
      self?.tokenExpiring()
    }
    sdk = client
    observeSettings()
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        DiscordPresence.shared.appEnteredBackground()
      }
    }
    return client
  }

  /// The presence setting changed: the timer runs again (it stops by itself when there is nothing to do).
  private func observeSettings() {
    withObservationTracking {
      _ = AppSettings.shared.values.enableRPC
    } onChange: {
      Task { @MainActor in
        let presence = DiscordPresence.shared
        presence.observeSettings()
        if presence.sdk != nil { presence.startTimer() }
      }
    }
  }

  /// Background: cleared like the desktop app clears it when its window is hidden, unless the video goes on
  /// (audio, Picture in Picture, AirPlay; see `desiredActivity`). The player applies "Pause On Lost Focus" on the
  /// same notification, so the decision waits a moment; a short background task lets the update go out.
  private func appEnteredBackground() {
    leftForeground = true
    guard sdk != nil, case .connected = account else { return }
    let background = DownloadBackgroundTask()
    background.begin("Tsumi Discord presence")
    startTimer()
    Task { @MainActor in
      defer { background.end() }
      try? await Task.sleep(nanoseconds: 800_000_000)
      let presence = DiscordPresence.shared
      if UIApplication.shared.applicationState == .background {
        presence.updatePresence(now: Date(), force: true)
      }
      // RunCallbacks (timer) delivers the answer meanwhile.
      try? await Task.sleep(nanoseconds: 2_500_000_000)
    }
  }

  private func refreshAndConnect(_ refreshToken: String) {
    let sdk = ensureSDK()
    let generation = self.generation
    busy = true
    sdk.refreshToken(refreshToken) { [weak self] result, tokens in
      guard let self, generation == self.generation else { return }
      self.busy = false
      if let tokens {
        self.accept(tokens, generation: generation)
        return
      }
      if result.isAuthorizationFailure {
        DiscordPresence.deleteRefreshToken()
        self.account = .notLinked
        self.lastError = "The Discord link is no longer valid, link your account again."
        return
      }
      self.lastError = "Couldn't reach Discord: \(result.message)"
      if case .connected = self.account {
        return
      }
      self.account = .disconnected
    }
  }

  /// Stores the new refresh token, hands the access token to the SDK and connects when needed.
  private func accept(_ tokens: DiscordTokens, generation: Int) {
    if !tokens.refreshToken.isEmpty {
      Self.storeRefreshToken(tokens.refreshToken)
    }
    guard let sdk else { return }
    busy = true
    sdk.updateToken(tokens.accessToken) { [weak self] result in
      guard let self, generation == self.generation else { return }
      self.busy = false
      guard result.successful else {
        self.account = .disconnected
        self.lastError = "Discord refused the token: \(result.message)"
        return
      }
      let status = sdk.status
      if status == .disconnected || status == .disconnecting {
        self.connectRequestedAt = Date()
        sdk.connect()
      }
    }
  }

  private func tokenExpiring() {
    guard !busy, let token = Self.storedRefreshToken() else { return }
    refreshAndConnect(token)
  }

  private func statusChanged(_ status: DiscordClientStatus, error: String?) {
    switch status {
    case .ready:
      guard Self.storedRefreshToken() != nil else {
        // Unlinked while connecting.
        sdk?.disconnect()
        return
      }
      account = .connected(username: sdk?.currentUsername)
      lastError = nil
      presenceSynced = false
      lastSentAt = .distantPast
      updatePresence(now: Date())
    case .connecting, .connected, .reconnecting, .httpWait:
      switch account {
      case .connected, .disconnected:
        account = .connecting
      default:
        break
      }
    case .disconnected:
      guard !busy, Self.storedRefreshToken() != nil else { return }
      switch account {
      case .connected, .connecting:
        account = .disconnected
        if let error {
          lastError = "Disconnected from Discord: \(error)"
        }
      default:
        break
      }
    case .disconnecting:
      break
    }
  }

  // MARK: - Presence

  /// Period the callback timer should run at now.
  private var callbackPeriod: TimeInterval {
    if case .disconnected = account, !busy { return Self.disconnectedCallbackInterval }
    return Self.callbackInterval
  }

  /// Starts the callback timer, or restarts it when its period no longer fits the account state.
  private func startTimer() {
    idleSince = nil
    let period = callbackPeriod
    if let timer {
      guard timer.timeInterval != period else { return }
      timer.invalidate()
      self.timer = nil
    }
    let timer = Timer(timeInterval: period, repeats: true) { _ in
      MainActor.assumeIsolated {
        DiscordPresence.shared.tick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
    idleSince = nil
  }

  /// RunCallbacks is needed: an account flow or connection runs, or a presence is kept up. Unlinked, or with
  /// the presence disabled once its clear went out, the timer stops after `idleGrace` (link, reconnect, the
  /// setting and the return to the foreground start it again). Linked but disconnected, it runs at 1 Hz.
  private var needsCallbacks: Bool {
    if busy { return true }
    let enabled = AppSettings.shared.values.enableRPC != "disabled"
    switch account {
    case .notLinked:
      return false
    case .linking, .connecting:
      return true
    case .connected:
      return enabled || !(presenceSynced && lastSent == nil)
    case .disconnected:
      return enabled
    }
  }

  private func tick() {
    DiscordSDKClient.runCallbacks()
    let now = Date()
    if needsCallbacks {
      idleSince = nil
      // Disconnected: 1 Hz; connecting again (a status callback, reconnect()): back to 10 Hz.
      if let timer, timer.timeInterval != callbackPeriod { startTimer() }
    } else if let since = idleSince {
      if now.timeIntervalSince(since) >= Self.idleGrace {
        stopTimer()
        return
      }
    } else {
      idleSince = now
    }
    guard now.timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
    lastCheck = now
    if case .connected(.none) = account, let username = sdk?.currentUsername {
      account = .connected(username: username)
    }
    updatePresence(now: now)
  }

  /// Sends the presence when it differs from what Discord shows, at most every `minimumUpdateInterval` (`force`:
  /// right away, the app is about to be suspended).
  private func updatePresence(now: Date, force: Bool = false) {
    guard let sdk, case .connected = account else { return }
    let desired = desiredActivity(now: now)
    if presenceSynced && Self.same(desired, lastSent) { return }
    guard force || now.timeIntervalSince(lastSentAt) >= Self.minimumUpdateInterval else { return }
    lastSentAt = now
    lastSent = desired
    presenceSynced = true
    guard let desired else {
      sdk.clearRichPresence()
      return
    }
    sdk.updateRichPresence(desired) { [weak self] result in
      guard !result.successful else { return }
      NSLog("[Discord] UpdateRichPresence failed: %@", result.message)
      if result.isRetryable {
        self?.presenceSynced = false
      }
    }
  }

  /// enableRPC: disabled → nothing; limited → the default status (no title, no buttons, like discord.js);
  /// full → the media while playing (or paused in the full screen player), else "Browsing the library".
  private func desiredActivity(now: Date) -> DiscordActivityContent? {
    let settings = AppSettings.shared.values
    // In the background nothing is shown (the desktop app clears it when hidden), unless the video goes on there.
    if UIApplication.shared.applicationState == .background && !(PlayerPresentation.shared.controller?.continuesInBackground ?? false) {
      browsingSince = nil
      return nil
    }
    switch settings.enableRPC {
    case "disabled":
      return nil
    case "limited":
      return DiscordActivityBuilder.browsing(since: launchDate, buttons: [])
    default:
      break
    }
    let code = watchTogetherCode?()
    if let playing = nowPlaying?(), !(playing.isPaused && !playing.isPresented) {
      browsingSince = nil
      // Adult content stays private (rpcHideAdult): no presence at all, or a generic status without title, cover or links.
      if DiscordActivityBuilder.isAdult(playing.media) && settings.rpcHideAdult != "off" {
        if settings.rpcHideAdult == "hidden" { return nil }
        let since = adultSince ?? now
        adultSince = since
        return DiscordActivityBuilder.privateActivity(since: since, buttons: DiscordActivityBuilder.buttons(media: nil, code: code, secondButton: "download"))
      }
      adultSince = nil
      return DiscordActivityBuilder.watching(playing, code: code, secondButton: settings.rpcSecondButton, partyId: partyId, now: now)
    }
    let since = browsingSince ?? now
    browsingSince = since
    let buttons = DiscordActivityBuilder.buttons(media: nil, code: code, secondButton: settings.rpcSecondButton)
    return DiscordActivityBuilder.browsing(since: since, buttons: buttons)
  }

  private static func same(_ first: DiscordActivityContent?, _ second: DiscordActivityContent?) -> Bool {
    switch (first, second) {
    case (nil, nil):
      return true
    case let (first?, second?):
      return first.matches(second, tolerance: timestampTolerance)
    default:
      return false
    }
  }

  // MARK: - Keychain

  private static func storedRefreshToken() -> String? {
    guard let data = TsumiKeychain.data(for: tokenAccount),
          let token = String(data: data, encoding: .utf8),
          !token.isEmpty else { return nil }
    return token
  }

  private static func storeRefreshToken(_ token: String) {
    TsumiKeychain.set(Data(token.utf8), for: tokenAccount)
  }

  private static func deleteRefreshToken() {
    TsumiKeychain.remove(tokenAccount)
  }
}

extension DiscordPresence.Account {
  /// Status line of Settings > Discord.
  var label: String {
    switch self {
    case .notLinked:
      return "Not linked"
    case .linking:
      return "Linking…"
    case .connecting:
      return "Connecting…"
    case .connected(let username):
      return username.map { "Connected as \($0)" } ?? "Connected"
    case .disconnected:
      return "Linked, not connected"
    }
  }
}

/// Activity contents of PlayerPage.svelte setDiscordRPC and presenceButtons.
enum DiscordActivityBuilder {
  static let tsumiLink = "https://mxfia19.github.io/Tsumi/"
  static let browsingDetails = "Watching Media on Tsumi"
  static let browsingState = "Browsing the library"
  static let browsingImageText = "Tsumi — Media Streaming"
  static let privateState = "Watching something"
  /// Asset uploaded to the Discord application (Rich Presence > Art Assets).
  static let iconAsset = "icon"

  /// Adult media (AniList isAdult or the Hentai genre), hidden by the rpcHideAdult setting (PlayerPage.svelte isAdultMedia).
  static func isAdult(_ media: Media) -> Bool {
    media.isAdult || media.genres.contains("Hentai")
  }

  /// Adult content with rpcHideAdult "title": "Watching Media on Tsumi" / "Watching something", app icon, no title or links.
  static func privateActivity(since: Date, buttons: [DiscordActivityContent.Button]) -> DiscordActivityContent {
    DiscordActivityContent(
      details: browsingDetails,
      state: privateState,
      largeImage: iconAsset,
      largeText: browsingImageText,
      start: since,
      end: nil,
      buttons: buttons
    )
  }

  /// No media: "Watching Media on Tsumi" / "Browsing the library", counting up since `since`.
  static func browsing(since: Date, buttons: [DiscordActivityContent.Button]) -> DiscordActivityContent {
    DiscordActivityContent(
      details: browsingDetails,
      state: browsingState,
      largeImage: iconAsset,
      largeText: browsingImageText,
      start: since,
      end: nil,
      buttons: buttons
    )
  }

  /// details = title, state = "Episode: N of M" / "The Movie", cover as large image, progress timestamps while
  /// playing (none while paused), party size [episode, total], presence buttons.
  static func watching(_ playing: DiscordNowPlaying, code: String?, secondButton: String, partyId: String, now: Date) -> DiscordActivityContent {
    let media = playing.media
    let total = media.episodes ?? 0
    let title = fit(playing.title, limit: 128) ?? browsingDetails
    let state: String
    if media.isMovie && total <= 1 {
      state = "The Movie"
    } else if playing.episode > 0 {
      state = "Episode: \(playing.episode)" + (total > 0 ? " of \(total)" : "")
    } else {
      state = "Streaming the Universe"
    }
    var start: Date? = nil
    var end: Date? = nil
    if !playing.isPaused {
      let rate = playing.rate.isFinite && playing.rate > 0 ? playing.rate : 1
      let time = playing.time.isFinite ? max(playing.time, 0) : 0
      start = now.addingTimeInterval(-time / rate)
      if playing.duration.isFinite, playing.duration > time {
        end = now.addingTimeInterval((playing.duration - time) / rate)
      }
    }
    let lobby = code.flatMap { $0.isEmpty ? nil : $0 }
    var content = DiscordActivityContent(
      details: title,
      state: state,
      largeImage: coverImage(media) ?? iconAsset,
      largeText: fit(playing.title, limit: 128) ?? browsingImageText,
      start: start,
      end: end,
      buttons: buttons(media: media, code: lobby, secondButton: secondButton)
    )
    if playing.episode >= 1 && total >= playing.episode {
      content.partySize = playing.episode
      content.partyMax = total
      content.partyId = lobby.map { "\($0)p" } ?? partyId
    }
    return content
  }

  /// presenceButtons(media, w2g): "Join Watch Together" in a lobby, the title page (AniList, or TMDB for shows
  /// and movies), then outside a lobby MyAnimeList (rpcSecondButton 'mal' and a MAL id) or "Download Tsumi".
  static func buttons(media: Media?, code: String?, secondButton: String) -> [DiscordActivityContent.Button] {
    var buttons: [DiscordActivityContent.Button] = []
    let lobby = code.flatMap { $0.isEmpty ? nil : $0 }
    if let lobby {
      let encoded = lobby.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? lobby
      buttons.append(.init(label: "Join Watch Together", url: "\(tsumiLink)w2g/?c=\(encoded)"))
    }
    if let media {
      if media.source == .tmdb {
        if let tmdbId = media.tmdbId {
          let isMovie = media.isMovie
          buttons.append(.init(
            label: isMovie ? "View Movie" : "View Show",
            url: "https://www.themoviedb.org/\(isMovie ? "movie" : "tv")/\(tmdbId)"
          ))
        }
      } else if let anilistId = media.anilistId {
        buttons.append(.init(label: "View on AniList", url: "https://anilist.co/anime/\(anilistId)"))
      }
    }
    if lobby == nil && buttons.count < 2 {
      if secondButton == "mal", let malId = media?.malId {
        buttons.append(.init(label: "View on MyAnimeList", url: "https://myanimelist.net/anime/\(malId)"))
      } else {
        buttons.append(.init(label: "Download Tsumi", url: tsumiLink))
      }
    }
    return Array(buttons.prefix(2))
  }

  /// Cover URL when Discord can take it (http(s), at most 300 characters), else nil (the `icon` asset).
  private static func coverImage(_ media: Media) -> String? {
    guard let url = (media.images.coverLarge ?? media.images.cover)?.absoluteString else { return nil }
    guard url.hasPrefix("https://") || url.hasPrefix("http://"), url.utf16.count <= 300 else { return nil }
    return url
  }

  /// Trimmed text cut to `limit` UTF-16 units (like the desktop `.slice(0, limit)`); nil under the 2 character
  /// minimum of the activity fields.
  static func fit(_ text: String, limit: Int) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = ""
    var units = 0
    for character in trimmed {
      let length = String(character).utf16.count
      if units + length > limit { break }
      result.append(character)
      units += length
    }
    return result.utf16.count >= 2 ? result : nil
  }
}
