import SwiftUI
import UIKit

// Drawing of external subtitles: the plain overlay (PlayerSubtitleOverlay) for SRT / WebVTT / MicroDVD, the
// typeset ASS/SSA overlay (positions, alignment, colours, outline, fades) scaled from PlayResX / PlayResY to the
// video rect, and the burn-in used by the screenshot (KeyX, PlayerPage.svelte screenshot draws the JASSUB canvas).

/// Subtitle layer of the player: plain cues inside the safe area, ASS cues over the whole video surface.
@MainActor
struct PlayerSubtitleCanvas: View {
  let controller: PlayerController
  let raised: Bool

  var body: some View {
    let cues = controller.activeSubtitleCues
    let plain = cues.filter { $0.ass == nil }
    let styled = cues.filter { $0.ass != nil }
    ZStack {
      if !styled.isEmpty {
        PlayerASSLayer(controller: controller, cues: styled, raised: raised)
          .ignoresSafeArea()
      }
      if !plain.isEmpty {
        GeometryReader { proxy in
          PlayerSubtitleOverlay(cues: plain, size: proxy.size, raised: raised)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

/// Reads the playback clock only while a shown cue fades or moves, so the layer is not redrawn on every tick.
@MainActor
struct PlayerASSLayer: View {
  let controller: PlayerController
  let cues: [PlayerSubtitleCue]
  let raised: Bool

  var body: some View {
    let animated = cues.contains { $0.ass?.isAnimated ?? false }
    let time = animated ? controller.displayTime + controller.subtitleDelay : 0
    let videoSize = controller.videoSize
    let fill = controller.videoFill
    GeometryReader { proxy in
      PlayerASSOverlay(
        cues: cues,
        size: proxy.size,
        videoSize: videoSize,
        fill: fill,
        time: time,
        bottomInset: raised ? 112 : 0
      )
    }
  }
}

/// Group of ASS cues drawn at one anchor: a positioned line alone, or the unpositioned lines sharing an
/// alignment and margins (stacked like libass collision handling).
struct PlayerASSItem: Identifiable {
  let id: String
  var cues: [PlayerSubtitleCue]
  let layout: PlayerASSLayout
  let positioned: Bool

  /// Layer order, then file order; unpositioned lines grouped by alignment and margins.
  static func items(_ cues: [PlayerSubtitleCue]) -> [PlayerASSItem] {
    let ordered = cues.sorted { lhs, rhs in
      (lhs.ass?.layer ?? 0, lhs.id) < (rhs.ass?.layer ?? 0, rhs.id)
    }
    var items: [PlayerASSItem] = []
    var groups: [String: Int] = [:]
    for cue in ordered {
      guard let layout = cue.ass else { continue }
      if layout.position != nil {
        items.append(PlayerASSItem(id: "p\(cue.id)", cues: [cue], layout: layout, positioned: true))
        continue
      }
      let key = "g\(layout.alignment)-\(PlayerSubtitleParser.safeInt(layout.marginL))-"
        + "\(PlayerSubtitleParser.safeInt(layout.marginR))-\(PlayerSubtitleParser.safeInt(layout.marginV))"
      if let index = groups[key] {
        items[index].cues.append(cue)
      } else {
        groups[key] = items.count
        items.append(PlayerASSItem(id: key, cues: [cue], layout: layout, positioned: false))
      }
    }
    return items
  }

  /// Top to bottom: bottom-aligned lines grow upwards (the earliest line stays at the bottom).
  var visualOrder: [PlayerSubtitleCue] {
    if positioned { return cues }
    if layout.verticalFraction == 1 { return cues.sorted { $0.id > $1.id } }
    return cues.sorted { $0.id < $1.id }
  }
}

enum PlayerASSMetrics {
  /// libass sizes fonts by ascender + descender, Core Text by the em square.
  static let fontScale: CGFloat = 0.9
}

enum PlayerVideoGeometry {
  /// Rect of the video inside `container` (aspect fit, or aspect fill with "Video Cover").
  static func videoRect(in container: CGSize, videoSize: CGSize, fallbackAspect: CGFloat, fill: Bool) -> CGRect {
    guard container.width > 0, container.height > 0 else { return .zero }
    var aspect = fallbackAspect
    if videoSize.width > 0, videoSize.height > 0 {
      aspect = videoSize.width / videoSize.height
    }
    guard aspect.isFinite, aspect > 0 else { return CGRect(origin: .zero, size: container) }
    let containerAspect = container.width / container.height
    let width: CGFloat
    let height: CGFloat
    if (aspect > containerAspect) != fill {
      width = container.width
      height = container.width / aspect
    } else {
      height = container.height
      width = container.height * aspect
    }
    return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
  }
}

/// Typeset ASS/SSA cues (the JASSUB canvas): every line anchored at its \pos / margins point with its \an
/// alignment, script units scaled by the video rect (PlayResX / PlayResY).
struct PlayerASSOverlay: View {
  let cues: [PlayerSubtitleCue]
  let size: CGSize
  let videoSize: CGSize
  let fill: Bool
  /// Subtitle clock in seconds (video time + offset), used by fades and moves.
  let time: Double
  /// Space kept free at the bottom for the controls (unpositioned bottom lines move up).
  let bottomInset: CGFloat

  var body: some View {
    let items = PlayerASSItem.items(cues)
    return ZStack(alignment: .topLeading) {
      Color.clear
      ForEach(items) { item in
        itemView(item)
      }
    }
    .frame(width: size.width, height: size.height)
  }

  private func itemView(_ item: PlayerASSItem) -> some View {
    let layout = item.layout
    let aspect = CGFloat(layout.playResX / max(layout.playResY, 1))
    let rect = PlayerVideoGeometry.videoRect(in: size, videoSize: videoSize, fallbackAspect: aspect, fill: fill)
    let scaleY = rect.height / CGFloat(max(layout.playResY, 1))
    let scaleX = rect.width / CGFloat(max(layout.playResX, 1))
    let first = item.cues[0]
    let anchor = layout.anchor(elapsed: (time - first.start) * 1000, duration: (first.end - first.start) * 1000)
    let x = rect.minX + CGFloat(anchor.x) * scaleX
    let rawY = rect.minY + CGFloat(anchor.y) * scaleY
    let bottomLine = !item.positioned && layout.verticalFraction == 1
    let y = bottomLine ? min(rawY, size.height - bottomInset) : rawY
    let horizontal = CGFloat(layout.horizontalFraction)
    let vertical = CGFloat(layout.verticalFraction)
    return VStack(alignment: PlayerASSOverlay.horizontalAlignment(layout), spacing: 0) {
      ForEach(item.visualOrder) { cue in
        if let cueLayout = cue.ass {
          PlayerASSCueView(
            layout: cueLayout,
            scale: scaleY,
            wrapWidth: CGFloat(cueLayout.wrapWidth) * scaleX,
            opacity: cueLayout.opacity(elapsed: (time - cue.start) * 1000)
          )
        }
      }
    }
    .frame(width: size.width, height: size.height, alignment: PlayerASSOverlay.frameAlignment(layout))
    .offset(x: x - horizontal * size.width, y: y - vertical * size.height)
  }

  static func horizontalAlignment(_ layout: PlayerASSLayout) -> HorizontalAlignment {
    switch layout.horizontalFraction {
    case 0: return .leading
    case 1: return .trailing
    default: return .center
    }
  }

  static func frameAlignment(_ layout: PlayerASSLayout) -> Alignment {
    let vertical: VerticalAlignment
    switch layout.verticalFraction {
    case 0: vertical = .top
    case 1: vertical = .bottom
    default: vertical = .center
    }
    return Alignment(horizontal: horizontalAlignment(layout), vertical: vertical)
  }
}

/// One typeset dialogue line: styled runs, outline / shadow or opaque box, scale, rotation and fade.
struct PlayerASSCueView: View {
  let layout: PlayerASSLayout
  /// Points per script unit (video height / PlayResY).
  let scale: CGFloat
  let wrapWidth: CGFloat
  let opacity: Double

  var body: some View {
    let anchor = UnitPoint(x: CGFloat(layout.horizontalFraction), y: CGFloat(layout.verticalFraction))
    return styledText
      .multilineTextAlignment(textAlignment)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: max(wrapWidth, 1), alignment: PlayerASSOverlay.frameAlignment(layout))
      .modifier(PlayerASSBorder(layout: layout, scale: scale))
      .scaleEffect(x: CGFloat(layout.scaleX / 100), y: CGFloat(layout.scaleY / 100), anchor: anchor)
      .rotationEffect(.degrees(-layout.rotation), anchor: anchor)
      .opacity(opacity)
  }

  private var textAlignment: TextAlignment {
    switch layout.horizontalFraction {
    case 0: return .leading
    case 1: return .trailing
    default: return .center
    }
  }

  private var styledText: Text {
    layout.runs.reduce(Text(verbatim: "")) { partial, run in
      partial + PlayerASSCueView.text(run, scale: scale)
    }
  }

  static func text(_ run: PlayerASSRun, scale: CGFloat) -> Text {
    let size = max(CGFloat(run.fontSize) * scale * PlayerASSMetrics.fontScale, 1)
    var text = Text(run.text)
      .font(Font.custom(run.fontName, fixedSize: size))
      .foregroundColor(run.primary.color)
    if run.bold { text = text.bold() }
    if run.italic { text = text.italic() }
    if run.underline { text = text.underline() }
    if run.strikeout { text = text.strikethrough() }
    return text
  }
}

/// BorderStyle 1 (outline + drop shadow) or 3 (opaque box).
struct PlayerASSBorder: ViewModifier {
  let layout: PlayerASSLayout
  let scale: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    let outline = CGFloat(layout.outline) * scale
    let shadow = CGFloat(layout.shadow) * scale
    if layout.borderStyle == 3 {
      content
        .padding(.horizontal, max(outline, 1))
        .padding(.vertical, max(outline * 0.5, 0.5))
        .background(layout.outlineColor.color)
        .shadow(color: shadow > 0.05 ? layout.backColor.color : Color.clear, radius: 0, x: shadow, y: shadow)
    } else {
      content.modifier(PlayerTextOutline(
        color: layout.outlineColor.color,
        width: outline,
        shadowColor: layout.backColor.color,
        shadowOffset: shadow
      ))
    }
  }
}

/// Text outline drawn with stacked hard shadows (SwiftUI has no text stroke), plus an optional drop shadow.
struct PlayerTextOutline: ViewModifier {
  let color: Color
  let width: CGFloat
  let shadowColor: Color
  let shadowOffset: CGFloat

  func body(content: Content) -> some View {
    let step = width
    let outline = step > 0.05 ? color : Color.clear
    // Thick outlines also get half steps so thin strokes do not show gaps.
    let half = step > 2.5 ? color : Color.clear
    return content
      .shadow(color: half, radius: 0, x: step / 2, y: 0)
      .shadow(color: half, radius: 0, x: -step / 2, y: 0)
      .shadow(color: half, radius: 0, x: 0, y: step / 2)
      .shadow(color: half, radius: 0, x: 0, y: -step / 2)
      .shadow(color: outline, radius: 0, x: step, y: 0)
      .shadow(color: outline, radius: 0, x: -step, y: 0)
      .shadow(color: outline, radius: 0, x: 0, y: step)
      .shadow(color: outline, radius: 0, x: 0, y: -step)
      .shadow(color: shadowOffset > 0.05 ? shadowColor : Color.clear, radius: 0, x: shadowOffset, y: shadowOffset)
  }
}

extension PlayerASSColor {
  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
  }

  var uiColor: UIColor {
    UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(opacity))
  }
}

// MARK: - Screenshot burn-in

/// Draws the active external subtitle cues onto a video frame (the Svelte screenshot composites the JASSUB
/// canvas over the frame). The frame is the video rect, so ASS script coordinates map to the whole image.
enum PlayerSubtitleBurner {
  static func render(_ frame: CGImage, cues: [PlayerSubtitleCue], time: Double) -> UIImage {
    let size = CGSize(width: frame.width, height: frame.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { context in
      let bounds = CGRect(origin: .zero, size: size)
      UIImage(cgImage: frame).draw(in: bounds)
      let cgContext = context.cgContext
      let styled = cues.filter { $0.ass != nil }
      for item in PlayerASSItem.items(styled) {
        drawItem(item, in: bounds, time: time, context: cgContext)
      }
      drawPlain(cues.filter { $0.ass == nil }, in: bounds)
    }
  }

  private enum Pass {
    case fill
    case stroke(UIColor, CGFloat)
    case solid(UIColor, CGFloat)
  }

  private static func drawItem(_ item: PlayerASSItem, in bounds: CGRect, time: Double, context: CGContext) {
    let layout = item.layout
    let scaleY = bounds.height / CGFloat(max(layout.playResY, 1))
    let scaleX = bounds.width / CGFloat(max(layout.playResX, 1))
    let first = item.cues[0]
    let point = layout.anchor(elapsed: (time - first.start) * 1000, duration: (first.end - first.start) * 1000)
    let anchor = CGPoint(x: bounds.minX + CGFloat(point.x) * scaleX, y: bounds.minY + CGFloat(point.y) * scaleY)
    let ordered = item.visualOrder.compactMap { cue -> (cue: PlayerSubtitleCue, layout: PlayerASSLayout, size: CGSize)? in
      guard let cueLayout = cue.ass else { return nil }
      let measured = measure(attributed(cueLayout, scale: scaleY, pass: .fill), width: CGFloat(cueLayout.wrapWidth) * scaleX)
      return (cue, cueLayout, measured)
    }
    let totalHeight = ordered.reduce(0) { $0 + $1.size.height }
    let horizontal = CGFloat(layout.horizontalFraction)
    var top = anchor.y - CGFloat(layout.verticalFraction) * totalHeight
    for entry in ordered {
      let origin = CGPoint(x: anchor.x - horizontal * entry.size.width, y: top)
      let opacity = CGFloat(entry.layout.opacity(elapsed: (time - entry.cue.start) * 1000))
      let cueAnchor = CGPoint(x: anchor.x, y: top + CGFloat(entry.layout.verticalFraction) * entry.size.height)
      drawCue(entry.layout, rect: CGRect(origin: origin, size: entry.size), anchor: cueAnchor, scale: scaleY, opacity: opacity, context: context)
      top += entry.size.height
    }
  }

  private static func drawCue(_ layout: PlayerASSLayout, rect: CGRect, anchor: CGPoint, scale: CGFloat, opacity: CGFloat, context: CGContext) {
    guard opacity > 0.01 else { return }
    let outline = CGFloat(layout.outline) * scale
    let shadow = CGFloat(layout.shadow) * scale
    context.saveGState()
    context.setAlpha(opacity)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    if layout.rotation != 0 || layout.scaleX != 100 || layout.scaleY != 100 {
      context.translateBy(x: anchor.x, y: anchor.y)
      context.rotate(by: -CGFloat(layout.rotation) * .pi / 180)
      context.scaleBy(x: CGFloat(layout.scaleX / 100), y: CGFloat(layout.scaleY / 100))
      context.translateBy(x: -anchor.x, y: -anchor.y)
    }
    if layout.borderStyle == 3 {
      let box = rect.insetBy(dx: -max(outline, 1), dy: -max(outline * 0.5, 0.5))
      if shadow > 0.05 {
        context.setFillColor(layout.backColor.uiColor.cgColor)
        context.fill(box.offsetBy(dx: shadow, dy: shadow))
      }
      context.setFillColor(layout.outlineColor.uiColor.cgColor)
      context.fill(box)
    } else {
      if shadow > 0.05 {
        draw(attributed(layout, scale: scale, pass: .solid(layout.backColor.uiColor, outline)), in: rect.offsetBy(dx: shadow, dy: shadow))
      }
      if outline > 0.05 {
        draw(attributed(layout, scale: scale, pass: .stroke(layout.outlineColor.uiColor, outline)), in: rect)
      }
    }
    draw(attributed(layout, scale: scale, pass: .fill), in: rect)
    context.endTransparencyLayer()
    context.restoreGState()
  }

  private static func attributed(_ layout: PlayerASSLayout, scale: CGFloat, pass: Pass) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    switch layout.horizontalFraction {
    case 0: paragraph.alignment = .left
    case 1: paragraph.alignment = .right
    default: paragraph.alignment = .center
    }
    paragraph.lineBreakMode = .byWordWrapping
    let result = NSMutableAttributedString()
    for run in layout.runs {
      let size = max(CGFloat(run.fontSize) * scale * PlayerASSMetrics.fontScale, 1)
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font(name: run.fontName, size: size, bold: run.bold, italic: run.italic),
        .paragraphStyle: paragraph
      ]
      switch pass {
      case .fill:
        attributes[.foregroundColor] = run.primary.uiColor
      case .stroke(let color, let width):
        // Positive stroke width = stroke only, centred on the glyph outline (half of it is outside).
        attributes[.foregroundColor] = UIColor.clear
        attributes[.strokeColor] = color
        attributes[.strokeWidth] = width * 2 / size * 100
      case .solid(let color, let width):
        // Negative stroke width = fill and stroke (the drop shadow covers the outline too).
        attributes[.foregroundColor] = color
        attributes[.strokeColor] = color
        attributes[.strokeWidth] = -(width * 2 / size * 100)
      }
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if run.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }

  private static func font(name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
    let base = UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
    var traits = base.fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    guard traits != base.fontDescriptor.symbolicTraits,
          let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
    return UIFont(descriptor: descriptor, size: size)
  }

  private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    let bounds = text.boundingRect(
      with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(bounds.width) + 1, height: ceil(bounds.height))
  }

  private static func draw(_ text: NSAttributedString, in rect: CGRect) {
    text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
  }

  /// Plain cues: same look as PlayerSubtitleOverlay (white, black outline, centred, top or bottom).
  private static func drawPlain(_ cues: [PlayerSubtitleCue], in bounds: CGRect) {
    guard !cues.isEmpty else { return }
    let fontSize = max(15, min(bounds.height, bounds.width * 9 / 16) * 0.055)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let width = bounds.width * 0.9
    func strings(_ cue: PlayerSubtitleCue) -> (fill: NSAttributedString, stroke: NSAttributedString) {
      let textFont = font(name: "", size: fontSize, bold: true, italic: cue.italic)
      let fill = NSAttributedString(string: cue.text, attributes: [
        .font: textFont, .paragraphStyle: paragraph, .foregroundColor: UIColor.white
      ])
      let stroke = NSAttributedString(string: cue.text, attributes: [
        .font: textFont, .paragraphStyle: paragraph, .foregroundColor: UIColor.clear,
        .strokeColor: UIColor.black, .strokeWidth: 16
      ])
      return (fill, stroke)
    }
    var top = bounds.minY + bounds.height * 0.04
    for cue in cues where cue.isTop {
      let pair = strings(cue)
      let size = measure(pair.fill, width: width)
      let rect = CGRect(x: bounds.midX - size.width / 2, y: top, width: size.width, height: size.height)
      draw(pair.stroke, in: rect)
      draw(pair.fill, in: rect)
      top += size.height
    }
    var bottom = bounds.maxY - bounds.height * 0.05
    for cue in cues.filter({ !$0.isTop }).reversed() {
      let pair = strings(cue)
      let size = measure(pair.fill, width: width)
      let rect = CGRect(x: bounds.midX - size.width / 2, y: bottom - size.height, width: size.width, height: size.height)
      draw(pair.stroke, in: rect)
      draw(pair.fill, in: rect)
      bottom -= size.height
    }
  }
}
