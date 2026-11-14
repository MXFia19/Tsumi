import SwiftUI
import UIKit

// Watch Together screen: WatchTogetherPage.svelte (Create / Join cards), Lobby.svelte (chat,
// members, Leave / Invite / Send), Message.svelte (grouped bubbles) and User.svelte (member row).
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
    }
    .animation(.easeInOut(duration: 0.25), value: client.notice?.id)
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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    VStack(spacing: 0) {
      W2GLobbyHeader(client: client)
      Divider()
      if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          chat
          Divider()
          W2GMemberList(members: client.members)
            .frame(width: 320)
        }
      } else {
        W2GMemberStrip(members: client.members)
        Divider()
        chat
      }
    }
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

  private var inputBar: some View {
    HStack(spacing: 12) {
      Button {
        client.leave()
      } label: {
        Image(systemName: "door.left.hand.open")
          .font(.title2)
      }
      .tint(.red)
      .foregroundStyle(.red)
      .accessibilityLabel("Leave")

      Button {
        client.copyInvite()
      } label: {
        Image(systemName: "person.badge.plus")
          .font(.title2)
      }
      .foregroundStyle(.green)
      .accessibilityLabel("Invite")

      TextField("Message", text: $draft)
        .textFieldStyle(.plain)
        .submitLabel(.send)
        .onSubmit { send() }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color(.tertiarySystemFill), in: Capsule())

      Button {
        send()
      } label: {
        Image(systemName: "paperplane.fill")
          .font(.title3)
      }
      .disabled(!canSend)
      .accessibilityLabel("Send")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .onChange(of: draft) { _, newValue in
      // <textarea maxlength='2048'>
      if newValue.count > 2048 { draft = String(newValue.prefix(2048)) }
    }
  }

  private func send() {
    guard canSend else { return }
    client.sendMessage(draft)
    draft = ""
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
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
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

@MainActor
struct W2GMemberStrip: View {
  let members: [W2GMember]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(members.count) Member(s)")
        .font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(members) { member in
            W2GMemberRow(member: member, avatarSize: 36)
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}

@MainActor
struct W2GMemberList: View {
  let members: [W2GMember]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\(members.count) Member(s)")
        .font(.title3.bold())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(members) { member in
            W2GMemberRow(member: member, avatarSize: 44)
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
      }
    }
  }
}

@MainActor
struct W2GMemberRow: View {
  let member: W2GMember
  var avatarSize: CGFloat = 44

  var body: some View {
    HStack(spacing: 10) {
      W2GAvatarView(user: member.user, size: avatarSize)
      Text(member.user.displayName)
        .lineLimit(1)
      if let url = member.user.profileURL {
        Spacer(minLength: 4)
        Link(destination: url) {
          Image(systemName: "arrow.up.right.square")
            .font(.title3)
        }
        .accessibilityLabel("Open profile")
      }
    }
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
            .foregroundStyle(incoming ? Color.primary : Color.white)
            .background(incoming ? Color(.secondarySystemBackground) : Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
