import ActivityKit
import Foundation
import Observation
import UIKit

// Lock screen countdown to the next episode (Live Activity + Dynamic Island, rendered by the TsumiWidgets
// extension). There is no push server, so:
// - an activity can only be started while the app is in the foreground (details button, or the "start
//   automatically" setting when the app is opened / its lists refresh);
// - its stale date is the airing time, so iOS shows "Out now" by itself when the episode airs;
// - the next time the app runs (foreground or background refresh) it ends the aired ones, which iOS then
//   dismisses about an hour after the airing time, and follows rescheduled episodes. A title whose next episode
//   airs soon gets a new countdown the next time the app is in the foreground after that hour (carry-over), since
//   an activity left running could stay "Out now" for hours when the app does not run again.

@MainActor
@Observable
final class LiveCountdownManager {
  static let shared = LiveCountdownManager()

  struct Running: Identifiable, Hashable {
    var id: String
    var mediaId: String
    var title: String
    var episode: Int
    var airingAt: Date
    var autoStarted: Bool
  }

  /// Countdowns on the lock screen (active or stale), soonest first.
  private(set) var running: [Running] = []
  /// At most this many countdowns at once (iOS allows a few per app).
  static let maxRunning = 4

  private static let autoStartedKey = "tsumi.liveCountdown.autoStarted"
  private static let carryOverKey = "tsumi.liveCountdown.carryOver"

  /// Next episode of a countdown the app ended in its "Out now" window, started the next time the app is in the
  /// foreground once that countdown is dismissed.
  private struct CarryOver: Codable {
    var episode: Int
    var airingAt: Date
    /// When the ended countdown leaves the lock screen.
    var startAfter: Date
    var autoStarted: Bool
  }

  private init() {}

  /// Live Activities are allowed for the app (Settings > Tsumi > Live Activities).
  var isEnabled: Bool {
    ActivityAuthorizationInfo().areActivitiesEnabled
  }

  var activeMediaIds: Set<String> {
    Set(running.map { $0.mediaId })
  }

  /// Thumbnails used by the activities (kept by the cover cleanup of the widget snapshot).
  var coverFiles: Set<String> {
    Set(Activity<TsumiCountdownAttributes>.activities.compactMap { $0.attributes.cover })
  }

  func reload() {
    running = Activity<TsumiCountdownAttributes>.activities
      .filter { $0.activityState == .active || $0.activityState == .stale }
      .map { activity in
        Running(id: activity.id, mediaId: activity.attributes.mediaId, title: activity.attributes.title, episode: activity.content.state.episode, airingAt: activity.content.state.airingAt, autoStarted: activity.attributes.autoStarted)
      }
      .sorted { $0.airingAt < $1.airingAt }
  }

  /// Next episode of a title with an airing time (AniList schedule, else the next airing of AniList / TMDB).
  static func nextAiring(for media: Media, now: Date = Date()) -> AiringNode? {
    if let node = AnimeHelpers.nextAiring(MediaStore.shared.extras(for: media).airingSchedule, now: now) { return node }
    if let next = media.nextAiring, next.airingAt > now { return AiringNode(episode: next.episode, airingAt: next.airingAt) }
    return nil
  }

  // MARK: - Details button

  func start(_ media: Media) async {
    let current = MediaStore.shared.media(media.id) ?? media
    guard let next = Self.nextAiring(for: current) else {
      ServiceMessages.shared.post(.warning, "No Upcoming Episode", "\(AniListService.shared.title(current)) has no scheduled episode to count down to.")
      return
    }
    let key = current.id
    var cover: String?
    if let location = await TsumiWidgetBridge.shared.resolveLocation(), let url = current.images.coverLarge ?? current.images.cover {
      let name = TsumiThumbnail.fileName(for: key)
      if await TsumiWidgetCovers.ensure(name, url: url, in: location) { cover = name }
    }
    let attributes = TsumiCountdownAttributes(mediaId: key, title: AniListService.shared.title(current), totalEpisodes: current.episodes, cover: cover, color: current.images.color, link: TsumiWidgetLinks.link(mediaKey: key), autoStarted: false)
    guard await request(attributes, episode: next.episode, airingAt: next.airingAt, quiet: false) else { return }
    if next.airingAt.timeIntervalSinceNow > 8 * 3600 {
      ServiceMessages.shared.post(.warning, "Countdown on Lock Screen", "Episode \(next.episode) airs in \(ServiceText.countdown(next.airingAt.timeIntervalSinceNow)). iOS ends Live Activities after 8 hours, so it may disappear before then: start it again later, or turn on Settings > Widgets > Start Automatically.")
    } else {
      ServiceMessages.shared.post(.success, "Countdown on Lock Screen", "Episode \(next.episode) of \(attributes.title) airs in \(ServiceText.countdown(next.airingAt.timeIntervalSinceNow)).")
    }
  }

  func stop(mediaId: String) async {
    for activity in Activity<TsumiCountdownAttributes>.activities where activity.attributes.mediaId == mediaId {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    var carried = loadCarryOver(now: Date())
    if carried.removeValue(forKey: mediaId) != nil { saveCarryOver(carried) }
    reload()
  }

  func endAll() async {
    for activity in Activity<TsumiCountdownAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    saveCarryOver([:])
    reload()
  }

  /// Starts (or replaces) the countdown of a title. Only works in the foreground.
  @discardableResult
  private func request(_ attributes: TsumiCountdownAttributes, episode: Int, airingAt: Date, quiet: Bool) async -> Bool {
    guard isEnabled else {
      if !quiet {
        ServiceMessages.shared.post(.error, "Live Activities Are Off", "Turn on Live Activities for Tsumi in the iOS Settings app (Settings > Tsumi).")
      }
      return false
    }
    for existing in Activity<TsumiCountdownAttributes>.activities where existing.attributes.mediaId == attributes.mediaId {
      await existing.end(nil, dismissalPolicy: .immediate)
    }
    let state = TsumiCountdownAttributes.ContentState(episode: episode, airingAt: airingAt, isOut: false)
    do {
      _ = try Activity<TsumiCountdownAttributes>.request(attributes: attributes, content: ActivityContent(state: state, staleDate: airingAt), pushType: nil)
      reload()
      return true
    } catch {
      if !quiet {
        ServiceMessages.shared.post(.error, "Couldn't Start the Countdown", error.localizedDescription)
      }
      return false
    }
  }

  // MARK: - Sync (after every widget snapshot)

  /// A countdown whose episode aired moves on to the next episode of the title when that one airs within this time
  /// (iOS keeps a Live Activity for 8 hours, up to 12 on the lock screen).
  static let nextEpisodeHorizon: TimeInterval = 12 * 3600

  /// Ends aired countdowns (or moves them on to the next episode), follows rescheduled episodes, then auto starts the
  /// ones airing soon. Runs after every snapshot, the background refresh included (TsumiWidgetBridge.backgroundRefresh,
  /// called by ShellBackgroundRefresh), so a running countdown follows the schedule while the app is closed.
  func sync(with snapshot: TsumiWidgetSnapshot?) async {
    let now = Date()
    var carried = loadCarryOver(now: now)
    var carriedChanged = false
    for activity in Activity<TsumiCountdownAttributes>.activities {
      guard activity.activityState == .active || activity.activityState == .stale else { continue }
      let state = activity.content.state
      let mediaId = activity.attributes.mediaId
      let rescheduled = snapshot?.airing.first { airing in
        airing.mediaId == mediaId && airing.episode == state.episode && abs(airing.airingAt.timeIntervalSince(state.airingAt)) > 60
      }
      if let rescheduled, rescheduled.airingAt > now {
        var updated = state
        updated.airingAt = rescheduled.airingAt
        updated.isOut = false
        await activity.update(ActivityContent(state: updated, staleDate: rescheduled.airingAt))
      } else if state.airingAt <= now {
        let next = Self.nextAiring(after: state, mediaId: mediaId, in: snapshot, now: now)
        let outEnd = state.airingAt.addingTimeInterval(TsumiWidgetSnapshot.outWindow)
        if let next, now >= outEnd {
          // "Out now" was shown for its window: count down to the next episode.
          let updated = TsumiCountdownAttributes.ContentState(episode: next.episode, airingAt: next.airingAt, isOut: false)
          await activity.update(ActivityContent(state: updated, staleDate: next.airingAt))
        } else {
          // "Out now" window: ended now and dismissed at the end of the window. Left running, it stayed "Out now"
          // until iOS ended it (8-12 hours) whenever the app did not run again (background refresh is
          // opportunistic). A next episode airing soon gets a new countdown the next time the app is in the
          // foreground once this one is dismissed (an activity can only be started in the foreground).
          var out = state
          out.isOut = true
          let dismissAt = max(outEnd, now.addingTimeInterval(10 * 60))
          await activity.end(ActivityContent(state: out, staleDate: nil), dismissalPolicy: .after(dismissAt))
          if let next {
            carried[mediaId] = CarryOver(episode: next.episode, airingAt: next.airingAt, startAfter: dismissAt, autoStarted: activity.attributes.autoStarted)
            carriedChanged = true
          }
        }
      }
    }
    if carriedChanged { saveCarryOver(carried) }
    reload()
    await autoStart(snapshot, now: now)
  }

  /// The title's next episode after the aired one, when it airs within `nextEpisodeHorizon`.
  private static func nextAiring(after state: TsumiCountdownAttributes.ContentState, mediaId: String, in snapshot: TsumiWidgetSnapshot?, now: Date) -> TsumiWidgetAiring? {
    guard let snapshot else { return nil }
    let limit = now.addingTimeInterval(nextEpisodeHorizon)
    return snapshot.airing
      .filter { $0.mediaId == mediaId && $0.episode > state.episode && $0.airingAt > now && $0.airingAt <= limit }
      .min { $0.airingAt < $1.airingAt }
  }

  /// "Start Automatically": followed titles airing within the chosen hours, once per episode (a countdown the
  /// user dismissed is not brought back). Also starts the carried-over next episodes (whatever the setting) once the
  /// ended countdown of their title left the lock screen.
  private func autoStart(_ snapshot: TsumiWidgetSnapshot?, now: Date) async {
    let preferences = TsumiWidgetPreferences.shared.values
    guard let snapshot, UIApplication.shared.applicationState == .active, isEnabled else { return }
    var carried = loadCarryOver(now: now)
    guard preferences.liveActivityAutoStart || !carried.isEmpty else { return }
    let horizon = now.addingTimeInterval(Double(preferences.liveActivityLeadHours) * 3600)
    var started = loadAutoStarted(now: now)
    var active = activeMediaIds
    // Ended countdowns still on the lock screen ("Out now" until their dismissal) are not replaced before then.
    let shown = Set(Activity<TsumiCountdownAttributes>.activities.filter { $0.activityState == .ended }.map { $0.attributes.mediaId })
    var seen = Set<String>()
    var changed = false
    var carriedChanged = false
    for airing in snapshot.airing.sorted(by: { $0.airingAt < $1.airingAt }) where airing.airingAt > now {
      let carry = carried[airing.mediaId].flatMap { $0.episode == airing.episode ? $0 : nil }
      let automatic = preferences.liveActivityAutoStart && airing.airingAt <= horizon
      guard carry != nil || automatic else { continue }
      guard seen.insert(airing.mediaId).inserted, !active.contains(airing.mediaId), !shown.contains(airing.mediaId) else { continue }
      if let carry, carry.startAfter > now, !automatic { continue }
      let key = "\(airing.mediaId)|\(airing.episode)"
      guard started[key] == nil else {
        if carry != nil {
          carried[airing.mediaId] = nil
          carriedChanged = true
        }
        continue
      }
      guard active.count < Self.maxRunning else { break }
      let attributes = TsumiCountdownAttributes(mediaId: airing.mediaId, title: airing.title, totalEpisodes: airing.totalEpisodes, cover: airing.cover, color: airing.color, link: airing.link, autoStarted: carry?.autoStarted ?? true)
      if await request(attributes, episode: airing.episode, airingAt: airing.airingAt, quiet: true) {
        started[key] = airing.airingAt.timeIntervalSince1970
        active.insert(airing.mediaId)
        changed = true
        if carry != nil {
          carried[airing.mediaId] = nil
          carriedChanged = true
        }
      }
    }
    if changed {
      UserDefaults.standard.set(started, forKey: Self.autoStartedKey)
    }
    if carriedChanged {
      saveCarryOver(carried)
    }
  }

  /// Carried-over next episodes still to air.
  private func loadCarryOver(now: Date) -> [String: CarryOver] {
    guard let data = UserDefaults.standard.data(forKey: Self.carryOverKey),
          let stored = try? JSONDecoder().decode([String: CarryOver].self, from: data) else { return [:] }
    return stored.filter { $0.value.airingAt > now }
  }

  private func saveCarryOver(_ value: [String: CarryOver]) {
    if value.isEmpty {
      UserDefaults.standard.removeObject(forKey: Self.carryOverKey)
    } else if let data = try? JSONEncoder().encode(value) {
      UserDefaults.standard.set(data, forKey: Self.carryOverKey)
    }
  }

  /// "<mediaId>|<episode>" → airing time of the auto started countdowns (forgotten a day after airing).
  private func loadAutoStarted(now: Date) -> [String: Double] {
    let stored = UserDefaults.standard.dictionary(forKey: Self.autoStartedKey) as? [String: Double] ?? [:]
    let limit = now.addingTimeInterval(-86400).timeIntervalSince1970
    return stored.filter { $0.value > limit }
  }
}
