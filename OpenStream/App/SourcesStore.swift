import Foundation
import Observation
import OpenStreamCore
import SwiftUI

/// The catalog of sources, which of them are on, and the order they're asked in.
///
/// The app ships the catalog and refreshes it from GitHub once a day; the newest copy is kept in
/// Application Support so a launch offline still has it. The viewer's choices live in UserDefaults.
@Observable
final class SourcesStore {
    private(set) var catalog: Catalog
    private(set) var order: [String]
    private(set) var disabled: Set<String>
    private(set) var finder: StreamFinder
    private(set) var isRefreshing = false
    /// How each source has done lately, kept between launches.
    private(set) var health: [String: Health] = [:]

    struct Health: Codable, Equatable {
        var failuresInARow = 0
        var lastFailure: Date?
        var lastFound: Date?
    }

    /// Five failures in a row (errors, not "doesn't have it") rest a source for ten minutes, as
    /// OpenStream for Android does, so a dead site stops slowing every search.
    static let restAfter = 5
    static let restFor: TimeInterval = 600

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let catalogFile: URL
    @ObservationIgnored private let sniffer = WebPlayerSniffer()

    private enum Keys {
        static let order = "openstream.sources.order"
        static let disabled = "openstream.sources.disabled"
        static let enabledSeen = "openstream.sources.seen"
        static let refreshed = "openstream.sources.refreshedAt"
        static let health = "openstream.sources.health"
    }

    init(folder: URL) {
        catalogFile = folder.appending(path: "catalog.json")
        var catalog = Catalog.bundled
        if let data = try? Data(contentsOf: catalogFile), let saved = try? JSONDecoder().decode(Catalog.self, from: data) {
            catalog = catalog.merged(with: saved)
        }
        self.catalog = catalog
        order = defaults.stringArray(forKey: Keys.order) ?? []
        disabled = Set(defaults.stringArray(forKey: Keys.disabled) ?? [])
        finder = StreamFinder(providers: [])
        if let data = defaults.data(forKey: Keys.health), let saved = try? JSONDecoder().decode([String: Health].self, from: data) {
            health = saved
        }
        adoptNewEntries()
        rebuild()
    }

    /// Supported entries in the viewer's order; unsupported engines (the anime sites) after them.
    var entries: [Catalog.Entry] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return catalog.extensions.sorted {
            if $0.isSupported != $1.isSupported { return $0.isSupported }
            return (position[$0.id] ?? .max, $0.engine.priority ?? .max) < (position[$1.id] ?? .max, $1.engine.priority ?? .max)
        }
    }

    func isEnabled(_ entry: Catalog.Entry) -> Bool {
        entry.isSupported && !disabled.contains(entry.id)
    }

    var enabledCount: Int { entries.filter(isEnabled).count }

    func setEnabled(_ enabled: Bool, _ entry: Catalog.Entry) {
        if enabled { disabled.remove(entry.id) } else { disabled.insert(entry.id) }
        defaults.set(Array(disabled), forKey: Keys.disabled)
        rebuild()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var ids = entries.filter(\.isSupported).map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        order = ids
        defaults.set(order, forKey: Keys.order)
        rebuild()
    }

    var resting: Set<String> {
        Set(health.filter { $0.value.failuresInARow >= Self.restAfter
            && ($0.value.lastFailure.map { Date.now.timeIntervalSince($0) < Self.restFor } ?? false) }.map(\.key))
    }

    /// A search's answer from one source.
    func record(_ providerID: String, _ status: SourceStatus) {
        var entry = health[providerID] ?? Health()
        switch status {
        case .found:
            entry.failuresInARow = 0
            entry.lastFound = .now
        case .failed:
            entry.failuresInARow += 1
            entry.lastFailure = .now
        case .nothing:
            // Answering without the title is a working source.
            entry.failuresInARow = 0
        default:
            return
        }
        guard entry != health[providerID] else { return }
        health[providerID] = entry
        if let data = try? JSONEncoder().encode(health) { defaults.set(data, forKey: Keys.health) }
    }

    /// What the Sources page says about a source's recent record.
    func summary(_ providerID: String) -> String? {
        guard let entry = health[providerID] else { return nil }
        if resting.contains(providerID) { return "Resting: failed \(entry.failuresInARow) times in a row" }
        if entry.failuresInARow >= 2 { return "Failed the last \(entry.failuresInARow) times" }
        if let found = entry.lastFound { return "Last found streams " + found.formatted(.relative(presentation: .named)) }
        return nil
    }

    func name(of providerID: String) -> String {
        catalog.extensions.first { $0.id == providerID }?.name ?? providerID
    }

    /// The order used to break ties between equally good streams.
    var rankingOrder: [String] { entries.filter(isEnabled).map(\.id) }

    /// Fetches the published catalog at most once a day, or now when asked.
    func refresh(force: Bool = false) async {
        if !force, let last = defaults.object(forKey: Keys.refreshed) as? Date, Date.now.timeIntervalSince(last) < 86400 {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let (data, response) = try? await URLSession.shared.data(from: Catalog.remoteURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let remote = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return }
        try? FileManager.default.createDirectory(at: catalogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogFile, options: .atomic)
        defaults.set(Date.now, forKey: Keys.refreshed)
        catalog = Catalog.bundled.merged(with: remote)
        adoptNewEntries()
        rebuild()
    }

    /// Entries seen for the first time start on or off as the catalog says, except Stremio
    /// add-ons, which start on here: the Mac can't run every engine Android can, and the add-ons
    /// are what most often has a stream AVFoundation plays.
    private func adoptNewEntries() {
        var seen = Set(defaults.stringArray(forKey: Keys.enabledSeen) ?? [])
        for entry in catalog.extensions where !seen.contains(entry.id) {
            seen.insert(entry.id)
            if entry.installedByDefault == false, entry.engine.type != "stremio" { disabled.insert(entry.id) }
        }
        defaults.set(Array(seen), forKey: Keys.enabledSeen)
        defaults.set(Array(disabled), forKey: Keys.disabled)
    }

    private func rebuild() {
        let providers = entries.filter(isEnabled).compactMap { $0.provider(sniffer: sniffer) }
        finder = StreamFinder(providers: providers)
    }
}
