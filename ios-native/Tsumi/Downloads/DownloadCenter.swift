import Foundation
import AVFoundation
import Observation
import UIKit

/// Offline downloads (desktop: common/modules/downloads/downloads.js + electron/src/main/downloads/manager.js).
/// A fresh stream is resolved with the extensions each time a download starts (source links expire). Direct files
/// use a background URLSession download task (resumable); clear HLS uses AVAssetDownloadURLSession with the variant
/// of the Download Quality setting; AES-128 HLS (keys AVFoundation does not keep offline) is saved segment by
/// segment and played through the loopback server. Subtitles, cover and metadata are saved in the item folder.
@MainActor
@Observable
final class DownloadCenter {
  static let shared = DownloadCenter()

  static let fileSessionID = "org.tsumi.app.downloads.files"
  static let assetSessionID = "org.tsumi.app.downloads.hls"
  /// A stream resolved by the player is used when a fresh resolution fails and it is younger than this.
  private static let seedMaxAge: TimeInterval = 15 * 60
  private static let autoRetries = 2
  private static let segmentRetries = 2
  /// Segment tasks running at once per hlsFiles download while the app is active (hundreds of background tasks
  /// created at once slow the session down). The rest start together when the app goes to the background, so
  /// the system keeps downloading while the app is suspended.
  private static let segmentWindow = 24

  /// Every download, oldest first.
  private(set) var items: [DownloadItem] = []

  @ObservationIgnored private let delegate = DownloadSessionDelegate()
  @ObservationIgnored private var fileSession: URLSession?
  @ObservationIgnored private var assetSession: AVAssetDownloadURLSession?
  @ObservationIgnored private var started = false
  /// Both background sessions reported their running tasks (pump waits for it).
  @ObservationIgnored private var reconnected = 0
  /// Items whose resolution / preparation runs in this process (token of the run, so a paused then resumed
  /// item never continues an older run).
  @ObservationIgnored private var preparing: [String: UUID] = [:]
  @ObservationIgnored private var fileTasks: [String: URLSessionDownloadTask] = [:]
  @ObservationIgnored private var segmentTasks: [String: [Int: URLSessionDownloadTask]] = [:]
  @ObservationIgnored private var assetTasks: [String: AVAssetDownloadTask] = [:]
  @ObservationIgnored private var segmentFailures: [String: Int] = [:]
  /// Request headers of the segment downloads of each item (to retry a segment).
  @ObservationIgnored private var segmentHeaders: [String: [String: String]] = [:]
  @ObservationIgnored private var segmentURLs: [String: [String: (url: URL, range: ClosedRange<Int64>?)]] = [:]
  /// Segments of each hlsFiles download not started yet (see `segmentWindow`).
  @ObservationIgnored private var segmentPending: [String: [HLSResource]] = [:]
  /// Tasks cancelled by this app (pause, remove, replaced task), by task identifier of each session: their
  /// completion is expected. Any other cancelled task was cancelled by the system (app force quit...): its
  /// resume data is kept and the download starts again.
  @ObservationIgnored private var ownFileCancels = Set<Int>()
  @ObservationIgnored private var ownAssetCancels = Set<Int>()
  /// index.json was read and every entry decoded: the startup sweep may delete what the index doesn't reference.
  @ObservationIgnored private var indexIntact = false
  @ObservationIgnored var backgroundCompletionHandlers: [String: () -> Void] = [:]
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
  @ObservationIgnored private var foregroundObserver: NSObjectProtocol?

  private init() {}

  // MARK: - Lifecycle

  /// Loads the list and reconnects to the background sessions (tasks keep running while the app is closed).
  func start() {
    guard !started else { return }
    started = true
    load()
    let files = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
    files.sessionSendsLaunchEvents = true
    files.isDiscretionary = false
    files.httpMaximumConnectionsPerHost = 4
    let fileSession = URLSession(configuration: files, delegate: delegate, delegateQueue: nil)
    self.fileSession = fileSession
    let assets = URLSessionConfiguration.background(withIdentifier: Self.assetSessionID)
    assets.sessionSendsLaunchEvents = true
    assets.isDiscretionary = false
    let assetSession = AVAssetDownloadURLSession(configuration: assets, assetDownloadDelegate: delegate, delegateQueue: OperationQueue.main)
    self.assetSession = assetSession
    fileSession.getAllTasks { tasks in
      let found = tasks.compactMap { $0 as? URLSessionDownloadTask }
      Task { @MainActor in DownloadCenter.shared.reattach(fileTasks: found) }
    }
    assetSession.getAllTasks { tasks in
      let found = tasks.compactMap { $0 as? AVAssetDownloadTask }
      Task { @MainActor in DownloadCenter.shared.reattach(assetTasks: found) }
    }
    DownloadProgressQueue.shared.start()
    observeConnection()
    // The segments still waiting start before the app is suspended (the session goes on without the app).
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        DownloadCenter.shared.startAllPendingSegments()
      }
    }
    // Offline AES-HLS plays through the loopback server, whose socket iOS may reclaim while the app is suspended.
    foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      DownloadLocalServer.shared.restartIfNeeded()
    }
  }

  /// Starts the queued downloads when the connection comes back.
  private func observeConnection() {
    withObservationTracking {
      _ = ShellConnectionMonitor.shared.isOffline
    } onChange: {
      Task { @MainActor in
        let center = DownloadCenter.shared
        center.observeConnection()
        center.pump()
      }
    }
  }

  private func reattach(fileTasks tasks: [URLSessionDownloadTask]) {
    for task in tasks {
      guard let tag = DownloadTaskTag(task.taskDescription), let item = self.item(tag.id), item.status != .completed, item.status != .paused else {
        ownFileCancels.insert(task.taskIdentifier)
        task.cancel()
        continue
      }
      if tag.file == DownloadTaskTag.videoFile {
        fileTasks[tag.id] = task
      } else {
        segmentTasks[tag.id, default: [:]][task.taskIdentifier] = task
        if let url = task.originalRequest?.url {
          segmentURLs[tag.id, default: [:]][tag.file] = (url, tag.range)
          segmentHeaders[tag.id] = task.originalRequest?.allHTTPHeaderFields ?? [:]
        }
      }
      update(tag.id) { $0.status = .downloading }
    }
    reconnectedSession()
  }

  private func reattach(assetTasks tasks: [AVAssetDownloadTask]) {
    for task in tasks {
      // Unknown, finished or duplicate download: cancelled, its partial package is deleted on completion.
      guard let id = task.taskDescription, let item = self.item(id), item.status != .completed, assetTasks[id] == nil else {
        ownAssetCancels.insert(task.taskIdentifier)
        task.cancel()
        continue
      }
      assetTasks[id] = task
      if item.status != .paused { update(id) { $0.status = .downloading } }
    }
    reconnectedSession()
  }

  private func reconnectedSession() {
    reconnected += 1
    guard reconnected == 2 else { return }
    // Interrupted while resolving / preparing, or tasks lost: start again with a fresh link.
    for item in items where item.status.isRunning {
      let hasTasks = fileTasks[item.id] != nil || !(segmentTasks[item.id]?.isEmpty ?? true) || assetTasks[item.id] != nil
      if !hasTasks {
        if item.kind == .hlsFiles, isComplete(item.id) {
          finishFiles(item.id)
        } else {
          update(item.id) { $0.status = .queued }
        }
      }
    }
    sweepOrphans()
    pump()
  }

  /// Startup sweep: item folders and .movpkg packages no download references (a download cancelled while its
  /// transfer started, removed while a task was landing, a crash). Only after a clean read of the index, and the
  /// packages only while no download runs (the package of a running HLS download is not referenced yet).
  private func sweepOrphans() {
    guard indexIntact else { return }
    let ids = Set(items.map(\.id))
    let assetPaths = Set(items.compactMap(\.assetPath))
    let idle = assetTasks.isEmpty && !items.contains { $0.status.isRunning || $0.status == .queued || ($0.status == .paused && $0.kind == .hlsAsset) }
    Task.detached(priority: .utility) {
      DownloadStorage.removeOrphans(keeping: ids, assetPaths: assetPaths, packages: idle)
    }
  }

  /// application(_:handleEventsForBackgroundURLSession:completionHandler:)
  func handleBackgroundEvents(_ identifier: String, completion: @escaping () -> Void) {
    backgroundCompletionHandlers[identifier] = completion
    start()
  }

  func backgroundEventsFinished(_ identifier: String) {
    save(now: true)
    backgroundCompletionHandlers.removeValue(forKey: identifier)?()
  }

  // MARK: - Persistence

  private func load() {
    guard let data = try? Data(contentsOf: DownloadStorage.indexURL),
          let list = try? JSONDecoder().decode([DownloadLossyItem].self, from: data) else { return }
    let loaded = list.compactMap { $0.value }
    items = loaded.sorted { $0.createdAt < $1.createdAt }
    indexIntact = loaded.count == list.count
  }

  private func save(now: Bool = false) {
    saveTask?.cancel()
    if now {
      writeIndex()
      return
    }
    saveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled else { return }
      DownloadCenter.shared.writeIndex()
    }
  }

  private func writeIndex() {
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: DownloadStorage.indexURL, options: .atomic)
  }

  private func writeMetadata(_ id: String) {
    guard var item = self.item(id), let folder = try? DownloadStorage.ensureFolder(id) else { return }
    item.seed = nil
    if let data = try? JSONEncoder().encode(item) {
      try? data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
    }
  }

  // MARK: - Lookups

  func item(_ id: String) -> DownloadItem? {
    items.first { $0.id == id }
  }

  /// Download of an episode (any status).
  func item(media: Media, episode: EpisodeRef) -> DownloadItem? {
    let id = DownloadNaming.id(mediaKey: media.id, episode: episode)
    if let exact = item(id) { return exact }
    // An absolute episode number also matches a season episode of the same number.
    return items.first { $0.media.id == media.id && $0.episode.number == episode.number && episode.season == nil }
  }

  var storageUsed: Int64 {
    items.reduce(0) { $0 + ($1.status == .completed ? ($1.sizeOnDisk ?? $1.bytes) : $1.bytes) }
  }

  private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    change(&items[index])
    save()
  }

  // MARK: - Adding

  /// Queues episodes of one title. `source` keeps the extension / search result to use; `seed` is the stream the
  /// player already resolved (fallback only).
  func download(media: Media, episodes: [(ref: EpisodeRef, title: String?)], source: DownloadSource? = nil, seed: DownloadSeed? = nil) {
    start()
    if ExtensionManager.shared.enabledExtensions().isEmpty && seed == nil {
      ServiceMessages.shared.post(.error, "No extension enabled", "Downloads use your extensions to find the episode. Add or enable one in Settings > Extensions.")
      return
    }
    var added = 0
    for episode in episodes {
      let id = DownloadNaming.id(mediaKey: media.id, episode: episode.ref)
      if let existing = item(id) {
        if existing.status == .paused, assetTasks[id] != nil {
          // A suspended HLS download goes on where it stopped (a new task would orphan its partial package).
          resume(id)
          added += 1
        } else if existing.status == .failed || existing.status == .paused {
          update(id) {
            $0.status = .queued
            $0.error = nil
            $0.attempts = 0
            if let seed { $0.seed = seed }
          }
          added += 1
        }
        continue
      }
      items.append(DownloadItem(id: id, media: media, episode: episode.ref, episodeTitle: episode.title, source: source, seed: seed))
      added += 1
    }
    save()
    let title = AniListService.shared.title(media)
    if added > 0 {
      let detail = episodes.count == 1 ? "\(title) - Episode \(episodes[0].ref.number)" : title
      ServiceMessages.shared.post(.success, added == 1 ? "Download queued" : "\(added) downloads queued", detail)
    } else {
      ServiceMessages.shared.post(.info, "Already in your downloads", title)
    }
    pump()
  }

  /// "Download Episode" of the player: the episode playing, from the result it was played from.
  func downloadFromPlayer(session: PlaybackSession, source: PlaybackSource?, extensionKey: String) {
    let server = session.currentServer
    if let server, server.url.isFileURL || server.url.host == "127.0.0.1" {
      ServiceMessages.shared.post(.info, "Already downloaded", "This episode plays from your downloads.")
      return
    }
    let recipe = DownloadSource(
      extensionKey: source?.extensionKey ?? extensionKey,
      extensionName: ShellPlayback.extensionName(source?.extensionKey ?? extensionKey),
      href: source?.href,
      title: source?.title,
      serverTitle: server?.title
    )
    let seed = server.map { DownloadSeed(url: $0.url, headers: $0.headers, subtitleURL: session.subtitleURL, serverTitle: $0.title, date: Date()) }
    download(media: session.media, episodes: [(ref: session.episode, title: session.episodeTitle)], source: recipe, seed: seed)
  }

  // MARK: - Actions

  func pause(_ id: String) {
    guard let item = self.item(id), item.status != .completed else { return }
    preparing.removeValue(forKey: id)
    if let task = fileTasks.removeValue(forKey: id) {
      ownFileCancels.insert(task.taskIdentifier)
      task.cancel(byProducingResumeData: { data in
        Task { @MainActor in DownloadCenter.shared.storeResumeData(id, data) }
      })
    }
    cancelSegments(id)
    assetTasks[id]?.suspend()
    update(id) {
      $0.status = .paused
      $0.error = nil
    }
  }

  func resume(_ id: String) {
    guard let item = self.item(id), item.status == .paused || item.status == .failed else { return }
    if item.status == .paused, let task = assetTasks[id] {
      task.resume()
      update(id) { $0.status = .downloading }
      return
    }
    update(id) {
      $0.status = .queued
      $0.error = nil
      $0.attempts = 0
    }
    pump()
  }

  /// Cancel (running) or Delete (finished): stops the tasks and removes the files.
  func remove(_ id: String) {
    guard let item = self.item(id) else { return }
    preparing.removeValue(forKey: id)
    if let task = fileTasks.removeValue(forKey: id) {
      ownFileCancels.insert(task.taskIdentifier)
      task.cancel()
    }
    cancelSegments(id)
    // Its partial .movpkg is deleted when the cancel completes (assetCompleted).
    if let task = assetTasks.removeValue(forKey: id) {
      ownAssetCancels.insert(task.taskIdentifier)
      task.cancel()
    }
    items.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: DownloadStorage.folder(id))
    if let path = item.assetPath {
      try? FileManager.default.removeItem(at: DownloadStorage.homeURL(path))
    }
    save(now: true)
    pump()
  }

  func removeAll(mediaKey: String) {
    for item in items where item.media.id == mediaKey { remove(item.id) }
  }

  private func cancelSegments(_ id: String) {
    if let tasks = segmentTasks.removeValue(forKey: id) {
      for task in tasks.values {
        ownFileCancels.insert(task.taskIdentifier)
        task.cancel()
      }
    }
    segmentPending.removeValue(forKey: id)
    segmentURLs.removeValue(forKey: id)
    segmentHeaders.removeValue(forKey: id)
  }

  private func storeResumeData(_ id: String, _ data: Data?) {
    guard let data, item(id) != nil, let folder = try? DownloadStorage.ensureFolder(id) else { return }
    try? data.write(to: folder.appendingPathComponent("resume.data"), options: .atomic)
    update(id) { $0.hasResumeData = true }
  }

  // MARK: - Queue

  private var maxConcurrent: Int {
    min(max(AppSettings.shared.values.downloadMaxConcurrent, 1), 5)
  }

  func pump() {
    guard started, reconnected >= 2 else { return }
    // Offline: the queue waits (a resolution would fail and use up the retries); see observeConnection.
    guard !ShellConnectionMonitor.shared.isOffline else { return }
    var free = maxConcurrent - items.filter { $0.status.isRunning }.count
    guard free > 0 else { return }
    for item in items where item.status == .queued {
      guard free > 0 else { break }
      free -= 1
      run(item.id)
    }
  }

  private func run(_ id: String) {
    update(id) {
      $0.status = .resolving
      $0.error = nil
    }
    let token = UUID()
    preparing[id] = token
    // Lets a resolution started while in the background (session events) finish.
    let background = DownloadBackgroundTask()
    background.begin("Tsumi download \(id)")
    Task { @MainActor in
      defer { background.end() }
      do {
        guard let item = self.item(id) else { return }
        let stream = try await self.resolve(item)
        guard self.preparing[id] == token, self.item(id)?.status == .resolving else { return }
        self.update(id) {
          if let source = stream.source { $0.source = source }
          $0.seed = nil
          $0.status = .downloading
        }
        _ = try DownloadStorage.ensureFolder(id)
        self.writeMetadata(id)
        await self.saveExtras(id, stream: stream)
        guard self.preparing[id] == token else { return }
        // Re-checked after every await of the transfer start: a pause / cancel meanwhile must not start a task.
        try await self.startTransferWithFallback(id, stream: stream) {
          self.preparing[id] == token && self.item(id)?.status == .downloading
        }
        // Only this run's token: a pause + resume meanwhile started a newer run.
        if self.preparing[id] == token { self.preparing.removeValue(forKey: id) }
      } catch {
        guard self.preparing[id] == token else { return }
        self.preparing.removeValue(forKey: id)
        if error is DownloadSuperseded { return }
        self.failed(id, error)
      }
    }
  }

  /// Failure: retried with a fresh link (expired links are the usual cause) unless final.
  private func failed(_ id: String, _ error: Error) {
    guard let item = self.item(id), item.status != .paused else { return }
    if ShellConnectionMonitor.shared.isOffline {
      // Connection lost: continue once it is back (pump runs again then).
      update(id) {
        $0.status = .queued
        $0.error = nil
      }
      return
    }
    let final = (error as? DownloadFailure)?.final ?? false
    if !final && item.attempts < Self.autoRetries {
      update(id) {
        $0.attempts += 1
        $0.status = .queued
        $0.error = nil
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        DownloadCenter.shared.pump()
      }
      return
    }
    update(id) {
      $0.status = .failed
      $0.error = Self.message(error)
    }
    save(now: true)
    pump()
  }

  private static func message(_ error: Error) -> String {
    if let failure = error as? DownloadFailure { return failure.message }
    if let http = error as? HTTPError, case .status(let code, _) = http { return DownloadNaming.httpMessage(code) }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cannotFindHost, .dnsLookupFailed:
        // The host of the link does not exist (any more): retrying the same link won't help.
        let host = urlError.failingURL?.host
        return "The video server\(host.map { " (\($0))" } ?? "") doesn't exist any more: the source gave a dead link. Pick another server or source."
      case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost:
        return "Network error while downloading. Retry to continue."
      default: break
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
      return "Not enough storage on this device."
    }
    return error.localizedDescription.isEmpty ? "Download failed" : error.localizedDescription
  }

  // MARK: - Fresh stream

  struct ResolvedStream {
    /// Another server of the same episode, tried when the chosen one is dead.
    struct Server {
      var url: URL
      var headers: [String: String]
      var title: String?
    }

    var url: URL
    var headers: [String: String]
    var subtitleURL: URL?
    var source: DownloadSource?
    /// The episode's other servers, in the order to try them (DownloadResolver).
    var alternatives: [Server] = []
  }

  /// A failure of the server itself (dead host, refused, HTTP error, unsupported or wrong file): another server of
  /// the episode may work. Not the device's own problems (offline, cancelled, storage full).
  private static func isServerProblem(_ error: Error) -> Bool {
    if PlaybackResolver.isCancellation(error) { return false }
    if let urlError = error as? URLError, [.cancelled, .notConnectedToInternet, .networkConnectionLost].contains(urlError.code) { return false }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return false }
    return true
  }

  /// The chosen server first, then the episode's other servers while a server fails before its transfer starts:
  /// a dead link (e.g. a mirror host that no longer exists) must not stop the download when another server of the
  /// same episode works. The server that worked is remembered, so a retry starts with it. Same as the desktop
  /// downloader (electron/src/main/downloads/manager.js downloadWithFallback).
  private func startTransferWithFallback(_ id: String, stream: ResolvedStream, isCurrent: () -> Bool) async throws {
    let candidates = [ResolvedStream.Server(url: stream.url, headers: stream.headers, title: stream.source?.serverTitle)] + stream.alternatives
    var lastError: Error?
    for (index, candidate) in candidates.enumerated() {
      guard isCurrent() else { return }
      var attempt = stream
      attempt.url = candidate.url
      attempt.headers = candidate.headers
      if index > 0 {
        update(id) { item in
          if var source = item.source {
            source.serverTitle = candidate.title
            item.source = source
          }
        }
      }
      do {
        try await startTransfer(id, stream: attempt, isCurrent: isCurrent)
        return
      } catch {
        if error is DownloadSuperseded || ShellConnectionMonitor.shared.isOffline || !Self.isServerProblem(error) { throw error }
        lastError = error
      }
    }
    let error = lastError ?? DownloadFailure("Download failed")
    if candidates.count > 1 {
      throw DownloadFailure("None of the \(candidates.count) servers of this episode worked. Last one: \(Self.message(error))")
    }
    throw error
  }

  private func resolve(_ item: DownloadItem) async throws -> ResolvedStream {
    do {
      return try await DownloadResolver.resolve(item)
    } catch {
      if PlaybackResolver.isCancellation(error) { throw error }
      if let seed = item.seed, Date().timeIntervalSince(seed.date) < Self.seedMaxAge {
        return ResolvedStream(url: seed.url, headers: seed.headers, subtitleURL: seed.subtitleURL, source: nil)
      }
      throw error
    }
  }

  // MARK: - Transfer

  private enum StreamKind {
    case file
    case hls(text: String, url: URL)
  }

  /// What the URL serves, read from the first bytes only (a direct file is never loaded in memory).
  private func classify(_ stream: ResolvedStream) async throws -> StreamKind {
    let url = stream.url
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw DownloadFailure("This kind of source (\(url.scheme ?? "unknown")) can't be downloaded.", final: true)
    }
    if DownloadHLS.looksLikeDASH(url) {
      throw DownloadFailure("DASH streams (.mpd) can't be downloaded yet. Try another server or source.", final: true)
    }
    if DownloadHLS.looksLikeHLS(url) {
      return try await playlist(url, headers: stream.headers)
    }
    var request = URLRequest(url: url, timeoutInterval: 30)
    for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    defer { bytes.task.cancel() }
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 200
    if !(200..<300).contains(status) { throw DownloadFailure(DownloadNaming.httpMessage(status)) }
    let mime = (response.mimeType ?? "").lowercased()
    if mime.contains("html") { throw DownloadFailure("The source returned a web page instead of a video (expired or protected link).") }
    if DownloadHLS.looksLikeDASH(response.url ?? url, mimeType: mime) {
      throw DownloadFailure("DASH streams (.mpd) can't be downloaded yet. Try another server or source.", final: true)
    }
    var head = Data()
    for try await byte in bytes {
      head.append(byte)
      if head.count >= 16 { break }
    }
    if mime.contains("mpegurl") || DownloadHLS.isPlaylist(String(decoding: head, as: UTF8.self)) {
      return try await playlist(response.url ?? url, headers: stream.headers)
    }
    // AVPlayer can't play Matroska / WebM: refused before downloading the whole file (another server may be MP4).
    if Self.isMatroska(url: response.url ?? url, mimeType: mime, head: head) {
      throw DownloadFailure("This server sends an MKV / WebM video, a format iPhone and iPad can't play. Pick another server or source.", final: true)
    }
    return .file
  }

  /// Matroska / WebM file: the EBML header (1A 45 DF A3) both formats start with, the MIME type, or the
  /// extension when neither the type nor the first bytes say otherwise (no "ftyp" box of an MP4).
  private static func isMatroska(url: URL, mimeType: String, head: Data) -> Bool {
    if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return true }
    if mimeType.contains("matroska") || mimeType.contains("webm") { return true }
    let generic = mimeType.isEmpty || mimeType.contains("octet-stream")
    let isMP4 = head.count >= 8 && head.subdata(in: (head.startIndex + 4)..<(head.startIndex + 8)) == Data("ftyp".utf8)
    return generic && !isMP4 && ["mkv", "mk3d", "webm"].contains(url.pathExtension.lowercased())
  }

  private func playlist(_ url: URL, headers: [String: String]) async throws -> StreamKind {
    let (data, response) = try await HTTP.data(url, headers: headers, timeout: 30)
    let text = String(decoding: data, as: UTF8.self)
    guard DownloadHLS.isPlaylist(text) else {
      if DownloadHLS.looksLikeDASH(response.url ?? url, mimeType: response.mimeType) {
        throw DownloadFailure("DASH streams (.mpd) can't be downloaded yet. Try another server or source.", final: true)
      }
      throw DownloadFailure("The source did not return a playable HLS playlist (expired or protected link).")
    }
    return .hls(text: text, url: response.url ?? url)
  }

  /// `isCurrent` is checked after every await: a download paused or cancelled meanwhile starts no task.
  private func startTransfer(_ id: String, stream: ResolvedStream, isCurrent: () -> Bool) async throws {
    let kind = try await classify(stream)
    guard isCurrent() else { throw DownloadSuperseded() }
    switch kind {
    case .file:
      startFile(id, stream: stream)
    case .hls(let text, let url):
      try await startHLS(id, stream: stream, text: text, url: url, isCurrent: isCurrent)
    }
  }

  private func startFile(_ id: String, stream: ResolvedStream) {
    guard let session = fileSession else { return }
    var task: URLSessionDownloadTask?
    let resumeURL = DownloadStorage.folder(id).appendingPathComponent("resume.data")
    if item(id)?.hasResumeData == true, let data = try? Data(contentsOf: resumeURL) {
      task = session.downloadTask(withResumeData: data)
    }
    try? FileManager.default.removeItem(at: resumeURL)
    if task == nil {
      var request = URLRequest(url: stream.url)
      for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
      task = session.downloadTask(with: request)
    }
    guard let task else { return }
    task.taskDescription = DownloadTaskTag(id: id, file: DownloadTaskTag.videoFile).description
    fileTasks[id] = task
    update(id) {
      $0.kind = .file
      $0.hasResumeData = false
    }
    task.resume()
  }

  private func startHLS(_ id: String, stream: ResolvedStream, text: String, url: URL, isCurrent: () -> Bool) async throws {
    let quality = AppSettings.shared.values.downloadQuality
    var mediaText = text
    var mediaURL = url
    var master: HLSMaster?
    var variant: HLSVariant?
    var audio: HLSRendition?
    if DownloadHLS.isMaster(text) {
      let parsed = DownloadHLS.parseMaster(text, base: url)
      guard let chosen = DownloadHLS.pickVariant(parsed.variants, quality: quality) else {
        throw DownloadFailure("The HLS playlist lists no playable quality.", final: true)
      }
      master = parsed
      variant = chosen
      audio = DownloadHLS.pickAudio(
        parsed,
        for: chosen,
        remembered: PlayerPreferences.lastAudio(for: item(id)?.media.id ?? ""),
        preferred: AppSettings.shared.values.audioLanguage
      )
      guard case .hls(let variantText, let variantURL) = try await playlist(chosen.uri, headers: stream.headers) else { return }
      if DownloadHLS.isMaster(variantText) { throw DownloadFailure("Nested HLS master playlists are not supported.", final: true) }
      mediaText = variantText
      mediaURL = variantURL
    }
    let videoPlan = DownloadHLS.planMedia(mediaText, base: mediaURL, prefix: "v")
    var audioPlan: HLSPlan?
    if let audioURL = audio?.uri, case .hls(let audioText, let finalAudioURL) = try await playlist(audioURL, headers: stream.headers) {
      audioPlan = DownloadHLS.planMedia(audioText, base: finalAudioURL, prefix: "a")
    }
    if let drm = videoPlan.drm ?? audioPlan?.drm { throw DownloadFailure(drm, final: true) }
    guard videoPlan.segmentCount > 0 else { throw DownloadFailure("The HLS playlist has no segments.", final: true) }
    // The playlists were fetched: paused or cancelled meanwhile, no task starts.
    guard isCurrent() else { throw DownloadSuperseded() }
    let height: Int? = (variant?.height ?? 0) > 0 ? variant?.height : nil
    update(id) { $0.quality = height }

    let needsFiles = videoPlan.hasAESKey || audioPlan?.hasAESKey == true || item(id)?.preferFiles == true
    if !needsFiles {
      let asset = Self.downloadAsset(master != nil ? url : mediaURL, headers: stream.headers)
      var selection: AVMediaSelection?
      if let parsedMaster = master, let chosenVariant = variant, DownloadHLS.hasAudioChoice(parsedMaster, for: chosenVariant) {
        selection = await Self.audioSelection(asset, mediaKey: item(id)?.media.id ?? "")
        guard isCurrent() else { throw DownloadSuperseded() }
      }
      try startAsset(id, asset: asset, audioSelection: selection, variant: variant, duration: videoPlan.duration)
      return
    }
    try startSegments(id, video: videoPlan, audio: audioPlan, master: master, variant: variant, rendition: audio, headers: stream.headers)
  }

  /// HLS asset with the stream headers (and their User-Agent).
  private static func downloadAsset(_ playlistURL: URL, headers: [String: String]) -> AVURLAsset {
    var assetOptions: [String: Any] = [:]
    if !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
      if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
        assetOptions[AVURLAssetHTTPUserAgentKey] = agent
      }
    }
    return AVURLAsset(url: playlistURL, options: assetOptions)
  }

  /// AVAssetDownloadTask saves one audio rendition, the default one (picked by the system from the device
  /// language) unless told otherwise: this asks for the one the player would pick (the track remembered for the
  /// show, then the preferred audio language, then Japanese), so the offline episode has the audio the user wants.
  /// nil keeps the default: one rendition, nothing matches, or the playlist could not be read within 15 s.
  private static func audioSelection(_ asset: AVURLAsset, mediaKey: String) async -> AVMediaSelection? {
    let remembered = PlayerPreferences.lastAudio(for: mediaKey)
    let preferred = AppSettings.shared.values.audioLanguage
    // The group is first read with a time limit (cancelling the load ends it), then again from the loaded asset.
    let loading = Task { (try? await asset.loadMediaSelectionGroup(for: .audible)) != nil }
    let limit = Task {
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      loading.cancel()
    }
    let loaded = await loading.value
    limit.cancel()
    guard loaded, let group = try? await asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1,
          let base = try? await asset.load(.preferredMediaSelection) else { return nil }
    // Same names and tags as the player's audio menu (PlayerController.loadMediaSelection).
    let tracks = group.options.enumerated().map { index, option in
      PlayerTrackOption(
        id: index,
        name: option.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
        languageTag: option.extendedLanguageTag ?? option.locale?.identifier
      )
    }
    guard let index = PlayerLanguage.preferredAudioTrack(tracks, remembered: remembered, preferred: preferred),
          group.options.indices.contains(index),
          let selection = base.mutableCopy() as? AVMutableMediaSelection else { return nil }
    selection.select(group.options[index], in: group)
    return selection
  }

  private func startAsset(_ id: String, asset: AVURLAsset, audioSelection: AVMediaSelection?, variant: HLSVariant?, duration: Double) throws {
    guard let session = assetSession, let item = self.item(id) else { return }
    // A previous task of this download (suspended, then queued again) is replaced: cancelled first, its partial
    // package is deleted when the cancel completes.
    if let previous = assetTasks.removeValue(forKey: id) {
      ownAssetCancels.insert(previous.taskIdentifier)
      previous.cancel()
    }
    var options: [String: Any] = [:]
    if let bandwidth = variant?.bandwidth, bandwidth > 0 {
      options[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = bandwidth
    }
    if let audioSelection {
      options[AVAssetDownloadTaskMediaSelectionKey] = audioSelection
    }
    let title = "\(AniListService.shared.title(item.media)) - \(item.displayEpisode)"
    let artwork = item.coverFile.flatMap { try? Data(contentsOf: DownloadStorage.folder(id).appendingPathComponent($0)) }
    guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: title, assetArtworkData: artwork, options: options) else {
      throw DownloadFailure("iOS refused to download this HLS stream.")
    }
    task.taskDescription = id
    assetTasks[id] = task
    // AVFoundation reports a fraction only: the size is estimated from the variant bitrate and the duration, so
    // the Downloads screen and Storage Used show bytes while it runs (replaced by the real size at the end).
    let bandwidth = Double(variant?.bandwidth ?? 0)
    let estimate = bandwidth > 0 && duration.isFinite && duration > 0 ? bandwidth / 8 * duration : 0
    update(id) {
      $0.kind = .hlsAsset
      $0.bytes = 0
      $0.progress = 0
      $0.totalBytes = estimate.isFinite && estimate < Double(Int64.max) ? Int64(estimate) : 0
    }
    task.resume()
  }

  private func startSegments(_ id: String, video: HLSPlan, audio: HLSPlan?, master: HLSMaster?, variant: HLSVariant?, rendition: HLSRendition?, headers: [String: String]) throws {
    guard let session = fileSession else { return }
    let folder = try DownloadStorage.ensureFolder(id)
    let resources = video.resources + (audio?.resources ?? [])
    let seconds = video.duration.isFinite ? Int(min(max(video.duration, 0), 1_000_000_000)) : 0
    let signature = "\(video.segmentCount):\(audio?.segmentCount ?? 0):\(seconds)"
    if let item = self.item(id), item.kind == .hlsFiles, let previous = item.hlsSignature, previous != signature {
      // The fresh link lists other segments (another encode / server): the saved ones don't match.
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      for name in names where name.hasPrefix("v-") || name.hasPrefix("a-") {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
      }
    }
    if let audio, let rendition {
      try video.playlist.write(to: folder.appendingPathComponent("video.m3u8"), atomically: true, encoding: .utf8)
      try audio.playlist.write(to: folder.appendingPathComponent("audio.m3u8"), atomically: true, encoding: .utf8)
      try DownloadHLS.localMaster(variant: variant, audio: rendition, independentSegments: master?.independentSegments ?? false)
        .write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    } else {
      try video.playlist.write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }
    var done = 0
    var bytes: Int64 = 0
    var remaining: [HLSResource] = []
    for resource in resources {
      let path = folder.appendingPathComponent(resource.file)
      if FileManager.default.fileExists(atPath: path.path) {
        done += 1
        bytes += DownloadStorage.size(of: path)
      } else {
        remaining.append(resource)
      }
    }
    segmentHeaders[id] = headers
    var urls: [String: (url: URL, range: ClosedRange<Int64>?)] = [:]
    for resource in resources { urls[resource.file] = (resource.url, resource.range) }
    segmentURLs[id] = urls
    update(id) {
      $0.kind = .hlsFiles
      $0.hlsSignature = signature
      $0.mediaFile = "index.m3u8"
      $0.segmentsTotal = resources.count
      $0.segmentsDone = done
      $0.bytes = bytes
      $0.progress = resources.isEmpty ? 0 : min(Double(done) / Double(resources.count), 0.999)
      $0.totalBytes = done > 0 ? Int64(Double(bytes) / Double(done) * Double(resources.count)) : 0
    }
    if remaining.isEmpty {
      finishFiles(id)
      return
    }
    segmentPending[id] = remaining
    startPendingSegments(id, session: session, all: UIApplication.shared.applicationState == .background)
  }

  /// Starts waiting segments of a download: up to `segmentWindow` running tasks, or all of them (`all`, app in
  /// the background).
  private func startPendingSegments(_ id: String, session: URLSession, all: Bool) {
    guard var pending = segmentPending[id], !pending.isEmpty else { return }
    let headers = segmentHeaders[id] ?? [:]
    let running = segmentTasks[id]?.count ?? 0
    let count = all ? pending.count : min(max(Self.segmentWindow - running, 0), pending.count)
    guard count > 0 else { return }
    for resource in pending.prefix(count) {
      let task = segmentTask(session, id: id, file: resource.file, url: resource.url, range: resource.range, headers: headers)
      segmentTasks[id, default: [:]][task.taskIdentifier] = task
      task.resume()
    }
    pending.removeFirst(count)
    segmentPending[id] = pending.isEmpty ? nil : pending
  }

  /// The app goes to the background: every waiting segment starts (the session goes on while it is suspended).
  private func startAllPendingSegments() {
    guard let session = fileSession else { return }
    for id in Array(segmentPending.keys) {
      startPendingSegments(id, session: session, all: true)
    }
  }

  private func segmentTask(_ session: URLSession, id: String, file: String, url: URL, range: ClosedRange<Int64>?, headers: [String: String]) -> URLSessionDownloadTask {
    var request = URLRequest(url: url)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
    let task = session.downloadTask(with: request)
    task.taskDescription = DownloadTaskTag(id: id, file: file, range: range).description
    return task
  }

  // MARK: - Session events

  func fileProgress(id: String, written: Int64, expected: Int64) {
    guard let item = self.item(id), item.status == .downloading else { return }
    if let index = items.firstIndex(where: { $0.id == id }) {
      items[index].bytes = written
      items[index].totalBytes = max(expected, 0)
      items[index].progress = expected > 0 ? min(Double(written) / Double(expected), 0.999) : 0
    }
  }

  func fileTaskCompleted(_ result: DownloadTaskResult) {
    let id = result.tag.id
    // Cancelled by this app (pause keeps its resume data itself, remove, replaced task): nothing to report.
    if ownFileCancels.remove(result.taskIdentifier) != nil { return }
    guard let item = self.item(id), item.status != .completed else { return }
    if result.tag.file == DownloadTaskTag.videoFile {
      // Only the task the download runs now changes it (not a late answer of a replaced one). Without a known
      // task (relaunch: the answer can come before the tasks are reattached) the download must be running.
      if let current = fileTasks[id] {
        guard current.taskIdentifier == result.taskIdentifier else { return }
        fileTasks.removeValue(forKey: id)
      } else if item.status != .downloading && result.savedFile == nil {
        // A new run already prepares: only its resume data is worth keeping.
        if let data = result.resumeData { storeResumeData(id, data) }
        return
      }
      if let file = result.savedFile, result.error == nil {
        update(id) {
          $0.mediaFile = file
          $0.kind = .file
        }
        complete(id)
        return
      }
      if let data = result.resumeData, let folder = DownloadStorage.existingFolder(id) {
        try? data.write(to: folder.appendingPathComponent("resume.data"), options: .atomic)
        update(id) { $0.hasResumeData = true }
      } else if !result.cancelled && item.hasResumeData {
        // Resume data from an expired link: start over with a fresh one.
        update(id) { $0.hasResumeData = false }
      }
      if result.cancelled {
        // Cancelled by the system (app force quit...): queued again, it continues from its resume data.
        update(id) { $0.status = .queued }
        pump()
        return
      }
      let status = result.status ?? 0
      if !(200..<300).contains(status) && status > 0 {
        failed(id, DownloadFailure(DownloadNaming.httpMessage(status)))
      } else {
        failed(id, result.error ?? DownloadFailure("The download stopped unexpectedly."))
      }
      return
    }
    // HLS segment / key / init segment.
    let known = segmentTasks[id]?.removeValue(forKey: result.taskIdentifier) != nil
    // A late answer of an older run while a new run prepares: the new run lists the segments again.
    if !known && preparing[id] != nil { return }
    if result.cancelled {
      // Cancelled by the system (app force quit...): the segment is fetched again with a fresh link once the
      // other tasks are done (below).
      finishSegmentsIfDone(id)
      return
    }
    let failureKey = "\(id)|\(result.tag.file)"
    if let file = result.savedFile, result.error == nil {
      let path = DownloadStorage.folder(id).appendingPathComponent(file)
      if file.hasSuffix(".key"), DownloadStorage.size(of: path) != 16 {
        cancelSegments(id)
        failed(id, DownloadFailure("The stream key could not be downloaded (protected source).", final: true))
        return
      }
      segmentFailures.removeValue(forKey: failureKey)
      let size = DownloadStorage.size(of: path)
      if let index = items.firstIndex(where: { $0.id == id }) {
        let done = (items[index].segmentsDone ?? 0) + 1
        let total = max(items[index].segmentsTotal ?? 1, 1)
        items[index].segmentsDone = done
        items[index].bytes += size
        items[index].progress = min(Double(done) / Double(total), 0.999)
        items[index].totalBytes = Int64(Double(items[index].bytes) / Double(done) * Double(total))
        save()
      }
      // The next waiting segments take the place of this one.
      if let session = fileSession {
        startPendingSegments(id, session: session, all: UIApplication.shared.applicationState == .background)
      }
    } else {
      let failures = (segmentFailures[failureKey] ?? 0) + 1
      segmentFailures[failureKey] = failures
      let status = result.status ?? 0
      let expired = [401, 403, 404, 410].contains(status)
      if !expired, failures <= Self.segmentRetries, let session = fileSession, let entry = segmentURLs[id]?[result.tag.file] {
        let task = segmentTask(session, id: id, file: result.tag.file, url: entry.url, range: entry.range, headers: segmentHeaders[id] ?? [:])
        segmentTasks[id, default: [:]][task.taskIdentifier] = task
        task.resume()
        return
      }
      segmentFailures.removeValue(forKey: failureKey)
      cancelSegments(id)
      failed(id, status >= 400 ? DownloadFailure(DownloadNaming.httpMessage(status)) : (result.error ?? DownloadFailure("A segment could not be downloaded.")))
      return
    }
    finishSegmentsIfDone(id)
  }

  /// No segment task left and none waiting: done, or tasks lost (relaunch, system cancel) → a fresh link.
  private func finishSegmentsIfDone(_ id: String) {
    let running = !(segmentTasks[id]?.isEmpty ?? true) || !(segmentPending[id]?.isEmpty ?? true)
    guard !running, item(id)?.status == .downloading else { return }
    if isComplete(id) {
      finishFiles(id)
    } else {
      update(id) { $0.status = .queued }
      pump()
    }
  }

  func assetProgress(id: String, progress: Double) {
    guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .downloading else { return }
    let fraction = min(progress, 0.999)
    items[index].progress = fraction
    // Estimated bytes (startAsset), for the row and Storage Used.
    if items[index].totalBytes > 0 {
      items[index].bytes = Int64(Double(items[index].totalBytes) * fraction)
    }
  }

  func assetCompleted(id: String, taskIdentifier: Int, relativePath: String?, error: Error?, cancelled: Bool) {
    let own = ownAssetCancels.remove(taskIdentifier) != nil
    // Only the task the download runs now may change it. Without a known task (relaunch: the answer can come
    // before the tasks are reattached) the answer is taken as the current one.
    var isCurrent = true
    if let current = assetTasks[id] {
      isCurrent = current.taskIdentifier == taskIdentifier
      if isCurrent { assetTasks.removeValue(forKey: id) }
    }
    let live = self.item(id).map { $0.status != .completed } ?? false
    guard live, isCurrent, !own, !cancelled else {
      // Cancelled, replaced or removed download: its package is partial and nothing references it.
      if let relativePath, relativePath != self.item(id)?.assetPath {
        try? FileManager.default.removeItem(at: DownloadStorage.homeURL(relativePath))
      }
      // Cancelled by the system (app force quit...): starts again with a fresh link.
      if cancelled, !own, isCurrent, self.item(id)?.status.isRunning == true {
        update(id) { $0.status = .queued }
        pump()
      }
      return
    }
    if let relativePath, error == nil {
      let url = DownloadStorage.homeURL(relativePath)
      DownloadStorage.excludeFromBackup(url)
      update(id) {
        $0.assetPath = relativePath
        $0.kind = .hlsAsset
      }
      complete(id)
      return
    }
    if let relativePath {
      try? FileManager.default.removeItem(at: DownloadStorage.homeURL(relativePath))
    }
    // AVFoundation could not save it (headers, unusual playlist...): the next attempt goes segment by segment.
    update(id) { $0.preferFiles = true }
    failed(id, error ?? DownloadFailure("The HLS download stopped unexpectedly."))
  }

  // MARK: - Completion

  private func isComplete(_ id: String) -> Bool {
    guard let urls = segmentURLs[id], !urls.isEmpty else {
      return item(id)?.segmentsDone != nil && item(id)?.segmentsDone == item(id)?.segmentsTotal
    }
    return urls.keys.allSatisfy { DownloadStorage.fileURL(id: id, file: $0) != nil }
  }

  private func finishFiles(_ id: String) {
    segmentTasks.removeValue(forKey: id)
    segmentPending.removeValue(forKey: id)
    segmentURLs.removeValue(forKey: id)
    segmentHeaders.removeValue(forKey: id)
    update(id) { $0.mediaFile = "index.m3u8" }
    complete(id)
  }

  private func complete(_ id: String) {
    // A run still preparing (relaunch race) must not start another transfer.
    preparing.removeValue(forKey: id)
    var size = DownloadStorage.size(of: DownloadStorage.folder(id))
    if let path = item(id)?.assetPath { size += DownloadStorage.size(of: DownloadStorage.homeURL(path)) }
    update(id) {
      $0.status = .completed
      $0.completedAt = Date()
      $0.progress = 1
      $0.error = nil
      $0.sizeOnDisk = size
      $0.bytes = size
      $0.totalBytes = size
      $0.seed = nil
    }
    writeMetadata(id)
    save(now: true)
    pump()
  }

  /// Cover (for the Downloads screen offline) and subtitles, saved with the stream headers.
  private func saveExtras(_ id: String, stream: ResolvedStream) async {
    guard let item = self.item(id), let folder = try? DownloadStorage.ensureFolder(id) else { return }
    if item.coverFile == nil, let cover = item.media.images.coverLarge ?? item.media.images.cover,
       let (data, _) = try? await HTTP.data(cover, timeout: 20), !data.isEmpty {
      try? data.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
      update(id) { $0.coverFile = "cover.jpg" }
    }
    if let subtitle = stream.subtitleURL {
      if let (data, _) = try? await HTTP.data(subtitle, headers: stream.headers, timeout: 30), !data.isEmpty {
        let text = String(decoding: data, as: UTF8.self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
          let file = "subtitle." + DownloadNaming.subtitleExtension(url: subtitle, text: text)
          try? data.write(to: folder.appendingPathComponent(file), options: .atomic)
          update(id) { $0.subtitleFile = file }
        }
      }
    }
  }

  // MARK: - Offline playback

  /// The download of an episode as a playback (local file, .movpkg or loopback URL), nil when not downloaded.
  func localPlayback(media: Media, episode: EpisodeRef) async -> ResolvedPlayback? {
    guard let item = self.item(media: media, episode: episode), item.status == .completed else { return nil }
    var url: URL?
    switch item.kind {
    case .file:
      url = item.mediaFile.flatMap { DownloadStorage.fileURL(id: item.id, file: $0) }
    case .hlsAsset:
      url = item.assetPath.map { DownloadStorage.homeURL($0) }
    case .hlsFiles:
      if let port = await DownloadLocalServer.shared.ensureRunning() {
        url = DownloadLocalServer.url(port: port, id: item.id, file: item.mediaFile ?? "index.m3u8")
      }
    case .none:
      url = nil
    }
    guard let url else { return nil }
    let subtitle = item.subtitleFile.flatMap { DownloadStorage.fileURL(id: item.id, file: $0) }
    let key = item.source?.extensionKey ?? "downloads"
    let current = MediaStore.shared.media(media.id) ?? item.media
    return ResolvedPlayback(
      media: current,
      episode: item.episode,
      servers: [StreamServer(title: "Downloaded", url: url, headers: [:])],
      selectedIndex: 0,
      subtitleURL: subtitle,
      extensionKey: key,
      displayName: "\(ExtensionContext.shared.displayTitle(current)) - Episode \(item.episode.number)"
    )
  }

  /// playAnime hook: a downloaded episode plays from disk (also offline). False when it isn't downloaded.
  func playIfDownloaded(media: Media, episode: EpisodeRef) -> Bool {
    start()
    guard let item = self.item(media: media, episode: episode), item.status == .completed else { return false }
    play(item)
    return true
  }

  func play(_ item: DownloadItem) {
    Task { @MainActor in
      guard let playback = await DownloadCenter.shared.localPlayback(media: item.media, episode: item.episode) else {
        ServiceMessages.shared.post(.error, "Can't play the download", "The downloaded file is missing. Delete it and download the episode again.")
        return
      }
      let source = item.source.flatMap { source in
        source.href.map { PlaybackSource(extensionKey: source.extensionKey, href: $0, title: source.title) }
      }
      PlaybackRequestCoordinator.shared.deliver(playback, source: source)
    }
  }
}

/// Fresh stream for a download (DefaultLoadingModal steps), from the remembered search result when there is one.
@MainActor
enum DownloadResolver {
  static func resolve(_ item: DownloadItem) async throws -> DownloadCenter.ResolvedStream {
    let manager = ExtensionManager.shared
    await manager.awaitPendingLoads()
    let enabled = manager.enabledExtensions()
    let defaultKey = AppSettings.shared.values.defaultExtension
    let ext = enabled.first(where: { $0.key == item.source?.extensionKey })
      ?? enabled.first(where: { $0.key == defaultKey })
      ?? manager.enabledExtensionsStarredFirst().first
    guard let ext else {
      throw DownloadFailure("No extension enabled to find this episode. Add or enable one in Settings > Extensions.", final: true)
    }
    let found: PlaybackSourceStream
    do {
      if let source = item.source, source.extensionKey == ext.key, let href = source.href {
        found = try await PlaybackResolver.resolveSourceStream(ext, href: href, episode: item.episode, title: source.title, strict: true)
      } else {
        let title = ExtensionContext.shared.displayTitle(item.media)
        let results = try await PlaybackResolver.scoredResults(ext, title: title, media: item.media)
        guard let best = results.first else {
          throw DownloadFailure("\(title) was not found on \(ext.displayName).", final: true)
        }
        found = try await PlaybackResolver.resolveSourceStream(ext, href: best.href, episode: item.episode, title: best.title, strict: true)
      }
    } catch let error as PlaybackResolutionError {
      switch error {
      case .noEpisodes: throw DownloadFailure("Episode \(item.episode.number) was not found on \(ext.displayName).", final: true)
      case .noStreamURL: throw DownloadFailure("\(ext.displayName) returned no stream for this episode.")
      default: throw DownloadFailure(error.localizedDescription)
      }
    }
    let stream = found.stream
    let index = stream.rememberedIndex(item.source?.serverTitle)
      ?? stream.rememberedIndex(StreamSessionMemory.preferredServerTitle)
      ?? 0
    let chosen = min(max(index, 0), stream.servers.count - 1)
    let server = stream.servers[chosen]
    // The other servers, in the extension's order, for a dead first one (resolve.js orderServerIndexes).
    let alternatives = stream.servers.indices
      .filter { $0 != chosen }
      .map { DownloadCenter.ResolvedStream.Server(url: stream.servers[$0].url, headers: stream.servers[$0].headers, title: stream.servers[$0].title) }
    return DownloadCenter.ResolvedStream(
      url: server.url,
      headers: server.headers,
      subtitleURL: stream.subtitleURL,
      source: DownloadSource(extensionKey: ext.key, extensionName: ext.displayName, href: found.source.href, title: found.source.title, serverTitle: server.title),
      alternatives: alternatives
    )
  }
}

/// UIApplication background task ended on expiration or when the work is done.
@MainActor
final class DownloadBackgroundTask {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  func begin(_ name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      self?.end()
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}

/// The download was paused or cancelled (or a newer run took over) while its transfer was starting: no task is
/// created and nothing is reported.
private struct DownloadSuperseded: Error {}

/// Index entry that can't be read is dropped instead of losing the whole list.
private struct DownloadLossyItem: Decodable {
  let value: DownloadItem?

  init(from decoder: Decoder) throws {
    value = try? DownloadItem(from: decoder)
  }
}
