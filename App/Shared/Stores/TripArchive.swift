import Foundation
import TrainTrackerCore

@MainActor
struct TripArchive {
    static let standard = TripArchive(defaults: .standard, fileURL: AtomicArchiveStore.applicationURL("trips.plist"))

    enum RecoveryError: LocalizedError {
        case required, noPayload, unreadable
        var errorDescription: String? {
            switch self {
            case .required:
                "Saved trips need recovery. Export or reset the preserved data in Settings before changing tracked trains."
            case .noPayload:
                "The saved-trip recovery data is no longer available. Try reading the saved trips again."
            case .unreadable:
                "Roundhouse still can't read these saved trips. Export the preserved data before choosing Reset."
            }
        }
    }

    private let storage: AtomicArchiveStore
    private let key: String
    private var recoveryKey: String { "\(key).recoveryRequired" }
    private var lastChecksKey: String { "\(key).lastSuccessfulChecks" }
    private var journalsKey: String { "\(key).changeJournals" }
    private var watchingKey: String { "\(key).watchingOnly" }
    private var recoveryPayloadKey: String { "\(key).recoveryPayload" }

    init(defaults: UserDefaults, key: String = "savedTrips", fileURL: URL? = nil,
         canReadLegacyData: @escaping @MainActor () -> Bool = AtomicArchiveStore.protectedDataAvailable) {
        self.key = key
        storage = AtomicArchiveStore(defaults: defaults, fileURL: fileURL,
            keys: [key, key + ".recoveryRequired", key + ".lastSuccessfulChecks", key + ".recoveryPayload",
                   key + ".watchingOnly", key + ".changeJournals"],
            canReadLegacyData: canReadLegacyData)
    }

    var storageUnavailable: Bool {
        do { _ = try storage.values(); return false }
        catch AtomicArchiveStore.StorageError.corruptContainer { return false }
        catch { return true }
    }

    var recoveryRequired: Bool {
        do {
            let state = try storage.values()
            if state[recoveryKey] as? Bool == true { return true }
            guard let value = state[key] else { return false }
            guard let data = value as? Data else { return true }
            return (try? JSONDecoder().decode([TrainTrip].self, from: data)) == nil
        } catch { return true }
    }

    func loadLastChecks() -> [RailIdentifier: Date] {
        guard let state = try? storage.values(),
              let stored = state[lastChecksKey] as? [String: Double] else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.map { (RailIdentifier(rawValue: $0.key), Date(timeIntervalSince1970: $0.value)) })
    }

    func loadRefreshEvidence(for ids: Set<RailIdentifier>) -> [RailIdentifier: TripRefreshEvidence] {
        let journals = (try? storage.values()[journalsKey] as? [String: Data]) ?? [:]
        let checks = loadLastChecks()
        return ids.reduce(into: [:]) { result, id in
            let journal = journals[id.rawValue].flatMap { try? JSONDecoder().decode(TripChangeJournal.self, from: $0) }
            if checks[id] != nil || journal != nil {
                result[id] = TripRefreshEvidence(lastSuccessfulCheck: checks[id], changes: journal ?? TripChangeJournal())
            }
        }
    }

    func saveChangeJournals(_ updates: [RailIdentifier: TripChangeJournal]) throws {
        guard !recoveryRequired else { throw RecoveryError.required }
        let encoded = try updates.mapValues { try JSONEncoder().encode($0) }
        try storage.update { values in
            var journals = values[journalsKey] as? [String: Data] ?? [:]
            for (id, journal) in encoded { journals[id.rawValue] = journal }
            values[journalsKey] = journals
        }
    }

    func loadWatchingIDs() -> Set<RailIdentifier> {
        guard let raw = (try? storage.values())?[watchingKey] as? [String] else { return [] }
        return Set(raw.map { RailIdentifier(rawValue: $0) })
    }

    /// A train and its local watching intent must survive or fail together. Provider snapshots
    /// contain no passenger intent and can replace the train without replacing this metadata.
    func saveOrThrow(_ trips: [TrainTrip], watching ids: Set<RailIdentifier>) throws {
        guard !recoveryRequired else { throw RecoveryError.required }
        let data = try encode(trips)
        try storage.update {
            $0[key] = data
            $0[watchingKey] = ids.map(\.rawValue).sorted()
            $0.removeValue(forKey: recoveryPayloadKey)
        }
    }

    @discardableResult
    func saveLastChecks(_ checks: [RailIdentifier: Date]) -> Bool {
        do {
            try storage.update { $0[lastChecksKey] = encodedChecks(checks) }
            return true
        } catch { return false }
    }

    func load() -> [TrainTrip] {
        do {
            let state = try storage.values()
            guard state[recoveryKey] as? Bool != true, let value = state[key] else { return [] }
            guard let data = value as? Data, let trips = try? JSONDecoder().decode([TrainTrip].self, from: data) else {
                let payload = try storage.preservedPayload(for: key)
                try? storage.update {
                    if $0[recoveryPayloadKey] == nil { $0[recoveryPayloadKey] = payload }
                    $0[recoveryKey] = true
                }
                return []
            }
            return trips
        } catch { return [] }
    }

    /// Compatibility for injected legacy fixtures. Production writes use the throwing APIs.
    @discardableResult
    func save(_ trips: [TrainTrip]) -> Bool {
        do { try saveOrThrow(trips); return true } catch { return false }
    }

    func saveOrThrow(_ trips: [TrainTrip]) throws {
        try saveEncoded(encode(trips))
    }

    /// Trip snapshots and successful-check times commit in the same atomic replacement.
    func save(_ trips: [TrainTrip], lastChecks: [RailIdentifier: Date],
              journalUpdate: (RailIdentifier, TripChangeJournal)? = nil) throws {
        guard !recoveryRequired else { throw RecoveryError.required }
        let data = try encode(trips)
        let updatedJournal = try journalUpdate.map { ($0.0.rawValue, try JSONEncoder().encode($0.1)) }
        try storage.update {
            $0[key] = data
            $0[lastChecksKey] = encodedChecks(lastChecks)
            if updatedJournal != nil || $0[journalsKey] != nil {
                let kept = Set(trips.map { $0.id.rawValue })
                var journals = ($0[journalsKey] as? [String: Data] ?? [:]).filter { kept.contains($0.key) }
                if let (id, encoded) = updatedJournal, kept.contains(id) { journals[id] = encoded }
                $0[journalsKey] = journals
            }
            if let watched = $0[watchingKey] as? [String], !watched.isEmpty {
                let kept = Set(trips.map { $0.id.rawValue })
                $0[watchingKey] = watched.filter(kept.contains)
            }
            $0.removeValue(forKey: recoveryPayloadKey)
        }
    }

    func encode(_ trips: [TrainTrip]) throws -> Data { try JSONEncoder().encode(trips) }

    func saveEncoded(_ data: Data) throws {
        guard !recoveryRequired else { throw RecoveryError.required }
        try storage.update {
            $0[key] = data
            $0.removeValue(forKey: recoveryPayloadKey)
        }
    }

    func preservedRecoveryPayload() throws -> Data {
        guard recoveryRequired else { throw RecoveryError.noPayload }
        if let state = try? storage.values(), let payload = state[recoveryPayloadKey] as? Data { return payload }
        return try storage.preservedPayload(for: key)
    }

    func retryRecovery() throws -> [TrainTrip] {
        // A protected-data or transient I/O failure can clear without any corrupt payload.
        let state = try storage.values()
        if state[recoveryKey] as? Bool != true {
            guard let value = state[key] else { return [] }
            if let data = value as? Data, let trips = try? JSONDecoder().decode([TrainTrip].self, from: data) {
                return trips
            }
        }
        let payload = try preservedRecoveryPayload()
        guard let trips = try? JSONDecoder().decode([TrainTrip].self, from: payload) else { throw RecoveryError.unreadable }
        try storage.update { $0[key] = payload; $0.removeValue(forKey: recoveryKey) }
        return trips
    }

    func resetRecovery() throws {
        guard recoveryRequired else { return }
        let data = try encode([])
        try storage.reset {
            $0[key] = data
            $0[lastChecksKey] = [String: Double]()
            $0.removeValue(forKey: journalsKey)
            $0.removeValue(forKey: watchingKey)
            $0.removeValue(forKey: recoveryKey)
            $0.removeValue(forKey: recoveryPayloadKey)
        }
    }

    /// Exact canonical values used by the independent cold-process proof.
    func persistenceValues() throws -> [String: Any] { try storage.values() }

    private func encodedChecks(_ checks: [RailIdentifier: Date]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: checks.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
    }
}
