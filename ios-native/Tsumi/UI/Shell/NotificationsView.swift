import SwiftUI

// Notifications modal (common/modals/NotificationsModal.svelte): search filter, list with hero image,
// cover, title, message, time, badges (Announcement / Movie / Delayed / Episode / Batch / Season,
// Dub / Sub), list status border, play and read buttons, "behind" prompt ("Continue Anyway?"), long press
// = right click (view details), mark all as read / unread, empty states. Opening it marks the watched
// episodes as read; the order is the one of the moment it opened (re-sorted on the next opening).

@MainActor
struct NotificationsView: View {
  @State private var searchText = ""
  @State private var appliedSearch = ""
  @State private var debounceTask: Task<Void, Never>? = nil
  @State private var order: [String] = []
  @State private var promptId: String? = nil

  var body: some View {
    let service = AppNotificationsService.shared
    let hasAny = !service.items.isEmpty
    let shown = displayed(service.filtered(appliedSearch))
    return NavigationStack {
      ScrollView {
        LazyVStack(spacing: 8) {
          if hasAny {
            searchField
          }
          if !hasAny {
            ShellErrorCard(lines: ["Nothing To See Here!", "Settings > Interface > Notifications Settings"])
          } else if shown.isEmpty {
            ShellErrorCard(lines: ["No results found."])
          }
          ForEach(shown) { notification in
            ShellNotificationRow(
              notification: notification,
              prompting: promptId == notification.id,
              onTap: { behind in tap(notification, behind: behind) },
              onPlay: { play(notification) },
              onView: { viewDetails(notification) },
              onDismissPrompt: { promptId = nil }
            )
          }
          if hasAny {
            markAllButton(service)
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
      }
      .background(Color.black)
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            AppRouter.shared.showNotifications = false
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .presentationDragIndicator(.visible)
    .task {
      await service.markWatchedAsRead()
      order = ShellNotificationSort.sorted(service.items).map { $0.id }
    }
    .onDisappear {
      debounceTask?.cancel()
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Color.secondary)
      TextField("Filter notifications by their titles", text: $searchText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .onSubmit { applySearch(now: true) }
      if !searchText.isEmpty {
        Button {
          searchText = ""
          applySearch(now: true)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(ShellPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .padding(.top, 8)
    .onChange(of: searchText) { _, _ in applySearch(now: false) }
  }

  private func markAllButton(_ service: AppNotificationsService) -> some View {
    let unread = service.hasUnread
    return Button {
      service.markAll(read: unread)
    } label: {
      Label(unread ? "Mark All As Read" : "Mark All As Unread", systemImage: unread ? "envelope.badge" : "envelope.open")
        .font(.body.weight(.bold))
        .foregroundStyle(Color.white)
        .padding(.vertical, 12)
    }
    .buttonStyle(.plain)
    .disabled(!appliedSearch.isEmpty || !searchText.isEmpty)
    .opacity((!appliedSearch.isEmpty || !searchText.isEmpty) ? 0.4 : 1)
    .padding(.top, 12)
  }

  /// updateSearch: 500 ms debounce.
  private func applySearch(now: Bool) {
    debounceTask?.cancel()
    if now {
      appliedSearch = searchText
      return
    }
    let text = searchText
    debounceTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 500_000_000)
      if Task.isCancelled { return }
      appliedSearch = text
    }
  }

  /// Order frozen when the list opened; notifications that arrived since then come first.
  private func displayed(_ list: [MediaNotification]) -> [MediaNotification] {
    guard !order.isEmpty else { return ShellNotificationSort.sorted(list) }
    var positions: [String: Int] = [:]
    for (index, id) in order.enumerated() where positions[id] == nil {
      positions[id] = index
    }
    var indexed: [(position: Int, offset: Int, item: MediaNotification)] = []
    for (offset, item) in list.enumerated() {
      indexed.append((position: positions[item.id] ?? -1, offset: offset, item: item))
    }
    indexed.sort { lhs, rhs in
      if lhs.position != rhs.position { return lhs.position < rhs.position }
      return lhs.offset < rhs.offset
    }
    return indexed.map { $0.item }
  }

  /// Click: the "behind" prompt first, then onclick(notification) (close + play). A movie release alert opens
  /// the movie details instead (nothing to play yet).
  private func tap(_ notification: MediaNotification, behind: Bool) {
    if notification.release != nil {
      viewDetails(notification)
      return
    }
    if !behind || promptId == notification.id {
      promptId = nil
      AppNotificationsService.shared.setRead(notification, read: true)
      ShellNavigation.afterClosingRootSheets {
        Task { @MainActor in
          await ShellPlayback.playNotification(notification)
        }
      }
    } else {
      promptId = notification.id
    }
  }

  /// Play button: play-anime without closing the modal.
  private func play(_ notification: MediaNotification) {
    Task { @MainActor in
      await ShellPlayback.playNotification(notification)
    }
  }

  /// Right click (long press here): read + open-anime.
  private func viewDetails(_ notification: MediaNotification) {
    promptId = nil
    AppNotificationsService.shared.setRead(notification, read: true)
    Task { @MainActor in
      if let media = await ShellNotificationMedia.resolve(notification, direct: true) {
        ShellNavigation.openDetails(media)
      }
    }
  }
}

/// NotificationsModal sort(): newest first (episode order inside a season batch), unread first.
enum ShellNotificationSort {
  static func sorted(_ list: [MediaNotification]) -> [MediaNotification] {
    let byDate = list.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
      if lhs.mediaId == rhs.mediaId, let left = lhs.episode, let right = rhs.episode, lhs.season != nil, rhs.season != nil {
        return left > right
      }
      return false
    }
    return byDate.filter { !$0.read } + byDate.filter { $0.read }
  }
}

/// The flags of one notification computed from its media (announcement, behind, completed...).
struct ShellNotificationState {
  let announcement: Bool
  let delayed: Bool
  let repeating: Bool
  let notWatching: Bool
  let behind: Bool
  let completed: Bool
  let progress: Int?

  init(notification: MediaNotification, media: Media?, authorized: Bool) {
    let entry = media?.listEntry
    let progress = entry?.progress
    let status = entry?.status
    delayed = notification.delayed
    announcement = notification.clickAction == .view && !notification.delayed
    repeating = status == .repeating
    notWatching = !announcement && !delayed && (progress ?? 0) == 0
    var isBehind = false
    if authorized && !announcement && !delayed, let episode = notification.episode, episode - 1 >= 1, status != .completed {
      let target: Int? = notification.season == nil ? episode : media?.episodes
      let current = (progress ?? 0) != 0 ? (progress ?? 0) : -1
      if let target { isBehind = current < target - 1 }
    }
    behind = isBehind
    var isCompleted = false
    if !announcement && !delayed && !notWatching && !isBehind, let episode = notification.episode {
      let target: Int? = notification.season == nil ? episode : media?.episodes
      isCompleted = status == .completed || (target.map { (progress ?? 0) >= $0 } ?? false)
    }
    completed = isCompleted
    self.progress = progress
  }

  /// Left border color (CSS order: current, repeating, completed, behind, announcement, not-watching).
  var borderColor: Color {
    if notWatching { return ShellPalette.notWatching }
    if announcement { return ShellPalette.announcement }
    if (behind && !notWatching) || delayed { return ShellPalette.dropped }
    if completed { return ShellPalette.completed }
    if repeating { return ShellPalette.repeating }
    return ShellPalette.current
  }
}

@MainActor
struct ShellNotificationRow: View {
  let notification: MediaNotification
  let prompting: Bool
  let onTap: (Bool) -> Void
  let onPlay: () -> Void
  let onView: () -> Void
  let onDismissPrompt: () -> Void

  @State private var media: Media? = nil

  var body: some View {
    let state = ShellNotificationState(notification: notification, media: media, authorized: AccountStore.shared.isAuthorized)
    return ZStack(alignment: .leading) {
      heroBackground
      HStack(alignment: .top, spacing: 10) {
        ShellNotificationCover(url: notification.icon ?? notification.iconXL)
        ShellNotificationContent(notification: notification, state: state, onPlay: onPlay)
      }
      .padding(6)
      .padding(.leading, 4)
      .opacity(notification.read ? 0.5 : 1)
      if prompting {
        ShellNotificationPrompt(progress: state.progress, onContinue: { onTap(state.behind) }, onDismiss: onDismissPrompt)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShellPalette.card)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(state.borderColor)
        .frame(width: 4)
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onTapGesture {
      onTap(state.behind)
    }
    .contextMenu {
      Button {
        onView()
      } label: {
        Label("View Details", systemImage: "info.circle")
      }
      if notification.episode != nil {
        Button {
          onPlay()
        } label: {
          Label("Play", systemImage: "play.fill")
        }
      }
      Button {
        AppNotificationsService.shared.setRead(notification, read: !notification.read)
      } label: {
        Label(notification.read ? "Mark as Unread" : "Mark as Read", systemImage: notification.read ? "envelope.badge" : "envelope.open")
      }
      .disabled(state.completed)
    }
    .task(id: notification.id) {
      media = await ShellNotificationMedia.resolve(notification, direct: false)
    }
  }

  @ViewBuilder
  private var heroBackground: some View {
    if let hero = notification.heroImage {
      AsyncImage(url: hero) { phase in
        if let image = phase.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          Color.clear
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      .overlay {
        LinearGradient(
          colors: [ShellPalette.card.opacity(0.97), ShellPalette.card.opacity(0.85), ShellPalette.card.opacity(0.6)],
          startPoint: .leading,
          endPoint: .trailing
        )
      }
      .allowsHitTesting(false)
    }
  }
}

@MainActor
struct ShellNotificationCover: View {
  let url: URL?

  var body: some View {
    AsyncImage(url: url) { phase in
      if let image = phase.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        ShellPalette.color(0x2A2B30)
      }
    }
    .frame(width: 60, height: 80)
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

@MainActor
struct ShellNotificationContent: View {
  let notification: MediaNotification
  let state: ShellNotificationState
  let onPlay: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 6) {
        Text(notification.title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(Color.white)
          .lineLimit(2)
        Spacer(minLength: 4)
        if notification.episode != nil {
          Button(action: onPlay) {
            Image(systemName: "play.fill")
              .font(.caption.weight(.bold))
              .frame(width: 30, height: 30)
              .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.white)
          .accessibilityLabel("Play")
        }
        Button {
          AppNotificationsService.shared.setRead(notification, read: !notification.read)
        } label: {
          Image(systemName: notification.read ? "envelope.open" : "envelope.badge")
            .font(.caption.weight(.bold))
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
        .disabled(state.completed)
        .accessibilityLabel(notification.read ? "Mark as Unread" : "Mark as Read")
      }
      Text(notification.message)
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.85))
        .lineLimit(3)
      HStack(spacing: 5) {
        Text(ServiceText.since(notification.timestamp))
          .font(.caption2)
          .foregroundStyle(Color.secondary)
        Spacer(minLength: 4)
        ShellNotificationBadges(notification: notification, state: state)
      }
    }
  }
}

@MainActor
struct ShellNotificationBadges: View {
  let notification: MediaNotification
  let state: ShellNotificationState

  var body: some View {
    HStack(spacing: 5) {
      if let kind = notification.releaseKind {
        // Movie release alert: "Movie" + "In Theaters" / "Digital" instead of Announcement and Sub / Dub.
        badge("Movie", ShellPalette.badgeEpisode, dark: true)
        if kind == .theatrical {
          badge("In Theaters", ShellPalette.notify, dark: false)
        } else {
          badge("Digital", ShellPalette.current, dark: true)
        }
      } else {
        standardBadges
      }
    }
  }

  @ViewBuilder
  private var standardBadges: some View {
    if state.announcement {
      badge("Announcement", ShellPalette.announcement, dark: true)
    } else if notification.format == "MOVIE" {
      badge("Movie", ShellPalette.badgeEpisode, dark: true)
    } else if let season = notification.season {
      badge("Season \(season)", ShellPalette.badgeEpisode, dark: true)
    } else {
      if state.delayed {
        badge("Delayed", ShellPalette.badgeDelayed, dark: false)
      }
      badge(notification.episode.map { "Episode \($0)" } ?? "Batch", ShellPalette.badgeEpisode, dark: true)
    }
    if notification.dub {
      badge("Dub", ShellPalette.badgeDub, dark: true)
    } else {
      badge("Sub", ShellPalette.badgeSub, dark: false)
    }
  }

  private func badge(_ text: String, _ color: Color, dark: Bool) -> some View {
    Text(text)
      .font(.caption2.weight(.bold))
      .foregroundStyle(dark ? Color.black : Color.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

/// "You Haven't Watched Any Episodes Yet!" / "Your Current Progress Is At Episode N" + "Continue Anyway?".
@MainActor
struct ShellNotificationPrompt: View {
  let progress: Int?
  let onContinue: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      if let progress, progress > 0 {
        (Text("Your Current Progress Is At ") + Text("Episode \(progress)").bold())
          .font(.subheadline)
          .foregroundStyle(Color.white)
          .multilineTextAlignment(.center)
      } else {
        Text("You Haven't Watched Any Episodes Yet!")
          .font(.subheadline)
          .foregroundStyle(Color.white)
          .multilineTextAlignment(.center)
      }
      Button(action: onContinue) {
        Label("Continue Anyway?", systemImage: "play.fill")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(Color.black)
          .padding(.horizontal, 18)
          .padding(.vertical, 7)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.82))
    .contentShape(Rectangle())
    .onTapGesture { onDismiss() }
  }
}

/// ErrorCard.svelte ("Ooops!" + messages).
@MainActor
struct ShellErrorCard: View {
  let lines: [String]

  var body: some View {
    VStack(spacing: 6) {
      Text("Ooops!")
        .font(.title.weight(.bold))
        .foregroundStyle(Color.white)
      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.body)
          .foregroundStyle(Color.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }
}
