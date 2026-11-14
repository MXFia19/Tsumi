import SwiftUI
import UIKit

// Watch Together inside the player (common/routes/w2g/components/PlayerW2G.svelte, PROTOCOL.md "UI requirements"):
// the Watch Together button with its unread badge, the side panel (members with crown, sync badge and host actions,
// chat with system lines, message field, reactions, Request pause / play, host tools, Resync), chat bubbles over the
// video while the panel is closed, action notices, floating reactions, the 3-2-1 countdown and the host's request
// prompts. Everything reads WatchTogetherClient.shared; PlayerView shows it only while in a lobby (the miniplayer
// does not show it).

/// Watch Together button of the player top bar (and of the overlay when the controls are hidden).
@MainActor
struct W2GPlayerButton: View {
  let unread: Int
  /// Floating over the video (controls hidden): draws its own background.
  var floating = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "person.2.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Circle().fill(floating ? Color.black.opacity(0.5) : Color.clear))
        .overlay(alignment: .topTrailing) {
          if unread > 0 {
            Text(unread > 9 ? "9+" : "\(unread)")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .frame(minWidth: 18, minHeight: 18)
              .background(Capsule().fill(Color.red))
              .offset(x: 4, y: -2)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(unread > 0 ? "Watch Together, \(unread) unread messages" : "Watch Together")
  }
}

/// Every Watch Together overlay of the player, plus the side panel when it is open.
@MainActor
struct W2GPlayerLayer: View {
  let client: WatchTogetherClient
  @Binding var panelOpen: Bool
  /// The player controls are shown (overlays move out of their way).
  let controlsVisible: Bool

  var body: some View {
    HStack(spacing: 0) {
      overlays
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if panelOpen {
        W2GPlayerPanel(client: client) { panelOpen = false }
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: panelOpen)
    .animation(.easeInOut(duration: 0.2), value: client.overlayNotices)
    .animation(.easeInOut(duration: 0.2), value: client.bubbles)
    .animation(.easeInOut(duration: 0.2), value: client.pendingRequests)
    .animation(.easeInOut(duration: 0.2), value: client.invites)
  }

  private var overlays: some View {
    ZStack {
      if !client.floatingReactions.isEmpty {
        W2GFloatingReactionsView(reactions: client.floatingReactions)
          .allowsHitTesting(false)
      }

      if let countdown = client.countdown {
        W2GCountdownOverlay(countdown: countdown)
          .allowsHitTesting(false)
      }

      VStack(spacing: 8) {
        noticeStack
        Spacer(minLength: 0)
        if !panelOpen && !client.bubbles.isEmpty {
          HStack(spacing: 0) {
            bubbleStack
            Spacer(minLength: 0)
          }
        }
      }
      .padding(.top, controlsVisible ? 64 : 14)
      .padding(.bottom, controlsVisible ? 112 : 20)
      .padding(.horizontal, 18)

      VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 0) {
          Spacer(minLength: 0)
          VStack(alignment: .trailing, spacing: 8) {
            if !controlsVisible && !panelOpen && client.unreadCount > 0 {
              W2GPlayerButton(unread: client.unreadCount, floating: true) { panelOpen = true }
            }
            // With the panel open they move to its top, so they are never under it.
            if !panelOpen {
              W2GPromptStack(client: client)
            }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.top, controlsVisible ? 64 : 12)
      .padding(.trailing, 18)
    }
  }

  /// "Alice paused at 12:34", "Only the host controls playback" [Request pause]…
  private var noticeStack: some View {
    VStack(spacing: 6) {
      ForEach(client.overlayNotices) { notice in
        HStack(spacing: 10) {
          Text(notice.text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
          if let request = notice.request {
            Button {
              client.sendRequest(request, from: notice.id)
            } label: {
              Text(request.label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(W2GAccentStyle.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Capsule().fill(W2GAccentStyle.fill))
            }
            .buttonStyle(.plain)
          }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .allowsHitTesting(notice.request != nil)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: 520)
  }

  /// "Alice: hello" for 5 s while the panel is closed.
  private var bubbleStack: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(client.bubbles) { bubble in
        (Text(bubble.name + ":").bold() + Text(" ") + Text(bubble.text))
          .font(.subheadline)
          .foregroundStyle(.white)
          .lineLimit(3)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.65)))
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .frame(maxWidth: 380, alignment: .leading)
    .allowsHitTesting(false)
  }
}

/// Host: "Alice wants to pause" [Accept] [Decline], declined after 15 s.
@MainActor
struct W2GRequestPrompt: View {
  let request: W2GHostRequest
  let client: WatchTogetherClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(request.prompt)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      HStack(spacing: 8) {
        Button {
          _ = client.answerRequest(id: request.id, accepted: true)
        } label: {
          Label("Accept", systemImage: "checkmark")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(W2GAccentStyle.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(W2GAccentStyle.fill))
        }
        .buttonStyle(.plain)
        Button {
          _ = client.answerRequest(id: request.id, accepted: false)
        } label: {
          Text("Decline")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
      }
      TimelineView(.periodic(from: .now, by: 0.25)) { context in
        let left = max(0, request.expiresAt - context.date.timeIntervalSince1970 * 1000)
        let fraction = min(1, left / W2GSync.requestTimeoutMs)
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
  }
}

/// 3-2-1 before "Start together" plays.
@MainActor
struct W2GCountdownOverlay: View {
  let countdown: W2GCountdown

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { context in
      let remaining = (countdown.endsAt - context.date.timeIntervalSince1970 * 1000) / 1000
      let left = Int(max(0, remaining).rounded(.up))
      if left > 0 {
        Text("\(left)")
          .font(.system(size: 84, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: 150, height: 150)
          .background(Circle().fill(Color.black.opacity(0.55)))
          .accessibilityLabel("Starting in \(left)")
      }
    }
  }
}

/// Emoji rising from the bottom trailing area, fading out.
@MainActor
struct W2GFloatingReactionsView: View {
  let reactions: [W2GFloatingReaction]

  var body: some View {
    GeometryReader { proxy in
      TimelineView(.animation) { context in
        ZStack {
          ForEach(reactions) { reaction in
            let elapsed = context.date.timeIntervalSince(reaction.createdAt) / W2GSync.reactionSeconds
            let progress = min(max(elapsed, 0), 1)
            Text(reaction.emoji)
              .font(.system(size: 40))
              .opacity(1 - progress * progress)
              .position(
                x: proxy.size.width * CGFloat(1 - reaction.inset),
                y: proxy.size.height * CGFloat(0.85 - 0.6 * progress)
              )
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
  }
}

/// "Host controls" / "Everyone controls" chip.
@MainActor
struct W2GModeChip: View {
  let mode: W2GMode
  var long = false

  var body: some View {
    let isHostMode = mode == .host
    let text: String
    if isHostMode {
      text = long ? "Host controls playback" : "Host controls"
    } else {
      text = long ? "Everyone controls playback" : "Everyone controls"
    }
    return Label(text, systemImage: isHostMode ? "crown.fill" : "person.2.fill")
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(Capsule().fill((isHostMode ? Color.yellow : Color.green).opacity(0.2)))
      .accessibilityLabel(isHostMode ? "Only the host can play, pause and seek" : "Anyone can play, pause and seek")
  }
}

/// Watch Together side panel of the player.
@MainActor
struct W2GPlayerPanel: View {
  let client: WatchTogetherClient
  let onClose: () -> Void

  private enum PanelTab: Hashable {
    case chat
    case people
  }

  @State private var section: PanelTab = .chat
  @State private var draft = ""
  @State private var confirmLeave = false
  @State private var leaveTask: Task<Void, Never>?

  static let width: CGFloat = 340
  private static let bottomId = "w2g-panel-bottom"

  var body: some View {
    VStack(spacing: 0) {
      header
      if !client.pendingRequests.isEmpty || !client.invites.isEmpty {
        // Host requests and invites stay visible and tappable while the panel is open.
        W2GPromptStack(client: client, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
      }
      quickActions
      independentToggle
      Picker("Section", selection: $section) {
        Text("Chat").tag(PanelTab.chat)
        Text("People (\(client.memberViews().count))").tag(PanelTab.people)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Divider()
      if section == .chat {
        chat
        reactionRow
        composer
      } else {
        people
      }
    }
    .foregroundStyle(.white)
    .frame(width: Self.width)
    .frame(maxHeight: .infinity)
    .background(Color(white: 0.07).opacity(0.95), ignoresSafeAreaEdges: .all)
    .environment(\.colorScheme, .dark)
    .onDisappear { leaveTask?.cancel() }
  }

  // MARK: Header and tools

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "person.2.fill")
        .font(.system(size: 17, weight: .semibold))
      VStack(alignment: .leading, spacing: 3) {
        Text("Watch Together")
          .font(.headline)
          .lineLimit(1)
        W2GModeChip(mode: client.effectiveMode)
      }
      Spacer(minLength: 4)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 16, weight: .bold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
    .padding(.leading, 14)
    .padding(.trailing, 4)
    .padding(.top, 6)
  }

  /// v2.2 "Watch on my own".
  private var independentToggle: some View {
    Toggle(isOn: independentBinding) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Watch on my own")
          .font(.subheadline.weight(.semibold))
        Text("Nothing you play is sent to the lobby")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
  }

  private var independentBinding: Binding<Bool> {
    let client = self.client
    return Binding(
      get: { !client.following },
      set: { value in client.setFollowing(!value) }
    )
  }

  /// Rejoin, Request pause / play (non-host in `host` mode), Resync, Start together, Resync everyone.
  private var quickActions: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let label = client.rejoinLabel {
          actionButton("Rejoin \(label)", systemImage: "arrow.uturn.backward.circle.fill") {
            client.rejoin()
          }
        }
        if client.controlLocked {
          let hostPaused = client.hostPaused
          actionButton(hostPaused ? "Request play" : "Request pause", systemImage: "hand.raised.fill") {
            _ = client.request(hostPaused ? .play : .pause)
          }
        }
        if !client.isHost && client.isWatching && client.following {
          actionButton("Resync", systemImage: "arrow.triangle.2.circlepath") {
            _ = client.resync()
          }
        }
        if client.canCountdown && client.isWatching {
          actionButton("Start together", systemImage: "timer") {
            _ = client.startTogether()
          }
        }
        if client.isHost && client.isWatching && client.following {
          actionButton("Resync everyone", systemImage: "crown.fill") {
            _ = client.resyncEveryone()
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: Chat

  private var chat: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 7) {
          if client.messages.isEmpty {
            Text("No messages yet")
              .font(.footnote)
              .foregroundStyle(.white.opacity(0.5))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
          }
          ForEach(client.messages.suffix(100)) { message in
            W2GPanelChatLine(message: message)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomId)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: client.messages.count) { _, _ in
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private var reactionRow: some View {
    HStack(spacing: 0) {
      ForEach(W2GSync.reactions, id: \.self) { emoji in
        Button {
          _ = client.react(emoji)
        } label: {
          Text(emoji)
            .font(.system(size: 22))
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("React \(emoji)")
      }
    }
    .padding(.horizontal, 6)
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Message", text: $draft)
        .textFieldStyle(.plain)
        .submitLabel(.send)
        .onSubmit { send() }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color.white.opacity(0.12)))
      Button {
        send()
      } label: {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canSend)
      .opacity(canSend ? 1 : 0.4)
      .accessibilityLabel("Send")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .onChange(of: draft) { _, value in
      if value.count > WatchTogetherClient.maxMessageLength {
        draft = String(value.prefix(WatchTogetherClient.maxMessageLength))
      }
    }
  }

  private func send() {
    guard canSend else { return }
    client.sendMessage(draft)
    draft = ""
  }

  // MARK: People

  private var people: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let members = client.memberViews(now: context.date.timeIntervalSince1970 * 1000)
          VStack(alignment: .leading, spacing: 10) {
            ForEach(members) { member in
              W2GMemberRow(
                member: member,
                canManage: client.isHost,
                compact: true,
                onKick: { _ = client.kick(member.userId) },
                onTransfer: { _ = client.transferHost(to: member.userId) },
                onInvite: { _ = client.invite(member.userId) }
              )
            }
          }
        }
        if client.isHost {
          Toggle(isOn: modeBinding) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Host only")
                .font(.subheadline.weight(.semibold))
              Text("Only the host can play, pause and seek")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            }
          }
          .padding(.top, 4)
        }
        Button(role: .destructive) {
          leaveTapped()
        } label: {
          Label(confirmLeave ? "Tap again to leave" : "Leave the lobby", systemImage: "door.left.hand.open")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Color.red.opacity(confirmLeave ? 0.3 : 0.14)))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
      }
      .padding(12)
    }
    .frame(maxHeight: .infinity)
  }

  private var modeBinding: Binding<Bool> {
    let client = self.client
    return Binding(
      get: { client.mode == .host },
      set: { value in _ = client.setMode(value ? .host : .everyone) }
    )
  }

  /// Leaving needs a second tap, so a mis-tap does not leave the lobby.
  private func leaveTapped() {
    leaveTask?.cancel()
    if confirmLeave {
      confirmLeave = false
      client.leave()
      onClose()
      return
    }
    confirmLeave = true
    leaveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled else { return }
      confirmLeave = false
    }
  }
}

/// One chat line of the player panel: system lines muted, messages as "Name text".
@MainActor
struct W2GPanelChatLine: View {
  let message: W2GChatMessage

  var body: some View {
    if message.isSystem {
      Text(message.text)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      let outgoing = message.direction == .outgoing
      (Text(outgoing ? "You" : message.user.displayName).bold() + Text(" ") + Text(message.text))
        .font(.subheadline)
        .foregroundStyle(Color.white)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, outgoing ? 8 : 0)
        .padding(.vertical, outgoing ? 4 : 0)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(outgoing ? 0.12 : 0))
        )
    }
  }
}

/// The app accent (Settings > Interface accent colour, else the AccentColor asset, which is white) and a text
/// colour that stays readable on it (WCAG relative luminance).
@MainActor
enum W2GAccentStyle {
  static var fill: Color { Color(uiColor: accent) }

  static var text: Color { luminance(accent) > 0.179 ? Color.black : Color.white }

  private static var accent: UIColor {
    if let custom = TsumiAppearanceStyle.color(hex: AppSettings.shared.values.accentColor) {
      return UIColor(custom)
    }
    return UIColor(named: "AccentColor") ?? UIColor.systemBlue
  }

  private static func luminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  private static func linear(_ component: CGFloat) -> Double {
    let value = min(max(Double(component), 0), 1)
    return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
}

/// Host request prompts and received invites (beside the video, at the top of the open panel, or app-wide).
@MainActor
struct W2GPromptStack: View {
  let client: WatchTogetherClient
  var alignment: HorizontalAlignment = .trailing

  var body: some View {
    VStack(alignment: alignment, spacing: 8) {
      ForEach(client.invites) { invite in
        W2GInvitePrompt(invite: invite, client: client)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
      ForEach(client.pendingRequests) { request in
        W2GRequestPrompt(request: request, client: client)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
  }
}

/// "Alice invites you to watch <title> · Episode 5" [Join] [Dismiss] (no timeout).
@MainActor
struct W2GInvitePrompt: View {
  let invite: W2GInvite
  let client: WatchTogetherClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(invite.prompt)
        .font(.subheadline.weight(.semibold))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button {
          client.acceptInvite(invite.id)
        } label: {
          Label("Join", systemImage: "play.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(W2GAccentStyle.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(W2GAccentStyle.fill))
        }
        .buttonStyle(.plain)
        Button {
          client.dismissInvite(invite.id)
        } label: {
          Text("Dismiss")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
      }
    }
    .foregroundStyle(.white)
    .padding(12)
    .frame(width: 280, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1).opacity(0.95)))
    .environment(\.colorScheme, .dark)
  }
}
