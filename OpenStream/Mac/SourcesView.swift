import OpenStreamCore
import SwiftUI

/// Where streams come from: turn sources on or off and drag them into the order they're
/// preferred in. Laid out as a System Settings list.
struct SourcesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.sources
        let supported = store.entries.filter(\.isSupported)
        let unsupported = store.entries.filter { !$0.isSupported }
        Form {
            Section {
                ForEach(supported) { entry in
                    SourceRow(entry: entry)
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Sources")
            } footer: {
                Text("Every source on is asked at once and the best stream plays first; when two are as good, the one higher in this list wins. Drag to reorder. Web players are only asked when the others find nothing.")
            }
            if !unsupported.isEmpty {
                Section {
                    ForEach(unsupported) { entry in
                        SourceRow(entry: entry)
                    }
                } header: {
                    Text("Coming to the Mac")
                } footer: {
                    Text("These anime sites need their own readers, which this version doesn't have yet.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sources")
        .navigationSubtitle("\(store.enabledCount) on")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                }
                .help("Check for new and updated sources")
            }
        }
    }
}

private struct SourceRow: View {
    let entry: Catalog.Entry
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.sources
        Toggle(isOn: Binding { store.isEnabled(entry) } set: { store.setEnabled($0, entry) }) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint.gradient, in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text([entry.kindLabel, entry.language].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let summary = store.summary(entry.id) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(store.resting.contains(entry.id) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    if let description = entry.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .disabled(!entry.isSupported)
    }

    private var symbol: String {
        switch entry.kindLabel {
        case "Direct": "bolt.fill"
        case "Stremio add-on": "puzzlepiece.extension.fill"
        case "Web player": "globe"
        default: "sparkles"
        }
    }

    private var tint: Color {
        switch entry.kindLabel {
        case "Direct": .orange
        case "Stremio add-on": .purple
        case "Web player": .blue
        default: .gray
        }
    }
}
