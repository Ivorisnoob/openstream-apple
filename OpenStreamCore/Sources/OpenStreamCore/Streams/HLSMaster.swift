import Foundation

/// Repairs a master playlist before AVFoundation reads it. Sources publish playlists that point at
/// things that don't exist: an I-frame playlist answering 404 (megaplay), which AVPlayer asks
/// for when seeking, or an AUDIO group no EXT-X-MEDIA defines (hdhub). Variant and media URIs are
/// made absolute so the result can be served from anywhere.
public enum HLSMaster {
    /// The cleaned playlist, or nil when it isn't a master playlist or needs nothing.
    public static func clean(_ text: String, base: URL) -> String? {
        guard text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-STREAM-INF") else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let definedGroups = Set(lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }.compactMap { attribute("GROUP-ID", in: $0) })
        var changed = false
        var output: [String] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                // Seeking works without trick-play playlists; a dead one makes it fail.
                changed = true
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF"), let group = attribute("AUDIO", in: line), !definedGroups.contains(group) {
                output.append(line.replacingOccurrences(of: ",AUDIO=\"\(group)\"", with: "")
                    .replacingOccurrences(of: "AUDIO=\"\(group)\",", with: ""))
                changed = true
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                output.append(url.absoluteString)
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:"), let uri = attribute("URI", in: line),
               let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                output.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(url.absoluteString)\""))
                continue
            }
            output.append(line)
        }
        return changed ? output.joined(separator: "\n") : nil
    }

    static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
