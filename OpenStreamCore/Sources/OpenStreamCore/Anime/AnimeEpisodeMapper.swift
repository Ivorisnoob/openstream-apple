import Foundation

/// One AniList episode: what anime sites and AniSkip index by.
public struct AnimeEpisodeRef: Sendable, Hashable {
    public var anilistID: Int
    public var malID: Int?
    /// The episode's number within the AniList entry (1 for a film).
    public var episode: Int
    /// Search titles, best first (romaji, English).
    public var titles: [String]
    /// Episodes in the entry, when AniList knows.
    public var episodeCount: Int?
}

/// Maps a TMDB title, season and episode to the AniList entry and episode anime sites use.
///
/// TMDB keeps a show's seasons under one id while AniList gives every season (or cour) its own
/// entry. ani.zip (keyless) finds the franchise's first entry from the TMDB id, AniList's GraphQL
/// API (keyless, ~90 requests a minute) walks its sequels, and each entry's ani.zip episode list is
/// checked for the TMDB season and episode, then for the episode's air date. Titles ani.zip doesn't
/// know map to nil. As OpenStream for Android does it; these services promise nothing.
public actor AnimeEpisodeMapper {
    public static let shared = AnimeEpisodeMapper()

    private struct EpisodeMapping: Sendable {
        var anilistEpisode: Int
        var season: Int?
        var number: Int?
        var airDate: String?
    }

    private struct Entry: Sendable {
        var anilistID: Int
        var malID: Int?
        var titles: [String]
        var episodeCount: Int?
        var sequelID: Int?
        var episodes: [EpisodeMapping]

        func ref(_ episode: Int) -> AnimeEpisodeRef {
            AnimeEpisodeRef(anilistID: anilistID, malID: malID, episode: episode, titles: titles, episodeCount: episodeCount)
        }
    }

    private var refs: [String: AnimeEpisodeRef?] = [:]
    private var entries: [Int: Entry] = [:]
    private var roots: [String: Int?] = [:]

    private static let aniZip = "https://api.ani.zip"
    private static let aniList = URL(string: "https://graphql.anilist.co")!
    private static let seriesFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]

    /// `airDate` is the TMDB episode's ("2023-09-29"), used when season numbers don't line up.
    public func map(_ identity: MediaIdentity, airDate: String?) async -> AnimeEpisodeRef? {
        if let known = refs[identity.key] { return known }
        guard let ref = try? await lookup(identity, airDate: airDate) else { return nil }
        refs[identity.key] = ref
        return ref
    }

    private func lookup(_ identity: MediaIdentity, airDate: String?) async throws -> AnimeEpisodeRef? {
        let isMovie = identity.ref.kind == .movie
        guard let rootID = try await rootID(identity.ref), let root = try await entry(rootID) else { return nil }
        if isMovie { return root.ref(1) }

        var chain = [root]
        var cursor = root
        while chain.count < 12, let next = cursor.sequelID, !chain.contains(where: { $0.anilistID == next }),
              let entry = try await entry(next) {
            chain.append(entry)
            cursor = entry
        }
        for entry in chain {
            if let match = entry.episodes.first(where: { $0.season == identity.season && $0.number == identity.episode }) {
                return entry.ref(match.anilistEpisode)
            }
        }
        if let airDate = airDate.map({ String($0.prefix(10)) }), airDate.count == 10 {
            for entry in chain {
                if let match = entry.episodes.first(where: { $0.airDate == airDate }) { return entry.ref(match.anilistEpisode) }
            }
        }
        // A single-entry show numbers its episodes the same way TMDB does.
        if identity.season == 1, root.episodeCount.map({ identity.episode <= $0 }) ?? true {
            return root.ref(identity.episode)
        }
        return nil
    }

    private func rootID(_ ref: TitleRef) async throws -> Int? {
        if let known = roots[ref.description] { return known }
        guard let data = try await get(URL(string: "\(Self.aniZip)/mappings?themoviedb_id=\(ref.id)")!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mappings = root["mappings"] as? [String: Any]
        else {
            roots[ref.description] = .some(nil)
            return nil
        }
        // TMDB film and series ids share numbers; ani.zip's type says which it matched.
        let isMovie = (mappings["type"] as? String) == "MOVIE"
        let id = isMovie == (ref.kind == .movie) ? (mappings["anilist_id"] as? Int) : nil
        roots[ref.description] = id
        return id
    }

    private func entry(_ id: Int) async throws -> Entry? {
        if let known = entries[id] { return known }
        let query = "query($id:Int){Media(id:$id,type:ANIME){id idMal episodes format title{romaji english} relations{edges{relationType node{id type format}}}}}"
        var request = URLRequest(url: Self.aniList, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": id]])
        let (data, response) = try await SourceHTTP.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = (root["data"] as? [String: Any])?["Media"] as? [String: Any]
        else { return nil }
        let titles = media["title"] as? [String: Any]
        let edges = ((media["relations"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        let sequel = edges.first { edge in
            let node = edge["node"] as? [String: Any]
            return edge["relationType"] as? String == "SEQUEL" && node?["type"] as? String == "ANIME"
                && Self.seriesFormats.contains(node?["format"] as? String ?? "")
        }
        var episodes: [EpisodeMapping] = []
        if let data = try await get(URL(string: "\(Self.aniZip)/mappings?anilist_id=\(id)")!),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = root["episodes"] as? [String: Any] {
            for (key, value) in list {
                guard let number = Int(key), let episode = value as? [String: Any] else { continue }
                episodes.append(EpisodeMapping(anilistEpisode: number, season: episode["seasonNumber"] as? Int,
                                               number: episode["episodeNumber"] as? Int,
                                               airDate: ((episode["airDate"] ?? episode["airdate"]) as? String).map { String($0.prefix(10)) }))
            }
        }
        let entry = Entry(anilistID: id, malID: media["idMal"] as? Int,
                          titles: [titles?["romaji"] as? String, titles?["english"] as? String].compactMap { $0 },
                          episodeCount: media["episodes"] as? Int,
                          sequelID: (sequel?["node"] as? [String: Any])?["id"] as? Int,
                          episodes: episodes.sorted { $0.anilistEpisode < $1.anilistEpisode })
        entries[id] = entry
        return entry
    }

    private func get(_ url: URL) async throws -> Data? {
        try await SourceHTTP.get(url)
    }
}

/// A stretch of an episode the viewer can skip.
public struct SkipSegment: Sendable, Hashable {
    public enum Kind: String, Sendable { case intro, recap, credits }
    public var kind: Kind
    public var start: Double
    public var end: Double
    /// The file length the times were measured on; files differ by a few seconds.
    public var episodeLength: Double
}

/// Intro, recap and credits times for anime from AniSkip (api.aniskip.com, keyless, community
/// submissions keyed by MyAnimeList id and episode). Any failure just means no Skip button.
public enum SkipTimes {
    public static func segments(malID: Int, episode: Int) async -> [SkipSegment] {
        let types = ["op", "ed", "recap", "mixed-op", "mixed-ed"].map { "types=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)?\(types)&episodeLength=0"),
              let data = try? await SourceHTTP.get(url)
        else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [SkipSegment] {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Interval: Decodable { var startTime: Double; var endTime: Double }
                var interval: Interval?
                var skipType: String?
                var episodeLength: Double?
            }
            var found: Bool?
            var results: [Result]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.found == true else { return [] }
        return (response.results ?? []).compactMap { result in
            let kind: SkipSegment.Kind
            switch result.skipType {
            case "op", "mixed-op": kind = .intro
            case "recap": kind = .recap
            case "ed", "mixed-ed": kind = .credits
            default: return nil
            }
            guard let interval = result.interval, interval.endTime > interval.startTime else { return nil }
            return SkipSegment(kind: kind, start: interval.startTime, end: interval.endTime, episodeLength: result.episodeLength ?? 0)
        }
        .sorted { $0.start < $1.start }
    }

    /// One segment of each kind: the submission timed on the file length closest to the one
    /// playing, so the button lines up with this file's intro.
    public static func best(_ segments: [SkipSegment], duration: Double) -> [SkipSegment] {
        let kinds: [SkipSegment.Kind] = [.recap, .intro, .credits]
        return kinds.compactMap { kind in
            segments.filter { $0.kind == kind }.min {
                abs($0.episodeLength - duration) < abs($1.episodeLength - duration)
            }
        }
        .filter { duration <= 0 || $0.end <= duration + 5 }
    }
}
