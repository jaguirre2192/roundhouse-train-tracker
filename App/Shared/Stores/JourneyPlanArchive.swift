import Foundation
import TrainTrackerCore

@MainActor
protocol JourneyPlanArchiving {
    func load() throws -> [TrackedJourneyPlan]
    func save(_ plans: [TrackedJourneyPlan]) throws
    func loadTrackingAttempts() throws -> [JourneyPlanTrackingAttempt]
    func saveTrackingAttempts(_ attempts: [JourneyPlanTrackingAttempt]) throws
    func preservedRecoveryPayload(for component: JourneyPlanStorageComponent) throws -> Data
    func resetRecoveryStorage(for component: JourneyPlanStorageComponent) throws
}

extension JourneyPlanArchiving {
    func preservedRecoveryPayload(for component: JourneyPlanStorageComponent) throws -> Data {
        throw JourneyPlanRecoveryAccessError.unsupported
    }

    func resetRecoveryStorage(for component: JourneyPlanStorageComponent) throws {
        throw JourneyPlanRecoveryAccessError.unsupported
    }
}

enum JourneyPlanStorageComponent: String, CaseIterable, Hashable, Identifiable, Sendable {
    case plans
    case transactionJournal

    var id: Self { self }

    var title: String {
        switch self {
        case .plans: "Saved Journey Plans"
        case .transactionJournal: "Journey Save Journal"
        }
    }
}

enum JourneyPlanRecoveryAccessError: LocalizedError, Equatable {
    case noStoredPayload
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noStoredPayload:
            "The recovery data is no longer available. Try reading the Journey Plan data again."
        case .unsupported:
            "This Journey Plan storage source doesn't support recovery actions."
        }
    }
}

struct JourneyPlanTrackingAttempt: Codable, Equatable {
    let id: UUID
    var insertedChildTripIDs: Set<RailIdentifier>
    var pendingInsertionChildTripID: RailIdentifier?
    var preExistingChildTripIDs: Set<RailIdentifier>
    // Optional so attempts written before Calendar import remain decodable.
    var calendarEventKey: String? = nil
    /// On restart promote watched children only if this exact booking was committed.
    var rideAfterCommit: RideAfterCommit? = nil

    struct RideAfterCommit: Codable, Equatable {
        let outboundFingerprint: String
        let returnFingerprint: String?
        let tripIDs: Set<RailIdentifier>

        func matches(_ plan: TrackedJourneyPlan) -> Bool {
            outboundFingerprint == plan.outbound.fingerprint && returnFingerprint == plan.returnDirection?.fingerprint
                && tripIDs == Set(plan.outbound.childTripIDs + (plan.returnDirection?.childTripIDs ?? []))
        }
    }
}

@MainActor
struct JourneyPlanArchive: JourneyPlanArchiving {
    enum ArchiveError: Error, Equatable {
        case unsupportedVersion(Int)
        case corruptData
        case storageUnavailable
    }

    static let standard = JourneyPlanArchive(defaults: .standard, fileURL: AtomicArchiveStore.applicationURL("journey-plans.plist"))

    private let storage: AtomicArchiveStore
    private let journalStorage: AtomicArchiveStore
    private let key: String
    private let trackingAttemptsKey: String

    init(defaults: UserDefaults, key: String = "savedJourneyPlans", fileURL: URL? = nil,
         canReadLegacyData: @escaping @MainActor () -> Bool = AtomicArchiveStore.protectedDataAvailable) {
        storage = AtomicArchiveStore(defaults: defaults, fileURL: fileURL, keys: [key],
                                     canReadLegacyData: canReadLegacyData)
        journalStorage = AtomicArchiveStore(defaults: defaults, fileURL: fileURL?.appendingPathExtension("journal"),
                                           keys: [key + ".trackingAttempts"], canReadLegacyData: canReadLegacyData)
        self.key = key
        trackingAttemptsKey = "\(key).trackingAttempts"
    }

    func load() throws -> [TrackedJourneyPlan] {
        let state = try archiveValues(storage)
        guard state[key] != nil else { return [] }
        guard let data = state[key] as? Data else {
            throw ArchiveError.corruptData
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(JourneyPlanArchiveVersion.self, from: data).version
        } catch {
            throw ArchiveError.corruptData
        }
        guard version == 1 else {
            throw ArchiveError.unsupportedVersion(version)
        }

        let envelope: JourneyPlanArchiveEnvelope
        do {
            envelope = try JSONDecoder().decode(JourneyPlanArchiveEnvelope.self, from: data)
        } catch {
            throw ArchiveError.corruptData
        }
        return envelope.plans
    }

    func save(_ plans: [TrackedJourneyPlan]) throws {
        let data = try JSONEncoder().encode(
            JourneyPlanArchiveEnvelope(version: 1, plans: plans)
        )
        try storage.update { $0[key] = data }
    }

    func loadTrackingAttempts() throws -> [JourneyPlanTrackingAttempt] {
        let state = try archiveValues(journalStorage)
        guard state[trackingAttemptsKey] != nil else { return [] }
        guard let data = state[trackingAttemptsKey] as? Data else {
            throw ArchiveError.corruptData
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(JourneyPlanArchiveVersion.self, from: data).version
        } catch {
            throw ArchiveError.corruptData
        }
        guard version == 1 else {
            throw ArchiveError.unsupportedVersion(version)
        }

        let envelope: JourneyPlanTrackingAttemptEnvelope
        do {
            envelope = try JSONDecoder().decode(JourneyPlanTrackingAttemptEnvelope.self, from: data)
        } catch {
            throw ArchiveError.corruptData
        }
        return envelope.attempts
    }

    func saveTrackingAttempts(_ attempts: [JourneyPlanTrackingAttempt]) throws {
        let data = try JSONEncoder().encode(
            JourneyPlanTrackingAttemptEnvelope(version: 1, attempts: attempts)
        )
        try journalStorage.update { $0[trackingAttemptsKey] = data }
    }

    func preservedRecoveryPayload(for component: JourneyPlanStorageComponent) throws -> Data {
        try store(for: component).preservedPayload(for: storageKey(for: component))
    }

    func resetRecoveryStorage(for component: JourneyPlanStorageComponent) throws {
        try store(for: component).reset { $0.removeValue(forKey: storageKey(for: component)) }
    }

    func persistenceValues() throws -> [String: Any] {
        try storage.values().merging(journalStorage.values()) { _, journal in journal }
    }

    private func archiveValues(_ store: AtomicArchiveStore) throws -> [String: Any] {
        do { return try store.values() }
        catch AtomicArchiveStore.StorageError.corruptContainer { throw ArchiveError.corruptData }
        catch { throw ArchiveError.storageUnavailable }
    }

    private func store(for component: JourneyPlanStorageComponent) -> AtomicArchiveStore {
        component == .plans ? storage : journalStorage
    }

    private func storageKey(for component: JourneyPlanStorageComponent) -> String {
        switch component {
        case .plans: key
        case .transactionJournal: trackingAttemptsKey
        }
    }
}

private struct JourneyPlanArchiveVersion: Decodable {
    let version: Int
}

private struct JourneyPlanArchiveEnvelope: Codable {
    let version: Int
    let plans: [TrackedJourneyPlan]
}

private struct JourneyPlanTrackingAttemptEnvelope: Codable {
    let version: Int
    let attempts: [JourneyPlanTrackingAttempt]
}
