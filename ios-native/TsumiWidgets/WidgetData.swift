import Foundation
import UIKit

// Data of the widgets: the snapshot written by the app into the shared App Group container, or, when the
// widget is configured with an AniList username (or the install has no usable App Group), the same snapshot
// built here from that user's public AniList list.

/// What a widget entry renders.
struct TsumiWidgetData {
  enum Source: Equatable {
    /// Snapshot written by the app.
    case app
    /// Public list of an AniList user (widget configuration).
    case anilist(String)
    /// Nothing to show (see `message`).
    case none
  }

  var snapshot: TsumiWidgetSnapshot?
  /// Folder of the cover thumbnails named in the snapshot.
  var coversDirectory: URL?
  var source: Source
  /// Shown instead of the content when there is nothing to show.
  var message: String?

  func image(_ name: String?) -> UIImage? {
    guard let name, let coversDirectory else { return nil }
    return UIImage(contentsOfFile: coversDirectory.appendingPathComponent(name).path)
  }

  var isUsernameMode: Bool {
    if case .anilist = source { return true }
    return false
  }

  /// Sample content for the widget gallery and placeholders.
  static var preview: TsumiWidgetData {
    let now = Date()
    let link = TsumiWidgetLinks.openApp
    let shows = [
      TsumiWidgetShow(id: "preview-1", title: "Your Show", progress: 5, total: 12, nextEpisode: 6, upcoming: false, nextEpisodeAiringAt: nil, cover: nil, coverURL: nil, color: "#3a5ba0", link: link),
      TsumiWidgetShow(id: "preview-2", title: "Another Series", progress: 10, total: 24, nextEpisode: 11, upcoming: false, nextEpisodeAiringAt: nil, cover: nil, coverURL: nil, color: "#a03a6b", link: link),
      TsumiWidgetShow(id: "preview-3", title: "Weekly Anime", progress: 3, total: nil, nextEpisode: 4, upcoming: true, nextEpisodeAiringAt: now.addingTimeInterval(2 * 86400), cover: nil, coverURL: nil, color: "#3aa05b", link: link)
    ]
    let airing = [
      TsumiWidgetAiring(mediaId: "preview-3", title: "Weekly Anime", episode: 4, totalEpisodes: 12, airingAt: now.addingTimeInterval(3 * 3600 + 1234), cover: nil, coverURL: nil, color: "#3aa05b", link: link),
      TsumiWidgetAiring(mediaId: "preview-4", title: "Season Two", episode: 8, totalEpisodes: nil, airingAt: now.addingTimeInterval(26 * 3600), cover: nil, coverURL: nil, color: "#a0803a", link: link),
      TsumiWidgetAiring(mediaId: "preview-5", title: "New Premiere", episode: 1, totalEpisodes: 13, airingAt: now.addingTimeInterval(3 * 86400), cover: nil, coverURL: nil, color: "#6b3aa0", link: link)
    ]
    let snapshot = TsumiWidgetSnapshot(generatedAt: now, account: "Preview", service: "anilist", continueWatching: shows, airing: airing)
    return TsumiWidgetData(snapshot: snapshot, coversDirectory: nil, source: .app, message: nil)
  }
}

enum TsumiWidgetDataLoader {
  /// Configuration username (trimmed, nil when empty).
  static func username(_ value: String?) -> String? {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    return name.isEmpty ? nil : name
  }

  static func load(username rawUsername: String?) async -> TsumiWidgetData {
    if let username = Self.username(rawUsername) {
      return await AniListPublicList.load(username: username)
    }
    if let location = TsumiSharedContainer.readableLocation(), let snapshot = TsumiWidgetSnapshot.read(from: location.directory) {
      let message = snapshot.account == nil ? "Sign in to Tsumi (AniList or MyAnimeList) to see your list here." : nil
      return TsumiWidgetData(snapshot: snapshot, coversDirectory: location.coversDirectory, source: .app, message: message)
    }
    if TsumiSharedContainer.accessibleLocations().isEmpty {
      return TsumiWidgetData(snapshot: nil, coversDirectory: nil, source: .none, message: "This install can't share data with widgets. Touch and hold the widget, choose Edit Widget and enter your AniList username.")
    }
    return TsumiWidgetData(snapshot: nil, coversDirectory: nil, source: .none, message: "Open Tsumi once to fill this widget, or edit it and enter your AniList username.")
  }
}

/// Public AniList list of a user (no sign-in needed; private lists cannot be read).
enum AniListPublicList {
  private static let endpoint = URL(string: "https://graphql.anilist.co")
  /// Responses are reused for a while: several widgets reload at the same time.
  private static let freshness: TimeInterval = 10 * 60

  private static let query = """
  query($name: String) {
    MediaListCollection(userName: $name, type: ANIME, status_in: [CURRENT, REPEATING, PLANNING], sort: UPDATED_TIME_DESC) {
      user { name }
      lists {
        entries {
          status
          progress
          media {
            id
            episodes
            status
            title { userPreferred }
            coverImage { large medium color }
            nextAiringEpisode { airingAt episode }
          }
        }
      }
    }
  }
  """

  private struct Cached: Codable {
    var fetchedAt: Date
    var snapshot: TsumiWidgetSnapshot
  }

  private static var cacheDirectory: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("TsumiWidgetsAniList", isDirectory: true)
  }

  private static var coversDirectory: URL {
    cacheDirectory.appendingPathComponent(TsumiWidgetSnapshot.coversFolder, isDirectory: true)
  }

  private static func cacheURL(_ username: String) -> URL {
    let safe = TsumiThumbnail.fileName(for: username.lowercased()).replacingOccurrences(of: ".jpg", with: "")
    return cacheDirectory.appendingPathComponent("list-\(safe).json")
  }

  static func load(username: String) async -> TsumiWidgetData {
    let cached = readCache(username)
    if let cached, Date().timeIntervalSince(cached.fetchedAt) < freshness {
      return data(cached.snapshot, username: username)
    }
    do {
      let snapshot = try await fetch(username: username)
      await downloadCovers(snapshot)
      writeCache(Cached(fetchedAt: Date(), snapshot: snapshot), username: username)
      return data(snapshot, username: username)
    } catch {
      if let cached { return data(cached.snapshot, username: username) }
      let message = (error as? AniListPublicError)?.message ?? "Couldn't reach AniList. The widget will try again later."
      return TsumiWidgetData(snapshot: nil, coversDirectory: nil, source: .anilist(username), message: message)
    }
  }

  private static func data(_ snapshot: TsumiWidgetSnapshot, username: String) -> TsumiWidgetData {
    TsumiWidgetData(snapshot: snapshot, coversDirectory: coversDirectory, source: .anilist(username), message: nil)
  }

  private static func readCache(_ username: String) -> Cached? {
    guard let data = try? Data(contentsOf: cacheURL(username)) else { return nil }
    return try? TsumiWidgetCoding.decoder().decode(Cached.self, from: data)
  }

  private static func writeCache(_ cached: Cached, username: String) {
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    if let data = try? TsumiWidgetCoding.encoder().encode(cached) {
      try? data.write(to: cacheURL(username), options: [.atomic])
    }
  }

  struct AniListPublicError: Error {
    var message: String
  }

  private static func fetch(username: String) async throws -> TsumiWidgetSnapshot {
    guard let endpoint else { throw AniListPublicError(message: "Couldn't reach AniList.") }
    var request = URLRequest(url: endpoint, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let payload: [String: Any] = ["query": query, "variables": ["name": username]]
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (body, _) = try await URLSession.shared.data(for: request)
    guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      throw AniListPublicError(message: "AniList sent an unreadable answer. The widget will try again later.")
    }
    let errors = json["errors"] as? [[String: Any]] ?? []
    let collection = (json["data"] as? [String: Any])?["MediaListCollection"] as? [String: Any]
    guard let collection else {
      let text = (errors.first?["message"] as? String) ?? ""
      if text.localizedCaseInsensitiveContains("private") {
        throw AniListPublicError(message: "\(username)'s AniList list is private. Make it public on AniList, or sign in to Tsumi.")
      }
      if text.localizedCaseInsensitiveContains("not found") || text.localizedCaseInsensitiveContains("invalid") {
        throw AniListPublicError(message: "No AniList user named \(username). Check the username in the widget settings.")
      }
      throw AniListPublicError(message: text.isEmpty ? "AniList didn't return \(username)'s list." : "AniList: \(text)")
    }
    return snapshot(from: collection, username: username, now: Date())
  }

  private static func snapshot(from collection: [String: Any], username: String, now: Date) -> TsumiWidgetSnapshot {
    let name = ((collection["user"] as? [String: Any])?["name"] as? String) ?? username
    var watching: [TsumiWidgetShow] = []
    var airing: [TsumiWidgetAiring] = []
    var seen = Set<Int>()
    let lists = collection["lists"] as? [[String: Any]] ?? []
    var entries: [[String: Any]] = []
    for list in lists {
      entries.append(contentsOf: list["entries"] as? [[String: Any]] ?? [])
    }
    for entry in entries {
      guard let media = entry["media"] as? [String: Any], let id = media["id"] as? Int, !seen.contains(id) else { continue }
      seen.insert(id)
      let status = entry["status"] as? String ?? ""
      let progress = entry["progress"] as? Int ?? 0
      let total = media["episodes"] as? Int
      let mediaStatus = media["status"] as? String ?? ""
      let title = ((media["title"] as? [String: Any])?["userPreferred"] as? String) ?? "Unknown Title"
      let coverImage = media["coverImage"] as? [String: Any]
      let coverURL = (coverImage?["large"] as? String ?? coverImage?["medium"] as? String).flatMap { URL(string: $0) }
      let color = coverImage?["color"] as? String
      let key = "al-\(id)"
      let cover = TsumiThumbnail.fileName(for: key)
      let link = TsumiWidgetLinks.anime(id)
      var nextAiring: (episode: Int, airingAt: Date)?
      if let next = media["nextAiringEpisode"] as? [String: Any], let episode = next["episode"] as? Int, let airingAt = next["airingAt"] as? Double {
        nextAiring = (episode, Date(timeIntervalSince1970: airingAt))
      }
      if let nextAiring {
        airing.append(TsumiWidgetAiring(mediaId: key, title: title, episode: nextAiring.episode, totalEpisodes: total, airingAt: nextAiring.airingAt, cover: cover, coverURL: coverURL, color: color, link: link))
      }
      guard status == "CURRENT" || status == "REPEATING" else { continue }
      if let total, total > 0, progress >= total { continue }
      let nextEpisode = progress + 1
      var upcoming = false
      var nextEpisodeAiringAt: Date?
      if let nextAiring {
        if nextAiring.episode == nextEpisode {
          upcoming = nextAiring.airingAt > now
          nextEpisodeAiringAt = upcoming ? nextAiring.airingAt : nil
        } else if nextAiring.episode < nextEpisode {
          upcoming = true
        }
      } else if mediaStatus == "NOT_YET_RELEASED" {
        upcoming = true
      }
      watching.append(TsumiWidgetShow(id: key, title: title, progress: progress, total: total, nextEpisode: nextEpisode, upcoming: upcoming, nextEpisodeAiringAt: nextEpisodeAiringAt, cover: cover, coverURL: coverURL, color: color, link: link))
    }
    let continueWatching = TsumiWidgetOrdering.continueWatching(watching, now: now)
    airing.sort { $0.airingAt < $1.airingAt }
    return TsumiWidgetSnapshot(generatedAt: now, account: name, service: "anilist", continueWatching: Array(continueWatching.prefix(10)), airing: Array(airing.prefix(30)))
  }

  /// Thumbnails of what the widgets can show (a few per widget), downloaded 4 at a time.
  private static func downloadCovers(_ snapshot: TsumiWidgetSnapshot) async {
    var wanted: [(String, URL)] = []
    var names = Set<String>()
    for show in snapshot.continueWatching.prefix(5) {
      if let cover = show.cover, let url = show.coverURL, names.insert(cover).inserted { wanted.append((cover, url)) }
    }
    for item in snapshot.airing.prefix(6) {
      if let cover = item.cover, let url = item.coverURL, names.insert(cover).inserted { wanted.append((cover, url)) }
    }
    let directory = coversDirectory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var index = 0
    while index < wanted.count {
      let batch = wanted[index..<min(index + 4, wanted.count)]
      await withTaskGroup(of: Void.self) { group in
        for (name, url) in batch {
          group.addTask {
            _ = await TsumiThumbnail.download(url, to: directory.appendingPathComponent(name), maxPixelSize: 240, timeout: 10)
          }
        }
      }
      index += 4
    }
    // Old thumbnails of titles no longer shown.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    if files.count > 60 {
      for file in files where !names.contains(file) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
      }
    }
  }
}
