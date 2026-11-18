import CryptoKit
import Foundation
import Observation

/// Original tickets and unfinished reviews are local, durable and independent of sign-in.
/// Every change writes the index atomically before memory is updated, so a failed write never
/// replaces what is already saved. A corrupt index is left untouched and blocks writes.
@MainActor
@Observable
final class LocalJourneyTicketStore {
    enum StoreError: LocalizedError, Equatable {
        case unavailable
        case invalidArchive
        case missingTicket
        case payloadTooLarge
        case emptyPayload

        var errorDescription: String? {
            switch self {
            case .unavailable: "Your ticket couldn't be saved on this device. Free some storage, then try again."
            case .invalidArchive: "Saved tickets couldn't be read, so changes are paused to protect them. Try loading them again."
            case .missingTicket: "This ticket is no longer saved on this device. Import it again to continue."
            case .payloadTooLarge: "That file is larger than 8 MB. Share a smaller copy of the ticket."
            case .emptyPayload: "That item is empty. Choose the ticket file again."
            }
        }
    }

    struct ImportResult: Equatable {
        let ticket: LocalJourneyTicket
        /// False when identical bytes were already saved; links and edits are preserved.
        let isNew: Bool
    }

    typealias Parser = @Sendable (ShareManifest, Data) async -> ParsedTicketImport

    private struct Archive: Codable {
        var version: Int
        var tickets: [LocalJourneyTicket]
        /// Unfinished reviews without an original artifact, such as a Calendar event.
        var reviews: [TicketRouteSuggestion]?
    }

    static let archiveVersion = 1

    private(set) var tickets: [LocalJourneyTicket] = []
    private(set) var reviews: [TicketRouteSuggestion] = []
    private(set) var loadError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let parse: Parser
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var healthy = false

    init(
        directory: URL? = nil,
        parse: @escaping Parser = { manifest, payload in
            await ShareImportParser.parseWithDetails(manifest: manifest, payload: payload)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.parse = parse
        self.now = now
        reload()
    }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "LocalJourneyTickets", directoryHint: .isDirectory)
    }

    var isAvailable: Bool { healthy }

    /// Tickets that still need a journey, most recent first.
    var draftTickets: [LocalJourneyTicket] {
        tickets.filter(\.isDraft).sorted { $0.updatedAt > $1.updatedAt }
    }

    func ticket(id: UUID) -> LocalJourneyTicket? {
        tickets.first { $0.id == id }
    }

    func tickets(forPlan planID: UUID) -> [LocalJourneyTicket] {
        tickets.filter { $0.linkedPlanIDs.contains(planID) }.sorted { $0.createdAt < $1.createdAt }
    }

    func tickets(forTrip tripID: String) -> [LocalJourneyTicket] {
        tickets.filter { $0.linkedTripIDs.contains(tripID) }.sorted { $0.createdAt < $1.createdAt }
    }

    func reload() {
        do {
            let index = indexURL
            if FileManager.default.fileExists(atPath: index.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: index))
                guard archive.version == Self.archiveVersion,
                      Set(archive.tickets.map(\.id)).count == archive.tickets.count,
                      Set(archive.tickets.map(\.digest)).count == archive.tickets.count else {
                    throw StoreError.invalidArchive
                }
                tickets = archive.tickets
                reviews = (archive.reviews ?? []).map { $0.restoringMissingCalendarRoute() }
            } else {
                tickets = []
                reviews = []
            }
            healthy = true
            loadError = nil
        } catch {
            healthy = false
            loadError = StoreError.invalidArchive.localizedDescription
        }
    }

    // MARK: - Import

    /// Saves the original bytes and parsed details before returning. Identical bytes return the
    /// existing record, so a repeated share, file or photo import never creates a duplicate.
    func importPayload(
        _ payload: Data,
        kind: ShareManifest.Kind,
        filename: String? = nil,
        parsed: ParsedTicketImport? = nil
    ) async throws -> ImportResult {
        guard healthy else { throw StoreError.invalidArchive }
        guard !payload.isEmpty else { throw StoreError.emptyPayload }
        guard ShareImportLimits.isSizeAllowed(payload.count) else { throw StoreError.payloadTooLarge }
        let digest = Self.digest(payload)
        if let existing = tickets.first(where: { $0.digest == digest }) {
            return ImportResult(ticket: existing, isNew: false)
        }
        let id = UUID()
        let manifest = ShareManifest(
            id: id, createdAt: now(), kind: kind, payloadFilename: "payload",
            suggestedFilename: filename, sizeBytes: payload.count
        )
        let result: ParsedTicketImport
        if let parsed {
            result = parsed
        } else {
            result = await parse(manifest, payload)
        }
        // Another intake may have saved the same bytes while text recognition was suspended.
        if let existing = tickets.first(where: { $0.digest == digest }) {
            return ImportResult(ticket: existing, isNew: false)
        }
        guard healthy else { throw StoreError.invalidArchive }
        let date = now()
        let record = LocalJourneyTicket(
            id: id, digest: digest, createdAt: date, kind: kind, filename: filename,
            mimeType: LocalJourneyTicket.mimeType(for: kind, payload: payload),
            suggestion: result.suggestion.revised(id: id), details: result.details, updatedAt: date
        )
        do {
            try prepareDirectory()
            try payload.write(to: payloadURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw StoreError.unavailable
        }
        do {
            try publish(tickets: [record] + tickets, reviews: reviews)
        } catch {
            try? FileManager.default.removeItem(at: payloadURL(id))
            throw error
        }
        return ImportResult(ticket: record, isNew: true)
    }

    // MARK: - Reviews

    /// Persists edits for a ticket, or for an unfinished review without an original artifact.
    func saveDraft(_ suggestion: TicketRouteSuggestion) throws {
        if tickets.contains(where: { $0.id == suggestion.id }) {
            try updateTicket(suggestion.id) { $0.suggestion = suggestion }
        } else {
            var next = reviews.filter { $0.id != suggestion.id }
            next.insert(suggestion, at: 0)
            try publish(tickets: tickets, reviews: next)
        }
    }

    /// Removes an unfinished review. Tickets and their originals are never removed here.
    func discardReview(id: UUID) throws {
        guard reviews.contains(where: { $0.id == id }) else { return }
        try publish(tickets: tickets, reviews: reviews.filter { $0.id != id })
    }

    /// Keeps the ticket on this device without a journey. It leaves the unfinished list.
    func keepWithoutJourney(id: UUID) throws {
        try updateTicket(id) { $0.isDraft = false }
    }

    func reopenForReview(id: UUID) throws {
        try updateTicket(id) { $0.isDraft = true }
    }

    // MARK: - Links

    /// Returns true when this call created the link, which is the only link Undo may remove.
    @discardableResult
    func link(id: UUID, planID: UUID) throws -> Bool {
        var inserted = false
        try updateTicket(id) {
            inserted = $0.linkedPlanIDs.insert(planID).inserted
            if inserted || $0.suggestion.routeReviewReason != .multipleJourneys { $0.finishLink() }
        }
        return inserted
    }

    @discardableResult
    func link(id: UUID, tripID: String) throws -> Bool {
        var inserted = false
        try updateTicket(id) {
            inserted = $0.linkedTripIDs.insert(tripID).inserted
            if inserted || $0.suggestion.routeReviewReason != .multipleJourneys { $0.finishLink() }
        }
        return inserted
    }

    /// Unlinking never deletes the original. A ticket with no journey returns to review.
    func unlink(id: UUID, planID: UUID) throws {
        try updateTicket(id) {
            $0.linkedPlanIDs.remove(planID)
            if !$0.isLinked { $0.isDraft = true }
        }
    }

    func unlink(id: UUID, tripID: String) throws {
        try updateTicket(id) {
            $0.linkedTripIDs.remove(tripID)
            if !$0.isLinked { $0.isDraft = true }
        }
    }

    /// Called only after both journey archives loaded successfully. Removing a journey keeps
    /// its original ticket available for review, including after an interrupted app session.
    func reconcileLinks(planIDs: Set<UUID>, tripIDs: Set<String>) throws {
        var updated = tickets
        for index in updated.indices {
            let wasLinked = updated[index].isLinked
            updated[index].linkedPlanIDs.formIntersection(planIDs)
            updated[index].linkedTripIDs.formIntersection(tripIDs)
            if wasLinked && !updated[index].isLinked { updated[index].isDraft = true }
        }
        guard updated != tickets else { return }
        try publish(tickets: updated, reviews: reviews)
    }

    /// Explicit deletion from the ticket screen. Journeys and trains are unaffected.
    func remove(id: UUID) throws {
        guard tickets.contains(where: { $0.id == id }) else { return }
        try publish(tickets: tickets.filter { $0.id != id }, reviews: reviews)
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: barcodeURL(id))
    }

    // MARK: - Artifacts

    func payload(id: UUID) throws -> Data {
        guard tickets.contains(where: { $0.id == id }) else { throw StoreError.missingTicket }
        do {
            return try Data(contentsOf: payloadURL(id))
        } catch {
            throw StoreError.missingTicket
        }
    }

    func cachedBarcode(id: UUID) -> Data? {
        try? Data(contentsOf: barcodeURL(id))
    }

    /// Scans once on device and keeps the crop beside the original for offline display.
    func barcode(id: UUID) async -> Data? {
        if let cached = cachedBarcode(id: id) { return cached }
        guard let ticket = ticket(id: id), ticket.hasVisualOriginal,
              let data = try? payload(id: id) else { return nil }
        let mimeType = ticket.mimeType
        guard let barcode = try? await Task.detached(priority: .userInitiated, operation: {
            try TicketBarcodeScanner.croppedBarcode(from: data, mimeType: mimeType)
        }).value else { return nil }
        guard tickets.contains(where: { $0.id == id }) else { return barcode }
        try? barcode.write(to: barcodeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return barcode
    }

    // MARK: - Persistence

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func updateTicket(_ id: UUID, change: (inout LocalJourneyTicket) -> Void) throws {
        var next = tickets
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw StoreError.missingTicket }
        let original = next[index]
        change(&next[index])
        guard next[index] != original else { return }
        next[index].updatedAt = now()
        try publish(tickets: next, reviews: reviews)
    }

    private func publish(tickets nextTickets: [LocalJourneyTicket], reviews nextReviews: [TicketRouteSuggestion]) throws {
        guard healthy else { throw StoreError.invalidArchive }
        do {
            try prepareDirectory()
            let archive = Archive(version: Self.archiveVersion, tickets: nextTickets, reviews: nextReviews)
            try JSONEncoder().encode(archive).write(
                to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw StoreError.unavailable
        }
        tickets = nextTickets
        reviews = nextReviews
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private var indexURL: URL { directory.appending(path: "index.json") }
    private func payloadURL(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".payload") }
    private func barcodeURL(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".barcode") }
}
