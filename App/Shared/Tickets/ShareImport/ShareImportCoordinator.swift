import Foundation
import Observation

/// Handles the "bring staged shares into review" side of the Share extension handoff. A Share
/// extension has no way to launch its containing app, so nothing wakes this up automatically —
/// the host app calls `scanForPendingShares()` itself, on launch and whenever it becomes active,
/// and this coordinator leases whatever it finds from the App Group inbox. The durable files are
/// acknowledged exactly once only after confirmation or an explicit discard.
///
/// Multiple pending shares are handled as a small in-memory queue, oldest first: only one review
/// sheet is ever presented at a time, and dismissing/confirming it advances to the next queued
/// item automatically.
@MainActor
@Observable
final class ShareImportCoordinator {
    private(set) var pendingReview: TicketRouteSuggestion?
    private(set) var errorMessage: String?

    /// Saves a leased share durably before its staging copy is acknowledged. When set, shares
    /// no longer wait in `pendingReview`: the local copy is the recoverable source of truth.
    typealias Handoff = @MainActor (ShareManifest, Data, ParsedTicketImport) async throws -> Void

    private let store: ShareStagingStore
    private let imageTextRecognizer: any ImageTextRecognizing
    private let handoff: Handoff?
    private var queue: [UUID] = []
    private var knownIDs: Set<UUID> = []
    /// Items whose local save just failed. They stay staged but wait for the next foreground scan
    /// or an explicit retry, so dismissing the error cannot immediately repeat the same failure.
    private var heldAfterFailure: Set<UUID> = []
    private var activeLease: ShareStagingStore.Lease?
    private var isProcessing = false

    init(
        store: ShareStagingStore = ShareStagingStore(),
        imageTextRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer(),
        handoff: Handoff? = nil
    ) {
        self.store = store
        self.imageTextRecognizer = imageTextRecognizer
        self.handoff = handoff
    }

    nonisolated static func isCallback(_ url: URL) -> Bool {
        url.scheme == "traintracker" && url.host == "share-import"
    }

    /// Compatibility path only: earlier builds of the extension tried to hand off a single item
    /// via this URL scheme. Normal operation never relies on it — `scanForPendingShares()` is what
    /// actually discovers staged shares — but honoring it costs nothing if it ever arrives.
    func handleCallback(_ url: URL) async {
        guard Self.isCallback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: idString) else { return }
        enqueue([id])
        await processQueueIfNeeded()
    }

    /// Safe to call repeatedly (initial launch, every time the app becomes active). IDs remain in
    /// `knownIDs` while queued, parsing, or under review, which closes the actor-reentrancy window
    /// where an overlapping scan could otherwise enqueue the same durable manifest again.
    func scanForPendingShares() async {
        heldAfterFailure.removeAll()
        let ids = await store.pendingManifestIDs()
        enqueue(ids)
        await processQueueIfNeeded()
    }

    /// Commits the current handoff after the person chooses Find Trains. The caller should only
    /// continue into search when this returns true, so a storage failure cannot silently lose the
    /// item between review and navigation.
    @discardableResult
    func confirmReview() async -> Bool {
        await finishReview(advanceSynchronously: false)
    }

    /// Explicit cancellation or interactive dismissal is a discard, not a passive read. It uses
    /// the same durable acknowledgment boundary as confirmation, then advances the queue.
    @discardableResult
    func discardReview() async -> Bool {
        await finishReview(advanceSynchronously: true)
    }

    /// Clearing an error also rescans before processing. A corrupt head item is removed by the
    /// store, while every later valid manifest remains durable and resumes after the alert.
    func dismissError() async {
        errorMessage = nil
        let ids = await store.pendingManifestIDs().filter { !heldAfterFailure.contains($0) }
        enqueue(ids)
        await processQueueIfNeeded()
    }

    private func enqueue(_ ids: [UUID]) {
        for id in ids where knownIDs.insert(id).inserted {
            queue.append(id)
        }
    }

    private func processQueueIfNeeded() async {
        guard !isProcessing, pendingReview == nil, errorMessage == nil else { return }
        isProcessing = true
        defer { isProcessing = false }
        while pendingReview == nil, !queue.isEmpty {
            let id = queue.removeFirst()
            do {
                let lease = try await store.lease(manifestID: id)
                activeLease = lease
                let parsed = await ShareImportParser.parseWithDetails(
                    manifest: lease.manifest,
                    payload: lease.payload,
                    imageTextRecognizer: imageTextRecognizer
                )

                // Parsing is deliberately non-destructive. If the launch/foreground task is
                // cancelled while OCR is suspended, release only the in-memory claim so a later
                // scan (or a relaunched coordinator) can recover the same durable item.
                guard !Task.isCancelled else {
                    activeLease = nil
                    knownIDs.remove(id)
                    return
                }
                if let handoff {
                    guard await transfer(lease, parsed: parsed, to: handoff) else { return }
                    continue
                }
                pendingReview = parsed.suggestion
            } catch ShareStagingStore.StoreError.manifestMissing, ShareStagingStore.StoreError.expired {
                knownIDs.remove(id)
                continue
            } catch {
                knownIDs.remove(id)
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// The staged item is acknowledged only after the handoff has saved it. A failure keeps the
    /// durable staged copy for the next scan, and identical bytes are deduplicated on retry.
    private func transfer(_ lease: ShareStagingStore.Lease, parsed: ParsedTicketImport, to handoff: Handoff) async -> Bool {
        do {
            try await handoff(lease.manifest, lease.payload, parsed)
        } catch {
            activeLease = nil
            knownIDs.remove(lease.id)
            heldAfterFailure.insert(lease.id)
            let reason = (error as? LocalizedError)?.errorDescription ?? "The shared ticket couldn't be saved on this device."
            errorMessage = reason + " It's still waiting and will import the next time you open Roundhouse."
            return false
        }
        do {
            try await store.acknowledge(lease)
        } catch {
            activeLease = nil
            knownIDs.remove(lease.id)
            heldAfterFailure.insert(lease.id)
            errorMessage = "The shared ticket is saved in My Trips. Its temporary copy will be cleared the next time you open Roundhouse."
            return false
        }
        activeLease = nil
        knownIDs.remove(lease.id)
        return true
    }

    private func finishReview(advanceSynchronously: Bool) async -> Bool {
        guard let lease = activeLease, pendingReview != nil else { return false }
        do {
            try await store.acknowledge(lease)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        activeLease = nil
        pendingReview = nil
        knownIDs.remove(lease.id)

        if advanceSynchronously {
            await processQueueIfNeeded()
        } else {
            // Queue progression must not delay confirmed navigation behind OCR for a later item.
            Task { await self.processQueueIfNeeded() }
        }
        return true
    }
}
