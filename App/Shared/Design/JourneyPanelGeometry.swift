import SwiftUI

/// Shared map-panel placement. Wide phone displays keep controls on the leading half;
/// an active vertical fold supplies the exact boundary instead of a guessed device width.
struct JourneyPanelGeometry: Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var bottom: CGFloat = 0
    var leadingFoldBoundary: CGFloat?
    var trailingFoldBoundary: CGFloat?
    var upperFoldBoundary: CGFloat?

    init() {}

    init(_ proxy: GeometryProxy) {
        width = proxy.size.width
        height = proxy.size.height
        bottom = proxy.safeAreaInsets.bottom
        if #available(iOS 27.1, *) {
            let fold = proxy.reservedRegions(kind: .division).first {
                $0.isActive && $0.frame.height > $0.frame.width
                    && $0.frame.minX > 0 && $0.frame.maxX < proxy.size.width
            }?.frame
            leadingFoldBoundary = fold?.minX
            trailingFoldBoundary = fold?.maxX
            upperFoldBoundary = proxy.reservedRegions(kind: .division).first {
                $0.isActive && $0.frame.width > $0.frame.height
                    && $0.frame.minY > 0 && $0.frame.maxY < proxy.size.height
            }?.frame.minY
        }
    }

    var floatsBeside: Bool {
        leadingFoldBoundary != nil || upperFoldBoundary != nil
            || width >= 620 || (width >= 560 && height < 520)
    }

    var panelWidth: CGFloat {
        min(TrainTrackerDevice.isDuo ? 360 : 396,
            max(1, (leadingFoldBoundary ?? width * 0.5) - 2 * Self.margin))
    }

    /// Map controls and camera framing begin beyond the entire reserved fold region.
    var mapLeadingInset: CGFloat {
        guard floatsBeside else { return 0 }
        return max(panelWidth + 2 * Self.margin, trailingFoldBoundary ?? 0)
    }

    /// In tabletop posture the scrolling panel ends before the horizontal hinge.
    var maximumPanelHeight: CGFloat {
        max(1, min(height, upperFoldBoundary ?? height) - 2 * Self.margin)
    }

    static let margin: CGFloat = TrainTrackerSpacing.space16
}
