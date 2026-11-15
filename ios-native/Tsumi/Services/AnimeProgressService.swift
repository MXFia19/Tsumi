import Foundation
import Observation

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
    guard safeDuration > 0 else { return 0 }
    return Int((currentTime / safeDuration * 100).rounded(.up))
  }
}

@Observable
@MainActor
final class AnimeProgressService {
  static let shared = AnimeProgressService()
  private static let storageKey = "tsumi.services.animeEpisodeProgress"

  private(set) var records: [EpisodeProgressRecord] = []

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
       let stored = try? JSONDecoder().decode([EpisodeProgressRecord].self, from: data) {
      records = stored
    }
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
    }
    save()
  }

  /// Settings "Reset Watch History" (cache.resetHistory).
  func reset() {
    records = []
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(records) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
