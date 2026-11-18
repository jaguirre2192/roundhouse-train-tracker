import SwiftUI
import XCTest
@testable import TrainTracker

/// Guards the 2026-08-24 UI/UX audit finding that an iPhone result row truncated a multi-leg
/// service to `SNCF · TGV 9579 · ÖBB · Night…`, hiding the final train number.
final class JourneyOptionRowLayoutTests: XCTestCase {
    private static let multiLeg = ["SNCF · TGV 9579", "ÖBB · Nightjet 237"]

    func testStandardSizesAllowTwoLinesOfServiceIdentity() {
        XCTAssertEqual(JourneyOptionRowLayout.serviceLineLimit(for: .large), 2)
        XCTAssertEqual(JourneyOptionRowLayout.serviceLineLimit(for: .xxxLarge), 2)
    }

    func testAccessibilitySizesKeepMoreOfTheServiceIdentity() {
        XCTAssertEqual(JourneyOptionRowLayout.serviceLineLimit(for: .accessibility1), 4)
        XCTAssertEqual(JourneyOptionRowLayout.serviceLineLimit(for: .accessibility5), 4)
    }

    func testServiceIdentityGrowthStaysBounded() {
        for size in DynamicTypeSize.allCases {
            let limit = JourneyOptionRowLayout.serviceLineLimit(for: size)
            XCTAssertGreaterThanOrEqual(limit, 2, "\(size) truncates a two-leg service to one line")
            XCTAssertLessThanOrEqual(limit, 4, "\(size) lets the service identity grow unbounded")
        }
    }

    func testMultiLegSummaryKeepsEveryOperatorAndTheFinalTrainNumber() {
        let summary = JourneyOptionRowLayout.serviceSummary(
            trainIdentities: Self.multiLeg,
            changes: "1 change"
        )

        XCTAssertEqual(
            summary.replacingOccurrences(of: "\u{00A0}", with: " "),
            "SNCF · TGV 9579  •  ÖBB · Nightjet 237"
        )
        XCTAssertTrue(summary.hasSuffix("Nightjet\u{00A0}237"))
    }

    func testEachLegKeepsItsOperatorAndTrainNumberOnOneLine() {
        let summary = JourneyOptionRowLayout.serviceSummary(
            trainIdentities: Self.multiLeg,
            changes: "1 change"
        )

        // Only the separator between legs offers ordinary-space wrap opportunities.
        let legs = summary.components(separatedBy: JourneyOptionRowLayout.serviceSeparator)
        XCTAssertEqual(legs.count, 2)
        XCTAssertTrue(legs.allSatisfy { !$0.contains(" ") })
        XCTAssertEqual(legs.last, "ÖBB\u{00A0}·\u{00A0}Nightjet\u{00A0}237")
    }

    func testServiceSummaryFallsBackToChangesWhenNoTrainIsIdentified() {
        XCTAssertEqual(
            JourneyOptionRowLayout.serviceSummary(trainIdentities: [], changes: "Direct"),
            "Direct"
        )
    }
}
