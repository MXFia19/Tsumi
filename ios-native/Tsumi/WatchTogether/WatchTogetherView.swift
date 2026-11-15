import SwiftUI
import UIKit

// Watch Together screen: WatchTogetherPage.svelte (Create / Join cards), Lobby.svelte (chat,
// members, Leave / Invite / Send, control mode, display name), Message.svelte (grouped bubbles, system lines)
// and User.svelte (member row with host crown, sync badge and host actions).
// State lives in WatchTogetherClient.shared, so the lobby survives navigation like the JS store.

@MainActor
struct WatchTogetherView: View {
  private var client: WatchTogetherClient { WatchTogetherClient.shared }

  init() {}

  var body: some View {
    let client = self.client
    ZStack(alignment: .top) {
      if client.isInLobby {
        W2GLobbyView(client: client)
      } else {
        W2GStartView(client: client)
      }
      if let notice = client.notice {
        W2GNoticeBanner(notice: notice)
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
          .onTapGesture { client.dismissNotice(notice.id) }
          .task(id: notice.id) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { client.dismissNotice(notice.id) }
          }
      }
      // Host: requests can be answered from the lobby screen too.
      if client.isInLobby && !client.pendingRequests.isEmpty {
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          VStack(alignment: .trailing, spacing: 8) {
            ForEach(client.pendingRequests) { request in
              W2GRequestPrompt(request: request, client: client)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, client.notice == nil ? 8 : 80)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: client.notice?.id)
    .animation(.easeInOut(duration: 0.2), value: client.pendingRequests)
    .navigationTitle("Watch Together")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Create / Join (WatchTogetherPage.svelte)

@MainActor
struct W2GStartView: View {
  let client: WatchTogetherClient
  @State private var joinText = ""
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Text("Watch Together")
          .font(.largeTitle.bold())
          .padding(.top, 24)
        if horizontalSizeClass == .regular {
          HStack(alignment: .top, spacing: 24) {
            joinCard
            createCard
          }
        } else {
          VStack(spacing: 20) {
            joinCard
            createCard
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var joinCard: some View {
    VStack(spacing: 16) {
      Image(systemName: "person.badge.plus")
        .font(.system(size: 64))
        .frame(height: 100)
      Text("Join Lobby")
        .font(.title.bold())
      TextField("Lobby Code or Link", text: $joinText)
        .multilineTextAlignment(.center)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.join)
        .onSubmit { checkInvite(joinText) }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      Button {
        if let pasted = UIPasteboard.general.string { joinText = pasted }
      } label: {
        Label("Paste", systemImage: "doc.on.clipboard")
      }
    }
    .padding(20)
    .frame(maxWidth: 360)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .onChange(of: joinText) { _, newValue in
      checkInvite(newValue)
    }
  }

  private var createCard: some View {
    VStack(spacing: 16) {
      Image(systemName: "plus")
        .font(.system(size: 64))
        .frame(height: 100)
      Text("Start a lobby, then send the invite link to watch in sync.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button {
        client.createLobby()
      } label: {
        Text("Create Lobby")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding(20)
    .frame(maxWidth: 360)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  /// checkInvite: join as soon as the text contains a 16-char code.
  private func checkInvite(_ text: String) {
    guard !text.isEmpty, let code = WatchTogetherClient.lobbyCode(in: text) else { return }
    joinText = ""
    client.join(code: code)
  }
}

// MARK: - Lobby (Lobby.svelte)

@MainActor
struct W2GLobbyView: View {
  let client: WatchTogetherClient
  @State private var draft = ""
  /// Shift+Return was pressed on a hardware keyboard: the newline it types is kept (Lobby.svelte
  /// checkInput: Enter sends, Shift+Enter adds a line).
  @State private var newlineAllowedUntil = Date.distantPast
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    VStack(spacing: 0) {
      // v2.3: "{reference} is watching {title · episode}" [Join] at the top while we are not on it.
      if let offer = client.joinOffer {
        W2GJoinCard(offer: offer, client: client)
          .padding(.horizontal, 16)
          .padding(.top, 10)
      }
      W2GLobbyHeader(client: client)
      Divider()
      if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          chat
          Divider()
          W2GMemberList(client: client)
            .frame(width: 340)
        }
      } else {
        W2GMemberStrip(client: client)
        Divider()
        chat
      }
    }
    .onAppear { markRead() }
    .onChange(of: client.messages.count) { _, _ in markRead() }
  }

  /// The chat is on screen (not under the full screen player): nothing unread.
  private func markRead() {
    if !PlayerPresentation.shared.isPresented { client.markChatRead() }
  }

  private var chat: some View {
    VStack(spacing: 0) {
      W2GChatList(groups: client.messageGroups, messageCount: client.messages.count)
      Divider()
      inputBar
    }
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Lobby.svelte textarea: grows with its lines, Return sends, Shift+Return (hardware keyboard) adds a
  /// line; received multi-line messages keep their line breaks. Pasted text keeps its line breaks too.
  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 12) {
      Button {
        client.leave()
      } label: {
        Image(systemName: "door.left.hand.open")
          .font(.title2)
          .frame(minHeight: 40)
      }
      .tint(.red)
      .foregroundStyle(.red)
      .accessibilityLabel("Leave")

      Button {
        client.copyInvite()
      } label: {
        Image(systemName: "person.badge.plus")
          .font(.title2)
          .frame(minHeight: 40)
      }
      .foregroundStyle(.green)
      .accessibilityLabel("Invite")

      TextField("Message", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .submitLabel(.send)
        .onSubmit { send(draft) }
        .onKeyPress(phases: .down) { press in
          guard press.key == .return else { return .ignored }
          if press.modifiers.contains(.shift) {
            // Let the field insert the line break; the draft observer keeps it.
            newlineAllowedUntil = Date().addingTimeInterval(0.5)
            return .ignored
          }
          send(draft)
          return .handled
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

      Button {
        send(draft)
      } label: {
        Image(systemName: "paperplane.fill")
          .font(.title3)
          .frame(minHeight: 40)
      }
      .disabled(!canSend)
      .accessibilityLabel("Send")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .onChange(of: draft) { oldValue, newValue in
      // A vertical text field types "\n" for Return instead of submitting: send the text as it was.
      if Self.typedNewline(old: oldValue, new: newValue) {
        if Date() < newlineAllowedUntil {
          newlineAllowedUntil = .distantPast
        } else if oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          draft = oldValue
          return
        } else {
          send(oldValue)
          return
        }
      }
      // <textarea maxlength='2048'>
      if newValue.count > 2048 { draft = String(newValue.prefix(2048)) }
    }
  }

  /// sendMessage: trimmed text (the client trims and caps it too), then clears the field.
  private func send(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    client.sendMessage(text)
    draft = ""
  }

  /// Exactly one line break was typed into `old` (Return), as opposed to a paste or other edit.
  static func typedNewline(old: String, new: String) -> Bool {
    let before = Array(old)
    let after = Array(new)
    guard after.count == before.count + 1 else { return false }
    var index = 0
    while index < before.count && before[index] == after[index] { index += 1 }
    guard after[index] == "\n" || after[index] == "\r\n" || after[index] == "\r" else { return false }
    return Array(after[(index + 1)...]) == Array(before[index...])
  }
}

@MainActor
struct W2GLobbyHeader: View {
  let client: WatchTogetherClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(client.isHost ? "Your lobby" : "Lobby")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(client.code ?? "")
            .font(.system(.headline, design: .monospaced))
            .textSelection(.enabled)
        }
        Spacer(minLength: 8)
        statusBadge
        if let link = client.inviteLink {
          ShareLink(item: link) {
            Image(systemName: "square.and.arrow.up")
              .font(.title3)
          }
          .accessibilityLabel("Share invite link")
        }
      }
      if let title = client.nowPlayingTitle, let shared = client.sharedMedia {
        Label("\(title) - Episode \(shared.episode.number)", systemImage: "play.tv")
          .font(.subheadline)
          .lineLimit(1)
      }
      HStack(spacing: 10) {
        W2GModeChip(mode: client.effectiveMode, long: true)
        Spacer(minLength: 4)
        if client.isHost {
          Toggle("Host only", isOn: modeBinding)
            .toggleStyle(.switch)
            .font(.subheadline)
            .fixedSize()
        } else if client.isWatching && client.following {
          Button {
            _ = client.resync()
          } label: {
            Label("Resync", systemImage: "arrow.triangle.2.circlepath")
              .font(.subheadline.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .accessibilityHint("Jump to the host")
        }
      }
      // v2.2 "Watch on my own" and "Rejoin".
      Toggle("Watch on my own", isOn: independentBinding)
        .toggleStyle(.switch)
        .font(.subheadline)
      if client.canInviteEveryone {
        Button {
          client.inviteEveryoneNotWatching()
        } label: {
          Label("Invite everyone not watching", systemImage: "person.3.fill")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
      }
      if let label = client.rejoinLabel {
        Button {
          client.rejoin()
        } label: {
          Label("Rejoin \(label)", systemImage: "arrow.uturn.backward.circle.fill")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
      }
      if !client.isLoggedIn {
        W2GDisplayNameField(client: client)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var modeBinding: Binding<Bool> {
    let client = self.client
    return Binding(
      get: { client.mode == .host },
      set: { value in _ = client.setMode(value ? .host : .everyone) }
    )
  }

  private var independentBinding: Binding<Bool> {
    let client = self.client
    return Binding(
      get: { !client.following },
      set: { value in client.setFollowing(!value) }
    )
  }

  private var statusBadge: some View {
    let peers = max(0, client.members.count - 1)
    let text: String
    let color: Color
    if client.connectedTrackers == 0 {
      text = "Connecting…"
      color = .orange
    } else if peers == 0 {
      text = "Waiting for others"
      color = .yellow
    } else {
      text = "\(peers) connected"
      color = .green
    }
    return HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Members (User.svelte)

/// Compact layout: horizontal strip of member cards (host actions in a menu on each card).
@MainActor
struct W2GMemberStrip: View {
  let client: WatchTogetherClient

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let members = client.memberViews(now: context.date.timeIntervalSince1970 * 1000)
      VStack(alignment: .leading, spacing: 8) {
        Text("\(members.count) Member(s)")
          .font(.headline)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 10) {
            ForEach(members) { member in
              W2GMemberCard(
                member: member,
                canManage: client.isHost,
                onKick: { _ = client.kick(member.userId) },
                onTransfer: { _ = client.transferHost(to: member.userId) },
                onInvite: { _ = client.invite(member.userId) }
              )
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }
}

/// Regular layout: member column.
@MainActor
struct W2GMemberList: View {
  let client: WatchTogetherClient

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let members = client.memberViews(now: context.date.timeIntervalSince1970 * 1000)
      VStack(alignment: .leading, spacing: 0) {
        Text("\(members.count) Member(s)")
          .font(.title3.bold())
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(members) { member in
              W2GMemberRow(
                member: member,
                canManage: client.isHost,
                onKick: { _ = client.kick(member.userId) },
                onTransfer: { _ = client.transferHost(to: member.userId) },
                onInvite: { _ = client.invite(member.userId) }
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      }
    }
  }
}

/// Member row: avatar, host crown, name, sync badge; the host gets "Make host" and "Remove from the lobby".
@MainActor
struct W2GMemberRow: View {
  let member: W2GMemberView
  var canManage = false
  var compact = false
  var onKick: () -> Void = {}
  var onTransfer: () -> Void = {}
  var onInvite: () -> Void = {}

  var body: some View {
    HStack(spacing: 10) {
      W2GAvatarView(user: member.user, size: compact ? 34 : 44)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          if member.isHost {
            Image(systemName: "crown.fill")
              .font(.caption)
              .foregroundStyle(.yellow)
              .accessibilityLabel("Host")
          }
          Text(member.isSelf ? member.name + " (you)" : member.name)
            .font(compact ? .subheadline : .body)
            .lineLimit(1)
        }
        W2GBadgeChip(badge: member.badge, rtt: member.rtt)
        // v2.2: what the member watches, and where from (v2.1 source).
        if !member.watching.isEmpty {
          Text(member.watching)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
        }
        if !member.source.isEmpty {
          Text(member.source)
            .font(.caption2)
            .foregroundStyle(Color.secondary.opacity(0.8))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if member.canInvite {
        W2GInviteButton(name: member.name, action: onInvite)
      }
      if canManage && !member.isSelf {
        Menu {
          W2GMemberActions(name: member.name, canBeHost: member.canBeHost, onKick: onKick, onTransfer: onTransfer)
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage \(member.name)")
      } else if !compact, let url = member.user.profileURL {
        Link(destination: url) {
          Image(systemName: "arrow.up.right.square")
            .font(.title3)
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Open profile")
      }
    }
  }
}

/// Compact member card for the horizontal strip.
@MainActor
struct W2GMemberCard: View {
  let member: W2GMemberView
  var canManage = false
  var onKick: () -> Void = {}
  var onTransfer: () -> Void = {}
  var onInvite: () -> Void = {}

  var body: some View {
    VStack(spacing: 4) {
      if canManage && !member.isSelf {
        Menu {
          W2GMemberActions(name: member.name, canBeHost: member.canBeHost, onKick: onKick, onTransfer: onTransfer)
        } label: {
          card
        }
        .accessibilityLabel("Manage \(member.name)")
      } else {
        card
      }
      if member.canInvite {
        W2GInviteButton(name: member.name, action: onInvite)
      }
    }
  }

  private var card: some View {
    VStack(spacing: 4) {
      W2GAvatarView(user: member.user, size: 40)
        .overlay(alignment: .topTrailing) {
          if member.isHost {
            Image(systemName: "crown.fill")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(.yellow)
              .padding(3)
              .background(Circle().fill(Color(.systemBackground)))
              .offset(x: 4, y: -4)
          }
        }
      Text(member.isSelf ? "You" : member.name)
        .font(.caption)
        .foregroundStyle(Color.primary)
        .lineLimit(1)
      W2GBadgeChip(badge: member.badge, rtt: member.rtt)
      if !member.watching.isEmpty {
        Text(member.watching)
          .font(.caption2)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
    }
    .frame(width: 104)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

/// v2.1 "Invite to watch" on a member row.
@MainActor
struct W2GInviteButton: View {
  let name: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Invite", systemImage: "play.circle.fill")
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Capsule().fill(Color.primary.opacity(0.12)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Invite \(name) to watch")
  }
}

/// Host actions on a member (in a menu, so a mis-tap does not remove anyone).
@MainActor
struct W2GMemberActions: View {
  let name: String
  /// v2 client: a v1 client cannot act as host (mode, kick, requests).
  let canBeHost: Bool
  let onKick: () -> Void
  let onTransfer: () -> Void

  var body: some View {
    if canBeHost {
      Button {
        onTransfer()
      } label: {
        Label("Make \(name) the host", systemImage: "crown")
      }
    }
    Button(role: .destructive) {
      onKick()
    } label: {
      Label("Remove from the lobby", systemImage: "person.fill.xmark")
    }
  }
}

/// Sync badge: "In sync", "+1.2 s ahead", "Buffering", "No signal"… with the ping when known.
@MainActor
struct W2GBadgeChip: View {
  let badge: W2GBadge
  var rtt: Double? = nil

  var body: some View {
    HStack(spacing: 4) {
      Text(badge.text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.18)))
      if let rtt {
        Text("\(Int(rtt.rounded())) ms")
          .font(.caption2)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var color: Color {
    switch badge.kind {
    case .sync: return .green
    case .ahead, .behind: return .orange
    case .buffering, .loading: return .yellow
    case .other: return .purple
    case .independent: return .teal
    case .playing: return .blue
    case .paused, .idle, .nosignal, .old, .connecting: return .gray
    }
  }
}

/// Name shown to the lobby when not logged in (settings `w2gDisplayName`).
@MainActor
struct W2GDisplayNameField: View {
  let client: WatchTogetherClient
  @State private var name = AppSettings.shared.values.w2gDisplayName
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "person.text.rectangle")
        .foregroundStyle(Color.secondary)
      TextField("Display name", text: $name)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .focused($focused)
        .onSubmit { save() }
      if focused {
        Button("Save") { save() }
          .font(.subheadline.weight(.semibold))
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onChange(of: focused) { _, isFocused in
      if !isFocused { save() }
    }
    .onChange(of: name) { _, value in
      if value.count > W2GSync.maxNameLength { name = String(value.prefix(W2GSync.maxNameLength)) }
    }
  }

  private func save() {
    client.setDisplayName(name)
    focused = false
    name = AppSettings.shared.values.w2gDisplayName
  }
}

@MainActor
struct W2GAvatarView: View {
  let user: W2GUser
  var size: CGFloat = 40

  var body: some View {
    AsyncImage(url: user.avatar ?? W2GUser.defaultAvatar) { phase in
      if let image = phase.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }
}

// MARK: - Chat (Message.svelte)

@MainActor
struct W2GChatList: View {
  let groups: [W2GMessageGroup]
  let messageCount: Int
  private static let bottomId = "w2g-chat-bottom"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if groups.isEmpty {
            Text("No messages yet.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.top, 24)
          }
          ForEach(groups) { group in
            W2GMessageGroupView(group: group)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomId)
        }
        .padding(16)
      }
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: messageCount) { _, _ in
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
      }
    }
  }
}

@MainActor
struct W2GMessageGroupView: View {
  let group: W2GMessageGroup

  private var incoming: Bool { group.direction == .incoming }

  var body: some View {
    if group.isSystem {
      // Local line: joins, leaves, actions, requests, reactions.
      Text(group.messages.first ?? "")
        .font(.footnote)
        .foregroundStyle(Color.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    } else {
      bubbles
    }
  }

  private var bubbles: some View {
    HStack(alignment: .bottom, spacing: 8) {
      if incoming {
        W2GAvatarView(user: group.user, size: 36)
      } else {
        Spacer(minLength: 48)
      }
      VStack(alignment: incoming ? .leading : .trailing, spacing: 4) {
        HStack(spacing: 8) {
          Text(group.user.displayName)
            .font(.subheadline.bold())
          Text(group.date.formatted(date: .omitted, time: .standard))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(group.messages.enumerated()), id: \.offset) { _, text in
          Text(text)
            .textSelection(.enabled)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundStyle(incoming ? Color.primary : W2GAccentStyle.text)
            .background(incoming ? Color(.secondarySystemBackground) : W2GAccentStyle.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
      .frame(maxWidth: .infinity, alignment: incoming ? .leading : .trailing)
      if incoming {
        Spacer(minLength: 48)
      } else {
        W2GAvatarView(user: group.user, size: 36)
      }
    }
  }
}

// MARK: - Notice banner (toast)

@MainActor
struct W2GNoticeBanner: View {
  let notice: W2GNotice

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(notice.title)
        .font(.subheadline.bold())
      Text(notice.message)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: 480, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(radius: 8, y: 2)
  }
}
