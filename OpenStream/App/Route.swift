import OpenStreamCore
import SwiftUI

/// Every page that can be pushed onto a section's stack.
enum Route: Hashable {
    case title(TitleSummary)
    case person(id: Int, name: String)
    case list(TitleList, name: String)
    case genre(Genre, kind: MediaKind, anime: Bool)
}

/// The sidebar's places. Each keeps its own trail of pages, as the TV app's sidebar does.
enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case search, home, movies, shows, anime
    case continueWatching, watchlist, history
    case sources

    var id: Self { self }

    var name: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .anime: "Anime"
        case .continueWatching: "Continue Watching"
        case .watchlist: "Watchlist"
        case .history: "History"
        case .sources: "Sources"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .movies: "film"
        case .shows: "tv"
        case .anime: "sparkles.tv"
        case .continueWatching: "play.circle"
        case .watchlist: "bookmark"
        case .history: "clock"
        case .sources: "antenna.radiowaves.left.and.right"
        }
    }

    static let browse: [SidebarItem] = [.search, .home, .movies, .shows, .anime]
    static let library: [SidebarItem] = [.continueWatching, .watchlist, .history]
}
