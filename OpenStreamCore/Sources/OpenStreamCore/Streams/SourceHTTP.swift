import Foundation

/// Requests to stream sources. They look like Safari on a Mac, which is what the app's web player
/// and AVPlayer present too: some hosts tie a link to the browser that asked for it.
public enum SourceHTTP {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// No cache and no cookies: source answers go stale in minutes, and nothing a source sets
    /// should follow the viewer to another.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// The body of a 200; nil for 404, which many sources answer for titles they don't have.
    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data? {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        return data
    }

    /// Whether a link answers like a video: a 16-byte range request that comes back as media or
    /// an HLS playlist rather than an error page. Sources hand out links that are already dead.
    static func looksPlayable(_ source: StreamSource) async -> Bool {
        var request = URLRequest(url: source.url, timeoutInterval: 5)
        source.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return false }
        var head = Data()
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 16 { break }
            }
        } catch {
            return false
        }
        bytes.task.cancel()
        let start = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isHLS { return start.hasPrefix("#EXTM3U") }
        return !(start.hasPrefix("<") || start.hasPrefix("{"))
    }
}
