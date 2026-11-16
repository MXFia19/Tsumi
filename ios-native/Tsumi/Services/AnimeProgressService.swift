import Foundation
import Observation
import UIKit

// Port of common/modules/anime/animeprogress.js: local playback position per media / episode
// (resume position, progress bars of the episode cards and lists).

struct EpisodeProgressRecord: Codable, Hashable {
  /// File / stream name, used when the media is unknown.
  var name: String?
  /// Media.id ("al-123" / "tmdb-tv-456").
  var mediaKey: String?
  var episode: Int?
  var currentTime: Double
  var safeDuration: Double
  var createdAt: Date
  var updatedAt: Date

  /// Watched percentage (0-100), rounded up as in the Svelte app.
  var percent: Int {
    guard safeDuration > 0, currentTime.isFinite, safeDuration.isFinite else { return 0 }
    return Int(min(100, max(0, (currentTime / safeDuration * 100).rounded(.up))))
  }
}

@Observable
@MainActor
final class AnimeProgressService {
  static let shared = AnimeProgressService()
  /// Where the records lived before they moved to a file (read once, then removed).
  private static let legacyStorageKey = "tsumi.services.animeEpisodeProgress"
  private static let fileName = "tsumi-anime-progress.json"
  /// Records kept (the least recently updated ones go first).
  static let maxRecords = 2000
  /// Positions are written to disk at most this often while playing (and when the app goes to the background).
  private static let saveDelay: UInt64 = 5_000_000_000
  private static let writeQueue = DispatchQueue(label: "org.tsumi.services.animeProgress", qos: .utility)

  private(set) var records: [EpisodeProgressRecord] = []

  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    let url = Self.fileURL
    if let data = try? Data(contentsOf: url),
       let stored = try? JSONDecoder().decode([SettingsLossyItem<EpisodeProgressRecord>].self, from: data) {
      records = Self.capped(stored.compactMap { $0.value })
    } else if let data = UserDefaults.standard.data(forKey: Self.legacyStorageKey),
              let stored = try? JSONDecoder().decode([SettingsLossyItem<EpisodeProgressRecord>].self, from: data) {
      // One-time move out of UserDefaults (the whole list was rewritten there on every progress tick).
      records = Self.capped(stored.compactMap { $0.value })
      if Self.write(records, to: url) {
        UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
      }
    }
    observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        AnimeProgressService.shared.saveNow()
      }
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent(fileName)
  }

  /// liveAnimeProgress: episode -> percent for a media.
  func progress(mediaKey: String) -> [Int: Int] {
    var result: [Int: Int] = [:]
    for record in records where record.mediaKey == mediaKey {
      if let episode = record.episode { result[episode] = record.percent }
    }
    // Cross-device resume: an episode played more recently on another device (PlaybackSyncService).
    if let remote = remotePercent(mediaKey: mediaKey) { result[remote.episode] = remote.percent }
    return result
  }

  /// Position of another device when it is newer than this device's record of that episode.
  private func remotePercent(mediaKey: String) -> (episode: Int, percent: Int)? {
    guard let remote = PlaybackSyncService.shared.remotePositions[mediaKey], remote.watchedPercent > 0 else { return nil }
    let local = records.first { $0.mediaKey == mediaKey && $0.episode == remote.episode }
    if let local, local.updatedAt >= remote.at { return nil }
    return (remote.episode, remote.watchedPercent)
  }

  /// liveAnimeEpisodeProgress: percent of one episode (nil when the episode is completed on the list).
  func episodeProgress(mediaKey: String, episode: Int, completed: Bool = false) -> Int? {
    if completed { return nil }
    if let remote = remotePercent(mediaKey: mediaKey), remote.episode == episode { return remote.percent }
    return records.first { $0.mediaKey == mediaKey && $0.episode == episode }?.percent ?? 0
  }

  /// getAnimeProgress: the most recently updated record by name or by media / episode.
  func record(name: String? = nil, mediaKey: String? = nil, episode: Int? = nil) -> EpisodeProgressRecord? {
    let byName = name.flatMap { value in records.first { $0.name == value } }
    let byId = mediaKey.flatMap { key in records.first { $0.mediaKey == key && $0.episode == episode } }
    if let byName, let byId, byName.updatedAt > byId.updatedAt { return byName }
    return byId ?? byName
  }

  /// setAnimeProgress.
  func set(name: String? = nil, mediaKey: String? = nil, episode: Int?, currentTime: Double, safeDuration: Double) {
    guard name != nil || mediaKey != nil, name != nil || episode != nil, currentTime >= 0, safeDuration > 0 else { return }
    let now = Date()
    if let index = records.firstIndex(where: { mediaKey != nil ? ($0.mediaKey == mediaKey && $0.episode == episode) : $0.name == name }) {
      records[index].currentTime = currentTime
      records[index].safeDuration = safeDuration
      records[index].updatedAt = now
    } else {
      records.append(EpisodeProgressRecord(name: name, mediaKey: mediaKey, episode: episode, currentTime: currentTime, safeDuration: safeDuration, createdAt: now, updatedAt: now))
      if records.count > Self.maxRecords { records = Self.capped(records) }
    }
    scheduleSave()
  }

  /// Settings "Reset Watch History" (cache.resetHistory).
  func reset() {
    records = []
    saveNow()
  }

  /// The `maxRecords` most recently updated records (in their stored order).
  private static func capped(_ list: [EpisodeProgressRecord]) -> [EpisodeProgressRecord] {
    guard list.count > maxRecords else { return list }
    let kept = list.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxRecords)
    let oldest = kept.last?.updatedAt ?? .distantPast
    var result = list.filter { $0.updatedAt > oldest }
    // Records updated at the same instant as the oldest kept one fill the remaining places.
    for record in list where record.updatedAt == oldest && result.count < maxRecords { result.append(record) }
    return result
  }

  private func scheduleSave() {
    guard saveTask == nil else { return }
    saveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: Self.saveDelay)
      if Task.isCancelled { return }
      AnimeProgressService.shared.saveNow()
    }
  }

  private func saveNow() {
    saveTask?.cancel()
    saveTask = nil
    let snapshot = records
    let url = Self.fileURL
    // One serial queue: the writes land in order.
    Self.writeQueue.async {
      AnimeProgressService.write(snapshot, to: url)
    }
  }

  @discardableResult
  nonisolated private static func write(_ records: [EpisodeProgressRecord], to url: URL) -> Bool {
    guard let data = try? JSONEncoder().encode(records) else { return false }
    return (try? data.write(to: url, options: .atomic)) != nil
  }
}
