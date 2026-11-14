import SwiftUI

// Settings > Player (common/routes/settings/tabs/PlayerTab.svelte). The libass options (default font,
// missing fonts, fast rendering, render resolution), Deband and the external player executable do not
// exist on iOS; "Auto Picture in Picture" is the iOS addition of the player module.

@MainActor
struct ShellPlayerSettingsView: View {
  var body: some View {
    _ = AppSettings.shared.values
    return Form {
      Section {
        ShellSettingPicker(
          title: "Preferred Subtitle Language",
          description: "What subtitle language to automatically select when a video is loaded if it exists. This won't find sources with this language automatically. If not found defaults to English.",
          options: ShellPlayerSettingsView.subtitleLanguages,
          selection: ShellBind.value(\.subtitleLanguage)
        )
      } header: {
        Text("Language Settings")
      }
      ShellPlaybackSettingsSection()
      ShellPictureInPictureSection()
    }
    .navigationTitle("Player")
  }

  static let subtitleLanguages: [ShellOption] = [
    ShellOption("", "None"),
    ShellOption("eng", "English"),
    ShellOption("jpn", "Japanese"),
    ShellOption("chi", "Chinese"),
    ShellOption("por", "Portuguese"),
    ShellOption("spa", "Spanish (Spain)"),
    ShellOption("lat", "Spanish (Latin America)"),
    ShellOption("ger", "German"),
    ShellOption("pol", "Polish"),
    ShellOption("cze", "Czech"),
    ShellOption("dan", "Danish"),
    ShellOption("gre", "Greek"),
    ShellOption("fin", "Finnish"),
    ShellOption("fre", "French"),
    ShellOption("hun", "Hungarian"),
    ShellOption("ita", "Italian"),
    ShellOption("kor", "Korean"),
    ShellOption("dut", "Dutch"),
    ShellOption("nor", "Norwegian"),
    ShellOption("rum", "Romanian"),
    ShellOption("rus", "Russian"),
    ShellOption("slo", "Slovak"),
    ShellOption("swe", "Swedish"),
    ShellOption("ara", "Arabic"),
    ShellOption("idn", "Indonesian")
  ]
}

/// "Playback Settings" group.
@MainActor
struct ShellPlaybackSettingsSection: View {
  @State private var chapterSource = PlayerPreferences.chapterSource.rawValue

  var body: some View {
    let autocomplete = AppSettings.shared.values.playerAutocomplete
    return Section {
      ShellSettingToggle(
        title: "Autoplay Next Episode",
        description: "Automatically starts playing next episode when a video ends.",
        isOn: ShellBind.value(\.playerAutoplay)
      )
      ShellSettingToggle(
        title: "Pause On Lost Focus",
        description: "Pauses/Resumes video playback when tabbing in/out of the app.",
        isOn: ShellBind.value(\.playerPause)
      )
      ShellSettingToggle(
        title: "Auto-Complete Episodes",
        description: "Automatically marks episodes as complete on AniList or MyAnimeList when you finish watching them. You must be logged in.",
        isOn: ShellBind.value(\.playerAutocomplete)
      )
      if autocomplete {
        ShellSettingCard(
          title: "Auto-Complete Threshold",
          description: "The percentage of an episode that must be watched before it is automatically marked as complete. A higher value means more of the episode must be watched."
        ) {
          ShellClampedNumberField(value: thresholdBinding, range: 1...100, step: 1, unit: "%")
        }
      }
      ShellSettingCard(
        title: "Seek Duration",
        description: "Seconds to skip forward or backward when using the seek buttons or keyboard shortcuts. Higher values might negatively impact buffering speeds."
      ) {
        ShellClampedNumberField(value: ShellBind.value(\.playerSeek), range: 0.2...360, step: 0.1, unit: "sec")
      }
      ShellSettingPicker(
        title: "Chapter Source Preference",
        description: "The chapter source to use during video playback. If your preferred source isn’t available, another source will be used automatically.",
        options: PlayerChapterSource.allCases.map { ShellOption($0.rawValue, $0.label) },
        selection: $chapterSource
      )
      ShellSettingToggle(
        title: "Auto-Skip Intro/Outro",
        description: "Attempt to automatically skip intro and outro. This WILL sometimes skip incorrect chapters, as some of the chapter data is community sourced.",
        isOn: ShellBind.value(\.playerSkip)
      )
    } header: {
      Text("Playback Settings")
    }
    .onChange(of: chapterSource) { _, value in
      PlayerPreferences.chapterSource = PlayerChapterSource(rawValue: value) ?? .embedded
    }
  }

  private var thresholdBinding: Binding<Double> {
    Binding(
      get: { Double(AppSettings.shared.values.playerAutocompleteThreshold) },
      set: { AppSettings.shared.values.playerAutocompleteThreshold = Int($0.rounded()) }
    )
  }
}

/// iOS addition of the player module (PlayerPreferences.autoPictureInPicture). Off by default, so leaving the
/// app follows "Pause On Lost Focus" like the Svelte app; when it is on, the video keeps playing in PiP (the
/// Svelte handleVisibility does not pause while in Picture in Picture).
@MainActor
struct ShellPictureInPictureSection: View {
  @State private var autoPictureInPicture = PlayerPreferences.autoPictureInPicture

  var body: some View {
    Section {
      ShellSettingToggle(
        title: "Auto Picture in Picture",
        description: "Keeps the video playing in a floating window when you leave the app during playback. Pause On Lost Focus does not apply while the floating window is shown.",
        isOn: $autoPictureInPicture
      )
    } header: {
      Text("Picture in Picture")
    }
    .onChange(of: autoPictureInPicture) { _, value in
      PlayerPreferences.autoPictureInPicture = value
    }
  }
}
