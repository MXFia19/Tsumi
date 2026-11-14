import Foundation

/// Simple persistent cache with expiry (JSON files in Caches/), mirroring common/modules/cache.js
/// for API responses, plus an in-memory layer.
actor DiskCache {
  static let shared = DiskCache()

  private struct Entry<T: Codable>: Codable {
    var expires: Date
    var value: T
  }

  private let directory: URL
  private var memory: [String: (expires: Date, value: Any)] = [:]

  init() {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory = base.appendingPathComponent("TsumiCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func fileURL(_ key: String) -> URL {
    let safe = key.data(using: .utf8)!.base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    return directory.appendingPathComponent(String(safe.prefix(200)) + ".json")
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
