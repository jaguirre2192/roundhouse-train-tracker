import XCTest
@testable import TrainTracker

final class JourneySearchLayoutTests: XCTestCase {
    func testLandingColumnsRequireRoomAndKeepAccessibilityReadingOrder() {
        XCTAssertTrue(JourneySearchLayout.usesTwoColumnForm(
            availableWidth: 760, isRegularWidth: true, isAccessibilitySize: false
        ))
        for (width, regular, accessible) in [(759.0, true, false), (951, false, false), (951, true, true)] {
            XCTAssertFalse(JourneySearchLayout.usesTwoColumnForm(
                availableWidth: width, isRegularWidth: regular, isAccessibilitySize: accessible
            ))
        }
    }

    func testRegularDetailBesideMyTripsKeepsResultsInOneReadableColumn() {
        // iPad portrait with its 420pt My Trips sidebar visible: the old size-class-only
        // branch reserved another 400pt and squeezed the results into about 200pt.
        XCTAssertFalse(JourneySearchLayout.usesSplitLayout(
            availableWidth: 612, isRegularWidth: true, isAccessibilitySize: false
        ))
        XCTAssertFalse(JourneySearchLayout.usesSplitLayout(
            availableWidth: 774, isRegularWidth: true, isAccessibilitySize: false
        ))
    }

    func testFullWidthSearchKeepsTheFormBesideResultsWhenBothFit() {
        XCTAssertTrue(JourneySearchLayout.usesSplitLayout(
            availableWidth: 1032, isRegularWidth: true, isAccessibilitySize: false
        ))
        XCTAssertTrue(JourneySearchLayout.usesSplitLayout(
            availableWidth: 946, isRegularWidth: true, isAccessibilitySize: false
        ))
    }

    func testCompactAndAccessibilitySearchKeepTheSinglePhaseLayout() {
        XCTAssertFalse(JourneySearchLayout.usesSplitLayout(
            availableWidth: 946, isRegularWidth: false, isAccessibilitySize: false
        ))
        XCTAssertFalse(JourneySearchLayout.usesSplitLayout(
            availableWidth: 1032, isRegularWidth: true, isAccessibilitySize: true
        ))
        XCTAssertFalse(JourneySearchLayout.usesSplitLayout(
            availableWidth: 0, isRegularWidth: true, isAccessibilitySize: false
        ))
    }
}
