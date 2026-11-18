import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyTimingEvidenceTests: XCTestCase {
    func testArrivalEventUsesArrivalEstimateAndArrivalDelayDespiteLaterDeparture() {
        let stop = stop(0, arrival: time(60), departure: time(80), expectedArrival: time(65), expectedDeparture: time(100))
        let presentation = StopTimelineTimePresentation(stop: stop, event: .arrival, timeZoneIdentifier: "Etc/UTC")

        XCTAssertEqual(presentation.date, time(65))
        XCTAssertEqual(presentation.timeText, "1:05 PM")
        XCTAssertEqual(presentation.timingBasis, .estimated)
        XCTAssertEqual(presentation.delayMinutes, 5)
    }

    func testScheduledArrivalWinsOverAnUnrelatedDepartureEstimate() {
        let stop = stop(0, arrival: time(60), departure: time(80), expectedDeparture: time(100))
        let presentation = StopTimelineTimePresentation(stop: stop, event: .arrival)

        XCTAssertEqual(presentation.date, time(60))
        XCTAssertEqual(presentation.timingLabel, "Scheduled")
        XCTAssertNil(presentation.delayMinutes)
    }

    func testDefaultDepartureUsesScheduledDepartureBeforeArrivalEstimate() {
        let stop = stop(0, arrival: time(60), departure: time(80), expectedArrival: time(65))
        let presentation = StopTimelineTimePresentation(stop: stop)

        XCTAssertEqual(presentation.date, time(80))
        XCTAssertEqual(presentation.timingBasis, .scheduled)
        XCTAssertNil(presentation.delayMinutes)
    }

    func testMissingRequestedEventFallsBackToTheOtherEventWithMatchingEvidence() {
        let departureOnly = stop(0, departure: time(80), expectedDeparture: time(88))
        let arrivalOnly = stop(1, arrival: time(60), expectedArrival: time(64))
        let arrival = StopTimelineTimePresentation(stop: departureOnly, event: .arrival)
        let departure = StopTimelineTimePresentation(stop: arrivalOnly)

        XCTAssertEqual(arrival.date, time(88))
        XCTAssertEqual(arrival.delayMinutes, 8)
        XCTAssertEqual(departure.date, time(64))
        XCTAssertEqual(departure.delayMinutes, 4)
        XCTAssertEqual(arrival.timingBasis, .estimated)
        XCTAssertEqual(departure.timingBasis, .estimated)
    }

    func testMissingTimesDoNotInventAValueOrEvidenceLabel() {
        let presentation = StopTimelineTimePresentation(stop: stop(0), event: .arrival)

        XCTAssertNil(presentation.date)
        XCTAssertNil(presentation.timeText)
        XCTAssertNil(presentation.timingLabel)
        XCTAssertNil(presentation.delayMinutes)
    }

    func testMixedItineraryLabelsScheduledDepartureAndEstimatedSelectedArrivalInEveryPhase() throws {
        let train = trip([
            stop(0, departure: time(0)),
            stop(1, arrival: time(60), departure: time(90), expectedArrival: time(65), expectedDeparture: time(110)),
            stop(2, arrival: time(180))
        ])
        let selected = segment(train, alighting: 1)
        let before = JourneyItineraryTimePresentation(segment: selected, trip: train, referenceDate: time(-10))
        let after = JourneyItineraryTimePresentation(segment: selected, trip: train, referenceDate: time(70))

        XCTAssertEqual(before.departure?.timingBasis, .scheduled)
        XCTAssertEqual(before.arrival?.timingBasis, .estimated)
        XCTAssertEqual(before.arrival?.date, time(65))
        let text = try XCTUnwrap(before.text)
        XCTAssertTrue(text.hasPrefix("Timetable "))
        XCTAssertTrue(text.contains(" – Estimated "))
        XCTAssertEqual(after.text, before.text)
    }

    func testMixedItineraryDoesNotTreatScheduledArrivalAsEstimatedFromDepartureOnlyData() throws {
        let train = trip([
            stop(0, departure: time(0), expectedDeparture: time(5)),
            stop(1, arrival: time(60), departure: time(90), expectedDeparture: time(110)),
            stop(2, arrival: time(180))
        ])
        let presentation = JourneyItineraryTimePresentation(
            segment: segment(train, alighting: 1), trip: train, referenceDate: time(30)
        )

        XCTAssertEqual(presentation.departure?.timingBasis, .estimated)
        XCTAssertEqual(presentation.arrival?.timingBasis, .scheduled)
        XCTAssertEqual(presentation.arrival?.date, time(60))
        let text = try XCTUnwrap(presentation.text)
        XCTAssertTrue(text.hasPrefix("Estimated "))
        XCTAssertTrue(text.contains(" – Timetable "))
    }

    func testUnmatchedOrUntrackedItineraryRetainsOnlySavedScheduledEndpoints() {
        let original = trip([stop(0, departure: time(0)), stop(1, arrival: time(60))])
        let selected = segment(original)
        let changedStops = trip([
            stop(4, departure: time(10), expectedDeparture: time(20)),
            stop(5, arrival: time(90), expectedArrival: time(100))
        ])
        for availableTrip in [changedStops, nil] {
            let presentation = JourneyItineraryTimePresentation(segment: selected, trip: availableTrip, referenceDate: time(30))
            XCTAssertEqual(presentation.departure?.date, time(0))
            XCTAssertEqual(presentation.arrival?.date, time(60))
            XCTAssertEqual(presentation.departure?.timingBasis, .scheduled)
            XCTAssertEqual(presentation.arrival?.timingBasis, .scheduled)
        }
    }

    func testCrossZoneMidnightRangeShowsBothLocalDates() throws {
        let train = trip([
            stop(0, departure: date("2026-09-07T03:50:00Z")),
            stop(1, arrival: date("2026-09-07T05:30:00Z"))
        ])
        let selected = segment(train, departureZone: "America/New_York", arrivalZone: "America/Chicago")
        let presentation = JourneyItineraryTimePresentation(segment: selected, trip: nil, referenceDate: time(0))
        let departure = try XCTUnwrap(presentation.departure)
        let arrival = try XCTUnwrap(presentation.arrival)
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        var central = Calendar(identifier: .gregorian)
        central.timeZone = TimeZone(identifier: "America/Chicago")!

        XCTAssertEqual(eastern.component(.day, from: departure.date), 6)
        XCTAssertEqual(central.component(.day, from: arrival.date), 7)
        XCTAssertTrue(presentation.showsDateChange)
        XCTAssertEqual(departure.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(arrival.timeZoneIdentifier, "America/Chicago")
        let text = try XCTUnwrap(presentation.text)
        XCTAssertTrue(text.contains(JourneyExperienceClock.date(departure.date, zone: departure.timeZoneIdentifier)))
        XCTAssertTrue(text.contains(JourneyExperienceClock.date(arrival.date, zone: arrival.timeZoneIdentifier)))
    }

    func testUTCDateChangeDoesNotInventADifferentLocalJourneyDay() {
        let train = trip([
            stop(0, departure: date("2026-09-06T23:50:00Z")),
            stop(1, arrival: date("2026-09-07T02:30:00Z"))
        ])
        let selected = segment(train, departureZone: "America/New_York", arrivalZone: "America/Chicago")
        let presentation = JourneyItineraryTimePresentation(segment: selected, trip: nil, referenceDate: time(0))

        XCTAssertFalse(presentation.showsDateChange)
        XCTAssertNotNil(presentation.text)
    }

    private func time(_ minutes: Double) -> Date {
        date("2026-09-06T12:00:00Z").addingTimeInterval(minutes * 60)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func stop(
        _ index: Int, arrival: Date? = nil, departure: Date? = nil,
        expectedArrival: Date? = nil, expectedDeparture: Date? = nil
    ) -> StopTime {
        StopTime(
            station: Station(
                id: RailIdentifier(rawValue: "us:fixture:stop-\(index)"), names: [.init("Stop \(index)")],
                location: .init(latitude: 40 + Double(index), longitude: -74), countryCode: "US"
            ),
            sequence: index, scheduledArrival: arrival, scheduledDeparture: departure,
            expectedArrival: expectedArrival, expectedDeparture: expectedDeparture
        )
    }

    private func trip(_ stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: RailIdentifier(rawValue: "us:fixture:train"), source: "fixture", serviceDate: time(0),
            operatorName: "Fixture Rail", product: "Express", headsign: stops.last!.station.displayName,
            stopTimes: stops,
            capabilities: .init(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func segment(
        _ trip: TrainTrip, alighting: Int? = nil,
        departureZone: String = "Etc/UTC", arrivalZone: String = "Etc/UTC"
    ) -> JourneyPlanSegment {
        let boarding = trip.stopTimes[0]
        let alighting = trip.stopTimes[alighting ?? (trip.stopTimes.count - 1)]
        return JourneyPlanSegment(
            id: "selected", kind: .rail,
            from: place(boarding.station, zone: departureZone), to: place(alighting.station, zone: arrivalZone),
            departure: boarding.scheduledDeparture, arrival: alighting.scheduledArrival, resolvedTripID: trip.id
        )
    }

    private func place(_ station: Station, zone: String) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName,
            context: "", countryCode: "US", timeZoneIdentifier: zone,
            location: station.location, eligibleModes: ["longDistanceRail"], attributions: []
        )
    }
}
