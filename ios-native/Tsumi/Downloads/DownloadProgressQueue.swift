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
/// Each entry belongs to the account that watched the episode: it is only sent while that account is the current
/// one (after a profile switch it waits until the account is back), and it is dropped when that account signs out.
///
/// UI: `pendingCount` / `pending` (observable, the current account's updates), `retryPending()` and
/// `discardPending()`.
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
    /// AccountProfile.id of the account the update belongs to. Missing in the entries of older versions: those
    /// belong to the account current when they are first seen (`claimLegacyEntries`).
    var account: String?

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
    // A profile switch shows that account's waiting updates and sends them.
    NotificationCenter.default.addObserver(forName: AccountStore.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.accountsChanged()
      }
    }
  }

  func start() {
    guard !started else { return }
    started = true
    claimLegacyEntries()
    observeConnection()
    flushSoon()
  }

  /// checkCompletion → Helper.updateEntry, or queued while offline. An update that fails online is queued too
  /// (retried when the connection comes back, at the next launch, or with `retryPending()`).
  func updateOrQueue(_ media: Media, episode: Int) async {
    // A Sora module result played as it is has no list entry: never sent, never queued.
    guard !media.isSoraResult else { return }
    // The account the episode was watched with, even if another profile is chosen while the update runs.
    let account = AccountStore.shared.current?.id
    if ShellConnectionMonitor.shared.isOffline {
      enqueue(media, episode: episode, account: account)
      return
    }
    if !(await MediaListService.shared.updateAfterWatching(media, episode: episode)) {
      enqueue(media, episode: episode, account: account)
    }
  }

  /// Sends the waiting updates now (a "Retry" button).
  func retryPending() async {
    await flush()
  }

  /// Drops the waiting updates of the current account (a "Discard" button: the ones `pending` lists).
  func discardPending() {
    let account = AccountStore.shared.current?.id
    store(load().filter { !Self.isListed($0, account: account) })
  }

  /// An account signed out (ProfilesService): its waiting updates can no longer be sent.
  func dropAccount(_ id: String) {
    let entries = load()
    let kept = entries.filter { $0.account != id }
    if kept.count != entries.count { store(kept) }
  }

  private func enqueue(_ media: Media, episode: Int, account: String?) {
    guard let account else { return }
    claimLegacyEntries()
    var entries = load().filter { !($0.account == account && $0.media.id == media.id && $0.episode <= episode) }
    entries.append(Entry(media: media, episode: episode, date: Date(), attempts: 0, account: account))
    store(entries)
  }

  /// Entries of older versions carry no account: they are given to the current one, which the queue used to send
  /// them for, so that a later profile switch no longer moves them to another list.
  private func claimLegacyEntries() {
    guard let account = AccountStore.shared.current?.id else { return }
    let entries = load()
    guard entries.contains(where: { $0.account == nil }) else { return }
    store(entries.map { entry in
      var copy = entry
      if copy.account == nil { copy.account = account }
      return copy
    })
  }

  private func accountsChanged() {
    refreshPending(load())
    if started { flushSoon() }
  }

  /// Listed in `pending` (and sent): the updates of `account`, and those not yet given to an account.
  private static func isListed(_ entry: Entry, account: String?) -> Bool {
    entry.account == nil || entry.account == account
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
    guard !flushing, !ShellConnectionMonitor.shared.isOffline, let account = AccountStore.shared.current?.id else { return }
    claimLegacyEntries()
    // Only the current account's updates: updateAfterWatching writes to the current account's list.
    let entries = load().filter { $0.account == account }.sorted { $0.date < $1.date }
    guard !entries.isEmpty else { return }
    flushing = true
    defer { flushing = false }
    for entry in entries {
      if ShellConnectionMonitor.shared.isOffline { return }
      // Another profile was chosen meanwhile: the rest waits for this account, the new one's updates are sent next.
      guard AccountStore.shared.current?.id == account else {
        flushSoon()
        return
      }
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
    let account = AccountStore.shared.current?.id
    pending = entries.filter { Self.isListed($0, account: account) }.sorted { $0.date < $1.date }.map { entry in
      PendingListUpdate(id: entry.key, title: entry.media.title.display(), episode: entry.episode, date: entry.date, attempts: entry.attempts ?? 0)
    }
  }
}
