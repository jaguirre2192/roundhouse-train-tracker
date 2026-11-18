import Foundation
import Observation
import TrainTrackerCore

struct TicketPurchaseDraft: Identifiable, Codable, Equatable {
    let id: UUID
    var journey: TicketPurchaseJourney
    var openedAt: Date
}

@MainActor
@Observable
final class TicketPurchaseStore {
    private(set) var drafts: [TicketPurchaseDraft] = []
    private(set) var loadFailed = false
    private let fileURL: URL?

    init(fileURL: URL? = TicketPurchaseStore.defaultURL) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
            guard envelope.version == 1 else { throw StorageError.unreadable }
            guard Set(envelope.drafts.map(\.id)).count == envelope.drafts.count else {
                throw StorageError.unreadable
            }
            drafts = envelope.drafts
        } catch { loadFailed = true }
    }

    /// Persists first. A failed write never opens the browser or replaces the in-memory context.
    @discardableResult
    func prepare(_ journey: TicketPurchaseJourney, at now: Date = .now) throws -> TicketPurchaseDraft {
        guard !loadFailed else { throw StorageError.unreadable }
        guard journey.canSearch(at: now) else { throw StorageError.departed }
        var updated = drafts
        let previous = updated.first { $0.journey.selectionFingerprints == journey.selectionFingerprints }
        updated.removeAll { $0.id == previous?.id }
        let draft = TicketPurchaseDraft(id: previous?.id ?? UUID(), journey: journey, openedAt: now)
        updated.insert(draft, at: 0)
        try save(updated)
        drafts = updated
        return draft
    }

    func remove(_ id: UUID) throws {
        guard !loadFailed else { throw StorageError.unreadable }
        let updated = drafts.filter { $0.id != id }
        try save(updated)
        drafts = updated
    }

    /// The UI requires explicit confirmation. Only this feature's recovery file is reset.
    func resetUnreadableSearches() throws {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        drafts = []
        loadFailed = false
    }

    private func save(_ value: [TicketPurchaseDraft]) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(Envelope(version: 1, drafts: value))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "TrainTracker/ticket-searches.json")
    }

    private struct Envelope: Codable {
        let version: Int
        let drafts: [TicketPurchaseDraft]
    }

    enum StorageError: LocalizedError {
        case unreadable, departed
        var errorDescription: String? {
            switch self {
            case .unreadable: "Saved ticket searches couldn’t be read. Reset ticket searches in My Trips to try again. Your tracked trains and tickets are unaffected."
            case .departed: "This journey’s scheduled departure has passed. Search again for an upcoming train before checking tickets."
            }
        }
    }
}
