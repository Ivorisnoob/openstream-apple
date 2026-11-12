import OpenStreamCore
import SwiftUI

enum Layout {
    /// The page's side margin; shelves scroll under it to the window's edge.
    static let gutter: CGFloat = 40
    static let cardSpacing: CGFloat = 18
    static let posterWidth: CGFloat = 168
    static let wideWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 10
}

// MARK: - Press and hover

extension EnvironmentValues {
    /// Whether the pointer rests on the card, so its artwork can lift while the text stays put.
    @Entry var cardHovered = false
}

/// Cards answer the moment they're pressed and lift under the pointer, as the TV app's do.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .environment(\.cardHovered, hovering)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(.rect)
        }
    }
}

/// Artwork that lifts and casts a shadow while hovered.
struct CardArtwork<Content: View>: View {
    var aspectRatio: CGFloat
    var cornerRadius: CGFloat = Layout.cornerRadius
    @ViewBuilder var content: Content
    @Environment(\.cardHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { content }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(hovered ? 0.18 : 0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovered ? 0.35 : 0.12), radius: hovered ? 14 : 4, y: hovered ? 8 : 2)
            .scaleEffect(hovered && !reduceMotion ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: hovered)
    }
}

// MARK: - Title cards

/// A poster. Posters carry their own title art, so a shelf shows only the picture; a grid can
/// ask for the name underneath.
struct PosterCard: View {
    let title: TitleSummary
    var width: CGFloat = Layout.posterWidth
    var showsCaption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardArtwork(aspectRatio: 2 / 3) {
                Artwork(path: title.posterPath, kind: .poster, width: width, placeholderSymbol: "film")
                    .overlay(alignment: .bottomLeading) {
                        // Without a poster there's no title art either: name it on the card.
                        if title.posterPath == nil {
                            Text(title.name)
                                .font(.callout.weight(.semibold))
                                .padding(10)
                        }
                    }
            }
            if showsCaption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(title.year.map(String.init) ?? title.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width)
        .help(title.name + (title.year.map { " (\($0))" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.name + (title.year.map { ", \($0)" } ?? ""))
    }
}

/// Text laid over the foot of an image on a soft band of material, so it reads on any picture.
struct CardBand<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 22)
            .padding(.bottom, 10)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                     startPoint: .top, endPoint: .bottom))
            }
            .environment(\.colorScheme, .dark)
    }
}

/// A wide still with the title underneath, for shelves of series and episodes.
struct WideCard: View {
    let title: TitleSummary
    var width: CGFloat = Layout.wideWidth
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardArtwork(aspectRatio: 16 / 9) {
                Artwork(path: title.backdropPath ?? title.posterPath, kind: .backdrop, width: width, placeholderSymbol: "tv")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(caption ?? title.year.map(String.init) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }
}

/// A Top 10 entry: the rank set into the poster's corner.
struct RankedCard: View {
    let rank: Int
    let title: TitleSummary

    var body: some View {
        PosterCard(title: title)
            .overlay(alignment: .topLeading) {
                Text("\(rank)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                    .padding(.leading, 10)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Number \(rank), \(title.name)")
    }
}

/// Continue Watching: the still, with the title, episode and time left on it.
struct ContinueCard: View {
    let item: ContinueItem
    var width: CGFloat = Layout.wideWidth

    var body: some View {
        CardArtwork(aspectRatio: 16 / 9) {
            Artwork(path: item.stillPath ?? item.title.backdropPath, kind: .backdrop, width: width, placeholderSymbol: "play.rectangle")
                .overlay(alignment: .bottom) {
                    CardBand {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title.name)
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill").font(.caption2)
                                if !item.isNext {
                                    ProgressBar(fraction: item.position.fraction).frame(width: 44)
                                }
                                Text(caption)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
        }
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title.name), \(caption)")
    }

    private var caption: String {
        var parts: [String] = []
        if let season = item.season, let episode = item.episode { parts.append("S\(season), E\(episode)") }
        if item.isNext {
            parts.append("Next Episode")
        } else {
            let left = max(0, item.position.duration - item.position.seconds)
            parts.append(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left")
        }
        return parts.joined(separator: " · ")
    }
}

/// A thin capsule of how much has been watched, on a dark backing so it reads over any image.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 2)
            .accessibilityLabel("\(Int(fraction * 100)) percent watched")
    }
}

/// A person, round, with what they did.
struct PersonCard: View {
    let name: String
    let role: String
    let profilePath: String?
    var size: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            CardArtwork(aspectRatio: 1, cornerRadius: size / 2) {
                Artwork(path: profilePath, kind: .profile, width: size, placeholderSymbol: "person.fill")
            }
            .frame(width: size)
            VStack(spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size + 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Links

/// A card that opens the title's page, with the title's menu on a secondary click.
struct TitleLink<Label: View>: View {
    let title: TitleSummary
    @ViewBuilder var label: Label

    var body: some View {
        NavigationLink(value: Route.title(title)) { label }
            .buttonStyle(CardButtonStyle())
            .contextMenu { TitleMenuItems(title: title) }
            .disabled(title.isPlaceholder)
    }
}

/// The menu every title card shares: play, Watchlist, sharing.
struct TitleMenuItems: View {
    let title: TitleSummary
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Play", systemImage: "play.fill") {
            app.playback.play(title)
        }
        Divider()
        let saved = app.library.isInWatchlist(title.ref)
        Button(saved ? "Remove from Watchlist" : "Add to Watchlist", systemImage: saved ? "bookmark.slash" : "bookmark") {
            app.library.toggleWatchlist(title)
        }
        if app.library.continueItem(for: title.ref) != nil {
            Button("Remove from Continue Watching", systemImage: "xmark.circle") {
                app.library.removeFromContinueWatching(title.ref)
            }
        }
        if title.kind == .movie {
            let watched = app.library.isWatched(title.ref)
            Button(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "checkmark.circle") {
                app.library.setWatched(!watched, title)
            }
        }
        Divider()
        ShareLink(item: title.webURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(title.webURL.absoluteString, forType: .string)
        }
    }
}

extension TitleSummary {
    /// The title's page on TMDB: a link anyone can open.
    var webURL: URL { URL(string: "https://www.themoviedb.org/\(kind.rawValue)/\(ref.id)")! }
}
