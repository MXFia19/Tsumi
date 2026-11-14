import SwiftUI

/// Temporary root view; replaced by the full navigation (Home, Search, Schedule, Catalogs,
/// Watch Together, Settings) once the screens are written.
struct RootView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "play.tv")
        .font(.system(size: 48))
      Text("Tsumi")
        .font(.largeTitle.bold())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
