import SwiftUI
import Observation

/// The few settings the hot views read (every card, the Home banner), one observable property per value.
/// `AppSettings.values` is a single observable struct: reading any field of it in a view makes that view
/// depend on every setting, so each settings write (player volume, subtitle style...) re-rendered every card
/// of Home. A property here only changes when its own value changes.
@MainActor
@Observable
final class BrowseSettingsMirror {
  static let shared = BrowseSettingsMirror()

  private(set) var cardPreview: Bool
  private(set) var cardAudio: Bool
  private(set) var titleLang: TitleLanguage
  private(set) var adult: String
  private(set) var hentaiBanner: Bool
  private(set) var bannerProvider: String

  private init() {
    let values = AppSettings.shared.values
    cardPreview = values.cardPreview
    cardAudio = values.cardAudio
    titleLang = values.titleLang
    adult = values.adult
    hentaiBanner = values.hentaiBanner
    bannerProvider = values.bannerProvider
    observe()
  }

  /// Follows the settings: the tracking ends at the first change, so it is set up again after each one.
  private func observe() {
    let values = withObservationTracking {
      AppSettings.shared.values
    } onChange: {
      Task { @MainActor in
        BrowseSettingsMirror.shared.observe()
      }
    }
    update(values)
  }

  /// Assigns only the values that changed (an @Observable property notifies on every assignment).
  private func update(_ values: SettingsValues) {
    if cardPreview != values.cardPreview { cardPreview = values.cardPreview }
    if cardAudio != values.cardAudio { cardAudio = values.cardAudio }
    if titleLang != values.titleLang { titleLang = values.titleLang }
    if adult != values.adult { adult = values.adult }
    if hentaiBanner != values.hentaiBanner { hentaiBanner = values.hentaiBanner }
    if bannerProvider != values.bannerProvider { bannerProvider = values.bannerProvider }
  }
}
