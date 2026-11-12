import OpenStreamCore
import SwiftUI

struct ContinueWatchingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.library.continueWatching.isEmpty {
                ContentUnavailableView("Nothing in Progress", systemImage: "play.circle",
                                       description: Text("Films and series you start appear here, ready to pick up where you left off."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.wideWidth, maximum: Layout.wideWidth + 60),
                                                 spacing: Layout.cardSpacing, alignment: .top)],
                              alignment: .leading, spacing: 28) {
                        ForEach(app.library.continueWatching) { item in
                            Button { app.playback.resume(item) } label: { ContinueCard(item: item) }
                                .buttonStyle(CardButtonStyle())
                                .contextMenu {
                                    Button("Go to \(item.title.kind == .movie ? "Movie" : "Show")", systemImage: "info.circle") {
                                        app.open(.title(item.title))
                                    }
                                    TitleMenuItems(title: item.title)
                                }
                        }
                    }
                    .padding(Layout.gutter)
                }
            }
        }
        .navigationTitle("Continue Watching")
    }
}

struct WatchlistView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.library.watchlist.isEmpty {
                ContentUnavailableView("Your Watchlist Is Empty", systemImage: "bookmark",
                                       description: Text("Add films and series with the + button to keep them here."))
            } else {
                ScrollView {
                    PosterGrid(items: app.library.watchlist) { title in
                        TitleLink(title: title) { PosterCard(title: title, showsCaption: true) }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("Watchlist")
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmsClear = false

    var body: some View {
        Group {
            if app.library.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Films and episodes you finish appear here."))
            } else {
                List {
                    ForEach(days, id: \.0) { day, items in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(items) { item in
                                HistoryRow(item: item)
                                    .contextMenu {
                                        Button("Remove from History", systemImage: "trash", role: .destructive) {
                                            app.library.removeHistory(item)
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { confirmsClear = true }
                    .disabled(app.library.history.isEmpty)
            }
        }
        .confirmationDialog("Clear your watch history?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { app.library.clearHistory() }
        } message: {
            Text("Watched marks and Continue Watching stay as they are.")
        }
    }

    private var days: [(Date, [HistoryItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: app.library.history) { calendar.startOfDay(for: $0.watchedAt) }
        return groups.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        NavigationLink(value: Route.title(item.title)) {
            HStack(spacing: 14) {
                Artwork(path: item.title.posterPath, kind: .poster, width: 40, placeholderSymbol: "film")
                    .frame(width: 40, height: 60)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.name).font(.headline)
                    if let season = item.season, let episode = item.episode {
                        Text("S\(season), E\(episode)" + (item.episodeName.map { " · \($0)" } ?? ""))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.title.kind.displayName).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.watchedAt.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
