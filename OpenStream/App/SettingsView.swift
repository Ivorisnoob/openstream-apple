import OpenStreamCore
import SwiftUI

/// OpenStream → Settings… (⌘,): panes along the toolbar, as the Mac's own apps lay them out.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Playback", systemImage: "play.rectangle") { PlaybackSettings() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettings() }
        }
        .scenePadding()
        .frame(width: 520)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Toggle("Start the best stream automatically", isOn: $settings.startsAutomatically)
            Text("When off, the player lists what it finds and waits for you to choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Play the next episode automatically", isOn: $settings.autoplaysNextEpisode)
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var imageBytes = 0
    @State private var dataBytes = 0
    @State private var confirmsHistory = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Artwork", value: imageBytes.formatted(.byteCount(style: .file)))
                LabeledContent("Film and series details", value: dataBytes.formatted(.byteCount(style: .file)))
                Button("Clear Cache") {
                    ImagePipeline.shared.clear()
                    app.tmdb.clearCache()
                    measure()
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Kept so pages open instantly and work offline. It refills as you browse.")
            }
            Section("History") {
                Button("Clear History…") { confirmsHistory = true }
                    .disabled(app.library.history.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: measure)
        .confirmationDialog("Clear your watch history?", isPresented: $confirmsHistory) {
            Button("Clear History", role: .destructive) { app.library.clearHistory() }
        }
    }

    private func measure() {
        imageBytes = ImagePipeline.shared.urlCache.currentDiskUsage
        dataBytes = app.tmdb.cacheSize
    }
}
