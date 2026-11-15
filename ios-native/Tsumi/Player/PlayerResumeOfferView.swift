import SwiftUI

/// "Resume at 12:34 (from PC)" over the player (the toast with a Resume action of common/modules/sync/session.js):
/// another device played this episode more recently (PlaybackSyncService). Hidden after 15 seconds.
@MainActor
struct PlayerResumeOfferView: View {
  let controller: PlayerController

  var body: some View {
    let sync = PlaybackSyncService.shared
    let session = controller.session
    if let offer = sync.offer, offer.controllerId == ObjectIdentifier(controller),
       offer.mediaKey == session.media.id, offer.episode == session.episode.number {
      VStack {
        HStack {
          Spacer(minLength: 0)
          card(offer, sync: sync)
        }
        Spacer(minLength: 0)
      }
      .padding(.top, 16)
      .padding(.horizontal, 16)
      .transition(.move(edge: .top).combined(with: .opacity))
      .task(id: offer.id) {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        sync.dismissOffer(offer.id)
      }
    }
  }

  private func card(_ offer: ResumeOffer, sync: PlaybackSyncService) -> some View {
    let place = offer.device == "Trakt" ? "another device" : offer.device
    let what = offer.isMovie ? "the movie" : "episode \(offer.episode)"
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
      VStack(alignment: .leading, spacing: 2) {
        Text("Resume at \(PlaybackPositionNote.formatClock(offer.time)) (from \(offer.device))")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
        Text("Continue \(what) where you left off on \(place).")
          .font(.caption)
          .foregroundStyle(Color.white.opacity(0.7))
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Resume") {
        controller.seek(to: max(offer.time - 2, 0))
        sync.dismissOffer(offer.id)
      }
      .buttonStyle(.borderedProminent)
      .tint(.white)
      .foregroundStyle(.black)
      Button {
        sync.dismissOffer(offer.id)
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(Color.white.opacity(0.8))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(12)
    .frame(maxWidth: 440)
    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
  }
}
