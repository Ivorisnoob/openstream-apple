import Compression
import Foundation

/// One line of subtitles and when it shows.
public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

/// A subtitle file the viewer can pick: from the stream's source or from OpenSubtitles.
public struct SubtitleOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var url: URL
    /// "English", "Español".
    public var language: String
    /// ISO 639-1 when known ("en").
    public var languageCode: String?
    /// Where it came from: the source's name or "OpenSubtitles".
    public var origin: String
    /// The release it was timed for, which says how well it will line up.
    public var release: String?
    public var isHearingImpaired: Bool
    public var headers: [String: String]

    public init(id: String, url: URL, language: String, languageCode: String?, origin: String, release: String? = nil,
                isHearingImpaired: Bool = false, headers: [String: String] = [:]) {
        self.id = id
        self.url = url
        self.language = language
        self.languageCode = languageCode
        self.origin = origin
        self.release = release
        self.isHearingImpaired = isHearingImpaired
        self.headers = headers
    }

    /// "English", "English (SDH)".
    public var label: String { language + (isHearingImpaired ? " (SDH)" : "") }
}

public enum Subtitles {
    /// The language name for a code in the viewer's own language ("en" → "English").
    public static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let short = Locale.LanguageCode(code).identifier
        return Locale.current.localizedString(forLanguageCode: short)?.capitalized(with: .current)
    }

    /// Downloads, unzips, decodes and parses a subtitle file.
    public static func load(_ option: SubtitleOption) async throws -> [SubtitleCue] {
        var request = URLRequest(url: option.url, timeoutInterval: 20)
        request.setValue(option.origin == OpenSubtitles.name ? OpenSubtitles.userAgent : SourceHTTP.userAgent,
                         forHTTPHeaderField: "User-Agent")
        option.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await SourceHTTP.session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw ProviderError.unreadable
        }
        let cues = parse(text(gunzipIfNeeded(data)))
        guard !cues.isEmpty else { throw ProviderError.unreadable }
        return cues
    }

    // MARK: Parsing

    /// SubRip and WebVTT: blocks of a time range followed by text, separated by blank lines.
    /// Styling tags are dropped; line breaks are kept. Ads that subtitle sites add are removed.
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timeIndex + 1)...]
                .map(stripTags)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty, end > start, !isAd(body) else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345", "01:02.345" or "1:02:03.4".
    static func time(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        let numbers = parts.dropLast().compactMap { Double($0) }
        guard numbers.count == parts.count - 1 else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 } * 60 + seconds
    }

    private static func stripTags(_ line: String) -> String {
        line.replacing(/<[^>]*>/, with: "").replacing(/\{\\[^}]*\}/, with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func isAd(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["opensubtitles", "osdb.link", "subscene", "addic7ed", "vip member", "advertise your product"]
            .contains { lower.contains($0) }
    }

    /// UTF-8 when it is; otherwise the Windows code page most subtitle files use.
    static func text(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Gzip

    /// OpenSubtitles serves `.gz`; Compression's zlib is raw DEFLATE, so the gzip header is read
    /// here and the body inflated.
    static func gunzipIfNeeded(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return data }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0, index + 2 <= bytes.count {
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return data }
        let body = Data(bytes[index..<(bytes.count - 8)])
        let size = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        let capacity = max(size, body.count * 8, 1024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            body.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return data }
        return output.prefix(written)
    }
}

/// OpenSubtitles' public REST search: no key, only a user agent, looked up by IMDb id. A legacy
/// endpoint it still serves but no longer documents, as OpenStream for Android uses it.
public enum OpenSubtitles {
    public static let name = "OpenSubtitles"
    static let userAgent = "TemporaryUserAgent"

    /// English first, then the viewer's language, then the rest by name; the most downloaded
    /// few per language.
    public static func search(_ identity: MediaIdentity, preferred: [String]) async -> [SubtitleOption] {
        guard let imdb = identity.imdbID?.replacingOccurrences(of: "tt", with: ""), let number = Int(imdb) else { return [] }
        // Path segments must be in alphabetical order or the API refuses the query.
        let base = identity.ref.kind == .movie
            ? "imdbid-\(number)"
            : "episode-\(identity.episode)/imdbid-\(number)/season-\(identity.season)"
        async let english = query("\(base)/sublanguageid-eng")
        async let all = query(base)
        let results = await english + all
        var seen = Set<String>()
        let unique = results.filter { seen.insert($0.id).inserted }
        let order = preferred + ["en"]
        let grouped = Dictionary(grouping: unique) { $0.languageCode ?? $0.language }
        return grouped.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? .max, ib = order.firstIndex(of: b.key) ?? .max
            if ia != ib { return ia < ib }
            return (a.value.first?.language ?? "") < (b.value.first?.language ?? "")
        }
        .flatMap { $0.value.prefix(4) }
    }

    private struct Result: Decodable {
        var IDSubtitleFile: String?
        var SubFormat: String?
        var LanguageName: String?
        var ISO639: String?
        var SubDownloadLink: String?
        var SubHearingImpaired: String?
        var SubDownloadsCnt: String?
        var MovieReleaseName: String?
    }

    private static func query(_ path: String) async -> [SubtitleOption] {
        guard let url = URL(string: "https://rest.opensubtitles.org/search/\(path)") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(userAgent, forHTTPHeaderField: "X-User-Agent")
        guard let (data, _) = try? await SourceHTTP.session.data(for: request),
              let results = try? JSONDecoder().decode([Result].self, from: data)
        else { return [] }
        return results
            .filter { ["srt", "vtt"].contains($0.SubFormat?.lowercased() ?? "") }
            .sorted { Int($0.SubDownloadsCnt ?? "") ?? 0 > Int($1.SubDownloadsCnt ?? "") ?? 0 }
            .compactMap { item in
                guard let id = item.IDSubtitleFile, let link = item.SubDownloadLink, let url = URL(string: link) else { return nil }
                return SubtitleOption(id: "os-\(id)", url: url,
                                      language: Subtitles.languageName(item.ISO639) ?? item.LanguageName ?? "Unknown",
                                      languageCode: item.ISO639, origin: name,
                                      release: item.MovieReleaseName?.trimmingCharacters(in: .whitespaces),
                                      isHearingImpaired: item.SubHearingImpaired == "1")
            }
    }
}
