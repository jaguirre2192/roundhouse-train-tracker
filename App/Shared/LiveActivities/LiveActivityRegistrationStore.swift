import CryptoKit
import Foundation

@MainActor
final class LiveActivityRegistrationStore {
    private struct Record: Codable {
        var tokenHash: String
        var generation: Int
        var ended: Bool
    }
    private let defaults: UserDefaults
    private static let recordsKey = "trainLiveActivityRegistrations.v1"
    private static let ownerKey = "trainLiveActivityRegistrationOwner.v1"
    private static let retiredIDsKey = "trainLiveActivityRetiredIDs.v1"
    private var records: [String: Record]
    private var recordInstallationID: UUID

    var installationID: UUID {
        let current = defaults.string(forKey: "pushInstallationID").flatMap(UUID.init(uuidString:))
            ?? recordInstallationID
        if current != recordInstallationID {
            retireActivityIDs(Set(records.keys))
            recordInstallationID = current
            records.removeAll()
            save()
        }
        return current
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: Self.recordsKey).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        if let saved = defaults.string(forKey: "pushInstallationID").flatMap(UUID.init(uuidString:)) {
            recordInstallationID = defaults.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:)) ?? saved
        } else {
            recordInstallationID = UUID()
            defaults.set(recordInstallationID.uuidString, forKey: "pushInstallationID")
        }
        _ = installationID
        save()
    }

    static func resetInstallationRecords(in defaults: UserDefaults, retiringActivityIDs: Set<String> = []) {
        let records = defaults.data(forKey: recordsKey)
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        let retired = Set(defaults.stringArray(forKey: retiredIDsKey) ?? [])
            .union(records.keys).union(retiringActivityIDs)
        defaults.set(Array(retired), forKey: retiredIDsKey)
        defaults.removeObject(forKey: recordsKey)
        defaults.set(defaults.string(forKey: "pushInstallationID"), forKey: ownerKey)
    }

    /// Adopts a replacement installation without retiring running activities, so they can
    /// register under it. End requests owned by the previous installation are dropped.
    func adoptReplacementInstallation(keepingActivityIDs running: Set<String>) {
        let ended = Set(records.filter { $0.value.ended }.map(\.key)).subtracting(running)
        let retired = Set(defaults.stringArray(forKey: Self.retiredIDsKey) ?? []).union(ended)
        defaults.set(Array(retired), forKey: Self.retiredIDsKey)
        recordInstallationID = defaults.string(forKey: "pushInstallationID").flatMap(UUID.init(uuidString:))
            ?? recordInstallationID
        records.removeAll()
        save()
    }

    /// Retired IDs only matter while ActivityKit still lists the activity.
    func pruneRetiredActivityIDs(keeping existingIDs: Set<String>) {
        let stored = Set(defaults.stringArray(forKey: Self.retiredIDsKey) ?? [])
        let kept = stored.intersection(existingIDs)
        guard kept.count != stored.count else { return }
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.retiredIDsKey)
        } else {
            defaults.set(Array(kept), forKey: Self.retiredIDsKey)
        }
    }

    var retiredActivityIDs: Set<String> {
        _ = installationID
        return Set(defaults.stringArray(forKey: Self.retiredIDsKey) ?? [])
    }

    func retireActivityIDs(_ ids: Set<String>) {
        let retired = Set(defaults.stringArray(forKey: Self.retiredIDsKey) ?? []).union(ids)
        defaults.set(Array(retired), forKey: Self.retiredIDsKey)
        for id in ids { records[id] = nil }
        save()
    }

    var knownActivityIDs: Set<String> {
        _ = installationID
        return Set(records.keys)
    }
    var pendingEnds: [String] {
        _ = installationID
        return records.filter { $0.value.ended }.map(\.key)
    }

    func generation(for id: String, token: Data) -> Int? {
        _ = installationID
        guard !retiredActivityIDs.contains(id), records[id]?.ended != true else { return nil }
        let hash = SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
        var record = records[id] ?? Record(tokenHash: "", generation: 0, ended: false)
        if record.tokenHash != hash {
            record.tokenHash = hash
            record.generation += 1
        }
        records[id] = record
        save()
        return record.generation
    }

    func markEnded(_ id: String) {
        _ = installationID
        guard !retiredActivityIDs.contains(id) else { return }
        var record = records[id] ?? Record(tokenHash: "", generation: 0, ended: true)
        record.ended = true
        records[id] = record
        save()
    }

    func acknowledgeEnd(_ id: String) {
        _ = installationID
        records[id] = nil
        save()
    }

    private func save() {
        defaults.set(recordInstallationID.uuidString, forKey: Self.ownerKey)
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.recordsKey) }
    }
}
