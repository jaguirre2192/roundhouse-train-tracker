import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TripRefreshEvidenceTests: XCTestCase {
    @MainActor
    func testPartialRefreshRecordsEachTripsOwnResult() async throws {
        let trips = Array(JourneyPlanTestFixtures.makeTrips().filter { !$0.isComplete }.prefix(2))
        XCTAssertEqual(trips.count, 2)
        let successful = try XCTUnwrap(trips.first)
        let failed = try XCTUnwrap(trips.last)
        let adapter = EvidenceRailAdapter(trips: trips)
        await adapter.fail([failed.id])
        let library = makeLibrary(trips: trips, adapter: adapter)

        await library.refreshTrackedTrips()

        XCTAssertNotNil(library.lastSuccessfulCheck(for: successful.id))
        XCTAssertFalse(library.lastRefreshFailed(for: successful.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: failed.id))
        XCTAssertTrue(library.lastRefreshFailed(for: failed.id))
    }

    @MainActor
    func testOtherTripSuccessDoesNotAdvanceFailedTripsLastCheck() async throws {
        let trips = Array(JourneyPlanTestFixtures.makeTrips().filter { !$0.isComplete }.prefix(2))
        XCTAssertEqual(trips.count, 2)
        let first = try XCTUnwrap(trips.first)
        let second = try XCTUnwrap(trips.last)
        let adapter = EvidenceRailAdapter(trips: trips)
        let library = makeLibrary(trips: trips, adapter: adapter)
        await library.refreshTrackedTrip(id: first.id)
        let firstCheck = try XCTUnwrap(library.lastSuccessfulCheck(for: first.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: second.id))

        await adapter.fail([first.id])
        await library.refreshTrackedTrips()

        XCTAssertEqual(library.lastSuccessfulCheck(for: first.id), firstCheck)
        XCTAssertTrue(library.lastRefreshFailed(for: first.id))
        XCTAssertNotNil(library.lastSuccessfulCheck(for: second.id))
        XCTAssertFalse(library.lastRefreshFailed(for: second.id))
    }

    @MainActor
    func testSuccessfulRetryClearsOnlyThatTripsFailure() async throws {
        let trips = Array(JourneyPlanTestFixtures.makeTrips().filter { !$0.isComplete }.prefix(2))
        let first = try XCTUnwrap(trips.first)
        let second = try XCTUnwrap(trips.last)
        let adapter = EvidenceRailAdapter(trips: trips)
        await adapter.fail(Set(trips.map(\.id)))
        let library = makeLibrary(trips: trips, adapter: adapter)
        await library.refreshTrackedTrips()

        await adapter.fail([second.id])
        await library.refreshTrackedTrip(id: first.id)

        XCTAssertNotNil(library.lastSuccessfulCheck(for: first.id))
        XCTAssertFalse(library.lastRefreshFailed(for: first.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: second.id))
        XCTAssertTrue(library.lastRefreshFailed(for: second.id))
    }

    @MainActor
    func testRestoringSavedTripsPreservesTheOriginalCheckTime() async throws {
        let suiteName = "TripRefreshEvidenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = TripArchive(defaults: defaults)
        let trips = JourneyPlanTestFixtures.makeTrips().filter { !$0.isComplete }
        let trip = try XCTUnwrap(trips.first)
        let adapter = EvidenceRailAdapter(trips: trips)
        let original = makeLibrary(trips: trips, adapter: adapter, archive: archive)
        await original.refreshTrackedTrips()
        let originalCheck = try XCTUnwrap(original.lastSuccessfulCheck(for: trip.id))

        let restored = makeLibrary(trips: nil, adapter: adapter, archive: archive)

        XCTAssertTrue(restored.containsTrip(id: trip.id))
        XCTAssertEqual(restored.lastSuccessfulCheck(for: trip.id), originalCheck,
                       "Reload must retain the original observation time, not claim a new check")
        XCTAssertFalse(restored.lastRefreshFailed(for: trip.id))
    }

    @MainActor
    func testRemovingAndReaddingTripClearsItsEvidence() async throws {
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first { !$0.isComplete })
        let adapter = EvidenceRailAdapter(trips: [trip])
        let library = makeLibrary(trips: [trip], adapter: adapter)
        await library.refreshTrackedTrips()
        await adapter.fail([trip.id])
        await library.refreshTrackedTrips()
        XCTAssertTrue(library.lastRefreshFailed(for: trip.id))

        XCTAssertTrue(library.removeTrip(id: trip.id))
        XCTAssertTrue(try library.storeTrackedTrip(trip))

        XCTAssertNil(library.lastSuccessfulCheck(for: trip.id))
        XCTAssertFalse(library.lastRefreshFailed(for: trip.id))
    }

    @MainActor
    func testResponseForRemovedTripDoesNotRestoreTripOrEvidence() async throws {
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first { !$0.isComplete })
        let adapter = EvidenceRailAdapter(trips: [trip], suspendsRequest: true)
        let library = makeLibrary(trips: [trip], adapter: adapter)
        let refresh = Task { await library.refreshTrackedTrips() }
        await adapter.waitUntilRequested()

        XCTAssertTrue(library.removeTrip(id: trip.id))
        await adapter.resume()
        await refresh.value

        XCTAssertFalse(library.containsTrip(id: trip.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: trip.id))
        XCTAssertFalse(library.lastRefreshFailed(for: trip.id))
    }

    @MainActor
    func testRefreshDuringInFlightPassWaitsForThatPass() async throws {
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first { !$0.isComplete })
        let adapter = EvidenceRailAdapter(trips: [trip], suspendsRequest: true)
        let library = makeLibrary(trips: [trip], adapter: adapter)
        let poll = Task { await library.refreshTrackedTrips() }
        await adapter.waitUntilRequested()

        // Pull to refresh arrives while the poll is still waiting on the network.
        var pullFinished = false
        let pull = Task {
            await library.refreshTrackedTrips()
            pullFinished = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(pullFinished, "A coalesced refresh must not end before the in-flight pass")

        await adapter.resume()
        await poll.value
        await pull.value

        XCTAssertTrue(pullFinished)
        XCTAssertFalse(library.isRefreshing)
        XCTAssertNotNil(library.lastSuccessfulCheck(for: trip.id))
    }

    @MainActor
    private func makeLibrary(
        trips: [TrainTrip]?,
        adapter: EvidenceRailAdapter,
        archive: TripArchive? = nil
    ) -> TripLibrary {
        TripLibrary(
            trips: trips,
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: RecordingPushCoordinator(),
            archive: archive,
            now: { Date(timeIntervalSince1970: 1_721_814_000) }
        )
    }
}

private actor EvidenceRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities
    private let trips: [RailIdentifier: TrainTrip]
    private var failedIDs: Set<RailIdentifier> = []
    private let suspendsRequest: Bool
    private var pendingRequest: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false

    init(trips: [TrainTrip], suspendsRequest: Bool = false) {
        capabilities = trips[0].capabilities
        self.trips = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        self.suspendsRequest = suspendsRequest
    }

    func fail(_ tripIDs: Set<RailIdentifier>) { failedIDs = tripIDs }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func resume() {
        pendingRequest?.resume()
        pendingRequest = nil
    }

    func searchStations(query: String) async throws -> [Station] { [] }
    func resolveStation(id: RailIdentifier) async throws -> Station { throw RailAdapterError.notFound }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        if suspendsRequest {
            await withCheckedContinuation { continuation in
                pendingRequest = continuation
                requested = true
                requestWaiter?.resume()
                requestWaiter = nil
            }
        }
        if failedIDs.contains(id) { throw URLError(.notConnectedToInternet) }
        guard let trip = trips[id] else { throw RailAdapterError.notFound }
        return trip
    }
}
