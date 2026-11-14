import SwiftUI
import Observation

/// Main tabs, same order as the desktop sidebar (common/components/navigation/Sidebar.svelte).
enum AppTab: String, Hashable, CaseIterable {
  case home
  case search
  case schedule
  case catalogs
  case watchTogether
  case settings
}

/// App-wide navigation shared by every screen: which tab is shown, which title's details are open,
/// and what the Search tab should show (e.g. "see all" of a home section).
@MainActor
@Observable
final class AppRouter {
  static let shared = AppRouter()

  var selectedTab: AppTab = .home
  /// Details sheet (DetailsModal.svelte equivalent).
  var presentedMedia: Media?
  /// Set before switching to the Search tab to show a section's full list or a preset query.
  var pendingSearch: PendingSearch?
  var showNotifications = false
  var showProfiles = false

  private init() {}

  func open(_ media: Media) {
    presentedMedia = media
  }

  func closeDetails() {
    presentedMedia = nil
  }

  func show(_ tab: AppTab) {
    presentedMedia = nil
    selectedTab = tab
  }

  /// Opens the Search tab on a given home section (its "see all" list).
  func showAll(sectionTitle: String) {
    pendingSearch = PendingSearch(sectionTitle: sectionTitle, query: nil)
    show(.search)
  }

  /// Opens the Search tab with a query (genre/tag/studio chips in the details view...).
  func search(_ query: MediaQuery) {
    pendingSearch = PendingSearch(sectionTitle: nil, query: query)
    show(.search)
  }
}

struct PendingSearch: Identifiable, Hashable {
  let id = UUID()
  var sectionTitle: String?
  var query: MediaQuery?
}
