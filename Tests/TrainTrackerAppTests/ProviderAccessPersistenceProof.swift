import Foundation
import XCTest

/// A separate four-route acceptance contract. The inherited 18-route proof keeps its defaults.
@MainActor
enum ProviderAccessPersistenceProof {
    static let requiredSeeds: Set<String> = [
        "SE Malmö–Lund", "SI Ljubljana–Maribor", "DK København–Odense", "DK–SE København–Malmö"
    ]

    static func configuredRunID() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_PROVIDER_ACCESS_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_PROVIDER_ACCESS_LIVE_TESTS=1 through run-provider-access-live-proof.py")
        }
        guard environment["RUN_LIVE_TRAIN_TRACKER_TESTS"] == "1",
              environment["TRAIN_TRACKER_LIVE_COLD_PROOF_RUN"] == nil,
              environment["TRAIN_TRACKER_PROVIDER_ACCESS_COUNTRIES"] == "SE,SI,DK",
              environment["TRAIN_TRACKER_PROVIDER_ACCESS_EXPECTED_COUNT"] == String(requiredSeeds.count),
              let runID = environment["TRAIN_TRACKER_PROVIDER_ACCESS_COLD_PROOF_RUN"],
              runID.range(of: "^provider-access-[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw LiveFlowFailure("Provider access proof requires its isolated run, SE/SI/DK matrix and exactly four routes")
        }
        return runID
    }

    static func run(_ seed: LiveRailSeed, in test: XCTestCase) async throws {
        _ = try configuredRunID()
        guard requiredSeeds.contains(seed.label) else {
            throw LiveFlowFailure("Provider access seed is outside the required matrix")
        }
        try await LiveImportTrackingFlow.run(seed, in: test)
    }

    static func verifyColdProcess() throws -> String {
        try LiveRailPersistenceProof.verifyRun(runID: configuredRunID(), expectedCount: requiredSeeds.count,
                                               expectedSeeds: requiredSeeds)
    }
}
