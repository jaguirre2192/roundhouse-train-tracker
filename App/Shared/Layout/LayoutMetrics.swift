import SwiftUI

enum LayoutMetrics {
    static let pageInset = TrainTrackerSpacing.space20
    static let sectionSpacing = TrainTrackerSpacing.space24
    static let rowSpacing = TrainTrackerSpacing.space12
    static let cardInset = TrainTrackerSpacing.space18
    static let expandedCardInset = TrainTrackerSpacing.space24
    static let contentMaxWidth: CGFloat = 760
    static let desktopDetailMaxWidth: CGFloat = 1040
    static let iconRailWidth = TrainTrackerSpacing.space24
    static let mobileFloatingBarClearance = TrainTrackerSpacing.space84
    /// Regular-width leading panel (Map trip card, Search form): ticket-sized, like a Maps place
    /// card, so panels line up from tab to tab.
    static let sidePanelWidth: CGFloat = 400
    /// Grouped forms on regular width stop growing here and centre on the page wash.
    static let readableFormWidth: CGFloat = 680
}

extension View {
    /// Centres a scrolling form's content within `maxWidth` while the page (and its scrolling)
    /// still spans the full width. Narrower than `maxWidth`, the form keeps its default margins.
    /// `minimumMargin` replaces the list's default side margin on narrow widths, for lists that
    /// share edges with the app's scroll pages.
    func trainTrackerReadableWidth(
        _ maxWidth: CGFloat = LayoutMetrics.readableFormWidth,
        minimumMargin: CGFloat = 0
    ) -> some View {
        modifier(ReadableWidthModifier(maxWidth: maxWidth, minimumMargin: minimumMargin))
    }
}

extension View {
    /// Leaves the navigation bar without a title when the screen draws its own title in the
    /// content column, so the title shares the content's leading edge instead of repeating,
    /// centred, in the bar. The navigation title still names the screen for VoiceOver and back
    /// buttons. Pair it with an inline title display mode.
    func trainTrackerBarTitleHidden(_ hidden: Bool = true) -> some View {
        toolbar {
            if hidden {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

private struct ReadableWidthModifier: ViewModifier {
    let maxWidth: CGFloat
    var minimumMargin: CGFloat = 0
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin > 0 ? margin : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { max(minimumMargin, ($0.size.width - maxWidth) / 2) } action: {
                margin = $0
            }
    }
}
