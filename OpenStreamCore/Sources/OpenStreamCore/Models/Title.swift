import Foundation

/// TMDB keeps films and series in separate id spaces, so a title is always a kind plus an id.
public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case movie
    case tv

    public var displayName: String {
        switch self {
        case .movie: "Movie"
        case .tv: "TV Show"
        }
    }
}

public struct TitleRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var kind: MediaKind
    public var id: Int

    public init(kind: MediaKind, id: Int) {
        self.kind = kind
        self.id = id
    }

    /// "movie:27205" or "tv:1396": the key used in saved data.
    public var description: String { "\(kind.rawValue):\(id)" }
}

/// What a list, shelf or search result knows about a title.
public struct TitleSummary: Identifiable, Hashable, Codable, Sendable {
    public var ref: TitleRef
    public var name: String
    public var overview: String
    public var posterPath: String?
    public var backdropPath: String?
    /// "2010-07-15"; empty when TMDB has no date.
    public var date: String
    public var rating: Double
    public var genreIDs: [Int]
    public var originalLanguage: String?

    public var id: TitleRef { ref }
    public var kind: MediaKind { ref.kind }

    public var year: Int? { date.count >= 4 ? Int(date.prefix(4)) : nil }

    public init(ref: TitleRef, name: String, overview: String = "", posterPath: String? = nil,
                backdropPath: String? = nil, date: String = "", rating: Double = 0,
                genreIDs: [Int] = [], originalLanguage: String? = nil) {
        self.ref = ref
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.date = date
        self.rating = rating
        self.genreIDs = genreIDs
        self.originalLanguage = originalLanguage
    }

    enum CodingKeys: String, CodingKey {
        case ref, name, overview, posterPath, backdropPath, date, rating, genreIDs, originalLanguage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(TitleRef.self, forKey: .ref)
        name = try c.decode(String.self, forKey: .name)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try c.decodeIfPresent(String.self, forKey: .backdropPath)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        rating = try c.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        genreIDs = try c.decodeIfPresent([Int].self, forKey: .genreIDs) ?? []
        originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage)
    }
}

public struct Genre: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CastMember: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    /// The character for actors, the job for crew.
    public var role: String
    public var profilePath: String?
}

public struct Trailer: Hashable, Codable, Sendable, Identifiable {
    public var key: String
    public var name: String

    public var id: String { key }
    public var url: URL { URL(string: "https://www.youtube.com/watch?v=\(key)")! }
}

public struct SeasonSummary: Hashable, Codable, Sendable, Identifiable {
    public var number: Int
    public var name: String
    public var episodeCount: Int
    public var posterPath: String?
    public var airDate: String

    public var id: Int { number }
}

public struct Episode: Hashable, Codable, Sendable, Identifiable {
    public var season: Int
    public var number: Int
    public var name: String
    public var overview: String
    public var stillPath: String?
    public var airDate: String
    /// Minutes.
    public var runtime: Int?

    public var id: String { "\(season):\(number)" }

    public init(season: Int, number: Int, name: String, overview: String, stillPath: String?, airDate: String,
                runtime: Int?) {
        self.season = season
        self.number = number
        self.name = name
        self.overview = overview
        self.stillPath = stillPath
        self.airDate = airDate
        self.runtime = runtime
    }

    /// TMDB lists episodes that haven't aired yet; they can't be played.
    public var hasAired: Bool {
        guard let date = TMDBDate.parse(airDate) else { return false }
        return date <= .now
    }
}

public struct Season: Hashable, Codable, Sendable {
    public var number: Int
    public var name: String
    public var overview: String
    public var episodes: [Episode]
}

/// Everything the title page shows.
public struct TitleDetails: Hashable, Sendable {
    public var summary: TitleSummary
    public var tagline: String
    public var genres: [Genre]
    /// Minutes; for a series the usual episode length.
    public var runtime: Int?
    public var certification: String?
    public var status: String
    public var imdbID: String?
    public var originalName: String
    public var logoPath: String?
    public var logoAspectRatio: Double?
    public var cast: [CastMember]
    public var crew: [CastMember]
    public var trailers: [Trailer]
    public var recommendations: [TitleSummary]
    public var seasons: [SeasonSummary]
    public var studios: [String]
    public var nextEpisodeDate: String?

    public var ref: TitleRef { summary.ref }

    /// Seasons with episodes, specials last, as streaming apps order them.
    public var playableSeasons: [SeasonSummary] {
        let regular = seasons.filter { $0.number > 0 && $0.episodeCount > 0 }
        let specials = seasons.filter { $0.number == 0 && $0.episodeCount > 0 }
        return regular + specials
    }
}

public struct Person: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var biography: String
    public var profilePath: String?
    public var knownFor: String
    public var birthday: String?
    public var placeOfBirth: String?
    /// Their films and series, most popular first, each once.
    public var credits: [TitleSummary]
}

public struct SearchResults: Sendable, Hashable {
    public var titles: [TitleSummary]
    public var people: [PersonSummary]
}

public struct PersonSummary: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var profilePath: String?
    public var knownFor: String
}

public enum TMDBDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// TMDB's dates carry no time or zone; they are read as the viewer's own day.
    public static func parse(_ string: String?) -> Date? {
        guard let string, string.count == 10 else { return nil }
        return formatter.date(from: string)
    }
}
