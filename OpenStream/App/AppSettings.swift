import Foundation
import Observation

/// The viewer's preferences, kept in UserDefaults under `openstream.*`.
@Observable
final class AppSettings {
    /// The next episode starts by itself when one ends.
    var autoplaysNextEpisode: Bool {
        didSet { defaults.set(autoplaysNextEpisode, forKey: Keys.autoplay) }
    }

    /// The player picks the first good stream itself; off, it waits for the viewer to choose.
    var startsAutomatically: Bool {
        didSet { defaults.set(startsAutomatically, forKey: Keys.autoStart) }
    }

    /// The language subtitles were last shown in ("en"), or nil when they were turned off.
    var subtitleLanguage: String? {
        didSet { defaults.set(subtitleLanguage, forKey: Keys.subtitles) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoplay = "openstream.player.autoplayNext"
        static let autoStart = "openstream.player.autoStart"
        static let subtitles = "openstream.subtitles.language"
    }

    init() {
        defaults.register(defaults: [Keys.autoplay: true, Keys.autoStart: true])
        autoplaysNextEpisode = defaults.bool(forKey: Keys.autoplay)
        startsAutomatically = defaults.bool(forKey: Keys.autoStart)
        subtitleLanguage = defaults.string(forKey: Keys.subtitles)
    }
}
