import SwiftUI
import UIKit

@main
struct TsumiApp: App {
  /// Player orientation lock (PlayerOrientation.supportedMask) and early wiring of notification taps.
  @UIApplicationDelegateAdaptor(ShellAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
        .preferredColorScheme(.dark)
        .modifier(TsumiAppearance())
    }
  }
}

/// Interface settings applied to the whole app: UI Scale (settings.uiScale, themes.js setScale) as a Dynamic
/// Type size, and the accent colour (the `--accent-color` CSS variable) as the tint.
@MainActor
struct TsumiAppearance: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    let values = AppSettings.shared.values
    let tinted = content.tint(TsumiAppearanceStyle.color(hex: values.accentColor))
    if let size = TsumiAppearanceStyle.dynamicTypeSize(scale: values.uiScale) {
      tinted.dynamicTypeSize(size)
    } else {
      tinted
    }
  }
}

enum TsumiAppearanceStyle {
  /// Scale choices of Settings > Interface (Svelte: a 50-200 % slider).
  static let scales: [Double] = [0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2]

  /// Dynamic Type size for a UI scale; nil at 100 % (the system text size is kept).
  static func dynamicTypeSize(scale: Double) -> DynamicTypeSize? {
    if abs(scale - 1) < 0.001 { return nil }
    switch scale {
    case ..<0.7: return .xSmall
    case ..<0.85: return .small
    case ..<1: return .medium
    case ..<1.15: return .xLarge
    case ..<1.3: return .xxLarge
    case ..<1.6: return .xxxLarge
    case ..<1.9: return .accessibility1
    default: return .accessibility2
    }
  }

  /// The scale choice closest to `scale` (imported values may sit between two choices).
  static func nearestScale(_ scale: Double) -> Double {
    scales.min(by: { abs($0 - scale) < abs($1 - scale) }) ?? 1
  }

  /// "#RRGGBB" → Color; nil for an empty or invalid value (the app default).
  static func color(hex: String) -> Color? {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }

  /// Color → "#RRGGBB".
  static func hex(_ color: Color) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "" }
    func channel(_ value: CGFloat) -> Int {
      Int((min(max(value, 0), 1) * 255).rounded())
    }
    return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }
}
