import Foundation

/// Vidking's API: a per-title seed, then an encrypted source list (`enc=2`) for one route
/// ("cdn", "hdmovie"…). Prefers the master playlist so quality switches inside the player.
public struct VidkingProvider: StreamProvider {
    public let id: String
    public let name: String
    public let isFallback = false
    let endpoint: String
    let language: String?
    let qualityFilter: String?

    static let base = URL(string: "https://api.speedracelight.com")!
    static let origin = "https://www.vidking.net"
    static var headers: [String: String] {
        ["User-Agent": SourceHTTP.userAgent, "Referer": origin + "/", "Origin": origin]
    }

    public init(id: String, name: String, endpoint: String, language: String?, qualityFilter: String?) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.language = language
        self.qualityFilter = qualityFilter
    }

    struct SeedResponse: Decodable { var seed: String }
    struct Payload: Decodable {
        struct Source: Decodable { var url: String?; var quality: String?; var type: String? }
        struct Subtitle: Decodable { var url: String?; var lang: String?; var label: String? }
        var sources: [Source]?
        var subtitles: [Subtitle]?
        var playlist: String?
    }

    public func resolve(_ identity: MediaIdentity) async throws -> [StreamSource] {
        var seedURL = URLComponents(url: Self.base.appending(path: "seed"), resolvingAgainstBaseURL: false)!
        seedURL.queryItems = [URLQueryItem(name: "mediaId", value: String(identity.ref.id))]
        guard let seedData = try await SourceHTTP.get(seedURL.url!),
              let seed = try? JSONDecoder().decode(SeedResponse.self, from: seedData).seed
        else { throw ProviderError.unavailable }

        var components = URLComponents(url: Self.base.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: identity.title),
            URLQueryItem(name: "mediaType", value: identity.ref.kind.rawValue),
            URLQueryItem(name: "year", value: identity.year.map(String.init) ?? ""),
            URLQueryItem(name: "episodeId", value: String(identity.episode)),
            URLQueryItem(name: "seasonId", value: String(identity.season)),
            URLQueryItem(name: "tmdbId", value: String(identity.ref.id)),
            URLQueryItem(name: "imdbId", value: identity.imdbID ?? ""),
            URLQueryItem(name: "enc", value: "2"),
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "_t", value: String(Int(Date.now.timeIntervalSince1970 * 1000))),
        ] + (language.map { [URLQueryItem(name: "language", value: $0)] } ?? [])
        guard let body = try await SourceHTTP.get(components.url!, headers: Self.headers),
              let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let plain = VidkingCipher.decrypt(text, seed: seed, mediaID: identity.ref.id),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(plain.utf8))
        else { throw ProviderError.unreadable }
        return sources(from: payload)
    }

    func sources(from payload: Payload) -> [StreamSource] {
        let subtitles = (payload.subtitles ?? []).compactMap { item -> StreamSubtitle? in
            guard let link = item.url, let url = URL(string: link) else { return nil }
            return StreamSubtitle(url: url, label: item.label ?? item.lang ?? "Subtitles", language: item.lang)
        }
        let audioLanguage = (qualityFilter ?? language)?.capitalized
        let all = payload.sources ?? []
        // Language routes pick one rendition by label, so they keep the per-source list.
        if qualityFilter == nil, let master = payload.playlist, master.hasPrefix("http"),
           let url = URL(string: master), !all.isEmpty {
            return [StreamSource(
                id: "\(id)-master", providerID: id, providerName: name, name: name, url: url,
                quality: all.map { StreamQuality.parse($0.quality) }.max() ?? .unknown,
                audio: StreamAudio.parse(language), audioLanguage: audioLanguage,
                headers: Self.headers, subtitles: subtitles, isHLSHint: true,
                audioLanguages: AudioLanguages.detect(language ?? "")
            )]
        }
        return all.compactMap { source in
            guard let link = source.url, link.hasPrefix("http"), let url = URL(string: link) else { return nil }
            if let qualityFilter, source.quality?.caseInsensitiveCompare(qualityFilter) != .orderedSame { return nil }
            let descriptor = [source.quality, source.type, language, qualityFilter].compactMap { $0 }.joined(separator: " ")
            return StreamSource(
                id: "\(id)-\(stableHash(link))", providerID: id, providerName: name, name: name, url: url,
                quality: StreamQuality.parse(source.quality), audio: StreamAudio.parse(descriptor),
                audioLanguage: audioLanguage, headers: Self.headers, subtitles: subtitles,
                audioLanguages: AudioLanguages.detect([language, qualityFilter].compactMap { $0 }.joined(separator: " "))
            )
        }
    }
}

/// Vidking's payload cipher: a keystream from the seed and the TMDB id, XORed over the
/// URL-safe base64 body, which must then start with "mvm1".
enum VidkingCipher {
    private static let schedule: [UInt32] = [
        1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
        3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
    ]
    private static let golden: UInt32 = 2654435769
    private static let size = 61
    private static let magic: [UInt8] = Array("mvm1".utf8)

    static func decrypt(_ encoded: String, seed: String, mediaID: Int) -> String? {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        let stream = keyStream(seed: seed, mediaID: mediaID, count: data.count)
        let plain = zip(data, stream).map { $0 ^ $1 }
        guard plain.count >= 4, Array(plain.prefix(4)) == magic else { return nil }
        return String(decoding: plain.dropFirst(4), as: UTF8.self)
    }

    /// Also encrypts: the cipher is a plain XOR, which the tests use to build fixtures.
    static func keyStream(seed: String, mediaID: Int, count: Int) -> [UInt8] {
        // n(n+1) is always even, so the reference implementation's other branch never runs.
        var values = [UInt32?](repeating: nil, count: size)
        var acc = mix(fnv(seed) ^ mix(UInt32(truncatingIfNeeded: mediaID) ^ golden))
        for round in 0..<8 {
            let index = Int(acc % UInt32(size))
            acc = rotl(acc &+ golden, 7 + (round & 7))
            values[index] = acc ^ mix(acc)
            acc = mix(acc &+ UInt32(index))
        }
        acc = mix(acc ^ 0xA5A5A5A5)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(count + 3)
        var block: UInt32 = 0
        while bytes.count < count {
            let index = Int(acc % UInt32(size))
            let stored = values[index]
            let derived = (stored ?? 0) ^ (golden &* (block &+ 1))
            let combined = stored != nil ? ((acc ^ derived) | (acc & derived)) : (acc ^ derived)
            let rotated = rotl(combined &+ acc, index & 31) ^ rotl(acc, (index * 7) & 31)
            acc = mix(rotated &+ golden)
            values[index] = acc
            block &+= 1
            for shift in 0..<4 where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: acc >> (shift * 8)))
            }
        }
        return bytes
    }

    private static func mix(_ input: UInt32) -> UInt32 {
        var v = input
        v ^= v >> 16
        v = v &* 2246822507
        v ^= v >> 13
        v = v &* 3266489909
        v ^= v >> 16
        return v
    }

    private static func fnv(_ seed: String) -> UInt32 {
        var v: UInt32 = 2166136261
        for unit in seed.utf16 { v = (v ^ UInt32(unit)) &* 16777619 }
        return mix(v)
    }

    private static func rotl(_ v: UInt32, _ bits: Int) -> UInt32 {
        let b = UInt32(bits & 31)
        return b == 0 ? v : (v << b) | (v >> (32 - b))
    }
}
