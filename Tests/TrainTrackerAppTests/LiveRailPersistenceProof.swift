import Foundation
import TrainTrackerCore
@testable import TrainTracker

/// Records expected bytes in our own receipt file, then verifies them through supported
/// archive APIs after the app process has ended. Never inspects UserDefaults' private files.
@MainActor
enum LiveRailPersistenceProof {
    struct Receipt: Codable {
        let runID: String
        let seed: String
        let suite: String
        let writerPID: Int32
        let archives: [String: Data]
        let checks: [String: Double]
        let vaultDirectoryName: String
        let ticketID: UUID
        let planID: UUID
        let payload: Data
        var canonicalFiles: [String: Data]? = nil
    }

    static var requestedRunID: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["TRAIN_TRACKER_PROVIDER_ACCESS_COLD_PROOF_RUN"]
            ?? environment["TRAIN_TRACKER_LIVE_COLD_PROOF_RUN"]
    }

    static func ticketDirectory() throws -> URL {
        let name = "LiveImportTracking-\(UUID())"
        guard let runID = requestedRunID else { return FileManager.default.temporaryDirectory.appending(path: name) }
        return try receiptsDirectory(runID: runID).appending(path: "vaults").appending(path: name)
    }

    static func flush(defaults: UserDefaults) throws {
        guard defaults.synchronize() else {
            throw LiveFlowFailure("Could not flush live-flow preferences")
        }
    }

    static func tripFile(in directory: URL) -> URL { directory.appending(path: "archives/trips.plist") }
    static func planFile(in directory: URL) -> URL { directory.appending(path: "archives/journey-plans.plist") }

    static func record(tripArchive: TripArchive, planArchive: JourneyPlanArchive, suite: String, seed: String,
                       vaultDirectory: URL, ticketID: UUID, planID: UUID, payload: Data) throws -> String? {
        guard let runID = requestedRunID else { return nil }
        let values = try tripArchive.persistenceValues().merging(planArchive.persistenceValues()) { _, value in value }
        let archives = try Dictionary(uniqueKeysWithValues: archiveKeys.map { key in
            guard let bytes = values[key] as? Data, !bytes.isEmpty else {
                throw LiveFlowFailure("Missing canonical archive \(key) before cold-app verification")
            }
            return (key, bytes)
        })
        guard let checks = values["savedTrips.lastSuccessfulChecks"] as? [String: Double], !checks.isEmpty else {
            throw LiveFlowFailure("Missing canonical refreshed trip checks before cold-app verification")
        }
        var receipt = Receipt(runID: runID, seed: seed, suite: suite, writerPID: ProcessInfo.processInfo.processIdentifier,
                              archives: archives, checks: checks, vaultDirectoryName: vaultDirectory.lastPathComponent,
                              ticketID: ticketID, planID: planID, payload: payload)
        receipt.canonicalFiles = try canonicalFileBytes(in: vaultDirectory)
        let directory = try receiptsDirectory(runID: runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(suite).json")
        let bytes = try JSONEncoder().encode(receipt)
        try bytes.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == bytes else { throw LiveFlowFailure("Cold-app proof receipt was not written") }
        return "Recorded atomic archive bytes for run \(runID); separate app launch must verify \(seed)"
    }

    static func verifyRun(runID: String, expectedCount: Int = 18, expectedSeeds: Set<String>? = nil) throws -> String {
        let directory = try receiptsDirectory(runID: runID)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let receipts = try files.map { try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: $0)) }
        try validateReceipts(receipts, runID: runID, expectedCount: expectedCount,
                             readerPID: ProcessInfo.processInfo.processIdentifier)
        if let expectedSeeds, Set(receipts.map(\.seed)) != expectedSeeds {
            throw LiveFlowFailure("Cold-app proof journeys do not match the required country/route matrix")
        }
        for receipt in receipts { try verifyReceipt(receipt) }
        // Retain all evidence if any receipt fails; clean only this completed run after all pass.
        for receipt in receipts {
            UserDefaults(suiteName: receipt.suite)?.removePersistentDomain(forName: receipt.suite)
            try FileManager.default.removeItem(at: vaultDirectory(for: receipt))
        }
        try FileManager.default.removeItem(at: directory)
        return "Verified \(receipts.count) journeys in a new app process: exact archive bytes, refresh checks, decoded archives, empty save journals, and ticket payloads"
    }

    static func validateReceipts(_ receipts: [Receipt], runID: String, expectedCount: Int, readerPID: Int32) throws {
        guard receipts.count == expectedCount, Set(receipts.map(\.seed)).count == expectedCount,
              Set(receipts.map(\.suite)).count == expectedCount else {
            throw LiveFlowFailure("Cold-app proof requires exactly \(expectedCount) unique journeys; found \(receipts.count)")
        }
        guard receipts.allSatisfy({ $0.runID == runID && $0.writerPID != readerPID
            && $0.suite.hasPrefix("LiveImportTracking.") }) else {
            throw LiveFlowFailure("Cold-app proof must read the requested run from a different app process")
        }
    }

    static func verifyReceipt(_ receipt: Receipt) throws {
        guard let defaults = UserDefaults(suiteName: receipt.suite) else { throw LiveFlowFailure("Cannot open saved suite") }
        let directory = try vaultDirectory(for: receipt)
        let tripArchive: TripArchive
        let planArchive: JourneyPlanArchive
        let domain: [String: Any]
        if let expectedFiles = receipt.canonicalFiles {
            // Read all three existing files before constructing an archive: a missing file
            // must fail, not be silently recreated from legacy preferences during this proof.
            guard expectedFiles == (try canonicalFileBytes(in: directory)) else {
                throw LiveFlowFailure("Cold-app canonical file bytes differ for \(receipt.seed)")
            }
            tripArchive = TripArchive(defaults: defaults, fileURL: tripFile(in: directory))
            planArchive = JourneyPlanArchive(defaults: defaults, fileURL: planFile(in: directory))
            domain = try tripArchive.persistenceValues().merging(planArchive.persistenceValues()) { _, value in value }
        } else {
            // Earlier failed UserDefaults runs remain inspectable without rewriting their evidence.
            try flush(defaults: defaults)
            guard let stored = defaults.persistentDomain(forName: receipt.suite) else {
                throw LiveFlowFailure("Cold-app suite is missing for \(receipt.seed)")
            }
            domain = stored
            tripArchive = TripArchive(defaults: defaults)
            planArchive = JourneyPlanArchive(defaults: defaults)
        }
        for key in receipt.canonicalFiles == nil ? ["savedTrips", "savedJourneyPlans"] : archiveKeys {
            guard let expected = receipt.archives[key], !expected.isEmpty, domain[key] as? Data == expected else {
                throw LiveFlowFailure("Cold-app archive \(key) differs for \(receipt.seed)")
            }
        }
        guard domain["savedTrips.lastSuccessfulChecks"] as? [String: Double] == receipt.checks else {
            throw LiveFlowFailure("Cold-app refresh checks differ for \(receipt.seed)")
        }
        let expectedTrips = try JSONDecoder().decode([TrainTrip].self, from: receipt.archives["savedTrips"]!)
        let expectedPlans = try JSONDecoder().decode(PlanEnvelope.self, from: receipt.archives["savedJourneyPlans"]!).plans
        guard !tripArchive.recoveryRequired, tripArchive.load() == expectedTrips,
              try planArchive.load() == expectedPlans,
              try planArchive.loadTrackingAttempts().isEmpty,
              expectedPlans.contains(where: { $0.id == receipt.planID }) else {
            throw LiveFlowFailure("Cold-app archive reconstruction failed for \(receipt.seed)")
        }
        let vault = LocalJourneyTicketStore(directory: try vaultDirectory(for: receipt))
        guard vault.tickets(forPlan: receipt.planID).map(\.id) == [receipt.ticketID],
              try vault.payload(id: receipt.ticketID) == receipt.payload else {
            throw LiveFlowFailure("Cold-app ticket association or payload differs for \(receipt.seed)")
        }
    }

    private static let archiveKeys = ["savedTrips", "savedJourneyPlans", "savedJourneyPlans.trackingAttempts"]

    private static func canonicalFileBytes(in directory: URL) throws -> [String: Data] {
        let urls = ["trips": tripFile(in: directory), "plans": planFile(in: directory),
                    "journal": planFile(in: directory).appendingPathExtension("journal")]
        return try urls.mapValues { try Data(contentsOf: $0) }
    }

    private struct PlanEnvelope: Decodable { let plans: [TrackedJourneyPlan] }

    private static func receiptsDirectory(runID: String) throws -> URL {
        guard runID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw LiveFlowFailure("Invalid cold-app proof run identifier")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return support.appending(path: "LiveRailPersistenceProof").appending(path: runID)
    }

    private static func vaultDirectory(for receipt: Receipt) throws -> URL {
        guard receipt.vaultDirectoryName.hasPrefix("LiveImportTracking-"),
              !receipt.vaultDirectoryName.contains("/"), !receipt.vaultDirectoryName.contains("..") else {
            throw LiveFlowFailure("Invalid cold-app ticket fixture directory")
        }
        return try receiptsDirectory(runID: receipt.runID).appending(path: "vaults").appending(path: receipt.vaultDirectoryName)
    }
}
