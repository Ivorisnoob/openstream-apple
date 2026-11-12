import OpenStreamCore
import SwiftUI

/// Posters in as many columns as fit, the way the TV app shows a full list.
struct PosterGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.posterWidth, maximum: Layout.posterWidth + 40),
                                     spacing: Layout.cardSpacing, alignment: .top)],
                  alignment: .leading, spacing: 28) {
            ForEach(items) { cell($0) }
        }
        .padding(.horizontal, Layout.gutter)
    }
}

/// A whole list ("See All", a genre), loading its next page as the end comes into view.
struct TitleListView: View {
    let list: TitleList
    let name: String
    @Environment(AppModel.self) private var app
    @State private var titles: [TitleSummary] = []
    @State private var page = 0
    @State private var state: LoadState<Void> = .loading
    @State private var reachedEnd = false

    var body: some View {
        Group {
            if case .failed(let message) = state, titles.isEmpty {
                LoadFailedView(message: message) { Task { await loadMore() } }
            } else {
                ScrollView {
                    PosterGrid(items: titles.isEmpty ? TitleSummary.placeholders(18) : titles) { title in
                        TitleLink(title: title) { PosterCard(title: title, width: Layout.posterWidth, showsCaption: true) }
                            .onAppear {
                                if title.id == titles.last?.id { Task { await loadMore() } }
                            }
                    }
                    .loadingPlaceholder(titles.isEmpty)
                    .padding(.vertical, 24)
                    if !titles.isEmpty, !reachedEnd {
                        ProgressView().controlSize(.small).padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationTitle(name)
        .task { if titles.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !reachedEnd, page < 25 else { return }
        if case .loading = state, page > 0 { return }
        state = .loading
        do {
            let next = try await app.tmdb.titles(list, page: page + 1)
            page += 1
            let known = Set(titles.map(\.ref))
            titles += next.filter { $0.posterPath != nil && !known.contains($0.ref) }
            reachedEnd = next.isEmpty
            state = .loaded(())
        } catch is CancellationError {
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

struct PersonView: View {
    let id: Int
    let name: String
    @Environment(AppModel.self) private var app
    @State private var person: LoadState<Person> = .loading
    @State private var showsBiography = false

    var body: some View {
        Group {
            switch person {
            case .failed(let message):
                LoadFailedView(message: message) { Task { await load() } }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        if let person = person.value, !person.credits.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Known For")
                                    .font(.title2.bold())
                                    .padding(.horizontal, Layout.gutter)
                                    .accessibilityAddTraits(.isHeader)
                                PosterGrid(items: person.credits) { title in
                                    TitleLink(title: title) { PosterCard(title: title, showsCaption: true) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 28)
                }
            }
        }
        .navigationTitle(name)
        .task(id: id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            Artwork(path: person.value?.profilePath, kind: .profile, width: 160, placeholderSymbol: "person.fill")
                .frame(width: 160, height: 160)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.largeTitle.bold())
                if let person = person.value {
                    Text(details(person))
                        .foregroundStyle(.secondary)
                    if !person.biography.isEmpty {
                        Text(person.biography)
                            .lineLimit(showsBiography ? nil : 5)
                            .frame(maxWidth: 700, alignment: .leading)
                            .padding(.top, 6)
                        Button(showsBiography ? "Less" : "More") {
                            withAnimation(.smooth) { showsBiography.toggle() }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.gutter)
    }

    private func details(_ person: Person) -> String {
        var parts = [person.knownFor].filter { !$0.isEmpty }
        if let born = TMDBDate.parse(person.birthday) {
            parts.append("Born " + born.formatted(date: .long, time: .omitted))
        }
        if let place = person.placeOfBirth { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            person = .loaded(try await app.tmdb.person(id))
        } catch is CancellationError {
        } catch {
            person = .failed(error.friendlyMessage)
        }
    }
}
