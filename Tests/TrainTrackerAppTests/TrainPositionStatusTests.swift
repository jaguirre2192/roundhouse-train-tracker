import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TrainPositionStatusTests: XCTestCase {
    func testRealPositionStatusReflectsObservationAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(status(minutesOld: 4, now: now), .live)
        XCTAssertEqual(status(minutesOld: 8, now: now), .recent)
        XCTAssertEqual(status(minutesOld: 79, now: now), .stale)
    }

    func testEstimatedAndUnavailableRemainDistinct() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let estimated = VehiclePosition(
            coordinate: GeoCoordinate(latitude: 40, longitude: -3),
            source: .inferred,
            confidence: 0.5,
            asOf: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(TrainPositionStatus(position: estimated, now: now), .estimated)
        XCTAssertEqual(TrainPositionStatus(position: nil, now: now), .unavailable)
    }

    private func status(minutesOld: TimeInterval, now: Date) -> TrainPositionStatus {
        let position = VehiclePosition(
            coordinate: GeoCoordinate(latitude: 40, longitude: -3),
            source: .real,
            confidence: 1,
            asOf: now.addingTimeInterval(-minutesOld * 60)
        )
        return TrainPositionStatus(position: position, now: now)
    }
}
