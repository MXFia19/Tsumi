import SwiftUI

/// Small visual pieces shared by the extension screens.
enum ExtensionPalette {
  static let card = Color.white.opacity(0.07)
  static let cardBorder = Color.white.opacity(0.10)
  static let muted = Color.white.opacity(0.55)
  static let dimmed = Color.white.opacity(0.35)
  static let warning = Color(red: 0.98, green: 0.75, blue: 0.20)
  static let success = Color(red: 0.25, green: 0.75, blue: 0.40)
  static let danger = Color(red: 0.92, green: 0.30, blue: 0.30)
}

/// Extension icon (manifest iconUrl), or the "unknown file" symbol (FileQuestion). Loaded with the extension image
/// rules (ExtensionImageLoader: size cap, no local address unless `allowsLocalNetwork`, downsampled).
struct ExtensionIconView: View {
  let url: URL?
  var size: CGFloat = 43
  var circle = false
  var allowsLocalNetwork = false

  var body: some View {
    Group {
      if let url {
        ExtensionAsyncImage(url: url, maxPixelSize: Int(size * 3), allowsLocalNetwork: allowsLocalNetwork) { phase in
          switch phase {
          case .success(let image):
            Image(uiImage: image).resizable().scaledToFill()
          default:
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : 6, style: .continuous))
  }

  private var placeholder: some View {
    Image(systemName: "doc.questionmark")
      .resizable()
      .scaledToFit()
      .padding(size * 0.12)
      .foregroundStyle(ExtensionPalette.muted)
  }
}

/// Grey pill badge (version, stream type, quality...).
struct ExtensionBadge: View {
  let text: String
  var color: Color = Color.white.opacity(0.14)
  var foreground: Color = .white

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color, in: Capsule())
  }
}

/// Poster with a 2:3 ratio, placeholder symbol when missing or failing. Loaded with the extension image rules
/// (ExtensionImageLoader: size cap, no local address unless `allowsLocalNetwork`, downsampled).
struct ExtensionPosterImage: View {
  let url: URL?
  var placeholderSymbol = "play.fill"
  var allowsLocalNetwork = false

  var body: some View {
    Color.white.opacity(0.06)
      .aspectRatio(2.0 / 3.0, contentMode: .fit)
      .overlay {
        if let url {
          ExtensionAsyncImage(url: url, allowsLocalNetwork: allowsLocalNetwork) { phase in
            switch phase {
            case .success(let image):
              Image(uiImage: image).resizable().scaledToFill()
            case .failure:
              symbol
            case .empty:
              ProgressView().tint(ExtensionPalette.muted)
            }
          }
        } else {
          symbol
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var symbol: some View {
    Image(systemName: placeholderSymbol)
      .font(.title)
      .foregroundStyle(ExtensionPalette.muted)
  }
}

/// Banner used for warnings and errors (alert boxes of the Svelte screens).
struct ExtensionNoticeBanner: View {
  let systemImage: String
  let tint: Color
  let title: String?
  let message: Text
  var messageColor: Color?

  init(systemImage: String, tint: Color, title: String?, message: String) {
    self.systemImage = systemImage
    self.tint = tint
    self.title = title
    self.message = Text(message)
    self.messageColor = nil
  }

  init(systemImage: String, tint: Color, title: String?, messageText: Text, messageColor: Color? = nil) {
    self.systemImage = systemImage
    self.tint = tint
    self.title = title
    self.message = messageText
    self.messageColor = messageColor
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 3) {
        if let title {
          Text(title).font(.headline).foregroundStyle(.white)
        }
        message
          .font(.subheadline)
          .foregroundStyle(messageColor ?? (title == nil ? Color.white : ExtensionPalette.muted))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4).padding(.vertical, 6)
    }
  }
}
