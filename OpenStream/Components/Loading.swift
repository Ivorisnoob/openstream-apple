import OpenStreamCore
import SwiftUI

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension Error {
    /// What a viewer reads when something didn't load: never a code dump.
    var friendlyMessage: String {
        if let error = self as? LocalizedError, let text = error.errorDescription { return text }
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline."
            case .timedOut: return "The connection timed out."
            default: return "Couldn't connect."
            }
        }
        return localizedDescription
    }
}

/// A page that couldn't load, with a way to try again.
struct LoadFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

extension TitleSummary {
    /// Stand-ins drawn redacted while a shelf loads, so the layout never shifts.
    static func placeholders(_ count: Int, kind: MediaKind = .movie) -> [TitleSummary] {
        (0..<count).map { index in
            TitleSummary(ref: TitleRef(kind: kind, id: -1 - index), name: "Loading title",
                         overview: String(repeating: "Loading the description of this title. ", count: 3),
                         date: "2000-01-01")
        }
    }

    var isPlaceholder: Bool { ref.id < 0 }
}

extension View {
    /// Draws the real view from stand-in data, redacted, and tells VoiceOver it's loading.
    @ViewBuilder func loadingPlaceholder(_ isLoading: Bool) -> some View {
        if isLoading {
            redacted(reason: .placeholder)
                .allowsHitTesting(false)
                .accessibilityLabel("Loading")
        } else {
            self
        }
    }
}
