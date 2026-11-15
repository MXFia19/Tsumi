import SwiftUI
import UIKit

// Downloads screen (common/routes/downloads/DownloadsPage.svelte): running downloads with progress, pause / resume /
// cancel / retry, and the downloaded episodes by title (play offline, delete), with the storage used. Everything
// comes from DownloadCenter, so it works without network (covers are saved with the episodes).

@MainActor
struct DownloadsView: View {
  @State private var confirmDelete: DownloadItem?
  @State private var confirmDeleteTitle: DownloadTitleGroup?

  var body: some View {
    let center = DownloadCenter.shared
    let items = center.items
    let pending = items.filter { $0.status.isPending }
    let groups = DownloadTitleGroup.groups(items.filter { $0.status == .completed })
    let completedCount = items.filter { $0.status == .completed }.count
    List {
      Section {
        HStack {
          Label("\(DownloadNaming.bytes(center.storageUsed)) used", systemImage: "internaldrive")
          Spacer()
          Text(completedCount == 1 ? "1 episode" : "\(completedCount) episodes")
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        if ShellConnectionMonitor.shared.isOffline {
          Label("You're offline: downloaded episodes still play.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if items.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("No downloads yet")
              .font(.headline)
            Text("Use the download button of an episode in the details of a title, Download Next Episodes next to Watch Now, or Download Episode in the player menu. Downloaded episodes play without internet, with their subtitles.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }
      }
      if !pending.isEmpty {
        Section("In Progress") {
          ForEach(pending) { item in
            DownloadPendingRow(item: item)
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  DownloadCenter.shared.remove(item.id)
                } label: {
                  Label(item.status == .failed || item.status == .paused ? "Delete" : "Cancel", systemImage: "xmark")
                }
              }
          }
        }
      }
      ForEach(groups) { group in
        Section {
          ForEach(group.items) { item in
            DownloadCompletedRow(item: item)
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  confirmDelete = item
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
          }
        } header: {
          HStack {
            Text(group.title)
              .lineLimit(1)
            Spacer()
            Text("\(DownloadNaming.bytes(group.size))")
            Menu {
              Button(role: .destructive) {
                confirmDeleteTitle = group
              } label: {
                Label("Delete All", systemImage: "trash")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More for \(group.title)")
          }
        }
      }
    }
    .navigationTitle("Downloads")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { DownloadCenter.shared.start() }
    .confirmationDialog(
      "Delete this episode?",
      isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
      titleVisibility: .visible,
      presenting: confirmDelete
    ) { item in
      Button("Delete \(item.displayEpisode)", role: .destructive) {
        DownloadCenter.shared.remove(item.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text("The downloaded file of \(AniListService.shared.title(item.media)) is removed from this device.")
    }
    .confirmationDialog(
      "Delete every downloaded episode?",
      isPresented: Binding(get: { confirmDeleteTitle != nil }, set: { if !$0 { confirmDeleteTitle = nil } }),
      titleVisibility: .visible,
      presenting: confirmDeleteTitle
    ) { group in
      Button("Delete \(group.items.count) Episodes", role: .destructive) {
        DownloadCenter.shared.removeAll(mediaKey: group.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: { group in
      Text(group.title)
    }
  }
}

/// Completed downloads of one title.
struct DownloadTitleGroup: Identifiable, Hashable {
  let id: String
  let title: String
  let items: [DownloadItem]
  let size: Int64

  @MainActor
  static func groups(_ items: [DownloadItem]) -> [DownloadTitleGroup] {
    let byMedia = Dictionary(grouping: items) { $0.media.id }
    return byMedia.map { key, list in
      let sorted = list.sorted { lhs, rhs in
        if (lhs.episode.season ?? 0) != (rhs.episode.season ?? 0) { return (lhs.episode.season ?? 0) < (rhs.episode.season ?? 0) }
        return lhs.episode.number < rhs.episode.number
      }
      let title = AniListService.shared.title(sorted[0].media)
      return DownloadTitleGroup(id: key, title: title, items: sorted, size: sorted.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) })
    }
    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }
}

/// Cover saved with the download (works offline), else the remote cover.
@MainActor
struct DownloadCover: View {
  let item: DownloadItem

  var body: some View {
    Group {
      if let file = item.coverFile, let url = DownloadStorage.fileURL(id: item.id, file: file), let image = UIImage(contentsOfFile: url.path) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        BrowseImage([item.media.images.coverLarge, item.media.images.cover], placeholder: BrowsePalette.skeleton)
      }
    }
    .frame(width: 46, height: 66)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

@MainActor
struct DownloadPendingRow: View {
  let item: DownloadItem

  var body: some View {
    HStack(spacing: 12) {
      DownloadCover(item: item)
      VStack(alignment: .leading, spacing: 4) {
        Text(AniListService.shared.title(item.media))
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(episodeLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if item.status == .downloading || item.status == .paused {
          ProgressView(value: item.progress)
            .tint(item.status == .paused ? Color.secondary : Color.accentColor)
        }
        HStack(spacing: 4) {
          if item.status == .resolving {
            ProgressView()
              .controlSize(.mini)
          }
          if item.status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          Text(statusText)
            .lineLimit(3)
        }
        .font(.caption)
        .foregroundStyle(item.status == .failed ? BrowsePalette.danger : Color.secondary)
      }
      Spacer(minLength: 0)
      actionButton
    }
    .padding(.vertical, 2)
  }

  /// Spoiler protection (Core/SpoilerProtection.swift) leaves the title out after the list progress.
  private var episodeLine: String {
    let hidden = SpoilerProtection.hidesEpisode(.episodeTitle, entry: BrowseMediaInfo.entry(item.media), episode: item.episode.number)
    if let title = item.episodeTitle, !title.isEmpty, !hidden { return "\(item.displayEpisode) - \(title)" }
    return item.displayEpisode
  }

  private var statusText: String {
    switch item.status {
    case .queued: return item.attempts > 0 ? "Waiting to retry with a fresh link…" : "Queued"
    case .resolving: return "Getting a fresh link from the extension…"
    case .paused:
      return item.bytes > 0 ? "Paused · \(DownloadNaming.bytes(item.bytes))" : "Paused"
    case .failed: return item.error ?? "Download failed"
    case .downloading:
      var parts = ["\(Int(item.progress * 100))%"]
      if item.bytes > 0 {
        parts.append(item.totalBytes > 0 ? "\(DownloadNaming.bytes(item.bytes)) of \(item.kind == .hlsFiles ? "~" : "")\(DownloadNaming.bytes(item.totalBytes))" : DownloadNaming.bytes(item.bytes))
      }
      if let quality = item.quality { parts.append("\(quality)p") }
      return parts.joined(separator: " · ")
    case .completed: return ""
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    let center = DownloadCenter.shared
    switch item.status {
    case .failed:
      button("arrow.clockwise", label: "Retry") { center.resume(item.id) }
    case .paused:
      button("play.fill", label: "Resume") { center.resume(item.id) }
    default:
      button("pause.fill", label: "Pause") { center.pause(item.id) }
    }
  }

  private func button(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 36, height: 36)
        .background(BrowsePalette.cardStrong, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

@MainActor
struct DownloadCompletedRow: View {
  let item: DownloadItem

  var body: some View {
    Button {
      DownloadCenter.shared.play(item)
    } label: {
      HStack(spacing: 12) {
        DownloadCover(item: item)
        VStack(alignment: .leading, spacing: 4) {
          Text(episodeLine)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
          Text(details)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "play.circle.fill")
          .font(.title2)
          .foregroundStyle(.white)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Play \(episodeLine) offline")
  }

  /// Spoiler protection (Core/SpoilerProtection.swift) leaves the title out after the list progress.
  private var episodeLine: String {
    let hidden = SpoilerProtection.hidesEpisode(.episodeTitle, entry: BrowseMediaInfo.entry(item.media), episode: item.episode.number)
    if let title = item.episodeTitle, !title.isEmpty, !hidden { return "\(item.displayEpisode) - \(title)" }
    return item.displayEpisode
  }

  private var details: String {
    var parts = [DownloadNaming.bytes(item.sizeOnDisk ?? item.bytes)]
    if let quality = item.quality { parts.append("\(quality)p") }
    if item.subtitleFile != nil { parts.append("Subtitles") }
    if let name = item.source?.extensionName { parts.append(name) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Entry points

/// Download state / action of one episode (EpisodeList.svelte download button): download, play the downloaded
/// file, retry a failed download, or open the Downloads screen while it runs.
@MainActor
struct DownloadEpisodeButton: View {
  let media: Media
  let episode: EpisodeRef
  var title: String?

  var body: some View {
    let item = DownloadCenter.shared.item(media: media, episode: episode)
    Button {
      guard let item else {
        DownloadCenter.shared.download(media: media, episodes: [(ref: episode, title: title)])
        return
      }
      switch item.status {
      case .completed: DownloadCenter.shared.play(item)
      case .failed: DownloadCenter.shared.resume(item.id)
      default: DownloadNavigation.open()
      }
    } label: {
      icon(item)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label(item))
  }

  @ViewBuilder
  private func icon(_ item: DownloadItem?) -> some View {
    switch item?.status {
    case .none:
      Image(systemName: "arrow.down.to.line")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(BrowsePalette.success)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(BrowsePalette.danger)
    case .paused:
      Image(systemName: "pause.circle")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    case .downloading:
      ZStack {
        Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
        Circle()
          .trim(from: 0, to: max(item?.progress ?? 0, 0.02))
          .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 18, height: 18)
    default:
      ProgressView()
        .controlSize(.small)
    }
  }

  private func label(_ item: DownloadItem?) -> String {
    switch item?.status {
    case .none: return "Download episode"
    case .completed: return "Downloaded: play offline"
    case .failed: return "Download failed: retry"
    case .paused: return "Download paused"
    case .downloading: return "Downloading \(Int((item?.progress ?? 0) * 100))%"
    default: return "Download queued"
    }
  }
}

/// "Download Next Episodes" of the details (next to Watch Now): 1 / 3 / 5 / 12 episodes after the list progress, or
/// all the released ones left. TMDB shows are downloaded episode by episode from the episode list.
@MainActor
struct DownloadNextMenu: View {
  let media: Media

  var body: some View {
    let isShow = media.source == .tmdb && media.format != .movie
    let released = AnimeHelpers.maxEpisode(media, playable: true)
    let entry = BrowseMediaInfo.entry(media)
    let progress = entry?.status == .completed ? 0 : (entry?.progress ?? 0)
    let remaining = max(released - progress, 0)
    if !isShow && released > 0 && media.status != .notYetReleased {
      if released == 1 {
        Button {
          DownloadCenter.shared.download(media: media, episodes: [(ref: EpisodeRef(number: 1, season: nil, localEpisode: nil), title: nil)])
        } label: {
          icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download")
      } else {
        Menu {
          Section("After episode \(progress)") {
            ForEach([1, 3, 5, 12].filter { $0 < remaining }, id: \.self) { count in
              Button(count == 1 ? "Next episode" : "Next \(count) episodes") {
                download(count, progress: progress, released: released)
              }
            }
            if remaining > 0 {
              Button("\(progress > 0 ? "All remaining" : "All") (\(remaining))") {
                download(remaining, progress: progress, released: released)
              }
            } else {
              Text("No released episode left to watch.")
            }
          }
        } label: {
          icon
        }
        .accessibilityLabel("Download Next Episodes")
      }
    }
  }

  private var icon: some View {
    Image(systemName: "arrow.down.to.line")
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 44, height: 44)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func download(_ count: Int, progress: Int, released: Int) {
    let first = progress + 1
    let last = min(first + count - 1, released)
    guard first <= last else { return }
    let episodes = (first...last).map { (ref: EpisodeRef(number: $0, season: nil, localEpisode: nil), title: String?.none) }
    DownloadCenter.shared.download(media: media, episodes: episodes)
  }
}

/// Opens the Downloads screen on the current tab (toolbar button, offline banner, episode buttons).
@MainActor
enum DownloadNavigation {
  static func open() {
    ShellNavigation.clearRootSheets()
    let tab = AppRouter.shared.selectedTab
    var path = ShellState.shared.path(for: tab)
    path.append(ShellRoute.downloads)
    ShellState.shared.setPath(path, for: tab)
  }
}

/// Toolbar entry of every tab (reachable offline).
@MainActor
struct ShellDownloadsButton: View {
  var body: some View {
    let running = DownloadCenter.shared.items.filter { $0.status.isRunning }.count
    Button {
      DownloadNavigation.open()
    } label: {
      Image(systemName: running > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
    }
    .accessibilityLabel(running > 0 ? "Downloads, \(running) running" : "Downloads")
  }
}

/// Settings > App > Downloads.
@MainActor
struct DownloadSettingsSection: View {
  @State private var confirmDeleteAll = false

  var body: some View {
    _ = AppSettings.shared.values
    let center = DownloadCenter.shared
    return Section {
      ShellSettingPicker(
        title: "Download Quality",
        description: "Quality picked when the source offers several (HLS streams). Sources with a single quality are downloaded as they are.",
        options: DownloadQuality.options.map { ShellOption($0.value, $0.label) },
        selection: ShellBind.value(\.downloadQuality)
      )
      ShellSettingPicker(
        title: "Simultaneous Downloads",
        description: "How many episodes download at the same time. The others wait in the queue.",
        options: (1...5).map { ShellOption(String($0), String($0)) },
        selection: Binding(
          get: { String(AppSettings.shared.values.downloadMaxConcurrent) },
          set: { AppSettings.shared.values.downloadMaxConcurrent = Int($0) ?? 2 }
        )
      )
      ShellSettingCard(title: "Storage Used", description: "Downloaded episodes are kept on this device only (not in iCloud backups).") {
        Text(DownloadNaming.bytes(center.storageUsed))
          .foregroundStyle(.secondary)
      }
      Button("Open Downloads") {
        DownloadNavigation.open()
      }
      Button("Delete All Downloads", role: .destructive) {
        confirmDeleteAll = true
      }
      .disabled(center.items.isEmpty)
      .confirmationDialog("Delete every download?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
        Button("Delete All Downloads", role: .destructive) {
          for item in DownloadCenter.shared.items { DownloadCenter.shared.remove(item.id) }
        }
        Button("Cancel", role: .cancel) {}
      }
    } header: {
      Text("Downloads")
    }
  }
}
