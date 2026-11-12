import AVKit
import OpenStreamCore
import SwiftUI

/// The player window's content, as QuickTime and the TV app play on the Mac: the picture with
/// the system's floating controls, and an inspector for streams and episodes.
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @State private var showsInspector = false
    /// The pointer moved over the picture lately, so the system's controls are showing.
    @State private var pointerActive = false
    @State private var pointerIdle: Task<Void, Never>?
    @State private var inspectorTab: InspectorTab = .sources

    enum InspectorTab: String, CaseIterable, Identifiable {
        case sources = "Streams", episodes = "Episodes"
        var id: Self { self }
    }

    private var playback: PlaybackModel { app.playback }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: playback.player)
                .opacity(playback.phase == .playing ? 1 : 0)
            if playback.phase == .playing {
                SubtitleText(raised: pointerActive)
                    .allowsHitTesting(false)
                BufferingIndicator()
            }
            if playback.phase != .playing {
                StatusOverlay(showsSources: { inspectorTab = .sources; showsInspector = true })
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            SkipButton()
                .padding(.trailing, 28)
                .padding(.bottom, 110)
        }
        .overlay(alignment: .bottomTrailing) {
            UpNextCard()
                .padding(.trailing, 28)
                .padding(.bottom, 96)
        }
        .animation(.easeInOut(duration: 0.3), value: playback.phase)
        .onContinuousHover { phase in
            // AVKit shows its controls while the pointer moves and hides them about three
            // seconds after it stops; the subtitles follow the same rhythm.
            pointerIdle?.cancel()
            guard case .active = phase else { pointerActive = false; return }
            pointerActive = true
            pointerIdle = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                pointerActive = false
            }
        }
        .ignoresSafeArea()
        .inspector(isPresented: $showsInspector) {
            PlayerInspector(tab: $inspectorTab)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AudioMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                SubtitleMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Streams and Episodes", systemImage: "list.bullet")
                }
                .help("Show streams and episodes")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(playback.title?.name ?? "OpenStream")
        .navigationSubtitle(playback.episodeLine ?? "")
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 360)
        .onDisappear { playback.stop() }
    }
}

/// AVKit's player view: the system's controls, subtitles and audio menus, speed, Picture in
/// Picture, AirPlay, full screen, the Now Playing widget and media keys.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.showsSharingServiceButton = false
        view.updatesNowPlayingInfoCenter = true
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// What the player is doing before the picture appears: the title's image, dimmed, with
/// progress or what went wrong.
private struct StatusOverlay: View {
    let showsSources: () -> Void
    @Environment(AppModel.self) private var app

    private var playback: PlaybackModel { app.playback }

    var body: some View {
        ZStack {
            Artwork(path: playback.episode?.stillPath ?? playback.title?.backdropPath, kind: .backdrop, width: 1280)
                .overlay(.black.opacity(0.6))
                .blur(radius: 24)
                .scaleEffect(1.1)
            VStack(spacing: 18) {
                if let title = playback.title {
                    TitleLogo(title: title, details: playback.details, maxWidth: 380, maxHeight: 110)
                }
                if let subtitle = playback.episodeLine {
                    Text(subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                status
                    .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
        .clipped()
    }

    @ViewBuilder
    private var status: some View {
        switch playback.phase {
        case .failed(let message):
            VStack(spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    Button("Search Again") { playback.searchAgain() }
                    if !playback.sources.isEmpty {
                        Button("Choose a Stream", action: showsSources)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        case .searching where !app.settings.startsAutomatically && !playback.sources.isEmpty:
            VStack(spacing: 12) {
                Text("\(playback.sources.count) streams found")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("Choose a Stream", action: showsSources)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        default:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: progressText)
            }
        }
    }

    private var progressText: String {
        switch playback.phase {
        case .preparing: return "Getting ready…"
        case .loading: return "Opening \(playback.current?.name ?? "stream")…"
        default:
            let total = playback.statuses.count
            let done = playback.statuses.values.filter(\.isDone).count
            if playback.isLookingFurther { return "Those streams didn't play. Asking more sources…" }
            if playback.sources.isEmpty { return "Looking for streams… \(done) of \(total) sources checked" }
            return "Found \(playback.sources.count) streams, picking the best…"
        }
    }
}

/// While the picture waits for data: a spinner, then after ten seconds a way out, so a frozen
/// frame never leaves the viewer guessing.
private struct BufferingIndicator: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        if playback.isBuffering, let since = playback.bufferingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                let slow = context.date.timeIntervalSince(since) >= 10
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    if slow {
                        Text("This stream is slow to load.")
                            .font(.callout.weight(.medium))
                        Button("Try Another Stream") { playback.tryAnotherStream() }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    }
                }
                .padding(slow ? 22 : 18)
                .glassEffect(.regular, in: .rect(cornerRadius: slow ? 22 : 40))
                .animation(.smooth, value: slow)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Loading")
        }
    }
}

/// The chosen subtitles over the picture, sized to it, in the plain white-on-dark style the
/// system uses for captions.
private struct SubtitleText: View {
    /// Lifted clear of the control bar while it shows.
    var raised = false
    @Environment(AppModel.self) private var app
    @State private var height: CGFloat = 600

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: .bottom) {
                if let text = app.playback.cueText {
                    SubtitleLine(text: text, height: height)
                        .padding(.horizontal, 40)
                        .padding(.bottom, raised ? max(110, height * 0.2) : height * 0.07)
                        .animation(.smooth(duration: 0.35), value: raised)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
    }
}

/// One subtitle line in the viewer's chosen size, colour and background (Settings → Subtitles);
/// a shadow keeps it readable when there's no background.
struct SubtitleLine: View {
    let text: String
    let height: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        Text(text)
            .font(.system(size: max(14, height * settings.subtitleSize.fraction), weight: .medium))
            .foregroundStyle(settings.subtitleColor.color)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(settings.subtitleBackground == .none ? 0.9 : 0), radius: 2, y: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(settings.subtitleBackground.opacity), in: .rect(cornerRadius: 6))
    }
}

/// Audio: the playing stream's own tracks, then every other language found for this film or
/// episode, each a stream from some source that the player switches to at the same spot.
private struct AudioMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        let others = playback.otherLanguageStreams
        Menu {
            Section("This Stream") {
                if playback.audioTracks.count > 1 {
                    ForEach(playback.audioTracks, id: \.self) { track in
                        Toggle(track.displayName, isOn: Binding { playback.selectedAudioTrack == track } set: {
                            if $0 { playback.selectAudioTrack(track) }
                        })
                    }
                } else {
                    let languages = playback.currentLanguages.map(AudioLanguages.name)
                    Text(languages.isEmpty ? "Original Audio" : languages.joined(separator: ", "))
                }
            }
            if !others.isEmpty {
                Section("Other Languages") {
                    ForEach(others, id: \.source.id) { language, source in
                        Button {
                            playback.playLanguage(language, from: source)
                        } label: {
                            Text(AudioLanguages.name(language))
                            Text("\(source.providerName) · \(source.quality.label)")
                        }
                    }
                }
            } else if playback.phase == .playing, !playback.canLookForMore, !playback.isLookingForMore {
                Text("No other languages found")
            }
            if playback.isLookingForMore {
                Text("Looking for other languages…")
            } else if playback.canLookForMore {
                Divider()
                Button("Look for Other Languages") { playback.lookForMoreStreams() }
            }
        } label: {
            Label("Audio", systemImage: "waveform")
        }
        .help("Audio language")
    }
}

/// Subtitles: Off, then each language with its files, the playing stream's own first.
private struct SubtitleMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        let options = playback.subtitleOptions
        let languages = options.reduce(into: [String]()) { if !$0.contains($1.language) { $0.append($1.language) } }
        Menu {
            Toggle("Off", isOn: Binding { playback.selectedSubtitle == nil } set: { if $0 { playback.selectSubtitle(nil) } })
            if options.isEmpty {
                Text(playback.isActive ? "Looking for subtitles…" : "No subtitles")
            }
            ForEach(languages, id: \.self) { language in
                let files = options.filter { $0.language == language }
                Section(language) {
                    ForEach(files) { option in
                        Toggle(isOn: Binding { playback.selectedSubtitle?.id == option.id } set: { if $0 { playback.selectSubtitle(option) } }) {
                            Text(title(option))
                            if let release = option.release, !release.isEmpty { Text(release) }
                        }
                    }
                }
            }
        } label: {
            Label("Subtitles", systemImage: playback.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .help(playback.subtitleError ?? (playback.isLoadingSubtitle ? "Loading subtitles…" : "Subtitles"))
    }

    private func title(_ option: SubtitleOption) -> String {
        option.isHearingImpaired ? "\(option.origin) · SDH" : option.origin
    }
}

/// "Skip Intro" while one plays, as streaming apps put it: bottom corner, above the controls.
/// Credits are left to Up Next when there's a next episode.
private struct SkipButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        if let segment = playback.activeSkip, playback.countdown == nil,
           !(segment.kind == .credits && playback.nextEpisode != nil) {
            Button {
                playback.skip(segment)
            } label: {
                Label(title(segment.kind), systemImage: "forward.end.fill")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.smooth, value: segment)
            .keyboardShortcut("s", modifiers: [])
        }
    }

    private func title(_ kind: SkipSegment.Kind) -> String {
        switch kind {
        case .intro: "Skip Intro"
        case .recap: "Skip Recap"
        case .credits: "Skip Credits"
        }
    }
}

/// Near the credits: the next episode, as the TV app offers it, then a countdown when it ends.
private struct UpNextCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        if let next = playback.nextEpisode, playback.showsUpNext || playback.countdown != nil {
            HStack(spacing: 14) {
                Artwork(path: next.stillPath, kind: .still, width: 140, placeholderSymbol: "tv")
                    .frame(width: 140, height: 79)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.countdown.map { "Next episode in \($0)" } ?? "Up Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .contentTransition(.numericText(countsDown: true))
                    Text("S\(next.season), E\(next.number) · \(next.name)")
                        .font(.headline)
                        .lineLimit(2)
                    HStack {
                        Button("Play Now") { playback.playNextEpisode() }
                            .buttonStyle(.glassProminent)
                        if playback.countdown != nil {
                            Button("Cancel") { playback.cancelCountdown() }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(width: 220, alignment: .leading)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.smooth, value: playback.countdown)
        }
    }
}

// MARK: - Inspector

private struct PlayerInspector: View {
    @Binding var tab: PlayerView.InspectorTab
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if app.playback.title?.kind == .tv {
                Picker("Show", selection: $tab) {
                    ForEach(PlayerView.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
            }
            if tab == .episodes, app.playback.title?.kind == .tv {
                EpisodeList()
            } else {
                SourceList()
            }
        }
    }
}

private struct SourceList: View {
    @Environment(AppModel.self) private var app
    @State private var showsEmpty = false

    var body: some View {
        let playback = app.playback
        let order = app.sources.rankingOrder.filter { playback.statuses[$0] != nil }
        let withStreams = order.filter { id in playback.sources.contains { $0.providerID == id } }
        let looking = order.filter { playback.statuses[$0] == .searching }
        let empty = order.filter { !withStreams.contains($0) && !looking.contains($0) }
        List {
            ForEach(withStreams, id: \.self) { providerID in
                Section(app.sources.name(of: providerID)) {
                    ForEach(playback.sources.filter { $0.providerID == providerID }) { source in
                        Button {
                            playback.choose(source)
                        } label: {
                            SourceRow(source: source, isCurrent: playback.current?.id == source.id,
                                      failed: playback.failedSources.contains(source.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !looking.isEmpty {
                Section("Still Looking") {
                    ForEach(looking, id: \.self) { providerID in
                        HStack {
                            Text(app.sources.name(of: providerID))
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if !empty.isEmpty {
                Section(isExpanded: $showsEmpty) {
                    ForEach(empty, id: \.self) { providerID in
                        HStack {
                            Text(app.sources.name(of: providerID))
                            Spacer()
                            Text(reason(playback.statuses[providerID]))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("No Streams (\(empty.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) {
            Button("Search Again", systemImage: "arrow.clockwise") { playback.searchAgain() }
                .buttonStyle(.glass)
                .padding(12)
        }
        .overlay {
            if playback.statuses.isEmpty {
                ProgressView()
            }
        }
    }

    private func reason(_ status: SourceStatus?) -> String {
        switch status {
        case .failed(let message): message
        case .waiting, .skipped: "Not needed"
        default: "Nothing found"
        }
    }
}

private struct SourceRow: View {
    let source: StreamSource
    let isCurrent: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : failed ? "exclamationmark.triangle" : "play.rectangle")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .lineLimit(2)
                    .foregroundStyle(failed ? .secondary : .primary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [source.quality.label, source.container]
        if let language = source.audioLanguage { parts.append(language) }
        if failed { parts.append("Didn't play") } else if !source.isLikelyPlayable { parts.append("May not play on Mac") }
        return parts.joined(separator: " · ")
    }
}

private struct EpisodeList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        List(playback.seasonEpisodes) { episode in
            Button {
                playback.play(episode: episode)
            } label: {
                HStack(spacing: 12) {
                    Artwork(path: episode.stillPath, kind: .still, width: 96, placeholderSymbol: "tv")
                        .frame(width: 96, height: 54)
                        .clipShape(.rect(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Episode \(episode.number)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(episode.name)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if playback.episode == episode {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!episode.hasAired)
        }
        .listStyle(.sidebar)
    }
}
