import ImageIO
import SwiftUI
import UIKit

/// Images whose address comes from a module or an addon (Sora search result covers, picker posters, extension icons).
/// Unlike the app's own images they go through the extension network rules: ExtensionHTTP (size cap, time limit) and
/// no local address (this device, the local network), redirects included, unless the extension itself was installed
/// from such an address. They are decoded downsampled with ImageIO, and a source above `maxSourcePixels` is refused,
/// so a broken or hostile module cannot get the app killed for memory with a huge file or a decompression bomb.
final class ExtensionImageLoader: @unchecked Sendable {
  static let shared = ExtensionImageLoader()
  /// Largest image file downloaded.
  static let maxBytes = 8 * 1024 * 1024
  /// Largest source image decoded (width x height), about 8000 x 5000.
  static let maxSourcePixels = 40_000_000
  /// Longest pixel side of a cover or a poster once decoded (about 200 points on a 3x screen).
  static let coverPixelSize = 600

  private let cache = NSCache<NSString, UIImage>()
  /// Images that cannot load (blocked address, error status, too large, not an image): not asked again.
  private let failures = ServiceLocked<Set<String>>(Set<String>())

  private init() {
    cache.countLimit = 300
    cache.totalCostLimit = 64 * 1024 * 1024
  }

  /// Local addresses are allowed for the images of an extension installed from the local network.
  @MainActor
  static func allowsLocalNetwork(extensionKey: String) -> Bool {
    ExtensionManager.shared.loadedExtension(extensionKey)?.allowsLocalNetwork ?? false
  }

  private static func cacheKey(_ url: URL, maxPixelSize: Int) -> String {
    "\(maxPixelSize)|\(url.absoluteString)"
  }

  func cached(_ url: URL, maxPixelSize: Int) -> UIImage? {
    cache.object(forKey: Self.cacheKey(url, maxPixelSize: maxPixelSize) as NSString)
  }

  /// Downloads and decodes an image at most `maxPixelSize` pixels on its longest side; nil when it cannot load.
  func load(_ url: URL, maxPixelSize: Int, allowsLocalNetwork: Bool) async -> UIImage? {
    let key = Self.cacheKey(url, maxPixelSize: maxPixelSize)
    if let image = cache.object(forKey: key as NSString) { return image }
    if failures.get().contains(key) { return nil }
    if !allowsLocalNetwork && ExtensionNetworkPolicy.isLocal(url) {
      failures.update { $0.insert(key) }
      return nil
    }
    do {
      let (data, response) = try await ExtensionHTTP.data(
        url,
        timeout: 25,
        limit: Self.maxBytes,
        allowRedirect: { allowsLocalNetwork || !ExtensionNetworkPolicy.isLocal($0) }
      )
      guard (200..<300).contains(response.statusCode), let image = Self.downsample(data, maxPixelSize: maxPixelSize) else {
        failures.update { $0.insert(key) }
        return nil
      }
      let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
      cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
      return image
    } catch {
      // Too large or a blocked redirect: final. Network failures and cancellations are tried again later.
      if error is ExtensionFailure {
        failures.update { $0.insert(key) }
      }
      return nil
    }
  }

  /// Decodes `data` at most `maxPixelSize` pixels on its longest side (ImageIO thumbnail: the full-size bitmap is never
  /// made for large JPEGs), orientation applied. nil for non-images and sources above `maxSourcePixels`.
  static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0 else {
      return nil
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          width > 0, height > 0, width * height <= maxSourcePixels else {
      return nil
    }
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return UIImage(cgImage: image)
  }
}

/// Load state of an `ExtensionAsyncImage`.
enum ExtensionImagePhase {
  case empty
  case success(UIImage)
  case failure
}

/// AsyncImage for images supplied by modules and addons (ExtensionImageLoader).
@MainActor
struct ExtensionAsyncImage<Content: View>: View {
  let url: URL?
  let maxPixelSize: Int
  let allowsLocalNetwork: Bool
  let content: (ExtensionImagePhase) -> Content
  @State private var phase: ExtensionImagePhase

  init(
    url: URL?,
    maxPixelSize: Int = ExtensionImageLoader.coverPixelSize,
    allowsLocalNetwork: Bool = false,
    @ViewBuilder content: @escaping (ExtensionImagePhase) -> Content
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.allowsLocalNetwork = allowsLocalNetwork
    self.content = content
    if let url, let image = ExtensionImageLoader.shared.cached(url, maxPixelSize: maxPixelSize) {
      _phase = State(initialValue: .success(image))
    } else {
      _phase = State(initialValue: url == nil ? .failure : .empty)
    }
  }

  var body: some View {
    content(phase)
      .task(id: url) {
        await load()
      }
  }

  private func load() async {
    guard let url else {
      phase = .failure
      return
    }
    if let image = ExtensionImageLoader.shared.cached(url, maxPixelSize: maxPixelSize) {
      phase = .success(image)
      return
    }
    phase = .empty
    let image = await ExtensionImageLoader.shared.load(url, maxPixelSize: maxPixelSize, allowsLocalNetwork: allowsLocalNetwork)
    if Task.isCancelled { return }
    if let image {
      phase = .success(image)
    } else {
      phase = .failure
    }
  }
}

/// Image of a module result filling its frame over a placeholder colour (BrowseImage for extension images).
@MainActor
struct ExtensionCoverImage: View {
  let url: URL?
  var placeholder: Color
  var allowsLocalNetwork = false

  var body: some View {
    placeholder
      .overlay {
        ExtensionAsyncImage(url: url, allowsLocalNetwork: allowsLocalNetwork) { phase in
          switch phase {
          case .success(let image):
            Image(uiImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
          default:
            Color.clear
          }
        }
      }
      .clipped()
  }
}
