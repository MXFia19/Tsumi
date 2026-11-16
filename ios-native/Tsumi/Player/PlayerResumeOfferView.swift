import SwiftUI

/// Resume cards over the player.
/// - "Resume at 12:34 (from PC)" (the toast with a Resume action of common/modules/sync/session.js): another
///   device played this episode more recently (PlaybackSyncService). Hidden after 15 seconds.
/// - Otherwise "Resumed at 12:34" with Start Over / Resume: this device's saved position was restored when the
///   episode loaded (`PlayerController.resumeChoice`). Hidden after 10 seconds (the position is kept).
@MainActor
struct PlayerResumeOfferView: View {
  let controller: PlayerController

  var body: some View {
    let sync = PlaybackSyncService.shared
    let session = controller.session
    if let offer = sync.offer, offer.controllerId == ObjectIdentifier(controller),
       offer.mediaKey == session.media.id, offer.episode == session.episode.number {
      placed(card(offer, sync: sync))
        .task(id: offer.id) {
          try? await Task.sleep(nanoseconds: 15_000_000_000)
          sync.dismissOffer(offer.id)
        }
    } else if let choice = controller.resumeChoice {
      placed(choiceCard(choice))
        .task(id: choice.id) {
          try? await Task.sleep(nanoseconds: 10_000_000_000)
          controller.dismissResumeChoice(choice.id)
        }
    }
  }

  /// Top trailing corner.
  private func placed<Content: View>(_ content: Content) -> some View {
    VStack {
      HStack {
        Spacer(minLength: 0)
        content
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 16)
    .padding(.horizontal, 16)
    .transition(.move(edge: .top).combined(with: .opacity))
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
      dismissButton {
        sync.dismissOffer(offer.id)
      }
    }
    .modifier(PlayerResumeCardStyle())
  }

  /// "Resumed at 12:34": Resume keeps the position, Start Over goes back to the beginning.
  private func choiceCard(_ choice: PlayerResumeChoice) -> some View {
    let clock = PlayerTime.format(choice.time, full: PlayerTime.full(for: controller.safeDuration))
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
      VStack(alignment: .leading, spacing: 2) {
        Text("Resumed at \(clock)")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
        Text("Where you left off. Start over to watch from the beginning.")
          .font(.caption)
          .foregroundStyle(Color.white.opacity(0.7))
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Start Over") {
        controller.startOver()
      }
      .buttonStyle(.bordered)
      .tint(.white)
      Button("Resume") {
        controller.dismissResumeChoice(choice.id)
      }
      .buttonStyle(.borderedProminent)
      .tint(.white)
      .foregroundStyle(.black)
    }
    .modifier(PlayerResumeCardStyle())
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.white.opacity(0.8))
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Dismiss")
  }
}

/// Dark rounded card of the resume offers.
private struct PlayerResumeCardStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(12)
      .frame(maxWidth: 480)
      .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
  }
}
