import Foundation

enum JourneySearchLayout {
    /// Two readable control columns fit on an expanded canvas without spreading one form
    /// across it. Accessibility type keeps the single-column reading order.
    static func usesTwoColumnForm(
        availableWidth: CGFloat,
        isRegularWidth: Bool,
        isAccessibilitySize: Bool
    ) -> Bool {
        isRegularWidth && !isAccessibilitySize && availableWidth >= 760
    }

    /// A 400pt form needs a full reading column alongside it, not the remainder of an
    /// already narrow split-view detail. Below this width each search phase uses the column.
    static let minimumResultsWidth: CGFloat = 500

    static func usesSplitLayout(
        availableWidth: CGFloat,
        isRegularWidth: Bool,
        isAccessibilitySize: Bool
    ) -> Bool {
        isRegularWidth && !isAccessibilitySize
            && availableWidth >= LayoutMetrics.sidePanelWidth + minimumResultsWidth
    }
}
