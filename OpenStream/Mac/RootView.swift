import OpenStreamCore
import SwiftUI

/// The main window: the sidebar of places, and each place's own stack of pages beside it.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool
    @State private var beforeSearch: SidebarItem = .home

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            NavigationStack(path: app.path(for: app.selection)) {
                root(app.selection)
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
            .id(app.selection)
        }
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Movies, Shows, People")
        .searchFocused($searchFocused)
        .onChange(of: app.searchText) { _, text in
            // Typing takes you to the results; clearing the field takes you back.
            if !text.isEmpty, app.selection != .search {
                beforeSearch = app.selection
                app.selection = .search
                app.paths[.search] = []
            } else if text.isEmpty, app.selection == .search, app.paths[.search, default: []].isEmpty {
                app.selection = beforeSearch
            }
        }
        .onChange(of: app.focusSearch) { _, _ in searchFocused = true }
        .frame(minWidth: 820, minHeight: 560)
        .task { await app.sources.refresh() }
    }

    @ViewBuilder
    private func root(_ item: SidebarItem) -> some View {
        switch item {
        case .search: SearchView()
        case .home: BrowseView(model: app.home, name: "Home")
        case .movies: BrowseView(model: app.movies, name: "Movies")
        case .shows: BrowseView(model: app.shows, name: "TV Shows")
        case .anime: BrowseView(model: app.anime, name: "Anime")
        case .continueWatching: ContinueWatchingView()
        case .watchlist: WatchlistView()
        case .history: HistoryView()
        case .sources: SourcesView()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .title(let title): TitleView(summary: title)
        case .person(let id, let name): PersonView(id: id, name: name)
        case .list(let list, let name): TitleListView(list: list, name: name)
        case .genre(let genre, let kind, _):
            TitleListView(list: .discover(kind, ["with_genres": String(genre.id), "sort_by": "popularity.desc",
                                                 "vote_count.gte": "50"]),
                          name: genre.name)
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List(selection: Binding { app.selection } set: { if let item = $0 { app.select(item) } }) {
            Section {
                // The search field sits above the list, as Music's does; this row shows its page.
                ForEach(SidebarItem.browse.filter { $0 != .search }) { row($0) }
            }
            Section("Library") {
                ForEach(SidebarItem.library) { row($0) }
            }
            Section {
                row(.sources)
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) {
            // Settings at the sidebar's foot, opening the app's Settings window (⌘,).
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .help("Settings (⌘,)")
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.name, systemImage: item.symbol)
            .tag(item)
    }
}
