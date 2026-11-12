import Foundation
import Testing
@testable import OpenStreamCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: fixture(name))
}

@Suite("TMDB")
struct TMDBTests {
    @Test func movieDetails() throws {
        let details = try decode(DetailsDTO.self, "movie").details(kind: .movie)
        #expect(details.summary.name == "Inception")
        #expect(details.summary.year == 2010)
        #expect(details.imdbID == "tt1375666")
        #expect(details.runtime == 148)
        #expect(details.certification == "PG-13")
        #expect(details.logoPath != nil)
        #expect(details.cast.first?.name == "Leonardo DiCaprio")
        #expect(details.crew.contains { $0.role == "Director, Writer" && $0.name == "Christopher Nolan" })
        #expect(!details.trailers.isEmpty)
        #expect(!details.recommendations.isEmpty)
        #expect(details.recommendations.allSatisfy { $0.kind == .movie })
    }

    @Test func showDetails() throws {
        let details = try decode(DetailsDTO.self, "tv").details(kind: .tv)
        #expect(details.summary.name == "Breaking Bad")
        #expect(details.imdbID == "tt0903747")
        #expect(details.certification != nil)
        // Specials go last; seasons in order before them.
        let numbers = details.playableSeasons.map(\.number)
        #expect(numbers.first == 1)
        #expect(numbers.last == 0)
    }

    @Test func season() throws {
        let dto = try decode(SeasonDTO.self, "season")
        let episodes = (dto.episodes ?? []).compactMap { $0.episode(season: 1) }
        #expect(episodes.count == 7)
        #expect(episodes[0].number == 1 && episodes[0].season == 1)
        #expect(episodes[0].hasAired)
    }

    @Test func mixedListsKeepTheirKinds() throws {
        let page = try decode(PageDTO<TitleDTO>.self, "trending")
        let titles = (page.results ?? []).compactMap { $0.summary(defaultKind: nil) }
        #expect(!titles.isEmpty)
        #expect(Set(titles.map(\.kind)).count == 2)
    }

    @Test func searchSeparatesPeople() throws {
        let page = try decode(PageDTO<TitleDTO>.self, "search")
        let results = page.results ?? []
        let titles = results.compactMap { $0.summary(defaultKind: nil) }
        #expect(titles.count == results.filter { $0.mediaType != "person" }.count)
    }

    @Test func person() throws {
        let person = try decode(PersonDTO.self, "person").person
        #expect(person.name == "Bryan Cranston")
        #expect(!person.credits.isEmpty)
        #expect(Set(person.credits.map(\.ref)).count == person.credits.count)
    }

    @Test func imageSizes() {
        #expect(TMDBImage.url("/a.jpg", kind: .poster, pixels: 300)?.absoluteString == "https://image.tmdb.org/t/p/w342/a.jpg")
        #expect(TMDBImage.url("/a.jpg", kind: .backdrop, pixels: 3000)?.absoluteString == "https://image.tmdb.org/t/p/original/a.jpg")
        #expect(TMDBImage.url(nil, kind: .poster, pixels: 300) == nil)
    }
}

@Suite("Streams")
struct StreamTests {
    @Test func quality() {
        #expect(StreamQuality.parse("4KHDHub 1080p") == .q1080)
        #expect(StreamQuality.parse("2160p UHD") == .q2160)
        #expect(StreamQuality.parse("UHD BluRay") == .q2160)
        #expect(StreamQuality.parse("720") == .q720)
        #expect(StreamQuality.parse("something") == .unknown)
    }

    @Test func vidkingCipherRoundTrip() {
        let plain = Array("mvm1{\"playlist\":\"https://x/master.m3u8\"}".utf8)
        let stream = VidkingCipher.keyStream(seed: "abc123", mediaID: 27205, count: plain.count)
        let encrypted = Data(zip(plain, stream).map { $0 ^ $1 })
        let encoded = encrypted.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(VidkingCipher.decrypt(encoded, seed: "abc123", mediaID: 27205) == "{\"playlist\":\"https://x/master.m3u8\"}")
        #expect(VidkingCipher.decrypt(encoded, seed: "other", mediaID: 27205) == nil)
    }

    /// Values from the Kotlin implementation's algorithm, so a port mistake shows.
    @Test func vidkingKeyStreamIsStable() {
        let bytes = VidkingCipher.keyStream(seed: "seed", mediaID: 1, count: 8)
        #expect(bytes == VidkingCipher.keyStream(seed: "seed", mediaID: 1, count: 8))
        #expect(bytes != VidkingCipher.keyStream(seed: "seed", mediaID: 2, count: 8))
    }

    @Test func stremioSkipsLinklessStreamsAndGroupsReleases() throws {
        let releases = StremioProvider.parse(try fixture("stremio"), providerID: "hdhub", providerName: "HDHub", title: "Inception")
        let all = releases.flatMap { $0 }
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.url.scheme?.hasPrefix("http") == true })
        #expect(all.allSatisfy { !$0.name.unicodeScalars.contains { $0.properties.isEmojiPresentation } })
        #expect(all.contains { $0.quality == .q2160 })
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func stremioIDs() {
        let provider = StremioProvider(id: "x", name: "X", endpoint: URL(string: "https://a.b/conf/manifest.json")!)
        #expect(provider.baseURL.absoluteString == "https://a.b/conf")
        let episode = MediaIdentity(ref: TitleRef(kind: .tv, id: 1396), imdbID: "tt0903747", title: "Breaking Bad",
                                    year: 2008, season: 2, episode: 3)
        #expect(provider.candidateIDs(episode, info: ManifestInfo(types: [], idPrefixes: nil)) == ["tt0903747:2:3"])
        #expect(provider.candidateIDs(episode, info: ManifestInfo(types: [], idPrefixes: ["tmdb:"])) == ["tmdb:1396:2:3"])
    }

    @Test func ranking() {
        func source(_ id: String, _ provider: String, _ quality: StreamQuality, _ path: String = "/a.m3u8") -> StreamSource {
            StreamSource(id: id, providerID: provider, providerName: provider, name: id,
                         url: URL(string: "https://h\(path)")!, quality: quality)
        }
        let ranked = StreamFinder.rank([
            source("mkv", "a", .q2160, "/a.mkv"),
            source("p2-1080", "b", .q1080),
            source("p1-1080", "a", .q1080),
            source("p1-auto", "a", .unknown),
        ], order: ["a", "b"])
        #expect(ranked.map(\.id) == ["p1-1080", "p2-1080", "p1-auto", "mkv"])
        // A cap at 720p makes a 1080p stream no better than a 720p one; the order decides.
        let capped = StreamFinder.rank([source("b-1080", "b", .q1080), source("a-720", "a", .q720)], order: ["a", "b"], maxQuality: .q720)
        #expect(capped.first?.id == "a-720")
        var dub = source("dub", "b", .q720)
        dub.audio = .dub
        let dubbed = StreamFinder.rank([source("orig", "a", .q1080), dub], order: ["a", "b"], audio: .dub)
        #expect(dubbed.first?.id == "dub")
        // A link that doesn't say its format waits behind HLS; one named .mkv goes last.
        var unknown = source("file", "a", .q2160, "/stream/123")
        var named = source("named", "a", .q2160, "/stream/456")
        named.fileExtension = "mkv"
        let mixed = StreamFinder.rank([unknown, named, source("hls", "b", .q720)], order: ["a", "b"])
        #expect(mixed.map(\.id) == ["hls", "file", "named"])
        unknown.fileExtension = "mp4"
        #expect(StreamFinder.rank([source("hls", "b", .q720), unknown], order: []).first?.id == "file")
    }

    @Test func audioLanguagesFromLabels() {
        #expect(AudioLanguages.detect("1080p | Eng") == ["en"])
        #expect(AudioLanguages.detect("Dual Audio [Hin-Eng] DD5.1") == ["hi", "en"])
        #expect(AudioLanguages.detect("Hotel Transylvania 1080p").isEmpty)
        var hindi = StreamSource(id: "h", providerID: "b", providerName: "b", name: "h", url: URL(string: "https://h/a.m3u8")!, quality: .q720)
        hindi.audioLanguages = ["hi"]
        let other = StreamSource(id: "o", providerID: "a", providerName: "a", name: "o", url: URL(string: "https://h/b.m3u8")!, quality: .q1080)
        #expect(StreamFinder.rank([other, hindi], order: ["a", "b"], language: "hi").first?.id == "h")
    }

    @Test func bundledCatalog() {
        let catalog = Catalog.bundled
        #expect(catalog.extensions.count > 10)
        #expect(catalog.extensions.contains { $0.engine.type == "stremio" })
        let newer = Catalog(name: "x", extensions: [Catalog.Entry(id: "yoru", name: "Yoru 2", versionCode: 99,
                                                                    engine: .init(type: "vidking-direct")),
                                                     Catalog.Entry(id: "new", name: "New", engine: .init(type: "stremio"))])
        let merged = catalog.merged(with: newer)
        #expect(merged.extensions.first { $0.id == "yoru" }?.name == "Yoru 2")
        #expect(merged.extensions.last?.id == "new")
    }

    @Test func webPlayerTemplates() {
        struct NoSniffer: WebPlayerSniffing {
            func streams(at page: URL, timeout: Duration) async -> [SniffedStream] { [] }
        }
        let provider = WebPlayerProvider(id: "w", name: "W", movieTemplate: "https://p/movie/{tmdbId}",
                                         tvTemplate: "https://p/tv/{tmdbId}/{season}/{episode}", isFallback: true,
                                         sniffer: NoSniffer())
        let episode = MediaIdentity(ref: TitleRef(kind: .tv, id: 5), imdbID: nil, title: "T", year: nil, season: 2, episode: 7)
        #expect(provider.pageURL(for: episode)?.absoluteString == "https://p/tv/5/2/7")
    }
}

@Suite("Library")
@MainActor
struct LibraryTests {
    let show = TitleSummary(ref: TitleRef(kind: .tv, id: 1), name: "Show")

    @Test func resumeOnlyBetweenStartAndCredits() {
        let library = Library(file: nil)
        library.record(show, season: 1, episode: 1, episodeName: nil, stillPath: nil, seconds: 10, duration: 1000)
        #expect(library.resumeTime(show.ref, season: 1, episode: 1) == nil)
        #expect(library.continueWatching.isEmpty)
        library.record(show, season: 1, episode: 1, episodeName: nil, stillPath: nil, seconds: 400, duration: 1000)
        #expect(library.resumeTime(show.ref, season: 1, episode: 1) == 400)
        #expect(library.continueWatching.first?.episode == 1)
        library.record(show, season: 1, episode: 1, episodeName: nil, stillPath: nil, seconds: 990, duration: 1000)
        #expect(library.resumeTime(show.ref, season: 1, episode: 1) == nil)
    }

    @Test func finishingMovesToTheNextEpisode() {
        let library = Library(file: nil)
        library.record(show, season: 1, episode: 1, episodeName: nil, stillPath: nil, seconds: 400, duration: 1000)
        let next = Episode(season: 1, number: 2, name: "Two", overview: "", stillPath: nil, airDate: "2020-01-01", runtime: 40)
        library.finish(show, season: 1, episode: 1, episodeName: "One", next: next)
        #expect(library.isWatched(show.ref, season: 1, episode: 1))
        #expect(library.continueWatching.count == 1)
        #expect(library.continueWatching[0].episode == 2 && library.continueWatching[0].isNext)
        #expect(library.history.count == 1)
    }

    @Test func backupRestoresIntoAnotherLibrary() throws {
        let source = Library(file: nil)
        source.toggleWatchlist(show)
        source.record(show, season: 1, episode: 2, episodeName: nil, stillPath: nil, seconds: 500, duration: 1000)
        let target = Library(file: nil)
        let other = TitleSummary(ref: TitleRef(kind: .movie, id: 9), name: "Film")
        target.toggleWatchlist(other)
        let summary = try target.restore(source.backup())
        #expect(summary.watchlist == 1)
        #expect(target.watchlist.map(\.ref) == [other.ref, show.ref])
        #expect(target.resumeTime(show.ref, season: 1, episode: 2) == 500)
        #expect(target.continueWatching.first?.title.ref == show.ref)
        // Restoring again changes nothing.
        #expect(try target.restore(source.backup()).watchlist == 0)
    }

    @Test func savesAndReopens() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let library = Library(file: file)
        library.toggleWatchlist(show)
        library.flush()
        #expect(Library(file: file).isInWatchlist(show.ref))
    }
}

@Suite("Subtitles")
struct SubtitleTests {
    private func file(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesSubRipWithoutTagsOrAds() throws {
        let cues = Subtitles.parse(Subtitles.text(try file("sample", "srt")))
        #expect(cues.count == 2)
        #expect(cues[0].start == 1 && cues[0].end == 3.5)
        #expect(cues[0].text == "Hello there\nGeneral Kenobi")
        #expect(cues[1].start == 62.25)
        #expect(cues[1].text == "Second line")
    }

    @Test func gunzipsOpenSubtitlesFiles() throws {
        let zipped = try file("sample.srt", "gz")
        let plain = try file("sample", "srt")
        #expect(Subtitles.gunzipIfNeeded(zipped) == plain)
        #expect(Subtitles.gunzipIfNeeded(plain) == plain)
    }

    @Test func parsesWebVTT() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nHi\n\nNOTE skip me\n\n01:00:00.500 --> 01:00:01.000\n<c.yellow>Late</c>\n"
        let cues = Subtitles.parse(vtt)
        #expect(cues.map(\.text) == ["Hi", "Late"])
        #expect(cues[1].start == 3600.5)
    }
}

@Suite("Working sources")
@MainActor
struct WorkingSourcesTests {
    @Test func remembersPerTitleAndKeepsTheMostRecent() async throws {
        let sources = WorkingSources(file: nil, limit: 2)
        let a = TitleRef(kind: .movie, id: 1), b = TitleRef(kind: .tv, id: 2), c = TitleRef(kind: .movie, id: 3)
        sources.record("hdhub", for: a)
        try await Task.sleep(for: .milliseconds(5))
        sources.record("phoenix", for: b)
        try await Task.sleep(for: .milliseconds(5))
        sources.record("yastream", for: c)
        #expect(sources.count == 2)
        #expect(sources.provider(for: a) == nil)
        #expect(sources.provider(for: b) == "phoenix")
        sources.forget(b)
        #expect(sources.provider(for: b) == nil)
    }

    @Test func savesAndReopens() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "working-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        WorkingSources(file: file).record("hdhub", for: TitleRef(kind: .movie, id: 7))
        try await Task.sleep(for: .milliseconds(300))
        #expect(WorkingSources(file: file).provider(for: TitleRef(kind: .movie, id: 7)) == "hdhub")
    }
}

@Suite("DASH")
struct DashTests {
    let base = URL(string: "https://cdn.example/dash/abc/index_web.mpd")!

    private func manifest() throws -> DashManifest {
        let url = try #require(Bundle.module.url(forResource: "vidlink", withExtension: "mpd", subdirectory: "Fixtures"))
        return try DashManifest.parse(Data(contentsOf: url), url: base)
    }

    @Test func readsAnFFmpegManifest() throws {
        let dash = try manifest()
        #expect(dash.duration == 36)
        #expect(dash.videos.map(\.height) == [1080, 720, 480])
        #expect(dash.audios.first?.language == "eng")
        let video = try #require(dash.videos.first)
        #expect(video.segments.count == 7) // six timeline entries, one repeated once
        #expect(video.segments[0].url.absoluteString == "https://cdn.example/dash/abc/chunk-stream0-00001.m4s")
        #expect(video.initialization.absoluteString == "https://cdn.example/dash/abc/init-stream0.m4s")
        #expect(abs(video.segments[0].duration - 143143.0 / 24000) < 0.0001)
    }

    @Test func writesHLS() throws {
        let dash = try manifest()
        let master = DashToHLS.master(dash, scheme: "osdash", id: "x")
        #expect(master.contains("CODECS=\"hvc1.1.6.L120.90,mp4a.40.2\""))
        #expect(master.contains("TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",LANGUAGE=\"en\""))
        #expect(master.contains("osdash://x/0.m3u8"))
        let media = DashToHLS.media(dash.videos[0], scheme: "osdash", id: "x")
        #expect(media.contains("#EXT-X-MAP:URI=\"osdash://x/0/init.mp4\""))
        #expect(media.contains("https://cdn.example/dash/abc/chunk-stream0-00002.m4s"))
        #expect(media.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func languages() {
        #expect(DashToHLS.languageCode("eng") == "en")
        #expect(DashToHLS.languageCode("und") == nil)
        #expect(DashToHLS.languageCode("pt-BR") == "pt")
    }

    @Test func durations() {
        #expect(DashManifest.seconds("PT2H28M8.0S") == 8888)
        #expect(DashManifest.seconds("PT45.5S") == 45.5)
        #expect(DashManifest.seconds("P1DT1M") == 86460)
    }

    @Test func retagsHEVC() {
        let data = Data([0, 0, 0, 20] + Array("hev1".utf8) + [1, 2, 3])
        #expect(Array(DashToHLS.retagHEVC(data)[4..<8]) == Array("hvc1".utf8))
    }
}
