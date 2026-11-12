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

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let catalogFile: URL
    @ObservationIgnored private let sniffer = WebPlayerSniffer()

    private enum Keys {
        static let order = "openstream.sources.order"
        static let disabled = "openstream.sources.disabled"
        static let enabledSeen = "openstream.sources.seen"
        static let refreshed = "openstream.sources.refreshedAt"
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
