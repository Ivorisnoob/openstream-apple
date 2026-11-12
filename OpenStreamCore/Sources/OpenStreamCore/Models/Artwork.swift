import Foundation

/// TMDB's image CDN. Paths come from the API ("/abc.jpg"); the size picks a pre-scaled rendition,
/// so the app asks for the smallest one that covers the pixels it draws.
public enum TMDBImage {
    public enum Kind: Sendable {
        case poster, backdrop, profile, still, logo

        var widths: [Int] {
            switch self {
            case .poster: [92, 154, 185, 342, 500, 780]
            case .backdrop: [300, 780, 1280]
            case .profile: [45, 185]
            case .still: [92, 185, 300]
            case .logo: [45, 92, 154, 185, 300, 500]
            }
        }
    }

    /// The rendition at least `pixels` wide, or the original when none is.
    public static func url(_ path: String?, kind: Kind, pixels: CGFloat) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let size = kind.widths.first { CGFloat($0) >= pixels }.map { "w\($0)" } ?? "original"
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
