import OpenStreamCore
import SwiftUI
import UniformTypeIdentifiers

/// OpenStream → Settings… (⌘,), or the gear at the sidebar's foot: panes along the toolbar,
/// each a grouped form, as the Mac's own apps lay theirs out. Changes apply at once.
struct SettingsView: View {
    @AppStorage("openstream.settings.pane") private var pane = Pane.general

    enum Pane: String {
        case general, playback, subtitles, library, storage
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Playback", systemImage: "play.rectangle", value: .playback) { PlaybackSettings() }
            Tab("Subtitles", systemImage: "captions.bubble", value: .subtitles) { SubtitleSettings() }
            Tab("Library", systemImage: "books.vertical", value: .library) { LibrarySettings() }
            Tab("Storage", systemImage: "internaldrive", value: .storage) { StorageSettings() }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmsReset = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Open at", selection: $settings.startPage) {
                    ForEach(AppSettings.StartPage.allCases) { Text($0.name).tag($0) }
                }
            } footer: {
                Text("The player always stays dark, as films are meant to be seen.")
            }
            Section("Home") {
                Toggle("Move through featured titles on their own", isOn: $settings.heroAdvances)
                Toggle("Show Continue Watching", isOn: $settings.showsContinueOnHome)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Default Settings…") { confirmsReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore every setting to its default?", isPresented: $confirmsReset) {
            Button("Restore Defaults", role: .destructive) { app.settings.reset() }
        } message: {
            Text("Your library and sources stay as they are.")
        }
    }
}

// MARK: - Playback

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle(isOn: $settings.startsAutomatically) {
                    Text("Start the best stream automatically")
                    Text("When off, the player lists what it finds and waits for you to choose.")
                }
                Toggle(isOn: $settings.resumesPlayback) {
                    Text("Resume where you left off")
                    Text("When off, films and episodes start from the beginning.")
                }
            }
            Section {
                Picker("Highest quality", selection: $settings.maxQuality) {
                    ForEach(AppSettings.qualities, id: \.self) { quality in
                        Text(quality == 0 ? "Best Available" : quality == 2160 ? "4K" : "\(quality)p").tag(quality)
                    }
                }
                Picker("Audio", selection: $settings.audioPreference) {
                    ForEach(AppSettings.AudioPreference.allCases) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("A lower quality uses less data and starts sooner on a slow connection. The audio choice decides between streams that offer both.")
            }
            Section("Episodes") {
                Toggle("Play the next episode automatically", isOn: $settings.autoplaysNextEpisode)
                Picker("Countdown", selection: $settings.nextEpisodeCountdown) {
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .disabled(!settings.autoplaysNextEpisode)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Subtitles

private struct SubtitleSettings: View {
    @Environment(AppModel.self) private var app

    /// The languages most subtitle files come in, named in the viewer's own language.
    private static let languages = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "pl", "tr", "ru", "ar", "hi", "ja", "ko", "zh"]

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Show subtitles in", selection: $settings.subtitleLanguage) {
                    Text("Off").tag(String?.none)
                    Divider()
                    ForEach(languageChoices, id: \.self) { code in
                        Text(Subtitles.languageName(code) ?? code).tag(Optional(code))
                    }
                }
                Toggle(isOn: $settings.prefersSDH) {
                    Text("Prefer subtitles for the deaf and hard of hearing")
                    Text("SDH subtitles also describe sounds and music.")
                }
            } footer: {
                Text("Subtitles come on by themselves in this language when a file is found. The subtitles button in the player changes it for what you're watching and remembers your choice.")
            }
            Section("Style") {
                Picker("Size", selection: $settings.subtitleSize) {
                    ForEach(AppSettings.SubtitleSize.allCases) { Text($0.name).tag($0) }
                }
                Picker("Text", selection: $settings.subtitleColor) {
                    ForEach(AppSettings.SubtitleColor.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Background", selection: $settings.subtitleBackground) {
                    ForEach(AppSettings.SubtitleBackground.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                SubtitlePreview()
            }
        }
        .formStyle(.grouped)
    }

    /// The common languages, plus whichever one is set if it isn't among them.
    private var languageChoices: [String] {
        var codes = Self.languages
        if let current = app.settings.subtitleLanguage, !codes.contains(current) { codes.insert(current, at: 0) }
        return codes.sorted { (Subtitles.languageName($0) ?? $0) < (Subtitles.languageName($1) ?? $1) }
    }
}

/// The chosen style over a still, sized as it would be on a 720-point-high player.
private struct SubtitlePreview: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.38), Color(red: 0.55, green: 0.42, blue: 0.3)],
                           startPoint: .top, endPoint: .bottom)
            SubtitleLine(text: "Where are you going?\nSomewhere we can't be found.", height: 300)
                .padding(.bottom, 18)
        }
        .frame(height: 150)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel("Subtitle preview")
    }
}

// MARK: - Library

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var app
    @State private var exporting = false
    @State private var importing = false
    @State private var message: String?
    @State private var confirmation: Clearing?

    enum Clearing: Identifiable {
        case history, continueWatching, watchlist
        var id: Self { self }
        var title: String {
            switch self {
            case .history: "Clear your watch history?"
            case .continueWatching: "Clear Continue Watching?"
            case .watchlist: "Clear your Watchlist?"
            }
        }
    }

    var body: some View {
        let library = app.library
        Form {
            Section {
                LabeledContent("Watchlist", value: "\(library.watchlist.count) titles")
                LabeledContent("Continue Watching", value: "\(library.continueWatching.count) titles")
                LabeledContent("History", value: "\(library.history.count) entries")
            }
            Section {
                HStack {
                    Button("Back Up Library…") { exporting = true }
                    Button("Restore from Backup…") { importing = true }
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup holds your Watchlist, where you are in everything, what you've watched and your history. Restoring adds it to what's here; nothing is removed.")
            }
            Section("Clear") {
                Button("Clear History…") { confirmation = .history }
                    .disabled(library.history.isEmpty)
                Button("Clear Continue Watching…") { confirmation = .continueWatching }
                    .disabled(library.continueWatching.isEmpty)
                Button("Clear Watchlist…") { confirmation = .watchlist }
                    .disabled(library.watchlist.isEmpty)
            }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exporting, document: BackupDocument(data: library.backup()),
                      contentType: .json, defaultFilename: "OpenStream Library \(Date.now.formatted(.iso8601.year().month().day()))") { result in
            if case .success = result { message = "Library backed up." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try library.restore(Data(contentsOf: url))
                message = "Restored: \(summary.watchlist) Watchlist titles, \(summary.progress) positions, \(summary.history) history entries."
            } catch {
                message = "That file isn't an OpenStream library backup."
            }
        }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding { confirmation != nil } set: { if !$0 { confirmation = nil } },
                            presenting: confirmation) { kind in
            Button("Clear", role: .destructive) {
                switch kind {
                case .history: library.clearHistory()
                case .continueWatching: library.clearContinueWatching()
                case .watchlist: library.clearWatchlist()
                }
            }
        } message: { _ in
            Text("This can't be undone, except from a backup.")
        }
    }
}

private struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var imageBytes = 0
    @State private var dataBytes = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Artwork", value: imageBytes.formatted(.byteCount(style: .file)))
                LabeledContent("Film and series details", value: dataBytes.formatted(.byteCount(style: .file)))
                HStack {
                    Spacer()
                    Button("Clear Cache") {
                        ImagePipeline.shared.clear()
                        app.tmdb.clearCache()
                        measure()
                    }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Kept so pages open instantly and work offline. It refills as you browse.")
            }
            Section("Sources") {
                LabeledContent("Sources on", value: "\(app.sources.enabledCount)")
                LabeledContent("Remembered sources", value: "\(app.workingSources.count) titles")
                HStack {
                    Button("Forget Remembered Sources") { app.workingSources.removeAll() }
                        .disabled(app.workingSources.count == 0)
                    Spacer()
                    Button("Check for Source Updates") { Task { await app.sources.refresh(force: true) } }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: measure)
    }

    private func measure() {
        imageBytes = ImagePipeline.shared.urlCache.currentDiskUsage
        dataBytes = app.tmdb.cacheSize
    }
}
