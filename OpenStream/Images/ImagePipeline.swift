import AppKit
import ImageIO
import OpenStreamCore
import SwiftUI

/// Artwork, fetched once and kept: TMDB's image CDN sends a year-long `max-age`, so a disk
/// `URLCache` serves every image again without the network. Decoding is the expensive part, so
/// images are downsampled with ImageIO to the pixels they're drawn at, off the main thread, and
/// the decoded results are kept in memory for scrolling back.
final class ImagePipeline: Sendable {
    static let shared = ImagePipeline()

    let urlCache: URLCache
    private let session: URLSession
    private let decoded = DecodedImages()

    init() {
        let folder = URL.cachesDirectory.appending(path: "com.ivor.openstream/Images")
        urlCache = URLCache(memoryCapacity: 0, diskCapacity: 600 << 20, directory: folder)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL, pixels: CGFloat) -> CGImage? {
        decoded.image(for: Self.key(url, pixels))
    }

    func image(_ url: URL, pixels: CGFloat) async -> CGImage? {
        let key = Self.key(url, pixels)
        if let image = decoded.image(for: key) { return image }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let image = await Task.detached(priority: .userInitiated) { Self.downsample(data, to: pixels) }.value
        if let image { decoded.store(image, for: key) }
        return image
    }

    /// Fills the disk cache ahead of time (the hero carousel's next slides).
    func prefetch(_ url: URL) {
        Task.detached(priority: .utility) { [session] in _ = try? await session.data(from: url) }
    }

    func clear() {
        urlCache.removeAllCachedResponses()
        decoded.removeAll()
    }

    private static func key(_ url: URL, _ pixels: CGFloat) -> String { "\(url.absoluteString)#\(Int(pixels))" }

    private nonisolated static func downsample(_ data: Data, to pixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixels, 64),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// NSCache is thread-safe; the wrapper only gives it Swift types and a size budget.
private final class DecodedImages: @unchecked Sendable {
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 300 << 20
        return cache
    }()

    func image(for key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

    func store(_ image: CGImage, for key: String) {
        cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() { cache.removeAllObjects() }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// A TMDB image that fills the frame it's given; its own size never drives layout. Shows a
/// quiet placeholder until it arrives, then fades in once.
struct Artwork: View {
    let path: String?
    let kind: TMDBImage.Kind
    /// Points the image is drawn at; the pipeline asks for the matching pixels.
    var width: CGFloat
    var contentMode: ContentMode = .fill
    var placeholderSymbol: String?

    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    private var pixels: CGFloat { width * scale }
    private var url: URL? { TMDBImage.url(path, kind: kind, pixels: pixels) }

    var body: some View {
        // The quiet fill only stands in while nothing has loaded; a logo's transparency must
        // show what's behind it.
        Rectangle()
            .fill(image == nil && kind != .logo ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .overlay {
                if let image {
                    Image(decorative: image, scale: scale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else if let placeholderSymbol {
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: max(14, width / 6)))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = ImagePipeline.shared.cached(url, pixels: pixels) {
                    image = cached
                    return
                }
                image = nil
                let loaded = await ImagePipeline.shared.image(url, pixels: pixels)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}
