import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// A two-process discriminator for a retained live-proof failure. Uses synthetic archived data
/// and isolated keys; never overwrites the app's savedTrips/savedJourneyPlans keys.
@MainActor
final class LiveDefaultsDurabilityProbeTests: XCTestCase {
    private struct Entry: Codable {
        let suite: String?
        let archiveKey: String
        let planKey: String
        let expected: [String: Data]
        let checks: [String: Double]
    }
    private struct Probe: Codable {
        let run: String
        let writerPID: Int32
        let entries: [Entry]
    }
    private struct PlanEnvelope: Decodable { let plans: [TrackedJourneyPlan] }

    func testWriteStandardAndSuiteArchivesForSeparateProcess() async throws {
        let run = try probeRun()
        let file = try receiptURL(run: run)
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw LiveFlowFailure("Defaults probe run already exists; use a fresh identifier")
        }
        let source = try swissReceipt()
        let trips = try JSONDecoder().decode([TrainTrip].self, from: XCTUnwrap(source.archives["savedTrips"]))
        let plans = try JSONDecoder().decode(PlanEnvelope.self, from: XCTUnwrap(source.archives["savedJourneyPlans"])).plans
        let checks = Dictionary(uniqueKeysWithValues: source.checks.map {
            (RailIdentifier(rawValue: $0.key), Date(timeIntervalSince1970: $0.value))
        })
        let suite = "LiveDefaultsDurabilityProbe.\(UUID())"
        let archiveKey = "LiveDefaultsDurabilityProbe.\(run).trips"
        let planKey = "LiveDefaultsDurabilityProbe.\(run).plans"
        var entries: [Entry] = []
        let standardLast = ProcessInfo.processInfo.environment["TRAIN_TRACKER_DEFAULTS_PROBE_STANDARD_LAST"] == "1"
        let domains: [String?] = standardLast ? [suite, nil] : [nil, suite]
        for domain in domains {
            let defaults = try open(domain)
            let tripArchive = TripArchive(defaults: defaults, key: archiveKey)
            let planArchive = JourneyPlanArchive(defaults: defaults, key: planKey)
            try planArchive.saveTrackingAttempts([
                JourneyPlanTrackingAttempt(id: UUID(), insertedChildTripIDs: [], preExistingChildTripIDs: [])
            ])
            XCTAssertTrue(defaults.synchronize())
            try tripArchive.saveOrThrow(trips)
            try planArchive.save(plans)
            try planArchive.saveTrackingAttempts([])
            // Match the live flow's reconstructed store before its final refresh write.
            let reopened = try open(domain)
            let reloaded = TripArchive(defaults: reopened, key: archiveKey)
            XCTAssertEqual(reloaded.load(), trips)
            try reloaded.saveOrThrow(trips)
            reloaded.saveLastChecks(checks)
            XCTAssertTrue(reopened.synchronize())
            let expected = try capture(reopened, keys: [archiveKey, planKey, planKey + ".trackingAttempts"])
            let storedChecks = try XCTUnwrap(reopened.dictionary(forKey: archiveKey + ".lastSuccessfulChecks") as? [String: Double])
            entries.append(Entry(suite: domain, archiveKey: archiveKey, planKey: planKey,
                                 expected: expected, checks: storedChecks))
        }
        // This deliberately adds no settling delay. The cold reader determines persistence.
        let probe = Probe(run: run, writerPID: ProcessInfo.processInfo.processIdentifier, entries: entries)
        try JSONEncoder().encode(probe).write(to: file, options: .atomic)
        print("Defaults durability probe written: \(run), domains=standard+UUIDsuite; independent reader required")
    }

    func testReadStandardAndSuiteArchivesInSeparateProcess() throws {
        let run = try probeRun()
        let file = try receiptURL(run: run)
        let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: file))
        guard probe.run == run, probe.writerPID != ProcessInfo.processInfo.processIdentifier,
              probe.entries.count == 2, probe.entries.filter({ $0.suite == nil }).count == 1 else {
            throw LiveFlowFailure("Defaults probe requires both domains from a different process")
        }
        var failures: [String] = []
        for entry in probe.entries {
            let defaults = try open(entry.suite)
            let label = entry.suite == nil ? "standard" : "UUID suite"
            for (key, expected) in entry.expected.sorted(by: { $0.key < $1.key }) {
                let actual = defaults.data(forKey: key)
                let equal = actual == expected
                print("Defaults probe \(label) \(key): expectedBytes=\(expected.count), actualBytes=\(actual?.count ?? -1), exact=\(equal)")
                if !equal { failures.append("\(label): \(key)") }
            }
            let actualChecks = defaults.dictionary(forKey: entry.archiveKey + ".lastSuccessfulChecks") as? [String: Double]
            print("Defaults probe \(label) exactChecks=\(actualChecks == entry.checks)")
            if actualChecks != entry.checks { failures.append("\(label): check timestamps") }
        }
        guard failures.isEmpty else {
            throw LiveFlowFailure("Defaults durability probe differs: \(failures.joined(separator: "; "))")
        }
        print("Defaults durability probe verified exact archives and checks in both domains: \(run)")
        // All fixtures remain for investigation, including on success. No archive is rewritten.
    }

    private func probeRun() throws -> String {
        guard let run = ProcessInfo.processInfo.environment["TRAIN_TRACKER_DEFAULTS_PROBE_RUN"] else {
            throw XCTSkip("Set TRAIN_TRACKER_DEFAULTS_PROBE_RUN and run writer then reader in separate app processes")
        }
        guard run.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw LiveFlowFailure("Invalid defaults probe identifier")
        }
        return run
    }

    private func receiptURL(run: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appending(path: "LiveDefaultsDurabilityProbe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: run + ".json")
    }

    private func swissReceipt() throws -> LiveRailPersistenceProof.Receipt {
        let sourceRun = ProcessInfo.processInfo.environment["TRAIN_TRACKER_DEFAULTS_PROBE_SOURCE_RUN"]
            ?? "production-20261113-evidence18-b"
        guard sourceRun.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw LiveFlowFailure("Invalid defaults probe source run")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        let directory = support.appending(path: "LiveRailPersistenceProof").appending(path: sourceRun)
        let receipts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                try JSONDecoder().decode(LiveRailPersistenceProof.Receipt.self, from: Data(contentsOf: $0))
            }.filter { $0.seed == "CH Zurich–Bern" }
        guard receipts.count == 1, let receipt = receipts.first else {
            throw LiveFlowFailure("Expected exactly one preserved synthetic Swiss receipt")
        }
        return receipt
    }

    private func open(_ suite: String?) throws -> UserDefaults {
        if let suite { return try XCTUnwrap(UserDefaults(suiteName: suite)) }
        return .standard
    }

    private func capture(_ defaults: UserDefaults, keys: [String]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, try XCTUnwrap(defaults.data(forKey: key), "Missing probe archive \(key)"))
        })
    }
}
