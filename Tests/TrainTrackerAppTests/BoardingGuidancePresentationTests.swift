import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// A passenger boarding mid-route must be guided to their boarding station before boarding; the
/// train's next stop is only the right guidance once they are aboard (by timetable).
final class BoardingGuidancePresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_789_500_000)

    private func minutes(_ value: Double) -> Date { base.addingTimeInterval(value * 60) }

    private func place(_ code: String, _ name: String) -> RailPlace {
        RailPlace(id: RailIdentifier(rawValue: "us:amtraker:\(code)"), kind: .station, displayName: name, context: "",
                  countryCode: "US", timeZoneIdentifier: "America/New_York",
                  location: GeoCoordinate(latitude: 39, longitude: -76), eligibleModes: [], attributions: [])
    }

    private func stop(_ code: String, _ name: String, _ sequence: Int, departure: Double?, arrival: Double?,
                      expectedDeparture: Double? = nil, expectedArrival: Double? = nil,
                      track: String? = nil, passed: Bool = false, cancelled: Bool = false,
                      passageObservedAt: Double? = nil) -> StopTime {
        StopTime(
            station: Station(id: RailIdentifier(rawValue: "us:amtraker:\(code)"), names: [LocalizedStationName(name)],
                             codes: [.sourceNative: code], location: GeoCoordinate(latitude: 39, longitude: -76), countryCode: "US"),
            sequence: sequence, scheduledArrival: arrival.map(minutes), scheduledDeparture: departure.map(minutes),
            expectedArrival: expectedArrival.map(minutes), expectedDeparture: expectedDeparture.map(minutes),
            plannedPlatform: track, expectedPlatform: track, platformKind: .track, platformSource: "Amtraker",
            isCancelled: cancelled, isPassed: passed, passageObservedAt: passageObservedAt.map(minutes)
        )
    }

    private var trip: TrainTrip {
        makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, track: "17", passed: true, passageObservedAt: 0),
            stop("BAL", "Baltimore Penn", 2, departure: 31, arrival: 30, track: "5"),
            stop("PHL", "Philadelphia 30th Street", 3, departure: 91, arrival: 90, track: "4"),
            stop("NYP", "New York Penn", 4, departure: nil, arrival: 180),
        ])
    }

    private func makeTrip(stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "2120-15"), source: "amtraker", serviceDate: base,
            operatorName: "Amtrak", product: "Acela 2120", headsign: "New York",
            stopTimes: stops,
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop)
        )
    }

    private var philadelphiaToNewYork: JourneyPlanSegment {
        JourneyPlanSegment(id: "leg", kind: .rail, from: place("PHL", "Philadelphia 30th Street"), to: place("NYP", "New York Penn"),
                           departure: minutes(91), arrival: minutes(180), serviceName: "Acela 2120",
                           resolvedTripID: trip.id)
    }

    @MainActor
    func testMidRouteBoardingGuidesToBoardingStationBeforeBoarding() {
        // 10 minutes in: the train has left Washington and its next stop is Baltimore, but the
        // passenger boards at Philadelphia.
        let early = ActiveTripCardPresentation(trip: trip, referenceDate: minutes(10), selectedSegment: philadelphiaToNewYork)
        XCTAssertEqual(trip.nextStop?.station.displayName, "Baltimore Penn")
        XCTAssertTrue(early.isBeforeBoarding)
        XCTAssertEqual(early.nextStopLabel, "Board at")
        XCTAssertEqual(early.nextStopValue, "Philadelphia 30th Street", "Not Baltimore, the train's next stop")
        XCTAssertEqual(early.platformText, "Track 4 · via Amtraker")

        let summary = tripAccessibilitySummary(trip, referenceDate: minutes(10), selectedSegment: philadelphiaToNewYork)
        XCTAssertTrue(summary.contains("board at: Philadelphia 30th Street"), summary)
        XCTAssertFalse(summary.contains("Baltimore"), summary)
    }

    @MainActor
    func testAfterBoardingTimeGuidanceMovesToThePassengersNextStop() {
        let aboard = ActiveTripCardPresentation(trip: trip, referenceDate: minutes(100), selectedSegment: philadelphiaToNewYork)
        XCTAssertFalse(aboard.isBeforeBoarding)
        XCTAssertEqual(aboard.nextStopLabel, "Next scheduled stop")
        XCTAssertEqual(aboard.nextStopValue, "New York Penn")

        let ended = ActiveTripCardPresentation(trip: trip, referenceDate: minutes(200), selectedSegment: philadelphiaToNewYork)
        XCTAssertEqual(ended.nextStopValue, "Arrival unconfirmed")
    }

    @MainActor
    func testSelectedLegUsesExpectedBoardingDepartureAndAlightingArrival() {
        let delayed = makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, passed: true),
            stop("BAL", "Baltimore Penn", 2, departure: 31, arrival: 30, passed: true),
            stop("PHL", "Philadelphia 30th Street", 3, departure: 91, arrival: 90,
                 expectedDeparture: 105, expectedArrival: 100, track: "4", passed: true),
            stop("NYP", "New York Penn", 4, departure: nil, arrival: 180, expectedArrival: 200),
        ])
        let before = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(100), selectedSegment: philadelphiaToNewYork)
        XCTAssertEqual(before.effectiveProgress.phase, .departureSoon)
        XCTAssertEqual(before.nextStopLabel, "Board at")
        XCTAssertEqual(before.nextStopValue, "Philadelphia 30th Street")
        XCTAssertEqual(before.status.kind, .delayed)
        XCTAssertEqual(before.status.delayMinutes, 14)
        let departing = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(105), selectedSegment: philadelphiaToNewYork)
        XCTAssertEqual(departing.nextStopValue, "New York Penn")
        let delayedArrival = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(190), selectedSegment: philadelphiaToNewYork)
        XCTAssertEqual(delayedArrival.effectiveProgress.phase, .underway)
        XCTAssertEqual(delayedArrival.nextStopValue, "New York Penn")
        let ended = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(200), selectedSegment: philadelphiaToNewYork)
        XCTAssertNil(ended.guidanceStop)

        let ticket = LiveLineTicket(
            trip: delayed,
            timeZoneIdentifier: { _ in "America/New_York" },
            selectedSegment: philadelphiaToNewYork,
            referenceDate: minutes(100)
        )
        let departure = JourneyPlanDateTimePresentation.time(minutes(105), timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(ticket.accessibilitySummary.contains("estimated at \(departure)"), ticket.accessibilitySummary)
    }

    @MainActor
    func testStandaloneTrainUsesTimetableFocusWhenPassageFlagsAreStale() {
        let staleTrip = makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, track: "17"),
            stop("BAL", "Baltimore Penn", 2, departure: 31, arrival: 30, track: "5"),
            stop("NYP", "New York Penn", 3, departure: nil, arrival: 180),
        ])
        XCTAssertEqual(staleTrip.nextStop?.station.displayName, "Washington Union")
        let standalone = ActiveTripCardPresentation(trip: staleTrip, referenceDate: minutes(10))
        XCTAssertEqual(standalone.effectiveProgress.phase, .underway)
        XCTAssertEqual(standalone.nextStopLabel, "Next scheduled stop")
        XCTAssertEqual(standalone.nextStopValue, "Baltimore Penn")
        XCTAssertEqual(standalone.platformValue, "5")
    }

    @MainActor
    func testStandaloneBoardingAndEndBoundariesIgnorePrematurePassageFlags() {
        let prematurelyPassed = makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, track: "17", passed: true),
            stop("BAL", "Baltimore Penn", 2, departure: 31, arrival: 30, track: "5", passed: true),
            stop("NYP", "New York Penn", 3, departure: nil, arrival: 180, passed: true),
        ])
        let before = ActiveTripCardPresentation(trip: prematurelyPassed, referenceDate: minutes(-1))
        XCTAssertTrue(before.isBeforeBoarding)
        XCTAssertEqual(before.nextStopLabel, "Board at")
        XCTAssertEqual(before.nextStopValue, "Washington Union")
        XCTAssertEqual(before.platformValue, "17")
        XCTAssertEqual(before.status.kind, .scheduled)

        let departing = ActiveTripCardPresentation(trip: prematurelyPassed, referenceDate: minutes(0))
        XCTAssertFalse(departing.isBeforeBoarding)
        XCTAssertEqual(departing.nextStopValue, "Baltimore Penn")

        let ended = ActiveTripCardPresentation(trip: prematurelyPassed, referenceDate: minutes(180))
        XCTAssertEqual(ended.effectiveProgress.phase, .ended)
        XCTAssertNil(ended.guidanceStop)
        XCTAssertEqual(ended.nextStopValue, "Arrival unconfirmed")
        XCTAssertEqual(ended.platformValue, "Not in feed")
        XCTAssertEqual(ended.status.kind, .arrived)
    }

    @MainActor
    func testStandaloneFocusStaysAtIntermediateStopThroughExpectedDwell() {
        let delayed = makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, passed: true),
            stop("BAL", "Baltimore Penn", 2, departure: 31, arrival: 30,
                 expectedDeparture: 45, expectedArrival: 40, track: "5", passed: true),
            stop("NYP", "New York Penn", 3, departure: nil, arrival: 180, expectedArrival: 200),
        ])
        let duringDelay = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(35))
        XCTAssertEqual(duringDelay.nextStopValue, "Baltimore Penn")
        XCTAssertEqual(duringDelay.platformValue, "5")
        XCTAssertEqual(duringDelay.effectiveProgress.nextTransitionDate, minutes(45))
        let duringDwell = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(44.9))
        XCTAssertEqual(duringDwell.nextStopValue, "Baltimore Penn")
        let afterDeparture = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(45))
        XCTAssertEqual(afterDeparture.nextStopValue, "New York Penn")
        let afterScheduledArrival = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(190))
        XCTAssertEqual(afterScheduledArrival.effectiveProgress.phase, .underway)
        XCTAssertEqual(afterScheduledArrival.nextStopValue, "New York Penn")
        let ended = ActiveTripCardPresentation(trip: delayed, referenceDate: minutes(200))
        XCTAssertNil(ended.guidanceStop)
    }

    @MainActor
    func testStandaloneScheduledDwellKeepsFocusUntilDeparture() {
        let standalone = ActiveTripCardPresentation(trip: trip, referenceDate: minutes(10))
        XCTAssertEqual(standalone.nextStopLabel, "Next scheduled stop")
        XCTAssertEqual(standalone.nextStopValue, "Baltimore Penn")
        XCTAssertEqual(ActiveTripCardPresentation(trip: trip, referenceDate: minutes(30.5)).nextStopValue, "Baltimore Penn")
        XCTAssertEqual(ActiveTripCardPresentation(trip: trip, referenceDate: minutes(31)).nextStopValue, "Philadelphia 30th Street")
    }

    @MainActor
    func testUnavailableTimetableRetainsProviderCallWithoutInferringBoarding() {
        let incomplete = makeTrip(stops: [
            stop("BAL", "Baltimore Penn", 1, departure: nil, arrival: nil, track: "5"),
        ])
        let presentation = ActiveTripCardPresentation(trip: incomplete, referenceDate: minutes(10))
        XCTAssertEqual(presentation.effectiveProgress.phase, .unavailable)
        XCTAssertFalse(presentation.isBeforeBoarding)
        XCTAssertEqual(presentation.nextStopValue, "Baltimore Penn")

        let cancelled = makeTrip(stops: [
            stop("WAS", "Washington Union", 1, departure: 0, arrival: nil, cancelled: true),
            stop("NYP", "New York Penn", 2, departure: nil, arrival: 180, cancelled: true),
        ])
        XCTAssertNil(ActiveTripCardPresentation(trip: cancelled, referenceDate: minutes(10)).guidanceStop)
    }

    @MainActor
    func testLiveTicketAccessibilityCarriesSelectedBoardingAndFailedCheckContext() {
        let ticket = LiveLineTicket(
            trip: trip,
            timeZoneIdentifier: { _ in "America/New_York" },
            lastSuccessfulCheck: minutes(0),
            lastRefreshFailed: true,
            selectedSegment: philadelphiaToNewYork,
            referenceDate: minutes(10)
        )
        let summary = ticket.accessibilitySummary
        XCTAssertTrue(summary.contains("from Philadelphia 30th Street to New York Penn"), summary)
        XCTAssertTrue(summary.contains("board at: Philadelphia 30th Street"), summary)
        XCTAssertTrue(summary.contains("Track 4 · via Amtraker"), summary)
        XCTAssertTrue(summary.contains("checked: 10m ago · Retry failed"), summary)
        let departure = JourneyPlanDateTimePresentation.time(minutes(91), timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(summary.contains("timetable time at \(departure)"), summary)
        XCTAssertFalse(summary.contains("Baltimore"), summary)
    }

    @MainActor
    func testLiveTicketAccessibilityCarriesReferenceDateAndSuccessfulCheck() {
        let ticket = LiveLineTicket(trip: trip, lastSuccessfulCheck: minutes(10), referenceDate: minutes(10))
        let summary = ticket.accessibilitySummary
        XCTAssertTrue(summary.contains("next stop: Baltimore Penn"), summary)
        XCTAssertTrue(summary.contains("checked: Just now"), summary)
        XCTAssertFalse(summary.contains("checked: Not yet"), summary)
    }

    @MainActor
    func testLiveTicketAccessibilityNamesUnconfirmedArrivalAfterTimetableEnds() {
        let ticket = LiveLineTicket(trip: trip, lastSuccessfulCheck: minutes(200), referenceDate: minutes(200))
        let summary = ticket.accessibilitySummary
        XCTAssertTrue(summary.contains("arrival unconfirmed"), summary)
        XCTAssertFalse(summary.contains("journey ended"), summary)
        XCTAssertFalse(summary.contains("next stop:"), summary)
        XCTAssertFalse(summary.contains("board at:"), summary)
        XCTAssertTrue(summary.contains("checked: Just now"), summary)
    }
}
