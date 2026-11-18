import SwiftUI
import UIKit

/// The content and division are measured in the same window coordinates. A trailing system
/// rail can shorten one pane without moving the physical hinge.
struct JourneySpreadColumns {
    let first: CGFloat
    let second: CGFloat
    let gap: CGFloat

    init?(content: ClosedRange<CGFloat>, division: ClosedRange<CGFloat>?, minimum: CGFloat, rightToLeft: Bool = false) {
        let width = content.upperBound - content.lowerBound
        let standardGap = TrainTrackerSpacing.space16
        let left: CGFloat
        let right: CGFloat
        if let division, content.contains(division.lowerBound), content.contains(division.upperBound) {
            let creaseWidth = division.upperBound - division.lowerBound
            gap = max(standardGap, creaseWidth + TrainTrackerSpacing.space8)
            let clearance = (gap - creaseWidth) / 2
            left = division.lowerBound - content.lowerBound - clearance
            right = content.upperBound - division.upperBound - clearance
        } else {
            gap = standardGap
            left = (width - gap) / 2
            right = left
        }
        guard min(left, right) >= minimum else { return nil }
        first = rightToLeft ? right : left
        second = rightToLeft ? left : right
    }

    var gridItems: [GridItem] {
        [GridItem(.fixed(first), spacing: gap, alignment: .top), GridItem(.fixed(second), spacing: 0, alignment: .top)]
    }

    /// Only the Duo inner display in landscape has a flat physical crease and a side system rail.
    @MainActor static var innerLandscapeWindowMidX: CGFloat? {
        guard TrainTrackerDevice.isDuo else { return nil }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive && $0.traitCollection.userInterfaceIdiom == .phone && $0.keyWindow != nil
        }
        guard let window = scene?.keyWindow, window.bounds.width >= 760,
              window.bounds.width > window.bounds.height else { return nil }
        return window.bounds.midX
    }

    static func division(in proxy: GeometryProxy, windowMidX: CGFloat?) -> ClosedRange<CGFloat>? {
        guard TrainTrackerDevice.isDuo else { return nil }
        let page = proxy.frame(in: .global)
        let space = JourneyPanelGeometry(proxy)
        if let left = space.leadingFoldBoundary, let right = space.trailingFoldBoundary {
            return (page.minX + left)...(page.minX + right)
        }
        guard let windowMidX else { return nil }
        // A flat Duo can still expose its physical division, though it is inactive. Use
        // the hosting window midpoint when only the asymmetric system rail is reported.
        if #available(iOS 27.1, *), let fold = proxy.reservedRegions(kind: .division, options: .includeInactive)
            .first(where: { $0.frame.height > $0.frame.width && $0.frame.midX > 0 && $0.frame.midX < page.width }) {
            return (page.minX + fold.frame.minX)...(page.minX + fold.frame.maxX)
        }
        return windowMidX...windowMidX
    }
}
