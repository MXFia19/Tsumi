import SwiftUI
import UIKit
import UserNotifications

// Settings > App (common/routes/settings/tabs/AppTab.svelte): about, query complexity, resets with
// confirmation (ConfirmButton.svelte), settings import / export / reset, toast levels, app and device info,
// plus the iOS notification permission. Desktop only parts (exit action, DNS over HTTPS, logging levels, log
// files, devtools, updater) and the changelog are not applicable; new versions are announced by AppUpdateChecker
// (Settings row and banner).

/// Actions guarded by "Confirm Reset".
enum ShellResetAction: String, Identifiable {
  case notifications
  case history
  case caches
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .notifications: return "Reset Notifications"
    case .history: return "Reset History"
    case .caches: return "Reset Caches"
    case .settings: return "Reset to Defaults"
    }
  }
}

@MainActor
struct ShellAppSettingsView: View {
  @State private var confirming: ShellResetAction? = nil
  @State private var clearingCaches = false

  var body: some View {
    Form {
      Section {
        ShellSettingCard(
          title: "About This App",
          description: "Restart may be required for some settings to take effect. If you don't know what settings do what, use defaults."
        ) {
          Text(ShellAppInfo.versionLine)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
        ShellQueryComplexityRow()
      } header: {
        Text("App Settings")
      }
      DownloadSettingsSection()
      ShellResetSection(confirming: $confirming, clearingCaches: clearingCaches)
      ShellSettingsManagementSection(confirming: $confirming)
      ShellNotificationPermissionSection()
      ShellDebugSettingsSection()
    }
    .navigationTitle("App")
    .confirmationDialog(
      confirming?.title ?? "",
      isPresented: Binding(
        get: { confirming != nil },
        set: { if !$0 { confirming = nil } }
      ),
      titleVisibility: .visible,
      presenting: confirming
    ) { action in
      Button("Confirm Reset", role: .destructive) {
        perform(action)
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func perform(_ action: ShellResetAction) {
    confirming = nil
    switch action {
    case .notifications:
      // cache.resetNotifications
      AppNotificationsService.shared.reset()
    case .history:
      // cache.resetHistory: episode progress and subtitle choices.
      AnimeProgressService.shared.reset()
      UserDefaults.standard.removeObject(forKey: "tsumi.player.lastSubtitle")
    case .caches:
      // cache.resetCaches (the services reload instead of restarting the app).
      clearingCaches = true
      Task { @MainActor in
        await Services.shared.clearCaches()
        clearingCaches = false
      }
    case .settings:
      ShellSettingsDefaults.resetAll()
    }
  }
}

/// Query Complexity (settings.queryComplexity, anilist.js queryComplexObjects).
@MainActor
struct ShellQueryComplexityRow: View {
  var body: some View {
    _ = AppSettings.shared.values
    return ShellSettingPicker(
      title: "Query Complexity",
      description: "Complex queries result in slower loading times but help in reducing the chances of hitting AniList's rate limit. Simple queries split up the requests into multiple queries which are requested as needed.",
      options: [ShellOption("Complex", "Complex (slow)"), ShellOption("Simple", "Simple (fast)")],
      selection: ShellBind.value(\.queryComplexity)
    )
  }
}

/// Reset Notifications / Reset History / Reset Caches.
@MainActor
struct ShellResetSection: View {
  @Binding var confirming: ShellResetAction?
  let clearingCaches: Bool

  var body: some View {
    Section {
      ShellSettingCard(
        title: "Reset Notifications",
        description: "Resets all notifications that have been cached, this is not recommended unless you are experiencing issues. This will also reset the last time you have been notified, so expect previous notifications to appear again."
      ) {
        Button("Reset") { confirming = .notifications }
          .buttonStyle(.bordered)
      }
      ShellSettingCard(
        title: "Reset History",
        description: "Resets all history data that has been cached, this is not recommended unless you are experiencing issues. You will lose your local episode progress, subtitle choices, and volume boost."
      ) {
        Button("Reset") { confirming = .history }
          .buttonStyle(.bordered)
      }
      ShellSettingCard(
        title: "Reset Caches",
        description: "Resets everything the app has cached, this is not recommended unless you are experiencing issues. Caching speeds up load times and decreases down time. This does not reset the notifications or history cache."
      ) {
        if clearingCaches {
          ProgressView()
        } else {
          Button("Reset") { confirming = .caches }
            .buttonStyle(.bordered)
        }
      }
    }
  }
}

/// Settings Management: Import from Clipboard, Export to Clipboard, Reset to Defaults.
@MainActor
struct ShellSettingsManagementSection: View {
  @Binding var confirming: ShellResetAction?

  var body: some View {
    Section {
      ShellSettingText(
        title: "Settings Management",
        description: "Import saved settings from your clipboard, export your current configuration to back it up or share with others, and restore everything back to default values if needed. This is especially useful for syncing preferences across devices, sharing settings with friends, or starting fresh with recommended defaults."
      )
      Button("Import from Clipboard") { importSettings() }
      Button("Export to Clipboard") { exportSettings() }
      Button("Reset to Defaults", role: .destructive) { confirming = .settings }
    }
  }

  private func importSettings() {
    guard let text = UIPasteboard.general.string, ShellSettingsTransfer.importJSON(text) else {
      ServiceMessages.shared.post(.error, "Failed to import settings", "Failed to import settings from clipboard, make sure the copied data is valid JSON.")
      return
    }
  }

  private func exportSettings() {
    guard let text = ShellSettingsTransfer.exportJSON() else { return }
    ShellClipboard.copy(text, detail: "settings")
  }
}

/// Export / import of the whole settings blob (AppTab.svelte importSettings / Export to Clipboard): the
/// `SettingsValues` keys plus the settings stored elsewhere (`cards`, `playerChapterSkip`,
/// `autoPictureInPicture`, `extensions`). The import is tolerant like settings.js `{ ...defaults, ...stored }`:
/// partial JSON, iOS exports and Svelte / desktop exports (array-shaped sections, 'NOTONLIST' in
/// releasesNotify, `{ key: { url, enabled, manifest } }` extensions) are accepted, unknown keys are ignored,
/// missing `SettingsValues` keys take their default, and the keys stored elsewhere change only when present.
@MainActor
enum ShellSettingsTransfer {
  static let cardsKey = "cards"
  static let chapterSourceKey = "playerChapterSkip"
  static let autoPictureInPictureKey = "autoPictureInPicture"
  static let extensionsKey = "extensions"

  static func exportJSON() -> String? {
    let values = AppSettings.shared.values
    guard let data = try? JSONEncoder().encode(values),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    // Svelte shape of the "Not on List" release option.
    var releases = values.releasesNotify.map { $0.rawValue }
    if values.releasesNotifyNotOnList { releases.append(SettingsValues.notOnListValue) }
    object["releasesNotify"] = releases
    object[cardsKey] = UserDefaults.standard.string(forKey: BrowseCardMode.storageKey) ?? BrowseCardMode.small.rawValue
    object[chapterSourceKey] = PlayerPreferences.chapterSource.rawValue
    object[autoPictureInPictureKey] = PlayerPreferences.autoPictureInPicture
    object[extensionsKey] = exportedExtensions()
    guard let output = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
    return String(data: output, encoding: .utf8)
  }

  /// settings.extensions shape `{ key: { url, enabled, manifest } }`, plus the iOS `key`, `kind` and `order`.
  private static func exportedExtensions() -> [String: Any] {
    var result: [String: Any] = [:]
    let encoder = JSONEncoder()
    for (index, config) in ExtensionManager.shared.installed.enumerated() {
      guard let data = try? encoder.encode(config),
            var entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
      entry["order"] = index
      result[config.key] = entry
    }
    return result
  }

  /// Applies a settings JSON; false when the text is not JSON or holds no known setting.
  static func importJSON(_ text: String) -> Bool {
    guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    var root = parsed
    // The desktop cache entry ({ settings: {...} }) and "App and Device Info" ({ appInfo: { settings } }).
    if let inner = root["settings"] as? [String: Any] {
      root = inner
    } else if let inner = (root["appInfo"] as? [String: Any])?["settings"] as? [String: Any] {
      root = inner
    }
    let known = Set(SettingsValues.allKeys + [cardsKey, chapterSourceKey, autoPictureInPictureKey, extensionsKey])
    guard root.keys.contains(where: { known.contains($0) }),
          let rootData = try? JSONSerialization.data(withJSONObject: root),
          var values = try? JSONDecoder().decode(SettingsValues.self, from: rootData) else { return false }
    if root["homeSections"] == nil {
      // scopedDefaults of settings.js: the full default layout.
      values.homeSections = ShellSettingsDefaults.svelteLayout(values)
    }
    AppSettings.shared.values = values
    if let cards = root[cardsKey] as? String, let mode = BrowseCardMode(rawValue: cards) {
      UserDefaults.standard.set(mode.rawValue, forKey: BrowseCardMode.storageKey)
    }
    if let chapter = root[chapterSourceKey] as? String, let source = PlayerChapterSource(rawValue: chapter) {
      PlayerPreferences.chapterSource = source
    }
    if let autoPiP = root[autoPictureInPictureKey] as? Bool {
      PlayerPreferences.autoPictureInPicture = autoPiP
    }
    if let extensions = root[extensionsKey] as? [String: Any] {
      importExtensions(extensions)
    }
    return true
  }

  /// iOS entries (with `kind`) replace the installed list; Svelte entries are installed from their manifest URL.
  private static func importExtensions(_ entries: [String: Any]) {
    var native: [(order: Int, config: InstalledExtension)] = []
    var manifests: [(url: String, enabled: Bool)] = []
    let decoder = JSONDecoder()
    for (key, value) in entries {
      guard var entry = value as? [String: Any], let url = entry["url"] as? String, !url.isEmpty else { continue }
      if entry["kind"] != nil {
        if entry["key"] == nil { entry["key"] = key }
        if let data = try? JSONSerialization.data(withJSONObject: entry),
           let config = try? decoder.decode(InstalledExtension.self, from: data) {
          native.append((order: (entry["order"] as? Int) ?? Int.max, config: config))
          continue
        }
      }
      manifests.append((url: url, enabled: (entry["enabled"] as? Bool) ?? true))
    }
    if !native.isEmpty {
      let ordered = native.sorted { $0.order < $1.order }.map { $0.config }
      ExtensionManager.shared.replaceInstalled(ordered)
    }
    guard !manifests.isEmpty else { return }
    Task { @MainActor in
      var failed = 0
      for item in manifests {
        do {
          let key = try await ExtensionManager.shared.addExtension(item.url)
          if !item.enabled {
            ExtensionManager.shared.toggleExtension(key, enabled: false)
          }
        } catch {
          failed += 1
        }
      }
      if failed > 0 {
        ServiceMessages.shared.post(.error, "Failed to import extensions", "\(failed) of \(manifests.count) extensions could not be loaded from their manifest URL.")
      }
    }
  }
}

/// iOS permission behind "System Notifications" (UNUserNotificationCenter).
@MainActor
struct ShellNotificationPermissionSection: View {
  @State private var status: UNAuthorizationStatus = .notDetermined
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Section {
      ShellSettingCard(
        title: "Notification Permission",
        description: "System notifications need the iOS permission. In-app notifications work without it."
      ) {
        control
      }
    }
    .task { await refresh() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { @MainActor in await refresh() }
      }
    }
  }

  @ViewBuilder
  private var control: some View {
    switch status {
    case .notDetermined:
      Button("Allow") {
        Task { @MainActor in
          _ = await AppNotificationsService.shared.requestAuthorization()
          await refresh()
        }
      }
      .buttonStyle(.bordered)
    case .denied:
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      .buttonStyle(.bordered)
    default:
      Text("Allowed")
        .foregroundStyle(Color.secondary)
    }
  }

  private func refresh() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    status = settings.authorizationStatus
  }
}

/// Debug Settings: Toast Levels and App and Device Info.
@MainActor
struct ShellDebugSettingsSection: View {
  var body: some View {
    _ = AppSettings.shared.values
    return Section {
      ShellSettingPicker(
        title: "Toast Levels",
        description: "Changes what toasts are shown in the app, limiting what toasts are shown could be useful if an api is down to prevent spam.",
        options: [
          ShellOption("All", "All"),
          ShellOption("Warnings / Successes", "Warnings / Successes"),
          ShellOption("Errors", "Errors"),
          ShellOption("None", "None")
        ],
        selection: ShellBind.value(\.toasts)
      )
      ShellSettingCard(
        title: "App and Device Info",
        description: "Copy app and device debug info and capabilities, such as GPU information, GPU capabilities, version information and settings to clipboard."
      ) {
        Button("Copy To Clipboard") { copyDeviceInfo() }
          .buttonStyle(.bordered)
      }
    } header: {
      Text("Debug Settings")
    }
  }

  private func copyDeviceInfo() {
    var settingsObject: Any = [String: Any]()
    if let data = try? JSONEncoder().encode(AppSettings.shared.values), let object = try? JSONSerialization.jsonObject(with: data) {
      settingsObject = object
    }
    let device = UIDevice.current
    let appInfo: [String: Any] = [
      "version": ShellAppInfo.version,
      "build": ShellAppInfo.build,
      "platform": "ios",
      "systemName": device.systemName,
      "systemVersion": device.systemVersion,
      "model": device.model,
      "settings": settingsObject
    ]
    let info: [String: Any] = ["appInfo": appInfo]
    guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    ShellClipboard.copy(text, detail: "device info")
  }
}

/// clipboard.js copyToClipboard (+ its "Copied to clipboard" toast).
@MainActor
enum ShellClipboard {
  static func copy(_ text: String, detail: String) {
    guard !text.isEmpty else { return }
    UIPasteboard.general.string = text
    ServiceMessages.shared.post(.info, "Copied to clipboard", "Copied \(detail) to clipboard")
  }
}
