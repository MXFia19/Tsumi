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

/// A theatrical or digital release still to come.
struct MovieRelease: Hashable, Sendable {
  enum Kind: String, Sendable {
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
  static let theatricalTypes = [2, 3]
  static let digitalTypes = [4]

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
  /// (with `anywhere`) in any country. Digital releases are often only listed for the US.
  static func releaseDate(_ countries: [TMDBReleaseCountry], types: [Int], regions: [String], anywhere: Bool = false) -> String? {
    func days(_ country: String?) -> [String] {
      countries
        .filter { country == nil || $0.country == country }
        .flatMap { $0.dates }
        .filter { types.contains($0.type) && $0.date.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
        .map { String($0.date.prefix(10)) }
        .sorted()
    }
    for country in regions {
      if let first = days(country).first { return first }
    }
    return anywhere ? days(nil).first : nil
  }

  /// releaseDay: local midnight of a "YYYY-MM-DD" day.
  static func releaseDay(_ day: String) -> Date? {
    let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    // TMDB days are Gregorian, whatever the device calendar.
    return ServiceDates.gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
