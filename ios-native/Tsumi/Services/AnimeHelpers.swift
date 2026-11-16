import Foundation

// Port of the non-UI helpers of common/modules/anime/anime.js: getMediaMaxEp, hasZeroEpisode,
// nextAiring / lastAired / airing labels, episodeByAirDate, genre / tag catalogs, trace.moe lookup
// (traceAnime) and AniSkip chapters (getChaptersAniSkip).

/// Zero episode (prologue / episode 0) detected by hasZeroEpisode.
struct ZeroEpisodeInfo: Hashable {
  var title: String?
  var thumbnail: URL?
  var length: Int?
  var summary: String?
  var airingAt: Date?
}

/// trace.moe match resolved to an AniList media.
struct TraceMoeMatch: Identifiable, Hashable {
  var id: String { media.id + "-\(episode ?? 0)-\(similarity)" }
  var media: Media
  var episode: Int?
  var similarity: Double
  var image: URL?
  var video: URL?
  var episodeTitle: String?
  var thumbnail: URL?
}

/// Chapter computed from AniSkip intervals (milliseconds).
struct SkipChapter: Hashable {
  var start: Double
  var end: Double
  var text: String
}

enum AnimeCatalog {
  /// durationMap: guessed duration (minutes) per format.
  static func duration(for format: MediaFormat) -> Int {
    switch format {
    case .tv: return 25
    case .tvShort: return 5
    case .movie: return 90
    case .special: return 45
    case .ova: return 25
    case .ona: return 25
    case .music: return 5
    case .unknown: return 5
    }
  }

  /// formatMap (N/A for unknown formats).
  static func formatLabel(_ format: MediaFormat) -> String {
    format == .unknown ? "N/A" : format.label
  }

  /// genreList (Hentai only when the adult setting is 'hentai').
  static var genres: [String] {
    var list = ["Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy"]
    if AppSettings.shared.values.adult == "hentai" { list.append("Hentai") }
    list += ["Horror", "Mahou Shoujo", "Mecha", "Music", "Mystery", "Psychological", "Romance", "Sci-Fi",
             "Slice of Life", "Sports", "Supernatural", "Thriller"]
    return list
  }

  /// tagList (adult tags only when the adult setting is 'hentai').
  static var tags: [String] {
    AppSettings.shared.values.adult == "hentai" ? baseTags + adultTags : baseTags
  }

  /// tmdbGenreList of tmdb.js.
  static let tmdbGenres: [String] = [
    "Action", "Action & Adventure", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
    "Family", "Fantasy", "History", "Horror", "Kids", "Music", "Mystery", "Reality", "Romance", "Sci-Fi",
    "Sci-Fi & Fantasy", "Thriller", "War", "War & Politics", "Western"
  ]

  static let baseTags: [String] = [
    "Chuunibyou", "Demons", "Food", "Heterosexual", "Isekai", "Iyashikei", "Josei", "Magic", "Yuri", "Love Triangle",
    "Female Harem", "Male Harem", "Mixed Gender Harem", "Arranged Marriage", "Marriage", "Martial Arts", "Military",
    "Nudity", "Parody", "Reincarnation", "Satire", "School", "Seinen", "Shoujo", "Shounen", "Slavery", "Space",
    "Super Power", "Superhero", "Teens' Love", "Unrequited Love", "Vampire", "Kids", "Gender Bending", "Body Swapping",
    "Boys' Love", "Cute Boys Doing Cute Things", "Cute Girls Doing Cute Things", "4-koma", "Achromatic",
    "Achronological Order", "Acrobatics", "Acting", "Adoption", "Advertisement", "Afterlife", "Age Gap",
    "Age Regression", "Agriculture", "Agender", "Airsoft", "Alchemy", "Aliens", "Alternate Universe",
    "American Football", "Amnesia", "Amputation", "Ancient China", "Animals", "Angels", "Anthropomorphism",
    "Anthology", "Anti-Hero", "Anachronism", "Archery", "Artificial Intelligence", "Aromantic", "Assassins",
    "Astronomy", "Asexual", "Athletics", "Augmented Reality", "Autobiographical", "Aviation", "Badminton", "Band",
    "Bar", "Baseball", "Basketball", "Battle Royale", "Biographical", "Bisexual", "Blackmail", "Board Game",
    "Boarding School", "Body Horror", "Body Image", "Bowling", "Boxing", "Bullying", "Butler", "Calligraphy", "Cars",
    "Cannibalism", "Chibi", "Cosmic Horror", "Creature Taming", "Crossover", "CGI", "Centaur", "Cheerleading",
    "Chimera", "Class Struggle", "Classic Literature", "Classical Music", "Cohabitation", "College", "Coming of Age",
    "Conspiracy", "Cosplay", "Cowboys", "Crime", "Criminal Organization", "Crossdressing", "Cult", "Cultivation",
    "Curses", "Cyberpunk", "Cyborg", "Cycling", "Dancing", "Death Game", "Delinquents", "Denpa", "Desert",
    "Detective", "Disability", "Dinosaurs", "Drawing", "Dragons", "Drugs", "Dullahan", "Dungeon", "Dystopian",
    "E-Sports", "Eco-Horror", "Economics", "Educational", "Elderly Protagonist", "Elf", "Ensemble Cast",
    "Environmental", "Episodic", "Ero Guro", "Estranged Family", "Espionage", "Exhibitionism", "Exorcism", "Fairy",
    "Fairy Tale", "Fake Relationship", "Family Life", "Fashion", "Femboy", "Female Protagonist", "Fencing",
    "Filmmaking", "Firefighters", "Fishing", "Fitness", "Flash", "Football", "Foreign", "Found Family", "Full CGI",
    "Full Color", "Fugitive", "Gambling", "Gangs", "Ghost", "Gods", "Goblin", "Golf", "Gore", "Guns", "Gyaru",
    "Handball", "Henshin", "Hikikomori", "Hip-hop Music", "Historical", "Homeless", "Horticulture", "Human Pet",
    "Ice Skating", "Idol", "Incest", "Indigenous Cultures", "Inn", "Jazz Music", "Judo", "Kaiju", "Kemonomimi",
    "Kingdom Management", "Konbini", "Kuudere", "Language Barrier", "Lacrosse", "LGBTQ+ Themes", "Long Strip",
    "Lost Civilization", "Maids", "Makeup", "Male Protagonist", "Mafia", "Matriarchy", "Matchmaking", "Medicine",
    "Medieval", "Memory Manipulation", "Mermaid", "Meta", "Metal Music", "Mixed Media", "Mopeds", "Monster Boy",
    "Monster Girl", "Motorcycles", "Mountaineering", "Musical Theater", "Mythology", "Natural Disaster",
    "Necromancy", "Nekomimi", "Ninja", "No Dialogue", "Noir", "Non-fiction", "Nun", "Office", "Office Lady", "Oiran",
    "Ojou-sama", "Omegaverse", "Orphan", "Otaku Culture", "Outdoor Activities", "Pandemic", "Parkour", "Parenthood",
    "Photography", "Pirates", "Philosophy", "Police", "Politics", "Polyamorous", "POV", "Post-Apocalyptic",
    "Primarily Adult Cast", "Primarily Animal Cast", "Primarily Child Cast", "Primarily Female Cast",
    "Primarily Male Cast", "Primarily Teen Cast", "Pregnancy", "Prison", "Proxy Battle", "Psychosexual", "Puppetry",
    "Rakugo", "Rape", "Real Robot", "Rehabilitation", "Religion", "Rescue", "Restaurant", "Revenge", "Robots",
    "Rock Music", "Rotoscoping", "Royal Affairs", "Rural", "Rugby", "Sadism", "Samurai", "School Club",
    "Scuba Diving", "Shapeshifting", "Ships", "Shrine Maiden", "Skateboarding", "Skeleton", "Slapstick",
    "Software Development", "Snowscape", "Space Opera", "Spearplay", "Stop Motion", "Steampunk", "Succubus",
    "Suicide", "Sumo", "Surfing", "Super Robot", "Surreal Comedy", "Survival", "Sweat", "Swordplay", "Swimming",
    "Table Tennis", "Tanks", "Tanned Skin", "Teacher", "Tennis", "Terrorism", "Time Loop", "Time Manipulation",
    "Time Skip", "Tokusatsu", "Tomboy", "Torture", "Tragedy", "Trains", "Transgender", "Travel", "Triads", "Tsundere",
    "Twins", "Urban", "Urban Fantasy", "Veterinarian", "Video Games", "Vikings", "Villainess", "Virtual World",
    "Vocal Synth", "Volleyball", "VTuber", "War", "Watersports", "Werewolf", "Witch", "Wilderness", "Work",
    "Wrestling", "Writing", "Wuxia", "Yakuza", "Yandere", "Youkai", "Zombie", "Vertical Video"
  ]

  static let adultTags: [String] = [
    "Ahegao", "Anal Sex", "Armpits", "Ashikoki", "Asphyxiation", "Bondage", "Boobjob", "Cervix Penetration",
    "Cheating", "Cumflation", "Cunnilingus", "Deepthroat", "Defloration", "DILF", "Double Penetration",
    "Erotic Piercings", "Facial", "Feet", "Fellatio", "Femdom", "Fisting", "Flat Chest", "Futanari", "Group Sex",
    "Hair Pulling", "Handjob", "Hypersexuality", "Inseki", "Irrumatio", "Lactation", "Large Breasts",
    "Male Pregnancy", "Masochism", "Masturbation", "Mating Press", "MILF", "Nakadashi", "Netorare", "Netorase",
    "Netori", "Pet Play", "Prostitution", "Public Sex", "Rimjob", "Scat", "Scissoring", "Sex Toys", "Shimaidon",
    "Squirting", "Sumata", "Tentacles", "Threesome", "Virginity", "Vore", "Voyeur", "Zoophilia"
  ]
}

enum AnimeHelpers {
  private static let streamingEpisodeRegex = try? NSRegularExpression(pattern: "Episode (\\d+(\\.\\d+)?) - ")
  private static let episodeTitleRegex = try? NSRegularExpression(pattern: "Episode (\\d+) - (.*)")
  private static let episodeZeroRegex = try? NSRegularExpression(pattern: "episode\\s*0", options: [.caseInsensitive])

  /// Number of "Episode N - Title" streaming episodes (N parsed as a double).
  static func streamingEpisodeNumber(_ title: String?) -> Double? {
    guard let title, let regex = streamingEpisodeRegex else { return nil }
    let range = NSRange(title.startIndex..<title.endIndex, in: title)
    guard let match = regex.firstMatch(in: title, range: range), let numberRange = Range(match.range(at: 1), in: title) else { return nil }
    return Double(title[numberRange])
  }

  /// /Episode (\d+) - (.*)/ of EpisodeList.svelte: (episode number, title).
  static func streamingEpisodeTitle(_ title: String?) -> (number: Int, title: String)? {
    guard let title, let regex = episodeTitleRegex else { return nil }
    let range = NSRange(title.startIndex..<title.endIndex, in: title)
    guard let match = regex.firstMatch(in: title, range: range),
          let numberRange = Range(match.range(at: 1), in: title),
          let titleRange = Range(match.range(at: 2), in: title),
          let number = Int(title[numberRange]) else { return nil }
    return (number, String(title[titleRange]))
  }

  static func isEpisodeZeroTitle(_ title: String?) -> Bool {
    guard let title, let regex = episodeZeroRegex else { return false }
    return regex.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)) != nil
  }

  /// nextAiring: first node airing after now.
  static func nextAiring(_ nodes: [AiringNode], now: Date = Date()) -> AiringNode? {
    nodes.filter { $0.airingAt > now }.min { $0.airingAt < $1.airingAt }
  }

  /// lastAired: latest node that already aired (highest episode on ties).
  static func lastAired(_ nodes: [AiringNode], now: Date = Date()) -> AiringNode? {
    nodes.filter { $0.airingAt < now }.sorted { lhs, rhs in
      if lhs.airingAt != rhs.airingAt { return lhs.airingAt > rhs.airingAt }
      return lhs.episode > rhs.episode
    }.first
  }

  /// getMediaMaxEp. `playable` returns the last playable episode instead of the total count.
  static func maxEpisode(_ media: Media, playable: Bool = false, extras: MediaExtras? = nil) -> Int {
    let info = extras ?? MediaStore.shared.extras(for: media)
    let nodes = info.airingSchedule
    let progress = media.listEntry?.progress
    if playable {
      let now = Date()
      // A stored nextAiring whose time has passed already aired (the media was cached before): it is playable,
      // instead of capping the playable episode one below it.
      if let next = media.nextAiring, next.airingAt > now, next.episode - 1 > 0 { return next.episode - 1 }
      let pastNext = media.nextAiring.map { $0.airingAt <= now ? $0.episode : 0 } ?? 0
      let aired = max(lastAired(nodes, now: now)?.episode ?? 0, pastNext)
      if aired > 0 { return aired }
      if media.status != .notYetReleased, let episodes = media.episodes, episodes > 0 { return episodes }
      return media.status == .releasing ? (progress ?? 1) : 0
    }
    let lastNode = nodes.last?.episode ?? 0
    var streamingCount = 0
    if !info.streamingEpisodes.isEmpty && !(media.status == .finished && (media.episodes ?? 0) > 0) {
      streamingCount = info.streamingEpisodes.filter { episode in
        guard let number = streamingEpisodeNumber(episode.title) else { return false }
        return number.rounded() == number
      }.count
    }
    let value = max(lastNode, nodes.count, streamingCount, media.episodes ?? 0, media.nextAiring?.episode ?? 0)
    if value > 0 { return value }
    return media.status == .releasing ? (progress ?? 1) : 0
  }

  /// PROGRESS_DESC sort value (closest to completion first, unstarted last).
  static func progressSortValue(_ media: Media) -> Double {
    let progress = media.listEntry?.progress ?? 0
    let total = media.episodes ?? maxEpisode(media)
    if progress == 0 { return Double.infinity }
    if total == 0 { return -Double(progress) }
    let distance = total - progress
    return distance <= 0 ? -Double.infinity : Double(distance)
  }

  /// episode(media) label of anime.js, e.g. "Episode 5" or "Episode 5 ~ 7".
  static func airingEpisodeLabel(_ nodes: [AiringNode], now: Date = Date()) -> String {
    if nodes.isEmpty { return "Episode 1" }
    if nodes.count == 1 { return "Episode \(nodes[0].episode)" }
    guard let first = nextAiring(nodes, now: now) else { return "Episode \(nodes[0].episode)" }
    let sameTime = nodes.filter { $0.airingAt == first.airingAt }.map { $0.episode }
    let last = sameTime.max() ?? first.episode
    return first.episode == last ? "Episode \(first.episode)" : "Episode \(first.episode) ~ \(last)"
  }

  /// getAiringInfo(airingAt(media)): ("2d 3h 4m", "Episode 5 in") or nil when nothing is scheduled.
  static func airingInfo(_ media: Media, nodes overrideNodes: [AiringNode]? = nil, delayedIndefinitely: Bool = false) -> (time: String, episode: String)? {
    let nodes = overrideNodes ?? MediaStore.shared.extras(for: media).airingSchedule
    let label = airingEpisodeLabel(nodes)
    if delayedIndefinitely { return ("Suspended", label + " is") }
    guard let next = nextAiring(nodes) else { return nil }
    let seconds = next.airingAt.timeIntervalSinceNow
    return (ServiceText.countdown(seconds), label + (seconds <= 0 ? " out for" : " in"))
  }

  /// episodeByAirDate: metadata closest to an air date, or the episode itself when there is no date.
  static func episodeByAirDate(_ date: Date?, episodes: [String: AniZipEpisode], episode: Int) -> AniZipEpisode? {
    guard let date else { return episodes[String(episode)] ?? episodes["1"] }
    var closest: [AniZipEpisode] = []
    var closestDistance = Double.infinity
    for value in episodes.values {
      guard let air = ServiceDates.parse(value.airdate ?? value.airDate) else { continue }
      let distance = abs(air.timeIntervalSince(date))
      if distance == closestDistance {
        closest.append(value)
      } else if distance < closestDistance {
        closest = [value]
        closestDistance = distance
      }
    }
    return closest.min { abs(($0.episodeNumber ?? 0) - episode) < abs(($1.episodeNumber ?? 0) - episode) }
  }

  /// hasZeroEpisode: detects a zero episode (prologue) from streaming episodes or ani.zip specials.
  static func hasZeroEpisode(_ media: Media, mappings existing: AniZipMappings? = nil) async -> ZeroEpisodeInfo? {
    guard media.source == .anilist, let anilistId = media.anilistId else { return nil }
    let mappings: AniZipMappings?
    if let existing {
      mappings = existing
    } else {
      mappings = await AnimeMappingsService.shared.aniZip(anilistId: anilistId)
    }
    let extras = MediaStore.shared.extras(for: media)
    let zeroStreaming = extras.streamingEpisodes.filter { episode in
      guard let number = streamingEpisodeNumber(episode.title) else { return false }
      return number.rounded() == number && number == 0
    }
    let firstEpisode = mappings?.episodes["1"]
    let zeroAsFirstEpisode = isEpisodeZeroTitle(firstEpisode?.title["en"] ?? firstEpisode?.title["jp"])
    if let zero = zeroStreaming.first, ((media.episodes ?? 0) >= extras.streamingEpisodes.count || zeroAsFirstEpisode) {
      let title = zero.title?.replacingOccurrences(of: "Episode 0 - ", with: "")
      var prequel: Media?
      if let title, title.count > 4, let edge = extras.relationEdges.first(where: { $0.relationType == "PREQUEL" && $0.format == "SPECIAL" }) {
        if let stored = MediaStore.shared.anilist(edge.id) {
          prequel = stored
        } else {
          prequel = try? await AniListService.shared.media(id: edge.id)
        }
      }
      let lowered = (title ?? "").lowercased()
      let prequelMatches: Bool = prequel?.title.all.contains(where: { $0.lowercased().contains(lowered) }) ?? false
      if prequel == nil || !prequelMatches {
        return ZeroEpisodeInfo(title: title, thumbnail: zero.thumbnail, length: nil, summary: nil, airingAt: nil)
      }
    }
    if let mappings, !((media.episodes ?? 0) > 0 && media.episodes == mappings.episodeCount && media.status == .finished) {
      let special = mappings.episodes["S0"] ?? mappings.episodes["s0"] ?? mappings.episodes["S1"] ?? mappings.episodes["s1"]
      if (mappings.specialCount ?? 0) > 0, let special, (special.airedBeforeEpisodeNumber ?? 0) > 0 {
        return ZeroEpisodeInfo(title: special.title["en"], thumbnail: URL.lenient(special.image), length: special.length, summary: special.summary, airingAt: ServiceDates.parse(special.airDateUtc))
      }
    }
    return nil
  }

  // MARK: - trace.moe (traceAnime)

  /// Looks up the anime of a screenshot by URL.
  static func traceAnime(imageURL: URL) async throws -> [TraceMoeMatch] {
    guard let encoded = imageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://api.trace.moe/search?cutBorders&url=\(encoded)") else { throw ServiceError.invalidResponse }
    let (data, _) = try await HTTP.data(url, timeout: 60)
    return try await resolveTrace(data)
  }

  /// Looks up the anime of a screenshot (image bytes).
  static func traceAnime(imageData: Data, mimeType: String = "image/jpeg") async throws -> [TraceMoeMatch] {
    guard let url = URL(string: "https://api.trace.moe/search") else { throw ServiceError.invalidResponse }
    let (data, _) = try await HTTP.data(url, method: "POST", headers: ["Content-Type": mimeType], body: imageData, timeout: 60)
    return try await resolveTrace(data)
  }

  private static func resolveTrace(_ data: Data) async throws -> [TraceMoeMatch] {
    let results = ServiceJSON.object(data)?.array("result") ?? []
    let ids = results.compactMap { $0.int("anilist") ?? $0.dict("anilist")?.int("id") }
    guard !ids.isEmpty else {
      throw ServiceError.api("Couldn't find anime for specified image! Try to remove black bars, or use a more detailed image.")
    }
    var variables = AniListVariables()
    variables.sort = nil
    variables.id = ids
    let media = try await AniListService.shared.searchAllIDs(variables)
    var matches: [TraceMoeMatch] = []
    for item in media {
      guard let result = results.first(where: { ($0.int("anilist") ?? $0.dict("anilist")?.int("id")) == item.anilistId }) else { continue }
      let episode = result.int("episode")
      var match = TraceMoeMatch(media: item, episode: episode, similarity: result.double("similarity") ?? 0, image: URL.lenient(result.string("image")), video: URL.lenient(result.string("video")))
      if let episode {
        let metadata = await AnimeMappingsService.shared.episodeMetadata(for: item)
        match.episodeTitle = metadata[String(episode)]?.title["en"]
        match.thumbnail = URL.lenient(metadata[String(episode)]?.image)
      }
      matches.append(match)
    }
    return matches.sorted { $0.similarity > $1.similarity }
  }

  // MARK: - AniSkip (getChaptersAniSkip)

  static func aniSkipChapters(malId: Int, episode: Int, duration: Double) async -> [SkipChapter] {
    let base = "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)/?types=op&types=ed&types=recap&episodeLength="
    guard let accurateURL = URL(string: base + String(Int(duration))), let roughURL = URL(string: base + "0") else { return [] }
    let accurate = (try? await HTTP.jsonObject(from: accurateURL)) as? [String: Any]
    let rough = (try? await HTTP.jsonObject(from: roughURL)) as? [String: Any]
    if accurate?.int("statusCode") == 500 || rough?.int("statusCode") == 500 { return [] }
    var byType: [String: [String: Any]] = [:]
    var order: [String] = []
    for result in (accurate?.array("results") ?? []) + (rough?.array("results") ?? []) {
      guard let type = result.string("skipType"), byType[type] == nil else { continue }
      byType[type] = result
      order.append(type)
    }
    let results = order.compactMap { byType[$0] }
    if results.isEmpty { return [] }
    return constructChapters(results, duration: duration)
  }

  private static func constructChapters(_ results: [[String: Any]], duration: Double) -> [SkipChapter] {
    var chapters: [SkipChapter] = results.compactMap { result in
      guard let interval = result.dict("interval"), let start = interval.double("startTime"), let end = interval.double("endTime") else { return nil }
      let diff = duration - (result.double("episodeLength") ?? duration)
      var text = (result.string("skipType") ?? "").uppercased()
      if text == "RECAP" { text = "Recap" }
      return SkipChapter(start: (start + diff) * 1000, end: (end + diff) * 1000, text: text)
    }
    guard let first = chapters.first else { return [] }
    let total = duration * 1000
    let ending = chapters.first { $0.text == "ED" }
    if Int(first.start) != 0 {
      chapters.insert(SkipChapter(start: 0, end: first.start, text: first.text == "OP" ? "Intro" : "Episode"), at: 0)
    }
    if let ending {
      if Int(ending.end) + 5000 - Int(total) < 0 { chapters.append(SkipChapter(start: ending.end, end: total, text: "Preview")) }
    } else if let last = chapters.last, Int(last.end) + 5000 - Int(total) < 0 {
      chapters.append(SkipChapter(start: last.end, end: total, text: "Episode"))
    }
    chapters.sort { $0.start < $1.start }
    var filled = chapters
    if chapters.count > 1 {
      for index in 0..<(chapters.count - 1) where Int(chapters[index].end) != Int(chapters[index + 1].start) {
        filled.append(SkipChapter(start: chapters[index].end, end: chapters[index + 1].start, text: "Episode"))
      }
    }
    return filled.sorted { $0.start < $1.start }
  }
}
