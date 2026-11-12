import Foundation

/// A Stremio add-on, spoken over its public HTTP protocol: `{base}/manifest.json` says which
/// kinds and id schemes it serves, `{base}/stream/{movie|series}/{id}.json` lists streams, where
/// `id` is an IMDb id (`tt0903747:1:1` for an episode) or, when the add-on takes them, `tmdb:` ids.
///
/// Only streams with a direct `url` can play. Torrents, YouTube and external links are left out:
/// there is no torrent engine or debrid account behind them.
public struct StremioProvider: StreamProvider {
    public let id: String
    public let name: String
    public let isFallback: Bool
    let baseURL: URL
    let manifest: ManifestCache

    public init(id: String, name: String, endpoint: URL, isFallback: Bool = false) {
        self.id = id
        self.name = name
        self.isFallback = isFallback
        // Configured add-ons keep their settings in the path, so the endpoint is used as given.
        let text = endpoint.absoluteString.replacingOccurrences(of: "/manifest.json", with: "")
        baseURL = URL(string: text.hasSuffix("/") ? String(text.dropLast()) : text) ?? endpoint
        manifest = ManifestCache()
    }

    static let maxStreams = 30

    public func resolve(_ identity: MediaIdentity) async throws -> [StreamSource] {
        let info = await manifest.info(for: baseURL)
        let type = identity.ref.kind == .movie ? "movie" : "series"
        if !info.types.isEmpty, !info.types.contains(type) { return [] }
        for videoID in candidateIDs(identity, info: info) {
            let url = baseURL.appending(path: "stream/\(type)/\(videoID).json")
            guard let data = try await SourceHTTP.get(url, headers: ["Accept": "application/json"]) else { continue }
            let releases = Self.parse(data, providerID: id, providerName: name, title: identity.title)
            let playable = await Self.firstPlayableMirrors(Array(releases.prefix(Self.maxStreams)))
            if !playable.isEmpty { return playable }
        }
        return []
    }

    /// The add-on's preferred id scheme first; the next only when the first finds nothing.
    func candidateIDs(_ identity: MediaIdentity, info: ManifestInfo) -> [String] {
        let suffix = identity.ref.kind == .movie ? "" : ":\(identity.season):\(identity.episode)"
        let takesIMDb = info.idPrefixes.map { $0.contains { $0.hasPrefix("tt") || $0 == "imdb" } } ?? true
        let takesTMDB = info.idPrefixes?.contains { $0.hasPrefix("tmdb") } ?? false
        var ids: [String] = []
        if let imdb = identity.imdbID, imdb.hasPrefix("tt"), takesIMDb { ids.append(imdb + suffix) }
        if takesTMDB { ids.append("tmdb:\(identity.ref.id)\(suffix)") }
        return ids
    }

    /// Streams grouped by release: add-ons list one release once per file host.
    static func parse(_ data: Data, providerID: String, providerName: String, title: String) -> [[StreamSource]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]]
        else { return [] }
        var order: [String] = []
        var releases: [String: [StreamSource]] = [:]
        for stream in streams {
            guard let text = (stream["url"] as? String)?.trimmingCharacters(in: .whitespaces),
                  text.hasPrefix("http"), let url = URL(string: text)
            else { continue }
            let hints = stream["behaviorHints"] as? [String: Any]
            let filename = hints?["filename"] as? String
            let nameLines = lines(stream["name"] as? String)
            let detailLines = lines((stream["title"] as? String) ?? (stream["description"] as? String))
            let everything = (nameLines + detailLines + [filename ?? ""]).joined(separator: " ")
            let release = detailLines.first ?? filename ?? nameLines.first ?? providerName
            let key = release.count > 1 ? release : url.absoluteString
            let headers = ((hints?["proxyHeaders"] as? [String: Any])?["request"] as? [String: String]) ?? [:]
            let subtitles = (stream["subtitles"] as? [[String: Any]] ?? []).compactMap { item -> StreamSubtitle? in
                guard let link = item["url"] as? String, link.hasPrefix("http"), let url = URL(string: link) else { return nil }
                let language = item["lang"] as? String
                return StreamSubtitle(url: url, label: Locale.current.localizedString(forLanguageCode: language ?? "") ?? language ?? "Subtitles",
                                      language: language)
            }
            let source = StreamSource(
                id: "\(providerID)-\(stableHash(key + url.absoluteString))",
                providerID: providerID,
                providerName: providerName,
                name: String(release.prefix(110)),
                url: url,
                quality: StreamQuality.parse(everything),
                audio: StreamAudio.parse(everything),
                headers: ["User-Agent": SourceHTTP.userAgent].merging(headers) { _, new in new },
                subtitles: subtitles,
                fileExtension: (filename ?? detailLines.joined(separator: " "))
                    .firstMatch(of: /\.(mkv|mp4|avi|m4v|mov|webm|ts)\b/.ignoresCase()).map { String($0.1) }
            )
            if releases[key] == nil { order.append(key) }
            releases[key, default: []].append(source)
        }
        return order.compactMap { releases[$0] }
    }

    /// For each release, the first mirror that answers like a video, checked in parallel within
    /// eight seconds; releases that haven't answered by then are left out.
    static func firstPlayableMirrors(_ releases: [[StreamSource]]) async -> [StreamSource] {
        await withTaskGroup(of: (Int, StreamSource?).self) { group in
            for (index, mirrors) in releases.enumerated() {
                group.addTask {
                    for mirror in mirrors where await SourceHTTP.looksPlayable(mirror) { return (index, mirror) }
                    return (index, nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return (-1, nil)
            }
            var found: [Int: StreamSource] = [:]
            var answered = 0
            for await (index, source) in group {
                if index == -1 { group.cancelAll(); break }
                if let source { found[index] = source }
                answered += 1
                if answered == releases.count { group.cancelAll(); break }
            }
            return found.sorted { $0.key < $1.key }.map(\.value)
        }
    }

    static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { clean(String($0)) }.filter { !$0.isEmpty }
    }

    /// Add-ons decorate their labels with emoji; the app's lists are plain text.
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !$0.properties.isEmojiPresentation && !($0.properties.isEmoji && $0.value > 0x2000) }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A short stable id from text (Swift's `hashValue` changes every launch).
func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(hash, radix: 36)
}

struct ManifestInfo: Sendable {
    var types: Set<String>
    /// Nil when the add-on doesn't say: then IMDb ids are assumed, as in Stremio itself.
    var idPrefixes: [String]?
}

/// Read once per run; add-ons rarely change what they serve.
actor ManifestCache {
    private var info: ManifestInfo?

    func info(for baseURL: URL) async -> ManifestInfo {
        if let info { return info }
        let loaded = await Self.load(baseURL)
        info = loaded
        return loaded
    }

    private static func load(_ baseURL: URL) async -> ManifestInfo {
        guard let data = try? await SourceHTTP.get(baseURL.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ManifestInfo(types: [], idPrefixes: nil) }
        // A "stream" resource given as an object may narrow the types and prefixes for itself.
        let resource = (manifest["resources"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .first { $0["name"] as? String == "stream" }
        let types = (resource?["types"] ?? manifest["types"]) as? [String] ?? []
        let prefixes = (resource?["idPrefixes"] ?? manifest["idPrefixes"]) as? [String]
        return ManifestInfo(types: Set(types), idPrefixes: prefixes?.isEmpty == false ? prefixes : nil)
    }
}
