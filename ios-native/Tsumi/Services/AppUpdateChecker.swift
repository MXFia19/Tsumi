import Foundation
import Observation

/// A release of Tsumi newer than the installed app.
struct AppUpdate: Equatable {
  let version: String
  let releaseURL: URL?
}

/// Update check of the sideloaded app (no App Store updates): compares the latest GitHub release of the repository
/// (releases/latest: no drafts, no pre-releases) with CFBundleShortVersionString. It only tells the user; the new IPA
/// comes from the download page or the Feather source (docs/ of the repository, on GitHub Pages).
@MainActor
@Observable
final class AppUpdateChecker {
  static let shared = AppUpdateChecker()

  static let repository = "MXFia19/Tsumi"
  /// Download page (GitHub Pages): direct .ipa link and the Feather / AltStore source.
  static let downloadPage = URL(string: "https://mxfia19.github.io/Tsumi/")!
  private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  /// Launch and return to the foreground check at most this often (the API allows 60 requests per hour and IP).
  private static let minimumInterval: TimeInterval = 6 * 60 * 60
  private static let dismissedKey = "tsumi.update.dismissedVersion"

  /// The newer release, nil when up to date (or not checked yet).
  private(set) var available: AppUpdate?
  /// Version whose banner was closed: the banner stays hidden for it, the Settings row stays.
  private(set) var dismissedVersion: String?
  @ObservationIgnored private var lastCheck: Date?
  @ObservationIgnored private var checking = false

  private init() {
    dismissedVersion = UserDefaults.standard.string(forKey: Self.dismissedKey)
  }

  /// Installed version (CFBundleShortVersionString).
  var installedVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
  }

  var showsBanner: Bool {
    guard let available else { return false }
    return available.version != dismissedVersion
  }

  func checkIfNeeded() async {
    if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.minimumInterval { return }
    await check()
  }

  func check() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      // 404: no published release yet.
      guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 404 else { return }
      lastCheck = Date()
      guard status == 200 else {
        available = nil
        return
      }
      let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
      let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
      if Self.isVersion(version, newerThan: installedVersion) {
        available = AppUpdate(version: version, releaseURL: release.htmlURL)
      } else {
        available = nil
      }
    } catch {
      // Offline or unexpected answer: try again on the next launch / foreground.
    }
  }

  func dismissBanner() {
    guard let available else { return }
    dismissedVersion = available.version
    UserDefaults.standard.set(available.version, forKey: Self.dismissedKey)
  }

  /// "1.10.2" > "1.9" (numeric components, missing ones are 0). False when either is not a version.
  nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    guard let new = components(candidate), let old = components(current) else { return false }
    for index in 0..<max(new.count, old.count) {
      let left = index < new.count ? new[index] : 0
      let right = index < old.count ? old[index] : 0
      if left != right { return left > right }
    }
    return false
  }

  /// Numeric components of "1.2.3" (a suffix such as "-beta" is ignored); nil when there are none.
  nonisolated private static func components(_ version: String) -> [Int]? {
    let numeric = version.prefix { $0.isNumber || $0 == "." }
    let parts = numeric.split(separator: ".").compactMap { Int($0) }
    return parts.isEmpty ? nil : parts
  }
}

/// Fields of GET /repos/{owner}/{repo}/releases/latest used by the update check.
private struct GitHubLatestRelease: Decodable {
  let tagName: String
  let htmlURL: URL?

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}
