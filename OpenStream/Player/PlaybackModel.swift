import AVFoundation
import Foundation
import Observation
import OpenStreamCore

/// The one player of the app. Finds streams for a film or episode, plays the best one, moves on
/// to the next if a stream fails, remembers where the viewer is, and lines up the next episode.
@Observable
final class PlaybackModel {
    enum Phase: Equatable {
        case idle
        /// Reading the title and its episodes before sources can be asked.
        case preparing
        case searching
        /// A stream was picked and AVFoundation is opening it.
        case loading
        case playing
        case failed(String)
    }

    let player = AVPlayer()
    private(set) var phase: Phase = .idle
    private(set) var title: TitleSummary?
    private(set) var details: TitleDetails?
    private(set) var episode: Episode?
    private(set) var seasonEpisodes: [Episode] = []
    private(set) var nextEpisode: Episode?
    private(set) var statuses: [String: SourceStatus] = [:]
    private(set) var sources: [StreamSource] = []
    private(set) var current: StreamSource?
    private(set) var failedSources: Set<String> = []
    /// The credits are close and there's an episode after this one.
    private(set) var showsUpNext = false
    /// Seconds until the next episode starts by itself.
    private(set) var countdown: Int?
    /// Bumped to ask the app to bring the player window forward.
    private(set) var windowRequests = 0

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let tmdb: TMDB
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var identity: MediaIdentity?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var searching = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var finishedThisItem = false
    @ObservationIgnored private var lastSaved: Date = .distantPast
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var failObserver: (any NSObjectProtocol)?

    init(tmdb: TMDB, library: Library) {
        self.tmdb = tmdb
        self.library = library
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2),
                                                      queue: .main, using: Self.tick(self))
    }

    var isActive: Bool { phase != .idle }

    /// "S1, E3 · Pilot" for an episode.
    var subtitle: String? {
        guard let episode else { return nil }
        return "S\(episode.season), E\(episode.number) · \(episode.name)"
    }

    // MARK: Starting

    /// Plays a film, or a series from where the viewer is (or its first episode).
    func play(_ title: TitleSummary, details: TitleDetails? = nil, episode: Episode? = nil, seasonEpisodes: [Episode] = []) {
        if title.kind == .tv, episode == nil, let item = library.continueItem(for: title.ref) {
            resume(item)
            return
        }
        start(title, details: details, season: episode?.season, episode: episode?.number, episodes: seasonEpisodes)
    }

    func resume(_ item: ContinueItem) {
        start(item.title, details: nil, season: item.season, episode: item.episode, episodes: [])
    }

    func playNextEpisode() {
        guard let title, let nextEpisode else { return }
        let episodes = seasonEpisodes.contains(nextEpisode) ? seasonEpisodes : []
        start(title, details: details, season: nextEpisode.season, episode: nextEpisode.number, episodes: episodes)
    }

    func play(episode: Episode) {
        guard let title else { return }
        start(title, details: details, season: episode.season, episode: episode.number, episodes: seasonEpisodes)
    }

    private func start(_ title: TitleSummary, details: TitleDetails?, season: Int?, episode: Int?, episodes: [Episode]) {
        saveProgress()
        tearDownItem()
        searchTask?.cancel()
        countdownTask?.cancel()
        self.title = title
        self.details = details?.ref == title.ref ? details : nil
        self.episode = nil
        nextEpisode = nil
        sources = []
        statuses = [:]
        failedSources = []
        current = nil
        countdown = nil
        showsUpNext = false
        phase = .preparing
        windowRequests += 1

        searchTask = Task {
            do {
                let details: TitleDetails
                if let known = self.details {
                    details = known
                } else {
                    details = try await tmdb.details(title.ref)
                }
                self.details = details
                if title.kind == .tv {
                    try await chooseEpisode(details: details, season: season, episode: episode, episodes: episodes)
                }
                guard !Task.isCancelled else { return }
                let identity = MediaIdentity(ref: title.ref, imdbID: details.imdbID, title: details.summary.name,
                                             originalTitle: details.originalName, year: details.summary.year,
                                             season: self.episode?.season ?? 1, episode: self.episode?.number ?? 1)
                self.identity = identity
                pendingSeek = library.resumeTime(title.ref, season: self.episode?.season, episode: self.episode?.number)
                await findSources(identity)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.friendlyMessage)
            }
        }
    }

    private func chooseEpisode(details: TitleDetails, season: Int?, episode: Int?, episodes: [Episode]) async throws {
        let seasonNumber = season ?? details.playableSeasons.first?.number ?? 1
        var list = episodes.first?.season == seasonNumber ? episodes : []
        if list.isEmpty { list = try await tmdb.season(details.ref.id, number: seasonNumber).episodes }
        seasonEpisodes = list
        let chosen = list.first { $0.number == episode } ?? list.first { $0.hasAired } ?? list.first
        self.episode = chosen
        nextEpisode = try? await following(chosen, in: list, details: details)
    }

    /// The episode after this one: the next in its season, else the first of the next season.
    private func following(_ episode: Episode?, in list: [Episode], details: TitleDetails) async throws -> Episode? {
        guard let episode else { return nil }
        if let next = list.first(where: { $0.number == episode.number + 1 }) { return next.hasAired ? next : nil }
        let seasons = details.playableSeasons.map(\.number).filter { $0 > 0 }.sorted()
        guard let nextSeason = seasons.first(where: { $0 > episode.season }) else { return nil }
        let first = try await tmdb.season(details.ref.id, number: nextSeason).episodes.first
        return first?.hasAired == true ? first : nil
    }

    // MARK: Sources

    private func findSources(_ identity: MediaIdentity) async {
        guard let finder = app?.sources.finder else { return }
        if finder.providers.isEmpty {
            phase = .failed("No sources are on. Turn some on in Sources.")
            return
        }
        if let cached = await finder.cached(identity) {
            for provider in finder.providers { statuses[provider.id] = .nothing }
            for source in cached { statuses[source.providerID] = .found(cached.filter { $0.providerID == source.providerID }.count) }
            sources = rank(cached)
            pickBest()
            return
        }
        phase = .searching
        searching = true
        for await update in finder.search(identity) {
            guard !Task.isCancelled else { break }
            statuses[update.providerID] = update.status
            guard !update.sources.isEmpty else { continue }
            sources = rank(sources + update.sources)
            schedulePick()
        }
        searching = false
        guard !Task.isCancelled else { return }
        if current == nil {
            pickTask?.cancel()
            pickBest()
        }
    }

    private func rank(_ sources: [StreamSource]) -> [StreamSource] {
        StreamFinder.rank(sources, order: app?.sources.rankingOrder ?? [])
    }

    /// The first stream found waits a moment for better ones from slower sources.
    private func schedulePick() {
        guard current == nil, pickTask == nil, app?.settings.startsAutomatically != false else { return }
        pickTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            pickTask = nil
            guard !Task.isCancelled, current == nil else { return }
            pickBest()
        }
    }

    private func pickBest() {
        guard app?.settings.startsAutomatically != false else {
            if phase == .searching, !searching { phase = sources.isEmpty ? .failed(noStreams) : .searching }
            return
        }
        if let next = sources.first(where: { $0.isLikelyPlayable && !failedSources.contains($0.id) }) {
            choose(next)
        } else if !searching {
            phase = .failed(sources.isEmpty ? noStreams : "None of the streams found would play. Try another from the list.")
        } else {
            phase = .searching
        }
    }

    private var noStreams: String {
        "No source has this \(episode == nil ? "film" : "episode") right now."
    }

    /// Plays a stream, keeping the viewer's place when switching between streams.
    func choose(_ source: StreamSource) {
        let seconds = player.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        if current != nil, seconds.isFinite, seconds > 5 { pendingSeek = seconds }
        tearDownItem()
        current = source
        phase = .loading
        finishedThisItem = false

        var headers = source.headers
        let agent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }
        if let agent { headers[agent.key] = nil }
        let asset = AVURLAsset(url: source.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPUserAgentKey: agent?.value ?? SourceHTTP.userAgent,
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        statusObservation = item.observe(\.status, options: [.new], changeHandler: Self.statusChanged(self, source: source))
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main, using: Self.ended(self))
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                                              queue: .main, using: Self.failedMidway(self, source: source))
        player.replaceCurrentItem(with: item)
        player.play()

        // A stream that hasn't started in 20 seconds is as good as broken.
        stallTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, current?.id == source.id, phase == .loading else { return }
            sourceFailed(source)
        }
    }

    private func sourceFailed(_ source: StreamSource) {
        guard current?.id == source.id else { return }
        // A stream that drops mid-film hands its place to the next one.
        let seconds = player.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        if seconds.isFinite, seconds > 5 { pendingSeek = seconds }
        failedSources.insert(source.id)
        if let identity { Task { await app?.sources.finder.forget(identity) } }
        current = nil
        tearDownItem()
        pickBest()
    }

    func searchAgain() {
        guard let title else { return }
        if let identity { Task { await app?.sources.finder.forget(identity) } }
        start(title, details: details, season: episode?.season, episode: episode?.number, episodes: seasonEpisodes)
    }

    // MARK: Progress

    func saveProgress() {
        guard let title, current != nil, let item = player.currentItem else { return }
        let seconds = CMTimeGetSeconds(item.currentTime())
        let duration = CMTimeGetSeconds(item.duration)
        guard seconds.isFinite, duration.isFinite, duration > 60 else { return }
        library.record(title, season: episode?.season, episode: episode?.number, episodeName: episode?.name,
                       stillPath: episode?.stillPath ?? title.backdropPath, seconds: seconds, duration: duration)
        lastSaved = .now
    }

    private func progressed(seconds: Double, duration: Double) {
        guard duration.isFinite, duration > 60, seconds.isFinite else { return }
        if Date.now.timeIntervalSince(lastSaved) >= 5 { saveProgress() }
        let remaining = duration - seconds
        let nearEnd = nextEpisode != nil && remaining < max(45, duration * 0.03)
        if nearEnd != showsUpNext { showsUpNext = nearEnd }
        if !finishedThisItem, seconds / duration >= Library.finishedFraction {
            finishedThisItem = true
            markFinished()
        }
    }

    private func markFinished() {
        guard let title else { return }
        library.finish(title, season: episode?.season, episode: episode?.number, episodeName: episode?.name, next: nextEpisode)
    }

    private func itemEnded() {
        if !finishedThisItem {
            finishedThisItem = true
            markFinished()
        }
        guard nextEpisode != nil, app?.settings.autoplaysNextEpisode == true else { return }
        countdown = 5
        countdownTask = Task {
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown = left - 1
            }
            guard !Task.isCancelled else { return }
            playNextEpisode()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    // MARK: Stopping

    /// The player window closed.
    func stop() {
        saveProgress()
        searchTask?.cancel()
        pickTask?.cancel()
        pickTask = nil
        countdownTask?.cancel()
        tearDownItem()
        phase = .idle
        current = nil
        showsUpNext = false
        countdown = nil
    }

    private func tearDownItem() {
        stallTask?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Callbacks
    //
    // AVFoundation calls these on its own threads; they're built outside the main actor and hop
    // back to it, so a closure written in a main-actor method is never run elsewhere.

    private nonisolated static func tick(_ model: PlaybackModel) -> @Sendable (CMTime) -> Void {
        { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model, let item = model.player.currentItem else { return }
                model.progressed(seconds: CMTimeGetSeconds(item.currentTime()), duration: CMTimeGetSeconds(item.duration))
            }
        }
    }

    private nonisolated static func statusChanged(_ model: PlaybackModel, source: StreamSource)
        -> @Sendable (AVPlayerItem, NSKeyValueObservedChange<AVPlayerItem.Status>) -> Void {
        { [weak model] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let model, model.current?.id == source.id else { return }
                switch status {
                case .readyToPlay:
                    model.stallTask?.cancel()
                    if let seek = model.pendingSeek {
                        model.pendingSeek = nil
                        await model.player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
                    }
                    model.phase = .playing
                    model.player.play()
                case .failed:
                    model.sourceFailed(source)
                default:
                    break
                }
            }
        }
    }

    private nonisolated static func ended(_ model: PlaybackModel) -> @Sendable (Notification) -> Void {
        { [weak model] _ in
            MainActor.assumeIsolated { model?.itemEnded() }
        }
    }

    private nonisolated static func failedMidway(_ model: PlaybackModel, source: StreamSource) -> @Sendable (Notification) -> Void {
        { [weak model] _ in
            MainActor.assumeIsolated { model?.sourceFailed(source) }
        }
    }
}
