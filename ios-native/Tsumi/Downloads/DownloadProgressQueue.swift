import Foundation
import Observation

/// List progress made offline (downloaded episodes): MediaListService.updateAfterWatching is kept until the
/// connection is back, then sent in order (desktop: updateEntryOrQueue in common/modules/downloads/downloads.js).
@MainActor
final class DownloadProgressQueue {
  static let shared = DownloadProgressQueue()

  private struct Entry: Codable {
    var media: Media
    var episode: Int
    var date: Date
  }

  private static let storageKey = "tsumi.downloads.offlineProgress"
  private var started = false
  private var flushing = false

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    observeConnection()
    flushSoon()
  }

  /// checkCompletion → Helper.updateEntry, or queued while offline.
  func updateOrQueue(_ media: Media, episode: Int) async {
    if ShellConnectionMonitor.shared.isOffline {
      guard AccountStore.shared.isAuthorized else { return }
      var entries = load().filter { !($0.media.id == media.id && $0.episode <= episode) }
      entries.append(Entry(media: media, episode: episode, date: Date()))
      store(entries)
      return
    }
    await MediaListService.shared.updateAfterWatching(media, episode: episode)
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
      await MediaListService.shared.updateAfterWatching(entry.media, episode: entry.episode)
      store(load().filter { !($0.media.id == entry.media.id && $0.episode == entry.episode && $0.date == entry.date) })
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
  }
}
