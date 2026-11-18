import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarJourneyFailureRecoveryTests: XCTestCase {
    func testFailedUpdateThenKeepingOriginalTrainRemovesAbandonedReplacement() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let original = try library.track(draft: draft(), resolution: resolution([trips[0]]))

        archive.shouldFailSave = true
        XCTAssertThrowsError(try library.track(draft: draft(revision: "changed"), resolution: resolution([trips[1]])))
        XCTAssertEqual(library.plans, [original])
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)

        archive.shouldFailSave = false
        let retry = try library.track(draft: draft(revision: "corrected"), resolution: resolution([trips[0]]))

        XCTAssertEqual(retry.id, original.id)
        XCTAssertEqual(library.plans, [retry])
        XCTAssertEqual(context.library.trips.map(\.id), [trips[0].id])
        XCTAssertEqual(context.push.unwatchedTripIDs, [trips[1].id])
        XCTAssertTrue(archive.storedTrackingAttempts.isEmpty)
    }

    func testFailedFirstImportReusesPendingIdentityAfterReloadAndNewDraft() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = CalendarRecoveryFailingArchive(
            base: JourneyPlanArchive(defaults: context.defaults, key: "calendarRecoveryPlans")
        )
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let originalDraft = draft()
        archive.shouldFailPlanSave = true

        XCTAssertThrowsError(try library.track(draft: originalDraft, resolution: resolution([trips[0]])))
        let attempts = try archive.loadTrackingAttempts()
        XCTAssertEqual(attempts.first?.id, originalDraft.id)
        XCTAssertEqual(attempts.first?.calendarEventKey, "event-one")
        XCTAssertEqual(context.library.trips.map(\.id), [trips[0].id])

        archive.shouldFailPlanSave = false
        let reloaded = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let newDraft = draft(revision: "edited")
        XCTAssertNotEqual(newDraft.id, originalDraft.id)
        let retry = try reloaded.track(draft: newDraft, resolution: resolution([trips[1]]))

        XCTAssertEqual(retry.id, originalDraft.id)
        XCTAssertEqual(reloaded.plans, [retry])
        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
        XCTAssertEqual(context.push.unwatchedTripIDs, [trips[0].id])
        XCTAssertTrue(try archive.loadTrackingAttempts().isEmpty)
    }

    func testRetryPreservesAbandonedTrainNowUsedByAnotherSavedPlan() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let original = try library.track(draft: draft(), resolution: resolution([trips[0]]))
        archive.shouldFailSave = true
        XCTAssertThrowsError(try library.track(draft: draft(revision: "changed"), resolution: resolution([trips[1]])))
        archive.shouldFailSave = false
        let shared = try library.track(
            draft: JourneyPlanTestFixtures.makeDraft(id: UUID()), resolution: resolution([trips[1]])
        )

        let retry = try library.track(draft: draft(revision: "corrected"), resolution: resolution([trips[0]]))

        XCTAssertEqual(retry.id, original.id)
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)
        try library.removePlanAndStopTrackingChildren(id: retry.id)
        XCTAssertEqual(library.plans, [shared])
        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
    }

    func testRetryPreservesPreExistingTrainFromAbandonedSelection() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[1]])
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        _ = try library.track(draft: draft(), resolution: resolution([trips[0]]))
        archive.shouldFailSave = true
        XCTAssertThrowsError(try library.track(draft: draft(revision: "changed"), resolution: resolution([trips[1]])))
        archive.shouldFailSave = false

        let retry = try library.track(draft: draft(revision: "corrected"), resolution: resolution([trips[0]]))
        try library.removePlanAndStopTrackingChildren(id: retry.id)

        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
        XCTAssertEqual(context.push.unwatchedTripIDs, [trips[0].id])
    }

    func testAnotherCalendarEventCannotReuseOrCleanFirstEventsPendingAttempt() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let firstDraft = draft(eventKey: "first-event")
        archive.shouldFailSave = true
        XCTAssertThrowsError(try library.track(draft: firstDraft, resolution: resolution([trips[0]])))
        archive.shouldFailSave = false

        let otherDraft = draft(eventKey: "other-event")
        let other = try library.track(draft: otherDraft, resolution: resolution([trips[1]]))
        XCTAssertEqual(other.id, otherDraft.id)
        XCTAssertNotEqual(other.id, firstDraft.id)
        XCTAssertEqual(archive.storedTrackingAttempts.map(\.id), [firstDraft.id])
        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set(trips.map(\.id)))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)

        let recovered = try library.track(draft: draft(eventKey: "first-event"), resolution: resolution([trips[1]]))
        XCTAssertEqual(recovered.id, firstDraft.id)
        XCTAssertEqual(Set(library.plans.map(\.id)), [firstDraft.id, other.id])
        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
        XCTAssertEqual(context.push.unwatchedTripIDs, [trips[0].id])
    }

    func testLegacyTrackingAttemptWithoutCalendarKeyDecodesAndRetainsOwnership() throws {
        let tripID = JourneyPlanTestFixtures.makeTrips()[0].id
        let attempt = JourneyPlanTrackingAttempt(
            id: UUID(), insertedChildTripIDs: [tripID],
            pendingInsertionChildTripID: nil, preExistingChildTripIDs: [],
            calendarEventKey: "event-one"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        object.removeValue(forKey: "calendarEventKey")
        let legacy = try JSONDecoder().decode(
            JourneyPlanTrackingAttempt.self, from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(legacy.calendarEventKey)
        XCTAssertEqual(legacy.id, attempt.id)
        XCTAssertEqual(legacy.insertedChildTripIDs, [tripID])
        XCTAssertTrue(legacy.preExistingChildTripIDs.isEmpty)
    }

    private func draft(eventKey: String = "event-one", revision: String = "first") -> JourneyPlanDraft {
        let original = JourneyPlanTestFixtures.makeDraft(id: UUID())
        return JourneyPlanDraft(
            id: original.id, origin: original.origin, destination: original.destination,
            outbound: original.outbound, returnOption: nil,
            calendarSource: CalendarJourneySource(eventKey: eventKey, revision: revision)
        )
    }

    private func resolution(_ trips: [TrainTrip]) -> JourneyPlanResolution {
        JourneyPlanTestFixtures.makeResolution(outboundTrips: trips)
    }
}

@MainActor
private final class CalendarRecoveryFailingArchive: JourneyPlanArchiving {
    enum Failure: Error { case save }
    private let base: JourneyPlanArchive
    var shouldFailPlanSave = false

    init(base: JourneyPlanArchive) { self.base = base }
    func load() throws -> [TrackedJourneyPlan] { try base.load() }
    func save(_ plans: [TrackedJourneyPlan]) throws {
        if shouldFailPlanSave { throw Failure.save }
        try base.save(plans)
    }
    func loadTrackingAttempts() throws -> [JourneyPlanTrackingAttempt] { try base.loadTrackingAttempts() }
    func saveTrackingAttempts(_ attempts: [JourneyPlanTrackingAttempt]) throws { try base.saveTrackingAttempts(attempts) }
}
