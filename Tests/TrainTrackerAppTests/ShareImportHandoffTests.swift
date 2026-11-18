import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    var isFailing: Bool { lock.withLock { failing } }
    func stop() { lock.withLock { failing = false } }
}

private struct NoTextRecognizer: ImageTextRecognizing {
    func recognizeText(in payload: Data) async throws -> String? { nil }
}

/// Shared tickets are saved to the local vault before the staged copy is acknowledged.
@MainActor
final class ShareImportHandoffTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "ShareImportHandoffTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeVault() -> LocalJourneyTicketStore {
        LocalJourneyTicketStore(directory: root.appending(path: "vault"))
    }

    private func makeCoordinator(
        store: ShareStagingStore, vault: LocalJourneyTicketStore, intake: JourneyIntakeModel? = nil, failFirst: Bool = false
    ) -> ShareImportCoordinator {
        var shouldFail = failFirst
        return ShareImportCoordinator(store: store, imageTextRecognizer: NoTextRecognizer()) { manifest, payload, parsed in
            if shouldFail {
                shouldFail = false
                throw LocalJourneyTicketStore.StoreError.unavailable
            }
            let result = try await vault.importPayload(payload, kind: manifest.kind, filename: manifest.suggestedFilename, parsed: parsed)
            intake?.sharedTicketSaved(result.ticket)
        }
    }

    func testSharedTicketIsSavedThenAcknowledgedAndPresentedForReview() async throws {
        let inbox = root.appending(path: "inbox")
        let store = ShareStagingStore(inboxURLProvider: { inbox })
        let vault = makeVault()
        let intake = JourneyIntakeModel(vault: vault)
        _ = try await store.stage(payload: Data("Amtrak Acela 2150 Boston to New York".utf8), kind: .text, suggestedFilename: nil)
        let coordinator = makeCoordinator(store: store, vault: vault, intake: intake)

        await coordinator.scanForPendingShares()

        XCTAssertNil(coordinator.pendingReview, "The vault copy replaces the in-memory review")
        XCTAssertEqual(vault.tickets.count, 1)
        let pending = await store.pendingManifestIDs()
        XCTAssertEqual(pending, [])
        guard case let .review(request) = intake.presentation else { return XCTFail("Expected review") }
        XCTAssertEqual(request.ticketID, vault.tickets.first?.id)
        XCTAssertEqual(request.suggestion.originGuess, "Boston")
    }

    func testFailedLocalSaveKeepsStagedItemAndRetryDoesNotDuplicate() async throws {
        let inbox = root.appending(path: "inbox")
        let store = ShareStagingStore(inboxURLProvider: { inbox })
        let vault = makeVault()
        let manifest = try await store.stage(payload: Data("Amtrak train 305 Chicago to St. Louis".utf8), kind: .text, suggestedFilename: nil)
        let coordinator = makeCoordinator(store: store, vault: vault, failFirst: true)

        await coordinator.scanForPendingShares()
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(vault.tickets.isEmpty)
        let stillPending = await store.pendingManifestIDs()
        XCTAssertEqual(stillPending, [manifest.id])

        await coordinator.dismissError()
        XCTAssertNil(coordinator.errorMessage, "Dismissing does not immediately repeat the failed save")
        XCTAssertTrue(vault.tickets.isEmpty)
        let held = await store.pendingManifestIDs()
        XCTAssertEqual(held, [manifest.id])

        await coordinator.scanForPendingShares() // Next foreground
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(vault.tickets.count, 1)
        let cleared = await store.pendingManifestIDs()
        XCTAssertEqual(cleared, [])
    }

    func testFailedAcknowledgmentAfterSaveRetriesWithoutSecondTicket() async throws {
        let inbox = root.appending(path: "inbox")
        let failure = FailureSwitch()
        let store = ShareStagingStore(inboxURLProvider: { inbox }, beforeAcknowledge: {
            if failure.isFailing { throw ShareStagingStore.StoreError.containerUnavailable }
        })
        let vault = makeVault()
        _ = try await store.stage(payload: Data("Eurostar 9032 London→Paris".utf8), kind: .text, suggestedFilename: nil)
        let coordinator = makeCoordinator(store: store, vault: vault)

        await coordinator.scanForPendingShares()
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(vault.tickets.count, 1)
        failure.stop()
        await coordinator.dismissError()
        XCTAssertEqual(vault.tickets.count, 1)
        await coordinator.scanForPendingShares()
        XCTAssertEqual(vault.tickets.count, 1, "Identical bytes are deduplicated on retry")
        let pending = await store.pendingManifestIDs()
        XCTAssertEqual(pending, [])
    }

    func testRepeatShareOfLinkedTicketDoesNotReopenReview() async throws {
        let vault = makeVault()
        let intake = JourneyIntakeModel(vault: vault)
        let payload = Data("Amtrak Acela 2150 Boston to New York".utf8)
        let first = try await vault.importPayload(payload, kind: .text)
        try vault.link(id: first.ticket.id, planID: UUID())
        let repeated = try await vault.importPayload(payload, kind: .text)
        intake.sharedTicketSaved(repeated.ticket)
        XCTAssertNil(intake.presentation)
    }
}
