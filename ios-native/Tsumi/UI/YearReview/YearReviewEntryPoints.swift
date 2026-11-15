import SwiftUI

// Entry points of the Year in Review (common/routes/yearreview/YearReviewBanner.svelte and
// YearReviewProfileButton.svelte): a Home banner in December (this year) and January (last year) for AniList
// users, and a button of the Profiles sheet (MyAnimeList profiles get the "needs AniList" explanation).

/// Home banner, dismissible until the next year.
@MainActor
struct YearReviewHomeBanner: View {
  @AppStorage("tsumi.yearReview.bannerDismissed") private var dismissedYear = 0
  @State private var presented = false

  var body: some View {
    let year = YearReviewCalc.bannerYear()
    let visible = year != nil && AccountStore.shared.isAniList && dismissedYear != year
    if visible, let year {
      let december = YearReviewCalc.calendar.component(.month, from: Date()) == 12
      HStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.title3.weight(.bold))
          .foregroundStyle(YearReviewStyle.background)
          .frame(width: 42, height: 42)
          .background(YearReviewStyle.accent, in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: december ? "Your \(year) in anime so far" : "Your \(year) in anime")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.white)
          Text("Episodes, hours, top anime, genres and studios of your year on AniList.")
            .font(.caption)
            .foregroundStyle(YearReviewStyle.muted)
            .lineLimit(2)
        }
        Spacer(minLength: 4)
        Button {
          presented = true
        } label: {
          Text("See")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(YearReviewStyle.background)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(YearReviewStyle.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See your year")
        Button {
          dismissedYear = year
        } label: {
          Image(systemName: "xmark")
            .font(.footnote.weight(.bold))
            .foregroundStyle(YearReviewStyle.muted)
            .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide until next year")
      }
      .padding(12)
      .background {
        ZStack {
          BrowsePalette.card
          LinearGradient(colors: [YearReviewStyle.accent.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .padding(.horizontal, 16)
      .contentShape(Rectangle())
      .onTapGesture { presented = true }
      .fullScreenCover(isPresented: $presented) {
        YearReviewView(year: year)
      }
    }
  }
}

/// "Year in Review" button of the Profiles sheet (current profile).
@MainActor
struct YearReviewProfileButton: View {
  @State private var presented = false

  var body: some View {
    if ProfilesService.shared.current != nil {
      ShellProfileBoxButton(title: "Year in Review", icon: "sparkles", tint: YearReviewStyle.accent.opacity(0.18)) {
        presented = true
      }
      .fullScreenCover(isPresented: $presented) {
        YearReviewView()
      }
    }
  }
}
