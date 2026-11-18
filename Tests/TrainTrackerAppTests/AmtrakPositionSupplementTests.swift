import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// Amtrak GPS arrives in the backend snapshot, including journeys saved with Transitous IDs.
@MainActor
final class AmtrakPositionSupplementTests: XCTestCase {
    func testMissingPositionIsFilledByBackendSnapshot() async throws {
        let saved = try BackendOnlyTripDataFixture.trip()
        let http = try BackendOnlyTripDataHTTPClient(positionAge: 30)
        let library = makeLibrary(saved, http: http)

        await library.refreshTrackedTrip(id: saved.id)

        let result = try XCTUnwrap(library.trip(id: saved.id))
        XCTAssertEqual(result.positions.count, 1)
        XCTAssertTrue(result.capabilities.hasPositions)
        XCTAssertEqual(result.positions.first?.source, .real)
        XCTAssertEqual(TrainPositionStatus(position: result.positions.first, now: BackendOnlyTripDataFixture.now), .live)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1, "GPS requires no second native provider request")
        XCTAssertEqual(requests.first?.url?.host, BackendOnlyTripDataFixture.baseURL.host)
    }

    func testPositionKeptFromFirstSaveIsReplacedByNewerServerGPS() async throws {
        let saved = try BackendOnlyTripDataFixture.trip(positionAge: 4_800)
        let http = try BackendOnlyTripDataHTTPClient(positionAge: 60)
        let library = makeLibrary(saved, http: http)

        await library.refreshTrackedTrip(id: saved.id)

        XCTAssertEqual(library.trip(id: saved.id)?.positions.first?.asOf,
                       BackendOnlyTripDataFixture.now.addingTimeInterval(-60))
    }

    func testSnapshotWithoutPositionRetainsLastKnownPositionWithoutInventingOne() async throws {
        for age: TimeInterval? in [nil, 4_800] {
            let saved = try BackendOnlyTripDataFixture.trip(positionAge: age)
            let http = try BackendOnlyTripDataHTTPClient()
            let library = makeLibrary(saved, http: http)

            await library.refreshTrackedTrip(id: saved.id)

            XCTAssertEqual(library.trip(id: saved.id)?.positions, saved.positions)
            if age != nil {
                XCTAssertEqual(TrainPositionStatus(position: library.trip(id: saved.id)?.positions.first,
                                                    now: BackendOnlyTripDataFixture.now), .stale)
            }
        }
    }

    func testBackendFailureRetainsPreviousGPSAndMarksTheCheckFailed() async throws {
        let saved = try BackendOnlyTripDataFixture.trip(positionAge: 180)
        let http = try BackendOnlyTripDataHTTPClient(status: 503, positionAge: 0)
        let library = makeLibrary(saved, http: http)

        await library.refreshTrackedTrip(id: saved.id)

        XCTAssertEqual(library.trip(id: saved.id), saved)
        XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: saved.id))
    }

    private func makeLibrary(_ trip: TrainTrip, http: BackendOnlyTripDataHTTPClient) -> TripLibrary {
        TripLibrary(trips: [trip], backendSnapshots: TripSnapshotBackendClient(
            baseURL: BackendOnlyTripDataFixture.baseURL, client: http
        ), pushCoordinator: RecordingPushCoordinator(), archive: nil, now: { BackendOnlyTripDataFixture.now })
    }
}
