import OpenStreamCore
import SwiftUI

/// A titled row that scrolls sideways, with page buttons at its ends while the pointer is over
/// it, as the TV app's rows have on the Mac (a trackpad swipes it as well).
struct Shelf<Content: View>: View {
    let title: String
    var seeAll: Route?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: 4) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
                Spacer()
            }
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Layout.gutter)

            ShelfScroller { content }
        }
    }
}

struct ShelfScroller<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var position = ScrollPosition(edge: .leading)
    @State private var geometry = ScrollState()
    @State private var hovering = false

    private struct ScrollState: Equatable {
        var offset: CGFloat = 0
        var visible: CGFloat = 0
        var total: CGFloat = 0
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                content
            }
            .scrollTargetLayout()
            // Room for a hovered card to lift without being clipped.
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .contentMargins(.horizontal, Layout.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollState.self) { geometry in
            ScrollState(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                        visible: geometry.containerSize.width,
                        total: geometry.contentSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing)
        } action: { _, new in
            geometry = new
        }
        .overlay(alignment: .leading) {
            pageButton(forward: false)
                .opacity(hovering && geometry.offset > 1 ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            pageButton(forward: true)
                .opacity(hovering && geometry.offset + geometry.visible < geometry.total - 1 ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }

    private func pageButton(forward: Bool) -> some View {
        Button {
            let page = max(200, geometry.visible - Layout.gutter * 2 - Layout.cardSpacing)
            let target = geometry.offset + (forward ? page : -page) - Layout.gutter
            withAnimation(.spring(response: 0.45, dampingFraction: 1)) {
                position.scrollTo(x: max(-Layout.gutter, min(target, geometry.total - geometry.visible - Layout.gutter)))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.title3.weight(.semibold))
                .frame(width: 22, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal, 6)
        .accessibilityLabel(forward ? "Next" : "Previous")
    }
}

/// A shelf of titles from a load that may still be running.
struct TitleShelf: View {
    let title: String
    let state: LoadState<[TitleSummary]>
    var style: Style = .poster
    var seeAll: Route?

    enum Style { case poster, wide, ranked }

    var body: some View {
        switch state {
        case .failed:
            EmptyView()
        case .loaded(let titles) where titles.isEmpty:
            EmptyView()
        default:
            let titles = state.value ?? TitleSummary.placeholders(8)
            Shelf(title: title, seeAll: state.value == nil ? nil : seeAll) {
                ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                    TitleLink(title: title) {
                        switch style {
                        case .poster: PosterCard(title: title)
                        case .wide: WideCard(title: title)
                        case .ranked: RankedCard(rank: index + 1, title: title)
                        }
                    }
                }
            }
            .loadingPlaceholder(state.value == nil)
        }
    }
}
