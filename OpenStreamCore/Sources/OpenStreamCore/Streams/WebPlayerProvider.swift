import Foundation

/// Something that loads a web player out of sight and reports the streams it starts. The app
/// provides it (it needs WebKit and a window); the core only says which page to open.
public protocol WebPlayerSniffing: Sendable {
    func streams(at page: URL, timeout: Duration) async -> [SniffedStream]
}

public struct SniffedStream: Sendable, Hashable {
    public var url: URL
    /// The page or frame that asked for it, which the host expects as Referer and Origin.
    public var frame: URL?
    public var qualityHint: String?

    public init(url: URL, frame: URL?, qualityHint: String?) {
        self.url = url
        self.frame = frame
        self.qualityHint = qualityHint
    }
}

/// A web player for a TMDB id: its page is opened unseen and the stream it requests is played
/// natively. URL templates take `{tmdbId}`, `{imdbId}`, `{season}` and `{episode}`.
public struct WebPlayerProvider: StreamProvider {
    public let id: String
    public let name: String
    public let isFallback: Bool
    let movieTemplate: String?
    let tvTemplate: String?
    let sniffer: any WebPlayerSniffing

    public init(id: String, name: String, movieTemplate: String?, tvTemplate: String?, isFallback: Bool,
                sniffer: any WebPlayerSniffing) {
        self.id = id
        self.name = name
        self.movieTemplate = movieTemplate
        self.tvTemplate = tvTemplate
        self.isFallback = isFallback
        self.sniffer = sniffer
    }

    public func pageURL(for identity: MediaIdentity) -> URL? {
        guard let template = identity.ref.kind == .movie ? movieTemplate : tvTemplate,
              template.hasPrefix("https://")
        else { return nil }
        if template.contains("{imdbId}"), identity.imdbID == nil { return nil }
        let text = template
            .replacingOccurrences(of: "{tmdbId}", with: String(identity.ref.id))
            .replacingOccurrences(of: "{imdbId}", with: identity.imdbID ?? "")
            .replacingOccurrences(of: "{season}", with: String(identity.season))
            .replacingOccurrences(of: "{episode}", with: String(identity.episode))
        return URL(string: text)
    }

    public func resolve(_ identity: MediaIdentity) async throws -> [StreamSource] {
        guard let page = pageURL(for: identity) else { return [] }
        let found = await sniffer.streams(at: page, timeout: .seconds(13))
        return found.map { stream in
            let referrer = stream.frame ?? page
            let origin = "\(referrer.scheme ?? "https")://\(referrer.host() ?? "")"
            return StreamSource(
                id: "\(id)-\(stableHash(stream.url.absoluteString))",
                providerID: id,
                providerName: name,
                name: name,
                url: stream.url,
                quality: StreamQuality.parse(stream.qualityHint ?? stream.url.absoluteString),
                audio: StreamAudio.parse(stream.qualityHint),
                headers: ["User-Agent": SourceHTTP.userAgent, "Referer": origin + "/", "Origin": origin]
            )
        }
    }
}
