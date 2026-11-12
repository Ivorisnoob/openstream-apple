import Foundation

/// An MPEG-DASH manifest, read far enough to describe the same media as HLS: AVFoundation plays
/// fragmented-MP4 HLS but not DASH, and most DASH from web players is ffmpeg's `isoff-live`
/// output: a SegmentTemplate per representation, with a SegmentTimeline or a fixed duration.
public struct DashManifest: Sendable {
    public struct Segment: Sendable, Hashable {
        public var url: URL
        public var duration: Double
    }

    public struct Representation: Sendable, Identifiable {
        public enum Kind: String, Sendable { case video, audio, text }
        public var id: String
        public var kind: Kind
        public var codecs: String
        public var bandwidth: Int
        public var width: Int?
        public var height: Int?
        public var frameRate: String?
        public var language: String?
        public var initialization: URL
        public var segments: [Segment]
    }

    public var duration: Double
    public var representations: [Representation]

    public var videos: [Representation] { representations.filter { $0.kind == .video } }
    public var audios: [Representation] { representations.filter { $0.kind == .audio } }

    public enum ParseError: Error { case unreadable, unsupported }

    public static func parse(_ data: Data, url: URL) throws -> DashManifest {
        let reader = DashReader(base: url)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw ParseError.unreadable }
        let representations = reader.finished.filter { !$0.segments.isEmpty }
        guard representations.contains(where: { $0.kind == .video }) else { throw ParseError.unsupported }
        return DashManifest(duration: reader.duration, representations: representations)
    }

    /// "PT2H28M8.0S" → 8888.
    static func seconds(_ iso: String?) -> Double {
        guard var text = iso?.uppercased(), text.hasPrefix("P") else { return 0 }
        text.removeFirst()
        var total = 0.0, number = ""
        var inTime = false
        for character in text {
            switch character {
            case "T": inTime = true
            case "D": total += (Double(number) ?? 0) * 86400; number = ""
            case "H": total += (Double(number) ?? 0) * 3600; number = ""
            case "M" where inTime: total += (Double(number) ?? 0) * 60; number = ""
            case "S": total += Double(number) ?? 0; number = ""
            default: number.append(character)
            }
        }
        return total
    }
}

/// Collects representations while XMLParser walks the manifest. Attributes inherit downward
/// (AdaptationSet → Representation) and SegmentTemplate may sit at either level.
private final class DashReader: NSObject, XMLParserDelegate {
    struct Template {
        var timescale: Double = 1
        var duration: Double?
        var startNumber = 1
        var initialization: String?
        var media: String?
        var timeline: [(t: Double?, d: Double, r: Int)] = []
    }

    let base: URL
    var duration = 0.0
    var finished: [DashManifest.Representation] = []

    private var baseStack: [URL]
    private var text = ""
    private var adaptation: [String: String] = [:]
    private var adaptationTemplate: Template?
    private var representation: [String: String]?
    private var representationTemplate: Template?
    private var inTemplateOf: Int = 0 // 1 = adaptation, 2 = representation

    init(base: URL) {
        self.base = base
        baseStack = [base]
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "MPD":
            duration = DashManifest.seconds(attributes["mediaPresentationDuration"])
        case "AdaptationSet":
            adaptation = attributes
            adaptationTemplate = nil
            baseStack.append(baseStack.last!)
        case "Representation":
            representation = attributes
            representationTemplate = adaptationTemplate
            baseStack.append(baseStack.last!)
        case "SegmentTemplate":
            var template = (representation != nil ? representationTemplate : adaptationTemplate) ?? Template()
            if let value = attributes["timescale"].flatMap(Double.init) { template.timescale = value }
            if let value = attributes["duration"].flatMap(Double.init) { template.duration = value }
            if let value = attributes["startNumber"].flatMap(Int.init) { template.startNumber = value }
            if let value = attributes["initialization"] { template.initialization = value }
            if let value = attributes["media"] { template.media = value }
            template.timeline = []
            if representation != nil { representationTemplate = template; inTemplateOf = 2 } else { adaptationTemplate = template; inTemplateOf = 1 }
        case "S":
            let entry = (t: attributes["t"].flatMap(Double.init), d: attributes["d"].flatMap(Double.init) ?? 0,
                         r: attributes["r"].flatMap(Int.init) ?? 0)
            if inTemplateOf == 2 { representationTemplate?.timeline.append(entry) } else { adaptationTemplate?.timeline.append(entry) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "BaseURL":
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value, relativeTo: baseStack.last), !baseStack.isEmpty {
                baseStack[baseStack.count - 1] = url.absoluteURL
            }
        case "Representation":
            if let attributes = representation, let made = make(attributes) { finished.append(made) }
            representation = nil
            representationTemplate = nil
            baseStack.removeLast()
        case "AdaptationSet":
            adaptation = [:]
            adaptationTemplate = nil
            baseStack.removeLast()
        case "SegmentTemplate":
            inTemplateOf = 0
        default:
            break
        }
    }

    private func make(_ attributes: [String: String]) -> DashManifest.Representation? {
        let merged = adaptation.merging(attributes) { _, own in own }
        guard let id = merged["id"], let template = representationTemplate ?? adaptationTemplate,
              let initialization = template.initialization, let media = template.media,
              let base = baseStack.last
        else { return nil }
        let bandwidth = Int(merged["bandwidth"] ?? "") ?? 0
        let mime = (merged["mimeType"] ?? "") + " " + (merged["contentType"] ?? "")
        let kind: DashManifest.Representation.Kind = mime.contains("video") ? .video : mime.contains("audio") ? .audio : .text
        func fill(_ pattern: String, number: Int? = nil, time: Double? = nil) -> URL? {
            var result = pattern.replacingOccurrences(of: "$RepresentationID$", with: id)
                .replacingOccurrences(of: "$Bandwidth$", with: String(bandwidth))
            result = Self.substitute(result, "Number", number)
            result = Self.substitute(result, "Time", time.map { Int($0) })
            result = result.replacingOccurrences(of: "$$", with: "$")
            return URL(string: result, relativeTo: base)?.absoluteURL
        }
        var segments: [DashManifest.Segment] = []
        var number = template.startNumber
        if !template.timeline.isEmpty {
            var time = 0.0
            for entry in template.timeline {
                if let t = entry.t { time = t }
                let repeats = entry.r < 0 ? max(0, Int(((duration * template.timescale) - time) / max(entry.d, 1)) - 1) : entry.r
                for _ in 0...repeats {
                    guard let url = fill(media, number: number, time: time) else { return nil }
                    segments.append(.init(url: url, duration: entry.d / template.timescale))
                    time += entry.d
                    number += 1
                }
            }
        } else if let fixed = template.duration, fixed > 0, duration > 0 {
            let length = fixed / template.timescale
            let count = Int((duration / length).rounded(.up))
            for index in 0..<count {
                guard let url = fill(media, number: number + index, time: Double(index) * fixed) else { return nil }
                segments.append(.init(url: url, duration: min(length, duration - Double(index) * length)))
            }
        }
        guard let initURL = fill(initialization) else { return nil }
        return DashManifest.Representation(
            id: id, kind: kind, codecs: merged["codecs"] ?? "", bandwidth: bandwidth,
            width: merged["width"].flatMap(Int.init), height: merged["height"].flatMap(Int.init),
            frameRate: merged["frameRate"], language: merged["lang"], initialization: initURL, segments: segments
        )
    }

    /// `$Number$` and `$Number%05d$`.
    private static func substitute(_ text: String, _ name: String, _ value: Int?) -> String {
        guard let value else { return text }
        var result = text.replacingOccurrences(of: "$\(name)$", with: String(value))
        while let start = result.range(of: "$\(name)%"),
              let end = result.range(of: "$", range: start.upperBound..<result.endIndex) {
            let format = String(result[start.upperBound..<end.lowerBound]) // "05d"
            let width = Int(format.filter(\.isNumber)) ?? 0
            let digits = String(value)
            let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: padded)
        }
        return result
    }
}

/// HLS playlists describing a DASH manifest's media. Segments stay at their own URLs; only the
/// playlists and each initialization segment come from the app (under `scheme`), the latter so
/// an HEVC sample entry tagged `hev1` can be retagged `hvc1`, the only one HLS accepts.
public enum DashToHLS {
    public static func master(_ manifest: DashManifest, scheme: String, id: String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let audios = manifest.audios
        for (index, audio) in audios.enumerated() {
            let code = languageCode(audio.language)
            let language = code.map { ",LANGUAGE=\"\($0)\"" } ?? ""
            let name = code.map(AudioLanguages.name) ?? (audios.count > 1 ? "Audio \(index + 1)" : "Audio")
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name)\"\(language),DEFAULT=\(index == 0 ? "YES" : "NO"),AUTOSELECT=YES,URI=\"\(scheme)://\(id)/\(audio.id).m3u8\"")
        }
        let audioCodecs = audios.first.map { "," + $0.codecs } ?? ""
        for video in manifest.videos.sorted(by: { $0.bandwidth > $1.bandwidth }) {
            var attributes = ["BANDWIDTH=\(video.bandwidth + (audios.first?.bandwidth ?? 0))",
                              "CODECS=\"\(hlsCodecs(video.codecs))\(audioCodecs)\""]
            if let width = video.width, let height = video.height { attributes.append("RESOLUTION=\(width)x\(height)") }
            if let rate = video.frameRate.flatMap(frameRate) { attributes.append("FRAME-RATE=\(String(format: "%.3f", rate))") }
            if !audios.isEmpty { attributes.append("AUDIO=\"audio\"") }
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append("\(scheme)://\(id)/\(video.id).m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func media(_ representation: DashManifest.Representation, scheme: String, id: String) -> String {
        let target = Int((representation.segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(scheme)://\(id)/\(representation.id)/init.mp4\""]
        for segment in representation.segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append(segment.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// DASH uses ISO 639-2 ("eng") or 639-1 ("en"); "und" and friends mean nobody said.
    static func languageCode(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased().split(separator: "-").first.map(String.init), !raw.isEmpty,
              !["und", "mul", "zxx", "mis"].contains(raw)
        else { return nil }
        if raw.count == 2 { return raw }
        let threeLetter = ["eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it",
                           "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh", "hin": "hi",
                           "ara": "ar", "tur": "tr", "tam": "ta", "tel": "te", "pol": "pl", "dut": "nl", "nld": "nl",
                           "swe": "sv", "tha": "th", "ind": "id", "ukr": "uk"]
        return threeLetter[raw]
    }

    /// HLS names HEVC with in-band parameter sets `hvc1` only.
    static func hlsCodecs(_ codecs: String) -> String {
        codecs.replacingOccurrences(of: "hev1", with: "hvc1")
    }

    static func frameRate(_ text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first
    }

    /// Retags an HEVC initialization segment's sample entry from `hev1` to `hvc1`. The parameter
    /// sets ffmpeg writes into `hvcC` are what `hvc1` needs, so only the four-letter code changes.
    public static func retagHEVC(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        let hev1: [UInt8] = Array("hev1".utf8)
        guard bytes.count > 8 else { return data }
        for index in 4..<(bytes.count - 3) where Array(bytes[index..<index + 4]) == hev1 {
            // A sample entry: preceded by its 32-bit size.
            bytes.replaceSubrange(index..<index + 4, with: Array("hvc1".utf8))
        }
        return Data(bytes)
    }
}
