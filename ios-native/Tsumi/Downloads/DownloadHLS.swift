import Foundation

// HLS planning of the downloads, port of electron/src/main/downloads/hls.js: master playlist variants, quality
// pick, DRM detection and, for the segment-by-segment downloads, the files to fetch (segments, AES-128 keys,
// init segments, byte ranges) with the local playlist pointing at them.

struct HLSVariant: Hashable {
  var uri: URL
  var bandwidth: Int
  var width: Int
  var height: Int
  var codecs: String
  var audioGroup: String
}

struct HLSRendition: Hashable {
  var type: String
  var groupId: String
  var name: String
  var language: String
  var isDefault: Bool
  var uri: URL?
}

struct HLSMaster {
  var variants: [HLSVariant]
  var renditions: [HLSRendition]
  var independentSegments: Bool
}

struct HLSResource: Hashable {
  enum Kind: String { case segment, key, map }
  var kind: Kind
  var url: URL
  var file: String
  /// Inclusive byte range.
  var range: ClosedRange<Int64>?
}

struct HLSPlan {
  var resources: [HLSResource]
  var playlist: String
  var drm: String?
  /// Encrypted with AES-128 (AVFoundation does not keep those keys offline).
  var hasAESKey: Bool
  var duration: Double
  var segmentCount: Int
}

enum DownloadHLS {
  static func isPlaylist(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("#EXTM3U")
  }

  static func isMaster(_ text: String) -> Bool {
    text.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
  }

  static func looksLikeHLS(_ url: URL, mimeType: String? = nil) -> Bool {
    url.absoluteString.lowercased().contains(".m3u8") || (mimeType ?? "").lowercased().contains("mpegurl")
  }

  static func looksLikeDASH(_ url: URL, mimeType: String? = nil) -> Bool {
    url.path.lowercased().hasSuffix(".mpd") || (mimeType ?? "").lowercased().contains("dash+xml")
  }

  /// KEY=VALUE,KEY2="quoted, value" (keys upper-cased).
  static func attributes(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      while index < characters.count, characters[index] == "," || characters[index] == " " { index += 1 }
      var key = ""
      while index < characters.count, characters[index] != "=", characters[index] != "," {
        key.append(characters[index])
        index += 1
      }
      guard index < characters.count, characters[index] == "=" else {
        index += 1
        continue
      }
      index += 1
      var value = ""
      if index < characters.count, characters[index] == "\"" {
        index += 1
        while index < characters.count, characters[index] != "\"" {
          value.append(characters[index])
          index += 1
        }
        index += 1
      } else {
        while index < characters.count, characters[index] != "," {
          value.append(characters[index])
          index += 1
        }
      }
      let name = key.trimmingCharacters(in: .whitespaces).uppercased()
      if !name.isEmpty { result[name] = value.trimmingCharacters(in: .whitespaces) }
    }
    return result
  }

  private static func tagValue(_ line: String) -> String {
    guard let colon = line.firstIndex(of: ":") else { return "" }
    return String(line[line.index(after: colon)...])
  }

  private static func resolve(_ uri: String, base: URL) -> URL? {
    URL(string: uri, relativeTo: base)?.absoluteURL ?? URL.lenient(uri)
  }

  private static func lines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func parseMaster(_ text: String, base: URL) -> HLSMaster {
    var variants: [HLSVariant] = []
    var renditions: [HLSRendition] = []
    var pending: [String: String]?
    var independent = false
    for line in lines(text) {
      let upper = line.uppercased()
      if upper.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") { independent = true }
      if upper.hasPrefix("#EXT-X-STREAM-INF:") {
        pending = attributes(tagValue(line))
        continue
      }
      if upper.hasPrefix("#EXT-X-MEDIA:") {
        let values = attributes(tagValue(line))
        renditions.append(HLSRendition(
          type: (values["TYPE"] ?? "").uppercased(),
          groupId: values["GROUP-ID"] ?? "",
          name: values["NAME"] ?? "",
          language: values["LANGUAGE"] ?? "",
          isDefault: (values["DEFAULT"] ?? "").uppercased() == "YES",
          uri: values["URI"].flatMap { resolve($0, base: base) }
        ))
        continue
      }
      if line.hasPrefix("#") { continue }
      if let values = pending, let url = resolve(line, base: base) {
        let size = (values["RESOLUTION"] ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
        variants.append(HLSVariant(
          uri: url,
          bandwidth: Int(values["BANDWIDTH"] ?? "") ?? Int(values["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
          width: size.count == 2 ? size[0] : 0,
          height: size.count == 2 ? size[1] : 0,
          codecs: values["CODECS"] ?? "",
          audioGroup: values["AUDIO"] ?? ""
        ))
        pending = nil
      }
    }
    return HLSMaster(variants: variants, renditions: renditions, independentSegments: independent)
  }

  /// Variant for the quality setting: the best one at or under a height limit (the smallest when all are taller).
  static func pickVariant(_ variants: [HLSVariant], quality: String) -> HLSVariant? {
    guard !variants.isEmpty else { return nil }
    let sorted = variants.sorted { lhs, rhs in
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.bandwidth < rhs.bandwidth
    }
    if quality == "lowest" { return sorted.first }
    guard let limit = Int(quality), sorted.contains(where: { $0.height > 0 }) else { return sorted.last }
    let fitting = sorted.filter { $0.height > 0 && $0.height <= limit }
    return fitting.last ?? sorted.first(where: { $0.height > 0 }) ?? sorted.first
  }

  static func pickAudio(_ master: HLSMaster, for variant: HLSVariant) -> HLSRendition? {
    guard !variant.audioGroup.isEmpty else { return nil }
    let group = master.renditions.filter { $0.type == "AUDIO" && $0.groupId == variant.audioGroup && $0.uri != nil }
    return group.first(where: { $0.isDefault }) ?? group.first
  }

  /// Why an EXT-X-KEY can't be saved (nil for none / AES-128 with a plain key).
  static func drmReason(_ values: [String: String]) -> String? {
    let method = (values["METHOD"] ?? "NONE").uppercased()
    if method == "NONE" { return nil }
    let format = (values["KEYFORMAT"] ?? "identity").lowercased()
    if method == "AES-128" && format == "identity" { return nil }
    return "This stream is DRM-protected (\(method)\(format != "identity" ? ", " + format : "")) and can't be downloaded."
  }

  private static let segmentExtensions: Set<String> = ["ts", "m4s", "mp4", "m4v", "m4a", "aac", "mp3", "ac3", "ec3", "vtt", "webvtt", "cmfv", "cmfa"]

  private static func segmentExtension(_ url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    return segmentExtensions.contains(ext) ? ext : "ts"
  }

  /// "length[@offset]". A malformed one (length <= 0, negative offset, past Int64) is ignored: building its
  /// ClosedRange would trap.
  private static func byteRange(_ text: String?) -> (length: Int64, offset: Int64?)? {
    guard let text else { return nil }
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@")
    guard let length = parts.first.flatMap({ Int64($0) }), length > 0 else { return nil }
    let offset = parts.count > 1 ? Int64(parts[1]) : nil
    if let offset, offset < 0 || offset > Int64.max - length { return nil }
    return (length, offset)
  }

  /// Inclusive range of `length` bytes from `start`, nil when it would overflow.
  private static func closedRange(start: Int64, length: Int64) -> ClosedRange<Int64>? {
    guard start >= 0, length > 0, start <= Int64.max - length else { return nil }
    return start...(start + length - 1)
  }

  /// EXTINF duration in seconds; a malformed one (nan, inf, negative, absurd) counts as 0 (Int(nan) traps).
  static func segmentDuration(_ value: String) -> Double {
    guard let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return 0 }
    return seconds
  }

  private static func replacingURI(_ line: String, with uri: String) -> String {
    guard let range = line.range(of: "URI=\"[^\"]*\"", options: .regularExpression) else { return line }
    return line.replacingCharacters(in: range, with: "URI=\"\(uri)\"")
  }

  private static func droppingByteRange(_ line: String) -> String {
    var result = line
    if let range = result.range(of: ",?BYTERANGE=\"[^\"]*\"", options: [.regularExpression, .caseInsensitive]) {
      result.removeSubrange(range)
    }
    return result.replacingOccurrences(of: ":,", with: ":")
  }

  private static let droppedTags = ["#EXT-X-BYTERANGE", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT", "#EXT-X-RENDITION-REPORT", "#EXT-X-SERVER-CONTROL", "#EXT-X-SKIP", "#EXT-X-SESSION-KEY"]

  /// Media playlist → files to download + local playlist. `prefix` names this playlist's files (v / a).
  static func planMedia(_ text: String, base: URL, prefix: String = "v") -> HLSPlan {
    var resources: [HLSResource] = []
    var output: [String] = []
    var keyFiles: [URL: String] = [:]
    var mapFiles: [String: String] = [:]
    var rangeEnds: [URL: Int64] = [:]
    var drm: String?
    var hasAESKey = false
    var duration = 0.0
    var segmentCount = 0
    var endList = false
    var pendingRange: (length: Int64, offset: Int64?)?

    for line in lines(text) {
      let upper = line.uppercased()
      if line.hasPrefix("#") {
        if upper.hasPrefix("#EXT-X-ENDLIST") { endList = true }
        if upper.hasPrefix("#EXT-X-BYTERANGE:") {
          pendingRange = byteRange(tagValue(line))
          continue
        }
        if droppedTags.contains(where: { upper.hasPrefix($0) }) { continue }
        if upper.hasPrefix("#EXTINF:") {
          duration += segmentDuration(tagValue(line).split(separator: ",").first.map(String.init) ?? "")
        }
        if upper.hasPrefix("#EXT-X-KEY:") {
          let values = attributes(tagValue(line))
          if let reason = drmReason(values) {
            drm = drm ?? reason
            output.append(line)
            continue
          }
          if (values["METHOD"] ?? "").uppercased() == "AES-128", let uri = values["URI"], let url = resolve(uri, base: base) {
            hasAESKey = true
            if keyFiles[url] == nil {
              let file = "\(prefix)-key-\(keyFiles.count).key"
              keyFiles[url] = file
              resources.append(HLSResource(kind: .key, url: url, file: file, range: nil))
            }
            output.append(replacingURI(line, with: keyFiles[url] ?? ""))
            continue
          }
          output.append(line)
          continue
        }
        if upper.hasPrefix("#EXT-X-MAP:") {
          let values = attributes(tagValue(line))
          guard let uri = values["URI"], let url = resolve(uri, base: base) else {
            output.append(line)
            continue
          }
          var range: ClosedRange<Int64>?
          if let parsed = byteRange(values["BYTERANGE"]) {
            range = closedRange(start: parsed.offset ?? 0, length: parsed.length)
          }
          let mapKey = url.absoluteString + (range.map { "#\($0.lowerBound)-\($0.upperBound)" } ?? "")
          if mapFiles[mapKey] == nil {
            let ext = segmentExtension(url)
            let file = "\(prefix)-init-\(mapFiles.count).\(ext == "ts" ? "mp4" : ext)"
            mapFiles[mapKey] = file
            resources.append(HLSResource(kind: .map, url: url, file: file, range: range))
          }
          output.append(replacingURI(droppingByteRange(line), with: mapFiles[mapKey] ?? ""))
          continue
        }
        output.append(line)
        continue
      }
      guard let url = resolve(line, base: base) else { continue }
      var range: ClosedRange<Int64>?
      if let pending = pendingRange {
        let start = pending.offset ?? rangeEnds[url] ?? 0
        range = closedRange(start: start, length: pending.length)
        if let range { rangeEnds[url] = range.upperBound + 1 }
        pendingRange = nil
      }
      let file = "\(prefix)-\(String(format: "%05ld", segmentCount)).\(segmentExtension(url))"
      resources.append(HLSResource(kind: .segment, url: url, file: file, range: range))
      output.append(file)
      segmentCount += 1
    }
    if !endList { output.append("#EXT-X-ENDLIST") }
    return HLSPlan(resources: resources, playlist: output.joined(separator: "\n") + "\n", drm: drm, hasAESKey: hasAESKey, duration: duration, segmentCount: segmentCount)
  }

  /// Local master playlist joining the video playlist and its separate audio rendition.
  static func localMaster(variant: HLSVariant?, audio: HLSRendition, independentSegments: Bool) -> String {
    var lines = ["#EXTM3U"]
    if independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
    let name = audio.name.isEmpty ? "Audio" : audio.name.replacingOccurrences(of: "\"", with: "")
    let language = audio.language.isEmpty ? "" : ",LANGUAGE=\"\(audio.language.replacingOccurrences(of: "\"", with: ""))\""
    lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name)\"\(language),DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
    var stream = ["BANDWIDTH=\(max(variant?.bandwidth ?? 1, 1))"]
    if let variant, variant.width > 0, variant.height > 0 { stream.append("RESOLUTION=\(variant.width)x\(variant.height)") }
    if let codecs = variant?.codecs, !codecs.isEmpty { stream.append("CODECS=\"\(codecs)\"") }
    stream.append("AUDIO=\"audio\"")
    lines.append("#EXT-X-STREAM-INF:" + stream.joined(separator: ","))
    lines.append("video.m3u8")
    return lines.joined(separator: "\n") + "\n"
  }
}
