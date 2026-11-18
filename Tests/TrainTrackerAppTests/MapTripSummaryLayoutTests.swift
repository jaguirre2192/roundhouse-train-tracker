import SwiftUI
import XCTest
@testable import TrainTracker

final class MapTripSummaryLayoutTests: XCTestCase {
    func testMapControlsMeetMinimumTouchTarget() {
        XCTAssertGreaterThanOrEqual(MapTripSummaryLayout.controlTargetSize, 44)
    }

    func testAccessibilitySizesStackStatusAndAllowTitleToWrap() {
        XCTAssertTrue(MapTripSummaryLayout.stacksStatus(at: .accessibility1))
        XCTAssertEqual(MapTripSummaryLayout.tripTitleLineLimit(at: .accessibility1), 2)
    }

    func testStandardSizesKeepCompactHeader() {
        XCTAssertFalse(MapTripSummaryLayout.stacksStatus(at: .large))
        XCTAssertEqual(MapTripSummaryLayout.tripTitleLineLimit(at: .large), 1)
    }

}
