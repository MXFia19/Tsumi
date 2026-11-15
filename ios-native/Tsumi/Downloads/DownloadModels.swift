import Foundation

// Offline downloads (common/modules/downloads/ + electron/src/main/downloads/ of the desktop app).

enum DownloadStatus: String, Codable, Hashable {
  case queued
  case resolving
  case downloading
  case paused
  case completed
  case failed

  /// Counted against "Simultaneous Downloads".
  var isRunning: Bool { self == .resolving || self == .downloading }
  /// Shown under "In Progress".
  var isPending: Bool { self != .completed }
}

enum DownloadKind: String, Codable, Hashable {
  /// Direct file (mp4...), background URLSession download task.
  case file
  /// HLS saved by AVAssetDownloadURLSession (.movpkg).
  case hlsAsset
  /// HLS saved segment by segment (AES-128 streams, whose keys AVFoundation does not keep offline), played back
  /// through the local loopback server.
  case hlsFiles
}

/// Extension + search result + server the download comes from: a fresh link is resolved from it each time the
/// download starts (source links expire).
struct DownloadSource: Codable, Hashable {
  var extensionKey: String
  var extensionName: String?
  var href: String?
  var title: String?
  var serverTitle: String?
}

/// Stream already resolved by the player, used only when a fresh resolution fails shortly after.
struct DownloadSeed: Codable, Hashable {
  var url: URL
  var headers: [String: String]
  var subtitleURL: URL?
  var serverTitle: String?
  var date: Date
}

struct DownloadItem: Codable, Identifiable, Hashable {
  var id: String
  var media: Media
  var episode: EpisodeRef
  var episodeTitle: String?
  var createdAt: Date
  var status: DownloadStatus
  var error: String?
  var kind: DownloadKind?
  var source: DownloadSource?
  var seed: DownloadSeed?
  var attempts: Int = 0
  var bytes: Int64 = 0
  var totalBytes: Int64 = 0
  var progress: Double = 0
  var quality: Int?
  /// File in the item folder: the video (file), "index.m3u8" (hlsFiles).
  var mediaFile: String?
  /// .movpkg path relative to the home directory (hlsAsset; the container path changes between launches).
  var assetPath: String?
  var subtitleFile: String?
  var coverFile: String?
  var sizeOnDisk: Int64?
  var completedAt: Date?
  /// hlsFiles: segment list of the playlist the saved segments come from.
  var hlsSignature: String?
  var segmentsTotal: Int?
  var segmentsDone: Int?
  /// AVAssetDownloadTask failed: the next attempt saves the HLS segment by segment.
  var preferFiles: Bool = false
  /// Direct file paused with URLSession resume data (stored next to the file, not in the index).
  var hasResumeData: Bool = false

  var displayEpisode: String {
    if let season = episode.season, let local = episode.localEpisode { return "S\(season) E\(local)" }
    return "Episode \(episode.number)"
  }

  enum CodingKeys: String, CodingKey {
    case id, media, episode, episodeTitle, createdAt, status, error, kind, source, seed, attempts, bytes, totalBytes, progress
    case quality, mediaFile, assetPath, subtitleFile, coverFile, sizeOnDisk, completedAt, hlsSignature, segmentsTotal, segmentsDone
    case preferFiles, hasResumeData
  }

  init(id: String, media: Media, episode: EpisodeRef, episodeTitle: String?, source: DownloadSource?, seed: DownloadSeed?) {
    self.id = id
    self.media = media
    self.episode = episode
    self.episodeTitle = episodeTitle
    self.createdAt = Date()
    self.status = .queued
    self.source = source
    self.seed = seed
  }

  /// Tolerant like the settings: a field that can't be read keeps its default.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    media = try container.decode(Media.self, forKey: .media)
    episode = try container.decode(EpisodeRef.self, forKey: .episode)
    episodeTitle = try? container.decodeIfPresent(String.self, forKey: .episodeTitle)
    createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    status = (try? container.decodeIfPresent(DownloadStatus.self, forKey: .status)) ?? .queued
    error = try? container.decodeIfPresent(String.self, forKey: .error)
    kind = try? container.decodeIfPresent(DownloadKind.self, forKey: .kind)
    source = try? container.decodeIfPresent(DownloadSource.self, forKey: .source)
    seed = try? container.decodeIfPresent(DownloadSeed.self, forKey: .seed)
    attempts = (try? container.decodeIfPresent(Int.self, forKey: .attempts)) ?? 0
    bytes = (try? container.decodeIfPresent(Int64.self, forKey: .bytes)) ?? 0
    totalBytes = (try? container.decodeIfPresent(Int64.self, forKey: .totalBytes)) ?? 0
    progress = (try? container.decodeIfPresent(Double.self, forKey: .progress)) ?? 0
    quality = try? container.decodeIfPresent(Int.self, forKey: .quality)
    mediaFile = try? container.decodeIfPresent(String.self, forKey: .mediaFile)
    assetPath = try? container.decodeIfPresent(String.self, forKey: .assetPath)
    subtitleFile = try? container.decodeIfPresent(String.self, forKey: .subtitleFile)
    coverFile = try? container.decodeIfPresent(String.self, forKey: .coverFile)
    sizeOnDisk = try? container.decodeIfPresent(Int64.self, forKey: .sizeOnDisk)
    completedAt = try? container.decodeIfPresent(Date.self, forKey: .completedAt)
    hlsSignature = try? container.decodeIfPresent(String.self, forKey: .hlsSignature)
    segmentsTotal = try? container.decodeIfPresent(Int.self, forKey: .segmentsTotal)
    segmentsDone = try? container.decodeIfPresent(Int.self, forKey: .segmentsDone)
    preferFiles = (try? container.decodeIfPresent(Bool.self, forKey: .preferFiles)) ?? false
    hasResumeData = (try? container.decodeIfPresent(Bool.self, forKey: .hasResumeData)) ?? false
  }
}

/// Error shown on a failed download. `final` ones are not retried automatically (DRM, unsupported format...).
struct DownloadFailure: LocalizedError {
  let message: String
  var final: Bool = false

  init(_ message: String, final: Bool = false) {
    self.message = message
    self.final = final
  }

  var errorDescription: String? { message }
}

/// Download quality setting (Settings > App > Downloads), same values as the desktop app.
enum DownloadQuality {
  static let options: [(value: String, label: String)] = [
    ("highest", "Highest"), ("1080", "1080p"), ("720", "720p"), ("480", "480p"), ("360", "360p"), ("lowest", "Lowest")
  ]
}

enum DownloadNaming {
  /// Stable id of one episode download: media key + season + episode.
  static func id(mediaKey: String, episode: EpisodeRef) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    let media = String(mediaKey.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    let season = episode.season ?? 0
    let number = episode.season != nil ? (episode.localEpisode ?? episode.number) : episode.number
    return "\(media)-s\(season)-e\(number)"
  }

  /// Subtitle file extension from the URL or the first bytes.
  static func subtitleExtension(url: URL, text: String) -> String {
    let fromURL = url.pathExtension.lowercased()
    if ["vtt", "srt", "ass", "ssa"].contains(fromURL) { return fromURL }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    if trimmed.hasPrefix("WEBVTT") { return "vtt" }
    if trimmed.range(of: "[Script Info]", options: .caseInsensitive) != nil { return "ass" }
    return "srt"
  }

  static func videoExtension(url: URL?, mimeType: String?) -> String {
    let mime = (mimeType ?? "").lowercased()
    if mime.contains("matroska") { return "mkv" }
    if mime.contains("webm") { return "webm" }
    let fromURL = url?.pathExtension.lowercased() ?? ""
    if ["mp4", "m4v", "mov", "mkv", "webm"].contains(fromURL) { return fromURL }
    return "mp4"
  }

  static func httpMessage(_ status: Int) -> String {
    switch status {
    case 401, 403: return "The source refused the download (HTTP \(status)). The link may have expired: retry to get a fresh one."
    case 404, 410: return "The source file is gone (HTTP \(status)). Retry to get a fresh link, or pick another source."
    case 429: return "The source is rate limiting downloads (HTTP 429). Try again later."
    default: return "The source answered HTTP \(status)."
    }
  }

  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
  }
}
