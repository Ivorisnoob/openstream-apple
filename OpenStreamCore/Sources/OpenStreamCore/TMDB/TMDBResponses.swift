import Foundation

// TMDB's JSON as it arrives. Everything is optional: TMDB leaves fields out freely, and one
// missing field must never cost a whole page. These turn into the public models at the end.

struct PageDTO<Item: Decodable & Sendable>: Decodable, Sendable {
    var results: [Item]?
    var page: Int?
    var totalPages: Int?
}

struct TitleDTO: Decodable, Sendable {
    var id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var profilePath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var voteCount: Int?
    var popularity: Double?
    var genreIds: [Int]?
    var originalLanguage: String?
    var knownForDepartment: String?
    var character: String?
    var job: String?

    /// Lists of one kind don't say their kind, so the caller passes it; mixed lists do.
    func summary(defaultKind: MediaKind?) -> TitleSummary? {
        let kind: MediaKind
        switch mediaType {
        case "movie": kind = .movie
        case "tv": kind = .tv
        case nil: guard let defaultKind else { return nil }; kind = defaultKind
        default: return nil
        }
        guard let name = title ?? name, !name.isEmpty else { return nil }
        return TitleSummary(
            ref: TitleRef(kind: kind, id: id),
            name: name,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            date: releaseDate ?? firstAirDate ?? "",
            rating: voteAverage ?? 0,
            genreIDs: genreIds ?? [],
            originalLanguage: originalLanguage
        )
    }
}

struct GenreListDTO: Decodable, Sendable {
    var genres: [Genre]?
}

struct EpisodeDTO: Decodable, Sendable {
    var episodeNumber: Int?
    var seasonNumber: Int?
    var name: String?
    var overview: String?
    var stillPath: String?
    var airDate: String?
    var runtime: Int?

    func episode(season fallback: Int) -> Episode? {
        guard let episodeNumber else { return nil }
        return Episode(
            season: seasonNumber ?? fallback,
            number: episodeNumber,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Episode \(episodeNumber)",
            overview: overview ?? "",
            stillPath: stillPath,
            airDate: airDate ?? "",
            runtime: runtime
        )
    }
}

struct SeasonDTO: Decodable, Sendable {
    var seasonNumber: Int?
    var name: String?
    var overview: String?
    var episodeCount: Int?
    var posterPath: String?
    var airDate: String?
    var episodes: [EpisodeDTO]?
}

struct DetailsDTO: Decodable, Sendable {
    struct Named: Decodable, Sendable { var name: String? }
    struct Credit: Decodable, Sendable {
        var id: Int
        var name: String?
        var character: String?
        var job: String?
        var profilePath: String?
    }
    struct Credits: Decodable, Sendable {
        var cast: [Credit]?
        var crew: [Credit]?
    }
    struct Video: Decodable, Sendable {
        var key: String?
        var site: String?
        var type: String?
        var name: String?
        var official: Bool?
    }
    struct Videos: Decodable, Sendable { var results: [Video]? }
    struct ExternalIDs: Decodable, Sendable { var imdbId: String? }
    struct Logo: Decodable, Sendable {
        var filePath: String?
        var iso6391: String?
        var aspectRatio: Double?
        var voteAverage: Double?
    }
    struct Images: Decodable, Sendable { var logos: [Logo]? }
    struct ReleaseDate: Decodable, Sendable { var certification: String? }
    struct CountryReleases: Decodable, Sendable {
        var iso31661: String?
        var releaseDates: [ReleaseDate]?
    }
    struct ReleaseDates: Decodable, Sendable { var results: [CountryReleases]? }
    struct Rating: Decodable, Sendable {
        var iso31661: String?
        var rating: String?
    }
    struct Ratings: Decodable, Sendable { var results: [Rating]? }

    var id: Int
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var genres: [Genre]?
    var runtime: Int?
    var episodeRunTime: [Int]?
    var status: String?
    var imdbId: String?
    var originalLanguage: String?
    var seasons: [SeasonDTO]?
    var productionCompanies: [Named]?
    var networks: [Named]?
    var nextEpisodeToAir: EpisodeDTO?
    var lastEpisodeToAir: EpisodeDTO?
    var credits: Credits?
    var videos: Videos?
    var recommendations: PageDTO<TitleDTO>?
    var similar: PageDTO<TitleDTO>?
    var externalIds: ExternalIDs?
    var images: Images?
    var releaseDates: ReleaseDates?
    var contentRatings: Ratings?

    func details(kind: MediaKind) -> TitleDetails {
        let name = title ?? self.name ?? ""
        let summary = TitleSummary(
            ref: TitleRef(kind: kind, id: id),
            name: name,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            date: releaseDate ?? firstAirDate ?? "",
            rating: voteAverage ?? 0,
            genreIDs: (genres ?? []).map(\.id),
            originalLanguage: originalLanguage
        )
        // An English logo first, then one with no text language; the best voted of those.
        let logos = images?.logos ?? []
        let logo = (logos.filter { $0.iso6391 == "en" } + logos.filter { $0.iso6391 == nil })
            .first { $0.filePath != nil }
        let trailers = (videos?.results ?? [])
            .filter { $0.site == "YouTube" && ($0.type == "Trailer" || $0.type == "Teaser") && $0.key != nil }
            .sorted { ($0.type == "Trailer" ? 0 : 1, $0.official == true ? 0 : 1) < ($1.type == "Trailer" ? 0 : 1, $1.official == true ? 0 : 1) }
            .map { Trailer(key: $0.key!, name: $0.name ?? "Trailer") }
        // One entry per person with every job they had, the most telling job first
        // ("Director, Writer"), people ordered by that job.
        let jobs = kind == .movie ? ["Director", "Screenplay", "Writer"] : ["Executive Producer"]
        var crewByPerson: [Int: (credit: Credit, jobs: [String])] = [:]
        var crewOrder: [Int] = []
        // Someone already in the cast (a host who also produces) is listed once, as cast.
        let castIDs = Set((credits?.cast ?? []).prefix(30).map(\.id))
        for credit in credits?.crew ?? [] {
            guard let job = credit.job, jobs.contains(job), !castIDs.contains(credit.id) else { continue }
            if crewByPerson[credit.id] == nil { crewOrder.append(credit.id) }
            crewByPerson[credit.id, default: (credit, [])].jobs.append(job)
        }
        let crew = crewOrder.compactMap { crewByPerson[$0] }
            .map { entry in (entry.credit, Array(Set(entry.jobs)).sorted { jobs.firstIndex(of: $0)! < jobs.firstIndex(of: $1)! }) }
            .sorted { jobs.firstIndex(of: $0.1[0])! < jobs.firstIndex(of: $1.1[0])! }
            .prefix(6)
            .map { CastMember(id: $0.0.id, name: $0.0.name ?? "", role: $0.1.joined(separator: ", "), profilePath: $0.0.profilePath) }
        let cast = (credits?.cast ?? []).prefix(30)
            .map { CastMember(id: $0.id, name: $0.name ?? "", role: $0.character ?? "", profilePath: $0.profilePath) }
        let recommended = (recommendations?.results ?? []) + (similar?.results ?? [])
        var seen = Set<TitleRef>()
        let more = recommended.compactMap { $0.summary(defaultKind: kind) }
            .filter { $0.posterPath != nil && seen.insert($0.ref).inserted }
        return TitleDetails(
            summary: summary,
            tagline: tagline ?? "",
            genres: genres ?? [],
            runtime: runtime ?? episodeRunTime?.first ?? lastEpisodeToAir?.runtime,
            certification: certification,
            status: status ?? "",
            imdbID: (imdbId ?? externalIds?.imdbId).flatMap { $0.isEmpty ? nil : $0 },
            originalName: originalTitle ?? originalName ?? name,
            logoPath: logo?.filePath,
            logoAspectRatio: logo?.aspectRatio,
            cast: Array(cast),
            crew: Array(crew),
            trailers: trailers,
            recommendations: Array(more.prefix(20)),
            seasons: (seasons ?? []).compactMap { season in
                guard let number = season.seasonNumber else { return nil }
                return SeasonSummary(number: number, name: season.name ?? "Season \(number)",
                                     episodeCount: season.episodeCount ?? 0,
                                     posterPath: season.posterPath, airDate: season.airDate ?? "")
            },
            studios: ((kind == .movie ? productionCompanies : networks) ?? []).compactMap(\.name).prefix(3).map { $0 },
            nextEpisodeDate: nextEpisodeToAir?.airDate
        )
    }

    /// The US rating when there is one, which is what the app's audience expects to read.
    private var certification: String? {
        let preferred = ["US", "GB"]
        if let releases = releaseDates?.results {
            for country in preferred {
                if let rating = releases.first(where: { $0.iso31661 == country })?.releaseDates?
                    .compactMap(\.certification).first(where: { !$0.isEmpty }) {
                    return rating
                }
            }
        }
        if let ratings = contentRatings?.results {
            for country in preferred {
                if let rating = ratings.first(where: { $0.iso31661 == country })?.rating, !rating.isEmpty {
                    return rating
                }
            }
        }
        return nil
    }
}

struct PersonDTO: Decodable, Sendable {
    struct Credits: Decodable, Sendable {
        var cast: [TitleDTO]?
        var crew: [TitleDTO]?
    }

    var id: Int
    var name: String?
    var biography: String?
    var profilePath: String?
    var knownForDepartment: String?
    var birthday: String?
    var placeOfBirth: String?
    var combinedCredits: Credits?

    var person: Person {
        let credits = (combinedCredits?.cast ?? []) + (combinedCredits?.crew ?? [])
        var seen = Set<TitleRef>()
        let titles = credits
            .sorted { ($0.voteCount ?? 0) > ($1.voteCount ?? 0) }
            .compactMap { $0.summary(defaultKind: nil) }
            .filter { $0.posterPath != nil && seen.insert($0.ref).inserted }
        return Person(id: id, name: name ?? "", biography: biography ?? "", profilePath: profilePath,
                      knownFor: knownForDepartment ?? "", birthday: birthday, placeOfBirth: placeOfBirth,
                      credits: titles)
    }
}
