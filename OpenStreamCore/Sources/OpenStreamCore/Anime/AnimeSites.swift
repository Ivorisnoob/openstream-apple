import CommonCrypto
import Foundation

/// megaplay.buzz embeds, which Re:Anime and Anikoto play from: the embed page carries a
/// `data-id`, `/stream/getSourcesNew` answers `{enc, tracks}`, and `enc` is base64url AES-256-CBC
/// JSON with a fixed key and IV from megaplay's player script (key zero-padded to 32 bytes). The
/// CDN answers 403 without megaplay's Referer. As OpenStream for Android reads them; nothing here
/// is documented by megaplay.
///
/// Its `tcdn` server hides MPEG-TS segments behind a PNG header on an ad CDN, which AVFoundation
/// can't strip, so only `bcdn` streams are offered.
enum Megaplay {
    static let origin = "https://megaplay.buzz"
    private static let key = "i?LMTAx0Q6,:}50U"
    private static let iv = "W0;27ToaUpl_P%'c"

    static func stream(embed: URL, referer: String, providerID: String, providerName: String, label: String,
                       audio: StreamAudio) async -> StreamSource? {
        guard let page = try? await SourceHTTP.get(embed, headers: ["Referer": referer]).map({ String(decoding: $0, as: UTF8.self) }),
              let id = page.firstMatch(of: /data-id="(\d+)"/).map({ String($0.1) })
        else { return nil }
        let server = URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value
        guard let sources = URL(string: "\(origin)/stream/getSourcesNew?id=\(id)" + (server.map { "&s=\($0)" } ?? "")),
              let data = try? await SourceHTTP.get(sources, headers: ["X-Requested-With": "XMLHttpRequest", "Referer": embed.absoluteString]),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enc = response["enc"] as? String,
              let plain = decrypt(enc),
              let file = (try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])?["file"] as? String,
              file.hasPrefix("http"), let url = URL(string: file)
        else { return nil }
        let headers = ["Referer": origin + "/", "User-Agent": SourceHTTP.userAgent]
        // Which CDN a server lands on rotates and some refuse anything but megaplay's own player:
        // only playlists that load are offered.
        guard let playlist = try? await SourceHTTP.get(url, headers: headers).map({ String(decoding: $0, as: UTF8.self) }),
              playlist.hasPrefix("#EXTM3U")
        else { return nil }
        let best = playlist.matches(of: /RESOLUTION=\d+x(\d+)/).compactMap { Int($0.1) }.max()
        let subtitles = ((response["tracks"] as? [[String: Any]]) ?? []).compactMap { track -> StreamSubtitle? in
            guard track["kind"] as? String == "captions", let link = track["file"] as? String, let url = URL(string: link),
                  let label = track["label"] as? String
            else { return nil }
            let code = Locale.LanguageCode.isoLanguageCodes.first { Locale.current.localizedString(forLanguageCode: $0.identifier) == label }
            return StreamSubtitle(url: url, label: label, language: code?.identifier)
        }
        let dub = audio == .dub
        return StreamSource(
            id: "\(providerID)-\(stableHash(file))", providerID: providerID, providerName: providerName,
            name: "\(label) · \(dub ? "Dub" : "Sub")", url: url,
            quality: best.map { StreamQuality.parse("\($0)p") } ?? .unknown,
            audio: audio, audioLanguage: dub ? "English" : "Japanese",
            headers: headers, subtitles: subtitles, isHLSHint: true,
            audioLanguages: [dub ? "en" : "ja"]
        )
    }

    static func decrypt(_ encoded: String) -> String? {
        var text = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        var keyBytes = Array(key.utf8)
        keyBytes += [UInt8](repeating: 0, count: max(0, 32 - keyBytes.count))
        let ivBytes = Array(iv.utf8.prefix(16))
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = data.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes, 32, ivBytes, input.baseAddress, data.count, &output, output.count, &written)
        }
        guard status == kCCSuccess else { return nil }
        return String(decoding: output.prefix(written), as: UTF8.self)
    }
}

/// An anime site: the TMDB episode is mapped to its AniList episode first (non-anime maps to
/// nothing, so the source quietly has nothing), then the site is asked for sub and dub.
public struct AnimeSiteProvider: StreamProvider {
    public enum Site: String, Sendable { case reanime, anikoto }

    public let id: String
    public let name: String
    public let isFallback = false
    let site: Site
    let base: String
    let mapper: AnimeEpisodeMapper

    public init(id: String, name: String, site: Site, baseURL: String, mapper: AnimeEpisodeMapper = .shared) {
        self.id = id
        self.name = name
        self.site = site
        self.base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.mapper = mapper
    }

    public func resolve(_ identity: MediaIdentity) async throws -> [StreamSource] {
        guard let ref = await mapper.map(identity, airDate: nil) else { return [] }
        switch site {
        case .reanime: return await reAnime(ref)
        case .anikoto: return try await anikoto(ref)
        }
    }

    /// Re:Anime's own servers send encrypted payloads, but megaplay serves the same episodes by
    /// AniList id, which is what the site's players use too.
    private func reAnime(_ ref: AnimeEpisodeRef) async -> [StreamSource] {
        await withTaskGroup(of: StreamSource?.self) { group in
            for (audio, type) in [(StreamAudio.original, "sub"), (.dub, "dub")] {
                guard let embed = URL(string: "\(Megaplay.origin)/stream/ani/\(ref.anilistID)/\(ref.episode)/\(type)?s=bcdn") else { continue }
                group.addTask {
                    await Megaplay.stream(embed: embed, referer: base + "/", providerID: id, providerName: name, label: "HD", audio: audio)
                }
            }
            var found: [StreamSource] = []
            for await source in group { if let source { found.append(source) } }
            return found.sorted { $0.audio == .original && $1.audio != .original }
        }
    }

    /// Anikoto: search the site, confirm the show by the MAL id each episode carries, then
    /// resolve the episode's sub and dub servers (megaplay embeds).
    private func anikoto(_ ref: AnimeEpisodeRef) async throws -> [StreamSource] {
        let ajax = ["X-Requested-With": "XMLHttpRequest", "Referer": base + "/"]
        guard let episodes = try await anikotoEpisodes(ref, ajax: ajax),
              let episode = episodes.first(where: { Double($0["num"] ?? "") == Double(ref.episode) }),
              let ids = episode["ids"],
              let list = try await ajaxResult("\(base)/ajax/server/list?servers=\(ids)", headers: ajax)
        else { return [] }
        var links: [(StreamAudio, String, String)] = []
        for (audio, type) in [(StreamAudio.original, "sub"), (.dub, "dub")] {
            guard let block = list.firstMatch(of: try Regex("data-type=\"\(type)\">(.*?)</ul>").dotMatchesNewlines())?.output[1].substring
            else { continue }
            for match in String(block).matches(of: /data-link-id="([^"]+)"[^>]*>([^<]+)</) {
                links.append((audio, String(match.1), String(match.2).trimmingCharacters(in: .whitespaces)))
            }
        }
        return await withTaskGroup(of: StreamSource?.self) { group in
            for (audio, linkID, label) in links.prefix(8) {
                group.addTask {
                    guard let url = URL(string: "\(base)/ajax/server?get=\(linkID)"),
                          let data = try? await SourceHTTP.get(url, headers: ajax),
                          let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any],
                          let link = result["url"] as? String, link.contains("megaplay"),
                          var embed = URLComponents(string: link)
                    else { return nil }
                    // The clean-segment server; the other hides its segments in images.
                    embed.queryItems = (embed.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "bcdn")]
                    guard let embedURL = embed.url else { return nil }
                    return await Megaplay.stream(embed: embedURL, referer: base + "/", providerID: id, providerName: name,
                                                 label: label, audio: audio)
                }
            }
            var found: [StreamSource] = []
            var seen = Set<URL>()
            for await source in group { if let source, seen.insert(source.url).inserted { found.append(source) } }
            return found.sorted { $0.audio == .original && $1.audio != .original }
        }
    }

    private func anikotoEpisodes(_ ref: AnimeEpisodeRef, ajax: [String: String]) async throws -> [[String: String]]? {
        for title in ref.titles {
            guard let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "\(base)/filter?keyword=\(query)"),
                  let html = try await SourceHTTP.get(url).map({ String(decoding: $0, as: UTF8.self) })
            else { continue }
            let pages = html.matches(of: /<a class="name d-title" href="([^"]+)"/).map { String($0.1) }
            for page in pages.prefix(5) {
                guard let episodes = try await episodeList(page, ajax: ajax), let first = episodes.first else { continue }
                if ref.malID == nil || first["mal"] == ref.malID.map(String.init) { return episodes }
            }
        }
        return nil
    }

    private func episodeList(_ href: String, ajax: [String: String]) async throws -> [[String: String]]? {
        let address = href.hasPrefix("http") ? href : base + "/" + href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: address),
              let page = try await SourceHTTP.get(url).map({ String(decoding: $0, as: UTF8.self) }),
              let showID = page.firstMatch(of: /id="watch-main"[^>]*?data-id="(\d+)"/).map({ String($0.1) }),
              let html = try await ajaxResult("\(base)/ajax/episode/list/\(showID)", headers: ajax)
        else { return nil }
        return html.matches(of: /<a [^>]*data-num="[^>]*>/).map { Self.dataAttributes(String($0.output)) }
    }

    private func ajaxResult(_ address: String, headers: [String: String]) async throws -> String? {
        guard let url = URL(string: address), let data = try await SourceHTTP.get(url, headers: headers),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["result"] as? String
    }

    static func dataAttributes(_ tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in tag.matches(of: /data-([\w-]+)="([^"]*)"/) { attributes[String(match.1)] = String(match.2) }
        return attributes
    }
}
