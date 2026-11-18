import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor ParseCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
final class LocalJourneyTicketStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appending(path: "LocalJourneyTicketStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore(counter: ParseCounter? = nil) -> LocalJourneyTicketStore {
        LocalJourneyTicketStore(directory: directory) { manifest, payload in
            await counter?.increment()
            return await ShareImportParser.parseWithDetails(manifest: manifest, payload: payload)
        }
    }

    private let ticketText = Data("Amtrak Acela 2150\nBoston South Station → New York Penn Station\nDeparts Sep 22, 2026 8:05 AM\nSeat 14A".utf8)

    func testImportPersistsOriginalAndDetailsAcrossRestart() async throws {
        let store = makeStore()
        let result = try await store.importPayload(ticketText, kind: .text, filename: "ticket.txt")
        XCTAssertTrue(result.isNew)
        XCTAssertEqual(result.ticket.suggestion.id, result.ticket.id)
        XCTAssertEqual(result.ticket.details.seat, "14A")
        XCTAssertTrue(result.ticket.isDraft)

        let restarted = makeStore()
        XCTAssertNil(restarted.loadError)
        XCTAssertEqual(restarted.tickets, [result.ticket])
        XCTAssertEqual(try restarted.payload(id: result.ticket.id), ticketText)
        XCTAssertEqual(restarted.draftTickets.map(\.id), [result.ticket.id])
    }

    func testIdenticalBytesDeduplicateAndPreserveLinksAndEdits() async throws {
        let counter = ParseCounter()
        let store = makeStore(counter: counter)
        let first = try await store.importPayload(ticketText, kind: .text)
        let planID = UUID()
        XCTAssertTrue(try store.link(id: first.ticket.id, planID: planID))
        XCTAssertFalse(try store.link(id: first.ticket.id, planID: planID), "A repeated link is not a new, undoable link")

        let repeated = try await makeStore(counter: counter).importPayload(ticketText, kind: .image, filename: "other.png")
        XCTAssertFalse(repeated.isNew)
        XCTAssertEqual(repeated.ticket.id, first.ticket.id)
        XCTAssertEqual(repeated.ticket.linkedPlanIDs, [planID])
        XCTAssertEqual(repeated.ticket.kind, .text)
        let parses = await counter.count
        XCTAssertEqual(parses, 1, "Duplicates are detected before parsing")
    }

    func testConcurrentIdenticalImportsCreateOneRecord() async throws {
        let store = makeStore()
        let payload = ticketText
        async let one = store.importPayload(payload, kind: .text)
        async let two = store.importPayload(payload, kind: .text)
        let results = try await [one, two]
        XCTAssertEqual(Set(results.map(\.ticket.id)).count, 1)
        XCTAssertEqual(store.tickets.count, 1)
        XCTAssertEqual(results.filter(\.isNew).count, 1)
    }

    func testDraftEditsSurviveRestartAndSourcelessReviewsAreSeparate() async throws {
        let store = makeStore()
        let ticket = try await store.importPayload(ticketText, kind: .text).ticket
        try store.saveDraft(ticket.suggestion.revised(origin: "Boston Back Bay"))
        let calendarReview = TicketRouteSuggestion(sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Lyon")
        try store.saveDraft(calendarReview)

        let restarted = makeStore()
        XCTAssertEqual(restarted.ticket(id: ticket.id)?.suggestion.originGuess, "Boston Back Bay")
        XCTAssertEqual(restarted.reviews, [calendarReview])
        try restarted.discardReview(id: calendarReview.id)
        XCTAssertTrue(makeStore().reviews.isEmpty)
        XCTAssertNotNil(makeStore().ticket(id: ticket.id), "Discarding a review never removes a ticket")
    }

    func testClearedCalendarStationStaysClearedAfterRestartWhileLegacyGuessesRecover() throws {
        let base = TicketRouteSuggestion(
            sourceDescription: "Travel", subtitle: "Train: Paris to Lyon",
            originGuess: "Paris", destinationGuess: "Lyon",
            calendarSource: CalendarJourneySource(eventKey: "calendar", revision: "r")
        )
        let store = SmartJourneyReviewStore(
            suggestion: base, client: ScriptedJourneySearchClient(),
            planTracker: RecordingJourneyPlanTracker(), plans: { [] }
        )
        store.setOrigin("")
        let vault = makeStore()
        try vault.saveDraft(store.suggestion)
        let restored = try XCTUnwrap(makeStore().reviews.first)
        XCTAssertNil(restored.originGuess)
        XCTAssertEqual(restored.destinationGuess, "Lyon")
        XCTAssertEqual(restored.originWasReviewed, true)

        let legacy = base.revised(origin: .some(nil), destination: .some(nil))
        let repaired = legacy.restoringMissingCalendarRoute()
        XCTAssertEqual(repaired.originGuess, "Paris")
        XCTAssertEqual(repaired.destinationGuess, "Lyon")
    }

    func testUnlinkKeepsOriginalAndReturnsUnlinkedTicketToReview() async throws {
        let store = makeStore()
        let ticket = try await store.importPayload(ticketText, kind: .text).ticket
        let planID = UUID()
        try store.link(id: ticket.id, planID: planID)
        try store.link(id: ticket.id, tripID: "trip-1")
        XCTAssertEqual(store.tickets(forPlan: planID).map(\.id), [ticket.id])
        XCTAssertEqual(store.tickets(forTrip: "trip-1").map(\.id), [ticket.id])
        XCTAssertFalse(store.ticket(id: ticket.id)!.isDraft)

        try store.unlink(id: ticket.id, planID: planID)
        XCTAssertFalse(store.ticket(id: ticket.id)!.isDraft, "Still attached to a train")
        try store.unlink(id: ticket.id, tripID: "trip-1")
        XCTAssertTrue(store.ticket(id: ticket.id)!.isDraft)
        XCTAssertEqual(try store.payload(id: ticket.id), ticketText)
    }

    func testFailedWritesKeepSavedStateAndReportStorageError() async throws {
        let store = makeStore()
        let ticket = try await store.importPayload(ticketText, kind: .text).ticket
        // Replace the directory with a file so every later write fails.
        let moved = directory.appending(path: "../moved-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.moveItem(at: directory, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try Data("blocker".utf8).write(to: directory)

        XCTAssertThrowsError(try store.link(id: ticket.id, planID: UUID())) { error in
            XCTAssertEqual(error as? LocalJourneyTicketStore.StoreError, .unavailable)
        }
        XCTAssertTrue(store.ticket(id: ticket.id)!.linkedPlanIDs.isEmpty)
        do {
            _ = try await store.importPayload(Data("Amtrak train 9 Chicago to Denver".utf8), kind: .text)
            XCTFail("Expected storage failure")
        } catch {
            XCTAssertEqual(error as? LocalJourneyTicketStore.StoreError, .unavailable)
        }
        XCTAssertEqual(store.tickets.count, 1)
    }

    func testCorruptIndexIsPreservedAndBlocksWrites() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{not json".utf8)
        try corrupt.write(to: directory.appending(path: "index.json"))
        let store = makeStore()
        XCTAssertNotNil(store.loadError)
        XCTAssertFalse(store.isAvailable)
        do {
            _ = try await store.importPayload(ticketText, kind: .text)
            XCTFail("Expected invalid archive")
        } catch {
            XCTAssertEqual(error as? LocalJourneyTicketStore.StoreError, .invalidArchive)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "index.json")), corrupt)
    }

    func testRejectsEmptyAndOversizedPayloads() async {
        let store = makeStore()
        for (payload, expected) in [(Data(), LocalJourneyTicketStore.StoreError.emptyPayload),
                                    (Data(count: ShareImportLimits.maxPayloadBytes + 1), .payloadTooLarge)] {
            do {
                _ = try await store.importPayload(payload, kind: .image)
                XCTFail("Expected rejection")
            } catch {
                XCTAssertEqual(error as? LocalJourneyTicketStore.StoreError, expected)
            }
        }
    }

    func testExplicitRemoveDeletesOnlyThatTicket() async throws {
        let store = makeStore()
        let first = try await store.importPayload(ticketText, kind: .text).ticket
        let second = try await store.importPayload(Data("Amtrak train 9 Chicago to Denver".utf8), kind: .text).ticket
        try store.remove(id: first.id)
        XCTAssertThrowsError(try store.payload(id: first.id))
        XCTAssertEqual(makeStore().tickets.map(\.id), [second.id])
    }

    func testRemovedJourneyReturnsOriginalTicketToReviewAfterRestart() async throws {
        let store = makeStore()
        let ticket = try await store.importPayload(ticketText, kind: .text).ticket
        try store.link(id: ticket.id, planID: UUID())
        try store.link(id: ticket.id, tripID: "removed-train")
        try makeStore().reconcileLinks(planIDs: [], tripIDs: [])
        let reopened = makeStore()
        XCTAssertEqual(reopened.draftTickets.map(\.id), [ticket.id])
        XCTAssertFalse(try XCTUnwrap(reopened.ticket(id: ticket.id)).isLinked)
        XCTAssertEqual(try reopened.payload(id: ticket.id), ticketText)
    }

    func testLinkReconciliationPreservesRemainingJourneyAndExplicitlyKeptTicket() async throws {
        let store = makeStore()
        let linked = try await store.importPayload(ticketText, kind: .text).ticket
        let kept = try await store.importPayload(Data("Amtrak train 9 Chicago to Denver".utf8), kind: .text).ticket
        let retainedPlan = UUID()
        try store.link(id: linked.id, planID: retainedPlan)
        try store.link(id: linked.id, planID: UUID())
        try store.link(id: linked.id, tripID: "retained-train")
        try store.keepWithoutJourney(id: kept.id)
        try store.reconcileLinks(planIDs: [retainedPlan], tripIDs: ["retained-train"])
        let saved = try XCTUnwrap(store.ticket(id: linked.id))
        XCTAssertEqual(saved.linkedPlanIDs, [retainedPlan])
        XCTAssertEqual(saved.linkedTripIDs, ["retained-train"])
        XCTAssertFalse(saved.isDraft)
        XCTAssertFalse(try XCTUnwrap(store.ticket(id: kept.id)).isDraft)
    }
}
