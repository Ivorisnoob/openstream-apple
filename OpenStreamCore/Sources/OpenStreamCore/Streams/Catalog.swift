import Foundation

/// A source catalog: the JSON OpenStream publishes (`extensions/index.json`), shared with
/// OpenStream for Android so one list serves both. The app ships a copy and refreshes it from
/// GitHub; a source is added or retired by editing the file, not by a new app release.
public struct Catalog: Codable, Sendable, Hashable {
    public var name: String
    public var extensions: [Entry]

    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var description: String?
        public var versionCode: Int?
        public var language: String?
        public var tags: [String]?
        public var installedByDefault: Bool?
        public var fallback: Bool?
        public var engine: Engine

        /// The kind of source this is, in words a viewer understands.
        public var kindLabel: String {
            switch engine.type {
            case "vidking-direct": "Direct"
            case "stremio": "Stremio add-on"
            case "web-embed", "vidking-webview": "Web player"
            case "anikoto", "reanime", "animepahe", "fouranimo", "animegg": "Anime"
            default: engine.type
            }
        }

        public var isAnime: Bool { kindLabel == "Anime" }
    }

    public struct Engine: Codable, Sendable, Hashable {
        public var type: String
        public var endpoint: String?
        public var priority: Int?
        public var language: String?
        public var qualityFilter: String?
        public var movieUrl: String?
        public var tvUrl: String?
    }

    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/Ivorisnoob/OpenStream/main/extensions/index.json")!

    public static var bundled: Catalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return Catalog(name: "OpenStream", extensions: []) }
        return catalog
    }

    /// The bundled list with any newer entries from `other` (by `versionCode`), keeping the order.
    public func merged(with other: Catalog) -> Catalog {
        var byID = Dictionary(extensions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order = extensions.map(\.id)
        for entry in other.extensions {
            if let current = byID[entry.id] {
                if (entry.versionCode ?? 0) >= (current.versionCode ?? 0) { byID[entry.id] = entry }
            } else {
                byID[entry.id] = entry
                order.append(entry.id)
            }
        }
        return Catalog(name: name, extensions: order.compactMap { byID[$0] })
    }
}

extension Catalog.Entry {
    /// Engines this version can run. The anime sites' own engines come later.
    public var isSupported: Bool {
        ["vidking-direct", "stremio", "web-embed", "vidking-webview", "reanime", "anikoto"].contains(engine.type)
    }

    public func provider(sniffer: any WebPlayerSniffing) -> (any StreamProvider)? {
        switch engine.type {
        case "vidking-direct":
            guard let endpoint = engine.endpoint else { return nil }
            return VidkingProvider(id: id, name: name, endpoint: endpoint, language: engine.language,
                                   qualityFilter: engine.qualityFilter)
        case "stremio":
            guard let endpoint = engine.endpoint.flatMap(URL.init(string:)) else { return nil }
            return StremioProvider(id: id, name: name, endpoint: endpoint, isFallback: fallback ?? false)
        case "web-embed":
            return WebPlayerProvider(id: id, name: name, movieTemplate: engine.movieUrl, tvTemplate: engine.tvUrl,
                                     isFallback: true, sniffer: sniffer)
        case "reanime", "anikoto":
            guard let endpoint = engine.endpoint, let site = AnimeSiteProvider.Site(rawValue: engine.type) else { return nil }
            return AnimeSiteProvider(id: id, name: name, site: site, baseURL: endpoint)
        case "vidking-webview":
            return WebPlayerProvider(id: id, name: name,
                                     movieTemplate: "https://www.vidking.net/embed/movie/{tmdbId}?autoPlay=true",
                                     tvTemplate: "https://www.vidking.net/embed/tv/{tmdbId}/{season}/{episode}?autoPlay=true",
                                     isFallback: true, sniffer: sniffer)
        default:
            return nil
        }
    }
}
