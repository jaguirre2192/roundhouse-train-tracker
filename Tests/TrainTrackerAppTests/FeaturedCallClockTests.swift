import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class FeaturedCallClockTests: XCTestCase {
    // 18:28 in Stamford on November 17, already 01:28 on November 18 in Cairo.
    private let date = Date(timeIntervalSince1970: 1_794_958_080)
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let cairo = TimeZone(identifier: "Africa/Cairo")!

    func testStamfordTimeOnACairoDeviceUsesItsStationZoneAndTheOffsetAtArrival() {
        let call = stop("STM", arrival: date)
        let local = JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: newYork.identifier)
        let visible = clock(call, supplied: newYork.identifier, cached: cairo)
        XCTAssertEqual(visible.timeText, local + " " + (newYork.abbreviation(for: date) ?? newYork.identifier))
        XCTAssertEqual(visible.displayText, visible.timeText)
        XCTAssertNotEqual(local, JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: cairo.identifier))
        XCTAssertNil(visible.stationToLocate)
    }

    func testUnknownZoneUsesExplicitUTCOnEveryDeviceAndOnlyQueriesTheVisibleStation() {
        let call = stop("STM", arrival: date)
        let fallback = JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: TimeZone.gmt.identifier) + " UTC"
        let oldStation = FeaturedCallClock.LocatedZone(stationID: stop("PHL").station.id, zone: cairo)
        let unknown = clock(call, supplied: "Invalid/Zone", located: oldStation)
        XCTAssertEqual(unknown.timeText, fallback)
        XCTAssertEqual(unknown.stationToLocate?.id, call.station.id)
        let retimed = clock(stop("STM", arrival: date.addingTimeInterval(120)))
        XCTAssertEqual(retimed.stationToLocate?.id, unknown.stationToLocate?.id)
        XCTAssertEqual(clock(call, lookup: false).timeText, fallback)
        XCTAssertNil(clock(call, lookup: false).stationToLocate)
        XCTAssertNil(clock(stop("NOCOORD", arrival: date, latitude: 0, longitude: 0)).stationToLocate)

        let located = FeaturedCallClock.LocatedZone(stationID: call.station.id, zone: newYork)
        let expected = JourneyPlanDateTimePresentation.labeledTime(date, timeZoneIdentifier: newYork.identifier,
                                                                  deviceTimeZone: cairo)
        XCTAssertEqual(clock(call, located: located).timeText, expected)
        XCTAssertEqual(clock(call, cached: newYork).timeText, expected)
        XCTAssertNil(clock(call, located: located).stationToLocate)
        XCTAssertNil(clock(call, cached: newYork).stationToLocate)
    }

    func testDepartureOnlyAndArrivalOnlyCallsKeepTheCorrectEventAndMissingTimeStaysEmpty() {
        let departure = date.addingTimeInterval(120)
        let departureText = JourneyPlanDateTimePresentation.labeledTime(departure, timeZoneIdentifier: newYork.identifier,
                                                                       deviceTimeZone: cairo)
        let onlyDeparture = clock(stop("STM", departure: departure), cached: newYork)
        XCTAssertEqual(onlyDeparture.displayText, "Departs " + departureText)
        let onlyArrival = clock(stop("NYP", arrival: date), boarding: true, cached: newYork)
        XCTAssertEqual(onlyArrival.displayText, onlyArrival.timeText.map { "Arrives " + $0 })
        let withDwell = stop("STM", arrival: date, departure: departure)
        XCTAssertEqual(clock(withDwell, boarding: true, cached: newYork).timeText, departureText)
        XCTAssertNotEqual(clock(withDwell, cached: newYork).timeText, departureText)
        XCTAssertNil(clock(stop("MISSING")).timeText)
        XCTAssertNil(clock(stop("MISSING")).stationToLocate)
    }

    func testSpokenFeaturedCallUsesTheSameQualifiedTimeAsTheStub() throws {
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: date).first)
        let progress = RailJourneyProgress(trip: trip, referenceDate: date)
        let stop = try XCTUnwrap(progress.focusStop)
        let utc = try XCTUnwrap(clock(stop, lookup: false).timeText)
        let summary = tripAccessibilitySummary(trip, referenceDate: date, guidanceTimeText: utc)
        XCTAssertTrue(summary.contains(stop.station.displayName))
        XCTAssertTrue(summary.contains("estimated arrival at " + utc), summary)
    }

    private func clock(_ stop: StopTime, boarding: Bool = false, supplied: String? = nil,
                       located: FeaturedCallClock.LocatedZone? = nil, cached: TimeZone? = nil,
                       lookup: Bool = true) -> FeaturedCallClock {
        FeaturedCallClock(stop: stop, boarding: boarding, suppliedZone: supplied, located: located,
                          cachedZone: cached, allowsLookup: lookup, deviceZone: cairo)
    }

    private func stop(_ code: String, arrival: Date? = nil, departure: Date? = nil,
                      latitude: Double = 41.046, longitude: Double = -73.542) -> StopTime {
        let station = Station(id: RailIdentifier(region: "us", source: "test", nativeID: code), names: [],
                              location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: "US")
        return StopTime(station: station, sequence: 2, scheduledArrival: arrival, scheduledDeparture: departure)
    }
}
