import SwiftUI
import UIKit

// Shared look of the browse screens (home, search, schedule, details): colors of common/css.css,
// text helpers (HTML descriptions), a small cached image view (SmartImage.svelte: first image that loads),
// skeleton shimmer, chips and a flow layout.

/// Colors of the Svelte theme (css.css variables).
enum BrowsePalette {
  static let background = Color.black
  static let card = Color.white.opacity(0.07)
  static let cardStrong = Color.white.opacity(0.12)
  static let skeleton = Color.white.opacity(0.09)
  static let muted = Color.white.opacity(0.62)
  static let dimmed = Color.white.opacity(0.38)
  /// --tertiary-color hsl(217, 77%, 54%).
  static let tertiary = Color(red: 0.186, green: 0.457, blue: 0.894)
  static let success = Color(red: 0.30, green: 0.78, blue: 0.40)
  static let danger = Color(red: 0.90, green: 0.30, blue: 0.32)
  static let dangerDim = Color(red: 0.42, green: 0.11, blue: 0.13)
  /// btn-secondary (light button with dark text).
  static let secondary = Color(white: 0.9)
  /// --senary-color (dub).
  static let dub = Color(red: 1.0, green: 0.84, blue: 0.0)
  /// --septenary-color (sub).
  static let sub = Color(red: 0.537, green: 0.153, blue: 1.0)
  /// --octonary-color (partial dub, "show my anime").
  static let partialDub = Color(red: 1.0, green: 0.369, blue: 0.0)
  /// --quinary-color (adult).
  static let adult = Color(red: 0.843, green: 0.024, blue: 0.039)

  /// statusColorMap of anime.js.
  static func status(_ status: ListStatus) -> Color {
    switch status {
    case .current: return Color(red: 0.239, green: 0.706, blue: 0.949)
    case .planning: return Color(red: 0.969, green: 0.604, blue: 0.388)
    case .completed: return Color(red: 0.412, green: 0.832, blue: 0.328)
    case .paused: return Color(red: 0.980, green: 0.478, blue: 0.478)
    case .repeating: return Color(red: 0.231, green: 0.682, blue: 0.918)
    case .dropped: return Color(red: 0.910, green: 0.365, blue: 0.459)
    }
  }

  /// "#rrggbb" cover colors of AniList.
  static func color(hex: String?) -> Color? {
    guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    let red = Double((number >> 16) & 0xFF) / 255.0
    let green = Double((number >> 8) & 0xFF) / 255.0
    let blue = Double(number & 0xFF) / 255.0
    return Color(red: red, green: green, blue: blue)
  }
}

/// Block of the synopsis markdown (BrowseText.markdownBlocks).
enum BrowseMarkdownBlock: Hashable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case listItem(marker: String, text: String, indent: Int)
  case quote(String)
  case rule
  case table(header: [String], rows: [[String]])
}

/// Text helpers (description cleanup of the cards and the details synopsis).
enum BrowseText {
  /// `.replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim()` of the cards.
  static func plain(_ html: String?) -> String {
    guard let html, !html.isEmpty else { return "" }
    var text = html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    text = decodeEntities(text)
    text = text.replacingOccurrences(of: "~!", with: "").replacingOccurrences(of: "!~", with: "")
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// DetailsModal sanitize(): line breaks kept, bold / italic / links rendered, every other tag removed.
  static func attributed(_ html: String?) -> AttributedString {
    guard let html, !html.isEmpty else { return AttributedString() }
    var text = html.trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: "\\.\\.+(?=\\s*$)", with: ".", options: .regularExpression)
    text = text.replacingOccurrences(of: "\n", with: "<br>")
    text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "\n[ \t]*(\n[ \t]*)+", with: "\n\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<(b|strong)>\\s*", with: "**", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)\\s*</(b|strong)>", with: "**", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<(i|em)>\\s*", with: "*", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)\\s*</(i|em)>", with: "*", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", with: "[$2]($1)", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    text = decodeEntities(text)
    text = text.replacingOccurrences(of: "~!", with: "").replacingOccurrences(of: "!~", with: "")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let parsed = try? AttributedString(markdown: text, options: options) {
      return parsed
    }
    let fallback = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
    return AttributedString(fallback)
  }

  /// One block of inline markdown (bold / italic / links / code), whitespace kept.
  static func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let parsed = try? AttributedString(markdown: text, options: options) {
      return parsed
    }
    return AttributedString(text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: ""))
  }

  /// sanitize() of DetailsModal.svelte (marked with gfm + breaks) as blocks: headings, bullet / numbered
  /// lists, quotes, rules, tables and paragraphs. HTML headings, list items and rules become markdown first.
  static func markdownBlocks(_ html: String?) -> [BrowseMarkdownBlock] {
    guard let html, !html.isEmpty else { return [] }
    var text = html.trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: "\\.\\.+(?=\\s*$)", with: ".", options: .regularExpression)
    text = text.replacingOccurrences(of: "\n", with: "<br>")
    text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
    for level in 1...6 {
      let hashes = String(repeating: "#", count: level)
      text = text.replacingOccurrences(of: "(?is)<h\(level)[^>]*>(.*?)</h\(level)>", with: "\n\(hashes) $1\n", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: "(?i)<li[^>]*>\\s*", with: "\n- ", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)</li>|</?ul[^>]*>|</?ol[^>]*>|</p>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<hr\\s*/?>", with: "\n---\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<(b|strong)>\\s*", with: "**", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)\\s*</(b|strong)>", with: "**", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<(i|em)>\\s*", with: "*", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)\\s*</(i|em)>", with: "*", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", with: "[$2]($1)", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    text = decodeEntities(text)
    text = text.replacingOccurrences(of: "~!", with: "").replacingOccurrences(of: "!~", with: "")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return [] }

    let lines = text.components(separatedBy: "\n")
    var blocks: [BrowseMarkdownBlock] = []
    var paragraph: [String] = []
    func flush() {
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
      }
    }
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        flush()
        index += 1
        continue
      }
      if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
        flush()
        let header = tableCells(trimmed)
        var rows: [[String]] = []
        index += 2
        while index < lines.count {
          let row = lines[index].trimmingCharacters(in: .whitespaces)
          if row.isEmpty || !row.contains("|") { break }
          rows.append(tableCells(row))
          index += 1
        }
        blocks.append(.table(header: header, rows: rows))
        continue
      }
      if let groups = captures(trimmed, "^(#{1,6})\\s+(.*)$") {
        flush()
        blocks.append(.heading(level: groups[0].count, text: groups[1]))
      } else if captures(trimmed, "^(-{3,}|\\*{3,}|_{3,})$") != nil {
        flush()
        blocks.append(.rule)
      } else if let groups = captures(line, "^(\\s*)[-*+]\\s+(.*)$") {
        flush()
        blocks.append(.listItem(marker: "\u{2022}", text: groups[1], indent: groups[0].count / 2))
      } else if let groups = captures(line, "^(\\s*)(\\d+)[.)]\\s+(.*)$") {
        flush()
        blocks.append(.listItem(marker: groups[1] + ".", text: groups[2], indent: groups[0].count / 2))
      } else if let groups = captures(trimmed, "^>\\s?(.*)$") {
        flush()
        blocks.append(.quote(groups[0]))
      } else {
        paragraph.append(line)
      }
      index += 1
    }
    flush()
    return blocks
  }

  /// True when the blocks hold more than plain paragraphs.
  static func hasStructure(_ blocks: [BrowseMarkdownBlock]) -> Bool {
    blocks.contains { block in
      if case .paragraph = block { return false }
      return true
    }
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("-") else { return false }
    return captures(trimmed, "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$") != nil
  }

  private static func tableCells(_ line: String) -> [String] {
    var row = line.trimmingCharacters(in: .whitespaces)
    if row.hasPrefix("|") { row.removeFirst() }
    if row.hasSuffix("|") { row.removeLast() }
    return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// Capture groups of the first match (unmatched groups as ""), nil without a match.
  private static func captures(_ text: String, _ pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    var groups: [String] = []
    if match.numberOfRanges > 1 {
      for position in 1..<match.numberOfRanges {
        if let groupRange = Range(match.range(at: position), in: text) {
          groups.append(String(text[groupRange]))
        } else {
          groups.append("")
        }
      }
    }
    return groups
  }

  /// Episode summaries: removes the trailing "(Source: ...)".
  static func episodeSummary(_ summary: String?) -> String {
    let text = plain(summary)
    return text.replacingOccurrences(of: "\\s*\\(?source:\\s*[\\s\\S]+?\\)?$", with: "", options: [.regularExpression, .caseInsensitive])
  }

  /// `.replace(/_/g, ' ').toLowerCase()` + CSS text-capitalize.
  static func capitalizedWords(_ raw: String) -> String {
    raw.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
  }

  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = text
    let named: [(String, String)] = [
      ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
      ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"), ("&rsquo;", "\u{2019}"),
      ("&lsquo;", "\u{2018}"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&times;", "\u{00D7}")
    ]
    for (entity, value) in named {
      result = result.replacingOccurrences(of: entity, with: value)
    }
    if result.contains("&#"), let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
      let source = result
      let matches = regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
      for match in matches.reversed() {
        guard let whole = Range(match.range, in: result),
              let hexRange = Range(match.range(at: 1), in: source),
              let numberRange = Range(match.range(at: 2), in: source) else { continue }
        let isHex = !source[hexRange].isEmpty
        let value = UInt32(source[numberRange], radix: isHex ? 16 : 10)
        if let value, let scalar = Unicode.Scalar(value) {
          result.replaceSubrange(whole, with: String(Character(scalar)))
        }
      }
    }
    return result.replacingOccurrences(of: "&amp;", with: "&")
  }

  /// "Today" / "Tomorrow" / "Monday, March 4".
  static func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter.string(from: date)
  }

  static func time(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
  }

  static func number(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}

// MARK: - Images (SmartImage.svelte)

/// Memory cache of the decoded images, shared by every browse image view.
final class BrowseImageCache: @unchecked Sendable {
  static let shared = BrowseImageCache()

  private let cache = NSCache<NSURL, UIImage>()
  private let failures = ServiceLocked<Set<URL>>(Set<URL>())

  private init() {
    cache.countLimit = 500
    cache.totalCostLimit = 160 * 1024 * 1024
  }

  func cached(_ url: URL) -> UIImage? {
    cache.object(forKey: url as NSURL)
  }

  /// Downloads and decodes an image; nil when the URL fails (404, not an image...).
  func load(_ url: URL) async -> UIImage? {
    if let image = cached(url) { return image }
    if failures.get().contains(url) { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 25
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        failures.update { $0.insert(url) }
        return nil
      }
      guard let image = UIImage(data: data) else {
        failures.update { $0.insert(url) }
        return nil
      }
      let prepared = image.preparingForDisplay() ?? image
      cache.setObject(prepared, forKey: url as NSURL, cost: data.count)
      return prepared
    } catch {
      return nil
    }
  }
}

/// Image with fallbacks: shows the first URL of the list that loads, over a placeholder color.
@MainActor
struct BrowseImage: View {
  let urls: [URL]
  var placeholder: Color
  var contentMode: ContentMode
  var alignment: Alignment
  @State private var image: UIImage?

  init(_ urls: [URL?], placeholder: Color = BrowsePalette.skeleton, contentMode: ContentMode = .fill, alignment: Alignment = .center) {
    let list = urls.compactMap { $0 }
    self.urls = list
    self.placeholder = placeholder
    self.contentMode = contentMode
    self.alignment = alignment
    var initial: UIImage?
    for url in list {
      if let cached = BrowseImageCache.shared.cached(url) {
        initial = cached
        break
      }
    }
    _image = State(initialValue: initial)
  }

  private var key: String {
    urls.map { $0.absoluteString }.joined(separator: "|")
  }

  var body: some View {
    placeholder
      .overlay(alignment: alignment) {
        if let image {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
        }
      }
      .clipped()
      .task(id: key) {
        await load()
      }
  }

  private func load() async {
    for url in urls {
      if let cached = BrowseImageCache.shared.cached(url) {
        image = cached
        return
      }
    }
    for url in urls {
      if Task.isCancelled { return }
      if let loaded = await BrowseImageCache.shared.load(url) {
        if Task.isCancelled { return }
        image = loaded
        return
      }
    }
  }
}

/// Cover turned 90 degrees to fill a wide frame (cover-rotated of css.css: hentai titles without a banner).
@MainActor
struct BrowseRotatedCover: View {
  let urls: [URL?]
  var placeholder: Color = BrowsePalette.skeleton

  var body: some View {
    GeometryReader { proxy in
      BrowseImage(urls, placeholder: placeholder)
        .frame(width: proxy.size.height, height: proxy.size.width)
        .rotationEffect(.degrees(-90))
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .clipped()
  }
}

/// Diagonal bands (repeating-linear-gradient(-45deg) of the unreleased episodes).
struct BrowseDiagonalStripes: Shape {
  var spacing: CGFloat = 12

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let step = max(spacing, 2)
    var x = rect.minX - rect.height
    while x < rect.maxX {
      path.move(to: CGPoint(x: x, y: rect.maxY))
      path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
      path.addLine(to: CGPoint(x: x + rect.height + step, y: rect.minY))
      path.addLine(to: CGPoint(x: x + step, y: rect.maxY))
      path.closeSubpath()
      x += step * 2
    }
    return path
  }
}

// MARK: - Small building blocks

/// Pulsing placeholder (skeloader). The repeating animation is scoped to the opacity only: a
/// `withAnimation(.repeatForever)` in onAppear also captured the initial layout of the screen, which then
/// moved up and down forever.
struct BrowseShimmer: ViewModifier {
  @State private var dimmed = false

  func body(content: Content) -> some View {
    content
      .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { view in
        view.opacity(dimmed ? 0.45 : 1)
      }
      .onAppear {
        dimmed = true
      }
  }
}

/// Rounded skeleton bar.
struct BrowseSkeletonBar: View {
  var width: CGFloat?
  var height: CGFloat = 10

  var body: some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(BrowsePalette.skeleton)
      .frame(width: width, height: height)
  }
}

/// Small grey badge (".badge" of the cards and details).
struct BrowseChip: View {
  let text: String
  var systemImage: String?
  var background: Color = BrowsePalette.cardStrong
  var foreground: Color = .white
  var font: Font = .caption.weight(.semibold)

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
        .lineLimit(1)
    }
    .font(font)
    .foregroundStyle(foreground)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// List status circle (list-status-circle).
struct BrowseListStatusDot: View {
  let status: ListStatus
  var size: CGFloat = 9

  var body: some View {
    Circle()
      .fill(BrowsePalette.status(status))
      .frame(width: size, height: size)
      .accessibilityLabel(status.label)
  }
}

/// Thin progress bar (episode cards / episode list).
struct BrowseProgressBar: View {
  let percent: Double
  var height: CGFloat = 3

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.white.opacity(0.25))
        Rectangle()
          .fill(BrowsePalette.tertiary)
          .frame(width: proxy.size.width * CGFloat(min(max(percent, 0), 100) / 100))
      }
    }
    .frame(height: height)
  }
}

/// Section title with lines on both sides (ToggleTitle.svelte / "Synopsis" / "Episodes").
struct BrowseSectionDivider: View {
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
      Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .fixedSize()
      Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
    }
  }
}

/// Slight press feedback for card buttons.
struct BrowsePressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
  }
}

/// Wrapping layout for chips (flex-wrap).
struct BrowseFlowLayout: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let ideal = subview.sizeThatFits(.unspecified)
      let width = min(ideal.width, maxWidth)
      if x > 0 && x + width > maxWidth {
        y += lineHeight + lineSpacing
        x = 0
        lineHeight = 0
      }
      x += width + spacing
      widest = max(widest, x - spacing)
      lineHeight = max(lineHeight, ideal.height)
    }
    var finalWidth = widest
    if let width = proposal.width, width.isFinite {
      finalWidth = width
    }
    return CGSize(width: finalWidth, height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let ideal = subview.sizeThatFits(.unspecified)
      let width = min(ideal.width, bounds.width)
      if x > bounds.minX && x + width > bounds.maxX {
        x = bounds.minX
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: ideal.height))
      x += width + spacing
      lineHeight = max(lineHeight, ideal.height)
    }
  }
}

/// Small / full card mode (settings.cards), shared by Home, Search and Schedule.
enum BrowseCardMode: String, CaseIterable {
  case small
  case full

  static let storageKey = "tsumi.browse.cards"
}

/// genreIcons of anime.js mapped to SF Symbols.
enum BrowseGenreIcons {
  static func symbol(_ genre: String) -> String? {
    switch genre {
    case "Action": return "bolt.fill"
    case "Adventure": return "map"
    case "Comedy": return "face.smiling"
    case "Drama": return "theatermasks"
    case "Ecchi": return "drop"
    case "Fantasy": return "wand.and.stars"
    case "Hentai": return "exclamationmark.triangle"
    case "Horror": return "moon.fill"
    case "Mahou Shoujo": return "sparkles"
    case "Mecha": return "gearshape.2"
    case "Music": return "guitars"
    case "Mystery": return "magnifyingglass"
    case "Psychological": return "brain.head.profile"
    case "Romance": return "heart"
    case "Sci-Fi": return "atom"
    case "Slice of Life": return "cup.and.saucer"
    case "Sports": return "sportscourt"
    case "Supernatural": return "eye"
    case "Thriller": return "waveform.path.ecg"
    default: return nil
    }
  }
}
