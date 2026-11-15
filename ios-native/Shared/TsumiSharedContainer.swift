import Foundation
import ImageIO
import UniformTypeIdentifiers

// App Group container shared by the app and the widget extension, resolved at runtime.
//
// The CI builds an unsigned .ipa that is re-signed when sideloaded, and every signing method treats App Groups
// differently: the binary's own (ad-hoc) entitlements may be kept (TrollStore), renamed with a team suffix
// (AltStore / SideStore style "group.org.tsumi.app.TEAMID"), replaced by the groups of the certificate's
// provisioning profile (Feather / zsign) or dropped. So the group name is never hard-coded: the candidates come
// from the running binary's code signature, then from the embedded provisioning profiles, then from the names
// this project uses, and the first container the process can really write to wins.

enum TsumiSharedContainer {
  /// App Group of the project (entitlements files of ios-native/Entitlements).
  static let defaultGroup = "group.org.tsumi.app"
  /// Folder of the container used by Tsumi (the container may be shared with other apps of a certificate).
  static let folderName = "TsumiWidgets"

  struct Location: Hashable {
    var group: String
    /// `<container>/TsumiWidgets`.
    var directory: URL

    var coversDirectory: URL {
      directory.appendingPathComponent(TsumiWidgetSnapshot.coversFolder, isDirectory: true)
    }

    var snapshotURL: URL {
      directory.appendingPathComponent(TsumiWidgetSnapshot.fileName)
    }
  }

  /// App Group identifiers to try, best first (computed once per process).
  static let candidates: [String] = computeCandidates()

  /// Where the app writes: the first candidate whose container this process can write to.
  static func writableLocation() -> Location? {
    for group in candidates {
      if let location = open(group) { return location }
    }
    return nil
  }

  /// Every candidate container this process can open.
  static func accessibleLocations() -> [Location] {
    candidates.compactMap { open($0) }
  }

  /// Where the widgets read: the accessible container holding the newest snapshot (the app and the extension may
  /// rank the candidates differently when they were signed with different profiles).
  static func readableLocation() -> Location? {
    var best: Location?
    var bestDate = Date.distantPast
    for location in accessibleLocations() {
      let attributes = try? FileManager.default.attributesOfItem(atPath: location.snapshotURL.path)
      guard let date = attributes?[.modificationDate] as? Date else { continue }
      if best == nil || date > bestDate {
        best = location
        bestDate = date
      }
    }
    return best
  }

  /// The Tsumi folder of a group's container, created if needed; nil when the group is not usable here.
  static func open(_ group: String) -> Location? {
    guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
    let directory = base.appendingPathComponent(folderName, isDirectory: true)
    let manager = FileManager.default
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    // containerURL can return a path the sandbox does not let us use: check that it is really writable.
    let probe = directory.appendingPathComponent(".probe")
    do {
      try Data().write(to: probe, options: [.atomic])
      try? manager.removeItem(at: probe)
    } catch {
      return nil
    }
    return Location(group: group, directory: directory)
  }

  // MARK: - Candidates

  private static func computeCandidates() -> [String] {
    var ordered: [String] = []
    func add(_ groups: [String]) {
      // Groups that look like ours first (a certificate's profile can list unrelated groups).
      let ours = groups.filter { $0.lowercased().contains("tsumi") }
      let others = groups.filter { !$0.lowercased().contains("tsumi") }
      for group in ours + others where group.hasPrefix("group.") && !group.contains("*") && !ordered.contains(group) {
        ordered.append(group)
      }
    }
    let bundle = Bundle.main.bundleURL
    // 1. The entitlements this process was really signed with.
    add(TsumiCodeSignature.applicationGroups(executable: Bundle.main.executableURL))
    // 2. The provisioning profile of this bundle, then of the host app (when running in the extension).
    add(TsumiCodeSignature.provisioningGroups(bundle: bundle))
    let host = hostAppBundleURL
    if let host {
      add(TsumiCodeSignature.provisioningGroups(bundle: host))
    }
    // 3. The project's group, and the group named after the (possibly renamed) app bundle identifier.
    add([defaultGroup])
    if let hostId = hostBundleIdentifier {
      add(["group." + hostId])
    }
    return ordered
  }

  /// The app bundle: the main bundle in the app, `Tsumi.app` around `PlugIns/TsumiWidgets.appex` in the extension.
  static var hostAppBundleURL: URL? {
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "appex" else { return bundle }
    let host = bundle.deletingLastPathComponent().deletingLastPathComponent()
    return host.pathExtension == "app" ? host : nil
  }

  /// Bundle identifier of the app (the extension's identifier minus its last component).
  static var hostBundleIdentifier: String? {
    guard let identifier = Bundle.main.bundleIdentifier else { return nil }
    guard Bundle.main.bundleURL.pathExtension == "appex" else { return identifier }
    if let host = hostAppBundleURL, let hostIdentifier = Bundle(url: host)?.bundleIdentifier { return hostIdentifier }
    var parts = identifier.split(separator: ".")
    guard parts.count > 1 else { return identifier }
    parts.removeLast()
    return parts.joined(separator: ".")
  }
}

/// Reads entitlements from the running binary's code signature and from embedded provisioning profiles.
enum TsumiCodeSignature {
  static let applicationGroupsKey = "com.apple.security.application-groups"

  static func applicationGroups(executable: URL?) -> [String] {
    guard let executable, let entitlements = entitlements(executable: executable) else { return [] }
    return entitlements[applicationGroupsKey] as? [String] ?? []
  }

  /// App Groups of `<bundle>/embedded.mobileprovision` (the plist inside the CMS envelope).
  static func provisioningGroups(bundle: URL) -> [String] {
    let url = bundle.appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: url) else { return [] }
    guard let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else { return [] }
    let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
    guard let plist = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
    return entitlements[applicationGroupsKey] as? [String] ?? []
  }

  /// Entitlements plist of a Mach-O executable (thin or fat), nil when it is unsigned.
  static func entitlements(executable: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: executable, options: [.alwaysMapped]) else { return nil }
    return data.withUnsafeBytes { raw -> [String: Any]? in
      let reader = TsumiBinaryReader(raw)
      guard let magic = reader.u32BE(0) else { return nil }
      if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
        // Fat binary: the first slice that has entitlements (arm64 first).
        let is64 = magic == 0xCAFEBABF
        let count = Int(reader.u32BE(4) ?? 0)
        let entrySize = is64 ? 32 : 20
        var slices: [(cpu: UInt32, offset: Int)] = []
        for index in 0..<min(count, 16) {
          let base = 8 + index * entrySize
          guard let cpu = reader.u32BE(base) else { break }
          let offset: Int
          if is64 {
            guard let value = reader.u64BE(base + 8) else { break }
            offset = Int(clamping: value)
          } else {
            guard let value = reader.u32BE(base + 8) else { break }
            offset = Int(value)
          }
          slices.append((cpu, offset))
        }
        let arm64: UInt32 = 0x0100000C
        let ordered = slices.filter { $0.cpu == arm64 } + slices.filter { $0.cpu != arm64 }
        for slice in ordered {
          if let found = thinEntitlements(reader, base: slice.offset) { return found }
        }
        return nil
      }
      return thinEntitlements(reader, base: 0)
    }
  }

  /// LC_CODE_SIGNATURE → SuperBlob → CSSLOT_ENTITLEMENTS (XML plist).
  private static func thinEntitlements(_ reader: TsumiBinaryReader, base: Int) -> [String: Any]? {
    guard let magic = reader.u32LE(base) else { return nil }
    let headerSize: Int
    switch magic {
    case 0xFEEDFACF: headerSize = 32
    case 0xFEEDFACE: headerSize = 28
    default: return nil
    }
    guard let commandCount = reader.u32LE(base + 16) else { return nil }
    var cursor = base + headerSize
    for _ in 0..<min(Int(commandCount), 4096) {
      guard let command = reader.u32LE(cursor), let size = reader.u32LE(cursor + 4), size >= 8 else { return nil }
      if command == 0x1D { // LC_CODE_SIGNATURE
        guard let dataOffset = reader.u32LE(cursor + 8) else { return nil }
        return superBlobEntitlements(reader, at: base + Int(dataOffset))
      }
      cursor += Int(size)
    }
    return nil
  }

  private static func superBlobEntitlements(_ reader: TsumiBinaryReader, at offset: Int) -> [String: Any]? {
    guard reader.u32BE(offset) == 0xFADE0CC0, let count = reader.u32BE(offset + 8) else { return nil }
    for index in 0..<min(Int(count), 64) {
      let entry = offset + 12 + index * 8
      guard let type = reader.u32BE(entry), let blobOffset = reader.u32BE(entry + 4) else { return nil }
      guard type == 5 else { continue } // CSSLOT_ENTITLEMENTS
      let blob = offset + Int(blobOffset)
      guard reader.u32BE(blob) == 0xFADE7171, let length = reader.u32BE(blob + 4), length > 8 else { return nil }
      guard let xml = reader.bytes(blob + 8, count: Int(length) - 8) else { return nil }
      return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
    }
    return nil
  }
}

/// Bounds-checked reads in a raw buffer.
struct TsumiBinaryReader {
  let raw: UnsafeRawBufferPointer

  init(_ raw: UnsafeRawBufferPointer) {
    self.raw = raw
  }

  func u32LE(_ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= raw.count else { return nil }
    return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
  }

  func u32BE(_ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= raw.count else { return nil }
    return UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
  }

  func u64BE(_ offset: Int) -> UInt64? {
    guard offset >= 0, offset + 8 <= raw.count else { return nil }
    return UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
  }

  func bytes(_ offset: Int, count: Int) -> Data? {
    guard offset >= 0, count >= 0, offset + count <= raw.count, let start = raw.baseAddress else { return nil }
    return Data(bytes: start.advanced(by: offset), count: count)
  }
}

/// Small JPEG cover thumbnails (widgets have a tight memory budget).
enum TsumiThumbnail {
  /// Downscaled JPEG of an image, nil when it cannot be decoded.
  static func jpeg(from data: Data, maxPixelSize: Int = 300) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  /// File name of a media key's thumbnail ("al-123.jpg").
  static func fileName(for mediaKey: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let safe = String(mediaKey.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    return safe + ".jpg"
  }

  /// Downloads `url` and stores its thumbnail at `destination` (skipped when the file exists).
  @discardableResult
  static func download(_ url: URL, to destination: URL, maxPixelSize: Int = 300, timeout: TimeInterval = 15) async -> Bool {
    if FileManager.default.fileExists(atPath: destination.path) { return true }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let thumbnail = jpeg(from: data, maxPixelSize: maxPixelSize) else { return false }
    do {
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try thumbnail.write(to: destination, options: [.atomic])
      return true
    } catch {
      return false
    }
  }
}
