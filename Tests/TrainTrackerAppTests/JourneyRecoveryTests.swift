import XCTest
import TrainTrackerCore
@testable import TrainTracker

@MainActor
final class JourneyRecoveryTests: XCTestCase {
    private typealias Fixture = JourneyRecoveryPreview

    private func request() throws -> JourneyRecoveryRequest {
        let stage = JourneyPlanStage(plan: Fixture.original, trips: Fixture.seed.trips, referenceDate: Fixture.date)
        XCTAssertEqual(stage.connection?.estimatedMinutes, 3)
        return try XCTUnwrap(JourneyRecoveryRequest.make(stage: stage, trips: Fixture.seed.trips, at: Fixture.date))
    }

    private func page(_ options: [JourneyOption], cursor: String? = nil, expires: Int = 10) -> JourneySearchPage {
        .init(generatedAt: Fixture.date, expiresAt: Fixture.time(expires), options: options,
              previousCursor: nil, nextCursor: cursor, warnings: [], attributions: [])
    }

    func testMatchesRidersChangeAndDestinationAndUsesDelayedArrival() throws {
        let request = try request()
        let criteria = request.criteria(at: Fixture.date)
        XCTAssertEqual(criteria.originID, Fixture.brussels.id)
        XCTAssertEqual(criteria.destinationID, Fixture.amsterdam.id)
        XCTAssertEqual(criteria.requestedTime, Fixture.time(25))
        XCTAssertEqual(request.searchRequest(at: Fixture.date).originPlace, Fixture.brussels)
        XCTAssertEqual(request.criteria(at: Fixture.time(32)).requestedTime, Fixture.time(32))
        XCTAssertNil(JourneyRecoveryRequest.make(stage: JourneyPlanStage(plan: Fixture.original, trips: Fixture.seed.trips,
            referenceDate: Fixture.time(1_000)), trips: Fixture.seed.trips, at: Fixture.time(1_000)))
    }

    func testSelectsNextReachableTrainExcludingOriginalExpiredAndCancelledOptions() throws {
        let request = try request()
        let early = Fixture.train("Earlier", start: 19, end: 100)
        let later = Fixture.train("Later", start: 110, end: 235)
        let cancelled = Fixture.train("Cancelled", start: 22, end: 125)
        let options = [Fixture.option(later), Fixture.option(Fixture.booked), Fixture.option(early),
                       Fixture.option(cancelled, cancelled: true), Fixture.option(Fixture.fallback)]
        let selected = try XCTUnwrap(JourneyRecoveryOption.next(in: page(options), request: request, at: Fixture.date))
        XCTAssertEqual(selected.firstTrain.tripID, Fixture.fallback.id)
        XCTAssertFalse(selected.estimated)
        XCTAssertNil(JourneyRecoveryOption.next(in: page(options, expires: -1), request: request, at: Fixture.date))
        XCTAssertNil(JourneyRecoveryOption.next(in: page([Fixture.option(early)]), request: request, at: Fixture.date))
    }

    func testSavedWalkCountsOnceAndUnknownWalkingTimeFallsBackToManualSearch() throws {
        let inbound = Fixture.incoming, onward = Fixture.booked
        let legs = try XCTUnwrap(Fixture.original.outbound.selectedSegments)
        func make(_ duration: TimeInterval?) -> JourneyRecoveryRequest? {
            let walk = JourneyPlanSegment(id: "concourse", kind: .walk, from: Fixture.brussels, to: Fixture.brussels, duration: duration)
            let itinerary = [legs[0], walk, legs[1]]
            let plan = TrackedJourneyPlan(id: Fixture.original.id, createdAt: Fixture.time(-100),
                origin: Fixture.paris, destination: Fixture.amsterdam,
                outbound: .init(fingerprint: "walk", departure: Fixture.time(-75), arrival: Fixture.time(132),
                    childTripIDs: [inbound.id, onward.id], selectedSegments: itinerary),
                returnDirection: nil, preExistingChildTripIDs: [])
            let stage = JourneyPlanStage(plan: plan, trips: [inbound, onward], referenceDate: Fixture.date)
            return JourneyRecoveryRequest.make(stage: stage, trips: [inbound, onward], at: Fixture.date)
        }
        XCTAssertEqual(make(600)?.readyAt, Fixture.time(33))
        XCTAssertNil(make(nil))
    }

    func testCancelledOnwardTrainGetsBackupWhilePassengerIsStillOnIncomingTrain() throws {
        let cancelled = Fixture.train(Fixture.booked.product, start: 23, end: 132, cancelled: true)
        let trips = [Fixture.incoming, cancelled]
        let stage = JourneyPlanStage(plan: Fixture.original, trips: trips, referenceDate: Fixture.date)
        let request = try XCTUnwrap(JourneyRecoveryRequest.make(stage: stage, trips: trips, at: Fixture.date))
        XCTAssertEqual(request.original.resolvedTripID, Fixture.booked.id)
        XCTAssertEqual(request.readyAt, Fixture.time(25))
    }

    func testResolutionCannotFollowACancelledNowUnreachableOrDifferentItinerary() throws {
        let request = try request()
        let candidate = try XCTUnwrap(JourneyRecoveryOption.next(in: page([Fixture.option(Fixture.fallback)]),
            request: request, at: Fixture.date))
        for trip in [Fixture.train(Fixture.fallback.product, start: 19, end: 125),
                     Fixture.train(Fixture.fallback.product, start: 50, end: 150),
                     Fixture.train(Fixture.fallback.product, start: 88, end: 212, cancelled: true),
                     Fixture.booked] {
            XCTAssertFalse(candidate.stillUsable(Fixture.resolution(for: trip), request: request, at: Fixture.date))
        }
        XCTAssertTrue(candidate.stillUsable(Fixture.resolution(for: Fixture.fallback), request: request, at: Fixture.date))
        XCTAssertFalse(candidate.stillUsable(Fixture.resolution(for: Fixture.fallback), request: request, at: Fixture.time(12)))
    }

    func testFollowingTwiceKeepsOriginalBookingAndRemainsAWatchUntilImported() async throws {
        let request = try request()
        let library = TripLibrary(trips: Fixture.seed.trips, pushCoordinator: JourneyPlanPreviewPushCoordinator(),
                                  archive: nil, automaticRefreshEnabled: false)
        let plans = try JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: [Fixture.original]))
        let store = JourneyRecoveryStore(client: Fixture())
        await store.load(request, at: Fixture.date)
        guard case .candidate(let candidate) = store.result else { return XCTFail("Expected later departure") }
        for _ in 0..<2 {
            await store.follow(candidate, request: request, planID: Fixture.originalID, in: plans) { Fixture.date }
        }
        XCTAssertEqual(plans.plans.count, 2)
        XCTAssertEqual(plans.plans.first(where: { $0.id == Fixture.originalID }), Fixture.original)
        XCTAssertTrue(library.isWatchingOnly(Fixture.fallback.id))
        let backupID = JourneyRecoveryStore.planID(for: candidate, basedOn: Fixture.originalID)
        let backup = try XCTUnwrap(plans.plans.first { $0.id == backupID })
        XCTAssertEqual(backup.outbound.selectedSegments?.first?.from, Fixture.brussels)
        XCTAssertEqual(backup.outbound.selectedSegments?.first?.to, Fixture.amsterdam)
        let actualBooking = JourneyPlanDraft(id: UUID(), origin: Fixture.brussels, destination: Fixture.amsterdam,
                                            outbound: candidate.option, returnOption: nil)
        try plans.track(draft: actualBooking, resolution: Fixture.resolution(for: Fixture.fallback))
        XCTAssertFalse(library.isWatchingOnly(Fixture.fallback.id))
        await store.follow(candidate, request: request, planID: Fixture.originalID, in: plans) { Fixture.date }
        XCTAssertFalse(library.isWatchingOnly(Fixture.fallback.id), "A shared train that is ridden stays ridden")
    }

    func testFailedImportKeepsChildrenWatchingAndOnlyMatchingCommittedJournalCanPromoteThem() throws {
        let library = TripLibrary(trips: [], pushCoordinator: JourneyPlanPreviewPushCoordinator(),
                                  archive: nil, automaticRefreshEnabled: false)
        let archive = RecordingJourneyPlanArchive()
        let plans = try JourneyPlanLibrary(tripLibrary: library, archive: archive)
        let outbound = Fixture.option(Fixture.fallback)
        let draft = JourneyPlanDraft(id: UUID(), origin: Fixture.brussels, destination: Fixture.amsterdam,
                                    outbound: outbound, returnOption: nil)
        archive.shouldFailSave = true
        XCTAssertThrowsError(try plans.track(draft: draft, resolution: Fixture.resolution(for: Fixture.fallback)))
        XCTAssertTrue(library.isWatchingOnly(Fixture.fallback.id))
        XCTAssertTrue(plans.plans.isEmpty)
        let journalBeforeCommit = archive.storedTrackingAttempts
        _ = try JourneyPlanLibrary(tripLibrary: library, archive: archive)
        XCTAssertTrue(library.isWatchingOnly(Fixture.fallback.id))
        archive.shouldFailSave = false
        try plans.track(draft: draft, resolution: Fixture.resolution(for: Fixture.fallback))
        XCTAssertFalse(library.isWatchingOnly(Fixture.fallback.id))
        // Simulate a kill after the plan file was replaced and before riding intent was committed.
        let restarted = TripLibrary(trips: [], pushCoordinator: JourneyPlanPreviewPushCoordinator(),
                                   archive: nil, automaticRefreshEnabled: false)
        try restarted.storeTrackedTrip(Fixture.fallback, watchingOnly: true)
        archive.storedTrackingAttempts = journalBeforeCommit
        _ = try JourneyPlanLibrary(tripLibrary: restarted, archive: archive)
        XCTAssertFalse(restarted.isWatchingOnly(Fixture.fallback.id))
        XCTAssertTrue(archive.storedTrackingAttempts.isEmpty)
    }

    func testPaginationSkipsUnusableResultsAndDoesNotKeepFetchingDuringOrdinaryRefreshes() async throws {
        let request = try request()
        let client = ScriptedJourneySearchClient(pages: [
            .success(page([Fixture.option(Fixture.booked)], cursor: "later")),
            .success(page([Fixture.option(Fixture.fallback)]))
        ])
        let store = JourneyRecoveryStore(client: client)
        await store.load(request, at: Fixture.date)
        await store.load(request, at: Fixture.time(2))
        let queries = await client.journeyRequests
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries.last?.cursor, "later")
        guard case .candidate(let candidate) = store.result else { return XCTFail("Expected second page") }
        XCTAssertEqual(candidate.firstTrain.tripID, Fixture.fallback.id)
    }
}
