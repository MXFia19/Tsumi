import Foundation
import Observation

/// One list progress update waiting to be sent (Settings / Downloads can list them).
struct PendingListUpdate: Identifiable, Hashable {
  var id: String
  var title: String
  var episode: Int
  var date: Date
  /// Failed sends so far.
  var attempts: Int
}

/// List progress made offline (downloaded episodes), or whose update failed: MediaListService.updateAfterWatching is
/// kept until the connection is back, then sent in order (desktop: updateEntryOrQueue in
/// common/modules/downloads/downloads.js). An entry only leaves the queue once it was sent (or after
/// `maxAttempts` failed sends, with an error toast).
///
/// UI: `pendingCount` / `pending` (observable), `retryPending()` and `discardPending()`.
@Observable
@MainActor
final class DownloadProgressQueue {
  static let shared = DownloadProgressQueue()

  private struct Entry: Codable {
    var media: Media
    var episode: Int
    var date: Date
    /// Failed sends (missing in the entries of older versions).
    var attempts: Int?

    var key: String { "\(media.id)-\(episode)-\(date.timeIntervalSince1970)" }
  }

  private static let storageKey = "tsumi.downloads.offlineProgress"
  /// Failed sends after which an update is given up.
  private static let maxAttempts = 5

  /// Updates waiting to be sent, oldest first.
  private(set) var pending: [PendingListUpdate] = []
  var pendingCount: Int { pending.count }

  @ObservationIgnored private var started = false
  @ObservationIgnored private var flushing = false

  private init() {
    refreshPending(load())
  }

  func start() {
    guard !started else { return }
    started = true
    observeConnection()
    flushSoon()
  }

  /// checkCompletion → Helper.updateEntry, or queued while offline. An update that fails online is queued too
  /// (retried when the connection comes back, at the next launch, or with `retryPending()`).
  func updateOrQueue(_ media: Media, episode: Int) async {
    if ShellConnectionMonitor.shared.isOffline {
      enqueue(media, episode: episode)
      return
    }
    if !(await MediaListService.shared.updateAfterWatching(media, episode: episode)) {
      enqueue(media, episode: episode)
    }
  }

  /// Sends the waiting updates now (a "Retry" button).
  func retryPending() async {
    await flush()
  }

  /// Drops every waiting update (a "Discard" button).
  func discardPending() {
    store([])
  }

  private func enqueue(_ media: Media, episode: Int) {
    guard AccountStore.shared.isAuthorized else { return }
    var entries = load().filter { !($0.media.id == media.id && $0.episode <= episode) }
    entries.append(Entry(media: media, episode: episode, date: Date(), attempts: 0))
    store(entries)
  }

  private func observeConnection() {
    withObservationTracking {
      _ = ShellConnectionMonitor.shared.isOffline
    } onChange: {
      Task { @MainActor in
        let queue = DownloadProgressQueue.shared
        queue.flushSoon()
        queue.observeConnection()
      }
    }
  }

  private func flushSoon() {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      await DownloadProgressQueue.shared.flush()
    }
  }

  private func flush() async {
    guard !flushing, !ShellConnectionMonitor.shared.isOffline else { return }
    let entries = load().sorted { $0.date < $1.date }
    guard !entries.isEmpty else { return }
    flushing = true
    defer { flushing = false }
    for entry in entries {
      if ShellConnectionMonitor.shared.isOffline { return }
      // Discarded meanwhile.
      guard load().contains(where: { $0.key == entry.key }) else { continue }
      let sent = await MediaListService.shared.updateAfterWatching(entry.media, episode: entry.episode)
      if sent {
        store(load().filter { $0.key != entry.key })
        continue
      }
      // Kept for the next try; the later updates wait so they are still sent in order.
      let attempts = (entry.attempts ?? 0) + 1
      if attempts >= Self.maxAttempts {
        store(load().filter { $0.key != entry.key })
        ServiceMessages.shared.post(.error, "Failed to Update Progress", "\(AniListService.shared.title(entry.media)): episode \(entry.episode) could not be saved to your list.")
        continue
      }
      store(load().map { candidate in
        var copy = candidate
        if candidate.key == entry.key { copy.attempts = attempts }
        return copy
      })
      return
    }
  }

  private func load() -> [Entry] {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  private func store(_ entries: [Entry]) {
    if entries.isEmpty {
      UserDefaults.standard.removeObject(forKey: Self.storageKey)
    } else if let data = try? JSONEncoder().encode(entries) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
    refreshPending(entries)
  }

  private func refreshPending(_ entries: [Entry]) {
    pending = entries.sorted { $0.date < $1.date }.map { entry in
      PendingListUpdate(id: entry.key, title: entry.media.title.display(), episode: entry.episode, date: entry.date, attempts: entry.attempts ?? 0)
    }
  }
}
