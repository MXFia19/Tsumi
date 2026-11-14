import SwiftUI
import UserNotifications

// Settings > Interface (common/routes/settings/tabs/InterfaceTab.svelte): interface options, notification
// settings and home screen settings. UI Scale maps to a Dynamic Type size and the CSS variables are reduced to
// an accent colour (App/TsumiApp.swift). The Discord rich presence settings are in Settings > Discord
// (ShellDiscordSettingsView); desktop only options (expandable sidebar, ANGLE backend) have no iOS equivalent.

@MainActor
struct ShellInterfaceSettingsView: View {
  var body: some View {
    Form {
      ShellInterfaceOptionsSection()
      ShellNotificationSettingsSection()
      ShellHomeScreenSettingsSection()
    }
    .navigationTitle("Interface")
  }
}

/// "Interface Settings" group.
@MainActor
struct ShellInterfaceOptionsSection: View {
  /// settings.cards (Small / Full), stored where the Browse screens read it.
  @AppStorage(BrowseCardMode.storageKey) private var cardMode = BrowseCardMode.small.rawValue

  var body: some View {
    let values = AppSettings.shared.values
    let aniListAuth = ProfilesService.shared.isAniList
    return Section {
      ShellSettingPicker(
        title: "Scale",
        description: "Adjust the size of text, buttons, and other interface elements to match your preference and screen size. 100% follows the iOS text size.",
        options: TsumiAppearanceStyle.scales.map { ShellOption(String($0), "\(Int(($0 * 100).rounded()))%") },
        selection: scaleBinding
      )
      ShellSettingCard(
        title: "Accent Color",
        description: "Color of the buttons, switches and selections (the accent color variable of the desktop themes)."
      ) {
        HStack(spacing: 10) {
          if !values.accentColor.isEmpty {
            Button("Reset") { AppSettings.shared.values.accentColor = "" }
              .buttonStyle(.borderless)
          }
          ColorPicker("Accent Color", selection: accentBinding, supportsOpacity: false)
            .labelsHidden()
        }
      }
      ShellSettingToggle(
        title: "Expandable Lists",
        description: "Choose whether lists like recommendations or relations, open as dropdowns or scroll horizontally. Scrollable lists work better on smaller screens.",
        isOn: ShellBind.value(\.toggleList)
      )
      if !aniListAuth {
        ShellSettingPicker(
          title: "Preferred Title Language",
          description: "What title language to automatically select when displaying the title of an anime.",
          options: [ShellOption(TitleLanguage.romaji.rawValue, "Japanese"), ShellOption(TitleLanguage.english.rawValue, "English")],
          selection: titleLanguageBinding
        )
      }
      ShellSettingPicker(
        title: "Card Type",
        description: "What type of cards to display in menus.",
        options: [ShellOption(BrowseCardMode.small.rawValue, "Small"), ShellOption(BrowseCardMode.full.rawValue, "Full")],
        selection: $cardMode
      )
      if cardMode != BrowseCardMode.full.rawValue {
        ShellSettingToggle(
          title: "Card Preview",
          description: "If a detailed preview card should be shown when tapping or hovering over the small card.",
          isOn: ShellBind.value(\.cardPreview)
        )
      }
      ShellSettingToggle(
        title: "Card Audio",
        description: "If the sub, dub, partial dub, and age rating icons should be shown on the cards, the corresponding episode number will be shown when possible. Additionally a label will be shown on the preview cards, anime view, episode cards, and the home banner of the highest possible audio available, either dub, partial dub, or sub. Note these will not be visible when viewing the schedule page. ",
        isOn: ShellBind.value(\.cardAudio)
      )
      ShellSettingToggle(
        title: "Prefer Dubs",
        description: "If your progress on a series matches the latest aired dubbed episode, the series will be hidden from Continue Watching until the next dub is available. Notifications will only be sent when a dubbed episode is released or if the series is sub-only (i.e., no dub exists).\n\nIf your progress goes beyond the latest dubbed episode, this setting will be ignored and the series will be treated as subbed. The Subbed Releases section will automatically hide dubbed series, and Dubbed Releases will hide subbed ones.\n\nThis setting is ideal for viewers who prefer dubbed content whenever available.",
        isOn: ShellBind.value(\.preferDubs)
      )
      ShellSettingPicker(
        title: "Adult Content",
        description: "Adult enables searching for adult (18+) rated anime, typically series with nudity. Hentai enables searching straight up Hentai. This includes adding the Hentai home feed, Hentai genre, and Hentai related tags for search queries.",
        options: [ShellOption("none", "None"), ShellOption("adult", "Adult"), ShellOption("hentai", "Hentai")],
        selection: ShellBind.value(\.adult)
      )
      if values.adult == "hentai" {
        ShellSettingToggle(
          title: "Hentai Banner",
          description: "Changes the displayed series on the home page banner to be exclusively Hentai.",
          isOn: ShellBind.value(\.hentaiBanner)
        )
      }
    } header: {
      Text("Interface Settings")
    }
  }

  /// settings.uiScale, shown as the closest scale choice.
  private var scaleBinding: Binding<String> {
    Binding(
      get: { String(TsumiAppearanceStyle.nearestScale(AppSettings.shared.values.uiScale)) },
      set: { value in AppSettings.shared.values.uiScale = Double(value) ?? 1 }
    )
  }

  /// "#RRGGBB" accent color (the app default while empty).
  private var accentBinding: Binding<Color> {
    Binding(
      get: { TsumiAppearanceStyle.color(hex: AppSettings.shared.values.accentColor) ?? Color.accentColor },
      set: { color in AppSettings.shared.values.accentColor = TsumiAppearanceStyle.hex(color) }
    )
  }

  /// <select bind:value={settings.titleLang}> with Japanese (romaji) and English.
  private var titleLanguageBinding: Binding<String> {
    Binding(
      get: {
        AppSettings.shared.values.titleLang == .romaji ? TitleLanguage.romaji.rawValue : TitleLanguage.english.rawValue
      },
      set: { value in
        AppSettings.shared.values.titleLang = TitleLanguage(rawValue: value) ?? .english
      }
    )
  }
}

/// "Notification Settings" group.
@MainActor
struct ShellNotificationSettingsSection: View {
  static let announceOptions = [ShellOption("all", "All"), ShellOption("following", "Following"), ShellOption("none", "None")]

  var body: some View {
    let values = AppSettings.shared.values
    let aniListAuth = ProfilesService.shared.isAniList
    return Section {
      ShellSettingToggle(
        title: "System Notifications",
        description: "Allows custom system notifications to be sent, with this disabled you will still get in-app notifications. If you enable system notifications and have MULTIPLE Notification Feeds specified, such as Releases and Anilist you WILL be spammed with multiple notifications. Consider choosing a single feed based on your needs.",
        isOn: systemNotifyBinding
      )
      if aniListAuth {
        ShellSettingPicker(
          title: "AniList Notifications",
          description: "Get notifications from your AniList account, showing when episodes have aired and any new anime titles you are following have been added to the database. Limited will only get important notifications like when a new season is announced.",
          options: [ShellOption("all", "All"), ShellOption("limited", "Limited"), ShellOption("none", "None")],
          selection: ShellBind.value(\.aniNotify)
        )
      }
      ShellSettingPicker(
        title: "Sub Announcements",
        description: Self.announceDescription("Sub"),
        options: Self.announceOptions,
        selection: ShellBind.value(\.subAnnounce)
      )
      ShellSettingPicker(
        title: "Dub Announcements",
        description: Self.announceDescription("Dub"),
        options: Self.announceOptions,
        selection: ShellBind.value(\.dubAnnounce)
      )
      if values.adult == "hentai" {
        ShellSettingPicker(
          title: "Hentai Announcements",
          description: Self.announceDescription("Hentai"),
          options: Self.announceOptions,
          selection: ShellBind.value(\.hentaiAnnounce)
        )
      }
      ShellReleasesNotifyEditor()
    } header: {
      Text("Notification Settings")
    }
  }

  static func announceDescription(_ type: String) -> String {
    "Get \(type) announcement notifications when an airing date is confirmed. Choose to get all announcements, updates on sequels for related anime you're following, or turn off notifications entirely."
  }

  /// Turning system notifications on asks for the iOS permission.
  private var systemNotifyBinding: Binding<Bool> {
    Binding(
      get: { AppSettings.shared.values.systemNotify },
      set: { value in
        AppSettings.shared.values.systemNotify = value
        if value {
          Task { @MainActor in
            _ = await AppNotificationsService.shared.requestAuthorization()
          }
        }
      }
    )
  }
}

/// "Releases Notifications": list of list statuses (+ Not on List) with add / change / remove.
@MainActor
struct ShellReleasesNotifyEditor: View {
  static let notOnListValue = SettingsValues.notOnListValue
  static let options: [ShellOption] = [
    ShellOption(ListStatus.current.rawValue, "Watching"),
    ShellOption(ListStatus.planning.rawValue, "Planning"),
    ShellOption(ListStatus.paused.rawValue, "Paused"),
    ShellOption(ListStatus.completed.rawValue, "Completed"),
    ShellOption(ListStatus.dropped.rawValue, "Dropped"),
    ShellOption(ListStatus.repeating.rawValue, "Rewatching"),
    ShellOption(notOnListValue, "Not on List")
  ]

  private var selected: [String] {
    let values = AppSettings.shared.values
    return values.releasesNotify.map { $0.rawValue } + (values.releasesNotifyNotOnList ? [Self.notOnListValue] : [])
  }

  var body: some View {
    let selected = self.selected
    let unused = Self.options.filter { !selected.contains($0.value) }
    return VStack(alignment: .leading, spacing: 10) {
      ShellSettingText(
        title: "Releases Notifications",
        description: "When a new episode is added to any of the Releases feeds, a notification will be sent depending on your list status."
      )
      ForEach(selected, id: \.self) { value in
        HStack(spacing: 12) {
          Picker("Status", selection: replaceBinding(value)) {
            ForEach(Self.options.filter { !selected.contains($0.value) || $0.value == value }) { option in
              Text(option.label).tag(option.value)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          Spacer()
          Button(role: .destructive) {
            remove(value)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove")
        }
      }
      Menu {
        ForEach(unused) { option in
          Button(option.label) { add(option.value) }
        }
      } label: {
        Label("Add Status", systemImage: "plus")
      }
      .buttonStyle(.borderless)
      .disabled(unused.isEmpty)
    }
    .padding(.vertical, 2)
  }

  private func replaceBinding(_ value: String) -> Binding<String> {
    Binding(
      get: { value },
      set: { newValue in
        guard newValue != value else { return }
        var list = selected
        if let index = list.firstIndex(of: value) { list[index] = newValue }
        store(list)
      }
    )
  }

  private func add(_ value: String) {
    var list = selected
    if !list.contains(value) { list.append(value) }
    store(list)
  }

  private func remove(_ value: String) {
    store(selected.filter { $0 != value })
  }

  private func store(_ list: [String]) {
    var statuses: [ListStatus] = []
    for value in list {
      if let status = ListStatus(rawValue: value), !statuses.contains(status) { statuses.append(status) }
    }
    var values = AppSettings.shared.values
    values.releasesNotify = statuses
    values.releasesNotifyNotOnList = list.contains(Self.notOnListValue)
    AppSettings.shared.values = values
  }
}

/// "Home Screen Settings" group.
@MainActor
struct ShellHomeScreenSettingsSection: View {
  var body: some View {
    _ = AppSettings.shared.values
    let authorized = ProfilesService.shared.isAuthorized
    return Section {
      if authorized {
        ShellSettingToggle(
          title: "Hide My Anime",
          description: "The anime on your Watching, Rewatching, Completed, and Dropped list will automatically be hidden from the default sections, this excludes user specific feeds.",
          isOn: ShellBind.value(\.hideMyAnime)
        )
      }
      ShellSettingPicker(
        title: "Hero Content",
        description: "What content to display on the home screen hero banner section. Balanced interleaves trending Anime and Western media, while the others restrict it to a single source.",
        options: [ShellOption("mix", "Balanced (50/50)"), ShellOption("anime", "Anime (AniList)"), ShellOption("western", "Western (TMDB)")],
        selection: ShellBind.value(\.bannerProvider)
      )
      NavigationLink(value: ShellSettingsRoute.animeSections) {
        ShellSettingText(title: "Anime Sections", description: "Create custom anime sections that can be added to the home screen. These use AniList genres and tags.")
      }
      NavigationLink(value: ShellSettingsRoute.westernSections) {
        ShellSettingText(title: "Western Sections (TMDB)", description: "Create custom western media sections powered by TMDB. These filter out anime and use TMDB genres.")
      }
      NavigationLink(value: ShellSettingsRoute.homeSections) {
        ShellSettingText(title: "Sections And Order", description: "Sections and their order on the home screen. Custom Anime and Western sections created above can be added here. Drag/drop these sections to re-order them.")
      }
    } header: {
      Text("Home Screen Settings")
    }
  }
}
