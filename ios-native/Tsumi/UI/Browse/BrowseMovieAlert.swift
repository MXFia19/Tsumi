import SwiftUI

// Movie release alerts in the interface (Services/MovieAlertsService.swift): the bell of the details of a TMDB movie,
// the line with its upcoming release days, and the bell shown on the schedule cards of the watched movies.

@MainActor
enum BrowseMovieAlert {
  /// Days after which a theatrical release with no digital date is old news (about 6 months, same as PC): an old
  /// movie that never got a digital date on TMDB would otherwise offer the bell forever.
  static let staleTheatricalDays = 183

  /// The bell shows for TMDB movies once their release days are loaded, unless the digital release is already
  /// past, or there is no digital date and the theatrical release is more than `staleTheatricalDays` old; a watched
  /// movie always shows it, so that the alert can be turned off.
  static func showsBell(_ media: Media, days: MovieReleaseDays?) -> Bool {
    guard MovieAlertsService.supports(media) else { return false }
    if MovieAlertsService.shared.isWatched(media) { return true }
    guard let days else { return false }
    let now = Date()
    let calendar = ServiceDates.gregorian
    if MovieAlertRules.digitalReleasePassed(days, now: now, calendar: calendar) { return false }
    return !theatricalLongPast(days, now: now, calendar: calendar)
  }

  /// No digital date and a theatrical release more than `staleTheatricalDays` before today.
  static func theatricalLongPast(_ days: MovieReleaseDays, now: Date, calendar: Calendar) -> Bool {
    guard days.digital == nil,
          let theatrical = days.theatrical,
          let day = MovieReleases.releaseDay(theatrical, calendar: calendar),
          let limit = calendar.date(byAdding: .day, value: -staleTheatricalDays, to: calendar.startOfDay(for: now)) else { return false }
    return day < limit
  }

  /// "In theaters Nov 18 · Digital Jan 5" (releases still to come only).
  static func upcomingText(_ days: MovieReleaseDays?) -> String? {
    guard let days else { return nil }
    return MovieAlertRules.upcomingText(days, now: Date(), calendar: ServiceDates.gregorian)
  }
}

/// Release alert toggle of the movie details (bell / bell.fill), with a toast like PC MovieAlertButton.svelte.
@MainActor
struct BrowseMovieAlertButton: View {
  let media: Media
  /// "In theaters Nov 18 · Digital Jan 5", shown by the "Release alert on" toast when known.
  var upcoming: String? = nil

  var body: some View {
    let service = MovieAlertsService.shared
    let watched = service.isWatched(media)
    Button {
      if watched, let tmdbId = media.tmdbId {
        service.remove(tmdbId: tmdbId)
        ServiceMessages.shared.post(.info, "Release alert off")
      } else {
        service.add(media)
        ServiceMessages.shared.post(.success, "Release alert on", upcoming ?? "You will be notified when it comes out in theaters and on digital.")
        // System notifications on but not allowed yet: the permission prompt comes with the first alert.
        let notifications = AppNotificationsService.shared
        if AppSettings.shared.values.systemNotify && !notifications.authorizationGranted {
          Task { @MainActor in
            _ = await notifications.requestAuthorization()
          }
        }
      }
    } label: {
      Image(systemName: watched ? "bell.fill" : "bell")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(watched ? BrowsePalette.tertiary : Color.white)
        .frame(width: 44, height: 44)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Release alert")
    .accessibilityValue(watched ? "On" : "Off")
    .accessibilityHint(watched ? "Stops the theatrical and digital release notifications" : "Notifies you when the movie comes out in theaters and on digital")
  }
}

/// Upcoming release days under the action buttons of the movie details.
struct BrowseMovieAlertDates: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "calendar")
      .font(.footnote.weight(.medium))
      .foregroundStyle(BrowsePalette.muted)
  }
}

/// Bell on the schedule card of a watched movie.
struct BrowseMovieAlertBadge: View {
  var body: some View {
    Image(systemName: "bell.fill")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 20, height: 20)
      .background(BrowsePalette.tertiary, in: Circle())
      .accessibilityLabel("Release alert on")
  }
}
