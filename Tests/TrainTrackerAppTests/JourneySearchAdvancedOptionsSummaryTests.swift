import XCTest
@testable import TrainTracker

final class JourneySearchAdvancedOptionsSummaryTests: XCTestCase {
    func testSummaryExplainsTheActiveConstraints() {
        XCTAssertEqual(
            JourneySearchAdvancedOptionsSummary.text(directOnly: true, maximumTransfers: 3),
            "Direct trains only"
        )
        XCTAssertEqual(
            JourneySearchAdvancedOptionsSummary.text(directOnly: false, maximumTransfers: 2),
            "Up to 2 changes"
        )
    }
}
