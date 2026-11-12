import OpenStreamCore
import SwiftUI

@Observable
final class SearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", shows = "TV Shows", people = "People"
        var id: Self { self }
    }

    private(set) var results: LoadState<SearchResults>?
    private(set) var query = ""
    var scope: Scope = .all

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Searches as the viewer types, a moment after they pause; the latest query always wins.
    func search(_ text: String, tmdb: TMDB) {
        let text = text.trimmingCharacters(in: .whitespaces)
        task?.cancel()
        guard text != query || results == nil else { return }
        query = text
        guard !text.isEmpty else { results = nil; return }
        if results == nil { results = .loading }
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let found = try await tmdb.search(text)
                guard !Task.isCancelled else { return }
                results = .loaded(found)
            } catch is CancellationError {
            } catch {
                results = .failed(error.friendlyMessage)
            }
        }
    }

    func titles(_ results: SearchResults) -> [TitleSummary] {
        switch scope {
        case .all: results.titles
        case .movies: results.titles.filter { $0.kind == .movie }
        case .shows: results.titles.filter { $0.kind == .tv }
        case .people: []
        }
    }
}

/// Search: genres to browse until something is typed, then results as you type.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SearchModel()
    @State private var movieGenres: [Genre] = []
    @State private var showGenres: [Genre] = []

    var body: some View {
        Group {
            switch model.results {
            case nil:
                browse
            case .failed(let message):
                LoadFailedView(message: message) { model.search(app.searchText, tmdb: app.tmdb) }
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let results):
                if results.titles.isEmpty, results.people.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    resultsView(results)
                }
            }
        }
        .navigationTitle("Search")
        .onChange(of: app.searchText, initial: true) { _, text in model.search(text, tmdb: app.tmdb) }
        .task {
            async let movies = try? app.tmdb.genres(.movie)
            async let shows = try? app.tmdb.genres(.tv)
            movieGenres = await movies ?? []
            showGenres = await shows ?? []
        }
    }

    private func resultsView(_ results: SearchResults) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Show", selection: $model.scope) {
                    ForEach(SearchModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, Layout.gutter)

                if model.scope == .all || model.scope == .people, !results.people.isEmpty {
                    Shelf(title: "People") {
                        ForEach(results.people) { person in
                            NavigationLink(value: Route.person(id: person.id, name: person.name)) {
                                PersonCard(name: person.name, role: person.knownFor, profilePath: person.profilePath)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                }
                let titles = model.titles(results)
                if !titles.isEmpty {
                    PosterGrid(items: titles) { title in
                        TitleLink(title: title) { PosterCard(title: title, showsCaption: true) }
                    }
                } else if model.scope != .people {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                genreGrid("Movies", genres: movieGenres, kind: .movie)
                genreGrid("TV Shows", genres: showGenres, kind: .tv)
            }
            .padding(.vertical, 28)
        }
    }

    @ViewBuilder
    private func genreGrid(_ title: String, genres: [Genre], kind: MediaKind) -> some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(genres) { genre in
                        NavigationLink(value: Route.genre(genre, kind: kind, anime: false)) {
                            GenreTile(genre: genre)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
        }
    }
}

/// A genre as a coloured tile, its colour fixed per genre so the grid looks the same every time.
private struct GenreTile: View {
    let genre: Genre
    @Environment(\.cardHovered) private var hovered

    private var tint: Color {
        let hues: [Double] = [0.0, 0.07, 0.12, 0.33, 0.45, 0.55, 0.62, 0.7, 0.78, 0.88, 0.95]
        return Color(hue: hues[abs(genre.id) % hues.count], saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        Text(genre.name)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .bottomLeading)
            .background(tint.gradient, in: .rect(cornerRadius: Layout.cornerRadius))
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: hovered)
    }
}
