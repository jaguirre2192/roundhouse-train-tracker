import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanLibraryTests: XCTestCase {
    @MainActor
    func testTrackRecordsChildrenThatExistedBeforeThePlan() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0]])
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: archive,
            now: { Date(timeIntervalSince1970: 1_721_814_000) }
        )

        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        XCTAssertEqual(plan.preExistingChildTripIDs, [trips[0].id])
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
    }

    @MainActor
    func testRetryingSameDraftReplacesPlanInsteadOfDuplicatingIt() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let draft = JourneyPlanTestFixtures.makeDraft()

        _ = try library.track(
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        )
        let replacement = try library.track(
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        XCTAssertEqual(library.plans, [replacement])
        XCTAssertEqual(replacement.id, draft.id)
        XCTAssertTrue(replacement.preExistingChildTripIDs.isEmpty)
    }

    @MainActor
    func testPartialResolutionPersistsOnlyAvailableTrips() throws {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)

        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [trip],
                outboundFailureCount: 1
            )
        )

        XCTAssertEqual(plan.outbound.childTripIDs, [trip.id])
        XCTAssertEqual(context.library.trips.map(\.id), [trip.id])
        XCTAssertEqual(archive.storedPlans, [plan])
    }

    @MainActor
    func testRoundTripPersistsBothDirectionsAndDeduplicatesSharedChild() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)

        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(includesReturn: true),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [trips[0], trips[0]],
                returnTrips: [trips[1]]
            )
        )

        XCTAssertEqual(plan.outbound.childTripIDs, [trips[0].id])
        XCTAssertEqual(plan.returnDirection?.fingerprint, "return-fingerprint")
        XCTAssertEqual(plan.returnDirection?.childTripIDs, [trips[1].id])
        XCTAssertEqual(Set(context.push.watchedTripIDs), Set(trips.map(\.id)))
    }

    @MainActor
    func testTrackKeepsTwoLegOutboundInJourneyOrderWithFirstLegActive() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )

        _ = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        XCTAssertEqual(context.library.trips.map(\.id), trips.map(\.id))
        XCTAssertEqual(context.library.activeTrip?.id, trips[0].id)
    }

    @MainActor
    func testTrackKeepsOutboundBeforeLaterReturnWithOutboundActive() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )

        _ = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(includesReturn: true),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [trips[0]],
                returnTrips: [trips[1]]
            )
        )

        XCTAssertEqual(context.library.trips.map(\.id), trips.map(\.id))
        XCTAssertEqual(context.library.activeTrip?.id, trips[0].id)
    }

    @MainActor
    func testPlanSaveFailureKeepsChildrenAndRetryPreservesOwnership() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        archive.shouldFailSave = true
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let draft = JourneyPlanTestFixtures.makeDraft()
        let resolution = JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)

        XCTAssertThrowsError(try library.track(draft: draft, resolution: resolution))
        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))

        archive.shouldFailSave = false
        let plan = try library.track(draft: draft, resolution: resolution)
        XCTAssertTrue(plan.preExistingChildTripIDs.isEmpty)
        XCTAssertEqual(library.plans, [plan])
    }

    @MainActor
    func testChildSaveFailurePreventsGroupingAndRetryPreservesOwnership() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let invalidSecond = JourneyPlanTestFixtures.replacingCoordinate(in: trips[1], latitude: .nan)
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let draft = JourneyPlanTestFixtures.makeDraft()

        XCTAssertThrowsError(try library.track(
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0], invalidSecond])
        ))
        XCTAssertTrue(archive.storedPlans.isEmpty)
        XCTAssertEqual(context.library.trips.map(\.id), [trips[0].id])

        let plan = try library.track(
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )
        XCTAssertTrue(plan.preExistingChildTripIDs.isEmpty)
        XCTAssertEqual(Set(plan.outbound.childTripIDs), Set(trips.map(\.id)))
    }

    @MainActor
    func testRetryAfterLibraryRecreationPreservesOwnershipFromPartialAttempt() throws {
        let suiteName = "JourneyPlanLibraryRetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripArchive = TripArchive(defaults: defaults, key: "retryTrips")
        let planArchive = JourneyPlanArchive(defaults: defaults, key: "retryPlans")
        let trips = JourneyPlanTestFixtures.makeTrips()
        let invalidSecond = JourneyPlanTestFixtures.replacingCoordinate(in: trips[1], latitude: .nan)
        let draft = JourneyPlanTestFixtures.makeDraft()

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
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0], invalidSecond])
        ))
        XCTAssertEqual(firstTripLibrary.trips.map(\.id), [trips[0].id])

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
        let plan = try recreatedPlanLibrary.track(
            draft: draft,
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        XCTAssertTrue(plan.preExistingChildTripIDs.isEmpty)
        try recreatedPlanLibrary.removePlanAndStopTrackingChildren(id: plan.id)
        XCTAssertTrue(recreatedTripLibrary.trips.isEmpty)
    }

    @MainActor
    func testPlanGroupingPersistsOnlyAfterAllChildrenAreStored() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        archive.onSave = { _ in
            XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)

        _ = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )
    }

    @MainActor
    func testRemovePlanDeletesOnlyGrouping() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        try library.removePlan(id: plan.id)

        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)
    }

    @MainActor
    func testDestructiveRemovalFailurePreservesGroupingAndChildrenForRetry() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )
        archive.shouldFailSave = true

        XCTAssertThrowsError(try library.removePlanAndStopTrackingChildren(id: plan.id))
        XCTAssertEqual(library.plans, [plan])
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)

        archive.shouldFailSave = false
        try library.removePlanAndStopTrackingChildren(id: plan.id)
        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertTrue(context.library.trips.isEmpty)
    }

    @MainActor
    func testChildRemovalPersistenceFailureKeepsRecoverableGroupingAndChildren() throws {
        let child = JourneyPlanTestFixtures.makeTrips()[0]
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
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [child])
        )
        let invalid = JourneyPlanTestFixtures.replacingCoordinate(
            in: JourneyPlanTestFixtures.makeTrips()[1],
            latitude: .nan
        )
        let suiteName = "JourneyPlanRemovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let removalPush = RecordingPushCoordinator()
        let removalTripLibrary = TripLibrary(
            trips: [child, invalid],
            pushCoordinator: removalPush,
            archive: TripArchive(defaults: defaults),
            automaticRefreshEnabled: false
        )
        let removalArchive = RecordingJourneyPlanArchive(plans: [plan])
        let removalLibrary = try JourneyPlanLibrary(
            tripLibrary: removalTripLibrary,
            archive: removalArchive
        )

        XCTAssertThrowsError(try removalLibrary.removePlanAndStopTrackingChildren(id: plan.id))
        XCTAssertEqual(removalLibrary.plans, [plan])
        XCTAssertTrue(removalTripLibrary.containsTrip(id: child.id))
        XCTAssertTrue(removalTripLibrary.containsTrip(id: invalid.id))
        XCTAssertTrue(removalPush.unwatchedTripIDs.isEmpty)

        removalTripLibrary.removeTrip(id: invalid.id)
        try removalLibrary.removePlanAndStopTrackingChildren(id: plan.id)
        XCTAssertTrue(removalLibrary.plans.isEmpty)
        XCTAssertTrue(removalTripLibrary.trips.isEmpty)
    }

    @MainActor
    func testRemovalPreviewPreservesSharedChildrenAndRemovesUniqueChildren() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        let first = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            ),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )
        _ = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            ),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        )

        let preview = library.removalPreview(for: first.id)
        XCTAssertEqual(preview.removableChildTripIDs, [trips[1].id])
        XCTAssertEqual(preview.preservedChildTripIDs, [trips[0].id])
        XCTAssertEqual(preview.sharedChildTripIDs, [trips[0].id])
        XCTAssertTrue(preview.preExistingChildTripIDs.isEmpty)

        try library.removePlanAndStopTrackingChildren(id: first.id)
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))
        XCTAssertFalse(context.library.containsTrip(id: trips[1].id))
    }

    @MainActor
    func testRemovalPreviewPreservesPreExistingChildren() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0]])
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        let plan = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
        )

        let preview = library.removalPreview(for: plan.id)
        XCTAssertEqual(preview.removableChildTripIDs, [trips[1].id])
        XCTAssertEqual(preview.preservedChildTripIDs, [trips[0].id])
        XCTAssertTrue(preview.sharedChildTripIDs.isEmpty)
        XCTAssertEqual(preview.preExistingChildTripIDs, [trips[0].id])

        try library.removePlanAndStopTrackingChildren(id: plan.id)
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))
        XCTAssertFalse(context.library.containsTrip(id: trips[1].id))
    }

    @MainActor
    func testSharedJourneyOwnedChildIsRemovedAfterOwnersAreDeletedFirstThenSecond() throws {
        try assertSharedJourneyOwnedChildIsRemoved(removalOrder: [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ])
    }

    @MainActor
    func testSharedJourneyOwnedChildIsRemovedAfterOwnersAreDeletedSecondThenFirst() throws {
        try assertSharedJourneyOwnedChildIsRemoved(removalOrder: [
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        ])
    }

    @MainActor
    private func assertSharedJourneyOwnedChildIsRemoved(removalOrder: [UUID]) throws {
        let child = JourneyPlanTestFixtures.makeTrips()[0]
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        for id in removalOrder.sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = try library.track(
                draft: JourneyPlanTestFixtures.makeDraft(id: id),
                resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [child])
            )
        }

        try library.removePlanAndStopTrackingChildren(id: removalOrder[0])
        XCTAssertTrue(context.library.containsTrip(id: child.id))
        try library.removePlanAndStopTrackingChildren(id: removalOrder[1])

        XCTAssertFalse(context.library.containsTrip(id: child.id))
    }
}
