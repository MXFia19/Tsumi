import SwiftUI
import UIKit

// Settings page (common/routes/settings/SettingsPage.svelte): Player, Interface, Discord (the rich presence
// settings of the Interface tab, plus the Discord account), Extensions, Profiles (opens the profiles modal),
// App. Shared building blocks: SettingCard.svelte, ClampedNumber.svelte, the settings bindings and the default
// values of common/modules/settings.js (setDefaults / resetSettings).

/// Screens of the Settings stack.
enum ShellSettingsRoute: Hashable {
  case player
  case interface
  case discord
  case extensions
  case app
  case animeSections
  case westernSections
  case homeSections
  case animeSection(String)
  case westernSection(String)
}

@MainActor
struct SettingsView: View {
  var body: some View {
    List {
      ShellUpdateSection()
      Section {
        NavigationLink(value: ShellSettingsRoute.player) {
          Label("Player", systemImage: "play.fill")
        }
        NavigationLink(value: ShellSettingsRoute.interface) {
          Label("Interface", systemImage: "macwindow")
        }
        NavigationLink(value: ShellSettingsRoute.discord) {
          Label("Discord", systemImage: "gamecontroller")
        }
        NavigationLink(value: ShellSettingsRoute.extensions) {
          Label("Extensions", systemImage: "puzzlepiece.extension")
        }
        Button {
          AppRouter.shared.showProfiles = true
        } label: {
          Label("Profiles", systemImage: "person")
            .foregroundStyle(Color.primary)
        }
        NavigationLink(value: ShellSettingsRoute.app) {
          Label("App", systemImage: "square.grid.2x2")
        }
        NavigationLink {
          ShellWidgetsSettingsView()
        } label: {
          Label("Widgets", systemImage: "square.text.square")
        }
      }
      Section {
        Text("Restart may be required for some settings to take effect.")
        Text("If you don't know what settings do what, use defaults.")
        Text(ShellAppInfo.versionLine)
      }
      .font(.footnote)
      .foregroundStyle(Color.secondary)
    }
    .navigationTitle("Settings")
    .navigationDestination(for: ShellSettingsRoute.self) { route in
      ShellSettingsDestination(route: route)
    }
  }
}

@MainActor
struct ShellSettingsDestination: View {
  let route: ShellSettingsRoute

  var body: some View {
    switch route {
    case .player:
      ShellPlayerSettingsView()
    case .interface:
      ShellInterfaceSettingsView()
    case .discord:
      ShellDiscordSettingsView()
    case .extensions:
      ShellExtensionsSettingsScreen()
    case .app:
      ShellAppSettingsView()
    case .animeSections:
      ShellAnimeSectionsView()
    case .westernSections:
      ShellWesternSectionsView()
    case .homeSections:
      ShellHomeSectionsView()
    case .animeSection(let title):
      ShellAnimeSectionEditor(initialTitle: title)
    case .westernSection(let title):
      ShellWesternSectionEditor(initialTitle: title)
    }
  }
}

/// ExtensionTab.svelte (the view draws its own "Extensions" header).
@MainActor
struct ShellExtensionsSettingsScreen: View {
  var body: some View {
    ExtensionSettingsView()
      .background(Color.black)
      .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Building blocks

/// Title + description of a SettingCard.
@MainActor
struct ShellSettingText: View {
  let title: String
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.primary)
      if !description.isEmpty {
        Text(description)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
  }
}

/// SettingCard.svelte with a control on the trailing side.
@MainActor
struct ShellSettingCard<Control: View>: View {
  let title: String
  let description: String
  let control: Control

  init(title: String, description: String, @ViewBuilder control: () -> Control) {
    self.title = title
    self.description = description
    self.control = control()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        Text(title)
          .font(.body.weight(.semibold))
        Spacer(minLength: 8)
        control
      }
      if !description.isEmpty {
        Text(description)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
  }
}

/// SettingCard with a custom-switch.
@MainActor
struct ShellSettingToggle: View {
  let title: String
  let description: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      ShellSettingText(title: title, description: description)
    }
  }
}

/// SettingCard with a <select>.
@MainActor
struct ShellSettingPicker: View {
  let title: String
  let description: String
  let options: [ShellOption]
  @Binding var selection: String

  var body: some View {
    Picker(selection: $selection) {
      ForEach(options) { option in
        Text(option.label).tag(option.value)
      }
    } label: {
      ShellSettingText(title: title, description: description)
    }
    .pickerStyle(.menu)
  }
}

/// <option value='...'>label</option>
struct ShellOption: Identifiable, Hashable {
  let value: String
  let label: String
  var id: String { value }

  init(_ value: String, _ label: String) {
    self.value = value
    self.label = label
  }
}

/// ClampedNumber.svelte: number input clamped to a range on commit (return key or focus loss).
@MainActor
struct ShellClampedNumberField: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String

  @State private var text = ""
  @FocusState private var focused: Bool

  init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) {
    _value = value
    self.range = range
    self.step = step
    self.unit = unit
  }

  var body: some View {
    HStack(spacing: 6) {
      TextField("", text: $text)
        .keyboardType(.numbersAndPunctuation)
        .submitLabel(.done)
        .multilineTextAlignment(.trailing)
        .frame(width: 70)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit { commit() }
      Text(unit)
        .foregroundStyle(Color.secondary)
    }
    .onAppear { text = Self.format(value) }
    .onChange(of: focused) { _, isFocused in
      if !isFocused { commit() }
    }
    .onChange(of: value) { _, newValue in
      if !focused { text = Self.format(newValue) }
    }
  }

  private func commit() {
    let parsed = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? value
    var clamped = min(max(parsed, range.lowerBound), range.upperBound)
    if step > 0 {
      clamped = (clamped / step).rounded() * step
      clamped = min(max(clamped, range.lowerBound), range.upperBound)
    }
    if clamped != value { value = clamped }
    text = Self.format(clamped)
  }

  static func format(_ number: Double) -> String {
    if number.rounded() == number { return String(Int(number)) }
    return String(format: "%.1f", number)
  }
}

/// Bindings to AppSettings.shared.values (the `settings` store of settings.js).
@MainActor
enum ShellBind {
  static func value<T>(_ keyPath: WritableKeyPath<SettingsValues, T>) -> Binding<T> {
    Binding(
      get: { AppSettings.shared.values[keyPath: keyPath] },
      set: { AppSettings.shared.values[keyPath: keyPath] = $0 }
    )
  }
}

/// Version line of the settings sidebar / About This App (`v${version} ${platform} ${arch}`).
@MainActor
enum ShellAppInfo {
  static var version: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.1"
  }

  static var build: String {
    (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
  }

  static var versionLine: String {
    "v\(version) iOS \(UIDevice.current.systemVersion) (\(build))"
  }
}

/// Default values (settings.js setDefaults / cache.resetSettings).
@MainActor
enum ShellSettingsDefaults {
  private static let layoutKey = "tsumi.shell.svelteLayoutApplied"

  /// settings.js setDefaults: the 14 section base layout plus the custom / western sections not in it.
  static func svelteLayout(_ values: SettingsValues) -> [HomeSectionSetting] {
    var layout = HomeSectionsService.defaultLayout
    var titles = Set(layout.map { $0.title })
    for custom in values.customSections where !titles.contains(custom.title) {
      layout.append(HomeSectionSetting(title: custom.title, sort: "TRENDING_DESC", formats: ["TV", "MOVIE"]))
      titles.insert(custom.title)
    }
    for western in values.westernSections where !titles.contains(western.title) {
      layout.append(HomeSectionSetting(title: western.title, sort: "N/A", formats: ["TV", "MOVIE"]))
      titles.insert(western.title)
    }
    return layout
  }

  /// Once: a layout still equal to Core's short default becomes the Svelte default layout.
  static func applySvelteLayoutOnce() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: layoutKey) else { return }
    defaults.set(true, forKey: layoutKey)
    let values = AppSettings.shared.values
    if values.homeSections == HomeSectionSetting.defaults {
      AppSettings.shared.values.homeSections = svelteLayout(values)
    }
  }

  /// "Reset to Defaults" (cache.resetSettings: `{ ...defaults }`): every setting of the app, including the
  /// ones stored outside Core (player preferences, card type) and the installed extensions (`extensions: {}`).
  static func resetAll() {
    var values = SettingsValues()
    values.homeSections = svelteLayout(values)
    AppSettings.shared.values = values
    PlayerPreferences.resetAll()
    UserDefaults.standard.set(BrowseCardMode.small.rawValue, forKey: BrowseCardMode.storageKey)
    ExtensionManager.shared.removeAll()
  }
}
