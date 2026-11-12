import OpenStreamCore
import SwiftUI

@Observable
final class TitleModel {
    let summary: TitleSummary
    private(set) var details: LoadState<TitleDetails> = .loading
    private(set) var season: LoadState<Season> = .loading
    var seasonNumber: Int? {
        didSet { if oldValue != seasonNumber { loadSeason() } }
    }

    @ObservationIgnored private let tmdb: TMDB
    @ObservationIgnored private var seasonTask: Task<Void, Never>?

    init(summary: TitleSummary, tmdb: TMDB) {
        self.summary = summary
        self.tmdb = tmdb
    }

    func load(fresh: Bool = false, startingSeason: Int?) async {
        do {
            let loaded = try await tmdb.details(summary.ref, fresh: fresh)
            details = .loaded(loaded)
            if summary.kind == .tv, seasonNumber == nil {
                let seasons = loaded.playableSeasons
                seasonNumber = seasons.first { $0.number == startingSeason }?.number ?? seasons.first?.number
            }
        } catch is CancellationError {
        } catch {
            if details.value == nil { details = .failed(error.friendlyMessage) }
        }
    }

    private func loadSeason() {
        guard let seasonNumber else { return }
        seasonTask?.cancel()
        season = .loading
        seasonTask = Task {
            do {
                season = .loaded(try await tmdb.season(summary.ref.id, number: seasonNumber))
            } catch is CancellationError {
            } catch {
                season = .failed(error.friendlyMessage)
            }
        }
    }
}

/// A film's or a series' page, laid out as the TV app's: the picture across the top with the
/// title and Play over it, then episodes, cast, more like it, and the details.
struct TitleView: View {
    let summary: TitleSummary
    @Environment(AppModel.self) private var app
    @State private var model: TitleModel?

    var body: some View {
        Group {
            if let model {
                TitleContent(model: model)
            } else {
                Color.clear
            }
        }
        .navigationTitle(summary.name)
        .toolbar(removing: .title)
        .task(id: summary.ref) {
            if model?.summary.ref != summary.ref {
                model = TitleModel(summary: summary, tmdb: app.tmdb)
            }
            await model?.load(startingSeason: app.library.continueItem(for: summary.ref)?.season)
        }
    }
}

private struct TitleContent: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 900

    var body: some View {
        if case .failed(let message) = model.details {
            LoadFailedView(message: message) { Task { await model.load(fresh: true, startingSeason: nil) } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    TitleHeader(model: model, width: width)
                    if model.summary.kind == .tv, let details = model.details.value {
                        EpisodesSection(model: model, details: details)
                    }
                    if let details = model.details.value {
                        if !details.cast.isEmpty || !details.crew.isEmpty {
                            CastShelf(details: details)
                        }
                        if !details.recommendations.isEmpty {
                            TitleShelf(title: "More Like This", state: .loaded(details.recommendations))
                        }
                        if !details.trailers.isEmpty {
                            TrailersShelf(trailers: details.trailers, backdrop: details.summary.backdropPath)
                        }
                        AboutSection(details: details)
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

private struct TitleHeader: View {
    let model: TitleModel
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @State private var showsFullOverview = false

    private var summary: TitleSummary { model.details.value?.summary ?? model.summary }
    private var height: CGFloat { min(max(width * 0.48, 420), 680) }

    var body: some View {
        Artwork(path: summary.backdropPath ?? model.summary.backdropPath, kind: .backdrop, width: width)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.88), .black.opacity(0.4), .clear],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .bottom, endPoint: .center)
            }
            .overlay(alignment: .bottomLeading) { info }
            .heroShape()
            .environment(\.colorScheme, .dark)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleLogo(title: summary, details: model.details.value, maxWidth: 460, maxHeight: 150)
            Text(metadata)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            if !summary.overview.isEmpty {
                Button {
                    showsFullOverview = true
                } label: {
                    Text(summary.overview)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 600, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show the full description")
                .popover(isPresented: $showsFullOverview, arrowEdge: .top) {
                    Text(summary.overview)
                        .padding(20)
                        .frame(width: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                PlayButton(label: playLabel, systemImage: "play.fill") { play() }
                    .disabled(model.details.value == nil && summary.kind == .tv)
                WatchlistButton(title: summary)
                if let trailer = model.details.value?.trailers.first {
                    Link(destination: trailer.url) {
                        Label("Trailer", systemImage: "film")
                            .labelStyle(.iconOnly)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Watch the Trailer")
                }
                ShareLink(item: summary.webURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Share")
            }
            .padding(.top, 4)
            if let item = app.library.continueItem(for: summary.ref), !item.isNext, item.position.duration > 0 {
                HStack(spacing: 10) {
                    ProgressBar(fraction: item.position.fraction)
                        .frame(width: 140)
                    Text(Duration.seconds(item.position.duration - item.position.seconds)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Resume", "Play S1, E3", "Continue S2, E1": what Play will do, before it's pressed.
    private var playLabel: String {
        if let item = app.library.continueItem(for: summary.ref) {
            if let season = item.season, let episode = item.episode {
                return item.isNext ? "Play S\(season), E\(episode)" : "Resume S\(season), E\(episode)"
            }
            return "Resume"
        }
        return summary.kind == .tv ? "Play S1, E1" : "Play"
    }

    private func play() {
        if let item = app.library.continueItem(for: summary.ref) {
            app.playback.resume(item)
        } else {
            app.playback.play(summary, details: model.details.value)
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if let details = model.details.value {
            if !details.genres.isEmpty { parts.append(details.genres.prefix(2).map(\.name).joined(separator: ", ")) }
            if let year = summary.year { parts.append(String(year)) }
            if summary.kind == .movie, let runtime = details.runtime, runtime > 0 {
                parts.append(Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
            if summary.kind == .tv {
                let count = details.playableSeasons.filter { $0.number > 0 }.count
                if count > 0 { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
            }
            if let certification = details.certification { parts.append(certification) }
        } else if let year = summary.year {
            parts.append(String(year))
        }
        if summary.rating > 0 { parts.append("★ " + summary.rating.formatted(.number.precision(.fractionLength(1)))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Episodes

private struct EpisodesSection: View {
    let model: TitleModel
    let details: TitleDetails
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                @Bindable var model = model
                Picker("Season", selection: $model.seasonNumber) {
                    ForEach(details.playableSeasons) { season in
                        Text(season.name).tag(Optional(season.number))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .font(.title2.bold())
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, Layout.gutter)

            switch model.season {
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.gutter)
            default:
                let episodes = model.season.value?.episodes ?? Self.placeholders
                ShelfScroller {
                    ForEach(episodes) { episode in
                        Button {
                            app.playback.play(details.summary, details: details, episode: episode,
                                              seasonEpisodes: episodes)
                        } label: {
                            EpisodeCard(title: details.summary, episode: episode)
                        }
                        .buttonStyle(CardButtonStyle())
                        .disabled(!episode.hasAired)
                        .contextMenu { EpisodeMenu(title: details.summary, episode: episode) }
                    }
                }
                .loadingPlaceholder(model.season.value == nil)
            }
        }
    }

    static let placeholders = (1...6).map {
        Episode(season: 1, number: $0, name: "Episode title", overview: String(repeating: "Episode description. ", count: 6),
                stillPath: nil, airDate: "2000-01-01", runtime: 45)
    }
}

private struct EpisodeCard: View {
    let title: TitleSummary
    let episode: Episode
    @Environment(AppModel.self) private var app
    private let width: CGFloat = 320

    var body: some View {
        let position = app.library.position(title.ref, season: episode.season, episode: episode.number)
        let watched = app.library.isWatched(title.ref, season: episode.season, episode: episode.number)
        CardArtwork(aspectRatio: 16 / 10) {
            Artwork(path: episode.stillPath ?? title.backdropPath, kind: .still, width: width, placeholderSymbol: "tv")
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white)
                            .font(.title3)
                            .shadow(radius: 3)
                            .padding(8)
                            .accessibilityLabel("Watched")
                    }
                }
                .overlay(alignment: .bottom) {
                    CardBand {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(caption)
                                .font(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .opacity(0.8)
                            Text(episode.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(episode.overview.isEmpty ? "\u{00A0}" : episode.overview)
                                .font(.caption)
                                .opacity(0.85)
                                .lineLimit(2, reservesSpace: true)
                            if let position, !watched, position.fraction > 0.01 {
                                ProgressBar(fraction: position.fraction)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
        }
        .frame(width: width)
        .opacity(episode.hasAired ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var parts = ["Episode \(episode.number)"]
        if !episode.hasAired, let date = TMDBDate.parse(episode.airDate) {
            parts.append(date.formatted(.dateTime.month(.abbreviated).day()))
        } else if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.joined(separator: " · ")
    }
}

private struct EpisodeMenu: View {
    let title: TitleSummary
    let episode: Episode
    @Environment(AppModel.self) private var app

    var body: some View {
        let watched = app.library.isWatched(title.ref, season: episode.season, episode: episode.number)
        Button(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "checkmark.circle") {
            app.library.setWatched(!watched, title, season: episode.season, episode: episode.number)
        }
    }
}

// MARK: - Cast, trailers, about

private struct CastShelf: View {
    let details: TitleDetails

    var body: some View {
        Shelf(title: "Cast & Crew") {
            ForEach(details.crew + details.cast, id: \.self) { member in
                NavigationLink(value: Route.person(id: member.id, name: member.name)) {
                    PersonCard(name: member.name, role: member.role, profilePath: member.profilePath)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }
}

private struct TrailersShelf: View {
    let trailers: [Trailer]
    let backdrop: String?

    var body: some View {
        Shelf(title: "Trailers") {
            ForEach(trailers.prefix(8)) { trailer in
                Link(destination: trailer.url) {
                    VStack(alignment: .leading, spacing: 8) {
                        CardArtwork(aspectRatio: 16 / 9) {
                            YouTubeThumbnail(key: trailer.key)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.title)
                                        .foregroundStyle(.white)
                                        .padding(14)
                                        .glassEffect(.regular, in: .circle)
                                }
                        }
                        Text(trailer.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(width: 280)
                }
                .buttonStyle(CardButtonStyle())
                .help("Opens on YouTube")
            }
        }
    }
}

/// Trailers live on YouTube; its thumbnail is the honest picture of each.
private struct YouTubeThumbnail: View {
    let key: String
    @State private var image: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: scale).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .task(id: key) {
                guard let url = URL(string: "https://i.ytimg.com/vi/\(key)/mqdefault.jpg") else { return }
                image = await ImagePipeline.shared.image(url, pixels: 280 * scale)
            }
    }
}

private struct AboutSection: View {
    let details: TitleDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(details.summary.name)
                        .font(.headline)
                    if !details.tagline.isEmpty {
                        Text(details.tagline)
                            .font(.subheadline.italic())
                            .foregroundStyle(.secondary)
                    }
                    Text(details.summary.overview)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560, alignment: .leading)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(value)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = []
        if !details.genres.isEmpty { facts.append(("Genre", details.genres.map(\.name).joined(separator: ", "))) }
        if let date = TMDBDate.parse(details.summary.date) {
            facts.append((details.summary.kind == .movie ? "Released" : "First Aired", date.formatted(date: .long, time: .omitted)))
        }
        if let runtime = details.runtime, runtime > 0 {
            facts.append(("Run Time", Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))))
        }
        if let certification = details.certification { facts.append(("Rated", certification)) }
        if !details.status.isEmpty { facts.append(("Status", details.status)) }
        if let next = TMDBDate.parse(details.nextEpisodeDate) {
            facts.append(("Next Episode", next.formatted(date: .long, time: .omitted)))
        }
        if !details.studios.isEmpty {
            facts.append((details.summary.kind == .movie ? "Studio" : "Network", details.studios.joined(separator: ", ")))
        }
        if let language = details.summary.originalLanguage,
           let name = Locale.current.localizedString(forLanguageCode: language) {
            facts.append(("Language", name))
        }
        if details.originalName != details.summary.name { facts.append(("Original Title", details.originalName)) }
        return facts
    }
}
