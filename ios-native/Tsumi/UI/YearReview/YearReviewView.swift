import SwiftUI
import UIKit

// Year in Review screen (common/routes/yearreview/YearReview.svelte): full-screen cover with the year picker,
// the loading progress (with the AniList rate-limit countdown), refresh and the share sheet of the summary card.
// Sections: YearReviewSections.swift. Data: Services/YearReviewService.swift.

enum YearReviewStyle {
  static let background = Color(red: 14 / 255, green: 15 / 255, blue: 19 / 255)
  static let card = Color.white.opacity(0.06)
  static let muted = Color.white.opacity(0.62)

  /// The accent colour of the app (settings.accentColor, the --accent-color CSS variable), white by default.
  static var accent: Color {
    TsumiAppearanceStyle.color(hex: AppSettings.shared.values.accentColor) ?? Color.white
  }

  /// "#rrggbb" of an AniList cover.
  static func color(_ hex: String?) -> Color? {
    guard let hex else { return nil }
    return TsumiAppearanceStyle.color(hex: hex)
  }

  static func updatedText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: date)
  }
}

@MainActor
struct YearReviewView: View {
  @State private var model: YearReviewModel
  @Environment(\.dismiss) private var dismiss

  init(year: Int? = nil) {
    _model = State(initialValue: YearReviewModel(year: year))
  }

  var body: some View {
    let accent = YearReviewStyle.accent
    return NavigationStack {
      ScrollView {
        content(accent: accent)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .frame(maxWidth: 900)
          .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      .background(alignment: .top) {
        ZStack(alignment: .topTrailing) {
          YearReviewStyle.background
          RadialGradient(colors: [accent.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
      }
      .navigationTitle("Year in Review")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
    }
    .preferredColorScheme(.dark)
    .tint(accent)
    .task { await model.start() }
    .onDisappear { model.cancel() }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button {
        model.cancel()
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Close")
    }
    if model.account.kind == .anilist {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Picker("Year", selection: Binding(get: { model.year }, set: { model.select($0) })) {
            ForEach(model.years, id: \.self) { year in
              Text(verbatim: String(year)).tag(year)
            }
          }
        } label: {
          HStack(spacing: 3) {
            Text(verbatim: String(model.year))
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
          }
        }
        .accessibilityLabel("Year")
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(model.phase == .loading)
        .accessibilityLabel("Refresh from AniList")
        if let image = model.shareImage {
          let title = "My \(model.year) in anime"
          ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel("Share the summary image")
        } else if model.preparingShare {
          ProgressView().controlSize(.small)
        }
      }
    }
  }

  @ViewBuilder
  private func content(accent: Color) -> some View {
    switch model.phase {
    case .needsAniList, .malOnly:
      YearReviewNotice(
        title: "Year in Review needs AniList",
        message: model.phase == .malOnly
          ? "Year in Review isn't supported for MyAnimeList accounts yet: it is built from your AniList list activity (episodes watched, completions, scores), which MyAnimeList doesn't provide. Add an AniList profile to see your year."
          : "It is built from your AniList list activity: episodes watched, completions, scores. Log in with AniList to see your year.",
        buttonTitle: "Log in with AniList",
        action: {
          model.cancel()
          dismiss()
          AppRouter.shared.showProfiles = true
        }
      )
    case .loading:
      YearReviewLoadingView(year: model.year, progress: model.progress, accent: accent)
    case .failed(let message):
      YearReviewNotice(title: "Could not load \(model.year)", message: message, buttonTitle: "Try again", action: {
        model.select(model.year)
      })
    case .loaded:
      if let result = model.result {
        if result.stats.hasData {
          VStack(alignment: .leading, spacing: 14) {
            if result.stale {
              Text("Could not refresh from AniList, showing the last saved data.")
                .font(.footnote)
                .foregroundStyle(Color.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            YearReviewSections(result: result, account: model.account, accent: accent)
          }
        } else {
          VStack(alignment: .leading, spacing: 14) {
            YearReviewNotice(
              title: "Nothing tracked in \(result.year)",
              message: "No anime activity was found on your AniList account for this year." + (model.years.count > 1 ? " Pick another year at the top." : ""),
              buttonTitle: nil,
              action: nil
            )
            if result.local.hasData {
              YearReviewLocalSection(result: result, accent: accent)
            }
          }
        }
      }
    }
  }
}

@MainActor
struct YearReviewNotice: View {
  let title: String
  let message: String
  let buttonTitle: String?
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Text(verbatim: title)
        .font(.title2.weight(.heavy))
        .multilineTextAlignment(.center)
      Text(verbatim: message)
        .font(.subheadline)
        .foregroundStyle(YearReviewStyle.muted)
        .multilineTextAlignment(.center)
      if let buttonTitle, let action {
        Button(action: action) {
          Text(verbatim: buttonTitle)
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(YearReviewStyle.background)
        .padding(.top, 4)
      }
    }
    .frame(maxWidth: 480)
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
  }
}

@MainActor
struct YearReviewLoadingView: View {
  let year: Int
  let progress: YearReviewProgress
  let accent: Color

  var body: some View {
    VStack(spacing: 14) {
      Text(verbatim: "Building your \(year)…")
        .font(.title2.weight(.heavy))
      ProgressView(value: min(max(progress.fraction, 0), 1))
        .tint(accent)
        .frame(maxWidth: 320)
      Text(verbatim: progress.message)
        .font(.subheadline)
        .foregroundStyle(YearReviewStyle.muted)
        .multilineTextAlignment(.center)
      if progress.wait > 0 {
        Text(verbatim: "AniList is limiting requests right now, resuming in \(progress.wait)s…")
          .font(.footnote)
          .foregroundStyle(Color.orange)
          .multilineTextAlignment(.center)
      }
      Text("The first load of a year can take a minute. It is cached afterwards.")
        .font(.caption)
        .foregroundStyle(YearReviewStyle.muted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: 480)
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
  }
}
