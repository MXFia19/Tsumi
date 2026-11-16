import Foundation
import AVFoundation

/// Where downloads are saved: Library/Application Support/Downloads/<id>/ (excluded from iCloud backup), plus the
/// .movpkg packages of AVAssetDownloadURLSession (stored by the system, referenced relative to the home folder).
/// Thread-safe: also used by the session delegate and the loopback server.
enum DownloadStorage {
  static var root: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let url = base.appendingPathComponent("Downloads", isDirectory: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      excludeFromBackup(url)
    }
    return url
  }

  static var indexURL: URL { root.appendingPathComponent("index.json") }

  static func folder(_ id: String) -> URL {
    root.appendingPathComponent(id, isDirectory: true)
  }

  static func ensureFolder(_ id: String) throws -> URL {
    let url = folder(id)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Folder of a download that still exists. The folder is created before any transfer starts and deleted when
  /// the download is removed, so a transfer landing after a cancel must not create it again (orphan folder).
  static func existingFolder(_ id: String) -> URL? {
    let url = folder(id)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
    return url
  }

  /// File of a download, nil for a path outside its folder or a missing file.
  static func fileURL(id: String, file: String) -> URL? {
    let invalid: (String) -> Bool = { $0.isEmpty || $0.contains("/") || $0.contains("\\") || $0 == "." || $0 == ".." }
    guard !invalid(id), !invalid(file) else { return nil }
    let url = folder(id).appendingPathComponent(file)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  static func homeURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
  }

  static func relativeToHome(_ url: URL) -> String? {
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(home) else { return nil }
    return String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  /// Startup sweep of DownloadCenter: deletes the item folders whose id is not in `ids` and, with `packages`, the
  /// .movpkg packages of AVAssetDownloadURLSession (Library/com.apple.UserManagedAssets.*) no download references.
  static func removeOrphans(keeping ids: Set<String>, assetPaths: Set<String>, packages: Bool) {
    let fileManager = FileManager.default
    let rootURL = root
    for name in (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) ?? [] where !ids.contains(name) {
      let url = rootURL.appendingPathComponent(name, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
      try? fileManager.removeItem(at: url)
    }
    guard packages else { return }
    // Matched by relative path and by package name (the container path may be written differently).
    let referencedNames = Set(assetPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
    let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
    for container in (try? fileManager.contentsOfDirectory(atPath: library.path)) ?? [] where container.hasPrefix("com.apple.UserManagedAssets") {
      let folder = library.appendingPathComponent(container, isDirectory: true)
      for entry in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where entry.lowercased().hasSuffix(".movpkg") {
        let url = folder.appendingPathComponent(entry)
        if referencedNames.contains(entry) { continue }
        if let relative = relativeToHome(url), assetPaths.contains(relative) { continue }
        try? fileManager.removeItem(at: url)
      }
    }
  }

  static func excludeFromBackup(_ url: URL) {
    var target = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? target.setResourceValues(values)
  }

  /// Size of a file or folder (recursive).
  static func size(of url: URL) -> Int64 {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
      return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total: Int64 = 0
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
      for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
      }
    }
    return total
  }
}

/// Task description of the file session: "<id>|<file>|<start>-<end>" (range only for byte range segments).
/// "@video" is the direct video file, named once its type is known.
struct DownloadTaskTag {
  static let videoFile = "@video"

  var id: String
  var file: String
  var range: ClosedRange<Int64>?

  init(id: String, file: String, range: ClosedRange<Int64>? = nil) {
    self.id = id
    self.file = file
    self.range = range
  }

  init?(_ description: String?) {
    guard let parts = description?.components(separatedBy: "|"), parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    id = parts[0]
    file = parts[1]
    range = nil
    if parts.count > 2 {
      let bounds = parts[2].split(separator: "-").compactMap { Int64($0) }
      if bounds.count == 2, bounds[1] >= bounds[0] { range = bounds[0]...bounds[1] }
    }
  }

  var description: String {
    var text = "\(id)|\(file)"
    if let range { text += "|\(range.lowerBound)-\(range.upperBound)" }
    return text
  }
}

/// Result of a finished file task, handed from the delegate queue to the download center.
struct DownloadTaskResult {
  var tag: DownloadTaskTag
  var taskIdentifier: Int
  /// Final file name (the direct video gets its extension here).
  var savedFile: String?
  var status: Int?
  var error: Error?
  var resumeData: Data?
  var cancelled: Bool
}

/// Delegate of both background sessions. File moves happen here (the temporary file is gone once the callback
/// returns); everything else is forwarded to DownloadCenter on the main actor.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, @unchecked Sendable {
  private let saved = ServiceLocked<[Int: String]>([:])
  private let assetLocations = ServiceLocked<[Int: URL]>([:])

  // MARK: Files

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let tag = DownloadTaskTag(downloadTask.taskDescription) else { return }
    let response = downloadTask.response as? HTTPURLResponse
    let status = response?.statusCode ?? 200
    guard (200..<300).contains(status) else { return }
    var file = tag.file
    if file == DownloadTaskTag.videoFile {
      file = "video." + DownloadNaming.videoExtension(url: response?.url ?? downloadTask.originalRequest?.url, mimeType: response?.mimeType)
    }
    // Removed (cancelled) download: the file is dropped instead of recreating the folder.
    guard let folder = DownloadStorage.existingFolder(tag.id) else { return }
    do {
      let destination = folder.appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
      if let range = tag.range, status == 200 {
        // The server ignored Range and sent the whole file: keep the requested bytes.
        let data = try Data(contentsOf: location, options: .mappedIfSafe)
        let upper = min(Int(range.upperBound) + 1, data.count)
        let lower = min(Int(range.lowerBound), upper)
        try data.subdata(in: lower..<upper).write(to: destination)
      } else {
        try FileManager.default.moveItem(at: location, to: destination)
      }
      saved.update { $0[downloadTask.taskIdentifier] = file }
    } catch {
      // Reported as a failure in didCompleteWithError (no saved file).
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let tag = DownloadTaskTag(downloadTask.taskDescription), tag.file == DownloadTaskTag.videoFile else { return }
    let id = tag.id
    Task { @MainActor in
      DownloadCenter.shared.fileProgress(id: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let assetTask = task as? AVAssetDownloadTask {
      let location = assetLocations.update { $0.removeValue(forKey: assetTask.taskIdentifier) }
      let id = assetTask.taskDescription ?? ""
      let taskIdentifier = assetTask.taskIdentifier
      let relative = location.flatMap { DownloadStorage.relativeToHome($0) }
      let cancelled = (error as? URLError)?.code == .cancelled
      Task { @MainActor in
        DownloadCenter.shared.assetCompleted(id: id, taskIdentifier: taskIdentifier, relativePath: relative, error: error, cancelled: cancelled)
      }
      return
    }
    guard let tag = DownloadTaskTag(task.taskDescription) else { return }
    let file = saved.update { $0.removeValue(forKey: task.taskIdentifier) }
    let status = (task.response as? HTTPURLResponse)?.statusCode
    let nsError = error as NSError?
    let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let cancelled = (error as? URLError)?.code == .cancelled
    let result = DownloadTaskResult(tag: tag, taskIdentifier: task.taskIdentifier, savedFile: file, status: status, error: error, resumeData: resumeData, cancelled: cancelled)
    Task { @MainActor in
      DownloadCenter.shared.fileTaskCompleted(result)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let identifier = session.configuration.identifier ?? ""
    Task { @MainActor in
      DownloadCenter.shared.backgroundEventsFinished(identifier)
    }
  }

  // MARK: HLS (AVAssetDownloadURLSession)

  func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
    assetLocations.update { $0[assetDownloadTask.taskIdentifier] = location }
  }

  func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
    let expected = timeRangeExpectedToLoad.duration.seconds
    guard expected.isFinite, expected > 0 else { return }
    let loaded = loadedTimeRanges.reduce(0.0) { total, value in
      let seconds = value.timeRangeValue.duration.seconds
      return total + (seconds.isFinite ? seconds : 0)
    }
    let id = assetDownloadTask.taskDescription ?? ""
    let progress = min(max(loaded / expected, 0), 1)
    Task { @MainActor in
      DownloadCenter.shared.assetProgress(id: id, progress: progress)
    }
  }
}
