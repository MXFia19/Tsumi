import SwiftUI

// Settings > Widgets: state of the data shared with the widgets, the lock screen countdown (Live Activity)
// options and the running countdowns. Plus the "Countdown on Lock Screen" button of the details.

@MainActor
struct ShellWidgetsSettingsView: View {
  @State private var refreshing = false

  var body: some View {
    let live = LiveCountdownManager.shared
    return Form {
      ShellWidgetsDataSection(refreshing: $refreshing)
      ShellLiveCountdownSection()
      if !live.running.isEmpty {
        Section {
          ForEach(live.running) { item in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                  .font(.body.weight(.semibold))
                  .lineLimit(1)
                Text("Episode \(item.episode) · \(item.airingAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.footnote)
                  .foregroundStyle(Color.secondary)
              }
              Spacer(minLength: 8)
              Button("End") {
                Task { await live.stop(mediaId: item.mediaId) }
              }
              .buttonStyle(.bordered)
            }
          }
          Button("End All Countdowns", role: .destructive) {
            Task { await live.endAll() }
          }
        } header: {
          Text("On the Lock Screen")
        }
      }
    }
    .navigationTitle("Widgets")
    .onAppear {
      live.reload()
    }
  }
}

/// Shared container status and manual refresh.
@MainActor
private struct ShellWidgetsDataSection: View {
  @Binding var refreshing: Bool

  var body: some View {
    let bridge = TsumiWidgetBridge.shared
    return Section {
      VStack(alignment: .leading, spacing: 4) {
        Text("Shared Data")
          .font(.body.weight(.semibold))
        if !bridge.isResolved {
          Text("Checking…")
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        } else if let location = bridge.location {
          Text("Widgets read your lists from Tsumi (\(location.group)).")
            .font(.footnote)
            .foregroundStyle(Color.secondary)
          if let lastWrite = bridge.lastWrite {
            Text("Updated \(lastWrite.formatted(date: .omitted, time: .shortened)).")
              .font(.footnote)
              .foregroundStyle(Color.secondary)
          }
        } else {
          Text("Not available: this install was signed without an App Group, so the widgets can't read Tsumi's data. Touch and hold a Tsumi widget, choose Edit Widget and enter your AniList username: the widget then loads your public AniList list by itself.")
            .font(.footnote)
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error = bridge.lastError {
          Text(error)
            .font(.footnote)
            .foregroundStyle(Color.red)
        }
      }
      .padding(.vertical, 2)
      Button {
        refreshing = true
        Task {
          await bridge.writeNow(force: true)
          refreshing = false
        }
      } label: {
        HStack {
          Text("Refresh Widgets")
          if refreshing {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(refreshing)
    } header: {
      Text("Home Screen Widgets")
    } footer: {
      Text("Touch and hold the Home Screen, tap Edit > Add Widget and search for Tsumi: Continue Watching (small, medium, large) and Next Episode (small, medium, and Lock Screen). A widget set to an AniList username shows that user's public list instead of the signed-in account.")
    }
    .task {
      _ = await bridge.resolveLocation()
    }
  }
}

/// Live Activity options.
@MainActor
private struct ShellLiveCountdownSection: View {
  var body: some View {
    let preferences = TsumiWidgetPreferences.shared
    let live = LiveCountdownManager.shared
    return Section {
      Toggle(isOn: Binding(
        get: { preferences.values.liveActivityAutoStart },
        set: { preferences.values.liveActivityAutoStart = $0 }
      )) {
        ShellSettingText(
          title: "Start Automatically",
          description: "When Tsumi is open, puts a countdown on the Lock Screen for the shows on your Watching, Rewatching and Planning lists that air soon (once per episode)."
        )
      }
      Picker(selection: Binding(
        get: { preferences.values.liveActivityLeadHours },
        set: { preferences.values.liveActivityLeadHours = $0 }
      )) {
        ForEach(TsumiWidgetPreferences.leadHourChoices, id: \.self) { hours in
          Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(hours)
        }
      } label: {
        ShellSettingText(title: "Airing Within", description: "How long before an episode airs its countdown starts.")
      }
      .disabled(!preferences.values.liveActivityAutoStart)
      if !live.isEnabled {
        Text("Live Activities are turned off for Tsumi. Turn them on in the iOS Settings app (Settings > Tsumi > Live Activities).")
          .font(.footnote)
          .foregroundStyle(Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Lock Screen Countdown")
    } footer: {
      Text("Start one from the details of an airing show (timer button). iOS lets Tsumi start a countdown only while it is open, and ends any Live Activity after 8 hours. When the episode airs it shows \"Out now\", then goes away about an hour later.")
    }
  }
}

/// Timer button of the details actions: starts / stops the lock screen countdown of an airing title.
@MainActor
struct LiveCountdownDetailButton: View {
  let media: Media

  var body: some View {
    let manager = LiveCountdownManager.shared
    let active = manager.activeMediaIds.contains(media.id)
    if active || LiveCountdownManager.nextAiring(for: media) != nil {
      Menu {
        if active {
          Button(role: .destructive) {
            Task { await manager.stop(mediaId: media.id) }
          } label: {
            Label("Stop Lock Screen Countdown", systemImage: "timer")
          }
        } else {
          Button {
            Task { await manager.start(media) }
          } label: {
            Label("Countdown on Lock Screen", systemImage: "timer")
          }
        }
      } label: {
        Image(systemName: active ? "timer.circle.fill" : "timer")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(active ? BrowsePalette.tertiary : Color.white)
          .frame(width: 44, height: 44)
          .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .accessibilityLabel(active ? "Stop Lock Screen Countdown" : "Countdown on Lock Screen")
    }
  }
}
