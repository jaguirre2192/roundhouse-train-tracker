import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class StationShortCodeTests: XCTestCase {
    func testPrefersCRSThenSourceNativeLetterCodes() {
        XCTAssertEqual(StationShortCode.code(for: station(codes: [.crs: "pad", .sourceNative: "LDN"])), "PAD")
        XCTAssertEqual(StationShortCode.code(for: station(codes: [.sourceNative: " nyp "])), "NYP")
    }

    func testRejectsNumericIdentifiersAndNamesInsteadOfInventingCodes() {
        XCTAssertNil(StationShortCode.code(for: station(codes: [.sourceNative: "8000105", .eva: "8000105"])))
        XCTAssertNil(StationShortCode.code(for: station(codes: [.sourceNative: "12345"])))
        XCTAssertNil(StationShortCode.code(for: station(codes: [.sourceNative: "Philadelphia"])))
        XCTAssertNil(StationShortCode.code(for: station(codes: [.gtfs: "WIL"])))
        XCTAssertNil(StationShortCode.code(for: nil))
    }

    func testAcceptsShortAlphanumericCodes() {
        XCTAssertEqual(StationShortCode.normalized("ab1"), "AB1")
        XCTAssertNil(StationShortCode.normalized("A"))
        XCTAssertNil(StationShortCode.normalized("NY-P"))
    }
}

final class RouteLineSummaryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    func testShortRoutesShowEveryStop() {
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 2, anchor: 0), [0, 1])
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 3, anchor: 1), [0, 1, 2])
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 5, anchor: 2), [0, 1, 2, 3, 4])
    }

    func testLongRoutesKeepEndsAndTheStopsAroundTheAnchor() {
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 12, anchor: 6), [0, 5, 6, 7, 11])
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 12, anchor: 0), [0, 1, 2, 3, 11])
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 12, anchor: 11), [0, 8, 9, 10, 11])
        XCTAssertEqual(RouteLineSummary.selectedIndices(count: 12, anchor: 1), [0, 1, 2, 3, 11])
    }

    func testNodeStatesFollowTheFocusStop() {
        let stops = makeStops(count: 5)
        let summary = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway,
            referenceDate: base, showsLiveMarker: false, confirmedPassedStopIDs: [stops[0].id, stops[1].id]
        )
        XCTAssertEqual(summary.nodes.map(\.state), [.passed, .passed, .next, .upcoming, .upcoming])
        // The same moment by the clock alone: the earlier stops are due, not reached.
        let byClock = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway, referenceDate: base, showsLiveMarker: true
        )
        XCTAssertEqual(byClock.nodes.map(\.state), [.due, .due, .next, .upcoming, .upcoming])
        XCTAssertNil(byClock.liveMarkerFraction, "no marker past a stop the train is not reported past")
        XCTAssertEqual(summary.nodes.map(\.code), ["AAA", "BBB", "CCC", "DDD", "EEE"])
    }

    func testEndedJourneyIsFullyPassedAndUpcomingJourneyHasNothingPassed() {
        let stops = makeStops(count: 4)
        let ended = RouteLineSummary(stops: stops, focusStopID: nil, phase: .ended, referenceDate: base, showsLiveMarker: true,
                                     isArrivalConfirmed: true)
        XCTAssertEqual(Set(ended.nodes.map(\.state)), [.passed])
        let elapsed = RouteLineSummary(stops: stops, focusStopID: nil, phase: .ended, referenceDate: base, showsLiveMarker: true)
        XCTAssertEqual(Set(elapsed.nodes.map(\.state)), [.due], "a timetable that ran out fills nothing")
        XCTAssertNil(ended.liveMarkerFraction)

        let upcoming = RouteLineSummary(stops: stops, focusStopID: nil, phase: .upcoming, referenceDate: base, showsLiveMarker: true)
        XCTAssertEqual(Set(upcoming.nodes.map(\.state)), [.upcoming])
        XCTAssertNil(upcoming.liveMarkerFraction)
    }

    func testLiveMarkerSitsBetweenPassedAndNextStopByElapsedTime() throws {
        let stops = makeStops(count: 5)
        // Stop 1 departs at +60 min and stop 2 arrives at +120 min; now is +90 min.
        let summary = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway,
            referenceDate: base.addingTimeInterval(90 * 60), showsLiveMarker: true, confirmedPassedStopIDs: [stops[1].id]
        )
        let fraction = try XCTUnwrap(summary.liveMarkerFraction)
        XCTAssertEqual(fraction, (1 + 0.5) / 4, accuracy: 0.0001)
    }

    func testLiveMarkerStaysClearOfTheDots() throws {
        let stops = makeStops(count: 5)
        let early = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway,
            referenceDate: base.addingTimeInterval(61 * 60), showsLiveMarker: true, confirmedPassedStopIDs: [stops[1].id]
        )
        XCTAssertEqual(try XCTUnwrap(early.liveMarkerFraction), (1 + 0.2) / 4, accuracy: 0.0001)
        let late = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway,
            referenceDate: base.addingTimeInterval(200 * 60), showsLiveMarker: true, confirmedPassedStopIDs: [stops[1].id]
        )
        XCTAssertEqual(try XCTUnwrap(late.liveMarkerFraction), (1 + 0.8) / 4, accuracy: 0.0001)
    }

    func testNoLiveMarkerForScheduledDataOrBeforeTheFirstStopIsPassed() {
        let stops = makeStops(count: 5)
        let scheduled = RouteLineSummary(
            stops: stops, focusStopID: stops[2].id, phase: .underway, referenceDate: base, showsLiveMarker: false
        )
        XCTAssertNil(scheduled.liveMarkerFraction)
        let atOrigin = RouteLineSummary(
            stops: stops, focusStopID: stops[0].id, phase: .underway, referenceDate: base, showsLiveMarker: true
        )
        XCTAssertNil(atOrigin.liveMarkerFraction)
    }

    func testCompactTimeOmitsTheDayPeriodAndUsesTheStopsZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T20:04:00Z"))
        XCTAssertEqual(
            RouteLineSummary.compactTime(date, timeZoneIdentifier: "America/New_York", locale: Locale(identifier: "en_US")),
            "4:04"
        )
        XCTAssertEqual(
            RouteLineSummary.compactTime(date, timeZoneIdentifier: "Europe/Berlin", locale: Locale(identifier: "de_DE")),
            "22:04"
        )
    }

    private func makeStops(count: Int) -> [StopTime] {
        let codes = ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH", "III", "JJJ", "KKK", "LLL"]
        return (0..<count).map { index in
            let time = base.addingTimeInterval(Double(index) * 60 * 60)
            return StopTime(
                station: station(code: codes[index]),
                sequence: index,
                scheduledArrival: index == 0 ? nil : time,
                scheduledDeparture: index == count - 1 ? nil : time
            )
        }
    }
}

final class TicketStubFieldsTests: XCTestCase {
    func testLinkedTicketWithCoachAndSeatReplacesArrivalAndStopsLeft() {
        let fields = TicketStubFields.live(
            nextStop: "WIL", platformNoun: "Track", platform: "2",
            coach: "6", seat: "14A", arrivalTime: "5:44 PM", stopsLeft: 3
        )
        XCTAssertEqual(fields.map(\.label), ["Next", "Track", "Coach", "Seat"])
        XCTAssertEqual(fields.map(\.value), ["WIL", "2", "6", "14A"])
    }

    func testWithoutAFullSeatAssignmentTheStubShowsArrivalAndStopsLeft() {
        let fields = TicketStubFields.live(
            nextStop: "WIL", platformNoun: "Platform", platform: nil,
            coach: "6", seat: "  ", arrivalTime: "5:44 PM", stopsLeft: 3
        )
        XCTAssertEqual(fields.map(\.label), ["Next", "Platform", "Arrives", "Stops left"])
        XCTAssertEqual(fields.map(\.value), ["WIL", TicketStubField.unavailableValue, "5:44 PM", "3"])
        XCTAssertFalse(fields[1].isAvailable)
    }

    func testStubAlwaysHasFourSlots() {
        let fields = TicketStubFields.live(
            nextStop: nil, platformNoun: "Track", platform: nil,
            coach: nil, seat: nil, arrivalTime: nil, stopsLeft: nil
        )
        XCTAssertEqual(fields.count, 4)
        XCTAssertTrue(fields.allSatisfy { !$0.isAvailable })
    }
}

private func station(code: String) -> Station {
    station(codes: [.sourceNative: code])
}

private func station(codes: [StationCodeKind: String]) -> Station {
    Station(
        id: RailIdentifier(rawValue: "test:station:\(codes.values.sorted().joined())"),
        names: [LocalizedStationName("Station")],
        codes: codes,
        location: GeoCoordinate(latitude: 40, longitude: -75),
        countryCode: "US"
    )
}

final class LiveLineTicketPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testLiveMarkerNeedsARecentSuccessfulRealtimeCheckWhileUnderway() {
        XCTAssertTrue(show(.delayed, .underway, checked: now.addingTimeInterval(-60)))
        XCTAssertTrue(show(.onTime, .underway, checked: now.addingTimeInterval(-299)))
        XCTAssertFalse(show(.delayed, .underway, checked: now.addingTimeInterval(-301)))
        XCTAssertFalse(show(.delayed, .underway, checked: nil))
        XCTAssertFalse(show(.delayed, .underway, checked: now, failed: true))
        XCTAssertFalse(show(.scheduled, .underway, checked: now))
        XCTAssertFalse(show(.delayed, .upcoming, checked: now))
        XCTAssertFalse(show(.delayed, .ended, checked: now))
    }

    func testFreshnessCopy() {
        XCTAssertEqual(
            LiveLineTicketPresentation.freshnessText(basis: "Estimated times", lastSuccessfulCheck: nil, lastRefreshFailed: false, referenceDate: now),
            "Estimated times · Not checked yet"
        )
        XCTAssertEqual(
            LiveLineTicketPresentation.freshnessText(basis: "Live data", lastSuccessfulCheck: now, lastRefreshFailed: false, referenceDate: now),
            "Live data · Checked just now"
        )
        XCTAssertEqual(
            LiveLineTicketPresentation.freshnessText(basis: "Estimated times", lastSuccessfulCheck: nil, lastRefreshFailed: true, referenceDate: now),
            "Estimated times · Check failed"
        )
        XCTAssertEqual(
            LiveLineTicketPresentation.freshnessText(
                basis: "Live data", lastSuccessfulCheck: now.addingTimeInterval(-180), lastRefreshFailed: false, referenceDate: now
            ),
            "Live data · Checked 3 min ago"
        )
    }

    func testOneFreshnessVocabularyAcrossScreens() {
        let failed = TripFreshness(lastSuccessfulCheck: now, lastRefreshFailed: true)
        XCTAssertEqual(failed, .checkFailed)
        XCTAssertEqual(failed.text(at: now), "Check failed · Saved times shown")
        XCTAssertFalse(failed.isConfirmed)
        XCTAssertEqual(TripFreshness(lastSuccessfulCheck: nil, lastRefreshFailed: false).text(at: now), "Not checked yet")
        let checked = TripFreshness(lastSuccessfulCheck: now.addingTimeInterval(-2 * 3_600), lastRefreshFailed: false)
        XCTAssertTrue(checked.isConfirmed)
        XCTAssertTrue(checked.text(at: now, timeZone: TimeZone(identifier: "UTC")!).hasPrefix("Last checked "))
    }

    func testArrivalSlotNamesTheDestination() {
        let fields = TicketStubFields.live(
            nextStop: "WIL", platformNoun: "Track", platform: "2",
            coach: nil, seat: nil, arrivalTime: "8:27 PM", destinationCode: "WAS", stopsLeft: 3
        )
        XCTAssertEqual(fields.map(\.label), ["Next", "Track", "At WAS", "Stops left"])
    }

    private func show(
        _ status: TripPresentationStatus.Kind, _ phase: RailJourneyProgress.Phase, checked: Date?, failed: Bool = false
    ) -> Bool {
        LiveLineTicketPresentation.showsLiveMarker(
            status: status, phase: phase, lastSuccessfulCheck: checked, lastRefreshFailed: failed, referenceDate: now
        )
    }
}
