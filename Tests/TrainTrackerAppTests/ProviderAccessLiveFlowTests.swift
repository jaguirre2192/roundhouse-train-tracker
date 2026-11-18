import XCTest
@testable import TrainTracker

/// Synthetic tickets and real backend/provider requests; isolated archives, no push registration.
@MainActor
final class ProviderAccessLiveFlowTests: XCTestCase {
    func testLiveSwedenMalmoLund() async throws {
        try await ProviderAccessPersistenceProof.run(.init(
            label: "SE Malmö–Lund",
            origin: .init("Malmö C", "Malmö C", "SE", nativeID: "dk-rejseplanen_000007400003"),
            destination: .init("Lund C", "Lund C", "SE", nativeID: "dk-rejseplanen_000007400120")
        ), in: self)
    }

    func testLiveSloveniaLjubljanaMaribor() async throws {
        try await ProviderAccessPersistenceProof.run(.init(
            label: "SI Ljubljana–Maribor",
            origin: .init("Ljubljana", "Ljubljana", "SI",
                          nativeID: "at-Railway-Current-Reference-Data-2026_si:63:311:0:3"),
            destination: .init("Maribor", "Maribor", "SI",
                               nativeID: "at-Railway-Current-Reference-Data-2026_si:63:106:0:1")
        ), in: self)
    }

    func testLiveDenmarkCopenhagenOdense() async throws {
        try await ProviderAccessPersistenceProof.run(.init(
            label: "DK København–Odense",
            origin: .init("København H", "København H", "DK", nativeID: "de-DELFI_000008601309"),
            destination: .init("Odense", "Odense", "DK", nativeID: "se-Trafiklab_860000512")
        ), in: self)
    }

    func testLiveCrossBorderDenmarkSweden() async throws {
        try await ProviderAccessPersistenceProof.run(.init(
            label: "DK–SE København–Malmö",
            origin: .init("København H", "København H", "DK", nativeID: "de-DELFI_000008601309"),
            destination: .init("Malmö C", "Malmö C", "SE", nativeID: "dk-rejseplanen_000007400003")
        ), in: self)
    }
}

@MainActor
final class ProviderAccessColdPersistenceTests: XCTestCase {
    func testColdProcessVerifiesAllFourCountryRoutes() throws {
        let evidence = XCTAttachment(string: try ProviderAccessPersistenceProof.verifyColdProcess())
        evidence.name = "Provider access four-route cold-process proof"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
