import Foundation

// Upcoming movies in the schedule. Port of common/modules/schedule/movies.js: a movie shows up at its theatrical
// release and again at its digital release, the "Release" filter of the schedule choosing which.
// Dates come from TMDB /movie/{id}/release_dates. Release types: 1 premiere, 2 theatrical (limited),
// 3 theatrical, 4 digital, 5 physical, 6 TV.

/// "Release" filter of the schedule (search.release of SearchBar.svelte, RELEASE_FILTERS).
enum ScheduleRelease: String, CaseIterable, Identifiable, Codable, Sendable {
  case any = ""
  case episodes
  case movies
  case theatrical
  case digital

  var id: String { rawValue }

  var label: String {
    switch self {
    case .any: return "Any"
    case .episodes: return "Episodes"
    case .movies: return "Movies"
    case .theatrical: return "In Theaters"
    case .digital: return "Digital"
    }
  }

  /// releaseKinds of movies.js.
  var episodes: Bool { self == .any || self == .episodes }
  var theatrical: Bool { self == .any || self == .movies || self == .theatrical }
  var digital: Bool { self == .any || self == .movies || self == .digital }
}

/// Release dates of one country (TMDB release_dates results).
struct TMDBReleaseCountry: Codable, Hashable, Sendable {
  var country: String
  var dates: [TMDBReleaseDate]
}

struct TMDBReleaseDate: Codable, Hashable, Sendable {
  var type: Int
  /// "2026-11-18T00:00:00.000Z"
  var date: String
}

/// Theatrical and digital release days of a movie ("YYYY-MM-DD", nil when TMDB has none).
struct MovieReleaseDays: Hashable, Sendable {
  var theatrical: String?
  var digital: String?

  func day(_ kind: MovieRelease.Kind) -> String? {
    kind == .theatrical ? theatrical : digital
  }
}

/// A theatrical or digital release still to come.
struct MovieRelease: Hashable, Sendable {
  enum Kind: String, CaseIterable, Sendable {
    case theatrical
    case digital
  }

  var kind: Kind
  var date: Date

  /// RELEASE_LABELS: "In theaters in 2d 3h", "On digital in 21d".
  var label: String { kind == .theatrical ? "In theaters" : "On digital" }
}

enum MovieReleases {
  /// MOVIE_WINDOW_DAYS: how far ahead movies are listed.
  static let windowDays = 60
  /// Theatrical: the wide release (3) of a country, else its limited one (2). A limited release before the wide one
  /// (US awards runs) would otherwise hide the wide date once it has passed (schedule and release alerts).
  static let theatricalTypes: [[Int]] = [[3], [2]]
  static let digitalTypes: [[Int]] = [[4]]

  /// LANGUAGE_COUNTRIES: main country of a language ("fr" -> FR), TMDB often has no dates for smaller countries.
  static let languageCountries = [
    "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "nl": "NL", "pt": "PT", "pl": "PL", "sv": "SE", "da": "DK",
    "nb": "NO", "no": "NO", "fi": "FI", "ru": "RU", "tr": "TR", "ja": "JP", "ko": "KR", "zh": "CN", "en": "US"
  ]

  /// releaseRegions: the device region, the main country of the first preferred language, the other countries
  /// and languages, then the US. A Belgian device in French -> ["BE", "FR", "US"].
  static var regions: [String] {
    var named: [String] = []
    if let device = Locale.current.region?.identifier, device.count == 2 { named.append(device.uppercased()) }
    let languages = Locale.preferredLanguages
    named += languages.compactMap { Locale(identifier: $0).region?.identifier }.filter { $0.count == 2 }.map { $0.uppercased() }
    let spoken = languages.compactMap { languageCountries[String($0.prefix(2)).lowercased()] }
    var result: [String] = []
    for region in [named.first, spoken.first].compactMap({ $0 }) + Array(named.dropFirst()) + Array(spoken.dropFirst()) + ["US"] where !result.contains(region) {
      result.append(region)
    }
    return result
  }

  /// releaseDate: first release day ("YYYY-MM-DD") of one of `types` in the first of `regions` that has one, else
  /// (with `anywhere`) in any country. Digital releases are often only listed for the US. `types` are groups tried
  /// in order within each country ([[3], [2]]: wide, else limited).
  static func releaseDate(_ countries: [TMDBReleaseCountry], types: [[Int]], regions: [String], anywhere: Bool = false) -> String? {
    func days(_ country: String?, _ group: [Int]) -> [String] {
      countries
        .filter { country == nil || $0.country == country }
        .flatMap { $0.dates }
        .filter { group.contains($0.type) && $0.date.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
        .map { String($0.date.prefix(10)) }
        .sorted()
    }
    func first(_ country: String?) -> String? {
      for group in types {
        if let day = days(country, group).first { return day }
      }
      return nil
    }
    for country in regions {
      if let found = first(country) { return found }
    }
    return anywhere ? first(nil) : nil
  }

  /// releaseDay: local midnight of a "YYYY-MM-DD" day (in the time zone of `calendar`).
  static func releaseDay(_ day: String, calendar: Calendar = ServiceDates.gregorian) -> Date? {
    let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    // TMDB days are Gregorian, whatever the device calendar.
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// Theatrical and digital release days used by the release alerts (MovieAlertsService) and the details bell:
  /// theatrical = wide release (type 3), else limited (type 2), of the first release region that has one (no
  /// fallback), digital = first day of type 4 in the release regions, else anywhere (the same days as the schedule).
  static func days(_ countries: [TMDBReleaseCountry], regions: [String]) -> MovieReleaseDays {
    MovieReleaseDays(
      theatrical: releaseDate(countries, types: theatricalTypes, regions: regions),
      digital: releaseDate(countries, types: digitalTypes, regions: regions, anywhere: true)
    )
  }

  /// movieReleaseNodes: the theatrical and digital releases still to come within `days`, earliest first.
  static func releases(_ countries: [TMDBReleaseCountry], regions: [String], theatrical: Bool = true, digital: Bool = true, now: Date = Date(), days: Int = windowDays) -> [MovieRelease] {
    let until = now.addingTimeInterval(Double(days) * 86_400)
    var result: [MovieRelease] = []
    func add(_ kind: MovieRelease.Kind, _ day: String?) {
      guard let day, let date = releaseDay(day), date > now, date <= until else { return }
      result.append(MovieRelease(kind: kind, date: date))
    }
    if theatrical { add(.theatrical, releaseDate(countries, types: theatricalTypes, regions: regions)) }
    if digital { add(.digital, releaseDate(countries, types: digitalTypes, regions: regions, anywhere: true)) }
    return result.sorted { $0.date < $1.date }
  }
}
