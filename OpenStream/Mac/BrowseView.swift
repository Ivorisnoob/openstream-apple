import OpenStreamCore
import SwiftUI

/// Home, Movies, TV Shows and Anime: a carousel of featured titles across the top, then shelves.
struct BrowseView: View {
    let model: BrowseModel
    let name: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let message = model.allFailed {
                LoadFailedView(message: message) { model.load() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        HeroCarousel(state: model.hero)
                        if model.style == .home, !app.library.continueWatching.isEmpty {
                            ContinueWatchingShelf(items: app.library.continueWatching)
                        }
                        if !model.genres.isEmpty, let kind = model.kind {
                            GenreStrip(genres: model.genres, kind: kind)
                        }
                        ForEach(model.shelves) { spec in
                            TitleShelf(title: spec.title, state: model.states[spec.id] ?? .loading, style: spec.style,
                                       seeAll: .list(spec.list, name: spec.title))
                        }
                    }
                    .padding(.bottom, 40)
                }
                // The hero runs up under the toolbar, with no band of its own.
                .ignoresSafeArea(edges: .top)
                .scrollEdgeEffectHidden(true, for: .top)
            }
        }
        .navigationTitle(name)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { model.loadIfNeeded() }
    }
}

struct ContinueWatchingShelf: View {
    let items: [ContinueItem]
    @Environment(AppModel.self) private var app

    var body: some View {
        Shelf(title: "Continue Watching") {
            ForEach(items) { item in
                Button {
                    app.playback.resume(item)
                } label: {
                    ContinueCard(item: item)
                }
                .buttonStyle(CardButtonStyle())
                .contextMenu {
                    Button("Go to \(item.title.kind == .movie ? "Movie" : "Show")", systemImage: "info.circle") {
                        app.open(.title(item.title))
                    }
                    TitleMenuItems(title: item.title)
                }
            }
        }
    }
}

/// The genres of a kind, as a row of capsules leading to each one's full list.
struct GenreStrip: View {
    let genres: [Genre]
    let kind: MediaKind

    var body: some View {
        ShelfScroller {
            ForEach(genres) { genre in
                NavigationLink(value: Route.genre(genre, kind: kind, anime: false)) {
                    Text(genre.name)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Hero

/// Featured titles, one at a time, crossfading every few seconds while the pointer is away.
struct HeroCarousel: View {
    let state: LoadState<[TitleSummary]>
    @State private var index = 0
    @State private var hovering = false
    @State private var width: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { min(max(width * 0.44, 380), 640) }

    var body: some View {
        let titles = state.value ?? []
        ZStack(alignment: .bottom) {
            if titles.isEmpty {
                Rectangle().fill(.quaternary)
                    .overlay(alignment: .bottomLeading) {
                        HeroInfo(title: TitleSummary.placeholders(1)[0])
                            .redacted(reason: .placeholder)
                    }
            } else {
                ForEach(Array(titles.enumerated()), id: \.element.id) { offset, title in
                    if offset == index {
                        HeroSlide(title: title, width: width)
                            .transition(.opacity)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(titles.indices, id: \.self) { dot in
                        Button {
                            show(dot)
                        } label: {
                            Capsule()
                                .fill(.white.opacity(dot == index ? 0.95 : 0.4))
                                .frame(width: dot == index ? 22 : 7, height: 7)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Featured \(dot + 1) of \(titles.count)")
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Layout.gutter)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .leading) { arrow(forward: false, count: titles.count) }
        .overlay(alignment: .trailing) { arrow(forward: true, count: titles.count) }
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .dark)
        .task(id: "\(titles.count)-\(hovering)") {
            guard titles.count > 1, !hovering, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                show((index + 1) % titles.count)
            }
        }
        .task(id: titles.count) {
            // The next slides' images load ahead, so a crossfade never shows an empty frame.
            for title in titles {
                if let url = TMDBImage.url(title.backdropPath, kind: .backdrop, pixels: width * 2) {
                    ImagePipeline.shared.prefetch(url)
                }
            }
        }
    }

    private func show(_ newIndex: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) { index = newIndex }
    }

    @ViewBuilder
    private func arrow(forward: Bool, count: Int) -> some View {
        if count > 1 {
            Button {
                show((index + (forward ? 1 : count - 1)) % count)
            } label: {
                Image(systemName: forward ? "chevron.right" : "chevron.left")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .frame(width: 32, height: 64)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
            .accessibilityLabel(forward ? "Next Featured Title" : "Previous Featured Title")
        }
    }
}

private struct HeroSlide: View {
    let title: TitleSummary
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @State private var details: TitleDetails?

    var body: some View {
        NavigationLink(value: Route.title(title)) {
            Artwork(path: title.backdropPath, kind: .backdrop, width: width)
                .backgroundExtensionEffect()
                .overlay {
                    // Darker towards the text, so it reads over any picture.
                    LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                                   startPoint: .bottomLeading, endPoint: .center)
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .bottom, endPoint: .center)
                }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            HeroInfo(title: title, details: details)
        }
        .task(id: title.ref) {
            details = try? await app.tmdb.details(title.ref)
        }
    }
}

/// The title's logo (or name), what it is, and its buttons.
struct HeroInfo: View {
    let title: TitleSummary
    var details: TitleDetails?
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleLogo(title: title, details: details, maxWidth: 420, maxHeight: 130)
            Text(metadata)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(title.overview)
                .font(.body)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 12) {
                PlayButton(label: "Play") { app.playback.play(title) }
                WatchlistButton(title: title)
                NavigationLink(value: Route.title(title)) {
                    Label("Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Details")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: String {
        var parts = [title.kind.displayName]
        if let year = title.year { parts.append(String(year)) }
        if let genres = details?.genres.prefix(2).map(\.name), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if title.rating > 0 { parts.append("★ " + title.rating.formatted(.number.precision(.fractionLength(1)))) }
        return parts.joined(separator: " · ")
    }
}

/// The title's own logo from TMDB when it has one, which is how the TV app names its titles;
/// otherwise the name, set large.
struct TitleLogo: View {
    let title: TitleSummary
    let details: TitleDetails?
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        Group {
            if let logo = details?.logoPath {
                let ratio = details?.logoAspectRatio ?? 3
                let width = min(maxWidth, maxHeight * ratio)
                Artwork(path: logo, kind: .logo, width: width, contentMode: .fit)
                    .background(.clear)
                    .frame(width: width, height: width / ratio)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .accessibilityLabel(title.name)
            } else {
                Text(title.name)
                    .font(.system(size: 44, weight: .bold))
                    .kerning(-0.8)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.25), value: details?.logoPath)
    }
}

/// The white Play capsule of the TV app: the one prominent action on a page.
struct PlayButton: View {
    let label: String
    var systemImage = "play.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(minWidth: 120, minHeight: 38)
        }
        .buttonStyle(PlayButtonStyle())
    }
}

struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(.white.opacity(isEnabled ? 1 : 0.5), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

struct WatchlistButton: View {
    let title: TitleSummary
    @Environment(AppModel.self) private var app

    var body: some View {
        let saved = app.library.isInWatchlist(title.ref)
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { app.library.toggleWatchlist(title) }
        } label: {
            Image(systemName: saved ? "checkmark" : "plus")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(saved ? "Remove from Watchlist" : "Add to Watchlist")
        .accessibilityLabel(saved ? "Remove from Watchlist" : "Add to Watchlist")
        .sensoryFeedback(.selection, trigger: saved)
    }
}
