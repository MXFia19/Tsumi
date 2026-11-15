import Foundation
import ActivityKit

/// Live Activity counting down to the next episode of a title (lock screen + Dynamic Island).
/// Started by the app (details "Countdown on Lock Screen", or automatically for followed titles airing soon);
/// rendered by the widget extension (TsumiWidgets/CountdownLiveActivity.swift).
struct TsumiCountdownAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var episode: Int
    var airingAt: Date
    /// The episode aired (the activity then ends and is dismissed a while later).
    var isOut: Bool
  }

  /// Media key ("al-<id>", "mal-<id>", "tmdb-tv-<id>").
  var mediaId: String
  var title: String
  var totalEpisodes: Int?
  /// Cover thumbnail file name in the shared container (nil when there is none).
  var cover: String?
  /// Cover colour "#rrggbb".
  var color: String?
  /// tsumi:// link opened by a tap.
  var link: URL?
  /// Started by the "start automatically" setting (not by the user).
  var autoStarted: Bool
}
