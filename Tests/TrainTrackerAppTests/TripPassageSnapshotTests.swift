import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TripPassageSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    func testLegacyWirePassedFlagDoesNotConfirmArrival() throws {
        let trip = try snapshot(passed: true).trip
        XCTAssertFalse(trip.isComplete)
        XCTAssertFalse(trip.stopTimes[0].hasConfirmedPassage(at: now))
        XCTAssertEqual(trip.nextStop?.id, trip.stopTimes[0].id)
    }

    func testExplicitArrivalAndDepartureSurviveDecodeAndRefresh() throws {
        let instant = ISO8601DateFormatter().string(from: now)
        let departed = try snapshot(passed: true, passage: instant)
        let arrived = try snapshot(passed: false, arrival: instant)
        XCTAssertTrue(departed.trip.stopTimes[0].hasConfirmedPassage(at: now))
        XCTAssertFalse(arrived.trip.stopTimes[0].hasConfirmedPassage(at: now))
        XCTAssertTrue(arrived.trip.stopTimes[0].hasConfirmedArrival(at: now))
        let refreshed = arrived.merging(into: departed.trip)
        XCTAssertEqual(refreshed.stopTimes[0].arrivalObservedAt, now)
        XCTAssertNil(refreshed.stopTimes[0].passageObservedAt)
        XCTAssertFalse(refreshed.stopTimes[0].isPassed)
    }

    func testMalformedObservationIsRejectedAndFutureObservationCannotConfirm() throws {
        XCTAssertFalse(try snapshot(passed: true, passage: "invalid").hasValidWireDates)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(121))
        let value = try snapshot(passed: true, passage: future, arrival: future)
        XCTAssertFalse(value.trip.stopTimes[0].hasConfirmedPassage(at: now))
        XCTAssertFalse(value.trip.stopTimes[0].hasConfirmedArrival(at: now))
    }

    private func snapshot(passed: Bool, passage: String? = nil, arrival: String? = nil) throws -> BackendTripSnapshot {
        var stop: [String: Any] = [
            "stationId": "us:amtraker:TEST", "stationName": "Test station", "countryCode": "US",
            "latitude": 40, "longitude": -74, "sequence": 1,
            "scheduledArrival": "2026-07-14T10:00:00Z", "cancelled": false, "passed": passed,
        ]
        stop["passageObservedAt"] = passage
        stop["arrivalObservedAt"] = arrival
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "us:amtraker:171-14", "source": "amtraker", "serviceDate": "2026-07-14",
            "operatorName": "Amtrak", "product": "171", "headsign": "Test station",
            "fetchedAt": ISO8601DateFormatter().string(from: now), "stops": [stop],
        ])
        return try JSONDecoder().decode(BackendTripSnapshot.self, from: data)
    }
}
