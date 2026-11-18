import Foundation
import CryptoKit
import TrainTrackerCore
@testable import TrainTracker
import XCTest

@MainActor
final class LiveRailPersistenceProofTests: XCTestCase {
    func testColdLaunchReadsAllCompletedLiveSuites() throws {
        guard let runID = LiveRailPersistenceProof.requestedRunID else {
            throw XCTSkip("Set TRAIN_TRACKER_LIVE_COLD_PROOF_RUN after the 18 live seeds, then terminate and relaunch the app")
        }
        let evidence = try LiveRailPersistenceProof.verifyRun(runID: runID, expectedCount: 18)
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "Cold-app persistence proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testColdLaunchReadsAmtrakAndSpain() throws {
        guard ProcessInfo.processInfo.environment["TRAIN_TRACKER_AMTRAK_SPAIN_COLD_PROOF"] == "1",
              let runID = LiveRailPersistenceProof.requestedRunID else {
            throw XCTSkip("Run this after the two Amtrak and Spain ticket imports in a separate app process")
        }
        let result = try LiveRailPersistenceProof.verifyRun(
            runID: runID, expectedCount: 2, expectedSeeds: ["US New York–Washington", "ES Madrid–Barcelona RENFE"]
        )
        let attachment = XCTAttachment(string: result)
        attachment.name = "Amtrak and Spain cold-launch proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Read-only diagnosis of a retained failure. This does not count as a persistence proof
    /// and does not clean, rewrite, or repair any archive or receipt.
    func testDiagnoseRetainedColdProofArchives() throws {
        guard let runID = LiveRailPersistenceProof.requestedRunID else {
            throw XCTSkip("Set TRAIN_TRACKER_LIVE_COLD_PROOF_RUN to inspect a retained failed run")
        }
        guard runID.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw LiveFlowFailure("Invalid diagnostic run identifier")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
        let directory = support.appending(path: "LiveRailPersistenceProof").appending(path: runID)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["DIAGNOSTIC ONLY: run=\(runID), receipts=\(files.count), readerPID=\(ProcessInfo.processInfo.processIdentifier)"]
        func fingerprint(_ data: Data?) -> String {
            guard let data else { return "missing" }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "bytes=\(data.count), sha256=\(hash)"
        }
        for file in files {
            let receipt = try JSONDecoder().decode(LiveRailPersistenceProof.Receipt.self, from: Data(contentsOf: file))
            let defaults = try XCTUnwrap(UserDefaults(suiteName: receipt.suite))
            let domain = defaults.persistentDomain(forName: receipt.suite) ?? [:]
            lines.append("seed=\(receipt.seed), suite=\(receipt.suite), writerPID=\(receipt.writerPID), domainKeys=\(domain.keys.sorted())")
            for key in ["savedTrips", "savedJourneyPlans"] {
                let expected = receipt.archives[key]
                let direct = defaults.data(forKey: key)
                let domainData = domain[key] as? Data
                lines.append("\(key): expected[\(fingerprint(expected))], dataForKey[\(fingerprint(direct))], persistentDomain[\(fingerprint(domainData))]")
                if key == "savedTrips", let direct, let expected {
                    let decoded = try? JSONDecoder().decode([TrainTrip].self, from: direct)
                    let expectedTrips = try? JSONDecoder().decode([TrainTrip].self, from: expected)
                    lines.append("decodedTripCount=\(decoded?.count ?? -1), decodedTripsEqual=\(decoded != nil && decoded == expectedTrips)")
                }
            }
            let checks = defaults.dictionary(forKey: "savedTrips.lastSuccessfulChecks") as? [String: Double]
            lines.append("checkCount=\(checks?.count ?? -1), exactChecksEqual=\(checks == receipt.checks)")
        }
        let diagnostic = lines.joined(separator: "\n")
        print(diagnostic)
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "Retained cold-app archive diagnostic (not a proof)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIncompleteRunCannotPassWithOnlyItsSuccessfulReceipts() {
        let previousMatrix = (0..<17).map { receipt(seed: "seed-\($0)", suite: "LiveImportTracking.suite-\($0)") }
        XCTAssertThrowsError(try LiveRailPersistenceProof.validateReceipts(previousMatrix, runID: "test-run",
                                                                          expectedCount: 18, readerPID: 2))
    }

    func testDuplicateSeedOrSuiteCannotSatisfyExpectedCount() {
        let first = receipt()
        let sameSeed = receipt(suite: "LiveImportTracking.second")
        let sameSuite = receipt(seed: "second")
        for receipts in [[first, sameSeed], [first, sameSuite]] {
            XCTAssertThrowsError(try LiveRailPersistenceProof.validateReceipts(receipts, runID: "test-run",
                                                                              expectedCount: 2, readerPID: 2))
        }
    }

    func testAnotherRunOrSameAppProcessCannotCountAsColdVerification() {
        XCTAssertThrowsError(try LiveRailPersistenceProof.validateReceipts([receipt()], runID: "other-run",
                                                                          expectedCount: 1, readerPID: 2))
        XCTAssertThrowsError(try LiveRailPersistenceProof.validateReceipts([receipt()], runID: "test-run",
                                                                          expectedCount: 1, readerPID: 1))
    }

    func testExactArchiveMismatchFailsAndPreservesSuiteForInvestigation() throws {
        let suite = "LiveImportTracking.ProofTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("changed".utf8), forKey: "savedTrips")
        defaults.set(Data("plans".utf8), forKey: "savedJourneyPlans")
        do {
            try LiveRailPersistenceProof.verifyReceipt(receipt(suite: suite))
            XCTFail("Changed archive bytes cannot pass the cold-app proof")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cold-app archive savedTrips differs"))
        }
        XCTAssertEqual(defaults.data(forKey: "savedTrips"), Data("changed".utf8))
    }

    func testMatchingArchivesCannotMaskChangedRefreshCheckTimes() throws {
        let suite = "LiveImportTracking.ProofTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = receipt(suite: suite)
        for (key, value) in expected.archives { defaults.set(value, forKey: key) }
        defaults.set(["trip": 124.0], forKey: "savedTrips.lastSuccessfulChecks")
        do {
            try LiveRailPersistenceProof.verifyReceipt(expected)
            XCTFail("Changed check times cannot pass the cold-app proof")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cold-app refresh checks differ"))
        }
    }

    func testMatchingPreferencesCannotMaskMissingOrChangedCanonicalFiles() throws {
        let suite = "LiveImportTracking.CanonicalProof.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runID = "canonical-proof-\(UUID())"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let runDirectory = support.appending(path: "LiveRailPersistenceProof").appending(path: runID)
        let vault = runDirectory.appending(path: "vaults/LiveImportTracking-fixture")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: runDirectory)
        }
        let base = receipt(suite: suite)
        var expected = LiveRailPersistenceProof.Receipt(
            runID: runID, seed: base.seed, suite: suite, writerPID: 1, archives: base.archives,
            checks: base.checks, vaultDirectoryName: base.vaultDirectoryName,
            ticketID: base.ticketID, planID: base.planID, payload: base.payload)
        expected.canonicalFiles = ["trips": Data("trip file".utf8), "plans": Data("plan file".utf8),
                                   "journal": Data("journal file".utf8)]
        install(expected, into: defaults)
        XCTAssertThrowsError(try LiveRailPersistenceProof.verifyReceipt(expected))
        let tripFile = LiveRailPersistenceProof.tripFile(in: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tripFile.path), "A missing canonical file must not be migrated during verification")

        try FileManager.default.createDirectory(at: tripFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try expected.canonicalFiles!["trips"]!.write(to: tripFile)
        try expected.canonicalFiles!["plans"]!.write(to: LiveRailPersistenceProof.planFile(in: vault))
        let journal = LiveRailPersistenceProof.planFile(in: vault).appendingPathExtension("journal")
        let changed = Data("changed journal".utf8)
        try changed.write(to: journal)
        XCTAssertThrowsError(try LiveRailPersistenceProof.verifyReceipt(expected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("canonical file bytes differ"))
        }
        XCTAssertEqual(try Data(contentsOf: journal), changed, "Failed verification must preserve evidence")
        XCTAssertEqual(defaults.data(forKey: "savedTrips"), base.archives["savedTrips"])
    }

    private func install(_ receipt: LiveRailPersistenceProof.Receipt, into defaults: UserDefaults) {
        for (key, value) in receipt.archives { defaults.set(value, forKey: key) }
        defaults.set(receipt.checks, forKey: "savedTrips.lastSuccessfulChecks")
    }

    private func receipt(seed: String = "first", suite: String = "LiveImportTracking.first") -> LiveRailPersistenceProof.Receipt {
        .init(runID: "test-run", seed: seed, suite: suite, writerPID: 1,
              archives: ["savedTrips": Data("trips".utf8), "savedJourneyPlans": Data("plans".utf8)],
              checks: ["trip": 123], vaultDirectoryName: "LiveImportTracking-fixture",
              ticketID: UUID(), planID: UUID(), payload: Data("ticket".utf8))
    }
}
