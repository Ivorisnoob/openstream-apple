import Foundation
import Observation
import OpenStreamCore
import SwiftUI

/// The app's long-lived objects and where the main window is.
@Observable
final class AppModel {
    let tmdb: TMDB
    let library: Library
    let settings = AppSettings()
    let sources: SourcesStore
    let workingSources: WorkingSources
    let playback: PlaybackModel

    var selection: SidebarItem = .home
    /// Each sidebar place keeps its own trail of pages.
    var paths: [SidebarItem: [Route]] = [:]
    var searchText = ""
    /// Bumped by Edit → Find (⌘F) to put the cursor in the toolbar's search field.
    var focusSearch = 0

    /// Home's and the browse pages' models belong to the window, so switching places never
    /// reloads them.
    @ObservationIgnored private(set) lazy var home = BrowseModel(tmdb: tmdb, style: .home)
    @ObservationIgnored private(set) lazy var movies = BrowseModel(tmdb: tmdb, style: .movies)
    @ObservationIgnored private(set) lazy var shows = BrowseModel(tmdb: tmdb, style: .shows)
    @ObservationIgnored private(set) lazy var anime = BrowseModel(tmdb: tmdb, style: .anime)

    init() {
        let support = URL.applicationSupportDirectory.appending(path: "OpenStream")
        let caches = URL.cachesDirectory.appending(path: "com.ivor.openstream")
        tmdb = TMDB(apiKey: Secrets.tmdbKey, cacheDirectory: caches.appending(path: "TMDB"))
        library = Library(file: support.appending(path: "library.json"))
        sources = SourcesStore(folder: support)
        workingSources = WorkingSources(file: support.appending(path: "working-sources.json"))
        playback = PlaybackModel(tmdb: tmdb, library: library)
        playback.app = self
        selection = settings.startPage.item
    }

    func path(for item: SidebarItem) -> Binding<[Route]> {
        Binding { self.paths[item] ?? [] } set: { self.paths[item] = $0 }
    }

    /// Pushes a page onto the current place's stack; search results open where search is.
    func open(_ route: Route) {
        paths[selection, default: []].append(route)
    }

    /// Clicking the place you're in returns to its first page, as the Mac's sidebars do.
    func select(_ item: SidebarItem) {
        if selection == item { paths[item] = [] } else { selection = item }
    }

    func saveState() {
        playback.saveProgress()
        library.flush()
    }
}

enum Secrets {
    /// Comes from Config/Secrets.xcconfig through Info.plist, never from source.
    static let tmdbKey: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String ?? ""
        return value.hasPrefix("$(") ? "" : value
    }()
}
