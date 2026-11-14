import SwiftUI

/// Episode list shown from the player (ManagerModal / FileCard in the Svelte app: current "Now Playing"
/// card, filter field, other entries, and the "Continue Anyway?" prompt when skipping ahead of the list progress).
@MainActor
struct PlayerEpisodeListSheet: View {
  let controller: PlayerController
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var pendingEpisode: EpisodeInfo?

  init(controller: PlayerController) {
    self.controller = controller
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          nowPlayingRow
        }
        if controller.episodeList.isEmpty {
          if controller.canLoadEpisodes {
            Section {
              if let previous = controller.previousEpisodeRef {
                Button {
                  play(previous)
                } label: {
                  Label("Previous Episode (\(previous.localEpisode ?? previous.number))", systemImage: "backward.end.fill")
                }
              }
              if let next = controller.nextEpisodeRef {
                Button {
                  play(next)
                } label: {
                  Label("Next Episode (\(next.localEpisode ?? next.number))", systemImage: "forward.end.fill")
                }
              }
            }
          }
        } else {
          Section("Episodes") {
            ForEach(filteredEpisodes) { info in
              episodeRow(info)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .searchable(text: $searchText, prompt: "Filter by episode number or title")
      .navigationTitle("Episodes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog(
        Text(behindTitle),
        isPresented: Binding(
          get: { pendingEpisode != nil },
          set: { presented in if !presented { pendingEpisode = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingEpisode
      ) { info in
        Button("Continue Anyway?") {
          pendingEpisode = nil
          play(info.ref)
        }
        Button("Cancel", role: .cancel) {
          pendingEpisode = nil
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private var filteredEpisodes: [EpisodeInfo] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return controller.episodeList }
    return controller.episodeList.filter { info in
      String(info.number) == query
        || String(info.localEpisode ?? info.number) == query
        || (info.title?.lowercased().contains(query) ?? false)
    }
  }

  /// FileCard prompt text.
  private var behindTitle: String {
    let progress = controller.session.media.listEntry?.progress ?? 0
    return progress > 0 ? "Your Current Progress Is At Episode \(progress)" : "You Haven't Watched Any Episodes Yet!"
  }

  /// FileCard `behind`: the episode is further than the next one to watch in the list.
  private func isBehind(_ info: EpisodeInfo) -> Bool {
    guard let entry = controller.session.media.listEntry, entry.status != .completed else { return false }
    guard info.number - 1 >= 1 else { return false }
    return entry.progress < info.number - 1
  }

  private func isWatched(_ info: EpisodeInfo) -> Bool {
    guard let entry = controller.session.media.listEntry else { return false }
    return entry.status == .completed || entry.progress >= info.number
  }

  private func select(_ info: EpisodeInfo) {
    if controller.isCurrent(info) {
      dismiss()
      return
    }
    if isBehind(info) {
      pendingEpisode = info
    } else {
      play(info.ref)
    }
  }

  private func play(_ ref: EpisodeRef) {
    dismiss()
    Task { await controller.playEpisode(ref) }
  }

  private var nowPlayingRow: some View {
    HStack(spacing: 12) {
      thumbnail(controller.session.media.images.cover)
      VStack(alignment: .leading, spacing: 4) {
        Text(controller.displayTitle)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        if let line = controller.episodeLine {
          Text(line)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 6) {
          badge("Now Playing", color: .blue)
          if let server = controller.session.currentServer {
            badge(server.title.isEmpty ? controller.serverName(controller.activeServerIndex) : server.title, color: .gray)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }

  private func episodeRow(_ info: EpisodeInfo) -> some View {
    Button {
      select(info)
    } label: {
      HStack(spacing: 12) {
        thumbnail(info.thumbnail ?? controller.session.media.images.cover)
        VStack(alignment: .leading, spacing: 4) {
          Text(episodeLabel(info))
            .font(.subheadline.weight(.semibold))
          if let title = PlayerText.cleanedTitle(info.title) {
            Text(title)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          HStack(spacing: 6) {
            if controller.isCurrent(info) { badge("Now Playing", color: .blue) }
            if info.isFiller { badge("Filler", color: .orange) }
            if isWatched(info) { badge("Watched", color: .green) }
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func episodeLabel(_ info: EpisodeInfo) -> String {
    if let season = info.season, let local = info.localEpisode {
      return "S\(season) · Episode \(local)"
    }
    return "Episode \(info.number)"
  }

  private func thumbnail(_ url: URL?) -> some View {
    AsyncImage(url: url) { phase in
      if let image = phase.image {
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.white.opacity(0.08)
      }
    }
    .frame(width: 112, height: 63)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.black)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.85), in: Capsule())
  }
}
