import AVFoundation
import Foundation
import OpenStreamCore

/// The AVURLAsset for a stream: its headers and cookies attached, and DASH turned into HLS.
nonisolated enum StreamAssets {
    static func asset(for source: StreamSource) async throws -> AVURLAsset {
        if source.isDASH { return try await DashGateway.shared.asset(for: source) }
        if source.isHLS, let repaired = await DashGateway.shared.repairedAsset(for: source) { return repaired }
        return AVURLAsset(url: source.url, options: options(for: source.headers, url: source.url))
    }

    /// Headers go in `AVURLAssetHTTPHeaderFieldsKey` (not public, but long relied on), the user
    /// agent in its own key, and cookies as real cookies so CDNs that check them get them.
    static func options(for headers: [String: String], url: URL) -> [String: Any] {
        var headers = headers
        let agent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }
        if let agent { headers[agent.key] = nil }
        var options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPUserAgentKey: agent?.value ?? SourceHTTP.userAgent,
        ]
        if let cookie = headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value {
            options[AVURLAssetHTTPCookiesKey] = cookies(cookie, for: url)
        }
        return options
    }

    /// "a=1; b=2" as cookies for the stream's site and its subdomains.
    static func cookies(_ header: String, for url: URL) -> [HTTPCookie] {
        guard let host = url.host() else { return [] }
        let domain = "." + host.split(separator: ".").suffix(2).joined(separator: ".")
        return header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return HTTPCookie(properties: [.name: parts[0], .value: parts[1], .domain: domain, .path: "/", .secure: "TRUE"])
        }
    }
}

/// Plays DASH by describing it as HLS. The manifest is fetched and rewritten here; AVPlayer asks
/// for the playlists and each initialization segment under a private URL scheme, which this
/// resource loader answers (on its own queue, hence nonisolated), and fetches the media segments
/// from the CDN itself.
nonisolated final class DashGateway: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = DashGateway()
    static let scheme = "openstream-dash"

    private struct Entry {
        var manifest: DashManifest?
        /// A repaired HLS master playlist, served as is.
        var master: String?
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "openstream.dash")

    func asset(for source: StreamSource) async throws -> AVURLAsset {
        var request = URLRequest(url: source.url, timeoutInterval: 15)
        source.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw URLError(.badServerResponse)
        }
        let manifest = try DashManifest.parse(data, url: response.url ?? source.url)
        let id = UUID().uuidString.lowercased()
        lock.withLock {
            // Only the last few streams are kept; each one is a whole film's segment list.
            if entries.count > 8 { entries.removeAll() }
            entries[id] = Entry(manifest: manifest, master: nil, headers: source.headers)
        }
        let master = URL(string: "\(Self.scheme)://\(id)/master.m3u8")!
        let asset = AVURLAsset(url: master, options: StreamAssets.options(for: source.headers, url: source.url))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// An HLS stream whose master playlist needs repair (see `HLSMaster`) is served from here;
    /// nil means it's fine, or couldn't be read, and should be opened directly.
    func repairedAsset(for source: StreamSource) async -> AVURLAsset? {
        var request = URLRequest(url: source.url, timeoutInterval: 8)
        source.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count < 2_000_000,
              let master = HLSMaster.clean(String(decoding: data, as: UTF8.self), base: response.url ?? source.url)
        else { return nil }
        let id = UUID().uuidString.lowercased()
        lock.withLock {
            if entries.count > 8 { entries.removeAll() }
            entries[id] = Entry(manifest: nil, master: master, headers: source.headers)
        }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://\(id)/master.m3u8")!,
                               options: StreamAssets.options(for: source.headers, url: source.url))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme, let id = url.host(),
              let entry = lock.withLock({ entries[id] })
        else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts == ["master.m3u8"], let master = entry.master {
            respond(loadingRequest, Data(master.utf8), type: "public.m3u-playlist")
            return true
        }
        guard let manifest = entry.manifest else { return false }
        if parts == ["master.m3u8"] {
            respond(loadingRequest, Data(DashToHLS.master(manifest, scheme: Self.scheme, id: id).utf8), type: "public.m3u-playlist")
            return true
        }
        if parts.count == 1, parts[0].hasSuffix(".m3u8"),
           let representation = manifest.representations.first(where: { $0.id + ".m3u8" == parts[0] }) {
            respond(loadingRequest, Data(DashToHLS.media(representation, scheme: Self.scheme, id: id).utf8), type: "public.m3u-playlist")
            return true
        }
        if parts.count == 2, parts[1] == "init.mp4",
           let representation = manifest.representations.first(where: { $0.id == parts[0] }) {
            var request = URLRequest(url: representation.initialization, timeoutInterval: 15)
            entry.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let data, error == nil,
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
                else {
                    loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                    return
                }
                self?.respond(loadingRequest, DashToHLS.retagHEVC(data), type: "public.mpeg-4")
            }
            task.resume()
            return true
        }
        return false
    }

    /// Answers a loading request, honouring the byte range AVFoundation asked for.
    private func respond(_ request: AVAssetResourceLoadingRequest, _ data: Data, type: String) {
        if let info = request.contentInformationRequest {
            info.contentType = type
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let start = Int(dataRequest.currentOffset)
            let length = dataRequest.requestsAllDataToEndOfResource ? data.count - start : dataRequest.requestedLength
            let end = min(data.count, start + max(0, length))
            if start < end { dataRequest.respond(with: data.subdata(in: start..<end)) }
        }
        request.finishLoading()
    }
}
