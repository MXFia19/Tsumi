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
  @ObservationIgnored var backgroundCompletionHandlers: [String: () -> Void] = [:]
  @ObservationIgnored private var saveTask: Task<Void, Never>?

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
      guard let id = task.taskDescription, let item = self.item(id), item.status != .completed else {
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
    pump()
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
    items = list.compactMap { $0.value }.sorted { $0.createdAt < $1.createdAt }
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
        if existing.status == .failed || existing.status == .paused {
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
    fileTasks.removeValue(forKey: id)?.cancel()
    cancelSegments(id)
    assetTasks.removeValue(forKey: id)?.cancel()
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
      for task in tasks.values { task.cancel() }
    }
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
        try await self.startTransferWithFallback(id, stream: stream) { self.preparing[id] == token }
        self.preparing.removeValue(forKey: id)
      } catch {
        guard self.preparing[id] == token else { return }
        self.preparing.removeValue(forKey: id)
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
        try await startTransfer(id, stream: attempt)
        return
      } catch {
        if ShellConnectionMonitor.shared.isOffline || !Self.isServerProblem(error) { throw error }
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
    return .file
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

  private func startTransfer(_ id: String, stream: ResolvedStream) async throws {
    switch try await classify(stream) {
    case .file:
      startFile(id, stream: stream)
    case .hls(let text, let url):
      try await startHLS(id, stream: stream, text: text, url: url)
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

  private func startHLS(_ id: String, stream: ResolvedStream, text: String, url: URL) async throws {
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
      audio = DownloadHLS.pickAudio(parsed, for: chosen)
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
    let height: Int? = (variant?.height ?? 0) > 0 ? variant?.height : nil
    update(id) { $0.quality = height }

    let needsFiles = videoPlan.hasAESKey || audioPlan?.hasAESKey == true || item(id)?.preferFiles == true
    if !needsFiles {
      try startAsset(id, playlistURL: master != nil ? url : mediaURL, headers: stream.headers, variant: variant)
      return
    }
    try startSegments(id, video: videoPlan, audio: audioPlan, master: master, variant: variant, rendition: audio, headers: stream.headers)
  }

  private func startAsset(_ id: String, playlistURL: URL, headers: [String: String], variant: HLSVariant?) throws {
    guard let session = assetSession, let item = self.item(id) else { return }
    var assetOptions: [String: Any] = [:]
    if !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
      if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
        assetOptions[AVURLAssetHTTPUserAgentKey] = agent
      }
    }
    let asset = AVURLAsset(url: playlistURL, options: assetOptions)
    var options: [String: Any] = [:]
    if let bandwidth = variant?.bandwidth, bandwidth > 0 {
      options[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = bandwidth
    }
    let title = "\(AniListService.shared.title(item.media)) - \(item.displayEpisode)"
    let artwork = item.coverFile.flatMap { try? Data(contentsOf: DownloadStorage.folder(id).appendingPathComponent($0)) }
    guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: title, assetArtworkData: artwork, options: options) else {
      throw DownloadFailure("iOS refused to download this HLS stream.")
    }
    task.taskDescription = id
    assetTasks[id] = task
    update(id) { $0.kind = .hlsAsset }
    task.resume()
  }

  private func startSegments(_ id: String, video: HLSPlan, audio: HLSPlan?, master: HLSMaster?, variant: HLSVariant?, rendition: HLSRendition?, headers: [String: String]) throws {
    guard let session = fileSession else { return }
    let folder = try DownloadStorage.ensureFolder(id)
    let resources = video.resources + (audio?.resources ?? [])
    let signature = "\(video.segmentCount):\(audio?.segmentCount ?? 0):\(Int(video.duration))"
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
    for resource in remaining {
      let task = segmentTask(session, id: id, file: resource.file, url: resource.url, range: resource.range, headers: headers)
      segmentTasks[id, default: [:]][task.taskIdentifier] = task
      task.resume()
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
    guard item(id) != nil else { return }
    if result.tag.file == DownloadTaskTag.videoFile {
      fileTasks.removeValue(forKey: id)
      if result.cancelled { return }
      if let file = result.savedFile, result.error == nil {
        update(id) {
          $0.mediaFile = file
          $0.kind = .file
        }
        complete(id)
        return
      }
      if let data = result.resumeData, let folder = try? DownloadStorage.ensureFolder(id) {
        try? data.write(to: folder.appendingPathComponent("resume.data"), options: .atomic)
        update(id) { $0.hasResumeData = true }
      } else if item(id)?.hasResumeData == true {
        // Resume data from an expired link: start over with a fresh one.
        update(id) { $0.hasResumeData = false }
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
    var tasks = segmentTasks[id] ?? [:]
    tasks.removeValue(forKey: result.taskIdentifier)
    segmentTasks[id] = tasks
    if result.cancelled { return }
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
    if tasks.isEmpty, item(id)?.status == .downloading {
      if isComplete(id) {
        finishFiles(id)
      } else {
        // Tasks lost (relaunch): continue with a fresh link.
        update(id) { $0.status = .queued }
        pump()
      }
    }
  }

  func assetProgress(id: String, progress: Double) {
    guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .downloading else { return }
    items[index].progress = min(progress, 0.999)
  }

  func assetCompleted(id: String, relativePath: String?, error: Error?, cancelled: Bool) {
    assetTasks.removeValue(forKey: id)
    guard item(id) != nil, !cancelled else { return }
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
    segmentURLs.removeValue(forKey: id)
    segmentHeaders.removeValue(forKey: id)
    update(id) { $0.mediaFile = "index.m3u8" }
    complete(id)
  }

  private func complete(_ id: String) {
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

/// Index entry that can't be read is dropped instead of losing the whole list.
private struct DownloadLossyItem: Decodable {
  let value: DownloadItem?

  init(from decoder: Decoder) throws {
    value = try? DownloadItem(from: decoder)
  }
}
