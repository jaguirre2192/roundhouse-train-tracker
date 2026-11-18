import Foundation
import XCTest
@testable import TrainTracker

private struct NilImageTextRecognizer: ImageTextRecognizing {
    func recognizeText(in payload: Data) async throws -> String? { nil }
}

private actor SuspendedImageTextRecognizer: ImageTextRecognizing {
    private var callCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<String?, Never>?

    func recognizeText(in payload: Data) async throws -> String? {
        callCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilStarted() async {
        if callCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume(with text: String?) {
        resultContinuation?.resume(returning: text)
        resultContinuation = nil
    }

    func calls() -> Int { callCount }
}

@MainActor
final class ShareImportCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeCoordinator() -> (ShareImportCoordinator, ShareStagingStore) {
        let directory = tempDirectory!
        let store = ShareStagingStore(inboxURLProvider: { directory })
        let coordinator = ShareImportCoordinator(store: store, imageTextRecognizer: NilImageTextRecognizer())
        return (coordinator, store)
    }

    func testScanLeasesOldestFirstThenAcknowledgesExplicitDiscards() async throws {
        let (coordinator, store) = makeCoordinator()
        _ = try await store.stage(payload: Data("older share".utf8), kind: .text, suggestedFilename: nil)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await store.stage(payload: Data("newer share".utf8), kind: .text, suggestedFilename: nil)

        await coordinator.scanForPendingShares()
        XCTAssertEqual(coordinator.pendingReview?.subtitle, "older share")
        let pendingBeforeDisposition = await store.pendingManifestIDs()
        XCTAssertEqual(pendingBeforeDisposition.count, 2)

        await coordinator.discardReview()
        XCTAssertEqual(coordinator.pendingReview?.subtitle, "newer share")
        let pendingAfterFirstDiscard = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterFirstDiscard.count, 1)

        await coordinator.discardReview()
        XCTAssertNil(coordinator.pendingReview)
        let pendingAfterSecondDiscard = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterSecondDiscard, [])
    }

    func testOverlappingScansDuringSuspendedOCRDoNotDuplicateTheLease() async throws {
        let directory = tempDirectory!
        let store = ShareStagingStore(inboxURLProvider: { directory })
        let recognizer = SuspendedImageTextRecognizer()
        let coordinator = ShareImportCoordinator(store: store, imageTextRecognizer: recognizer)
        _ = try await store.stage(payload: Data("image bytes".utf8), kind: .image, suggestedFilename: nil)

        let firstScan = Task { await coordinator.scanForPendingShares() }
        await recognizer.waitUntilStarted()
        await coordinator.scanForPendingShares()
        await coordinator.scanForPendingShares()

        let callsWhileSuspended = await recognizer.calls()
        XCTAssertEqual(callsWhileSuspended, 1)
        XCTAssertNil(coordinator.pendingReview)
        XCTAssertNil(coordinator.errorMessage)

        await recognizer.resume(with: "only share")
        await firstScan.value

        XCTAssertEqual(coordinator.pendingReview?.subtitle, "only share")
        let callsAfterResume = await recognizer.calls()
        XCTAssertEqual(callsAfterResume, 1)
        await coordinator.scanForPendingShares()
        let callsAfterRescan = await recognizer.calls()
        XCTAssertEqual(callsAfterRescan, 1)

        await coordinator.discardReview()
        XCTAssertNil(coordinator.pendingReview)
        let pendingAfterDiscard = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterDiscard, [])
    }

    func testRelaunchAfterLeaseDuringOCRRecoversDurableItem() async throws {
        let directory = tempDirectory!
        let store = ShareStagingStore(inboxURLProvider: { directory })
        let manifest = try await store.stage(
            payload: Data("unrecognized image".utf8),
            kind: .image,
            suggestedFilename: nil
        )

        // Simulate the first process terminating after its destructive predecessor would have
        // consumed the bytes, but before OCR or review could finish.
        _ = try await store.lease(manifestID: manifest.id)
        let pendingAfterInterruptedLease = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterInterruptedLease, [manifest.id])

        let relaunched = ShareImportCoordinator(
            store: ShareStagingStore(inboxURLProvider: { directory }),
            imageTextRecognizer: NilImageTextRecognizer()
        )
        await relaunched.scanForPendingShares()

        XCTAssertNotNil(relaunched.pendingReview)
        let confirmed = await relaunched.confirmReview()
        XCTAssertTrue(confirmed)
        let pendingAfterConfirmation = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterConfirmation, [])
    }

    func testRelaunchDuringReviewRecoversUntilExplicitDisposition() async throws {
        let directory = tempDirectory!
        let firstStore = ShareStagingStore(inboxURLProvider: { directory })
        let manifest = try await firstStore.stage(
            payload: Data("review survives relaunch".utf8),
            kind: .text,
            suggestedFilename: nil
        )
        let firstCoordinator = ShareImportCoordinator(
            store: firstStore,
            imageTextRecognizer: NilImageTextRecognizer()
        )
        await firstCoordinator.scanForPendingShares()
        XCTAssertEqual(firstCoordinator.pendingReview?.subtitle, "review survives relaunch")
        let pendingDuringReview = await firstStore.pendingManifestIDs()
        XCTAssertEqual(pendingDuringReview, [manifest.id])

        let relaunchedStore = ShareStagingStore(inboxURLProvider: { directory })
        let relaunchedCoordinator = ShareImportCoordinator(
            store: relaunchedStore,
            imageTextRecognizer: NilImageTextRecognizer()
        )
        await relaunchedCoordinator.scanForPendingShares()

        XCTAssertEqual(relaunchedCoordinator.pendingReview?.subtitle, "review survives relaunch")
        await relaunchedCoordinator.discardReview()
        let pendingAfterDiscard = await relaunchedStore.pendingManifestIDs()
        XCTAssertEqual(pendingAfterDiscard, [])
    }

    func testFailedAcknowledgmentKeepsReviewAndDurableItemRecoverable() async throws {
        let directory = tempDirectory!
        let store = ShareStagingStore(
            inboxURLProvider: { directory },
            beforeAcknowledge: { throw ShareStagingStore.StoreError.containerUnavailable }
        )
        let manifest = try await store.stage(
            payload: Data("keep this review".utf8),
            kind: .text,
            suggestedFilename: nil
        )
        let coordinator = ShareImportCoordinator(
            store: store,
            imageTextRecognizer: NilImageTextRecognizer()
        )
        await coordinator.scanForPendingShares()
        let reviewID = coordinator.pendingReview?.id

        let confirmed = await coordinator.confirmReview()

        XCTAssertFalse(confirmed)
        XCTAssertEqual(coordinator.pendingReview?.id, reviewID)
        XCTAssertEqual(
            coordinator.errorMessage,
            "Roundhouse couldn't reach its shared storage."
        )
        let pendingAfterFailure = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterFailure, [manifest.id])

        await coordinator.dismissError()
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.pendingReview?.id, reviewID)
        let pendingAfterErrorDismissal = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterErrorDismissal, [manifest.id])
    }

    func testCorruptHeadThenValidItemResumesOnceAfterErrorDismissal() async throws {
        let (coordinator, store) = makeCoordinator()
        let corrupt = try await store.stage(
            payload: Data("corrupt head".utf8),
            kind: .text,
            suggestedFilename: nil
        )
        try await Task.sleep(for: .milliseconds(5))
        let valid = try await store.stage(
            payload: Data("valid second".utf8),
            kind: .text,
            suggestedFilename: nil
        )
        let corruptPayloadURL = tempDirectory
            .appendingPathComponent("\(corrupt.id.uuidString).share", isDirectory: true)
            .appendingPathComponent(ShareStagingStore.payloadFilename(for: corrupt.id))
        try Data("changed byte count".utf8).write(to: corruptPayloadURL)

        await coordinator.scanForPendingShares()

        XCTAssertEqual(
            coordinator.errorMessage,
            "This shared item couldn't be verified and was removed."
        )
        XCTAssertNil(coordinator.pendingReview)
        let pendingAfterCorruptHead = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterCorruptHead, [valid.id])

        async let firstOverlap: Void = coordinator.scanForPendingShares()
        async let secondOverlap: Void = coordinator.scanForPendingShares()
        _ = await (firstOverlap, secondOverlap)
        XCTAssertNil(coordinator.pendingReview)

        await coordinator.dismissError()

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.pendingReview?.subtitle, "valid second")
        await coordinator.scanForPendingShares()
        await coordinator.discardReview()
        XCTAssertNil(coordinator.pendingReview)
        let pendingAfterValidDiscard = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterValidDiscard, [])
    }

    func testHandleCallbackConsumesTheReferencedManifest() async throws {
        let (coordinator, store) = makeCoordinator()
        let manifest = try await store.stage(payload: Data("callback share".utf8), kind: .text, suggestedFilename: nil)
        let url = URL(string: "traintracker://share-import?id=\(manifest.id.uuidString)")!

        await coordinator.handleCallback(url)

        XCTAssertEqual(coordinator.pendingReview?.subtitle, "callback share")
        let confirmed = await coordinator.confirmReview()
        XCTAssertTrue(confirmed)
        let pendingAfterConfirmation = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterConfirmation, [])
    }

    func testIrrelevantURLIsIgnored() async {
        let (coordinator, _) = makeCoordinator()

        await coordinator.handleCallback(URL(string: "https://example.com")!)

        XCTAssertNil(coordinator.pendingReview)
        XCTAssertNil(coordinator.errorMessage)
    }
}
