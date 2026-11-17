import SwiftUI
import Observation

// Module page of a Sora module result opened as it is (SoraResultSource.swift): pushed on the Search stack when the
// module's "Link results to AniList / TMDB" is off, or by "Open as is" when no AniList / TMDB title matches. The
// result's image, title and module name, the `extractDetails` description (and air date), and the module's own
// `extractEpisodes` list; an episode plays with that module and that episode href only
// (PlaybackRequestCoordinator.playSoraResult).

@MainActor
@Observable
final class SoraResultModel {
  enum EpisodesPhase: Equatable {
    case loading
    case loaded([SoraResultEpisode])
    case failed(String)
  }

  let result: SoraSearchResult
  /// Pseudo media played for the result (Media.isSoraResult).
  let media: Media
  private(set) var details: SoraResultDetails?
  private(set) var phase: EpisodesPhase = .loading

  @ObservationIgnored private var started = false
  @ObservationIgnored private var token = 0

  init(result: SoraSearchResult) {
    self.result = result
    media = SoraResultSource.media(result)
  }

  /// Loads the details and the episodes once (the view calls it when it appears).
  func start() {
    guard !started else { return }
    started = true
    loadEpisodes()
    let result = self.result
    Task { [weak self] in
      // Failures are ignored: the page shows the episodes anyway.
      let found = await SoraResultSource.details(result)
      self?.details = found
    }
  }

  /// "Retry" after the episodes failed to load.
  func retry() {
    loadEpisodes()
  }

  private func loadEpisodes() {
    token += 1
    let current = token
    phase = .loading
    let result = self.result
    Task { [weak self] in
      do {
        let list = try await SoraResultSource.episodes(result)
        guard let self, current == self.token else { return }
        self.phase = .loaded(list)
      } catch {
        guard let self, current == self.token, !PlaybackResolver.isCancellation(error) else { return }
        let message = error.localizedDescription
        self.phase = .failed(message.isEmpty ? "Failed to load the episodes" : message)
      }
    }
  }

  /// Plays an episode of the list: the player can then move between the listed episodes (SoraResultSessions).
  func play(_ episode: SoraResultEpisode) {
    guard case .loaded(let list) = phase else { return }
    let source = PlaybackSource(extensionKey: result.extensionKey, href: result.href, title: result.title)
    SoraResultSessions.shared.remember(SoraResultSessions.Entry(source: source, episodes: list), for: media.id)
    PlaybackRequestCoordinator.shared.playSoraResult(media, episode: episode, source: source)
  }

  /// Watched share of each episode played on this device (local resume positions).
  var progress: [Int: Int] {
    AnimeProgressService.shared.progress(mediaKey: media.id)
  }
}

@MainActor
struct SoraResultView: View {
  @State private var model: SoraResultModel
  @State private var descriptionExpanded = false

  init(result: SoraSearchResult) {
    _model = State(initialValue: SoraResultModel(result: result))
  }

  private var result: SoraSearchResult { model.result }

  private var descriptionHint: String {
    descriptionExpanded ? "Shortens the description" : "Shows the whole description"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if let description = model.details?.description {
          Text(description)
            .font(.subheadline)
            .foregroundStyle(BrowsePalette.muted)
            .lineLimit(descriptionExpanded ? nil : 6)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { descriptionExpanded.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(descriptionHint))
        }
        episodes
      }
      .padding(16)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(BrowsePalette.background)
    .navigationTitle(result.title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { model.start() }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      // Module-supplied address: extension image rules (size cap, no local address, downsampled).
      ExtensionCoverImage(url: result.imageURL, placeholder: BrowsePalette.skeleton, allowsLocalNetwork: ExtensionImageLoader.allowsLocalNetwork(extensionKey: result.extensionKey))
        .frame(width: 120, height: 120 / BrowseSmallCard.coverRatio)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(result.title)
          .font(.title3.bold())
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 4) {
          Image(systemName: "puzzlepiece.extension")
          Text(result.extensionName)
            .lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(BrowsePalette.muted)
        .accessibilityElement(children: .combine)
        if let airdate = model.details?.airdate {
          HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(airdate)
              .lineLimit(2)
          }
          .font(.caption)
          .foregroundStyle(BrowsePalette.muted)
          .accessibilityElement(children: .combine)
        }
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: Episodes

  @ViewBuilder
  private var episodes: some View {
    switch model.phase {
    case .loading:
      HStack(spacing: 10) {
        ProgressView()
          .tint(.white)
        Text("Loading episodes…")
          .font(.subheadline)
          .foregroundStyle(BrowsePalette.muted)
      }
      .frame(maxWidth: .infinity, minHeight: 120)
    case .failed(let message):
      VStack(spacing: 10) {
        Text(message)
          .font(.subheadline)
          .foregroundStyle(BrowsePalette.muted)
          .multilineTextAlignment(.center)
        Button {
          model.retry()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.white)
      }
      .padding(20)
      .frame(maxWidth: .infinity, minHeight: 120)
    case .loaded(let list):
      if list.isEmpty {
        Text("No episodes found")
          .font(.subheadline)
          .foregroundStyle(BrowsePalette.muted)
          .frame(maxWidth: .infinity, minHeight: 120)
      } else if list.count == 1 {
        // A single video (a VOD, a movie): "Play" rather than "Episode 1".
        row(list[0], label: "Play", progress: model.progress)
      } else {
        episodeList(list)
      }
    }
  }

  private func episodeList(_ list: [SoraResultEpisode]) -> some View {
    let progress = model.progress
    return VStack(alignment: .leading, spacing: 10) {
      Text("Episodes")
        .font(.headline)
        .foregroundStyle(.white)
      LazyVStack(spacing: 8) {
        ForEach(list) { episode in
          row(episode, label: "Episode \(episode.number)", progress: progress)
        }
      }
    }
  }

  private func row(_ episode: SoraResultEpisode, label: String, progress: [Int: Int]) -> some View {
    let percent = progress[episode.number] ?? 0
    let spokenLabel: String = episode.title.map { "\(label), \($0)" } ?? label
    let spokenValue: String = percent > 0 ? "\(percent)% watched" : ""
    return Button {
      model.play(episode)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "play.fill")
          .font(.subheadline)
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(BrowsePalette.tertiary, in: Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
          if let title = episode.title {
            Text(title)
              .font(.footnote)
              .foregroundStyle(BrowsePalette.muted)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          if percent > 0 {
            // Watched share of the local resume position.
            GeometryReader { proxy in
              ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(BrowsePalette.tertiary)
                  .frame(width: proxy.size.width * CGFloat(min(percent, 100)) / 100)
              }
            }
            .frame(height: 3)
            .padding(.top, 3)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BrowsePalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(BrowsePressableStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(spokenLabel))
    .accessibilityValue(Text(spokenValue))
    .accessibilityAddTraits(.isButton)
  }
}
