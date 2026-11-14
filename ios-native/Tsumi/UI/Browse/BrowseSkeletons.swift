import SwiftUI

// components/skeletons/* (SmallCardSk, FullCardSk, EpisodeCardSk, BannerSk, EpisodeListSk) and
// components/cards/ErrorCard.svelte.

struct BrowseSmallCardSkeleton: View {
  var width: CGFloat?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(BrowsePalette.skeleton)
        .aspectRatio(BrowseSmallCard.coverRatio, contentMode: .fit)
      BrowseSkeletonBar(width: (width ?? 120) * 0.8)
      BrowseSkeletonBar(width: (width ?? 120) * 0.55)
    }
    .frame(width: width)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .modifier(BrowseShimmer())
  }
}

struct BrowseFullCardSkeleton: View {
  var width: CGFloat?

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(BrowsePalette.skeleton)
        .frame(width: BrowseFullCard.height * 0.66)
      VStack(alignment: .leading, spacing: 10) {
        BrowseSkeletonBar(width: 160, height: 14)
        BrowseSkeletonBar(width: 120)
        BrowseSkeletonBar(width: 180)
        BrowseSkeletonBar(width: 140)
        Spacer()
      }
      .padding(.vertical, 10)
      Spacer(minLength: 0)
    }
    .frame(width: width, height: BrowseFullCard.height)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .modifier(BrowseShimmer())
  }
}

struct BrowseEpisodeCardSkeleton: View {
  var width: CGFloat?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(BrowsePalette.skeleton)
        .frame(height: 168)
      HStack(alignment: .top) {
        BrowseSkeletonBar(width: 150)
        Spacer()
        VStack(alignment: .trailing, spacing: 6) {
          BrowseSkeletonBar(width: 90)
          BrowseSkeletonBar(width: 50)
        }
      }
    }
    .frame(width: width)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .modifier(BrowseShimmer())
  }
}

struct BrowseBannerSkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Spacer()
      BrowseSkeletonBar(width: 260, height: 30)
      BrowseSkeletonBar(width: 200)
      BrowseSkeletonBar(width: 300)
      BrowseSkeletonBar(width: 260)
      BrowseSkeletonBar(width: 220)
      BrowseSkeletonBar(width: 140)
      BrowseSkeletonBar(width: 200, height: 34)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .modifier(BrowseShimmer())
  }
}

struct BrowseEpisodeRowSkeleton: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(BrowsePalette.skeleton)
        .frame(width: 150, height: 84)
      VStack(alignment: .leading, spacing: 10) {
        BrowseSkeletonBar(width: 150, height: 12)
        BrowseSkeletonBar(width: 110)
        BrowseSkeletonBar(width: 130)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(BrowsePalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .modifier(BrowseShimmer())
  }
}

/// ErrorCard.svelte: "Ooops!" with the reason.
struct BrowseErrorCard: View {
  enum Kind: Equatable {
    /// Nothing returned ("Looks like there's nothing here.").
    case empty
    /// No search results.
    case noResults
    /// A request failed.
    case failed(String)
  }

  let kind: Kind
  var height: CGFloat? = 220
  var onRetry: (() -> Void)?

  var body: some View {
    VStack(spacing: 8) {
      Text("Ooops!")
        .font(.title.bold())
        .foregroundStyle(.white)
      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.subheadline)
          .foregroundStyle(BrowsePalette.muted)
          .multilineTextAlignment(.center)
      }
      if let onRetry {
        Button {
          onRetry()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(.top, 4)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .frame(height: height)
  }

  private var lines: [String] {
    switch kind {
    case .empty:
      return ["Looks like there's nothing here."]
    case .noResults:
      return ["No results found."]
    case .failed(let message):
      return message.isEmpty ? ["Looks like something went wrong!"] : ["Looks like something went wrong!", message]
    }
  }
}
