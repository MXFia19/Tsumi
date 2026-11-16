import Foundation
import CryptoKit

/// Simple persistent cache with expiry (JSON files in Caches/), mirroring common/modules/cache.js
/// for API responses, plus a bounded in-memory layer (least recently used entries are dropped first).
actor DiskCache {
  static let shared = DiskCache()

  private struct Entry<T: Codable>: Codable {
    var expires: Date
    var value: T
  }

  /// The expiry of an entry file, read without decoding its value type.
  private struct EntryHeader: Decodable {
    var expires: Date
  }

  private struct MemoryEntry {
    var expires: Date
    var value: Any
    /// Last use (`clock` value), for the least recently used eviction.
    var used: UInt64
  }

  /// Set once the files named by base64 prefixes (which could collide) have been removed.
  private static let hashedNamesKey = "tsumi.cache.sha256Names"
  /// Entries kept in memory; past this the least recently used quarter is dropped.
  private static let memoryLimit = 400
  /// Expired files are kept this long for the offline / stale fallbacks (`allowExpired`), then deleted at launch.
  static let expiredFileGrace: TimeInterval = 30 * 24 * 3600

  private let directory: URL
  private var memory: [String: MemoryEntry] = [:]
  private var clock: UInt64 = 0

  init() {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory = base.appendingPathComponent("TsumiCache", isDirectory: true)
    if !UserDefaults.standard.bool(forKey: Self.hashedNamesKey) {
      // Files of the old naming scheme can no longer be found: drop them once.
      try? FileManager.default.removeItem(at: directory)
      UserDefaults.standard.set(true, forKey: Self.hashedNamesKey)
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// File named by the SHA-256 of the whole key (cache.js keys entries by the full JSON string).
  private func fileURL(_ key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".json")
  }

  /// Returns the cached value if present and not expired (or `allowExpired`, e.g. when offline).
  func get<T: Codable>(_ key: String, as type: T.Type, allowExpired: Bool = false) -> T? {
    if let hit = memory[key] {
      if allowExpired || hit.expires > Date(), let value = hit.value as? T {
        touch(key)
        return value
      }
      // Expired: no longer worth memory (the file still serves `allowExpired` reads).
      if hit.expires <= Date() { memory[key] = nil }
    }
    guard let data = try? Data(contentsOf: fileURL(key)),
          let entry = try? JSONDecoder().decode(Entry<T>.self, from: data) else { return nil }
    guard allowExpired || entry.expires > Date() else { return nil }
    remember(key, expires: entry.expires, value: entry.value)
    return entry.value
  }

  func set<T: Codable>(_ key: String, _ value: T, ttl: TimeInterval) {
    let expires = Date().addingTimeInterval(ttl)
    remember(key, expires: expires, value: value)
    if let data = try? JSONEncoder().encode(Entry(expires: expires, value: value)) {
      try? data.write(to: fileURL(key), options: .atomic)
    }
  }

  func remove(_ key: String) {
    memory[key] = nil
    try? FileManager.default.removeItem(at: fileURL(key))
  }

  func clear() {
    memory.removeAll()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// Memory warning: drops the in-memory layer (the files stay).
  func purgeMemory() {
    memory.removeAll()
  }

  /// Fetch-through helper: cached value if fresh, else run `load` and store it.
  func cached<T: Codable>(_ key: String, ttl: TimeInterval, load: () async throws -> T) async throws -> T {
    if let value = get(key, as: T.self) { return value }
    do {
      let value = try await load()
      set(key, value, ttl: ttl)
      return value
    } catch {
      if let stale = get(key, as: T.self, allowExpired: true) { return stale }
      throw error
    }
  }

  // MARK: - Memory layer

  private func touch(_ key: String) {
    clock &+= 1
    memory[key]?.used = clock
  }

  private func remember(_ key: String, expires: Date, value: Any) {
    clock &+= 1
    memory[key] = MemoryEntry(expires: expires, value: value, used: clock)
    if memory.count > Self.memoryLimit { evict() }
  }

  /// Drops the expired entries, then the least recently used ones down to three quarters of the limit.
  private func evict() {
    let now = Date()
    memory = memory.filter { $0.value.expires > now }
    let target = Self.memoryLimit * 3 / 4
    guard memory.count > target else { return }
    let oldest = memory.sorted { $0.value.used < $1.value.used }.prefix(memory.count - target)
    for (key, _) in oldest { memory[key] = nil }
  }

  // MARK: - Files

  /// Deletes the files expired for more than `expiredFileGrace` (and unreadable ones), off the actor so cache reads
  /// are not held up. Run once at launch.
  nonisolated func pruneExpiredFiles() {
    let manager = FileManager.default
    guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
    let limit = Date().addingTimeInterval(-Self.expiredFileGrace)
    let decoder = JSONDecoder()
    for file in files where file.pathExtension == "json" {
      // A file written after the limit cannot have expired before it.
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      if modified > limit { continue }
      guard let data = try? Data(contentsOf: file), let header = try? decoder.decode(EntryHeader.self, from: data) else {
        try? manager.removeItem(at: file)
        continue
      }
      if header.expires < limit { try? manager.removeItem(at: file) }
    }
  }
}
