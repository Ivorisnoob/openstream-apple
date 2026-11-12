import Foundation
import Observation
import OpenStreamCore
import SwiftUI

/// The viewer's preferences, kept in UserDefaults under `openstream.*`. Each one is read where it
/// matters (the player, the browse pages, the subtitle overlay), so changing it takes effect at once.
@Observable
final class AppSettings {
    // MARK: General

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var name: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var appearance: Appearance { didSet { save(appearance.rawValue, Keys.appearance) } }
    /// Where a new window opens.
    var startPage: StartPage { didSet { save(startPage.rawValue, Keys.startPage) } }
    /// The featured carousel moves on by itself (it never does with Reduce Motion on).
    var heroAdvances: Bool { didSet { save(heroAdvances, Keys.heroAdvances) } }
    var showsContinueOnHome: Bool { didSet { save(showsContinueOnHome, Keys.continueOnHome) } }

    enum StartPage: String, CaseIterable, Identifiable {
        case home, movies, shows, anime, watchlist
        var id: Self { self }
        var item: SidebarItem {
            switch self {
            case .home: .home
            case .movies: .movies
            case .shows: .shows
            case .anime: .anime
            case .watchlist: .watchlist
            }
        }
        var name: String { item.name }
    }

    // MARK: Playback

    /// The player picks the first good stream itself; off, it waits for the viewer to choose.
    var startsAutomatically: Bool { didSet { save(startsAutomatically, Keys.autoStart) } }
    /// Pick up where the viewer left off; off, everything starts from the beginning.
    var resumesPlayback: Bool { didSet { save(resumesPlayback, Keys.resume) } }
    /// The next episode starts by itself when one ends.
    var autoplaysNextEpisode: Bool { didSet { save(autoplaysNextEpisode, Keys.autoplay) } }
    var nextEpisodeCountdown: Int { didSet { save(nextEpisodeCountdown, Keys.countdown) } }
    /// 0 = as good as the stream and connection allow.
    var maxQuality: Int { didSet { save(maxQuality, Keys.maxQuality) } }
    var audioPreference: AudioPreference { didSet { save(audioPreference.rawValue, Keys.audio) } }

    enum AudioPreference: String, CaseIterable, Identifiable {
        case any, original, dubbed
        var id: Self { self }
        var name: String {
            switch self {
            case .any: "No Preference"
            case .original: "Original Language"
            case .dubbed: "Dubbed"
            }
        }
        var streamAudio: StreamAudio? {
            switch self {
            case .any: nil
            case .original: .original
            case .dubbed: .dub
            }
        }
    }

    static let qualities = [0, 2160, 1080, 720, 480]

    var streamQualityCap: StreamQuality? {
        switch maxQuality {
        case 2160: .q2160
        case 1080: .q1080
        case 720: .q720
        case 480: .q480
        default: nil
        }
    }

    // MARK: Subtitles

    /// The language subtitles turn on in ("en"), or nil when they're off.
    var subtitleLanguage: String? { didSet { save(subtitleLanguage, Keys.subtitles) } }
    var prefersSDH: Bool { didSet { save(prefersSDH, Keys.sdh) } }
    var subtitleSize: SubtitleSize { didSet { save(subtitleSize.rawValue, Keys.subtitleSize) } }
    var subtitleColor: SubtitleColor { didSet { save(subtitleColor.rawValue, Keys.subtitleColor) } }
    var subtitleBackground: SubtitleBackground { didSet { save(subtitleBackground.rawValue, Keys.subtitleBackground) } }

    enum SubtitleSize: String, CaseIterable, Identifiable {
        case small, medium, large, extraLarge
        var id: Self { self }
        var name: String { self == .extraLarge ? "Extra Large" : rawValue.capitalized }
        /// Of the picture's height.
        var fraction: CGFloat {
            switch self {
            case .small: 0.034
            case .medium: 0.042
            case .large: 0.052
            case .extraLarge: 0.064
            }
        }
    }

    enum SubtitleColor: String, CaseIterable, Identifiable {
        case white, yellow
        var id: Self { self }
        var name: String { rawValue.capitalized }
        var color: Color { self == .white ? .white : Color(red: 1, green: 0.92, blue: 0.3) }
    }

    enum SubtitleBackground: String, CaseIterable, Identifiable {
        case none, translucent, solid
        var id: Self { self }
        var name: String { rawValue.capitalized }
        var opacity: Double {
            switch self {
            case .none: 0
            case .translucent: 0.55
            case .solid: 0.9
            }
        }
    }

    // MARK: Storage

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "openstream.appearance"
        static let startPage = "openstream.startPage"
        static let heroAdvances = "openstream.home.heroAdvances"
        static let continueOnHome = "openstream.home.continueWatching"
        static let autoStart = "openstream.player.autoStart"
        static let resume = "openstream.player.resume"
        static let autoplay = "openstream.player.autoplayNext"
        static let countdown = "openstream.player.countdown"
        static let maxQuality = "openstream.player.maxQuality"
        static let audio = "openstream.player.audio"
        static let subtitles = "openstream.subtitles.language"
        static let sdh = "openstream.subtitles.sdh"
        static let subtitleSize = "openstream.subtitles.size"
        static let subtitleColor = "openstream.subtitles.color"
        static let subtitleBackground = "openstream.subtitles.background"
    }

    init() {
        defaults.register(defaults: [
            Keys.heroAdvances: true, Keys.continueOnHome: true, Keys.autoStart: true, Keys.resume: true,
            Keys.autoplay: true, Keys.countdown: 5,
        ])
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        startPage = StartPage(rawValue: defaults.string(forKey: Keys.startPage) ?? "") ?? .home
        heroAdvances = defaults.bool(forKey: Keys.heroAdvances)
        showsContinueOnHome = defaults.bool(forKey: Keys.continueOnHome)
        startsAutomatically = defaults.bool(forKey: Keys.autoStart)
        resumesPlayback = defaults.bool(forKey: Keys.resume)
        autoplaysNextEpisode = defaults.bool(forKey: Keys.autoplay)
        nextEpisodeCountdown = defaults.integer(forKey: Keys.countdown)
        maxQuality = defaults.integer(forKey: Keys.maxQuality)
        audioPreference = AudioPreference(rawValue: defaults.string(forKey: Keys.audio) ?? "") ?? .any
        subtitleLanguage = defaults.string(forKey: Keys.subtitles)
        prefersSDH = defaults.bool(forKey: Keys.sdh)
        subtitleSize = SubtitleSize(rawValue: defaults.string(forKey: Keys.subtitleSize) ?? "") ?? .medium
        subtitleColor = SubtitleColor(rawValue: defaults.string(forKey: Keys.subtitleColor) ?? "") ?? .white
        subtitleBackground = SubtitleBackground(rawValue: defaults.string(forKey: Keys.subtitleBackground) ?? "") ?? .translucent
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Everything back as it was when the app was new.
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("openstream.") && !key.hasPrefix("openstream.sources") {
            defaults.removeObject(forKey: key)
        }
        let fresh = AppSettings()
        appearance = fresh.appearance
        startPage = fresh.startPage
        heroAdvances = fresh.heroAdvances
        showsContinueOnHome = fresh.showsContinueOnHome
        startsAutomatically = fresh.startsAutomatically
        resumesPlayback = fresh.resumesPlayback
        autoplaysNextEpisode = fresh.autoplaysNextEpisode
        nextEpisodeCountdown = fresh.nextEpisodeCountdown
        maxQuality = fresh.maxQuality
        audioPreference = fresh.audioPreference
        subtitleLanguage = fresh.subtitleLanguage
        prefersSDH = fresh.prefersSDH
        subtitleSize = fresh.subtitleSize
        subtitleColor = fresh.subtitleColor
        subtitleBackground = fresh.subtitleBackground
    }
}
