import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class AtomicTripLibraryFailureTests: XCTestCase {
    func testRefreshWriteFailureRetainsSavedSnapshotAndCheckAndReportsFailure() async throws {
        let context = try Context()
        defer { context.cleanUp() }
        let saved = JourneyPlanTestFixtures.makeTrips()[0]
        let refreshed = JourneyPlanTestFixtures.replacingCoordinate(in: saved, latitude: 35.12345)
        XCTAssertNotEqual(saved, refreshed)
        let now = saved.serviceDate.addingTimeInterval(600)
        let checkedAt = now.addingTimeInterval(-60)
        let archive = context.tripArchive()
        try archive.save([saved], lastChecks: [saved.id: checkedAt])
        let originalBytes = try Data(contentsOf: context.tripURL)
        let provider = ReplacementSnapshotProvider(snapshot: refreshed)
        let library = TripLibrary(
            backendSnapshots: provider, pushCoordinator: RecordingPushCoordinator(), archive: archive,
            automaticRefreshEnabled: true, now: { now }
        )
        try context.makeReadOnly()
        defer { context.makeWritable() }

        await library.refreshTrackedTrip(id: saved.id)

        let requestCount = await provider.enrichmentCount
        XCTAssertEqual(requestCount, 1, "The backend succeeded; persistence is the failure under test")
        XCTAssertEqual(library.trips, [saved])
        XCTAssertEqual(library.lastSuccessfulCheck(for: saved.id), checkedAt)
        XCTAssertNil(library.lastUpdated)
        XCTAssertTrue(library.lastRefreshFailed(for: saved.id))
        XCTAssertNotNil(library.refreshError)
        XCTAssertFalse(library.isRefreshing)
        XCTAssertEqual(try Data(contentsOf: context.tripURL), originalBytes)
        XCTAssertEqual(context.tripArchive().load(), [saved])
        XCTAssertEqual(context.tripArchive().loadLastChecks(), [saved.id: checkedAt])
    }

    func testRemovalWriteFailureRetainsTrackedStateCheckAndPushWatch() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let saved = JourneyPlanTestFixtures.makeTrips()[0]
        let now = saved.serviceDate
        let checkedAt = now.addingTimeInterval(-30)
        let archive = context.tripArchive()
        try archive.save([saved], lastChecks: [saved.id: checkedAt])
        let originalBytes = try Data(contentsOf: context.tripURL)
        let push = RecordingPushCoordinator()
        let library = TripLibrary(pushCoordinator: push, archive: archive,
                                  automaticRefreshEnabled: true, now: { now })
        library.resumePushWatches()
        XCTAssertEqual(push.watchedTripIDs, [saved.id])
        try context.makeReadOnly()
        defer { context.makeWritable() }

        XCTAssertFalse(library.removeTrip(id: saved.id))

        XCTAssertTrue(library.containsTrip(id: saved.id))
        XCTAssertEqual(library.trips, [saved])
        XCTAssertEqual(library.lastSuccessfulCheck(for: saved.id), checkedAt)
        XCTAssertTrue(push.unwatchedTripIDs.isEmpty)
        XCTAssertEqual(push.watchedTripIDs, [saved.id])
        XCTAssertNotNil(library.refreshError)
        XCTAssertEqual(try Data(contentsOf: context.tripURL), originalBytes)
        XCTAssertEqual(context.tripArchive().loadLastChecks(), [saved.id: checkedAt])
    }

    func testBackgroundRuntimePreservesPendingJournalOwnershipUntilTripStorageUnlocks() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let saved = JourneyPlanTestFixtures.makeTrips()[0]
        let checkedAt = saved.serviceDate
        try TripArchive(defaults: context.defaults, key: Context.tripKey)
            .save([saved], lastChecks: [saved.id: checkedAt])
        let gate = ProtectedDataGate()
        let tripArchive = TripArchive(
            defaults: context.defaults, key: Context.tripKey, fileURL: context.tripURL,
            canReadLegacyData: { gate.isAvailable }
        )
        let attempt = JourneyPlanTrackingAttempt(
            id: UUID(), insertedChildTripIDs: [], pendingInsertionChildTripID: saved.id,
            preExistingChildTripIDs: []
        )
        let planArchive = JourneyPlanArchive(
            defaults: context.defaults, key: "pendingPlans", fileURL: context.planURL,
            canReadLegacyData: { true }
        )
        try planArchive.save([])
        try planArchive.saveTrackingAttempts([attempt])
        let originalJournal = try Data(contentsOf: context.planURL.appendingPathExtension("journal"))
        let library = TripLibrary(pushCoordinator: RecordingPushCoordinator(), archive: tripArchive,
                                  automaticRefreshEnabled: false)
        let plans = try JourneyPlanLibrary(tripLibrary: library, archive: planArchive)
        let runtime = TrainJourneyRuntime(library: library, planLibrary: plans, navigation: AppNavigationModel())

        runtime.retryArchiveAvailability()

        XCTAssertTrue(library.tripArchiveTemporarilyUnavailable)
        XCTAssertTrue(library.trips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.tripURL.path))
        XCTAssertEqual(try planArchive.loadTrackingAttempts(), [attempt])
        XCTAssertEqual(try Data(contentsOf: context.planURL.appendingPathExtension("journal")), originalJournal,
                       "An unreadable trip archive does not prove the pending child was never saved")

        gate.isAvailable = true
        runtime.retryArchiveAvailability()

        XCTAssertFalse(library.tripArchiveRecoveryRequired)
        XCTAssertFalse(library.tripArchiveTemporarilyUnavailable)
        XCTAssertEqual(library.trips, [saved])
        XCTAssertEqual(library.lastSuccessfulCheck(for: saved.id), checkedAt)
        XCTAssertTrue(plans.recoveryIssues.isEmpty)
        let recoveredAttempts = try planArchive.loadTrackingAttempts()
        XCTAssertEqual(recoveredAttempts.count, 1)
        let recovered = try XCTUnwrap(recoveredAttempts.first)
        XCTAssertEqual(recovered.id, attempt.id)
        XCTAssertNil(recovered.pendingInsertionChildTripID)
        XCTAssertEqual(recovered.insertedChildTripIDs, [saved.id])
        XCTAssertTrue(recovered.preExistingChildTripIDs.isEmpty)
    }

    @MainActor
    private final class ProtectedDataGate {
        var isAvailable = false
    }

    private struct Context {
        static let tripKey = "atomicFailureTrips"
        let suiteName: String
        let defaults: UserDefaults
        let directory: URL
        var tripURL: URL { directory.appendingPathComponent("trips.plist") }
        var planURL: URL { directory.appendingPathComponent("plans.plist") }

        init() throws {
            suiteName = "AtomicTripLibraryFailureTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @MainActor
        func tripArchive() -> TripArchive {
            TripArchive(defaults: defaults, key: Self.tripKey, fileURL: tripURL, canReadLegacyData: { true })
        }

        func makeReadOnly() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }

        func makeWritable() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        func cleanUp() {
            makeWritable()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private actor ReplacementSnapshotProvider: TripDataProviding {
    let snapshot: TrainTrip
    private(set) var enrichmentCount = 0

    init(snapshot: TrainTrip) { self.snapshot = snapshot }

    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }

    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection,
               source: RailSource?) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { snapshot }

    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip {
        enrichmentCount += 1
        return snapshot
    }
}
