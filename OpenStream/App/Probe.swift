#if DEBUG
import AVFoundation
import Foundation
import OpenStreamCore

/// Debug builds only: checks the parts that can't be seen from a terminal, then quits.
///
///     OPENSTREAM_PROBE=movie:27205 Debug/OpenStream.app/Contents/MacOS/OpenStream
///     OPENSTREAM_PROBE=tv:1396:1:1 …
///
/// Searches every enabled source for the title, prints what each found, then opens the best
/// streams with AVPlayer and reports whether they reach `readyToPlay` and advance.
enum Probe {
    static func runIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["OPENSTREAM_PROBE"] else { return }
        Task { @MainActor in
            await run(spec)
            exit(0)
        }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    @MainActor
    private static func run(_ spec: String) async {
        if spec.hasPrefix("sniff "), let page = URL(string: String(spec.dropFirst(6))) {
            let found = await WebPlayerSniffer().streams(at: page, timeout: .seconds(25))
            log("probe: sniffed \(found.count): \(found.map(\.url.absoluteString))")
            return
        }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2, let kind = MediaKind(rawValue: parts[0]), let id = Int(parts[1]) else {
            log("probe: bad spec \(spec)")
            return
        }
        let tmdb = TMDB(apiKey: Secrets.tmdbKey, cacheDirectory: nil)
        let ref = TitleRef(kind: kind, id: id)
        guard let details = try? await tmdb.details(ref) else {
            log("probe: TMDB details failed (key set: \(!Secrets.tmdbKey.isEmpty))")
            return
        }
        log("probe: \(details.summary.name) imdb=\(details.imdbID ?? "-") logo=\(details.logoPath != nil)")
        let identity = MediaIdentity(ref: ref, imdbID: details.imdbID, title: details.summary.name,
                                     originalTitle: details.originalName, year: details.summary.year,
                                     season: parts.count > 2 ? Int(parts[2]) ?? 1 : 1,
                                     episode: parts.count > 3 ? Int(parts[3]) ?? 1 : 1)
        let store = SourcesStore(folder: FileManager.default.temporaryDirectory.appending(path: "openstream-probe"))
        let only = ProcessInfo.processInfo.environment["OPENSTREAM_PROBE_SOURCES"].map { Set($0.split(separator: ",").map(String.init)) }
        // Every supported source, on or off, unless a list is given.
        let providers = store.catalog.extensions.filter(\.isSupported)
            .compactMap { $0.provider(sniffer: WebPlayerSniffer()) }
            .filter { only?.contains($0.id) ?? true }
        let finder = StreamFinder(providers: providers)
        log("probe: asking \(providers.count) sources")
        let started = Date.now
        var all: [StreamSource] = []
        for await update in finder.search(identity) {
            let elapsed = Date.now.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
            switch update.status {
            case .searching, .waiting: continue
            default: break
            }
            log("probe: [\(elapsed)s] \(update.providerID): \(update.status)")
            for source in update.sources.prefix(3) {
                log("probe:     \(source.quality.label) \(source.container) \(source.name.prefix(50)) \(source.url.host() ?? "")")
            }
            all += update.sources
        }
        let ranked = StreamFinder.rank(all, order: store.rankingOrder).filter(\.isLikelyPlayable)
        log("probe: \(all.count) streams, \(ranked.count) likely playable")
        for source in ranked.prefix(4) {
            let result = await tryPlaying(source)
            log("probe: play \(source.providerID) \(source.quality.label) \(source.container) -> \(result)")
        }
    }

    @MainActor
    private static func tryPlaying(_ source: StreamSource) async -> String {
        var headers = source.headers
        let agent = headers.removeValue(forKey: "User-Agent") ?? SourceHTTP.userAgent
        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers,
                                                          AVURLAssetHTTPUserAgentKey: agent])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if item.status == .failed {
                return "failed: \(item.error?.localizedDescription ?? "?") \((item.error as NSError?)?.underlyingErrors.first?.localizedDescription ?? "")"
            }
            let seconds = CMTimeGetSeconds(item.currentTime())
            if item.status == .readyToPlay, seconds > 1.5 {
                let size = item.presentationSize
                player.pause()
                return "playing (t=\(Int(seconds))s, \(Int(size.width))x\(Int(size.height)), duration \(Int(CMTimeGetSeconds(item.duration)))s)"
            }
        }
        player.pause()
        return "no progress in 20s (status \(item.status.rawValue))"
    }
}
#endif
