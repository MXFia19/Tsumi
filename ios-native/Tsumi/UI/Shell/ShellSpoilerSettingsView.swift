import SwiftUI

// Settings > Interface > Spoiler Protection (common/routes/settings/components/SpoilerSettings.svelte): the level and
// the list statuses it applies to. The rules are in Core/SpoilerProtection.swift.

@MainActor
struct ShellSpoilerSettingsSection: View {
  var body: some View {
    let values = AppSettings.shared.values
    return Section {
      ShellSettingPicker(
        title: "Spoiler Protection",
        description: SpoilerProtection.description,
        options: SpoilerLevel.allCases.map { ShellOption($0.rawValue, $0.label) },
        selection: levelBinding
      )
      if SpoilerProtection.level(values) != .off {
        ShellSpoilerStatusEditor()
      }
    } header: {
      Text("Spoiler Protection")
    }
  }

  private var levelBinding: Binding<String> {
    Binding(
      get: { SpoilerProtection.level(AppSettings.shared.values).rawValue },
      set: { value in AppSettings.shared.values.spoilers = value }
    )
  }
}

/// "Spoiler Protection Statuses": list statuses (+ Not on List) with add / change / remove, like the Releases
/// Notifications editor.
@MainActor
struct ShellSpoilerStatusEditor: View {
  private var selected: [String] {
    var result: [String] = []
    for value in AppSettings.shared.values.spoilerStatus where !result.contains(value) {
      result.append(value)
    }
    return result
  }

  var body: some View {
    let selected = self.selected
    let options = SpoilerProtection.statusOptions
    let unused = options.filter { !selected.contains($0.value) }
    return VStack(alignment: .leading, spacing: 10) {
      ShellSettingText(title: "Spoiler Protection Statuses", description: SpoilerProtection.statusDescription)
      ForEach(selected, id: \.self) { value in
        HStack(spacing: 12) {
          Picker("Status", selection: replaceBinding(value)) {
            ForEach(options.filter { !selected.contains($0.value) || $0.value == value }) { option in
              Text(option.label).tag(option.value)
            }
            // A status the app does not offer (e.g. Completed from an imported settings file) stays selectable.
            if !options.contains(where: { $0.value == value }) {
              Text(value.capitalized).tag(value)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          Spacer()
          Button(role: .destructive) {
            store(selected.filter { $0 != value })
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove")
        }
      }
      Menu {
        ForEach(unused) { option in
          Button(option.label) { store(selected + [option.value]) }
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

  private func store(_ list: [String]) {
    var result: [String] = []
    for value in list where !value.isEmpty && !result.contains(value) {
      result.append(value)
    }
    AppSettings.shared.values.spoilerStatus = result
  }
}
