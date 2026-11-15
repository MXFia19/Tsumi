import SwiftUI
import UIKit

// modals/details/components/EpisodeList.svelte: episode list of the details (thumbnail, number and title,
// length, summary, air date, watch progress, filler / recap mark, completed / next / unreleased states,
// Dub / Sub airing rows with the Card Audio setting), reverse order, season picker for TMDB shows. Tap plays
// the episode, long press opens the extension picker.

@MainActor
struct BrowseDetailEpisodes: View {
  @Bindable var model: BrowseDetailModel

  var body: some View {
    let media = model.live
    let entry = BrowseMediaInfo.entry(media)
    let watched = entry?.status == .completed
    let watching = entry.map { BrowseMediaInfo.watchingStatuses.contains($0.status) } ?? false
    let userProgress = watching ? (entry?.progress ?? 0) : 0
    let percents = Services.shared.progress.progress(mediaKey: media.id)
    let zeroOffset = model.hasZeroEpisode ? 1 : 0
    let showDub = ServiceSettingsExtras.cardAudio
    let now = Date()
    VStack(alignment: .leading, spacing: 18) {
      if !model.episodesLoaded {
        header(count: nil)
        ForEach(0..<skeletonCount(media), id: \.self) { _ in
          BrowseEpisodeRowSkeleton()
            .padding(.horizontal, 16)
        }
      } else if model.episodesFailed {
        header(count: nil)
        BrowseErrorCard(kind: .failed("Couldn't load episodes."), height: 180, onRetry: { model.retryEpisodes() })
          .padding(.horizontal, 16)
      } else if !model.episodes.isEmpty {
        header(count: model.episodes.count)
        // Only the rows are lazy (long series), the rest of the details is a plain stack.
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(model.displayedEpisodes(now: now)) { episode in
            BrowseEpisodeRow(
              media: media,
              episode: episode,
              title: displayTitle(episode, media: media),
              completed: !watched && userProgress >= episode.number + zeroOffset,
              target: userProgress + 1 == episode.number + zeroOffset,
              percent: watched ? 0 : (percents[episode.number] ?? 0),
              now: now,
              dub: showDub ? model.dubAirings[episode.number] : nil
            )
            .padding(.horizontal, 16)
          }
        }
      }
    }
  }

  private func skeletonCount(_ media: Media) -> Int {
    if media.status == .notYetReleased { return 1 }
    return max(min(AnimeHelpers.maxEpisode(media), 6), 1)
  }

  private func header(count: Int?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      BrowseSectionDivider(title: "Episodes")
      if let count, count > 0 {
        HStack(spacing: 10) {
          Text(Self.countText(count))
            .font(.footnote)
            .foregroundStyle(BrowsePalette.muted)
          Spacer()
          if model.seasons.count > 1 {
            seasonPicker
          }
          Button {
            model.reversed.toggle()
          } label: {
            Label("Reverse", systemImage: "arrow.up.arrow.down")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.white)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Reverse Episodes")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  private var seasonPicker: some View {
    Picker("Season", selection: $model.selectedSeason) {
      Text("All Seasons").tag(Int?.none)
      ForEach(model.seasons, id: \.self) { season in
        Text(Self.seasonName(season)).tag(Int?.some(season))
      }
    }
    .pickerStyle(.menu)
    .tint(.white)
  }

  static func countText(_ count: Int) -> String {
    count == 1 ? "1 Episode" : "\(count) Episodes"
  }

  static func seasonName(_ season: Int) -> String {
    season == 0 ? "Specials" : "Season \(season)"
  }

  /// "5. Title" unless the title already holds the number; "Episode 5" when there is no (unique) title.
  private func displayTitle(_ episode: EpisodeInfo, media: Media) -> String {
    let fallback = "Episode \(episode.number)"
    guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
          !model.duplicateTitleIds.contains(episode.id) else { return fallback }
    if media.episodes == 1 || media.source == .tmdb { return title }
    let pattern = "(?<![\\d.])\(episode.number)(?![\\d.])"
    if title.range(of: pattern, options: .regularExpression) != nil { return title }
    return "\(episode.number). \(title)"
  }
}

/// One episode card of the list.
@MainActor
struct BrowseEpisodeRow: View {
  let media: Media
  let episode: EpisodeInfo
  let title: String
  let completed: Bool
  let target: Bool
  let percent: Int
  let now: Date
  /// Dub airing of the episode (dubbedEpisode, Card Audio setting): "Dub: ..." and "Sub: ..." labels.
  var dub: DubEpisodeAiring? = nil

  private var unreleased: Bool {
    guard media.status != .finished else { return false }
    if let airDate = episode.airDate { return airDate > now }
    return episode.number > 1 || media.status == .notYetReleased
  }

  /// Filler or Recap (Jikan flags).
  private var markText: String? {
    if episode.isFiller { return "Filler" }
    if episode.isRecap { return "Recap" }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        thumbnail
        VStack(alignment: .leading, spacing: 6) {
          titleRow
          if dub == nil {
            Text(dateText)
              .font(.caption)
              .foregroundStyle(BrowsePalette.muted)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      progressView
      summaryView
      if let dub {
        dubRow(dub)
      }
    }
    .padding(12)
    .background(completed ? Color.black : BrowsePalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      // .unreleased-overlay: diagonal stripes.
      if unreleased {
        BrowseDiagonalStripes(spacing: 12)
          .fill(Color.black.opacity(0.3))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .allowsHitTesting(false)
      }
    }
    .overlay {
      if let borderColor {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(borderColor, lineWidth: 1)
      }
    }
    // .unreleased: blur(.06rem) grayscale(50%).
    .blur(radius: unreleased ? 0.6 : 0)
    .saturation(unreleased ? 0.5 : 1)
    .opacity(completed ? 0.5 : 1)
    .contentShape(Rectangle())
    .onTapGesture {
      play(force: false)
    }
    .onLongPressGesture(minimumDuration: 0.45) {
      guard !unreleased else { return }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      play(force: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Choose Extension") {
      play(force: true)
    }
  }

  private var borderColor: Color? {
    if markText != nil { return BrowsePalette.secondary }
    if target { return Color.white }
    return nil
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let image = episode.thumbnail {
      BrowseImage([image], placeholder: BrowsePalette.skeleton)
        .frame(width: 150, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          if let markText {
            Text(markText)
              .font(.caption2.weight(.bold))
              .foregroundStyle(.black)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(BrowsePalette.secondary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
              .padding(4)
          }
        }
    }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
      Spacer(minLength: 0)
      if let length = episode.durationMinutes {
        Text("\(length)m")
          .font(.caption)
          .foregroundStyle(BrowsePalette.muted)
      }
      if !unreleased {
        DownloadEpisodeButton(media: media, episode: episode.ref, title: episode.title)
      }
    }
  }

  @ViewBuilder
  private var progressView: some View {
    if completed {
      BrowseProgressBar(percent: 100, height: 2)
    } else if percent > 0 {
      BrowseProgressBar(percent: Double(percent), height: 2)
    }
  }

  @ViewBuilder
  private var summaryView: some View {
    let summary = BrowseText.episodeSummary(episode.summary)
    if !summary.isEmpty {
      Text(summary)
        .font(.caption)
        .fontWeight(unreleased ? .bold : .regular)
        .foregroundStyle(unreleased ? BrowsePalette.tertiary : Color.white.opacity(0.8))
        .lineLimit(dub == nil ? 4 : 3)
    }
    if episode.thumbnail == nil, let markText {
      BrowseChip(text: markText, background: BrowsePalette.secondary, foreground: .black)
    }
  }

  /// "Dub: in 3 days (Delayed)" and "Sub: 2 weeks ago" labels (EpisodeList.svelte date-row).
  private func dubRow(_ dub: DubEpisodeAiring) -> some View {
    BrowseFlowLayout(spacing: 6, lineSpacing: 6) {
      BrowseChip(text: "Dub: " + dub.text, background: dub.delayed ? BrowsePalette.danger : BrowsePalette.dub, foreground: .black, font: .caption.weight(.bold))
      if media.source != .tmdb {
        let subDelayed = episode.airDate == nil && dub.delayed && !dub.notPlanned
        BrowseChip(text: "Sub: " + subText(dub), background: subDelayed ? BrowsePalette.danger : BrowsePalette.sub, foreground: .black, font: .caption.weight(.bold))
      }
    }
  }

  /// Sub label: the sub air date, the dub text while the sub date is unknown, else the release estimate.
  private func subText(_ dub: DubEpisodeAiring) -> String {
    if episode.airDate == nil && !dub.notPlanned { return dub.text }
    return dateText
  }

  /// since(airdate), or the release estimate of EpisodeList.svelte.
  private var dateText: String {
    if let airDate = episode.airDate { return ServiceText.since(airDate) }
    let extras = Services.shared.store.extras(for: media)
    let startMonthKnown = extras.startDate?.month != nil
    if (media.status == .releasing && episode.number > 1 && unreleased) || (media.status == .notYetReleased && !startMonthKnown && media.season == nil) {
      return "In Production"
    }
    if (media.status == .notYetReleased || episode.number <= 1) && !startMonthKnown, let season = media.season {
      return season.rawValue.capitalized + " " + (media.seasonYear.map { String($0) } ?? "")
    }
    if (media.status == .notYetReleased || episode.number <= 1), startMonthKnown, let date = extras.startDate?.date {
      return ServiceText.monthDay(date, year: true)
    }
    if media.status == .finished { return "Released" }
    return "Unknown"
  }

  private func play(force: Bool) {
    guard !unreleased else { return }
    BrowseActions.play(media, episode: episode.ref, force: force)
  }
}
