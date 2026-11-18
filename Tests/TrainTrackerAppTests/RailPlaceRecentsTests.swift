import Foundation
import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class RailPlaceRecentsTests: XCTestCase {
    @MainActor
    func testRecentsAreMostRecentFirstDeduplicatedByCanonicalIDAndCappedAtSix() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        for index in 0..<7 {
            context.recents.record(
                JourneySearchStoreFixtures.place(
                    id: "place-\(index)",
                    name: "Place \(index)"
                )
            )
        }
        context.recents.record(
            JourneySearchStoreFixtures.place(id: "place-3", name: "Updated Place 3")
        )

        XCTAssertEqual(context.recents.places.count, 6)
        XCTAssertEqual(context.recents.places.first?.displayName, "Updated Place 3")
        XCTAssertEqual(context.recents.places.filter { $0.id.rawValue == "place-3" }.count, 1)
        XCTAssertFalse(context.recents.places.contains { $0.id.rawValue == "place-0" })
    }

    @MainActor
    func testRecentsPersistOnDeviceAndReload() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.recents.record(JourneySearchStoreFixtures.paris)
        context.recents.record(JourneySearchStoreFixtures.amsterdam)

        let reloaded = RailPlaceRecents(defaults: context.defaults, key: context.key)

        XCTAssertEqual(reloaded.places, [
            JourneySearchStoreFixtures.amsterdam,
            JourneySearchStoreFixtures.paris,
        ])
    }

    @MainActor
    func testPersistedRecentsAreDeduplicatedBeforeCapAndRewritten() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let newestDuplicate = JourneySearchStoreFixtures.place(
            id: "duplicate",
            name: "Newest Duplicate"
        )
        let staleDuplicate = JourneySearchStoreFixtures.place(
            id: "duplicate",
            name: "Stale Duplicate"
        )
        let remaining = (1...5).map {
            JourneySearchStoreFixtures.place(id: "place-\($0)", name: "Place \($0)")
        }
        context.defaults.set(
            try JSONEncoder().encode([newestDuplicate, staleDuplicate] + remaining),
            forKey: context.key
        )

        let reloaded = RailPlaceRecents(defaults: context.defaults, key: context.key)

        XCTAssertEqual(reloaded.places.map(\.id.rawValue), [
            "duplicate", "place-1", "place-2", "place-3", "place-4", "place-5",
        ])
        XCTAssertEqual(reloaded.places.first?.displayName, "Newest Duplicate")
        let persistedData = try XCTUnwrap(context.defaults.data(forKey: context.key))
        let persisted = try JSONDecoder().decode([RailPlace].self, from: persistedData)
        XCTAssertEqual(persisted, reloaded.places)
    }

    @MainActor
    func testCorruptStoredRecentsLoadAsEmptyWithoutCrashing() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.defaults.set(Data("not-json".utf8), forKey: context.key)

        let reloaded = RailPlaceRecents(defaults: context.defaults, key: context.key)

        XCTAssertTrue(reloaded.places.isEmpty)
    }

    @MainActor
    func testClearRemovesMemoryAndPersistentRecents() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.recents.record(JourneySearchStoreFixtures.paris)

        context.recents.clear()

        XCTAssertTrue(context.recents.places.isEmpty)
        XCTAssertNil(context.defaults.object(forKey: context.key))
        XCTAssertTrue(RailPlaceRecents(defaults: context.defaults, key: context.key).places.isEmpty)
    }

    @MainActor
    private func makeContext() throws -> Context {
        let suiteName = "RailPlaceRecentsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "recentRailPlaces"
        return Context(
            recents: RailPlaceRecents(defaults: defaults, key: key),
            defaults: defaults,
            suiteName: suiteName,
            key: key
        )
    }

    @MainActor
    private struct Context {
        let recents: RailPlaceRecents
        let defaults: UserDefaults
        let suiteName: String
        let key: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
