import Foundation

public enum TMDBError: LocalizedError, Sendable {
    case missingKey
    case http(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "This build has no TMDB key."
        case .http(401): "TMDB didn't accept this build's key."
        case .http(404): "TMDB doesn't have this anymore."
        case .http(let code): "TMDB answered with an error (\(code))."
        case .unreadable: "TMDB's answer couldn't be read."
        }
    }
}

/// A list of titles TMDB can give, one page at a time.
public enum TitleList: Hashable, Sendable {
    case trending(MediaKind?, daily: Bool = false)
    case popular(MediaKind)
    case topRated(MediaKind)
    case nowPlaying
    case upcoming
    case onTheAir
    case airingToday
    case discover(MediaKind, [String: String])

    var path: String {
        switch self {
        case .trending(let kind, let daily): "trending/\(kind?.rawValue ?? "all")/\(daily ? "day" : "week")"
        case .popular(let kind): "\(kind.rawValue)/popular"
        case .topRated(let kind): "\(kind.rawValue)/top_rated"
        case .nowPlaying: "movie/now_playing"
        case .upcoming: "movie/upcoming"
        case .onTheAir: "tv/on_the_air"
        case .airingToday: "tv/airing_today"
        case .discover(let kind, _): "discover/\(kind.rawValue)"
        }
    }

    var kind: MediaKind? {
        switch self {
        case .trending(let kind, _): kind
        case .popular(let kind), .topRated(let kind), .discover(let kind, _): kind
        case .nowPlaying, .upcoming: .movie
        case .onTheAir, .airingToday: .tv
        }
    }

    var query: [String: String] {
        if case .discover(_, let filters) = self { return filters }
        return [:]
    }

    /// Anime: Japanese animation. TMDB has no anime genre, so this is the closest honest filter.
    public static func anime(_ kind: MediaKind, sortedBy sort: String = "popularity.desc", extra: [String: String] = [:]) -> TitleList {
        var filters = ["with_genres": "16", "with_original_language": "ja", "sort_by": sort, "vote_count.gte": "20"]
        filters.merge(extra) { _, new in new }
        return .discover(kind, filters)
    }
}

/// The Movie Database: every title, season, person and image the app shows.
///
/// Caching is HTTP's own: TMDB sends `Cache-Control: max-age` (hours for a title, minutes for
/// trending) and an ETag, so a `URLCache` on disk answers fresh requests without the network and
/// revalidates stale ones with a 304. With no connection, the cached copy is used however old.
public final class TMDB: Sendable {
    private let apiKey: String
    private let session: URLSession
    private let cache: URLCache
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(apiKey: String, cacheDirectory: URL?) {
        self.apiKey = apiKey
        cache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20, directory: cacheDirectory)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    // MARK: Lists

    public func titles(_ list: TitleList, page: Int = 1, fresh: Bool = false) async throws -> [TitleSummary] {
        var query = list.query
        query["page"] = String(page)
        let response: PageDTO<TitleDTO> = try await get(list.path, query, fresh: fresh)
        return (response.results ?? []).compactMap { $0.summary(defaultKind: list.kind) }
    }

    public func genres(_ kind: MediaKind) async throws -> [Genre] {
        let response: GenreListDTO = try await get("genre/\(kind.rawValue)/list", [:])
        return response.genres ?? []
    }

    public func search(_ text: String, page: Int = 1) async throws -> SearchResults {
        let response: PageDTO<TitleDTO> = try await get("search/multi", ["query": text, "page": String(page)])
        let results = response.results ?? []
        let people = results.filter { $0.mediaType == "person" }.compactMap { dto -> PersonSummary? in
            guard let name = dto.name else { return nil }
            return PersonSummary(id: dto.id, name: name, profilePath: dto.profilePath,
                                 knownFor: dto.knownForDepartment ?? "")
        }
        return SearchResults(titles: results.compactMap { $0.summary(defaultKind: nil) }, people: people)
    }

    // MARK: Titles

    public func details(_ ref: TitleRef, fresh: Bool = false) async throws -> TitleDetails {
        let appended = ref.kind == .movie
            ? "credits,videos,recommendations,similar,external_ids,images,release_dates"
            : "credits,videos,recommendations,similar,external_ids,images,content_ratings"
        let response: DetailsDTO = try await get(
            "\(ref.kind.rawValue)/\(ref.id)",
            ["append_to_response": appended, "include_image_language": "en,null"],
            fresh: fresh
        )
        return response.details(kind: ref.kind)
    }

    public func season(_ showID: Int, number: Int, fresh: Bool = false) async throws -> Season {
        let response: SeasonDTO = try await get("tv/\(showID)/season/\(number)", [:], fresh: fresh)
        return Season(
            number: response.seasonNumber ?? number,
            name: response.name ?? "Season \(number)",
            overview: response.overview ?? "",
            episodes: (response.episodes ?? []).compactMap { $0.episode(season: number) }
        )
    }

    public func person(_ id: Int) async throws -> Person {
        let response: PersonDTO = try await get("person/\(id)", ["append_to_response": "combined_credits"])
        return response.person
    }

    public func clearCache() {
        cache.removeAllCachedResponses()
    }

    public var cacheSize: Int { cache.currentDiskUsage }

    // MARK: Requests

    private func get<T: Decodable & Sendable>(_ path: String, _ query: [String: String],
                                              fresh: Bool = false) async throws -> T {
        guard !apiKey.isEmpty else { throw TMDBError.missingKey }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        items.append(URLQueryItem(name: "include_adult", value: "false"))
        items.append(URLQueryItem(name: "language", value: "en-US"))
        // A stable order, so the same request always finds the same cache entry.
        items.sort { $0.name < $1.name }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        // Pull to refresh skips the cache; the new answer still replaces the cached one.
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }

        do {
            return try await load(request)
        } catch let error as URLError where Self.isOffline(error) {
            request.cachePolicy = .returnCacheDataDontLoad
            if let value: T = try? await load(request) { return value }
            throw error
        }
    }

    private func load<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TMDBError.http(status) }
        do { return try decoder.decode(T.self, from: data) } catch { throw TMDBError.unreadable }
    }

    private static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
         .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed].contains(error.code)
    }
}
