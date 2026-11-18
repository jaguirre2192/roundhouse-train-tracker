import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanRecoveryTests: XCTestCase {
    @MainActor
    func testCorruptPlanArchiveDoesNotPreventBootingTheValidTripLibrary() throws {
        try assertBootPreservesTrips(
            storedValue: Data("not-json".utf8),
            component: .plans,
            expectedFailure: .corruptData
        )
    }

    @MainActor
    func testFuturePlanArchiveDoesNotPreventBootingTheValidTripLibrary() throws {
        try assertBootPreservesTrips(
            storedValue: Data(#"{"version":2,"plans":{"future":"shape"}}"#.utf8),
            component: .plans,
            expectedFailure: .unsupportedVersion(2)
        )
    }

    @MainActor
    func testCorruptTransactionJournalDoesNotPreventBootingTheValidTripLibrary() throws {
        try assertBootPreservesTrips(
            storedValue: Data("not-json".utf8),
            component: .transactionJournal,
            expectedFailure: .corruptData
        )
    }

    @MainActor
    func testFutureTransactionJournalDoesNotPreventBootingTheValidTripLibrary() throws {
        try assertBootPreservesTrips(
            storedValue: Data(#"{"version":2,"attempts":{"future":"shape"}}"#.utf8),
            component: .transactionJournal,
            expectedFailure: .unsupportedVersion(2)
        )
    }

    @MainActor
    func testRecoveryExportsExactBytesAndBlocksPlanMutation() throws {
        let context = try makeRecoveryContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let corrupt = Data("preserve-these-bytes".utf8)
        context.defaults.set(corrupt, forKey: context.planKey)
        let library = try JourneyPlanLibrary(
            tripLibrary: context.tripLibrary,
            archive: context.planArchive
        )

        XCTAssertEqual(try library.preservedRecoveryPayload(for: .plans), corrupt)
        XCTAssertThrowsError(try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first)]
            )
        )) { error in
            XCTAssertEqual(
                error as? JourneyPlanLibrary.LibraryError,
                .recoveryRequired(.plans)
            )
            XCTAssertTrue(error.localizedDescription.contains("Open Settings"))
        }
        XCTAssertEqual(context.defaults.data(forKey: context.planKey), corrupt)
    }

    @MainActor
    func testRetryLoadsExternallyRestoredArchive() throws {
        let context = try makeRecoveryContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set(Data("not-json".utf8), forKey: context.planKey)
        let library = try JourneyPlanLibrary(
            tripLibrary: context.tripLibrary,
            archive: context.planArchive
        )
        XCTAssertEqual(library.recoveryIssues.map(\.component), [.plans])

        try context.planArchive.save([])
        try library.retryRecovery()

        XCTAssertTrue(library.recoveryIssues.isEmpty)
        XCTAssertTrue(library.plans.isEmpty)
    }

    @MainActor
    func testResetClearsOnlyConfirmedComponentAndRetainsTrips() throws {
        let context = try makeRecoveryContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let corruptPlan = Data("bad-plan".utf8)
        let corruptJournal = Data("bad-journal".utf8)
        context.defaults.set(corruptPlan, forKey: context.planKey)
        context.defaults.set(corruptJournal, forKey: context.journalKey)
        let library = try JourneyPlanLibrary(
            tripLibrary: context.tripLibrary,
            archive: context.planArchive
        )

        try library.resetRecovery(for: .plans)

        XCTAssertNil(context.defaults.object(forKey: context.planKey))
        XCTAssertEqual(context.defaults.data(forKey: context.journalKey), corruptJournal)
        XCTAssertEqual(library.recoveryIssues.map(\.component), [.transactionJournal])
        XCTAssertEqual(context.tripLibrary.trips.map(\.id), [context.trip.id])

        try library.resetRecovery(for: .transactionJournal)
        XCTAssertNil(context.defaults.object(forKey: context.journalKey))
        XCTAssertTrue(library.recoveryIssues.isEmpty)
        XCTAssertEqual(context.tripLibrary.trips.map(\.id), [context.trip.id])
    }

    @MainActor
    func testAbandonedAttemptDoesNotClaimFailedChildLaterAddedIndividually() throws {
        let suiteName = "JourneyPlanAbandonedAttemptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripArchive = TripArchive(defaults: defaults, key: "abandonedTrips")
        let planArchive = JourneyPlanArchive(defaults: defaults, key: "abandonedPlans")
        let trips = JourneyPlanTestFixtures.makeTrips()
        let invalidSecond = JourneyPlanTestFixtures.replacingCoordinate(in: trips[1], latitude: .nan)

        let firstTripLibrary = TripLibrary(
            trips: [],
            pushCoordinator: RecordingPushCoordinator(),
            archive: tripArchive,
            automaticRefreshEnabled: false
        )
        let firstPlanLibrary = try JourneyPlanLibrary(
            tripLibrary: firstTripLibrary,
            archive: planArchive
        )
        XCTAssertThrowsError(try firstPlanLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0], invalidSecond])
        ))

        let recreatedTripLibrary = TripLibrary(
            trips: nil,
            pushCoordinator: RecordingPushCoordinator(),
            archive: tripArchive,
            automaticRefreshEnabled: false
        )
        let recreatedPlanLibrary = try JourneyPlanLibrary(
            tripLibrary: recreatedTripLibrary,
            archive: planArchive
        )
        XCTAssertTrue(try recreatedTripLibrary.storeTrackedTrip(trips[1]))

        let secondPlan = try recreatedPlanLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]])
        )
        XCTAssertEqual(secondPlan.preExistingChildTripIDs, [trips[1].id])

        try recreatedPlanLibrary.removePlanAndStopTrackingChildren(id: secondPlan.id)
        XCTAssertTrue(recreatedTripLibrary.containsTrip(id: trips[1].id))
    }

    @MainActor
    func testInvalidRemovableChildAndGroupingFailurePreserveMemoryAndDurableArchive() throws {
        let validChild = JourneyPlanTestFixtures.makeTrips()[0]
        let invalidChild = JourneyPlanTestFixtures.replacingCoordinate(in: validChild, latitude: .nan)
        let setupTripLibrary = TripLibrary(
            trips: [],
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: false
        )
        let setupArchive = RecordingJourneyPlanArchive()
        let setupLibrary = try JourneyPlanLibrary(
            tripLibrary: setupTripLibrary,
            archive: setupArchive
        )
        let plan = try setupLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [validChild])
        )

        let suiteName = "JourneyPlanInvalidRemovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripArchive = TripArchive(defaults: defaults)
        try tripArchive.saveOrThrow([validChild])
        let push = RecordingPushCoordinator()
        let tripLibrary = TripLibrary(
            trips: [invalidChild],
            pushCoordinator: push,
            archive: tripArchive,
            automaticRefreshEnabled: false
        )
        let planArchive = RecordingJourneyPlanArchive(plans: [plan])
        planArchive.shouldFailSave = true
        let library = try JourneyPlanLibrary(
            tripLibrary: tripLibrary,
            archive: planArchive
        )

        XCTAssertThrowsError(try library.removePlanAndStopTrackingChildren(id: plan.id))
        XCTAssertEqual(library.plans, [plan])
        XCTAssertTrue(tripLibrary.containsTrip(id: invalidChild.id))
        XCTAssertEqual(tripArchive.load().map(\.id), [validChild.id])
        XCTAssertTrue(push.unwatchedTripIDs.isEmpty)

        planArchive.shouldFailSave = false
        try library.removePlanAndStopTrackingChildren(id: plan.id)
        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertTrue(tripLibrary.trips.isEmpty)
        XCTAssertTrue(tripArchive.load().isEmpty)
        XCTAssertEqual(push.unwatchedTripIDs, [invalidChild.id])
    }

    @MainActor
    private func assertBootPreservesTrips(
        storedValue: Data,
        component: JourneyPlanStorageComponent,
        expectedFailure: JourneyPlanStorageRecoveryIssue.Failure
    ) throws {
        let suiteName = "JourneyPlanBootRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripArchive = TripArchive(defaults: defaults, key: "bootTrips")
        let planArchive = JourneyPlanArchive(defaults: defaults, key: "bootPlans")
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first)
        try tripArchive.saveOrThrow([trip])
        let storedKey = component == .plans ? "bootPlans" : "bootPlans.trackingAttempts"
        defaults.set(storedValue, forKey: storedKey)

        let tripLibrary = TripLibrary(
            trips: nil,
            pushCoordinator: RecordingPushCoordinator(),
            archive: tripArchive,
            automaticRefreshEnabled: false
        )
        let planLibrary = try XCTUnwrap(
            try? JourneyPlanLibrary(
                tripLibrary: tripLibrary,
                archive: planArchive
            )
        )

        XCTAssertEqual(planLibrary.recoveryIssues.map(\.component), [component])
        XCTAssertEqual(planLibrary.recoveryIssues.map(\.failure), [expectedFailure])
        XCTAssertEqual(tripLibrary.trips.map(\.id), [trip.id])
        XCTAssertEqual(defaults.data(forKey: storedKey), storedValue)
    }

    @MainActor
    private func makeRecoveryContext() throws -> RecoveryContext {
        let suiteName = "JourneyPlanRecoveryActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first)
        let tripArchive = TripArchive(defaults: defaults, key: "recoveryTrips")
        try tripArchive.saveOrThrow([trip])
        let tripLibrary = TripLibrary(
            trips: nil,
            pushCoordinator: RecordingPushCoordinator(),
            archive: tripArchive,
            automaticRefreshEnabled: false
        )
        return RecoveryContext(
            suiteName: suiteName,
            defaults: defaults,
            planArchive: JourneyPlanArchive(defaults: defaults, key: "recoveryPlans"),
            tripLibrary: tripLibrary,
            trip: trip,
            planKey: "recoveryPlans",
            journalKey: "recoveryPlans.trackingAttempts"
        )
    }

    private struct RecoveryContext {
        let suiteName: String
        let defaults: UserDefaults
        let planArchive: JourneyPlanArchive
        let tripLibrary: TripLibrary
        let trip: TrainTrip
        let planKey: String
        let journalKey: String
    }
}
