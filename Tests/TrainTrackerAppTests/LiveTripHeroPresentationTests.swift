import Foundation
import XCTest
@testable import TrainTracker

final class LiveTripHeroPresentationTests: XCTestCase {
    @MainActor
    func testLiveHeroPrioritizesNextStopPlatformAndFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_784_574_000)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: now).first)
        let presentation = ActiveTripCardPresentation(
            trip: trip,
            referenceDate: now,
            lastSuccessfulCheck: now
        )

        XCTAssertEqual(presentation.nextStopValue, "Wilmington")
        XCTAssertEqual(presentation.platformValue, "2")
        XCTAssertEqual(presentation.freshnessValue, "Just now")
        XCTAssertEqual(presentation.destinationCountryCode, "US")
    }

    @MainActor
    func testUncheckedHeroKeepsExpectedTimesSeparateFromCheckFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_784_574_000)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: now).last)
        let presentation = ActiveTripCardPresentation(trip: trip, referenceDate: now)

        XCTAssertEqual(presentation.nextStopValue, "Orlando")
        XCTAssertEqual(presentation.nextStopLabel, "Board at")
        XCTAssertEqual(presentation.platformValue, "Not in feed")
        XCTAssertEqual(presentation.freshnessValue, "Not yet")
        XCTAssertEqual(presentation.status.kind, .onTime)
        XCTAssertEqual(presentation.status.text, "On time")
    }

    @MainActor
    func testCardAccessibilitySummaryIncludesEveryVisibleOperationalFact() throws {
        let now = Date(timeIntervalSince1970: 1_784_574_000)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: now).first)

        let summary = tripAccessibilitySummary(trip, referenceDate: now)

        XCTAssertTrue(summary.contains("status: 7 minutes late"))
        XCTAssertTrue(summary.contains("next stop: Wilmington"))
        XCTAssertTrue(summary.contains("Track 2 · operator confirmed"), "Amtrak assignments are tracks")
        XCTAssertTrue(summary.contains("checked: Not yet"))
        XCTAssertFalse(summary.contains("live data:"))
    }

    @MainActor
    func testPositionTimestampDoesNotEstablishTimingFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_784_574_000)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: now).first)
        XCTAssertFalse(trip.positions.isEmpty)

        let presentation = ActiveTripCardPresentation(trip: trip, referenceDate: now)

        XCTAssertEqual(presentation.freshnessValue, "Not yet")
        XCTAssertNotEqual(presentation.detailStatusValue, "Live")
    }

    @MainActor
    func testFailedRefreshRetainsLastSuccessfulCheckInPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_784_574_000)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: now).first)
        let presentation = ActiveTripCardPresentation(
            trip: trip,
            referenceDate: now,
            lastSuccessfulCheck: now.addingTimeInterval(-600),
            lastRefreshFailed: true
        )

        XCTAssertEqual(presentation.freshnessValue, "10m ago · Retry failed")
    }
}
