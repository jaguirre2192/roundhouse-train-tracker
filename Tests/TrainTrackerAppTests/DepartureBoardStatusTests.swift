import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class DepartureBoardStatusTests: XCTestCase {
    private let scheduled = Date(timeIntervalSince1970: 1_792_900_000)

    func testCancellationWinsOverAnyEstimate() {
        let stop = makeStop(expected: scheduled.addingTimeInterval(20 * 60), cancelled: true)
        XCTAssertEqual(DepartureBoardStatus(stopTime: stop), .cancelled)
    }

    func testFiveOrMoreMinutesLateCarriesTheTimetableTime() {
        let stop = makeStop(expected: scheduled.addingTimeInterval(7 * 60))
        XCTAssertEqual(DepartureBoardStatus(stopTime: stop), .delayed(minutes: 7, scheduled: scheduled))
    }

    func testSmallDelaysAndEarlyRunningReadAsOnTime() {
        XCTAssertEqual(DepartureBoardStatus(stopTime: makeStop(expected: scheduled.addingTimeInterval(4 * 60))), .onTime)
        XCTAssertEqual(DepartureBoardStatus(stopTime: makeStop(expected: scheduled.addingTimeInterval(-2 * 60))), .onTime)
    }

    func testRowsWithoutAnEstimateSayTheyAreTimetableOnly() {
        XCTAssertEqual(DepartureBoardStatus(stopTime: makeStop(expected: nil)), .timetableOnly)
    }

    func testArrivalOnlyEstimatesStillCount() {
        let stop = StopTime(
            station: station,
            sequence: 1,
            scheduledArrival: scheduled,
            expectedArrival: scheduled.addingTimeInterval(12 * 60)
        )
        XCTAssertEqual(DepartureBoardStatus(stopTime: stop), .delayed(minutes: 12, scheduled: scheduled))
    }

    private func makeStop(expected: Date?, cancelled: Bool = false) -> StopTime {
        StopTime(
            station: station,
            sequence: 1,
            scheduledDeparture: scheduled,
            expectedDeparture: expected,
            isCancelled: cancelled
        )
    }

    private var station: Station {
        Station(
            id: RailIdentifier(rawValue: "test:station"),
            names: [LocalizedStationName("Station")],
            location: GeoCoordinate(latitude: 0, longitude: 0),
            countryCode: "DE"
        )
    }
}
