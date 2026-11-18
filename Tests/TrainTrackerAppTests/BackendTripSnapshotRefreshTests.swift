import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class BackendTripSnapshotRefreshTests: XCTestCase {
    func testRefreshCorrectsSavedStationCountryAndCoordinatesWhilePreservingLabels() throws {
        var savedCall = call("Paris", 1, 10)
        savedCall["countryCode"] = "NL"
        savedCall["stationName"] = "Saved Paris label"
        let saved = try snapshot([savedCall, call("Brussels", 2, 11)]).trip
        var corrected = call("Paris", 1, 10)
        corrected["countryCode"] = "FR"
        corrected["latitude"] = 48.881
        corrected["longitude"] = 2.355

        let refreshed = try snapshot([corrected, call("Brussels", 2, 11)]).merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes[0].station.id, saved.stopTimes[0].station.id)
        XCTAssertEqual(refreshed.stopTimes[0].station.countryCode, "FR")
        XCTAssertEqual(refreshed.stopTimes[0].station.location, GeoCoordinate(latitude: 48.881, longitude: 2.355))
        XCTAssertEqual(refreshed.stopTimes[0].station.names, saved.stopTimes[0].station.names)
        XCTAssertEqual(refreshed.stopTimes[0].station.codes, saved.stopTimes[0].station.codes)
    }

    func testRefreshRetainsValidSavedMetadataWhenCurrentLocationOrCountryIsUnknown() throws {
        let saved = try snapshot([call("A", 1, 10), call("B", 2, 11)]).trip
        var invalid = call("A", 1, 10)
        invalid["countryCode"] = "XX"
        invalid["latitude"] = 91
        invalid["longitude"] = 181

        let refreshed = try snapshot([invalid, call("B", 2, 11)]).merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes[0].station, saved.stopTimes[0].station)
    }

    func testFreshRouteMembershipDoesNotApplyAnotherStationsStatusToRemovedBoardingStop() throws {
        let saved = try snapshot([call("A", 1, 10), call("B", 2, 11), call("C", 3, 12)]).trip
        let update = try snapshot([call("A", 1, 10), call("C", 2, 12, cancelled: true)])

        let refreshed = update.merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes.map(\.station.displayName), ["A", "C"])
        XCTAssertFalse(refreshed.stopTimes[0].isCancelled)
        XCTAssertTrue(refreshed.stopTimes[1].isCancelled)
        let passenger = RailJourneyProgress(
            trip: refreshed, referenceDate: date(10),
            boardingStationID: RailIdentifier(rawValue: "eu:transitous:B"),
            alightingStationID: RailIdentifier(rawValue: "eu:transitous:C")
        )
        XCTAssertEqual(passenger.phase, .unavailable)
        XCTAssertTrue(passenger.stops.isEmpty, "A removed boarding call cannot silently become another station")
        let savedJourney = RailJourneyProgress(
            trip: refreshed, referenceDate: date(10),
            boardingPlace: place(saved.stopTimes[1].station),
            alightingPlace: place(saved.stopTimes[2].station)
        )
        XCTAssertEqual(savedJourney.phase, .unavailable)
        XCTAssertTrue(savedJourney.stops.isEmpty)
    }

    func testFreshRouteAddsStopsAndRetainsTheSelectedPassengerBounds() throws {
        let saved = try snapshot([call("A", 1, 9), call("B", 2, 10), call("C", 3, 12), call("D", 4, 13)]).trip
        let update = try snapshot([call("A", 1, 9), call("B", 2, 10), call("X", 3, 11), call("C", 4, 12), call("D", 5, 13)])

        let refreshed = update.merging(into: saved)
        let passenger = RailJourneyProgress(
            trip: refreshed, referenceDate: date(10),
            boardingStationID: RailIdentifier(rawValue: "eu:transitous:B"),
            alightingStationID: RailIdentifier(rawValue: "eu:transitous:C")
        )

        XCTAssertEqual(refreshed.stopTimes.map(\.station.displayName), ["A", "B", "X", "C", "D"])
        XCTAssertEqual(passenger.stops.map(\.station.displayName), ["B", "X", "C"])
        XCTAssertEqual(passenger.departureDate, date(10))
        XCTAssertEqual(passenger.arrivalDate, date(12))
        XCTAssertEqual(refreshed.stopTimes[1].station, saved.stopTimes[1].station)
    }

    func testRepeatedStationCallsKeepTheirOwnCurrentTimesAndPlatforms() throws {
        let saved = try snapshot([
            call("A", 1, 10, platform: "1"), call("B", 2, 11), call("A", 3, 12, platform: "3"),
        ]).trip
        let update = try snapshot([
            call("A", 1, 10, platform: "2"), call("B", 2, 11), call("A", 3, 13, platform: "4"),
        ])

        let refreshed = update.merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes.map(\.scheduledArrival), [date(10), date(11), date(13)])
        XCTAssertEqual(refreshed.stopTimes.map(\.expectedPlatform), ["2", nil, "4"])
    }

    func testHealthySnapshotRecoversAnEmptySavedTimetable() throws {
        let saved = try snapshot([]).trip
        let update = try snapshot([call("A", 1, 10), call("B", 2, 11)])

        let refreshed = update.merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes.map(\.station.displayName), ["A", "B"])
        XCTAssertEqual(RailJourneyProgress(trip: refreshed, referenceDate: date(10)).phase, .underway)
    }

    func testRepeatedCallDoesNotInheritAnotherOccurrencesMissingPlatform() throws {
        let saved = try snapshot([
            call("A", 1, 10, platform: "1"), call("B", 2, 11), call("A", 3, 12, platform: "3"),
        ]).trip
        let update = try snapshot([
            call("A", 1, 10), call("B", 2, 11), call("A", 3, 12),
        ])

        let refreshed = update.merging(into: saved)

        XCTAssertEqual(refreshed.stopTimes.map(\.plannedPlatform), ["1", nil, "3"])
    }

    func testPlatformTimestampFollowsTheActualAssignmentOnImportAndRefresh() throws {
        var retained = call("A", 1, 10, platform: "9")
        retained["platformObservedAt"] = timestamp(7)
        retained["platformSource"] = "Station feed"
        let imported = try snapshot([retained, call("B", 2, 11)]).trip
        XCTAssertEqual(imported.stopTimes.first?.platformObservedAt, date(7))
        let latest = try snapshot([call("A", 1, 10, platform: "8"), call("B", 2, 11)]).merging(into: imported)
        XCTAssertEqual(latest.stopTimes.first?.platformObservedAt, date(9), "An untimed new assignment uses the source snapshot's timestamp")
        XCTAssertNil(latest.stopTimes.first?.platformSource, "An independent report does not inherit another feed's attribution")
        let cleared = try snapshot([call("A", 1, 10), call("B", 2, 11)]).merging(into: latest)
        XCTAssertNil(cleared.stopTimes.first?.platformObservedAt)
    }

    private func snapshot(_ stops: [[String: Any]]) throws -> BackendTripSnapshot {
        let payload: [String: Any] = [
            "id": "eu:transitous:20261112_demo", "source": "transitous", "serviceDate": "2026-11-12",
            "operatorName": "Test Rail", "product": "IC 1", "headsign": "Destination",
            "fetchedAt": "2026-11-12T09:00:00Z", "stops": stops,
        ]
        return try JSONDecoder().decode(BackendTripSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func call(_ name: String, _ sequence: Int, _ hour: Int, cancelled: Bool = false, platform: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "stationId": "eu:transitous:\(name)", "stationName": name, "countryCode": "DE",
            "latitude": 52.0 + Double(sequence) / 100, "longitude": 13.0,
            "sequence": sequence, "scheduledArrival": timestamp(hour), "scheduledDeparture": timestamp(hour),
            "cancelled": cancelled, "passed": false,
        ]
        value["plannedPlatform"] = platform
        value["expectedPlatform"] = platform
        return value
    }

    private func timestamp(_ hour: Int) -> String { String(format: "2026-11-12T%02d:00:00Z", hour) }
    private func date(_ hour: Int) -> Date { ISO8601DateFormatter().date(from: timestamp(hour))! }

    private func place(_ station: Station) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName, context: "",
            countryCode: station.countryCode, timeZoneIdentifier: "Europe/Berlin",
            location: station.location, eligibleModes: ["NIGHT_RAIL"], attributions: []
        )
    }
}
