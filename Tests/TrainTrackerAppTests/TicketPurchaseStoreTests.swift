import XCTest
import TrainTrackerCore
@testable import TrainTracker

@MainActor
final class TicketPurchaseStoreTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appending(path: "searches.json") }
    private let departure = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { departure.addingTimeInterval(-3_600) }

    override func setUp() async throws {
        folder = URL.temporaryDirectory.appending(path: "TicketPurchaseTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: folder) }

    func testSearchRoundTripsAcrossStoreRecreationWithoutClaimingPurchase() throws {
        let store = TicketPurchaseStore(fileURL: url)
        let journey = try makeJourney()
        let draft = try store.prepare(journey, at: now)
        let restored = TicketPurchaseStore(fileURL: url)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.drafts, [draft])
        XCTAssertEqual(restored.drafts.first?.journey, journey)
        let payload = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(payload.contains("preview-not-a-real-token"))
        XCTAssertFalse(payload.contains("purchased"))
    }

    func testRetryUpdatesSameDraftAndRetainsIndependentOneWaySearch() throws {
        let store = TicketPurchaseStore(fileURL: url)
        let roundTrip = try makeJourney()
        let first = try store.prepare(roundTrip, at: now)
        let oneWay = try store.prepare(makeJourney(roundTrip: false), at: now)
        let retry = try store.prepare(roundTrip, at: now.addingTimeInterval(60))
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(store.drafts.map(\.id), [first.id, oneWay.id])
        XCTAssertEqual(store.drafts.first?.openedAt, now.addingTimeInterval(60))
    }

    func testFailedWriteDoesNotReplaceExistingInMemoryDrafts() throws {
        let store = TicketPurchaseStore(fileURL: url)
        let first = try store.prepare(makeJourney(), at: now)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.prepare(makeJourney(roundTrip: false), at: now))
        XCTAssertEqual(store.drafts, [first])
    }

    func testCorruptAndFutureStorageArePreservedAndBlockOverwrite() throws {
        for payload in [Data("broken".utf8), Data(#"{"version":2,"drafts":[]}"#.utf8)] {
            try payload.write(to: url)
            let store = TicketPurchaseStore(fileURL: url)
            XCTAssertTrue(store.loadFailed)
            XCTAssertThrowsError(try store.prepare(makeJourney(), at: now))
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }
    }

    func testExplicitResetAffectsOnlyTicketSearchFile() throws {
        let tracked = folder.appending(path: "tracked-trips.json")
        let sentinel = Data("unrelated trips".utf8)
        try sentinel.write(to: tracked)
        try Data("broken".utf8).write(to: url)
        let store = TicketPurchaseStore(fileURL: url)
        try store.resetUnreadableSearches()
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(try Data(contentsOf: tracked), sentinel)
        XCTAssertNoThrow(try store.prepare(makeJourney(), at: now))
    }

    func testPastDepartureCannotOpenOrOverwriteSavedContext() throws {
        let store = TicketPurchaseStore(fileURL: url)
        let first = try store.prepare(makeJourney(), at: now)
        XCTAssertThrowsError(try store.prepare(makeJourney(), at: departure))
        XCTAssertEqual(store.drafts, [first])
    }

    func testRemovingOneSearchPreservesOthersOnDisk() throws {
        let store = TicketPurchaseStore(fileURL: url)
        let first = try store.prepare(makeJourney(), at: now)
        let remaining = try store.prepare(makeJourney(roundTrip: false), at: now)
        try store.remove(first.id)
        XCTAssertEqual(TicketPurchaseStore(fileURL: url).drafts, [remaining])
    }

    private func makeJourney(roundTrip: Bool = true) throws -> TicketPurchaseJourney {
        let fixture = TicketPurchasePreviewFixture(departure: departure)
        return try TicketPurchaseJourney(outbound: fixture.outbound, returnOption: roundTrip ? fixture.returning : nil)
    }
}
