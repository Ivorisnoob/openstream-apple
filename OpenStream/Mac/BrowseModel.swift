import Foundation
import Observation
import OpenStreamCore

/// What one of the browse places shows: a hero carousel and shelves, each loaded on its own so
/// one slow or failed list never holds up the others.
@Observable
final class BrowseModel {
    enum Style { case home, movies, shows, anime }

    struct ShelfSpec: Identifiable, Hashable {
        let title: String
        let list: TitleList
        var style: TitleShelf.Style = .poster
        var limit = 20

        var id: String { title }
    }

    let style: Style
    let shelves: [ShelfSpec]
    private(set) var hero: LoadState<[TitleSummary]> = .loading
    private(set) var states: [String: LoadState<[TitleSummary]>] = [:]
    private(set) var genres: [Genre] = []
    private(set) var loadedAt: Date?

    @ObservationIgnored private let tmdb: TMDB
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(tmdb: TMDB, style: Style) {
        self.tmdb = tmdb
        self.style = style
        shelves = Self.shelves(for: style)
    }

    var kind: MediaKind? {
        switch style {
        case .movies: .movie
        case .shows: .tv
        case .home, .anime: nil
        }
    }

    var heroList: TitleList {
        switch style {
        case .home: .trending(nil)
        case .movies: .trending(.movie)
        case .shows: .trending(.tv)
        case .anime: .anime(.tv)
        }
    }

    /// Loads once, then again only when asked or after the lists have had time to change.
    func loadIfNeeded() {
        if let loadedAt, Date.now.timeIntervalSince(loadedAt) < 3600, hero.value != nil { return }
        load()
    }

    func load(fresh: Bool = false) {
        loading?.cancel()
        if hero.value == nil { hero = .loading }
        loading = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadHero(fresh: fresh) }
                for spec in shelves {
                    group.addTask { await self.loadShelf(spec, fresh: fresh) }
                }
                if let kind {
                    group.addTask { await self.loadGenres(kind) }
                }
            }
            loadedAt = .now
        }
    }

    private func loadGenres(_ kind: MediaKind) async {
        if let genres = try? await tmdb.genres(kind) { self.genres = genres }
    }

    private func loadHero(fresh: Bool) async {
        do {
            let titles = try await tmdb.titles(heroList, fresh: fresh)
            // Only titles with a wide image and a description make a good first impression.
            hero = .loaded(Array(titles.filter { $0.backdropPath != nil && !$0.overview.isEmpty }.prefix(7)))
        } catch is CancellationError {
        } catch {
            if hero.value == nil { hero = .failed(error.friendlyMessage) }
        }
    }

    private func loadShelf(_ spec: ShelfSpec, fresh: Bool) async {
        if states[spec.id]?.value == nil { states[spec.id] = .loading }
        do {
            var titles = try await tmdb.titles(spec.list, fresh: fresh)
            if titles.count < spec.limit, spec.limit > 20 {
                titles += (try? await tmdb.titles(spec.list, page: 2, fresh: fresh)) ?? []
            }
            states[spec.id] = .loaded(Array(titles.filter { $0.posterPath != nil }.prefix(spec.limit)))
        } catch is CancellationError {
        } catch {
            if states[spec.id]?.value == nil { states[spec.id] = .failed(error.friendlyMessage) }
        }
    }

    var allFailed: String? {
        guard case .failed(let message) = hero, states.values.allSatisfy({ $0.value == nil }) else { return nil }
        return message
    }

    private static func popular(_ kind: MediaKind, genre: String) -> TitleList {
        .discover(kind, ["with_genres": genre, "sort_by": "popularity.desc", "vote_count.gte": "100"])
    }

    private static func shelves(for style: Style) -> [ShelfSpec] {
        switch style {
        case .home:
            [
                ShelfSpec(title: "Top 10 This Week", list: .trending(nil), style: .ranked, limit: 10),
                ShelfSpec(title: "Trending Movies", list: .trending(.movie, daily: true)),
                ShelfSpec(title: "Trending Shows", list: .trending(.tv, daily: true)),
                ShelfSpec(title: "New Episodes This Week", list: .onTheAir, style: .wide),
                ShelfSpec(title: "Popular Anime", list: .anime(.tv)),
                ShelfSpec(title: "Top Rated Movies", list: .topRated(.movie)),
            ]
        case .movies:
            [
                ShelfSpec(title: "In Theaters", list: .nowPlaying),
                ShelfSpec(title: "Popular", list: .popular(.movie)),
                ShelfSpec(title: "Coming Soon", list: .upcoming, style: .wide),
                ShelfSpec(title: "Top Rated", list: .topRated(.movie)),
                ShelfSpec(title: "Action", list: popular(.movie, genre: "28")),
                ShelfSpec(title: "Comedy", list: popular(.movie, genre: "35")),
                ShelfSpec(title: "Science Fiction", list: popular(.movie, genre: "878")),
                ShelfSpec(title: "Horror", list: popular(.movie, genre: "27")),
                ShelfSpec(title: "Family", list: popular(.movie, genre: "10751")),
                ShelfSpec(title: "Documentaries", list: popular(.movie, genre: "99")),
            ]
        case .shows:
            [
                ShelfSpec(title: "Airing Today", list: .airingToday, style: .wide),
                ShelfSpec(title: "Popular", list: .popular(.tv)),
                ShelfSpec(title: "Top Rated", list: .topRated(.tv)),
                ShelfSpec(title: "Drama", list: popular(.tv, genre: "18")),
                ShelfSpec(title: "Comedy", list: popular(.tv, genre: "35")),
                ShelfSpec(title: "Crime", list: popular(.tv, genre: "80")),
                ShelfSpec(title: "Sci-Fi & Fantasy", list: popular(.tv, genre: "10765")),
                ShelfSpec(title: "Reality", list: popular(.tv, genre: "10764")),
                ShelfSpec(title: "Documentary Series", list: popular(.tv, genre: "99")),
            ]
        case .anime:
            [
                ShelfSpec(title: "Popular Series", list: .anime(.tv)),
                ShelfSpec(title: "Airing Now", list: .anime(.tv, extra: ["with_status": "0"]), style: .wide),
                ShelfSpec(title: "Top Rated Series", list: .anime(.tv, sortedBy: "vote_average.desc", extra: ["vote_count.gte": "300"])),
                ShelfSpec(title: "Anime Films", list: .anime(.movie)),
                ShelfSpec(title: "Top Rated Films", list: .anime(.movie, sortedBy: "vote_average.desc", extra: ["vote_count.gte": "300"])),
                ShelfSpec(title: "Action & Adventure", list: .anime(.tv, extra: ["with_genres": "16,10759"])),
                ShelfSpec(title: "Fantasy", list: .anime(.tv, extra: ["with_genres": "16,10765"])),
            ]
        }
    }
}
