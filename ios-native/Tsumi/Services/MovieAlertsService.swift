import Foundation
import Observation

// Movie release alerts ("Films à surveiller", same behaviour as the desktop app): the bell of the details of a TMDB
// movie adds it to a persisted list; the list is checked a few seconds after launch, 5 seconds after an alert is
// turned on, every 6 hours while the app runs and in the background refresh, and an in-app + system notification
// is posted when the movie comes out in theaters, then when it comes out on digital (the movie then leaves the list).

/// A watched movie: enough to post the notification and reopen the details without a request.
struct MovieAlertEntry: Codable, Hashable, Identifiable {
  var id: Int { tmdbId }
  var tmdbId: Int
  /// Media key ("tmdb-movie-<id>").
  var mediaKey: String
  var title: String
  var cover: URL?
  var coverLarge: URL?
  var banner: URL?
  /// When the alert was turned on: releases already out that day never fire.
  var addedAt: Date
  /// Release kinds already announced (MovieRelease.Kind raw values: "theatrical", "digital").
  var notified: [String] = []
  /// The movie when the alert was turned on (without its relations, recommendations and cast): the details open
  /// from it when the media store dropped the movie and TMDB does not answer (PC alert `media` snapshot). Optional so
  /// that entries stored without it still decode.
  var media: Media? = nil

  func wasNotified(_ kind: MovieRelease.Kind) -> Bool {
    notified.contains(kind.rawValue)
  }

  /// Same alert: same movie turned on at the same time. An alert turned off and on again during a check is another
  /// alert, which never gets the result computed for the old one.
  func isSameAlert(_ other: MovieAlertEntry) -> Bool {
    tmdbId == other.tmdbId && addedAt == other.addedAt
  }
}

/// Pure rules of the release alerts (no state, no network), kept apart so they are easy to reason about. Same rules
/// as PC common/modules/schedule/moviealerts.js (dueRelease).
enum MovieAlertRules {
  /// Alerts still waiting after this many days are dropped (a digital release that never got a date), like PC
  /// ALERT_RETENTION_DAYS.
  static let retentionDays = 548

  struct Decision: Equatable {
    /// Release to announce now, nil for none.
    var notify: MovieRelease.Kind?
    /// Release kinds to mark as announced.
    var markNotified: [MovieRelease.Kind] = []
    /// The entry leaves the list (done: digital release announced, movie already on digital when the alert was
    /// turned on, or alert too old).
    var remove = false
  }

  /// What to do with one watched movie (PC dueRelease). A release is due when its day (local midnight) has come, it
  /// was not announced yet and it is not before the day the alert was turned on (a release already out then never
  /// fires). Both due at once: only the digital release is announced, both are marked. The release to announce is
  /// decided first; the alert is then done when the digital release is announced, when the movie was already on
  /// digital the day the alert was turned on (a theatrical release due at the same time is still announced), or
  /// after `retentionDays`.
  static func decide(_ entry: MovieAlertEntry, theatrical: String?, digital: String?, now: Date, calendar: Calendar) -> Decision {
    let addedDay = calendar.startOfDay(for: entry.addedAt)
    let theatricalDay = theatrical.flatMap { MovieReleases.releaseDay($0, calendar: calendar) }
    let digitalDay = digital.flatMap { MovieReleases.releaseDay($0, calendar: calendar) }
    func due(_ kind: MovieRelease.Kind, _ day: Date?) -> Bool {
      guard !entry.wasNotified(kind), let day else { return false }
      return day <= now && day >= addedDay
    }
    let notify: MovieRelease.Kind?
    if due(.digital, digitalDay) {
      notify = .digital
    } else if due(.theatrical, theatricalDay) {
      notify = .theatrical
    } else {
      notify = nil
    }
    let markNotified: [MovieRelease.Kind] = notify == .digital ? [.theatrical, .digital] : (notify.map { [$0] } ?? [])
    let digitalAnnounced = notify == .digital || entry.wasNotified(.digital)
    let digitalBeforeAdded = digitalDay.map { $0 < addedDay } ?? false
    let expired = now.timeIntervalSince(addedDay) > Double(retentionDays) * 86_400
    return Decision(notify: notify, markNotified: markNotified, remove: digitalAnnounced || digitalBeforeAdded || expired)
  }

  /// "Out in theaters today!" / "In theaters since Nov 18" / "Out on digital today!" / "On digital since Jan 5".
  static func message(_ kind: MovieRelease.Kind, day: Date, now: Date, calendar: Calendar) -> String {
    let today = calendar.isDate(day, inSameDayAs: now)
    switch kind {
    case .theatrical:
      return today ? "Out in theaters today!" : "In theaters since \(shortDate(day, calendar: calendar))"
    case .digital:
      return today ? "Out on digital today!" : "On digital since \(shortDate(day, calendar: calendar))"
    }
  }

  /// The details bell is offered while the digital release is not past (a digital day before today hides it).
  static func digitalReleasePassed(_ days: MovieReleaseDays, now: Date, calendar: Calendar) -> Bool {
    guard let digital = days.digital, let day = MovieReleases.releaseDay(digital, calendar: calendar) else { return false }
    return day < calendar.startOfDay(for: now)
  }

  /// "In theaters Nov 18 · Digital Jan 5": the releases still to come (today included), nil when none is known.
  static func upcomingText(_ days: MovieReleaseDays, now: Date, calendar: Calendar) -> String? {
    let today = calendar.startOfDay(for: now)
    var parts: [String] = []
    for kind in MovieRelease.Kind.allCases {
      guard let value = days.day(kind), let day = MovieReleases.releaseDay(value, calendar: calendar), day >= today else { continue }
      let when = calendar.isDate(day, inSameDayAs: today) ? "today" : shortDate(day, calendar: calendar)
      parts.append("\(kind == .theatrical ? "In theaters" : "Digital") \(when)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "Nov 18" (English, like the rest of the interface).
  static func shortDate(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }
}

/// The watched movies (persisted in UserDefaults like ReleaseNotifyStore) and their release checks.
@MainActor
@Observable
final class MovieAlertsService {
  static let shared = MovieAlertsService()
  private static let storageKey = "tsumi.services.movieAlerts"
  /// Time between two checks while the app runs.
  static let checkInterval: TimeInterval = 6 * 3600

  private(set) var entries: [MovieAlertEntry] = []

  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var runningCheck: Task<Void, Never>?
  @ObservationIgnored private var addCheck: Task<Void, Never>?
  @ObservationIgnored private var lastCheck: Date?

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
       let stored = try? JSONDecoder().decode([SettingsLossyItem<MovieAlertEntry>].self, from: data) {
      // One unreadable entry does not empty the list.
      entries = stored.compactMap { $0.value }
    }
  }

  /// TMDB movies only (not AniList anime, not shows).
  static func supports(_ media: Media) -> Bool {
    media.source == .tmdb && media.tmdbType == .movie && media.tmdbId != nil
  }

  func isWatched(_ tmdbId: Int) -> Bool {
    entries.contains { $0.tmdbId == tmdbId }
  }

  func isWatched(_ media: Media) -> Bool {
    guard Self.supports(media), let tmdbId = media.tmdbId else { return false }
    return isWatched(tmdbId)
  }

  /// Turns the alert of `media` on, then checks 5 seconds later (debounced) so that a movie out today is announced
  /// at once instead of at the next 6 hour check.
  func add(_ media: Media) {
    guard Self.supports(media), let tmdbId = media.tmdbId, !isWatched(tmdbId) else { return }
    // What the details need to open again (PC snapshot): the heavy detail lists are loaded again when they open.
    var snapshot = media
    snapshot.relations = []
    snapshot.recommendations = []
    snapshot.characters = []
    snapshot.staff = []
    let entry = MovieAlertEntry(
      tmdbId: tmdbId,
      mediaKey: media.id,
      title: AniListService.shared.title(media),
      cover: media.images.cover,
      coverLarge: media.images.coverLarge,
      banner: media.images.banner,
      addedAt: Date(),
      notified: [],
      media: snapshot
    )
    entries.append(entry)
    save()
    addCheck?.cancel()
    addCheck = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      if Task.isCancelled { return }
      // A check already running is awaited; it also covers the entries added while it runs (runCheck).
      await MovieAlertsService.shared.check()
    }
  }

  /// Turns the alert of a movie off.
  func remove(tmdbId: Int) {
    let before = entries.count
    entries.removeAll { $0.tmdbId == tmdbId }
    if entries.count != before { save() }
  }

  /// Reset Notifications: the alerts live with the notification bookkeeping (PC 'notification-reset').
  func removeAll() {
    addCheck?.cancel()
    addCheck = nil
    guard !entries.isEmpty else { return }
    entries = []
    save()
  }

  /// Media of a TMDB movie for the details (PC movieMedia): the stored one, else the snapshot kept by its alert,
  /// else TMDB. Nil when none answers.
  func movieMedia(tmdbId: Int) async -> Media? {
    if let stored = MediaStore.shared.media(Media.tmdbKey(tmdbId, .movie)) { return stored }
    if let snapshot = entries.first(where: { $0.tmdbId == tmdbId })?.media { return snapshot }
    return await TMDBService.shared.media(id: tmdbId, type: .movie)
  }

  /// Release days of a movie (cached /movie/{id}/release_dates request, 12 hours).
  func releaseDays(movieId: Int, regions: [String] = MovieReleases.regions) async -> MovieReleaseDays {
    let countries = await TMDBService.shared.releaseDates(movieId: movieId)
    return MovieReleases.days(countries, regions: regions)
  }

  // MARK: - Checks

  /// First check a few seconds after launch, then every 6 hours while the app runs. Idempotent.
  func start() {
    guard loopTask == nil else { return }
    loopTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      while !Task.isCancelled {
        await MovieAlertsService.shared.check()
        try? await Task.sleep(nanoseconds: UInt64(MovieAlertsService.checkInterval * 1_000_000_000))
      }
    }
  }

  /// Back to the foreground: checks when the last check is older than the interval (the loop does not run while
  /// the app is suspended).
  func checkIfStale() {
    guard let lastCheck, Date().timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
    Task { @MainActor in
      await MovieAlertsService.shared.check()
    }
  }

  /// Checks every watched movie and queues the due notifications. A check already running is awaited instead of
  /// starting a second one (launch loop, background refresh and the check after `add` at the same time).
  func check() async {
    if let runningCheck {
      await runningCheck.value
      return
    }
    let task = Task { @MainActor in
      await MovieAlertsService.shared.runCheck()
    }
    runningCheck = task
    await task.value
    runningCheck = nil
  }

  private func runCheck() async {
    lastCheck = Date()
    guard !entries.isEmpty else { return }
    let calendar = ServiceDates.gregorian
    let regions = MovieReleases.regions
    // Every alert once, including the ones turned on while this check awaits its requests (a check started by `add`
    // only awaits this one, so the new alert must not be left for the next 6 hour check). An alert is the movie and
    // the time it was turned on, so an alert turned off and on again meanwhile is checked as a new one.
    var checked: [MovieAlertEntry] = []
    while let snapshot = entries.first(where: { entry in !checked.contains(where: { $0.isSameAlert(entry) }) }) {
      checked.append(snapshot)
      let days = await releaseDays(movieId: snapshot.tmdbId, regions: regions)
      // The alert may have been turned off (or off and on again) during the request: only the same alert gets this
      // result, with its current state.
      guard let entry = entries.first(where: { $0.isSameAlert(snapshot) }) else { continue }
      let now = Date()
      let decision = MovieAlertRules.decide(entry, theatrical: days.theatrical, digital: days.digital, now: now, calendar: calendar)
      if let kind = decision.notify, let value = days.day(kind), let day = MovieReleases.releaseDay(value, calendar: calendar) {
        // Stored (in-app list written) before the alert is saved as announced: a quit right after loses nothing.
        post(entry, kind: kind, message: MovieAlertRules.message(kind, day: day, now: now, calendar: calendar), now: now)
      }
      if apply(decision, to: entry) { save() }
    }
  }

  /// Returns true when the list changed.
  private func apply(_ decision: MovieAlertRules.Decision, to alert: MovieAlertEntry) -> Bool {
    guard let index = entries.firstIndex(where: { $0.isSameAlert(alert) }) else { return false }
    if decision.remove {
      entries.remove(at: index)
      return true
    }
    var changed = false
    for kind in decision.markNotified where !entries[index].notified.contains(kind.rawValue) {
      entries[index].notified.append(kind.rawValue)
      changed = true
    }
    return changed
  }

  /// In-app + system notification (system when systemNotify is on), stored at once (no queue debounce) so that it is
  /// written before the alert is saved as announced. Its own identity (media key + release kind) keeps it apart
  /// from every other notification.
  private func post(_ entry: MovieAlertEntry, kind: MovieRelease.Kind, message: String, now: Date) {
    let notification = MediaNotification(
      mediaId: entry.tmdbId,
      mediaKey: entry.mediaKey,
      title: entry.title,
      message: message,
      icon: entry.cover ?? entry.coverLarge,
      iconXL: entry.coverLarge ?? entry.cover,
      heroImage: entry.banner,
      episode: nil,
      season: nil,
      timestamp: now,
      format: MediaFormat.movie.rawValue,
      dub: false,
      delayed: false,
      clickAction: .view,
      read: false,
      release: kind.rawValue
    )
    AppNotificationsService.shared.addNow(notification, systemNotify: AppSettings.shared.values.systemNotify)
  }

  private func save() {
    if let data = try? JSONEncoder().encode(entries) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
