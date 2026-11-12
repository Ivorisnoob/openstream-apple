import Foundation

/// What a source needs to find one film or one episode.
public struct MediaIdentity: Hashable, Sendable, Codable {
    public var ref: TitleRef
    public var imdbID: String?
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var season: Int
    public var episode: Int

    public init(ref: TitleRef, imdbID: String?, title: String, originalTitle: String? = nil,
                year: Int?, season: Int = 1, episode: Int = 1) {
        self.ref = ref
        self.imdbID = imdbID
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.season = season
        self.episode = episode
    }

    /// "movie:27205" or "tv:1396:1:3".
    public var key: String {
        ref.kind == .movie ? ref.description : "\(ref):\(season):\(episode)"
    }
}

public enum StreamQuality: Int, Comparable, Codable, Sendable, CaseIterable {
    case unknown = 0, q360, q480, q720, q1080, q1440, q2160

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .unknown: "Auto"
        case .q360: "360p"
        case .q480: "480p"
        case .q720: "720p"
        case .q1080: "1080p"
        case .q1440: "1440p"
        case .q2160: "4K"
        }
    }

    /// An explicit height ("1080p") wins over words like "4K" that sources also use in their own
    /// names ("4KHDHub 1080p" is a 1080p stream).
    public static func parse(_ text: String?) -> StreamQuality {
        guard let text = text?.lowercased(), !text.isEmpty else { return .unknown }
        if let match = text.firstMatch(of: /(?:^|\D)(2160|1440|1080|720|480|360)p?(?:\D|$)/) {
            switch match.1 {
            case "2160": return .q2160
            case "1440": return .q1440
            case "1080": return .q1080
            case "720": return .q720
            case "480": return .q480
            default: return .q360
            }
        }
        if text.contains(/\b(4k|uhd)\b/) { return .q2160 }
        if text == "hd" || text.contains("full hd") || text.contains("fhd") { return .q1080 }
        return .unknown
    }
}

public enum StreamAudio: String, Codable, Sendable {
    case original, dub, multi, unknown

    public static func parse(_ text: String?) -> StreamAudio {
        let text = text?.lowercased() ?? ""
        if text.contains("multi") || text.contains("dual") { return .multi }
        if text.contains("dub") || text.contains("english") || text.contains("hindi") || text.contains("german") {
            return .dub
        }
        if text.contains("sub") { return .original }
        return .unknown
    }
}

public struct StreamSubtitle: Hashable, Sendable, Codable {
    public var url: URL
    public var label: String
    public var language: String?
}

/// One playable stream from one source.
public struct StreamSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var providerID: String
    public var providerName: String
    /// What the source calls this stream ("Yoru", "4KHDHub 1080p WEB-DL 2.1 GB").
    public var name: String
    public var url: URL
    public var quality: StreamQuality
    public var audio: StreamAudio
    public var audioLanguage: String?
    /// Sent with the playlist and every segment: some hosts refuse requests without them.
    public var headers: [String: String]
    public var subtitles: [StreamSubtitle]
    /// When the URL doesn't say (no ".m3u8"), the source does.
    public var isHLSHint: Bool
    /// The file's extension when the source names the file but the link doesn't ("mkv").
    public var fileExtension: String?

    public init(id: String, providerID: String, providerName: String, name: String, url: URL,
                quality: StreamQuality = .unknown, audio: StreamAudio = .unknown, audioLanguage: String? = nil,
                headers: [String: String] = [:], subtitles: [StreamSubtitle] = [], isHLSHint: Bool = false,
                fileExtension: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.name = name
        self.url = url
        self.quality = quality
        self.audio = audio
        self.audioLanguage = audioLanguage
        self.headers = headers
        self.subtitles = subtitles
        self.isHLSHint = isHLSHint
        self.fileExtension = fileExtension?.lowercased()
    }

    public var isHLS: Bool { isHLSHint || url.path.lowercased().hasSuffix(".m3u8") }

    /// "HLS", "MP4", "MKV": AVFoundation plays the first two; the rest are offered but may fail.
    public var container: String {
        if isHLS { return "HLS" }
        return knownExtension?.uppercased() ?? "File"
    }

    private var knownExtension: String? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        return fileExtension
    }

    /// AVFoundation can't open Matroska, AVI or DASH; such streams are listed last and never
    /// picked automatically.
    public var isLikelyPlayable: Bool {
        !["mkv", "avi", "mpd", "webm", "ts"].contains(knownExtension ?? "")
    }

    /// How sure AVFoundation is to open it: HLS, then MP4-family files, then links that don't say.
    public var playabilityRank: Int {
        if isHLS { return 2 }
        if ["mp4", "m4v", "mov"].contains(knownExtension ?? "") { return 2 }
        return isLikelyPlayable ? 1 : 0
    }
}

/// A source the viewer can turn on: one entry of a catalog.
public protocol StreamProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Asked only when the direct sources find nothing.
    var isFallback: Bool { get }
    func resolve(_ identity: MediaIdentity) async throws -> [StreamSource]
}

public enum ProviderError: LocalizedError, Sendable {
    case http(Int)
    case unreadable
    case unsupported
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Answered with an error (\(code))"
        case .unreadable: "Sent something unreadable"
        case .unsupported: "Can't be used here"
        case .unavailable: "Isn't answering right now"
        case .timedOut: "Took too long"
        }
    }
}
