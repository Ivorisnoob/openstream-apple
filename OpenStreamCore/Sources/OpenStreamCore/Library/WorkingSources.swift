import Foundation
import Observation

/// The source that last played each title, so pressing Play asks it first, alone, and the
/// rest only when it has nothing: the same title tends to stay on the same source, and one source
/// answers far sooner than all of them. Kept for a film or a whole series, as OpenStream for
/// Android keeps it, for the most recent `limit` titles.
@MainActor
@Observable
public final class WorkingSources {
    struct Entry: Codable, Sendable {
        var provider: String
        var at: Date
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let limit: Int

    public init(file: URL?, limit: Int = 200) {
        self.file = file
        self.limit = limit
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    public var count: Int { entries.count }

    public func provider(for ref: TitleRef) -> String? {
        entries[ref.description]?.provider
    }

    /// A stream from `providerID` played properly for this title.
    public func record(_ providerID: String, for ref: TitleRef) {
        entries[ref.description] = Entry(provider: providerID, at: .now)
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.at < $1.value.at }.prefix(entries.count - limit).map(\.key)
            oldest.forEach { entries[$0] = nil }
        }
        save()
    }

    /// The remembered source had nothing this time.
    public func forget(_ ref: TitleRef) {
        guard entries[ref.description] != nil else { return }
        entries[ref.description] = nil
        save()
    }

    public func removeAll() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let file else { return }
        let snapshot = entries
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
