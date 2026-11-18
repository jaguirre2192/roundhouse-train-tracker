import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyIntakeModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appending(path: "JourneyIntakeModelTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testUndoRemovesOnlyTheNewJourneyItsNewTrainsAndLinkWhilePreservingTicketAndPreexistingTrain() async throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let preexisting = trips[1]
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [preexisting])
        defer { context.cleanup() }
        let planLibrary = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let navigation = AppNavigationModel()

        let ticket = try await vault.importPayload(Data("Eurostar 9032 Paris to Amsterdam".utf8), kind: .text).ticket
        intake.review(ticket: ticket)
        guard case let .review(request) = intake.presentation else { return XCTFail("Expected review") }
        let plan = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0], preexisting])
        )

        intake.completeReview(request, plan: plan, created: true, navigation: navigation)
        XCTAssertNil(intake.presentation)
        XCTAssertEqual(vault.ticket(id: ticket.id)?.linkedPlanIDs, [plan.id])
        XCTAssertEqual(intake.undo?.removesPlanID, plan.id)
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))

        intake.performUndo(planLibrary: planLibrary)
        XCTAssertNil(intake.undo)
        XCTAssertTrue(planLibrary.plans.isEmpty)
        XCTAssertFalse(context.library.containsTrip(id: trips[0].id), "The train this journey added stops tracking")
        XCTAssertTrue(context.library.containsTrip(id: preexisting.id), "A train tracked before the add is kept")
        XCTAssertEqual(try vault.payload(id: ticket.id), Data("Eurostar 9032 Paris to Amsterdam".utf8), "The original ticket is kept")
        XCTAssertTrue(vault.ticket(id: ticket.id)?.linkedPlanIDs.isEmpty == true)
        XCTAssertTrue(vault.ticket(id: ticket.id)?.isDraft == true, "The ticket returns to Unfinished for another try")
    }

    func testUndoAfterRemoveGroupRestoresTheGroupInPlaceAndKeepsTrains() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let planLibrary = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())
        let intake = JourneyIntakeModel(vault: LocalJourneyTicketStore(directory: directory))
        let plan = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        )
        let controller = JourneyPlanRemovalController(planID: plan.id, library: planLibrary)

        XCTAssertTrue(controller.removeGrouping())
        let removed = try XCTUnwrap(controller.removedGroup)
        XCTAssertEqual(removed.plan, plan)
        intake.offerUndo(restoring: removed)
        XCTAssertTrue(planLibrary.plans.isEmpty)
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id), "Remove Group keeps the train")

        intake.performUndo(planLibrary: planLibrary)

        XCTAssertNil(intake.undo)
        XCTAssertEqual(planLibrary.plans, [plan])
        XCTAssertTrue(context.library.containsTrip(id: trips[0].id))
    }

    func testUpdatingAnExistingJourneyOffersNoPlanRemoval() async throws {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let calendarReview = TicketRouteSuggestion(sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Amsterdam")
        intake.review(suggestion: calendarReview)
        XCTAssertEqual(vault.reviews.map(\.id), [calendarReview.id], "An unfinished Calendar review is saved")
        guard case let .review(request) = intake.presentation else { return XCTFail("Expected review") }
        let plan = TrackedJourneyPlan(
            id: UUID(), createdAt: .now, origin: JourneySearchStoreFixtures.paris, destination: JourneySearchStoreFixtures.amsterdam,
            outbound: JourneyPlanDirection(fingerprint: "f", departure: .now, arrival: .now, childTripIDs: []),
            returnDirection: nil, preExistingChildTripIDs: []
        )
        intake.completeReview(request, plan: plan, created: false, navigation: AppNavigationModel())
        XCTAssertNil(intake.undo)
        XCTAssertTrue(vault.reviews.isEmpty)
    }

    func testCalendarEventKeepsOneDraftAndEditedDetailsReplaceIt() {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let source = CalendarJourneySource(eventKey: "event", revision: "r1")
        let first = TicketRouteSuggestion(sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Lyon", calendarSource: source)
        let draftID = intake.reviewRequest(for: first).suggestion.id

        let againUnedited = TicketRouteSuggestion(sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Lyon", calendarSource: source)
        XCTAssertEqual(intake.reviewRequest(for: againUnedited).suggestion.id, draftID)
        let edited = TicketRouteSuggestion(sourceDescription: "Travel", originGuess: "Paris Gare de Lyon", destinationGuess: "Lyon", calendarSource: source)
        let request = intake.reviewRequest(for: edited, isEdited: true)
        XCTAssertEqual(request.suggestion.id, draftID)
        XCTAssertEqual(request.suggestion.originGuess, "Paris Gare de Lyon")
        XCTAssertEqual(vault.reviews.count, 1)
        XCTAssertEqual(vault.reviews.first?.originGuess, "Paris Gare de Lyon")
    }

    func testLocalModalBlocksRootPresentationUntilItCloses() async throws {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let ticket = try await vault.importPayload(Data("Amtrak train 1 Chicago to Denver".utf8), kind: .text).ticket
        intake.beginLocalPresentation()
        intake.sharedTicketSaved(ticket)
        XCTAssertNil(intake.presentation)
        intake.presentAddJourney()
        XCTAssertNil(intake.presentation)
        intake.endLocalPresentation()
        guard case let .review(request) = intake.presentation else { return XCTFail("Expected queued review") }
        XCTAssertEqual(request.ticketID, ticket.id)
    }

    func testScreenOwnedSheetReportsErrorsLocallyAndReleasesQueuedReviews() async throws {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let ticket = try await vault.importPayload(Data("Amtrak train 3 Chicago to Denver".utf8), kind: .text).ticket
        intake.beginLocalPresentation()
        XCTAssertTrue(intake.hasLocalPresentation, "Root alerts wait while a screen-owned sheet is up")
        intake.sharedTicketSaved(ticket)
        intake.review(ticket: ticket)
        XCTAssertNil(intake.presentation, "Nothing replaces the sheet a journey or train screen owns")
        intake.endLocalPresentation()
        XCTAssertFalse(intake.hasLocalPresentation)
        guard case let .review(request) = intake.presentation else { return XCTFail("Queued review presents once") }
        XCTAssertEqual(request.ticketID, ticket.id)
        intake.dismissPresentation()
        XCTAssertNil(intake.presentation, "The same ticket is not queued twice")
    }

    func testRepeatedIdenticalErrorsAreReportedOnce() {
        let intake = JourneyIntakeModel(vault: LocalJourneyTicketStore(directory: directory))
        intake.report("Storage full")
        intake.dismissError()
        intake.report("Storage full")
        XCTAssertEqual(intake.errorMessage, "Storage full")
        intake.report("Storage full")
        XCTAssertEqual(intake.errorMessage, "Storage full")
    }

    func testDraftEditsAreCoalescedAndFlushedOnClose() async throws {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let ticket = try await vault.importPayload(Data("Amtrak train 1 Chicago to Denver".utf8), kind: .text).ticket
        intake.review(ticket: ticket)
        intake.saveDraft(ticket.suggestion.revised(origin: "Chicago Union"))
        intake.saveDraft(ticket.suggestion.revised(origin: "Chicago Union Station"))
        XCTAssertEqual(vault.ticket(id: ticket.id)?.suggestion.originGuess, "Chicago", "Not written on every keystroke")
        intake.dismissPresentation()
        XCTAssertEqual(vault.ticket(id: ticket.id)?.suggestion.originGuess, "Chicago Union Station")
    }

    func testSharedImportsQueueBehindCurrentPresentationAndExplicitAttachIsUndoable() async throws {
        let vault = LocalJourneyTicketStore(directory: directory)
        let intake = JourneyIntakeModel(vault: vault)
        let first = try await vault.importPayload(Data("Amtrak train 1 Chicago to Denver".utf8), kind: .text).ticket
        let second = try await vault.importPayload(Data("Amtrak train 2 Denver to Chicago".utf8), kind: .text).ticket
        intake.sharedTicketSaved(first)
        intake.sharedTicketSaved(second)
        guard case let .review(current) = intake.presentation else { return XCTFail("Expected review") }
        XCTAssertEqual(current.ticketID, first.id)
        intake.dismissPresentation()
        guard case let .review(next) = intake.presentation else { return XCTFail("Expected queued review") }
        XCTAssertEqual(next.ticketID, second.id)
        intake.dismissPresentation()
        XCTAssertNil(intake.presentation)

        intake.attach(ticketID: first.id, to: .trip("trip-7"))
        XCTAssertEqual(vault.tickets(forTrip: "trip-7").map(\.id), [first.id])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        intake.performUndo(planLibrary: try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive()))
        XCTAssertTrue(vault.tickets(forTrip: "trip-7").isEmpty)
        XCTAssertNotNil(vault.ticket(id: first.id))
    }
}

final class AddJourneyImportRecoveryTests: XCTestCase {
    func testReplacementImportClearsPreviousSaveFailureBeforeReading() {
        var recovery = AddJourneyImportRecovery()
        recovery.fail("Storage full", retryPayload: payload("old ticket", kind: .pdf, filename: "Old.pdf"))

        recovery.beginImport()

        XCTAssertNil(recovery.errorMessage)
        XCTAssertNil(recovery.retryPayload, "An unreadable replacement must not retain the old ticket's retry")
    }

    func testPhotoFileAndParseFailuresNeverOfferPreviousPayloadAsRetry() {
        let failures = [
            "That photo couldn't be read. Choose it again.",
            "That file couldn't be opened. Choose it again.",
            "Choose a PDF, image, text or email file.",
            "This ticket couldn't be read.",
        ]
        for failure in failures {
            var recovery = AddJourneyImportRecovery()
            recovery.fail("Storage full", retryPayload: payload("old ticket", kind: .text, filename: nil))
            recovery.beginImport()

            recovery.fail(failure)

            XCTAssertEqual(recovery.errorMessage, failure)
            XCTAssertNil(recovery.retryPayload, "A read or parse failure needs a new selection, not a retry of old contents")
        }
    }

    func testRetryKeepsCurrentFailedSaveContentsAndMetadataAcrossRepeatedFailures() throws {
        var recovery = AddJourneyImportRecovery()
        let current = payload("current ticket", kind: .pdf, filename: "Current.pdf")
        recovery.fail("Storage full", retryPayload: current)

        let retry = try XCTUnwrap(recovery.retryPayload)
        recovery.beginImport()
        recovery.fail("Storage full", retryPayload: retry)

        XCTAssertEqual(recovery.retryPayload?.data, current.data)
        XCTAssertEqual(recovery.retryPayload?.kind, .pdf)
        XCTAssertEqual(recovery.retryPayload?.filename, "Current.pdf")
    }

    func testReplacementSaveFailureOffersOnlyReplacementContents() {
        var recovery = AddJourneyImportRecovery()
        recovery.fail("Storage full", retryPayload: payload("old ticket", kind: .pdf, filename: "Old.pdf"))
        recovery.beginImport()
        recovery.fail("Storage full", retryPayload: payload("replacement ticket", kind: .image, filename: "New.png"))

        XCTAssertEqual(recovery.retryPayload?.data, Data("replacement ticket".utf8))
        XCTAssertEqual(recovery.retryPayload?.kind, .image)
        XCTAssertEqual(recovery.retryPayload?.filename, "New.png")
    }

    private func payload(_ text: String, kind: ShareManifest.Kind, filename: String?) -> AddJourneyImportRecovery.Payload {
        AddJourneyImportRecovery.Payload(data: Data(text.utf8), kind: kind, filename: filename)
    }
}
