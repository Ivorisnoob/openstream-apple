import OpenStreamCore
import SwiftUI

@main
struct OpenStreamApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        Probe.runIfAsked()
        #endif
    }

    var body: some Scene {
        // One main window, listed in the Window menu and brought back once closed, as the TV app's.
        Window("OpenStream", id: "main") {
            MainWindow()
                .environment(model)
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        // Playback gets its own window, as QuickTime's does: it can sit beside the library, go
        // full screen in its own Space, and closing it stops the film.
        Window("Player", id: PlayerWindow.id) {
            PlayerView()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum PlayerWindow {
    static let id = "player"
}

/// The main window, which also brings the player forward whenever something starts.
private struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView()
            .onChange(of: app.playback.windowRequests) { _, _ in openWindow(id: PlayerWindow.id) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The menu bar: every place has a command and a shortcut.
private struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Refresh") {
                switch model.selection {
                case .home: model.home.load(fresh: true)
                case .movies: model.movies.load(fresh: true)
                case .shows: model.shows.load(fresh: true)
                case .anime: model.anime.load(fresh: true)
                default: break
                }
            }
            .keyboardShortcut("r")
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                model.focusSearch += 1
            }
            .keyboardShortcut("f")
        }
        CommandMenu("Go") {
            ForEach(Array((SidebarItem.browse.dropFirst() + SidebarItem.library).enumerated()), id: \.element) { index, item in
                Button(item.name) { model.select(item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Sources") { model.select(.sources) }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandMenu("Playback") {
            Button("Next Episode") { model.playback.playNextEpisode() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(model.playback.nextEpisode == nil || !model.playback.isActive)
            Button("Search for Streams Again") { model.playback.searchAgain() }
                .disabled(!model.playback.isActive)
        }
    }
}
