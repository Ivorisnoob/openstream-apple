import Foundation

/// How one source is getting on with a search.
public enum SourceStatus: Hashable, Sendable {
    case waiting
    case searching
    case found(Int)
    case nothing
    case failed(String)
    /// A fallback source that wasn't asked because the others found streams.
    case skipped

    public var isDone: Bool {
        switch self {
        case .waiting, .searching: false
        default: true
        }
    }
}

public struct SearchUpdate: Sendable {
    public var providerID: String
    public var status: SourceStatus
    public var sources: [StreamSource]
}

/// Asks every enabled source at once and reports each as it answers, so the player can start
/// on the first good stream while slower sources are still looking.
///
/// Fallback sources (web players, which load whole pages) wait until the direct ones have
/// found nothing, or nothing after eight seconds. Each source gets 25 seconds.
public final class StreamFinder: Sendable {
    public let providers: [any StreamProvider]
    private let cache = ResolvedStreamCache()

    public init(providers: [any StreamProvider]) {
        self.providers = providers
    }

    static let perSourceLimit: Duration = .seconds(25)
    /// Web players load whole pages a few at a time, so their limit covers waiting their turn.
    static let fallbackLimit: Duration = .seconds(60)
    static let fallbackDelay: Duration = .seconds(8)

    /// The last complete search for this episode, if it found something in the last ten minutes.
    /// Links from sources expire, which is why the window is short and memory only.
    public func cached(_ identity: MediaIdentity) async -> [StreamSource]? {
        await cache.sources(for: cacheKey(identity))
    }

    public func forget(_ identity: MediaIdentity) async {
        await cache.remove(cacheKey(identity))
    }

    /// Every source, the fallbacks only when needed. With `only`, just those sources, all at once:
    /// asked when every stream found so far has failed to play.
    public func search(_ identity: MediaIdentity, only: Set<String>? = nil) -> AsyncStream<SearchUpdate> {
        let providers = only.map { ids in self.providers.filter { ids.contains($0.id) }.map { $0.asking() } } ?? self.providers
        let cache = self.cache
        let key = only == nil ? cacheKey(identity) : cacheKey(identity) + "|more"
        return AsyncStream { continuation in
            let task = Task {
                let direct = providers.filter { !$0.isFallback }
                let fallback = providers.filter(\.isFallback)
                for provider in providers {
                    continuation.yield(SearchUpdate(providerID: provider.id, status: provider.isFallback ? .waiting : .searching, sources: []))
                }
                var all: [StreamSource] = []
                var finishedAll = true
                await withTaskGroup(of: SearchUpdate?.self) { group in
                    for provider in direct {
                        group.addTask { await Self.run(provider, identity) }
                    }
                    let fallbackTimer = !fallback.isEmpty
                    if fallbackTimer {
                        group.addTask {
                            try? await Task.sleep(for: Self.fallbackDelay)
                            return nil
                        }
                    }
                    var directLeft = direct.count
                    var startedFallback = fallback.isEmpty
                    func startFallback() {
                        guard !startedFallback else { return }
                        startedFallback = true
                        for provider in fallback {
                            continuation.yield(SearchUpdate(providerID: provider.id, status: .searching, sources: []))
                            group.addTask { await Self.run(provider, identity) }
                        }
                    }
                    if direct.isEmpty { startFallback() }
                    for await update in group {
                        guard let update else {
                            if all.isEmpty { startFallback() }
                            continue
                        }
                        if Task.isCancelled { finishedAll = false; break }
                        all += update.sources
                        continuation.yield(update)
                        if direct.contains(where: { $0.id == update.providerID }) {
                            directLeft -= 1
                            if directLeft == 0, all.isEmpty { startFallback() }
                        }
                    }
                    if !startedFallback {
                        for provider in fallback {
                            continuation.yield(SearchUpdate(providerID: provider.id, status: .skipped, sources: []))
                        }
                    }
                }
                if finishedAll, !Task.isCancelled, !all.isEmpty { await cache.store(all, for: key) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ provider: any StreamProvider, _ identity: MediaIdentity) async -> SearchUpdate {
        let result = await withTaskGroup(of: Result<[StreamSource], any Error>?.self) { group in
            group.addTask {
                do { return .success(try await provider.resolve(identity)) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: provider.isFallback || provider is Asked ? fallbackLimit : perSourceLimit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(ProviderError.timedOut)
        }
        switch result {
        case .success(let sources):
            return SearchUpdate(providerID: provider.id, status: sources.isEmpty ? .nothing : .found(sources.count),
                                sources: sources)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? (error as? URLError).map { _ in "Couldn't connect" } ?? "Failed"
            return SearchUpdate(providerID: provider.id, status: .failed(message), sources: [])
        }
    }

    private func cacheKey(_ identity: MediaIdentity) -> String {
        identity.key + "|" + providers.map(\.id).joined(separator: ",")
    }

    /// Best first: streams AVFoundation surely opens (HLS, MP4), then links that don't say, then
    /// formats it can't open; within each, quality (an unlabelled stream counts as
    /// 720p, since most are adaptive), then the viewer's order of sources.
    /// `audio` puts streams the viewer prefers (original or dubbed) ahead within the same
    /// playability; `maxQuality` treats anything above it as that quality, so a 4K stream doesn't
    /// win over 1080p for someone who capped at 1080p.
    public static func rank(_ sources: [StreamSource], order: [String], audio: StreamAudio? = nil,
                            maxQuality: StreamQuality? = nil) -> [StreamSource] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func score(_ quality: StreamQuality) -> Int {
            let value = quality == .unknown ? StreamQuality.q720.rawValue : quality.rawValue
            return min(value, maxQuality?.rawValue ?? .max)
        }
        func matches(_ source: StreamSource) -> Bool {
            guard let audio else { return false }
            if audio == .dub { return source.audio == .dub || source.audio == .multi }
            return source.audio != .dub
        }
        return sources.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.playabilityRank != y.playabilityRank { return x.playabilityRank > y.playabilityRank }
            if matches(x) != matches(y) { return matches(x) }
            if score(x.quality) != score(y.quality) { return score(x.quality) > score(y.quality) }
            let px = position[x.providerID] ?? .max, py = position[y.providerID] ?? .max
            if px != py { return px < py }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// A provider asked directly, not held back as a fallback.
private struct Asked: StreamProvider {
    let base: any StreamProvider
    var id: String { base.id }
    var name: String { base.name }
    var isFallback: Bool { false }
    func resolve(_ identity: MediaIdentity) async throws -> [StreamSource] { try await base.resolve(identity) }
}

extension StreamProvider {
    func asking() -> any StreamProvider { Asked(base: self) }
}

actor ResolvedStreamCache {
    private var entries: [String: (sources: [StreamSource], at: Date)] = [:]
    private let lifetime: TimeInterval = 600

    func sources(for key: String) -> [StreamSource]? {
        guard let entry = entries[key] else { return nil }
        guard Date.now.timeIntervalSince(entry.at) < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.sources
    }

    func store(_ sources: [StreamSource], for key: String) {
        entries = entries.filter { Date.now.timeIntervalSince($0.value.at) < lifetime }
        entries[key] = (sources, .now)
    }

    func remove(_ key: String) {
        entries[key] = nil
    }
}
