import SwiftUI
import WebKit

// modals/TrailerModal.svelte: YouTube trailer (youtube-nocookie embed) in a WKWebView.

/// "Watch Trailer" sheet.
@MainActor
struct BrowseTrailerSheet: View {
  let videoId: String
  let title: String
  let fallbackImages: [URL?]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .font(.headline)
          .foregroundStyle(BrowsePalette.muted)
          .lineLimit(1)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      ZStack {
        BrowseImage(BrowseMediaInfo.youTubeThumbnails(videoId) + fallbackImages, placeholder: Color.black)
        BrowseYouTubePlayer(videoId: videoId)
      }
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .padding(.horizontal, 8)
      Spacer(minLength: 0)
    }
    .background(Color.black)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

/// YouTube embed player (autoplay, inline, Japanese captions preferred like the Svelte iframe).
struct BrowseYouTubePlayer: UIViewRepresentable {
  let videoId: String

  final class Coordinator {
    var loadedId: String?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.allowsPictureInPictureMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    load(webView, coordinator: context.coordinator)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    if context.coordinator.loadedId != videoId {
      load(webView, coordinator: context.coordinator)
    }
  }

  static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
  }

  private func load(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.loadedId = videoId
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    let safeId = String(videoId.filter { allowed.contains($0) })
    guard !safeId.isEmpty else { return }
    let source = "https://www.youtube-nocookie.com/embed/\(safeId)?autoplay=1&playsinline=1&vq=medium&cc_lang_pref=ja&rel=0"
    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>html,body{margin:0;padding:0;background:transparent;height:100%;overflow:hidden;}iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0;}</style>
    </head>
    <body>
    <iframe src="\(source)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
    </body>
    </html>
    """
    // YouTube requires a referrer from embedded web views: use the app identifier as origin.
    let origin = "https://" + (Bundle.main.bundleIdentifier ?? "org.tsumi.app").lowercased()
    webView.loadHTMLString(html, baseURL: URL(string: origin))
  }
}
