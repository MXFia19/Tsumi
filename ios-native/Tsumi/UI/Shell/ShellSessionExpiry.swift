import SwiftUI

// Persistent session prompts (Services/SessionExpiry.swift), shown above the toasts until answered or closed:
// "Your AniList session has expired" with "Log in again" / "Log out", or "expires soon" with "Log in again".
// Desktop: the svelte-sonner toast of common/modules/auth/expiry.js (duration Infinity, action + cancel).

@MainActor
struct ShellSessionExpiryPrompts: View {
  var body: some View {
    let center = SessionExpiryCenter.shared
    return VStack(spacing: 8) {
      ForEach(center.prompts) { prompt in
        ShellSessionExpiryCard(prompt: prompt)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: 520)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.prompts.map { $0.id })
  }
}

@MainActor
struct ShellSessionExpiryCard: View {
  let prompt: SessionExpiryCenter.Prompt

  private var expired: Bool { prompt.kind == .expired }
  private var tint: Color { expired ? ShellPalette.color(0xF87171) : ShellPalette.color(0xFACC15) }
  private var fill: Color { expired ? ShellPalette.color(0x2D0B0B) : ShellPalette.color(0x2A2405) }

  var body: some View {
    let center = SessionExpiryCenter.shared
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: expired ? "clock.badge.exclamationmark" : "clock")
          .font(.body.weight(.semibold))
          .foregroundStyle(tint)
        VStack(alignment: .leading, spacing: 3) {
          Text(prompt.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
          Text(prompt.message)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        Button {
          center.dismiss(prompt)
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.7))
            .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        if expired {
          Button {
            center.logOut(prompt)
          } label: {
            Text("Log out")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Color.white)
              .padding(.horizontal, 12)
              .frame(minHeight: 34)
              .background(Capsule().fill(Color.white.opacity(0.16)))
          }
          .buttonStyle(.plain)
        }
        Button {
          center.logInAgain(prompt)
        } label: {
          Text("Log in again")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(fill.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.45), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.45), radius: 10, y: 4)
  }
}
