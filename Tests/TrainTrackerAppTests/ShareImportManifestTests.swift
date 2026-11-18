import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import TrainTracker

private actor ShareReadyCommitGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseBeforeCommit() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func releaseCommit() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class ShareImportLimitsTests: XCTestCase {
    func testAcceptsPlainTextURLPDFAndImageTypes() {
        XCTAssertEqual(ShareImportLimits.kind(forTypeIdentifier: UTType.plainText.identifier), .text)
        XCTAssertEqual(ShareImportLimits.kind(forTypeIdentifier: UTType.url.identifier), .url)
        XCTAssertEqual(ShareImportLimits.kind(forTypeIdentifier: UTType.pdf.identifier), .pdf)
        XCTAssertEqual(ShareImportLimits.kind(forTypeIdentifier: UTType.jpeg.identifier), .image)
    }

    func testRejectsUnsupportedTypeIdentifier() {
        XCTAssertNil(ShareImportLimits.kind(forTypeIdentifier: UTType.executable.identifier))
        XCTAssertFalse(ShareImportLimits.isAcceptedTypeIdentifier(UTType.executable.identifier))
    }

    func testFileURLsAreNotTreatedAsWebURLs() {
        XCTAssertNotEqual(ShareImportLimits.kind(forTypeIdentifier: UTType.fileURL.identifier), .url)
    }

    func testSizeValidationRejectsZeroAndOversizePayloads() {
        XCTAssertFalse(ShareImportLimits.isSizeAllowed(0))
        XCTAssertFalse(ShareImportLimits.isSizeAllowed(ShareImportLimits.maxPayloadBytes + 1))
        XCTAssertTrue(ShareImportLimits.isSizeAllowed(1024))
        XCTAssertTrue(ShareImportLimits.isSizeAllowed(ShareImportLimits.maxPayloadBytes))
    }
}

final class ShareStagingStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareStagingStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeStore() -> ShareStagingStore {
        let directory = tempDirectory!
        return ShareStagingStore(inboxURLProvider: { directory })
    }

    // MARK: - Default (unavailable App Group container) behavior in the test host

    func testStageRejectsOversizePayload() async {
        let store = ShareStagingStore()
        let oversized = Data(repeating: 0x41, count: ShareImportLimits.maxPayloadBytes + 1)

        do {
            _ = try await store.stage(payload: oversized, kind: .text, suggestedFilename: nil)
            XCTFail("Expected oversize payload to be rejected")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .payloadTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLeaseWithUnknownIdentifierThrows() async {
        let store = ShareStagingStore()

        do {
            _ = try await store.lease(manifestID: UUID())
            XCTFail("Expected leasing an unknown manifest to throw")
        } catch {
            // Either containerUnavailable (no App Group entitlement in the test host) or
            // manifestMissing is acceptable here — both mean nothing was returned.
        }
    }

    // MARK: - Hardened behavior against an injected (real, writable) inbox directory

    func testStageThenLeaseStaysDurableUntilAcknowledged() async throws {
        let store = makeStore()
        let payload = Data("hello train".utf8)

        let manifest = try await store.stage(payload: payload, kind: .text, suggestedFilename: "note.txt")
        let pending = await store.pendingManifestIDs()
        XCTAssertEqual(pending, [manifest.id])

        let lease = try await store.lease(manifestID: manifest.id)
        XCTAssertEqual(lease.manifest.id, manifest.id)
        XCTAssertEqual(lease.payload, payload)
        let pendingWhileLeased = await store.pendingManifestIDs()
        XCTAssertEqual(pendingWhileLeased, [manifest.id])

        try await store.acknowledge(lease)
        let pendingAfterAcknowledgment = await store.pendingManifestIDs()
        XCTAssertEqual(pendingAfterAcknowledgment, [])

        do {
            _ = try await store.lease(manifestID: manifest.id)
            XCTFail("Expected an acknowledged id to be single-use")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .manifestMissing)
        }
    }

    func testPendingManifestIDsAreOrderedOldestFirst() async throws {
        let store = makeStore()
        let older = try writeManifest(in: store, createdAt: Date().addingTimeInterval(-60), payload: Data("older".utf8))
        let newer = try writeManifest(in: store, createdAt: Date().addingTimeInterval(-30), payload: Data("newer".utf8))

        let pending = await store.pendingManifestIDs()

        XCTAssertEqual(pending, [older, newer])
    }

    func testTwoStoresCannotDiscoverOrPurgeSuspendedReadyCommit() async throws {
        let directory = tempDirectory!
        let gate = ShareReadyCommitGate()
        let writer = ShareStagingStore(
            inboxURLProvider: { directory },
            beforeReadyCommit: { await gate.pauseBeforeCommit() }
        )
        let reader = ShareStagingStore(inboxURLProvider: { directory })
        let payload = Data("suspended extension".utf8)

        let stagingTask = Task {
            try await writer.stage(payload: payload, kind: .text, suggestedFilename: nil)
        }
        await gate.waitUntilPaused()

        let firstPendingWhileSuspended = await reader.pendingManifestIDs()
        let secondPendingWhileSuspended = await reader.pendingManifestIDs()
        XCTAssertEqual(firstPendingWhileSuspended, [])
        XCTAssertEqual(secondPendingWhileSuspended, [])
        let whileSuspended = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(whileSuspended.filter { $0.lastPathComponent.contains(".staging-") }.count, 1)

        await gate.releaseCommit()
        let manifest = try await stagingTask.value

        let pendingAfterCommit = await reader.pendingManifestIDs()
        XCTAssertEqual(pendingAfterCommit, [manifest.id])
        let lease = try await reader.lease(manifestID: manifest.id)
        XCTAssertEqual(lease.payload, payload)
    }

    func testConsumeRejectsManifestWhoseDecodedIdDoesNotMatchTheFilename() async throws {
        let store = makeStore()
        let requestedID = UUID()
        let impostorID = UUID()
        // Simulate a tampered/corrupt manifest file: its filename says `requestedID`, but the
        // JSON payload inside claims a different id.
        try write(
            manifest: ShareManifest(
                id: impostorID,
                createdAt: Date(),
                kind: .text,
                payloadFilename: ShareStagingStore.payloadFilename(for: impostorID),
                suggestedFilename: nil,
                sizeBytes: 5
            ),
            named: "\(requestedID.uuidString).manifest.json"
        )

        do {
            _ = try await store.lease(manifestID: requestedID)
            XCTFail("Expected id mismatch to be treated as corrupt")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .corrupt)
        }
    }

    func testConsumeIgnoresAForgedPayloadFilenameAndNeverTouchesIt() async throws {
        let store = makeStore()
        let id = UUID()
        // A forged `payloadFilename` (as if trying a path traversal) must not be trusted — the
        // real payload path is always derived from `id`, so this can only fail validation.
        try write(
            manifest: ShareManifest(
                id: id,
                createdAt: Date(),
                kind: .text,
                payloadFilename: "../../etc/passwd",
                suggestedFilename: nil,
                sizeBytes: 5
            ),
            named: "\(id.uuidString).manifest.json"
        )
        try Data("hello".utf8).write(to: tempDirectory.appendingPathComponent(ShareStagingStore.payloadFilename(for: id)))

        // The forged `payloadFilename` is never used to build a path — only compared — so this
        // fails validation (corrupt) rather than ever touching a path outside the inbox directory.
        do {
            _ = try await store.lease(manifestID: id)
            XCTFail("Expected forged payloadFilename to be treated as corrupt")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .corrupt)
        }
    }

    func testConsumeRejectsPayloadByteCountMismatch() async throws {
        let store = makeStore()
        let id = UUID()
        try write(
            manifest: ShareManifest(
                id: id,
                createdAt: Date(),
                kind: .text,
                payloadFilename: ShareStagingStore.payloadFilename(for: id),
                suggestedFilename: nil,
                sizeBytes: 999
            ),
            named: "\(id.uuidString).manifest.json"
        )
        try Data("too short".utf8).write(to: tempDirectory.appendingPathComponent(ShareStagingStore.payloadFilename(for: id)))

        do {
            _ = try await store.lease(manifestID: id)
            XCTFail("Expected byte count mismatch to be treated as corrupt")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .corrupt)
        }
    }

    func testConsumeRejectsManifestClaimingOversizePayload() async throws {
        let store = makeStore()
        let id = UUID()
        try write(
            manifest: ShareManifest(
                id: id,
                createdAt: Date(),
                kind: .text,
                payloadFilename: ShareStagingStore.payloadFilename(for: id),
                suggestedFilename: nil,
                sizeBytes: ShareImportLimits.maxPayloadBytes + 1
            ),
            named: "\(id.uuidString).manifest.json"
        )

        do {
            _ = try await store.lease(manifestID: id)
            XCTFail("Expected oversize sizeBytes to be rejected")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
    }

    func testExpiredManifestIsRejectedAndPurged() async throws {
        let store = makeStore()
        let id = UUID()
        let staleDate = Date().addingTimeInterval(-(ShareManifest.maxAge + 60))
        try write(
            manifest: ShareManifest(
                id: id,
                createdAt: staleDate,
                kind: .text,
                payloadFilename: ShareStagingStore.payloadFilename(for: id),
                suggestedFilename: nil,
                sizeBytes: 5
            ),
            named: "\(id.uuidString).manifest.json"
        )
        try Data("hello".utf8).write(to: tempDirectory.appendingPathComponent(ShareStagingStore.payloadFilename(for: id)))

        do {
            _ = try await store.lease(manifestID: id)
            XCTFail("Expected expired manifest to be rejected")
        } catch let error as ShareStagingStore.StoreError {
            XCTAssertEqual(error, .expired)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent(ShareStagingStore.payloadFilename(for: id)).path
        ))
    }

    func testPendingManifestIDsPurgesExpiredEntriesButProtectsLegacyOrphanPayloads() async throws {
        let store = makeStore()
        let staleDate = Date().addingTimeInterval(-(ShareManifest.maxAge + 60))
        let expiredID = try writeManifest(in: store, createdAt: staleDate, payload: Data("stale".utf8))
        let liveID = try writeManifest(in: store, createdAt: Date(), payload: Data("fresh".utf8))
        // A legacy flat payload has no atomic marker, so the host cannot distinguish an orphan
        // from an older extension suspended just before its manifest write.
        let orphanPayloadURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).payload")
        try Data("orphan".utf8).write(to: orphanPayloadURL)

        let pending = await store.pendingManifestIDs()

        XCTAssertEqual(pending, [liveID])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent(ShareStagingStore.payloadFilename(for: expiredID)).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPayloadURL.path))
    }

    func testPendingManifestIDsPurgesStagingDirectoryOnlyAfterFullShareLifetime() async throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fresh = tempDirectory.appendingPathComponent(
            ".\(UUID().uuidString).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let expired = tempDirectory.appendingPathComponent(
            ".\(UUID().uuidString).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelated = tempDirectory.appendingPathComponent(".archive.staging-old", isDirectory: true)
        let unrelatedReady = tempDirectory.appendingPathComponent("notes.share", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelatedReady, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(ShareManifest.maxAge + 60))],
            ofItemAtPath: expired.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(ShareManifest.maxAge + 60))],
            ofItemAtPath: unrelated.path
        )

        _ = await makeStore().pendingManifestIDs()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedReady.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func writeManifest(in store: ShareStagingStore, createdAt: Date, payload: Data) throws -> UUID {
        let id = UUID()
        let payloadFilename = ShareStagingStore.payloadFilename(for: id)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try payload.write(to: tempDirectory.appendingPathComponent(payloadFilename))
        try write(
            manifest: ShareManifest(
                id: id,
                createdAt: createdAt,
                kind: .text,
                payloadFilename: payloadFilename,
                suggestedFilename: nil,
                sizeBytes: payload.count
            ),
            named: "\(id.uuidString).manifest.json"
        )
        return id
    }

    private func write(manifest: ShareManifest, named filename: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: tempDirectory.appendingPathComponent(filename))
    }
}
