import Foundation
import CryptoKit

/// Simple persistent cache with expiry (JSON files in Caches/), mirroring common/modules/cache.js
/// for API responses, plus an in-memory layer.
actor DiskCache {
  static let shared = DiskCache()

  private struct Entry<T: Codable>: Codable {
    var expires: Date
    var value: T
  }

  /// Set once the files named by base64 prefixes (which could collide) have been removed.
  private static let hashedNamesKey = "tsumi.cache.sha256Names"

  private let directory: URL
  private var memory: [String: (expires: Date, value: Any)] = [:]

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
    if let hit = memory[key], allowExpired || hit.expires > Date(), let value = hit.value as? T { return value }
    guard let data = try? Data(contentsOf: fileURL(key)),
          let entry = try? JSONDecoder().decode(Entry<T>.self, from: data) else { return nil }
    guard allowExpired || entry.expires > Date() else { return nil }
    memory[key] = (entry.expires, entry.value)
    return entry.value
  }

  func set<T: Codable>(_ key: String, _ value: T, ttl: TimeInterval) {
    let expires = Date().addingTimeInterval(ttl)
    memory[key] = (expires, value)
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
}
