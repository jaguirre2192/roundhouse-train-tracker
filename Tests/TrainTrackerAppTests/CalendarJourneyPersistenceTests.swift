import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarJourneyPersistenceTests: XCTestCase {
    func testReimportWithNewDraftIDUpdatesExistingPlanAcrossReload() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let original = try library.track(
            draft: draft(revision: "first"),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        )
        let reloaded = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let edited = try reloaded.track(
            draft: draft(revision: "edited"),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]])
        )
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(reloaded.plans, [edited])
        XCTAssertEqual(edited.calendarSource?.revision, "edited")
        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
        XCTAssertEqual(context.push.unwatchedTripIDs, [trips[0].id])
    }

    func testRepeatedUnchangedImportDoesNotDuplicateJourneyOrTrips() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let resolution = JourneyPlanTestFixtures.makeResolution(outboundTrips: JourneyPlanTestFixtures.makeTrips())
        let original = try library.track(draft: draft(), resolution: resolution)
        let repeated = try library.track(draft: draft(), resolution: resolution)
        XCTAssertEqual(original.id, repeated.id)
        XCTAssertEqual(library.plans, [repeated])
        XCTAssertEqual(Set(context.library.trips.map(\.id)).count, context.library.trips.count)
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)
    }

    func testFailedUpdateKeepsOldPlanAndOldTripThenRetryReplacesIt() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let trips = JourneyPlanTestFixtures.makeTrips()
        let original = try library.track(draft: draft(), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]]))
        archive.shouldFailSave = true
        XCTAssertThrowsError(try library.track(
            draft: draft(revision: "edited"), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]])
        ))
        XCTAssertEqual(library.plans, [original])
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)
        archive.shouldFailSave = false
        let updated = try library.track(
            draft: draft(revision: "edited"), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]])
        )
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(context.library.trips.map(\.id), [trips[1].id])
        XCTAssertTrue(updated.preExistingChildTripIDs.isEmpty)
    }

    func testUpdatePreservesOldTrainUsedByAnotherPlan() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let trips = JourneyPlanTestFixtures.makeTrips()
        let oldResolution = JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        _ = try library.track(draft: draft(), resolution: oldResolution)
        let other = try library.track(draft: JourneyPlanTestFixtures.makeDraft(id: UUID()), resolution: oldResolution)
        let edited = try library.track(draft: draft(revision: "edited"), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]]))
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))
        try library.removePlanAndStopTrackingChildren(id: edited.id)
        XCTAssertEqual(library.plans, [other])
        XCTAssertEqual(context.library.trips.map(\.id), [trips[0].id])
    }

    func testUpdatePreservesIndependentlyTrackedOldTrain() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0]])
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        _ = try library.track(draft: draft(), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]]))
        let edited = try library.track(draft: draft(revision: "edited"), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[1]]))
        try library.removePlanAndStopTrackingChildren(id: edited.id)
        XCTAssertEqual(context.library.trips.map(\.id), [trips[0].id])
    }

    func testSourceRoundTripsAndLegacyPlanWithoutSourceStillDecodes() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let plan = try library.track(draft: draft(), resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: JourneyPlanTestFixtures.makeTrips()))
        let encoded = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(TrackedJourneyPlan.self, from: encoded), plan)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "calendarSource")
        let legacy = try JSONDecoder().decode(TrackedJourneyPlan.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.calendarSource)
        XCTAssertEqual(legacy.id, plan.id)
        XCTAssertEqual(legacy.outbound, plan.outbound)
    }

    private func draft(revision: String = "first") -> JourneyPlanDraft {
        let original = JourneyPlanTestFixtures.makeDraft(id: UUID())
        return JourneyPlanDraft(
            id: original.id, origin: original.origin, destination: original.destination,
            outbound: original.outbound, returnOption: nil,
            calendarSource: CalendarJourneySource(eventKey: "event-hash", revision: revision)
        )
    }
}
