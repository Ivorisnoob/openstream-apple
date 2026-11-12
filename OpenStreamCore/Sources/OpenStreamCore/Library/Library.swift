import Foundation
import Observation

/// Where the viewer is in a film or an episode.
public struct PlaybackPosition: Codable, Hashable, Sendable {
    public var seconds: Double
    public var duration: Double
    public var updatedAt: Date

    public var fraction: Double { duration > 0 ? min(1, seconds / duration) : 0 }
}

/// One row of Continue Watching: the title, and the episode to carry on with.
public struct ContinueItem: Codable, Hashable, Sendable, Identifiable {
    public var title: TitleSummary
    public var season: Int?
    public var episode: Int?
    public var episodeName: String?
    public var stillPath: String?
    public var position: PlaybackPosition
    /// The episode after a finished one, not yet started: shown as "Next Episode".
    public var isNext: Bool

    public var id: TitleRef { title.ref }

    public var key: String {
        if let season, let episode { return "\(title.ref):\(season):\(episode)" }
        return title.ref.description
    }
}

public struct HistoryItem: Codable, Hashable, Sendable, Identifiable {
    public var title: TitleSummary
    public var season: Int?
    public var episode: Int?
    public var episodeName: String?
    public var watchedAt: Date

    public var id: String { "\(title.ref):\(season ?? 0):\(episode ?? 0):\(watchedAt.timeIntervalSince1970)" }
}

/// The viewer's own things: Watchlist, where they stopped, what they finished.
@MainActor
@Observable
public final class Library {
    public private(set) var watchlist: [TitleSummary] = []
    public private(set) var continueWatching: [ContinueItem] = []
    public private(set) var history: [HistoryItem] = []
    private var positions: [String: PlaybackPosition] = [:]
    private var watched: Set<String> = []

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// A position closer than this to the end counts as finished, as credits roll.
    public static let finishedFraction = 0.94
    /// Less than this in, and it isn't worth resuming.
    public static let minimumResume: Double = 30

    struct Snapshot: Codable, Sendable {
        var watchlist: [TitleSummary]
        var continueWatching: [ContinueItem]
        var history: [HistoryItem]
        var positions: [String: PlaybackPosition]
        var watched: Set<String>

        init(watchlist: [TitleSummary], continueWatching: [ContinueItem], history: [HistoryItem],
             positions: [String: PlaybackPosition], watched: Set<String>) {
            self.watchlist = watchlist
            self.continueWatching = continueWatching
            self.history = history
            self.positions = positions
            self.watched = watched
        }

        // Every field optional, so a file from an older version always opens.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            watchlist = (try? c.decodeIfPresent([TitleSummary].self, forKey: .watchlist)) ?? []
            continueWatching = (try? c.decodeIfPresent([ContinueItem].self, forKey: .continueWatching)) ?? []
            history = (try? c.decodeIfPresent([HistoryItem].self, forKey: .history)) ?? []
            positions = (try? c.decodeIfPresent([String: PlaybackPosition].self, forKey: .positions)) ?? [:]
            watched = (try? c.decodeIfPresent(Set<String>.self, forKey: .watched)) ?? []
        }
    }

    public init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        watchlist = snapshot.watchlist
        continueWatching = snapshot.continueWatching
        history = snapshot.history
        positions = snapshot.positions
        watched = snapshot.watched
    }

    // MARK: Watchlist

    public func isInWatchlist(_ ref: TitleRef) -> Bool {
        watchlist.contains { $0.ref == ref }
    }

    public func toggleWatchlist(_ title: TitleSummary) {
        if isInWatchlist(title.ref) {
            watchlist.removeAll { $0.ref == title.ref }
        } else {
            watchlist.insert(title, at: 0)
        }
        save()
    }

    // MARK: Progress

    public static func key(_ ref: TitleRef, season: Int? = nil, episode: Int? = nil) -> String {
        if let season, let episode { return "\(ref):\(season):\(episode)" }
        return ref.description
    }

    public func position(_ ref: TitleRef, season: Int? = nil, episode: Int? = nil) -> PlaybackPosition? {
        positions[Self.key(ref, season: season, episode: episode)]
    }

    /// Where to start: the saved spot, unless it's too early or already at the credits.
    public func resumeTime(_ ref: TitleRef, season: Int? = nil, episode: Int? = nil) -> Double? {
        guard let position = position(ref, season: season, episode: episode),
              position.seconds >= Self.minimumResume, position.fraction < Self.finishedFraction
        else { return nil }
        return position.seconds
    }

    public func isWatched(_ ref: TitleRef, season: Int? = nil, episode: Int? = nil) -> Bool {
        watched.contains(Self.key(ref, season: season, episode: episode))
    }

    public func continueItem(for ref: TitleRef) -> ContinueItem? {
        continueWatching.first { $0.title.ref == ref }
    }

    /// Called every few seconds while something plays.
    public func record(_ title: TitleSummary, season: Int?, episode: Int?, episodeName: String?, stillPath: String?,
                       seconds: Double, duration: Double) {
        guard duration > 0, seconds.isFinite else { return }
        let key = Self.key(title.ref, season: season, episode: episode)
        let position = PlaybackPosition(seconds: seconds, duration: duration, updatedAt: .now)
        positions[key] = position
        if position.fraction >= Self.finishedFraction { return }
        guard seconds >= Self.minimumResume || continueItem(for: title.ref)?.key == key else { return }
        let item = ContinueItem(title: title, season: season, episode: episode, episodeName: episodeName,
                                stillPath: stillPath, position: position, isNext: false)
        continueWatching.removeAll { $0.title.ref == title.ref }
        continueWatching.insert(item, at: 0)
        save(soon: true)
    }

    /// A film or episode reached its credits. A series moves on to `next`; a film leaves
    /// Continue Watching.
    public func finish(_ title: TitleSummary, season: Int?, episode: Int?, episodeName: String?,
                       next: Episode?) {
        let key = Self.key(title.ref, season: season, episode: episode)
        let alreadyWatched = watched.contains(key)
        watched.insert(key)
        if !alreadyWatched {
            history.insert(HistoryItem(title: title, season: season, episode: episode, episodeName: episodeName,
                                       watchedAt: .now), at: 0)
            if history.count > 500 { history.removeLast(history.count - 500) }
        }
        continueWatching.removeAll { $0.title.ref == title.ref }
        if let next {
            let item = ContinueItem(title: title, season: next.season, episode: next.number, episodeName: next.name,
                                    stillPath: next.stillPath,
                                    position: PlaybackPosition(seconds: 0, duration: Double(next.runtime ?? 0) * 60,
                                                               updatedAt: .now),
                                    isNext: true)
            continueWatching.insert(item, at: 0)
        }
        save()
    }

    public func setWatched(_ isWatched: Bool, _ title: TitleSummary, season: Int? = nil, episode: Int? = nil) {
        let key = Self.key(title.ref, season: season, episode: episode)
        if isWatched {
            watched.insert(key)
            positions[key] = nil
        } else {
            watched.remove(key)
        }
        save()
    }

    public func removeFromContinueWatching(_ ref: TitleRef) {
        continueWatching.removeAll { $0.title.ref == ref }
        save()
    }

    public func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        save()
    }

    public func clearHistory() {
        history.removeAll()
        save()
    }

    public func clearContinueWatching() {
        continueWatching.removeAll()
        save()
    }

    public func clearWatchlist() {
        watchlist.removeAll()
        save()
    }

    // MARK: Backup

    /// Everything the viewer has, as a JSON file they can keep or move to another Mac.
    public func backup() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    public struct RestoreSummary: Sendable {
        public var watchlist: Int
        public var progress: Int
        public var history: Int
    }

    /// Merges a backup into what's here: nothing is lost on either side, and where both have
    /// the same film or episode, the more recent position wins.
    @discardableResult
    public func restore(_ data: Data) throws -> RestoreSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let other = try decoder.decode(Snapshot.self, from: data)
        let known = Set(watchlist.map(\.ref))
        let newWatchlist = other.watchlist.filter { !known.contains($0.ref) }
        watchlist += newWatchlist
        var progress = 0
        for (key, position) in other.positions where (positions[key]?.updatedAt ?? .distantPast) < position.updatedAt {
            positions[key] = position
            progress += 1
        }
        watched.formUnion(other.watched)
        let historyIDs = Set(history.map(\.id))
        let newHistory = other.history.filter { !historyIDs.contains($0.id) }
        history = (history + newHistory).sorted { $0.watchedAt > $1.watchedAt }
        var items = Dictionary(continueWatching.map { ($0.title.ref, $0) }, uniquingKeysWith: { a, _ in a })
        for item in other.continueWatching where (items[item.title.ref]?.position.updatedAt ?? .distantPast) < item.position.updatedAt {
            items[item.title.ref] = item
        }
        continueWatching = items.values.sorted { $0.position.updatedAt > $1.position.updatedAt }
        save()
        return RestoreSummary(watchlist: newWatchlist.count, progress: progress, history: newHistory.count)
    }

    private var snapshot: Snapshot {
        Snapshot(watchlist: watchlist, continueWatching: continueWatching, history: history,
                 positions: positions, watched: watched)
    }

    // MARK: Saving

    /// Written off the main thread; frequent progress updates are batched.
    private func save(soon: Bool = false) {
        guard let file else { return }
        let snapshot = Snapshot(watchlist: watchlist, continueWatching: continueWatching, history: history,
                                positions: positions, watched: watched)
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            if soon { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Before quitting: whatever is pending, written now.
    public func flush() {
        guard let file else { return }
        saveTask?.cancel()
        let snapshot = Snapshot(watchlist: watchlist, continueWatching: continueWatching, history: history,
                                positions: positions, watched: watched)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
