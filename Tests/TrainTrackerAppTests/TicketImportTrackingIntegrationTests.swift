import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class TicketImportTrackingIntegrationTests: XCTestCase {
    func testImportedTicketSurvivesResolveRetrySaveReloadDuplicateImportAndLiveRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TicketImportFlow-\(UUID())")
        let suite = "TicketImportFlow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = JourneySearchStoreFixtures.date("2026-11-14T13:00:00Z")
        let transport = TicketImportFlowHTTPClient()
        let baseURL = try XCTUnwrap(URL(string: "https://ticket-flow.invalid"))
        let client = JourneySearchClient(baseURL: baseURL, client: transport)
        let snapshots = TripSnapshotBackendClient(baseURL: baseURL, client: transport, now: { now })
        let tripArchive = TripArchive(defaults: defaults)
        let push = RecordingPushCoordinator()
        let trips = TripLibrary(trips: [], backendSnapshots: snapshots,
                                pushCoordinator: push,
                                archive: tripArchive, automaticRefreshEnabled: false, now: { now })
        let planArchive = JourneyPlanArchive(defaults: defaults)
        let plans = try JourneyPlanLibrary(tripLibrary: trips, archive: planArchive, now: { now })
        let vault = LocalJourneyTicketStore(directory: directory)
        let payload = Data("SNCF TGV 6611\nParis Gare de Lyon to Lyon Part Dieu\nDeparture: 2026-11-14T14:00:00Z\nCoach 5 Seat 14A".utf8)
        let imported = try await vault.importPayload(payload, kind: .text)
        let intake = JourneyIntakeModel(vault: vault)
        intake.review(ticket: imported.ticket)
        guard case let .review(request) = intake.presentation else { return XCTFail("Expected the durable ticket review") }
        let review = SmartJourneyReviewStore(suggestion: request.suggestion, client: client, planTracker: plans,
                                            plans: { plans.plans }, now: { now })
        review.start()
        await waitUntil { review.search.phase == .reviewing || review.search.phase == .showingOutbound }
        XCTAssertEqual(review.search.phase, .reviewing, "The ticket's explicit instant must match the correct train")
        let searches = await transport.searchRequests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(searches.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["time"] as? String, "2026-11-14T15:00:00+01:00")
        XCTAssertEqual(body["originId"] as? String, "eu:transitous:paris-lyon")
        XCTAssertEqual(body["destinationId"] as? String, "eu:transitous:lyon")
        XCTAssertTrue(plans.plans.isEmpty, "Finding a match must not save before confirmation")
        guard review.search.phase == .reviewing else { review.cancelMatching(); return }

        review.search.resolveSelection()
        await waitUntil { review.search.phase == .failed(.resolutionUnavailable) }
        XCTAssertTrue(plans.plans.isEmpty)
        XCTAssertTrue(vault.ticket(id: imported.ticket.id)?.isDraft == true)
        review.search.resolveSelection()
        await waitUntil { review.search.resolvedPlan != nil }
        XCTAssertTrue(review.search.trackResolvedPlan())
        let saved = try XCTUnwrap(plans.plans.first)
        XCTAssertEqual(saved.outbound.departure, JourneySearchStoreFixtures.date("2026-11-14T14:00:00Z"))
        XCTAssertEqual(saved.outbound.selectedSegments?.first?.from.id, TicketImportFlowHTTPClient.origin.id)
        XCTAssertEqual(saved.outbound.childTripIDs, [TicketImportFlowHTTPClient.tripID])
        intake.completeReview(request, plan: saved, created: true, navigation: AppNavigationModel())

        let reloadedVault = LocalJourneyTicketStore(directory: directory)
        let reloadedTrips = TripLibrary(backendSnapshots: snapshots,
                                       pushCoordinator: push, archive: tripArchive, automaticRefreshEnabled: true, now: { now })
        let reloadedPlans = try JourneyPlanLibrary(tripLibrary: reloadedTrips, archive: planArchive, now: { now })
        XCTAssertEqual(reloadedPlans.plans.map(\.id), [saved.id])
        XCTAssertEqual(reloadedTrips.trips.map(\.id), [TicketImportFlowHTTPClient.tripID])
        XCTAssertEqual(reloadedVault.tickets(forPlan: saved.id).map(\.id), [imported.ticket.id])
        XCTAssertEqual(try reloadedVault.payload(id: imported.ticket.id), payload)

        let repeated = try await reloadedVault.importPayload(payload, kind: .text)
        XCTAssertFalse(repeated.isNew)
        XCTAssertEqual(repeated.ticket.id, imported.ticket.id)
        let reopened = SmartJourneyReviewStore(suggestion: repeated.ticket.suggestion, client: client,
            planTracker: reloadedPlans, plans: { reloadedPlans.plans }, linkedPlanIDs: repeated.ticket.linkedPlanIDs, now: { now })
        reopened.start()
        XCTAssertEqual(reopened.stage, .existing(planID: saved.id))
        XCTAssertEqual(reloadedPlans.plans.count, 1)
        XCTAssertEqual(reloadedTrips.trips.count, 1)

        await reloadedTrips.refreshTrackedTrip(id: TicketImportFlowHTTPClient.tripID)
        let refreshed = try XCTUnwrap(reloadedTrips.trip(id: TicketImportFlowHTTPClient.tripID))
        XCTAssertEqual(refreshed.stopTimes.first?.displayPlatform, "9")
        XCTAssertEqual(refreshed.stopTimes.first?.delayMinutes, 5)
        XCTAssertEqual(reloadedTrips.lastSuccessfulCheck(for: refreshed.id), now)
        XCTAssertEqual(tripArchive.load().first?.stopTimes.first?.displayPlatform, "9")

        // Another artifact for the same trip keeps its printed product. A saved provider
        // label without that product may decline the early shortcut; fingerprint review
        // must still attach this ticket to the existing plan without another tracked train.
        let alternate = try await reloadedVault.importPayload(payload + Data("\nSecond copy".utf8), kind: .text)
        XCTAssertEqual(alternate.ticket.suggestion.trainNumberGuess, "TGV 6611")
        let alternateIntake = JourneyIntakeModel(vault: reloadedVault)
        alternateIntake.review(ticket: alternate.ticket)
        guard case let .review(alternateRequest) = alternateIntake.presentation else { return XCTFail("Expected second ticket review") }
        let alternateReview = SmartJourneyReviewStore(suggestion: alternateRequest.suggestion, client: client,
            planTracker: reloadedPlans, plans: { reloadedPlans.plans }, now: { now })
        defer { alternateReview.cancelMatching() }
        XCTAssertNil(alternateReview.existingPlan())
        alternateReview.start()
        await waitUntil { alternateReview.search.phase == .reviewing }
        let selected = try XCTUnwrap(alternateReview.search.selectedOutbound)
        let existing = try XCTUnwrap(alternateReview.existingPlan(forSelected: selected))
        XCTAssertEqual(existing.id, saved.id)
        alternateIntake.completeReview(alternateRequest, plan: existing, created: false, navigation: AppNavigationModel())
        XCTAssertEqual(reloadedPlans.plans.count, 1)
        XCTAssertEqual(reloadedTrips.trips.count, 1)
        XCTAssertEqual(Set(reloadedVault.tickets(forPlan: saved.id).map(\.id)), [imported.ticket.id, alternate.ticket.id])
    }

    func testComplexTicketKeepsRemainingJourneysReviewableAfterLinkAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ComplexTicketFlow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalJourneyTicketStore(directory: directory)
        let payload = Data(TicketImportReliabilityTests.connectedRoundTrip.utf8)
        let imported = try await vault.importPayload(payload, kind: .text)
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let plans = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let saved = try plans.track(draft: JourneyPlanTestFixtures.makeDraft(),
                                    resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: JourneyPlanTestFixtures.makeTrips()))
        try vault.saveDraft(imported.ticket.suggestion.revised(
            origin: "London St Pancras", destination: "Lyon Part Dieu", trainNumber: "9032",
            departureWallClock: TicketWallClock(year: 2026, month: 11, day: 14, hour: 10, minute: 0)
        ))
        let intake = JourneyIntakeModel(vault: vault)
        let request = JourneyIntakeModel.ReviewRequest(suggestion: imported.ticket.suggestion, ticketID: imported.ticket.id, vault: vault)
        intake.completeReview(request, plan: saved, created: true, navigation: AppNavigationModel())
        XCTAssertNil(intake.errorMessage)

        let reloaded = LocalJourneyTicketStore(directory: directory)
        let repeated = try await reloaded.importPayload(payload, kind: .text)
        XCTAssertFalse(repeated.isNew)
        XCTAssertTrue(repeated.ticket.isDraft, "Saving one chosen journey must leave the other journeys unfinished")
        XCTAssertEqual(repeated.ticket.linkedPlanIDs, [saved.id])
        XCTAssertNil(repeated.ticket.suggestion.originGuess)
        XCTAssertNil(repeated.ticket.suggestion.destinationGuess)
        XCTAssertNil(repeated.ticket.suggestion.departureWallClock)
        let review = SmartJourneyReviewStore(suggestion: repeated.ticket.suggestion, client: ScriptedJourneySearchClient(),
            planTracker: plans, plans: { plans.plans }, linkedPlanIDs: repeated.ticket.linkedPlanIDs)
        review.start()
        XCTAssertEqual(review.stage, .details(.multipleJourneys), "A linked first journey must not hide the rest of the booking")
        try reloaded.keepWithoutJourney(id: imported.ticket.id)
        XCTAssertFalse(try XCTUnwrap(reloaded.ticket(id: imported.ticket.id)).isDraft, "The person can explicitly finish reviewing the ticket")
        XCTAssertEqual(try reloaded.payload(id: imported.ticket.id), payload)
    }

    func testRepeatedComplexTicketLinkPreservesTheNextReviewedJourney() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ComplexTicketRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalJourneyTicketStore(directory: directory)
        let imported = try await vault.importPayload(Data(TicketImportReliabilityTests.connectedRoundTrip.utf8), kind: .text)
        let planID = UUID()
        try vault.link(id: imported.ticket.id, planID: planID)
        let next = try XCTUnwrap(vault.ticket(id: imported.ticket.id)).suggestion.revised(
            origin: "Lyon Part Dieu", destination: "London St Pancras", trainNumber: "9033",
            departureWallClock: TicketWallClock(year: 2026, month: 11, day: 21, hour: 10, minute: 0)
        )
        try vault.saveDraft(next)
        XCTAssertFalse(try vault.link(id: imported.ticket.id, planID: planID))
        let reloaded = LocalJourneyTicketStore(directory: directory)
        XCTAssertEqual(reloaded.ticket(id: imported.ticket.id)?.suggestion, next)
        XCTAssertTrue(reloaded.ticket(id: imported.ticket.id)?.isDraft == true)
    }
}
