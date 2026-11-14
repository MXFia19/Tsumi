import Foundation
import Observation
import UserNotifications
import UIKit

// Port of common/modals/NotificationsModal.svelte (in-app notification list: queue with 15 s debounce,
// de-duplication, delayed / released replacement, auto read when watched, mark all, search) and of the
// AniList notification polling (anilist.js findNewNotifications, every 5 minutes), delivered as local
// notifications through UNUserNotificationCenter when systemNotify is on.

/// One in-app notification (the `detail` objects of 'notification-app' events).
struct MediaNotification: Codable, Hashable, Identifiable {
  enum ClickAction: String, Codable, Hashable {
    case play = "PLAY"
    case view = "VIEW"
  }

  var id: String { "\(mediaId)-\(episode.map { String($0) } ?? "none")-\(dub)" }
  var mediaId: Int
  var mediaKey: String
  var title: String
  var message: String
  var icon: URL?
  var iconXL: URL?
  var heroImage: URL?
  var episode: Int?
  var season: Int?
  var timestamp: Date
  var format: String?
  var dub: Bool
  var delayed: Bool
  var clickAction: ClickAction
  var read: Bool

  /// tsumi://anime/<id>, the activation link of the notification.
  var deepLink: URL? { URL(string: "tsumi://anime/\(mediaId)") }

  /// Core representation.
  var appNotification: AppNotification {
    AppNotification(id: id, title: title, message: message, date: timestamp, mediaKey: mediaKey, episode: episode, image: iconXL ?? icon, read: read)
  }

  static func make(media: Media, title: String? = nil, message: String, episode: Int?, timestamp: Date, dub: Bool, delayed: Bool = false, action: ClickAction) -> MediaNotification {
    let hero = media.images.banner ?? media.trailerYouTubeId.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
    return MediaNotification(mediaId: media.anilistId ?? media.tmdbId ?? 0, mediaKey: media.id, title: title ?? AniListService.shared.title(media), message: message, icon: media.images.cover, iconXL: media.images.coverLarge, heroImage: hero, episode: episode, season: nil, timestamp: timestamp, format: media.format.rawValue, dub: dub, delayed: delayed, clickAction: action, read: false)
  }
}

/// Notification bookkeeping of cache.js `notifications` (lastAni / lastSub / lastDub / lastHentai,
/// announced and delayed ids), persisted in UserDefaults.
final class ReleaseNotifyStore: @unchecked Sendable {
  static let shared = ReleaseNotifyStore()
  private static let storageKey = "tsumi.services.notifyState"

  struct State: Codable {
    var lastAni: Double = 0
    var lastSub: Double = 0
    var lastDub: Double = 0
    var lastHentai: Double = 0
    var delayedDubs: [String] = []
    var announcedDubs: [Int] = []
    var announcedSubs: [Int] = []
    var announcedHentais: [Int] = []
  }

  private let state: ServiceLocked<State>

  private init() {
    var initial = State()
    if let data = UserDefaults.standard.data(forKey: Self.storageKey), let decoded = try? JSONDecoder().decode(State.self, from: data) {
      initial = decoded
    }
    state = ServiceLocked(initial)
  }

  private func mutate(_ body: (inout State) -> Void) {
    let snapshot: State = state.update { value in
      body(&value)
      return value
    }
    if let data = try? JSONEncoder().encode(snapshot) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }

  var lastAni: Double { state.get().lastAni }

  func setLastAni(_ value: Double) {
    mutate { $0.lastAni = value }
  }

  func last(_ feed: ReleaseFeed) -> Double {
    let current = state.get()
    switch feed {
    case .sub: return current.lastSub
    case .dub: return current.lastDub
    case .hentai: return current.lastHentai
    }
  }

  func setLast(_ feed: ReleaseFeed, _ value: Double) {
    mutate { current in
      switch feed {
      case .sub: current.lastSub = value
      case .dub: current.lastDub = value
      case .hentai: current.lastHentai = value
      }
    }
  }

  func announced(_ feed: ReleaseFeed) -> [Int] {
    let current = state.get()
    switch feed {
    case .sub: return current.announcedSubs
    case .dub: return current.announcedDubs
    case .hentai: return current.announcedHentais
    }
  }

  func addAnnounced(_ feed: ReleaseFeed, id: Int) {
    mutate { current in
      switch feed {
      case .sub: current.announcedSubs.append(id)
      case .dub: current.announcedDubs.append(id)
      case .hentai: current.announcedHentais.append(id)
      }
    }
  }

  func delayedDubs() -> [String] {
    state.get().delayedDubs
  }

  func addDelayedDub(_ key: String) {
    mutate { $0.delayedDubs.append(key) }
  }

  /// cache.resetNotifications.
  func reset() {
    mutate { $0 = State() }
  }
}

/// Action buttons of the system notifications (capacitor/src/main/app.js `notifyTypes`): "View Anime" opens
/// the details (tsumi://anime/<id>), "Start Watching" / "Resume" / "Watch" play (tsumi://search/<id>).
enum TsumiNotificationCategory {
  static let viewAnime = "view_anime"
  static let startWatching = "start_watching"
  static let continueWatching = "continue_watching"
  static let watchNow = "watch_now"

  /// Action identifiers (app.js `actionId`).
  static let viewAction = "view_anime"
  static let watchAction = "watch_anime"

  static func register() {
    let view = UNNotificationAction(identifier: viewAction, title: "View Anime", options: [.foreground])
    let start = UNNotificationAction(identifier: watchAction, title: "Start Watching", options: [.foreground])
    let resume = UNNotificationAction(identifier: watchAction, title: "Resume", options: [.foreground])
    let watch = UNNotificationAction(identifier: watchAction, title: "Watch", options: [.foreground])
    let categories: Set<UNNotificationCategory> = [
      UNNotificationCategory(identifier: viewAnime, actions: [view], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: startWatching, actions: [start, view], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: continueWatching, actions: [resume, view], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: watchNow, actions: [watch, view], intentIdentifiers: [], options: [])
    ]
    UNUserNotificationCenter.current().setNotificationCategories(categories)
  }
}

/// UNUserNotificationCenter delegate: shows banners in foreground and forwards taps / action buttons
/// (app.js localNotificationActionPerformed: the watch action opens the play link, the others the details).
final class TsumiNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  var onOpenURL: ((URL) -> Void)?

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    let link: String?
    switch response.actionIdentifier {
    case TsumiNotificationCategory.watchAction:
      link = (info["watchURL"] as? String) ?? (info["url"] as? String)
    case UNNotificationDismissActionIdentifier:
      link = nil
    default:
      link = info["url"] as? String
    }
    let handler = onOpenURL
    if let link, let url = URL(string: link) {
      DispatchQueue.main.async {
        handler?(url)
      }
    }
    completionHandler()
  }
}

@Observable
@MainActor
final class AppNotificationsService {
  static let shared = AppNotificationsService()
  private static let fileName = "tsumi-notifications.json"

  /// Sorted: unread first, then newest first.
  private(set) var items: [MediaNotification] = []
  private(set) var authorizationGranted = false

  var unreadCount: Int { items.filter { !$0.read }.count }
  var hasUnread: Bool { items.contains { !$0.read } }

  /// Called when a notification is tapped (tsumi://anime/<id>); the app routes it like any deep link.
  @ObservationIgnored var onOpenURL: ((URL) -> Void)? {
    didSet { delegate.onOpenURL = onOpenURL }
  }

  @ObservationIgnored private let delegate = TsumiNotificationDelegate()
  @ObservationIgnored private var incoming: [(notification: MediaNotification, system: Bool)] = []
  @ObservationIgnored private var debounceTask: Task<Void, Never>?
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  /// System notifications being handed to iOS (image download + add), awaited by `flushAndWait()`.
  @ObservationIgnored private var deliveries: [UUID: Task<Void, Never>] = [:]

  private init() {
    let url = Self.fileURL
    if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([MediaNotification].self, from: data) {
      items = stored
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent(fileName)
  }

  /// Posts a notification from any thread (window.dispatchEvent('notification-app')).
  nonisolated static func dispatch(_ notification: MediaNotification) {
    Task { @MainActor in
      AppNotificationsService.shared.queue(notification, systemNotify: AppSettings.shared.values.systemNotify)
    }
  }

  // MARK: - Lifecycle

  /// Installs the notification delegate, asks for permission (systemNotify) and starts the AniList polling.
  func start() {
    UNUserNotificationCenter.current().delegate = delegate
    TsumiNotificationCategory.register()
    if AppSettings.shared.values.systemNotify {
      Task { _ = await requestAuthorization() }
    }
    startPolling()
    updateBadge()
  }

  func requestAuthorization() async -> Bool {
    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    authorizationGranted = granted
    return granted
  }

  func accountChanged() {
    startPolling()
  }

  private func startPolling() {
    pollTask?.cancel()
    guard AccountStore.shared.isAniList else { return }
    pollTask = Task {
      while !Task.isCancelled {
        await checkAniList()
        try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
      }
    }
  }

  /// One refresh pass, e.g. from a BGAppRefreshTask (AniList notifications + schedule announcements).
  func backgroundRefresh() async {
    await checkAniList()
    await AnimeScheduleService.shared.checkForUpdates()
  }

  // MARK: - AniList notifications (findNewNotifications)

  func checkAniList() async {
    let settings = AppSettings.shared.values
    guard settings.aniNotify != "none", AccountStore.shared.isAniList else { return }
    guard let notifications = try? await AniListService.shared.notifications() else { return }
    let lastNotified = ReleaseNotifyStore.shared.lastAni
    let fresh = lastNotified > 0 ? notifications.filter({ $0.createdAt.timeIntervalSince1970 > lastNotified }) : []
    for item in fresh {
      let media = item.media
      guard settings.aniNotify != "limited" || item.type != "AIRING" else { continue }
      guard item.mediaType == "ANIME", media.format != .music else { continue }
      var allowed = !settings.preferDubs
      if !allowed {
        let watching = media.listEntry?.status == .current || media.listEntry?.status == .repeating
        if media.status == .finished && !watching {
          allowed = true
        } else if !(await MALDubsService.shared.isDubMedia(malId: media.malId)) {
          allowed = true
        } else {
          let resolved = await AniListService.shared.requestMedia(id: media.anilistId ?? 0)
          allowed = await AnimeScheduleService.shared.isSubbedProgress(resolved)
        }
      }
      guard allowed else { continue }
      let isMovie = media.format == .movie
      let message: String
      if item.type == "AIRING" {
        message = isMovie
          ? "The Movie (Sub) is out in Japan, if this is a theatrical release it will likely be a few months before it is available for streaming."
          : "Episode \(item.episode ?? 0) (Sub) is out in Japan, it should be available soon."
      } else {
        message = "Was recently announced!"
      }
      let notification = MediaNotification.make(media: media, title: media.title.userPreferred ?? media.title.display(), message: message, episode: item.type == "AIRING" ? item.episode : nil, timestamp: item.createdAt, dub: false, action: item.type == "AIRING" ? .play : .view)
      queue(notification, systemNotify: settings.systemNotify)
    }
    if !fresh.isEmpty || lastNotified <= 1 {
      ReleaseNotifyStore.shared.setLastAni(Date().timeIntervalSince1970)
    }
  }

  // MARK: - Queue (queueNotification / processNotifications)

  func queue(_ notification: MediaNotification, systemNotify: Bool) {
    incoming.append((notification, systemNotify))
    debounceTask?.cancel()
    debounceTask = Task {
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      if Task.isCancelled { return }
      self.processIncoming()
    }
  }

  /// Processes the queue immediately (e.g. before the app goes to background).
  func flush() {
    debounceTask?.cancel()
    processIncoming()
  }

  /// Processes the queue and waits until its system notifications were handed to iOS (background refresh).
  func flushAndWait() async {
    flush()
    let pending = Array(deliveries.values)
    for task in pending {
      await task.value
    }
  }

  private func processIncoming() {
    if incoming.isEmpty { return }
    var seen = Set<String>()
    var unique: [(notification: MediaNotification, system: Bool)] = []
    for entry in incoming where !seen.contains(entry.notification.id) {
      seen.insert(entry.notification.id)
      unique.append(entry)
    }
    incoming.removeAll()
    for entry in unique { add(entry.notification) }
    let system = unique.filter { $0.system }.map { $0.notification }.sorted { $0.timestamp > $1.timestamp }.prefix(20)
    for notification in system { deliver(notification) }
    save()
    updateBadge()
  }

  /// addNotification: replaces delayed / released duplicates, auto read when already watched.
  private func add(_ incoming: MediaNotification) {
    var notification = incoming
    var current = items.filter { existing in
      if notification.delayed {
        return !(existing.mediaId == notification.mediaId && existing.episode == notification.episode && existing.dub && existing.clickAction == .play)
      }
      return !(existing.mediaId == notification.mediaId && existing.episode == notification.episode && existing.delayed)
    }
    current = current.filter { $0.mediaId != notification.mediaId || $0.episode != notification.episode || $0.dub != notification.dub }
    if let episode = notification.episode, let media = MediaStore.shared.media(notification.mediaKey) {
      let target = notification.season == nil ? episode : (media.episodes ?? episode)
      if media.listEntry?.status == .completed || (media.listEntry?.progress ?? -1) >= target {
        notification.read = true
      }
    }
    items = Self.sorted([notification] + current)
  }

  private static func sorted(_ list: [MediaNotification]) -> [MediaNotification] {
    let byDate = list.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
      if lhs.mediaId == rhs.mediaId, let left = lhs.episode, let right = rhs.episode, lhs.season != nil, rhs.season != nil { return left > right }
      return false
    }
    return byDate.filter { !$0.read } + byDate.filter { $0.read }
  }

  // MARK: - Read state

  func markAll(read: Bool) {
    items = items.map { item in
      var copy = item
      copy.read = read
      return copy
    }
    save()
    updateBadge()
  }

  func setRead(_ notification: MediaNotification, read: Bool = true) {
    items = items.map { item in
      var copy = item
      if item.id == notification.id { copy.read = read }
      return copy
    }
    save()
    updateBadge()
  }

  /// 'notification-read': the list progress reached the notified episode.
  func markRead(mediaId: Int?, episode: Int?, episodes: Int?) {
    guard let mediaId, let episode else { return }
    var changed = false
    items = items.map { item in
      var copy = item
      if item.mediaId == mediaId, !item.read {
        let reached = (item.episode.map { episode >= $0 } ?? false) || (item.season != nil && episode >= (episodes ?? Int.max))
        if reached {
          copy.read = true
          changed = true
        }
      }
      return copy
    }
    if changed {
      save()
      updateBadge()
    }
  }

  /// markWatchedAsRead: run when the notification list is opened.
  func markWatchedAsRead() async {
    var updates = Set<String>()
    let authorized = AccountStore.shared.isAuthorized
    for notification in items where !notification.read {
      let announcement = notification.clickAction == .view && !notification.delayed
      if announcement || notification.delayed { continue }
      guard let episode = notification.episode else { continue }
      var media = MediaStore.shared.media(notification.mediaKey)
      if media == nil, notification.mediaKey.hasPrefix("al-") {
        media = await AniListService.shared.requestMedia(id: notification.mediaId)
      }
      let progress = media?.listEntry?.progress
      let status = media?.listEntry?.status
      let notWatching = (progress ?? 0) == 0
      let target = notification.season == nil ? episode : (media?.episodes ?? episode)
      let behind = authorized && episode - 1 >= 1 && status != .completed && (progress ?? -1) < target - 1
      let watched = !notWatching && !behind && (status == .completed || (progress ?? -1) >= target)
      if watched { updates.insert(notification.id) }
    }
    guard !updates.isEmpty else { return }
    items = Self.sorted(items.map { item in
      var copy = item
      if updates.contains(item.id) { copy.read = true }
      return copy
    })
    save()
    updateBadge()
  }

  /// Search box of the notifications modal.
  func filtered(_ text: String) -> [MediaNotification] {
    guard !text.isEmpty else { return items }
    return items.filter { notification in
      if ServiceText.matchKeys([notification.title], phrase: text) { return true }
      guard let media = MediaStore.shared.media(notification.mediaKey) else { return false }
      return ServiceText.matchKeys(media.title.all + media.synonyms, phrase: text)
    }
  }

  /// cache.resetNotifications: clears the list and the bookkeeping.
  func reset() {
    items = []
    incoming.removeAll()
    ReleaseNotifyStore.shared.reset()
    save()
    updateBadge()
  }

  // MARK: - Delivery

  private func deliver(_ notification: MediaNotification) {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.message
    content.sound = .default
    content.threadIdentifier = notification.mediaKey
    content.categoryIdentifier = Self.category(for: notification)
    if let link = notification.deepLink?.absoluteString {
      var info: [String: Any] = ["url": link, "mediaKey": notification.mediaKey]
      if let watch = Self.watchLink(for: notification) { info["watchURL"] = watch.absoluteString }
      content.userInfo = info
    }
    let identifier = notification.id
    // app.js attachments: heroImg || iconXL || icon.
    let imageURL = notification.heroImage ?? notification.iconXL ?? notification.icon
    let token = UUID()
    deliveries[token] = Task {
      if let imageURL, let attachment = await Self.attachment(from: imageURL, identifier: identifier) {
        content.attachments = [attachment]
      }
      let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
      try? await UNUserNotificationCenter.current().add(request)
      self.deliveries[token] = nil
    }
  }

  /// tsumi://search/<id> (play) for AniList episodes; nil for announcements and other sources.
  private static func watchLink(for notification: MediaNotification) -> URL? {
    guard notification.clickAction == .play, !notification.delayed, notification.episode != nil,
          notification.mediaKey == Media.anilistKey(notification.mediaId) else { return nil }
    return URL(string: "tsumi://search/\(notification.mediaId)")
  }

  /// app.js actionTypeId: "View Anime" only for announcements; otherwise Start Watching (nothing watched
  /// yet), Resume (some progress) or Watch, each with "View Anime".
  private static func category(for notification: MediaNotification) -> String {
    guard watchLink(for: notification) != nil else { return TsumiNotificationCategory.viewAnime }
    let progress = MediaStore.shared.media(notification.mediaKey)?.listEntry?.progress ?? 0
    if progress > 0 { return TsumiNotificationCategory.continueWatching }
    if (notification.episode ?? 0) <= 1 { return TsumiNotificationCategory.startWatching }
    return TsumiNotificationCategory.watchNow
  }

  /// Downloads the cover so that it shows in the system notification.
  private static func attachment(from url: URL, identifier: String) async -> UNNotificationAttachment? {
    guard let result = try? await HTTP.data(url, timeout: 15) else { return nil }
    let data = result.0
    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    do {
      try data.write(to: file)
      return try UNNotificationAttachment(identifier: identifier, url: file, options: nil)
    } catch {
      return nil
    }
  }

  private func updateBadge() {
    let count = unreadCount
    UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
  }

  private func save() {
    let snapshot = items
    let url = Self.fileURL
    saveTask?.cancel()
    saveTask = Task.detached(priority: .utility) {
      if let data = try? JSONEncoder().encode(snapshot) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }
}
