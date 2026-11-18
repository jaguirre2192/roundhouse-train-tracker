import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TripPresentationEvidenceTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_784_574_000)

    func testEmptyStopsDoNotImplyCancellationOrArrival() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: []))

        XCTAssertEqual(presentation.kind, .unavailable)
        XCTAssertEqual(presentation.text, "No times yet")
    }

    func testCapabilitiesWithoutExpectedTimeRemainScheduled() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [makeStop(scheduled: time)]))

        XCTAssertEqual(presentation.kind, .scheduled)
        XCTAssertEqual(presentation.badgeText, "Timetable")
        XCTAssertFalse(presentation.kind.isDisruption)
    }

    func testExpectedTimeWithoutScheduleIsAnUncomparedEstimate() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [makeStop(expected: time)]))

        XCTAssertEqual(presentation.kind, .estimated)
        XCTAssertEqual(presentation.text, "Estimated")
    }

    func testMatchedExpectedTimeIsExplicitlyExpectedOnTime() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [
            makeStop(scheduled: time, expected: time),
        ]))

        XCTAssertEqual(presentation.kind, .onTime)
        XCTAssertEqual(presentation.text, "On time")
        XCTAssertEqual(presentation.badgeText, "On time")
    }

    func testSmallPositiveEstimateIsNotLabeledOnTime() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [
            makeStop(scheduled: time, expected: time.addingTimeInterval(120)),
        ]))

        XCTAssertEqual(presentation.kind, .estimated)
        XCTAssertEqual(presentation.text, "2 min late")
    }

    func testTimingComparisonDoesNotMixArrivalAndDeparture() {
        let stop = StopTime(
            station: makeStation(),
            sequence: 0,
            scheduledArrival: time,
            expectedDeparture: time.addingTimeInterval(600)
        )
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [stop]))

        XCTAssertEqual(presentation.kind, .estimated)
        XCTAssertEqual(presentation.text, "Estimated")
    }

    func testPassageFlagsWithoutUsableJourneyTimingDoNotClaimAnEndedJourney() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [
            makeStop(passed: true),
        ]), referenceDate: time)

        XCTAssertEqual(presentation.kind, .unavailable)
        XCTAssertEqual(presentation.text, "No times yet")
    }

    func testUnstampedPassageDoesNotDiscardAvailableTimetableTiming() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [
            makeStop(scheduled: time, passed: true),
        ]), referenceDate: time)

        XCTAssertEqual(presentation.kind, .scheduled)
        XCTAssertEqual(presentation.text, "Timetable")
        XCTAssertFalse(presentation.saysHowTheTrainRuns)
    }

    func testPrematurePassageFlagsDoNotEndUpcomingOrUnderwayTimetable() {
        let trip = makeTrip(stops: [
            makeStop(scheduled: time, expected: time, passed: true),
            makeStop(scheduled: time.addingTimeInterval(3_600), expected: time.addingTimeInterval(3_900), passed: true, sequence: 1),
        ])
        let before = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(-60))
        XCTAssertEqual(before.kind, .onTime)
        let underway = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(900))
        XCTAssertEqual(underway.kind, .delayed)
        XCTAssertEqual(underway.delayMinutes, 5)

        let ended = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(3_900))
        XCTAssertEqual(ended.kind, .arrived)
        XCTAssertEqual(ended.text, "Arrival unconfirmed")
        XCTAssertEqual(ended.badgeText, "Arrival unconfirmed")
    }

    func testExpectedArrivalBoundaryEndsJourneyWithStaleUnpassedFlags() {
        let trip = makeTrip(stops: [
            makeStop(scheduled: time, expected: time),
            makeStop(scheduled: time.addingTimeInterval(3_600), expected: time.addingTimeInterval(4_200), sequence: 1),
        ])
        let delayed = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(3_900))
        XCTAssertEqual(delayed.kind, .delayed)
        XCTAssertEqual(delayed.delayMinutes, 10)

        let ended = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(4_200))
        XCTAssertEqual(ended.kind, .arrived)
    }

    func testUnderwayStatusComparesEffectiveFocusInsteadOfStaleOrigin() {
        let trip = makeTrip(stops: [
            makeStop(scheduled: time, expected: time.addingTimeInterval(1_800)),
            makeStop(scheduled: time.addingTimeInterval(3_600), expected: time.addingTimeInterval(4_020), sequence: 1),
        ])
        XCTAssertEqual(trip.nextStop?.delayMinutes, 30)
        let status = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(2_700))
        XCTAssertEqual(status.kind, .delayed)
        XCTAssertEqual(status.delayMinutes, 7)
    }

    func testFinalDestinationUsesArrivalEstimateRatherThanItsDepartureEstimate() {
        let destination = StopTime(
            station: makeStation(), sequence: 1,
            scheduledArrival: time.addingTimeInterval(3_600),
            scheduledDeparture: time.addingTimeInterval(3_720),
            expectedArrival: time.addingTimeInterval(4_200),
            expectedDeparture: time.addingTimeInterval(3_720)
        )
        let trip = makeTrip(stops: [makeStop(scheduled: time, expected: time), destination])
        let status = TripPresentationStatus(trip: trip, referenceDate: time.addingTimeInterval(900))
        XCTAssertEqual(status.kind, .delayed)
        XCTAssertEqual(status.delayMinutes, 10)
    }

    func testReusableSelectedProgressControlsStatusAfterPassengerAlights() {
        let trip = makeTrip(stops: [
            makeStop(scheduled: time, expected: time),
            makeStop(scheduled: time.addingTimeInterval(1_800), expected: time.addingTimeInterval(2_100), sequence: 1),
            makeStop(scheduled: time.addingTimeInterval(3_600), expected: time.addingTimeInterval(3_600), sequence: 2),
        ])
        let reference = time.addingTimeInterval(2_700)
        let selectedTrip = makeTrip(stops: Array(trip.stopTimes.prefix(2)))
        let selectedProgress = RailJourneyProgress(trip: selectedTrip, referenceDate: reference)
        XCTAssertEqual(TripPresentationStatus(trip: trip, referenceDate: reference).kind, .onTime)
        let selectedStatus = TripPresentationStatus(trip: trip, referenceDate: reference, progress: selectedProgress)
        XCTAssertEqual(selectedStatus.kind, .arrived)
        XCTAssertEqual(selectedStatus.text, "Arrival unconfirmed")
    }

    func testInvalidTimeEstimateDoesNotTrapOrClaimRealtimeTiming() {
        let presentation = TripPresentationStatus(trip: makeTrip(stops: [
            makeStop(scheduled: time, expected: Date(timeIntervalSinceReferenceDate: .infinity)),
        ]), referenceDate: time)

        XCTAssertEqual(presentation.kind, .unavailable)
    }

    private func makeStop(
        scheduled: Date? = nil,
        expected: Date? = nil,
        passed: Bool = false,
        sequence: Int = 0
    ) -> StopTime {
        StopTime(
            station: makeStation(),
            sequence: sequence,
            scheduledDeparture: scheduled,
            expectedDeparture: expected,
            isPassed: passed
        )
    }

    private func makeStation() -> Station {
        Station(
            id: RailIdentifier(rawValue: "test:station"),
            names: [LocalizedStationName("Station")],
            location: GeoCoordinate(latitude: 0, longitude: 0),
            countryCode: "US"
        )
    }

    private func makeTrip(stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: RailIdentifier(rawValue: "test:trip"),
            source: "test",
            serviceDate: time,
            operatorName: "Railway",
            product: "Train 1",
            headsign: "Destination",
            stopTimes: stops,
            capabilities: RealtimeCapabilities(
                hasPositions: true,
                hasPlatforms: true,
                hasRealtimeDelays: true,
                hasAlerts: true,
                granularity: .perStop
            )
        )
    }
}
