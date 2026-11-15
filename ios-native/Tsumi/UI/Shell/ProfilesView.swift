import SwiftUI
import UIKit
import WebKit

// Profiles modal (common/components/Profiles.svelte): current profile, other profiles (switch, sync list
// entries, authenticate, logout), AniList / MyAnimeList login, "Add Profile" (at most 5 other profiles),
// "Authenticate" for an expired MyAnimeList session and "Sign Out".
// Logins open in a web view sheet (Electron 'open-auth' window) that catches the token / code in the URLs it
// loads; a "Paste token" field (settings.js paste handler) is the fallback and also routes pasted links.

@MainActor
struct ProfilesView: View {
  /// modal.open(modal.PROFILE, true): the login buttons are shown even with a current profile.
  @State private var addingProfile = false

  var body: some View {
    let service = ProfilesService.shared
    // Read here so the sheet binding below is re-evaluated when a login page opens or closes.
    _ = service.webLogin
    return NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          ShellCurrentProfileHeader()
          YearReviewProfileButton()
          ShellOtherProfilesList()
          ShellProfileActions(addingProfile: $addingProfile)
        }
        .padding(20)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
      }
      .background(Color.black)
      .disabled(service.isLoggingIn)
      .overlay {
        if service.isLoggingIn {
          ProgressView()
            .controlSize(.large)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            AppRouter.shared.showProfiles = false
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .presentationDragIndicator(.visible)
    .sheet(item: webLoginBinding) { request in
      ShellWebLoginSheet(request: request)
    }
  }

  /// The login page of ProfilesService (closing the sheet cancels the login).
  private var webLoginBinding: Binding<TsumiWebLoginRequest?> {
    Binding(
      get: { ProfilesService.shared.webLogin },
      set: { value in
        if value == nil {
          let service = ProfilesService.shared
          service.finishWebLogin(nil, request: service.webLogin?.id)
        }
      }
    )
  }
}

// MARK: - Web view login

/// Login page in a web view (Electron 'open-auth' window). Cancel closes it without an error toast.
@MainActor
struct ShellWebLoginSheet: View {
  let request: TsumiWebLoginRequest

  var body: some View {
    let id = request.id
    return NavigationStack {
      ShellWebLoginView(request: request)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Log in to \(request.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              ProfilesService.shared.finishWebLogin(nil, request: id)
            }
          }
        }
    }
    .onDisappear {
      ProfilesService.shared.finishWebLogin(nil, request: id)
    }
  }
}

/// WKWebView with the default (persistent) website data store, so the next login is remembered.
struct ShellWebLoginView: UIViewRepresentable {
  let request: TsumiWebLoginRequest

  func makeCoordinator() -> ShellWebLoginCoordinator {
    ShellWebLoginCoordinator(requestID: request.id, malState: request.malState)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore.default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    context.coordinator.attach(webView)
    webView.load(URLRequest(url: request.url))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}

  static func dismantleUIView(_ webView: WKWebView, coordinator: ShellWebLoginCoordinator) {
    coordinator.detach()
    webView.stopLoading()
    webView.navigationDelegate = nil
  }
}

/// Inspects every URL of the login web view: navigation requests, redirects, commits, failed loads of
/// custom schemes (tsumi:// / shiru://) and, through KVO on `url`, fragment-only changes (the AniList pin page
/// gets `#access_token=...`). The first URL carrying the login result ends the web login.
final class ShellWebLoginCoordinator: NSObject, WKNavigationDelegate {
  private let requestID: UUID
  private let malState: String?
  private var observation: NSKeyValueObservation?
  private var finished = false

  init(requestID: UUID, malState: String?) {
    self.requestID = requestID
    self.malState = malState
  }

  @MainActor
  func attach(_ webView: WKWebView) {
    observation = webView.observe(\.url, options: [.new]) { [weak self] observed, _ in
      MainActor.assumeIsolated {
        _ = self?.inspect(observed.url)
      }
    }
  }

  @MainActor
  func detach() {
    observation?.invalidate()
    observation = nil
  }

  /// Ends the login when `url` carries its result; returns true in that case (the navigation is cancelled).
  @MainActor
  func inspect(_ url: URL?) -> Bool {
    guard let url, let callback = ProfilesService.loginCallbackURL(url, malState: malState) else { return false }
    if !finished {
      finished = true
      ProfilesService.shared.finishWebLogin(callback, request: requestID)
    }
    return true
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let blocked: Bool = MainActor.assumeIsolated {
      let url = navigationAction.request.url
      if self.inspect(url) { return true }
      // Only web pages load here (other schemes would leave the app or fail).
      let scheme = url?.scheme?.lowercased() ?? "https"
      return !["http", "https", "about", "data", "blob"].contains(scheme)
    }
    decisionHandler(blocked ? .cancel : .allow)
  }

  func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      _ = self.inspect(webView.url)
    }
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      _ = self.inspect(webView.url)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      _ = self.inspect(webView.url)
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
    MainActor.assumeIsolated {
      _ = self.inspect(failingURL)
    }
  }
}

/// Current profile: large avatar, service badge, name.
@MainActor
struct ShellCurrentProfileHeader: View {
  var body: some View {
    let current = ProfilesService.shared.current
    return Group {
      if let current {
        VStack(spacing: 10) {
          ShellAvatar(url: current.viewer.avatar, size: 130)
            .overlay(alignment: .bottomTrailing) {
              ShellServiceBadge(service: current.viewer.service)
            }
          Text(current.viewer.name)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current Profile, \(current.viewer.name)")
      }
    }
  }
}

/// "Other Profiles": tap to switch, sync switch or Authenticate, Logout.
@MainActor
struct ShellOtherProfilesList: View {
  var body: some View {
    let others = ProfilesService.shared.others
    return Group {
      if !others.isEmpty {
        VStack(spacing: 4) {
          Text("Other Profiles")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ShellPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          ForEach(others) { profile in
            ShellOtherProfileRow(profile: profile)
          }
        }
      }
    }
  }
}

@MainActor
struct ShellOtherProfileRow: View {
  let profile: AccountProfile

  var body: some View {
    let service = ProfilesService.shared
    let profile = self.profile
    return HStack(spacing: 12) {
      Button {
        service.switchTo(profile)
      } label: {
        HStack(spacing: 12) {
          ShellAvatar(url: profile.viewer.avatar, size: 48)
            .overlay(alignment: .bottomTrailing) {
              ShellServiceBadge(service: profile.viewer.service)
                .scaleEffect(0.8)
            }
          Text(profile.viewer.name)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Switch to Profile: \(profile.viewer.name)")
      if profile.reauth {
        Button {
          Task { @MainActor in _ = await service.reauthenticate() }
        } label: {
          Image(systemName: "clock.badge.exclamationmark")
            .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
        .accessibilityLabel("Authenticate")
      } else {
        Toggle(
          "Sync List Entries",
          isOn: Binding(
            get: { service.isSynced(profile) },
            set: { _ in service.toggleSync(profile) }
          )
        )
        .labelsHidden()
        .accessibilityLabel("Sync List Entries")
      }
      Button {
        service.drop(profile)
      } label: {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.white)
      .accessibilityLabel("Logout")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(profile.reauth ? ShellPalette.error : ShellPalette.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

/// Login buttons / Add Profile / Authenticate / Sign Out.
@MainActor
struct ShellProfileActions: View {
  @Binding var addingProfile: Bool

  var body: some View {
    let service = ProfilesService.shared
    let current = service.current
    let others = service.others
    let showLogin = (addingProfile || (current == nil && others.isEmpty)) && others.count < ProfilesService.maxOtherProfiles
    return VStack(spacing: 6) {
      if showLogin {
        ShellLoginBox(showTitle: current == nil && others.isEmpty) {
          addingProfile = false
        }
      } else if service.canAddProfile {
        ShellProfileBoxButton(title: "Add Profile", icon: "plus", tint: ShellPalette.card) {
          addingProfile = true
        }
      }
      if let current {
        if current.reauth {
          ShellProfileBoxButton(title: "Authenticate", icon: "clock.badge.exclamationmark", tint: ShellPalette.error) {
            Task { @MainActor in _ = await service.reauthenticate() }
          }
        }
        ShellProfileBoxButton(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right", tint: ShellPalette.card) {
          service.logout()
        }
      }
    }
  }
}

/// AniList and MyAnimeList login buttons (confirmAnilist / confirmMAL).
@MainActor
struct ShellLoginBox: View {
  let showTitle: Bool
  let onSuccess: () -> Void

  var body: some View {
    let service = ProfilesService.shared
    return VStack(spacing: 12) {
      if showTitle {
        Text("Log In")
          .font(.title3.weight(.bold))
          .foregroundStyle(Color.white)
      }
      Button {
        Task { @MainActor in
          if await service.loginAniList() { onSuccess() }
        }
      } label: {
        Text("AniList")
          .font(.headline)
          .foregroundStyle(Color.white)
          .frame(width: 180, height: 40)
          .background(ShellPalette.color(0x02A9FF), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log in with AniList")
      Button {
        Task { @MainActor in
          if await service.loginMAL() { onSuccess() }
        }
      } label: {
        Text("MyAnimeList")
          .font(.headline)
          .foregroundStyle(Color.white)
          .frame(width: 180, height: 40)
          .background(ShellPalette.myAnimeList, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log in with MyAnimeList")
      ShellPasteTokenField(onSuccess: onSuccess)
        .padding(.top, 4)
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity)
    .background(ShellPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

/// "Paste token" fallback (settings.js paste handler): an AniList token or pin page URL, a MyAnimeList
/// `code=...&state=...` redirect, or an AniList / MyAnimeList / tsumi:// link (`ShellPasteHandler`).
@MainActor
struct ShellPasteTokenField: View {
  let onSuccess: () -> Void
  @State private var text = ""

  var body: some View {
    let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(alignment: .leading, spacing: 6) {
      Text("Or paste the token AniList shows, or a link")
        .font(.footnote)
        .foregroundStyle(Color.secondary)
      HStack(spacing: 8) {
        TextField("Paste token", text: $text)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.roundedBorder)
          .submitLabel(.go)
          .onSubmit { submit() }
        Button {
          if let value = UIPasteboard.general.string { text = value }
        } label: {
          Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Paste from Clipboard")
        Button("Log In") { submit() }
          .buttonStyle(.bordered)
          .disabled(isEmpty)
      }
    }
    .padding(.horizontal, 16)
  }

  private func submit() {
    let value = text
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task { @MainActor in
      if await ShellPasteHandler.handle(value) {
        text = ""
        onSuccess()
      }
    }
  }
}

@MainActor
struct ShellProfileBoxButton: View {
  let title: String
  let icon: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
