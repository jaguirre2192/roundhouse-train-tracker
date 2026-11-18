import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanArchiveTests: XCTestCase {
    @MainActor
    func testVersionOneArchiveRoundTripsPlans() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let plans = [makePlan()]

        try context.archive.save(plans)

        XCTAssertEqual(try context.archive.load(), plans)
    }

    @MainActor
    func testAbsentArchiveLoadsAsEmpty() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        XCTAssertEqual(try context.archive.load(), [])
    }

    @MainActor
    func testUnsupportedVersionThrowsWithoutDeletingStoredBytes() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        try context.archive.save([makePlan()])
        let stored = try XCTUnwrap(context.defaults.data(forKey: context.key))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        object["version"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        context.defaults.set(unsupported, forKey: context.key)

        XCTAssertThrowsError(try context.archive.load()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .unsupportedVersion(2))
        }
        XCTAssertEqual(context.defaults.data(forKey: context.key), unsupported)
    }

    @MainActor
    func testUnsupportedVersionWinsOverUnknownFuturePayloadShape() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let future = Data(#"{"version":2,"plans":{"future":"shape"}}"#.utf8)
        context.defaults.set(future, forKey: context.key)

        XCTAssertThrowsError(try context.archive.load()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .unsupportedVersion(2))
        }
        XCTAssertEqual(context.defaults.data(forKey: context.key), future)
    }

    @MainActor
    func testCorruptArchiveThrowsWithoutDeletingStoredBytes() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let corrupt = Data("not-json".utf8)
        context.defaults.set(corrupt, forKey: context.key)

        XCTAssertThrowsError(try context.archive.load()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .corruptData)
        }
        XCTAssertEqual(context.defaults.data(forKey: context.key), corrupt)
    }

    @MainActor
    func testWrongTypedArchiveValueThrowsCorruptDataWithoutDeletingStoredValue() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set("not-data", forKey: context.key)

        XCTAssertThrowsError(try context.archive.load()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .corruptData)
        }
        XCTAssertEqual(context.defaults.string(forKey: context.key), "not-data")
    }

    @MainActor
    func testFutureTrackingAttemptShapeReportsUnsupportedVersionWithoutDeletingBytes() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let trackingKey = "\(context.key).trackingAttempts"
        let future = Data(#"{"version":2,"attempts":{"future":"shape"}}"#.utf8)
        context.defaults.set(future, forKey: trackingKey)

        XCTAssertThrowsError(try context.archive.loadTrackingAttempts()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .unsupportedVersion(2))
        }
        XCTAssertEqual(context.defaults.data(forKey: trackingKey), future)
    }

    @MainActor
    func testCorruptTrackingAttemptJournalThrowsWithoutDeletingBytes() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let trackingKey = "\(context.key).trackingAttempts"
        let corrupt = Data("not-json".utf8)
        context.defaults.set(corrupt, forKey: trackingKey)

        XCTAssertThrowsError(try context.archive.loadTrackingAttempts()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .corruptData)
        }
        XCTAssertEqual(context.defaults.data(forKey: trackingKey), corrupt)
    }

    @MainActor
    func testWrongTypedTrackingAttemptJournalThrowsWithoutDeletingValue() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let trackingKey = "\(context.key).trackingAttempts"
        context.defaults.set("not-data", forKey: trackingKey)

        XCTAssertThrowsError(try context.archive.loadTrackingAttempts()) { error in
            XCTAssertEqual(error as? JourneyPlanArchive.ArchiveError, .corruptData)
        }
        XCTAssertEqual(context.defaults.string(forKey: trackingKey), "not-data")
    }

    @MainActor
    func testEncodingFailureIsObservableAndDoesNotReplaceStoredPlans() throws {
        let context = try makeArchive()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let valid = [makePlan()]
        try context.archive.save(valid)
        let stored = try XCTUnwrap(context.defaults.data(forKey: context.key))
        let invalid = makePlan(origin: makePlace(name: "Invalid", latitude: .nan))

        XCTAssertThrowsError(try context.archive.save([invalid]))
        XCTAssertEqual(context.defaults.data(forKey: context.key), stored)
        XCTAssertEqual(try context.archive.load(), valid)
    }

    @MainActor
    private func makeArchive() throws -> (
        archive: JourneyPlanArchive,
        defaults: UserDefaults,
        suiteName: String,
        key: String
    ) {
        let suiteName = "JourneyPlanArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "journeyPlans"
        return (JourneyPlanArchive(defaults: defaults, key: key), defaults, suiteName, key)
    }

    private func makePlan(origin: RailPlace? = nil) -> TrackedJourneyPlan {
        let outboundID = RailIdentifier(rawValue: "eu:transitous:outbound")
        let returnID = RailIdentifier(rawValue: "eu:transitous:return")
        return TrackedJourneyPlan(
            id: UUID(uuidString: "B11ED8D7-B10C-4FEB-9CBB-A5D4C94B64B5")!,
            createdAt: Date(timeIntervalSince1970: 1_721_814_000),
            origin: origin ?? makePlace(name: "Paris", latitude: 48.8566),
            destination: makePlace(name: "Amsterdam", latitude: 52.3676),
            outbound: JourneyPlanDirection(
                fingerprint: "outbound-fingerprint",
                departure: Date(timeIntervalSince1970: 1_721_890_000),
                arrival: Date(timeIntervalSince1970: 1_721_930_000),
                childTripIDs: [outboundID]
            ),
            returnDirection: JourneyPlanDirection(
                fingerprint: "return-fingerprint",
                departure: Date(timeIntervalSince1970: 1_722_150_000),
                arrival: Date(timeIntervalSince1970: 1_722_190_000),
                childTripIDs: [returnID]
            ),
            preExistingChildTripIDs: [outboundID]
        )
    }

    private func makePlace(name: String, latitude: Double) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: "eu:transitous:\(name.lowercased())"),
            kind: .city,
            displayName: name,
            context: "All stations",
            countryCode: "FR",
            timeZoneIdentifier: "Europe/Paris",
            location: GeoCoordinate(latitude: latitude, longitude: 2.3522),
            eligibleModes: ["highSpeedRail"],
            attributions: ["Transitous"]
        )
    }
}
