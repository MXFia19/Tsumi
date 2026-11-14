import SwiftUI

@main
struct TsumiApp: App {
  /// Player orientation lock (PlayerOrientation.supportedMask) and early wiring of notification taps.
  @UIApplicationDelegateAdaptor(ShellAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
        .preferredColorScheme(.dark)
    }
  }
}
