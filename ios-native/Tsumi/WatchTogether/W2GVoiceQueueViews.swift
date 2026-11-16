import SwiftUI
import UIKit

// Watch Together v2.4 views (PROTOCOL.md "Voice chat" / "Shared queue" UI), ports of
// common/routes/w2g/components/{VoiceControls.svelte, Queue.svelte, User.svelte voice parts, PlayerW2G.svelte mic button
// and speaker chips, Prompts.svelte "Up next"}. Used by the lobby screen and the player panel.

// MARK: - Voice

/// Join voice / Leave voice, Mute / Unmute, or the hold-to-talk button with push-to-talk on.
@MainActor
struct W2GVoiceControls: View {
  let client: WatchTogetherClient

  var body: some View {
    let voice = client.voice
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if voice.joined {
          pill("Leave voice", systemImage: "phone.down.fill", tint: .red) { client.leaveVoice() }
          if voice.hasMic {
            if voice.pushToTalk {
              W2GHoldToTalkButton(client: client, size: 38)
              Text(voice.transmitting ? "Talking…" : "Hold to talk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(voice.transmitting ? Color.green : Color.secondary)
            } else {
              pill(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill", tint: voice.muted ? .red : nil) {
                client.setVoiceMuted(!voice.muted)
              }
            }
          }
          if voice.speaking {
            Circle()
              .fill(Color.green)
              .frame(width: 10, height: 10)
              .accessibilityLabel("You are speaking")
          }
        } else {
          Button {
            client.joinVoice()
          } label: {
            Label(voice.starting ? "Joining…" : "Join voice", systemImage: "headphones")
              .font(.subheadline.weight(.bold))
              .foregroundStyle(W2GAccentStyle.text)
              .padding(.horizontal, 14)
              .frame(minHeight: 36)
              .background(Capsule().fill(W2GAccentStyle.fill))
              .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .disabled(voice.starting)
          .accessibilityHint("Talk with the lobby, echo cancellation on")
        }
      }
      if let error = voice.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func pill(_ title: String, systemImage: String, tint: Color?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(tint ?? Color.primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill((tint ?? Color.primary).opacity(0.14)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// Push-to-talk: transmits while pressed.
@MainActor
struct W2GHoldToTalkButton: View {
  let client: WatchTogetherClient
  var size: CGFloat = 44
  @GestureState private var pressing = false

  var body: some View {
    let live = client.voice.transmitting
    Image(systemName: live ? "mic.fill" : "mic")
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Circle().fill(live ? Color.green : Color.black.opacity(0.55)))
      .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($pressing) { _, state, _ in state = true }
      )
      .onChange(of: pressing) { _, value in
        client.setPushToTalkHeld(value)
      }
      // The button can go away mid-press (overlay hidden, panel closed): the gesture never ends, release it here or
      // the microphone keeps sending.
      .onDisappear {
        client.setPushToTalkHeld(false)
      }
      .accessibilityLabel("Hold to talk")
      .accessibilityAddTraits(.isButton)
  }
}

/// Microphone button over the video while in voice: mute toggle, or hold to talk with push-to-talk on.
@MainActor
struct W2GPlayerMicButton: View {
  let client: WatchTogetherClient

  var body: some View {
    let voice = client.voice
    if voice.pushToTalk {
      W2GHoldToTalkButton(client: client, size: 40)
    } else {
      Button {
        client.setVoiceMuted(!voice.muted)
      } label: {
        Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(Circle().fill(voice.muted ? Color.red.opacity(0.85) : Color.black.opacity(0.5)))
          .overlay(Circle().stroke(Color.green, lineWidth: voice.speaking ? 3 : 0))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(voice.muted ? "Unmute your microphone" : "Mute your microphone")
    }
  }
}

/// Who is speaking, over the video while the panel is closed.
@MainActor
struct W2GSpeakersOverlay: View {
  let speakers: [(userId: String, name: String)]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(speakers, id: \.userId) { speaker in
        Label(speaker.name, systemImage: "waveform")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Capsule().fill(Color.black.opacity(0.6)))
          .overlay(Capsule().stroke(Color.green, lineWidth: 1.5))
          .transition(.opacity)
      }
    }
  }
}

/// "In voice" / "muted" marks next to a member's name.
@MainActor
struct W2GMemberVoiceMark: View {
  let voice: W2GMemberVoice

  var body: some View {
    if voice.joined {
      HStack(spacing: 3) {
        Image(systemName: voice.muted ? "mic.slash.fill" : "headphones")
          .font(.caption2.weight(.bold))
          .foregroundStyle(voice.speaking ? Color.green : Color.secondary)
          .accessibilityLabel(voice.muted ? "In voice, muted" : "In voice")
        if voice.mix.muted {
          Image(systemName: "speaker.slash.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.red)
            .accessibilityLabel("Muted for you")
        }
      }
    }
  }
}

/// Speaker button of a member in voice (while we are in voice): mute and volume, only for us.
@MainActor
struct W2GMemberVoiceButton: View {
  let client: WatchTogetherClient
  let member: W2GMemberView
  @State private var showMix = false

  var body: some View {
    if client.voice.joined && member.voice.joined && !member.isSelf {
      Button {
        showMix = true
      } label: {
        Image(systemName: member.voice.mix.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.subheadline)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Volume of \(member.name)")
      .sheet(isPresented: $showMix) {
        W2GVoiceMixSheet(client: client, userId: member.userId, name: member.name)
      }
    }
  }
}

@MainActor
struct W2GVoiceMixSheet: View {
  let client: WatchTogetherClient
  let userId: String
  let name: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let mix = client.voiceMixes[userId] ?? W2GVoiceMix()
    NavigationStack {
      Form {
        Toggle("Mute for me", isOn: Binding(
          get: { client.voiceMixes[userId]?.muted ?? false },
          set: { client.setMemberVoice(userId, muted: $0) }
        ))
        VStack(alignment: .leading, spacing: 6) {
          Text("Volume \(Int((mix.volume * 100).rounded()))%")
            .font(.subheadline)
          Slider(value: Binding(
            get: { client.voiceMixes[userId]?.volume ?? 1 },
            set: { client.setMemberVoice(userId, volume: $0) }
          ), in: 0...1)
          .accessibilityLabel("Volume of \(name)")
        }
        Text("Only you hear the change.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .navigationTitle(name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.height(300)])
  }
}

// MARK: - Queue

/// "Up next": items with votes and the host tools, suggestions waiting for approval, "Members need approval",
/// "Add next episode".
@MainActor
struct W2GQueueList: View {
  let client: WatchTogetherClient

  var body: some View {
    let queue = client.queue
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label("Up next (\(queue.items.count))", systemImage: "list.bullet.rectangle")
          .font(.headline)
        Spacer(minLength: 4)
        if let label = client.nextEpisodeLabel {
          Button {
            client.addNextEpisode()
          } label: {
            Label("Add \(label)", systemImage: "text.badge.plus")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
          }
          .buttonStyle(.bordered)
          .accessibilityHint("Queue the episode after the lobby one")
        }
      }
      if client.isHost {
        Toggle(isOn: Binding(
          get: { client.queue.policy == .approval },
          set: { client.setQueuePolicy($0 ? .approval : .open) }
        )) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Members need approval")
              .font(.subheadline.weight(.semibold))
            Text("Members suggest, you accept or decline")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      if queue.items.isEmpty {
        Text("Nothing queued. Add episodes from their details page.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
        W2GQueueRow(client: client, item: item, index: index, count: queue.items.count)
      }
      if !queue.pending.isEmpty {
        Text("Waiting for the host's approval")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        ForEach(queue.pending) { item in
          W2GQueueRow(client: client, item: item, pending: true)
        }
      }
    }
  }
}

@MainActor
struct W2GQueueRow: View {
  let client: WatchTogetherClient
  let item: W2GQueueItem
  var index = 0
  var count = 0
  var pending = false

  private var mine: Bool { item.addedBy == client.selfId }
  private var addedBy: String { mine ? "you" : (item.addedByName.isEmpty ? "someone" : item.addedByName) }

  var body: some View {
    HStack(spacing: 10) {
      if !pending {
        AsyncImage(url: item.coverURL) { phase in
          if let image = phase.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            Color.primary.opacity(0.1)
          }
        }
        .frame(width: 34, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(item.label)
          .font(.subheadline)
          .lineLimit(2)
        Text("\(pending ? "Suggested" : "Added") by \(addedBy)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if pending {
        if client.isHost {
          iconButton("checkmark", label: "Accept \(item.label)", filled: true) { client.answerSuggestion(item.id, accepted: true) }
          iconButton("xmark", label: "Decline \(item.label)") { client.answerSuggestion(item.id, accepted: false) }
        } else if mine {
          iconButton("xmark", label: "Cancel your suggestion") { client.removeQueueItem(item.id) }
        }
      } else {
        voteButton
        if client.isHost {
          if client.following {
            iconButton("play.fill", label: "Play \(item.label) now", filled: true) { client.playQueueItem(item.id) }
          }
          Menu {
            Button {
              client.moveQueueItem(item.id, by: -1)
            } label: {
              Label("Move up", systemImage: "chevron.up")
            }
            .disabled(index == 0)
            Button {
              client.moveQueueItem(item.id, by: 1)
            } label: {
              Label("Move down", systemImage: "chevron.down")
            }
            .disabled(index >= count - 1)
            Button(role: .destructive) {
              client.removeQueueItem(item.id)
            } label: {
              Label("Remove", systemImage: "trash")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
              .font(.title3)
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Manage \(item.label)")
        } else if mine {
          iconButton("xmark", label: "Remove \(item.label)") { client.removeQueueItem(item.id) }
        }
      }
    }
  }

  private var voteButton: some View {
    let voted = item.votes.contains(client.selfId)
    return Button {
      client.voteQueueItem(item.id)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: voted ? "hand.thumbsup.fill" : "hand.thumbsup")
        if !item.votes.isEmpty { Text("\(item.votes.count)") }
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(voted ? Color.green : Color.primary)
      .padding(.horizontal, 8)
      .frame(minHeight: 32)
      .background(Capsule().fill((voted ? Color.green : Color.primary).opacity(0.12)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(voted ? "Remove your vote" : "Vote for \(item.label)")
  }

  private func iconButton(_ systemImage: String, label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(filled ? W2GAccentStyle.text : Color.primary)
        .frame(width: 34, height: 34)
        .background(Circle().fill(filled ? W2GAccentStyle.fill : Color.primary.opacity(0.12)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// The queue in a sheet (lobby screen).
@MainActor
struct W2GQueueSheet: View {
  let client: WatchTogetherClient
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        W2GQueueList(client: client)
          .padding(16)
      }
      .navigationTitle("Up next")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Host: "Up next: {title · episode}" [Play now] [Cancel], 5 s.
@MainActor
struct W2GAdvancePrompt: View {
  let advance: W2GAdvance
  let client: WatchTogetherClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Up next: \(advance.item.label)")
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      HStack(spacing: 8) {
        Button {
          client.advanceNow()
        } label: {
          Label("Play now", systemImage: "play.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(W2GAccentStyle.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(W2GAccentStyle.fill))
        }
        .buttonStyle(.plain)
        Button {
          client.cancelAdvance()
        } label: {
          Text("Cancel")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
      }
      TimelineView(.periodic(from: .now, by: 0.25)) { context in
        let left = max(0, advance.endsAt - context.date.timeIntervalSince1970 * 1000)
        let fraction = min(1, left / (W2GSync.queueAdvanceSeconds * 1000))
        GeometryReader { proxy in
          Capsule()
            .fill(Color.white.opacity(0.55))
            .frame(width: proxy.size.width * CGFloat(fraction), height: 3)
        }
        .frame(height: 3)
      }
    }
    .foregroundStyle(.white)
    .padding(12)
    .frame(width: 260, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1).opacity(0.94)))
    .environment(\.colorScheme, .dark)
  }
}

/// "Add to Watch Together queue" on the details page and on episode rows, while in a lobby.
@MainActor
struct W2GQueueAddButton: View {
  /// Shows "Add to queue" next to the icon.
  var titled = false
  let action: () -> Void

  var body: some View {
    if WatchTogetherClient.shared.isInLobby {
      Button(action: action) {
        if titled {
          Label("Add to queue", systemImage: "text.badge.plus")
            .font(.subheadline.weight(.semibold))
        } else {
          Image(systemName: "text.badge.plus")
            .font(.subheadline.weight(.semibold))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .foregroundStyle(.white)
            .contentShape(Circle())
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add to Watch Together queue")
    }
  }
}
