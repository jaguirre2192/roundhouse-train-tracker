import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class TripLibraryBackendOnlyTests: XCTestCase {
    func testStationSearchBoardAndTrackingUseBackendSnapshotsIncludingGPS() async throws {
        let http = try BackendOnlyTripDataHTTPClient(positionAge: 30)
        let library = makeLibrary(http: http)

        let stations = try await library.searchStations(query: "Washington", source: .unitedStates)
        XCTAssertEqual(stations.first?.id, BackendOnlyTripDataFixture.stationID)
        let board = try await library.board(stationID: XCTUnwrap(stations.first?.id), source: .unitedStates,
                                            at: BackendOnlyTripDataFixture.now)
        try await library.addTrip(XCTUnwrap(board.first), source: .unitedStates)
        let trip = try XCTUnwrap(library.trips.first)
        XCTAssertEqual(trip.positions.first?.coordinate, GeoCoordinate(latitude: 39.176, longitude: -76.694))
        XCTAssertEqual(trip.stopTimes.first?.expectedPlatform, "3")
        XCTAssertEqual(trip.stopTimes.first?.expectedDeparture,
                       ISO8601DateFormatter().date(from: "2026-11-14T10:05:00Z"))
        await library.refreshTrackedTrip(id: trip.id)
        XCTAssertEqual(library.trips.first?.positions, trip.positions)
        XCTAssertEqual(library.lastSuccessfulCheck(for: trip.id), BackendOnlyTripDataFixture.now)

        let requests = await http.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, [
            "/v1/stations/search", "/v1/stations/board", "/v1/trips/snapshot", "/v1/trips/snapshot",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == BackendOnlyTripDataFixture.baseURL.host })
    }

    func testFailuresNeverBecomeEmptySuccessesOrReplaceSavedData() async throws {
        for status in [503, 429] {
            let http = try BackendOnlyTripDataHTTPClient(status: status)
            let saved = try BackendOnlyTripDataFixture.trip(positionAge: 300)
            let library = makeLibrary(http: http, trips: [saved])
            await assertOperationsFail(library, expectedStatus: status)
            await library.refreshTrackedTrip(id: saved.id)

            XCTAssertEqual(library.trips, [saved])
            XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
            XCTAssertNil(library.lastSuccessfulCheck(for: saved.id))
            XCTAssertNil(library.lastUpdated)
            XCTAssertNotNil(library.refreshError)
            let requests = await http.requests
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == BackendOnlyTripDataFixture.baseURL.host })
            XCTAssertEqual(requests.count, status == 429 ? 1 : 5,
                           "Retry-After pauses all later train requests without bypassing the backend")
        }
    }

    func testMissingBackendConfigurationFailsWithoutMakingAnyNetworkRequest() async throws {
        let http = try BackendOnlyTripDataHTTPClient()
        let saved = try BackendOnlyTripDataFixture.trip(positionAge: 300)
        let library = TripLibrary(trips: [saved], backendSnapshots: TripSnapshotBackendClient(baseURL: nil, client: http),
                                  pushCoordinator: RecordingPushCoordinator(), archive: nil,
                                  now: { BackendOnlyTripDataFixture.now })
        await assertOperationsFail(library, expectedStatus: nil)
        await library.refreshTrackedTrip(id: saved.id)

        XCTAssertEqual(library.trips, [saved])
        XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: saved.id))
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailedRefreshKeepsPersistedSnapshotAndOriginalSuccessfulCheck() async throws {
        let suite = "TripLibraryBackendOnlyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = TripArchive(defaults: defaults)
        let saved = try BackendOnlyTripDataFixture.trip(positionAge: 300)
        let originalCheck = BackendOnlyTripDataFixture.now.addingTimeInterval(-300)
        try archive.saveOrThrow([saved])
        archive.saveLastChecks([saved.id: originalCheck])
        let http = try BackendOnlyTripDataHTTPClient(status: 503)
        let library = TripLibrary(backendSnapshots: TripSnapshotBackendClient(baseURL: BackendOnlyTripDataFixture.baseURL, client: http),
                                  pushCoordinator: RecordingPushCoordinator(), archive: archive,
                                  now: { BackendOnlyTripDataFixture.now })

        await library.refreshTrackedTrip(id: saved.id)

        XCTAssertEqual(library.trips, [saved])
        XCTAssertEqual(archive.load(), [saved])
        XCTAssertEqual(library.lastSuccessfulCheck(for: saved.id), originalCheck)
        XCTAssertEqual(archive.loadLastChecks()[saved.id], originalCheck)
        XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
    }

    func testEmptySnapshotCannotEraseSavedStopsOrAdvanceCheckTime() async throws {
        let http = try BackendOnlyTripDataHTTPClient(emptyStops: true)
        let saved = try BackendOnlyTripDataFixture.trip(positionAge: 300)
        let library = makeLibrary(http: http, trips: [saved])

        await library.refreshTrackedTrip(id: saved.id)

        XCTAssertEqual(library.trips, [saved])
        XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: saved.id))
    }

    func testCombinedStationSearchDoesNotMaskBackendOutageAsNoResults() async throws {
        let http = try BackendOnlyTripDataHTTPClient(status: 503)
        do {
            _ = try await makeLibrary(http: http).searchStations(query: "Washington")
            XCTFail("A provider outage is not an empty station list")
        } catch RailStationSearchError.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await http.requests
        let scopes = requests.compactMap { request -> String? in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            return items?.first { $0.name == "scope" }?.value
        }
        XCTAssertEqual(Set(scopes), ["us", "international"])
    }

    private func makeLibrary(http: BackendOnlyTripDataHTTPClient, trips: [TrainTrip] = []) -> TripLibrary {
        TripLibrary(trips: trips, backendSnapshots: TripSnapshotBackendClient(
            baseURL: BackendOnlyTripDataFixture.baseURL, client: http, now: { BackendOnlyTripDataFixture.now }
        ), pushCoordinator: RecordingPushCoordinator(), archive: nil, now: { BackendOnlyTripDataFixture.now })
    }

    private func assertOperationsFail(_ library: TripLibrary, expectedStatus: Int?) async {
        for source in [RailSource.unitedStates, .europe] {
            do {
                _ = try await library.searchStations(query: "Washington", source: source)
                XCTFail("Station failures must remain errors")
            } catch { assertBackendError(error, expectedStatus: expectedStatus) }
        }
        do {
            _ = try await library.board(stationID: BackendOnlyTripDataFixture.stationID, source: .europe,
                                        at: BackendOnlyTripDataFixture.now)
            XCTFail("Board failures must remain errors")
        } catch { assertBackendError(error, expectedStatus: expectedStatus) }
        do {
            let trip = try BackendOnlyTripDataFixture.trip()
            try await library.addTrip(StopTimeSummary(tripID: trip.id, serviceDate: trip.serviceDate,
                stopTime: XCTUnwrap(trip.stopTimes.first), headsign: trip.headsign, product: trip.product), source: .europe)
            XCTFail("Trip lookup failures must remain errors")
        } catch { assertBackendError(error, expectedStatus: expectedStatus) }
    }

    private func assertBackendError(_ error: Error, expectedStatus: Int?, file: StaticString = #filePath, line: UInt = #line) {
        switch (error, expectedStatus) {
        case (TripSnapshotBackendClient.ClientError.notConfigured, nil): break
        case (TripSnapshotBackendClient.ClientError.rejected(503), 503): break
        case (TripSnapshotBackendClient.ClientError.rateLimited(let delay), 429):
            XCTAssertEqual(delay, 45, file: file, line: line)
        default: XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
