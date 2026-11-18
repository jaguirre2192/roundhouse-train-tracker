import XCTest
@testable import TrainTracker

@MainActor
final class JourneyPanelGeometryTests: XCTestCase {
    func testOuterPhoneKeepsBottomSheet() {
        let space = geometry(width: 466, height: 678)
        XCTAssertFalse(space.floatsBeside)
    }

    func testBothInnerOrientationsKeepPanelWithinLeadingHalf() {
        for (width, height) in [(669.0, 951.0), (951.0, 669.0)] {
            let space = geometry(width: width, height: height)
            XCTAssertTrue(space.floatsBeside)
            XCTAssertLessThanOrEqual(space.panelWidth + 2 * JourneyPanelGeometry.margin, width / 2)
            XCTAssertGreaterThan(space.panelWidth, 260)
        }
    }

    func testActiveFoldOverridesTheFlatScreenMidpoint() {
        var space = geometry(width: 950, height: 669)
        space.leadingFoldBoundary = 350
        XCTAssertTrue(space.floatsBeside)
        XCTAssertLessThanOrEqual(space.panelWidth + 2 * JourneyPanelGeometry.margin, 350)
    }

    func testNarrowWindowWithActiveFoldNeverCrossesItsBoundary() {
        var space = geometry(width: 540, height: 760)
        space.leadingFoldBoundary = 250
        XCTAssertTrue(space.floatsBeside)
        XCTAssertGreaterThan(space.panelWidth, 0)
        XCTAssertLessThanOrEqual(space.panelWidth + 2 * JourneyPanelGeometry.margin, 250)
    }

    func testMapControlsClearTheEntireFoldWhenPanelWidthIsCapped() {
        var space = geometry(width: 1100, height: 760)
        space.leadingFoldBoundary = 530
        space.trailingFoldBoundary = 570
        XCTAssertEqual(space.panelWidth, TrainTrackerDevice.isDuo ? 360 : 396)
        XCTAssertEqual(space.mapLeadingInset, 570)
        XCTAssertLessThan(space.panelWidth + 2 * JourneyPanelGeometry.margin, space.leadingFoldBoundary!)
    }

    func testTabletopPanelStopsAboveTheHorizontalHinge() {
        var space = geometry(width: 669, height: 951)
        space.upperFoldBoundary = 460
        XCTAssertTrue(space.floatsBeside)
        XCTAssertEqual(space.maximumPanelHeight + 2 * JourneyPanelGeometry.margin, 460)
    }

    private func geometry(width: Double, height: Double) -> JourneyPanelGeometry {
        var space = JourneyPanelGeometry()
        space.width = width
        space.height = height
        return space
    }
}
