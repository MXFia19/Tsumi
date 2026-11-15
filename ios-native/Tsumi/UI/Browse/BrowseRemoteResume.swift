import SwiftUI

/// "Resume Episode 5 at 12:34 (from PC)" under the play button of the details (RemoteResume.svelte): the position
/// written in the note of the list entry (anime) or the Trakt playback progress (shows and movies), when it is
/// newer than what this device played (PlaybackSyncService.detailsOffer). Applied to the play button, so nothing
/// changes in the layout while there is no offer.
@MainActor
struct BrowseRemoteResume: ViewModifier {
  let media: Media
  @State private var offer: DetailsResumeOffer?

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      content
      if let offer {
        button(offer)
      }
    }
    .task(id: "\(media.id)-\(TraktService.shared.isConnected)") {
      offer = nil
      offer = await PlaybackSyncService.shared.detailsOffer(for: media)
    }
  }

  private func button(_ offer: DetailsResumeOffer) -> some View {
    Button {
      self.offer = nil
      PlaybackSyncService.shared.resumeFromDetails(media, offer)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "clock.arrow.circlepath")
        Text("\(label(offer)) at \(position(offer))")
          .fontWeight(.semibold)
          .lineLimit(1)
        Text("(from \(offer.device))")
          .foregroundStyle(Color.white.opacity(0.6))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.subheadline)
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 40)
      .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Played more recently on \(offer.device == "Trakt" ? "another device" : offer.device)")
  }

  private func label(_ offer: DetailsResumeOffer) -> String {
    if media.isMovie { return "Resume" }
    if let season = offer.episode.season, let local = offer.episode.localEpisode { return "Resume S\(season)E\(local)" }
    return "Resume Episode \(offer.episode.number)"
  }

  private func position(_ offer: DetailsResumeOffer) -> String {
    // Trakt only stores a percentage: the time from the TMDB runtime would be an estimate.
    offer.device == "Trakt"
      ? PlaybackPositionNote.label(time: nil, percent: offer.percent)
      : PlaybackPositionNote.label(time: offer.time, percent: offer.percent)
  }
}
