import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class ConnectionTimetableAndClockTests: XCTestCase {
    private let london = "Europe/London"
    private let paris = "Europe/Paris"

    func testChangedArrivalLeavesSixMinutesAndTwoShortOfPlanningEstimate() throws {
        let brussels = JourneyRecoveryPreview.brussels
        let scheduled = date("2026-11-18T13:40:00Z")
        let actual = date("2026-11-18T13:46:00Z")
        let onward = date("2026-11-18T13:52:00Z")
        let station = site(brussels.displayName, zone: brussels.timeZoneIdentifier)
        let incoming = StopTime(station: station, sequence: 2, scheduledArrival: scheduled, expectedArrival: actual)
        // An arrival estimate at the boarding call cannot replace its departure.
        let outgoing = StopTime(station: station, sequence: 1, scheduledDeparture: onward, expectedArrival: scheduled)
        let walk = JourneyPlanSegment(id: "walk", kind: .walk, from: brussels, to: brussels, duration: 300)
        let timing = try XCTUnwrap(timetable(at: brussels, arrival: incoming, departure: outgoing, walks: [walk]))
        XCTAssertEqual(timing.incoming.date, actual)
        XCTAssertTrue(timing.incoming.usesEstimate)
        XCTAssertEqual(timing.onward.date, onward)
        XCTAssertFalse(timing.onward.usesEstimate)
        XCTAssertEqual(timing.availableMinutes, 6)
        XCTAssertEqual(timing.planningMinutes, 8)
        XCTAssertNotNil(timing.sharedClockLabel)
        XCTAssertNil(timing.published)
        XCTAssertEqual(timing.marginMinutes, -2)

        let unknownWalk = JourneyPlanSegment(id: "walk", kind: .walk, from: brussels, to: brussels)
        let uncertain = try XCTUnwrap(timetable(at: brussels, arrival: incoming, departure: outgoing, walks: [unknownWalk]))
        XCTAssertNil(uncertain.allowanceMinutes)
        XCTAssertNil(uncertain.marginMinutes)
    }

    func testSharedClockLabelSeparatesTimeChangeAndOnTimeEstimate() throws {
        let place = JourneyRecoveryPreview.brussels
        let station = site(place.displayName, zone: place.timeZoneIdentifier)
        let before = date("2026-03-29T00:55:00Z")
        let after = date("2026-03-29T01:05:00Z")
        let incoming = StopTime(station: station, sequence: 2, scheduledArrival: before, expectedArrival: before)
        let outgoing = StopTime(station: station, sequence: 1, scheduledDeparture: after)
        let timing = try XCTUnwrap(timetable(at: place, arrival: incoming, departure: outgoing))
        XCTAssertNil(timing.sharedClockLabel)
        XCTAssertEqual(timing.availableMinutes, 10)
        XCTAssertEqual(timing.incoming.timingLabel, "Matches timetable")
        XCTAssertEqual(timing.onward.timingLabel, "Timetable")
    }

    func testPublishedTransferIsLimitedToVerifiedDatesStationsAndTracks() throws {
        let date2026 = date("2026-11-18T13:46:00Z")
        let date2027 = date("2027-03-20T15:30:00Z")
        let neustadt = site("Wiener Neustadt Hbf", country: "AT", latitude: 47.81145, longitude: 16.23432)
        func rule(_ station: Station, incoming: String? = nil, outgoing: String? = nil, at instant: Date) -> PublishedStationTransfer? {
            PublishedStationTransfer.find(arrival: .init(station: station, sequence: 2, plannedPlatform: incoming),
                                          departure: .init(station: station, sequence: 1, plannedPlatform: outgoing), at: instant)
        }
        XCTAssertEqual(rule(neustadt, at: date2026)?.minutes, 5)
        XCTAssertTrue(try XCTUnwrap(rule(neustadt, at: date2026)).sourceURL.path.contains("snnb-2026"))
        XCTAssertTrue(try XCTUnwrap(rule(neustadt, at: date2027)).sourceURL.path.contains("snnb-2027"))
        XCTAssertNil(rule(neustadt, at: date("2025-12-12T23:00:00Z")))
        XCTAssertNil(rule(neustadt, at: date("2027-12-15T23:00:00Z")))
        XCTAssertNil(PublishedStationTransfer.find(arrival: .init(station: neustadt, sequence: 2),
            departure: .init(station: neustadt, sequence: 1), at: date("2027-12-11T22:56:00Z"),
            onward: date("2027-12-11T23:05:00Z")))
        XCTAssertNil(rule(site("Wiener Neustadt Hbf", country: "AT", latitude: 48.185, longitude: 16.376), at: date2026))
        XCTAssertNil(rule(site("Wiener Neustadt Hbf", country: "DE", latitude: 47.81145, longitude: 16.23432), at: date2026))
        let salzburg = site("Salzburg Hbf", country: "AT", latitude: 47.81310, longitude: 13.04507)
        XCTAssertEqual(rule(salzburg, incoming: "5", outgoing: "5", at: date2026)?.minutes, 3)
        XCTAssertNil(rule(salzburg, incoming: "5", outgoing: "6", at: date2026))
        XCTAssertNil(rule(salzburg, incoming: "5", at: date2026))
        let wien = site("Wien Hbf", country: "AT", latitude: 48.18520, longitude: 16.37630)
        XCTAssertNil(rule(wien, incoming: "1", outgoing: "1", at: date2026))
        XCTAssertEqual(rule(wien, incoming: "8", outgoing: "8", at: date2026)?.minutes, 4)
    }

    func testPublishedMinutesTakePrecedenceAndCrossTownWalkCannotClaimStationRule() throws {
        let place = RailPlace(id: .init(rawValue: "wiener-neustadt"), kind: .station, displayName: "Wiener Neustadt Hbf",
                              context: "AT", countryCode: "AT", timeZoneIdentifier: "Europe/Vienna",
                              location: .init(latitude: 47.81145, longitude: 16.23432), eligibleModes: ["rail"], attributions: [])
        let station = site(place.displayName, country: "AT", latitude: 47.81145, longitude: 16.23432)
        let instant = date("2026-11-18T13:46:00Z")
        let arrival = StopTime(station: station, sequence: 2, scheduledArrival: instant)
        let departure = StopTime(station: station, sequence: 1, scheduledDeparture: instant.addingTimeInterval(180))
        let connection = try XCTUnwrap(timetable(at: place, arrival: arrival, departure: departure))
        XCTAssertEqual(connection.published?.minutes, 5)
        XCTAssertEqual(connection.marginMinutes, -2)
        let crossTown = JourneyPlanSegment(id: "walk", kind: .walk, from: place, to: place,
                                           duration: 600, isStationChange: true)
        XCTAssertNil(timetable(at: place, arrival: arrival, departure: departure, walks: [crossTown])?.published)
        XCTAssertNil(timetable(at: place, arrival: arrival, departure: .init(station: station, sequence: 1, isCancelled: true)))
    }

    @MainActor
    func testSelectedAustrianRailServicesResolveTheirPublishedStationAllowance() throws {
        let seed = PublishedConnectionPreview.seed
        let stage = JourneyPlanStage(plan: try XCTUnwrap(seed.plans.first), trips: seed.trips, referenceDate: try XCTUnwrap(seed.referenceDate))
        XCTAssertEqual(stage.kind, .connection)
        let timing = try XCTUnwrap(stage.connection?.timetable)
        XCTAssertEqual(timing.availableMinutes, 32)
        XCTAssertEqual(timing.published?.minutes, 5)
        XCTAssertEqual(timing.marginMinutes, 27)
        XCTAssertEqual(timing.published?.source, "ÖBB-Infrastruktur · 2026")
    }

    func testEastboundAndWestboundClocksShareOneInstantAcrossMidnightAndSummerTime() throws {
        for (instant, parisTime, londonTime) in [
            ("2026-11-18T11:48:00Z", "2026-11-18 12:48", "2026-11-18 11:48"),
            ("2026-07-18T10:48:00Z", "2026-07-18 12:48", "2026-07-18 11:48"),
            ("2026-11-18T23:20:00Z", "2026-11-19 00:20", "2026-11-18 23:20")
        ] {
            let at = date(instant)
            for (from, to, delta) in [(london, paris, 60), (paris, london, -60)] {
                let first = StopTime(station: site("Origin", zone: from), sequence: 0, scheduledDeparture: at.addingTimeInterval(-7200))
                let last = StopTime(station: site("Destination", zone: to), sequence: 1, scheduledArrival: at)
                let guide = clockGuide([first, last])
                XCTAssertEqual(guide.changes, [last.id])
                let comparison = try XCTUnwrap(guide.comparisons[last.id])
                XCTAssertEqual(comparison.instant, at)
                XCTAssertEqual(comparison.offsetMinutes, delta)
                XCTAssertEqual(comparison.shift, delta > 0 ? "1 hour ahead" : "1 hour behind")
                XCTAssertEqual(localDate(at, in: comparison.current.zone), delta > 0 ? parisTime : londonTime)
                XCTAssertEqual(localDate(at, in: comparison.previous.zone), delta > 0 ? londonTime : parisTime)
            }
        }
    }

    func testBorderOnLaterKnownCallIsPinnedAndTimeTapMatchesDisplayedDeparture() throws {
        let at = date("2026-11-18T11:48:00Z")
        func call(_ name: String, _ index: Int, _ zone: String?) -> StopTime {
            .init(station: site(name, zone: zone), sequence: index, scheduledArrival: at, scheduledDeparture: at.addingTimeInterval(300))
        }
        let calls = [call("London", 0, london), call("Unreported", 1, nil), call("Lille", 2, paris),
                     call("Amiens", 3, paris), call("Paris", 4, paris)]
        let guide = clockGuide(calls)
        XCTAssertEqual(guide.changes, [calls[2].id])
        let intermediate = try XCTUnwrap(guide.comparisons[calls[2].id])
        XCTAssertEqual(intermediate.instant, at.addingTimeInterval(300))
        XCTAssertEqual(intermediate.event, "Timetable departure")
        XCTAssertEqual(guide.comparisons[calls[4].id]?.instant, at)
        XCTAssertEqual(guide.comparisons[calls[4].id]?.event, "Timetable arrival")
        let outline = JourneyRouteOutline(stops: calls, focusID: nil, pinned: guide.changes)
        XCTAssertEqual(outline.visibleStops.map(\.sequence), [0, 2, 4])
    }

    func testSameOffsetsTemporalDSTChangeAndFallbackZonesDoNotIntroduceMarks() {
        let before = date("2026-03-29T00:15:00Z")
        let after = date("2026-03-29T02:15:00Z")
        for (from, to) in [(paris, "Europe/Brussels"), (paris, paris), ("No/SuchZone", paris)] {
            let first = StopTime(station: site("A", zone: from), sequence: 0, scheduledDeparture: before)
            let last = StopTime(station: site("B", zone: to), sequence: 1, scheduledArrival: after)
            let guide = clockGuide([first, last])
            XCTAssertTrue(guide.changes.isEmpty)
            XCTAssertTrue(guide.comparisons.isEmpty)
        }
        let stops = [StopTime(station: site("A"), sequence: 0, scheduledDeparture: before),
                     StopTime(station: site("B"), sequence: 1, scheduledArrival: after)]
        let unsupported = TripDetailTimeZoneContext(trip: train(stops), routeTimeZones: .init(
            departureTimeZoneIdentifier: london, arrivalTimeZoneIdentifier: paris))
        XCTAssertTrue(RouteClockGuide(stops: stops, zones: unsupported).changes.isEmpty)
    }

    func testMissingParisPlaceZoneStoredAsUTCCannotInventFrenchClockChange() throws {
        let instant = date("2026-07-18T15:00:00Z")
        let first = StopTime(station: site("Paris Nord", country: "FR", latitude: 48.88, longitude: 2.35),
                             sequence: 0, scheduledDeparture: instant)
        let last = StopTime(station: site("Lille Europe", country: "FR", latitude: 50.63, longitude: 3.07, zone: paris),
                            sequence: 1, scheduledArrival: instant.addingTimeInterval(3600))
        let unknownPlace = RailPlace(id: first.station.id, kind: .station, displayName: first.station.displayName,
                                     context: "FR", countryCode: "FR", timeZoneIdentifier: "UTC", location: first.station.location,
                                     eligibleModes: ["rail"], attributions: [])
        let stops = [first, last]
        let zones = TripDetailTimeZoneContext(trip: train(stops), routeTimeZones: .init(
            departureTimeZoneIdentifier: "UTC", arrivalTimeZoneIdentifier: paris), additionalPlaces: [unknownPlace])
        XCTAssertNil(zones.stationClockZone(for: first))
        XCTAssertNil(zones.timeZoneIdentifier(for: first))
        XCTAssertEqual(zones.stationClockZone(for: last)?.identifier, paris)
        XCTAssertTrue(RouteClockGuide(stops: stops, zones: zones).changes.isEmpty)
        let timing = try XCTUnwrap(timetable(at: unknownPlace, arrival: .init(station: first.station, sequence: 1, scheduledArrival: instant),
                                              departure: .init(station: last.station, sequence: 0, scheduledDeparture: instant)))
        XCTAssertNil(timing.incoming.stationZone)
        XCTAssertEqual(timing.onward.stationZone?.identifier, paris)
        let reportedUTC = StopTime(station: site("UTC station", zone: "UTC"), sequence: 0, scheduledDeparture: instant)
        XCTAssertEqual(clockGuide([reportedUTC, last]).comparisons[last.id]?.offsetMinutes, 120)
    }

    func testWireRefreshPreservesValidStationZoneAndOlderArchivesRoundTrip() throws {
        func snapshot(_ zone: String?) throws -> BackendTripSnapshot {
            var call: [String: Any] = ["stationId": "STP", "stationName": "St Pancras", "countryCode": "GB", "sequence": 0,
                                       "cancelled": false, "passed": false, "scheduledDeparture": "2026-11-18T10:00:00Z"]
            call["timeZoneIdentifier"] = zone
            let raw: [String: Any] = ["id": "trip", "source": "transitous", "serviceDate": "2026-11-18", "product": "Eurostar",
                                      "operatorName": "Eurostar", "headsign": "Paris", "fetchedAt": "2026-11-18T09:00:00Z", "stops": [call]]
            return try JSONDecoder().decode(BackendTripSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let original = try snapshot(nil).trip
        let old = try JSONDecoder().decode(TrainTrip.self, from: JSONEncoder().encode(original))
        XCTAssertNil(old.stopTimes.first?.station.timeZoneIdentifier)
        let fresh = try snapshot(london).merging(into: old)
        XCTAssertEqual(fresh.stopTimes.first?.station.timeZoneIdentifier, london)
        XCTAssertEqual(try snapshot("No/SuchZone").merging(into: fresh).stopTimes.first?.station.timeZoneIdentifier, london)
        XCTAssertEqual(try snapshot(nil).merging(into: fresh).stopTimes.first?.station.timeZoneIdentifier, london)
    }

    private func timetable(at place: RailPlace, arrival: StopTime, departure: StopTime, walks: [JourneyPlanSegment] = []) -> ConnectionTimetable? {
        let previous = JourneyPlanSegment(id: "in", kind: .rail, from: JourneyRecoveryPreview.paris, to: place)
        let next = JourneyPlanSegment(id: "out", kind: .rail, from: place, to: JourneyRecoveryPreview.amsterdam)
        return .init(previous: previous, next: next, walks: walks, arrival: arrival, departure: departure)
    }

    private func clockGuide(_ calls: [StopTime]) -> RouteClockGuide {
        RouteClockGuide(stops: calls, zones: TripDetailTimeZoneContext(trip: train(calls)))
    }

    private func train(_ calls: [StopTime]) -> TrainTrip {
        TrainTrip(id: .init(rawValue: "test:clock"), source: "test", serviceDate: date("2026-11-18T00:00:00Z"),
                  operatorName: "Eurostar", product: "Test", headsign: "Destination", stopTimes: calls,
                  capabilities: .init(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop))
    }

    private func site(_ name: String, country: String = "GB", latitude: Double = 51.53, longitude: Double = -0.12, zone: String? = nil) -> Station {
        .init(id: .init(rawValue: name), names: [.init(name)], location: .init(latitude: latitude, longitude: longitude),
              countryCode: country, timeZoneIdentifier: zone)
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func localDate(_ instant: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: instant)
    }
}
