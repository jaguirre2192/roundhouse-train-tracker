import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class AtomicArchivePersistenceTests: XCTestCase {
    private let tripKey = "atomicTrips"
    private let planKey = "atomicPlans"
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testTripMigrationPreservesLegacyBytesAndCanonicalFileWinsThereafter() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let trips = JourneyPlanTestFixtures.makeTrips()
        let legacy = TripArchive(defaults: context.defaults, key: tripKey)
        try legacy.save([trips[0]], lastChecks: [trips[0].id: checkedAt])
        let original = try XCTUnwrap(context.defaults.data(forKey: tripKey))
        let archive = tripArchive(context)

        XCTAssertEqual(archive.load(), [trips[0]])
        XCTAssertEqual(archive.loadLastChecks(), [trips[0].id: checkedAt])
        XCTAssertEqual(context.defaults.data(forKey: tripKey), original)
        XCTAssertEqual(try archive.persistenceValues()[tripKey] as? Data, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.fileURL.path))

        try legacy.save([trips[1]], lastChecks: [:])
        let reopened = tripArchive(context)
        XCTAssertEqual(reopened.load(), [trips[0]], "A later defaults value cannot replace the migrated canonical archive")
        XCTAssertEqual(reopened.loadLastChecks(), [trips[0].id: checkedAt])
    }

    func testJourneyMigrationPreservesPlansAndJournalAsSeparateCanonicalComponents() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let plan = makePlan()
        let attempt = makeAttempt()
        let legacy = JourneyPlanArchive(defaults: context.defaults, key: planKey)
        try legacy.save([plan])
        try legacy.saveTrackingAttempts([attempt])
        let planBytes = try XCTUnwrap(context.defaults.data(forKey: planKey))
        let journalBytes = try XCTUnwrap(context.defaults.data(forKey: planKey + ".trackingAttempts"))
        let archive = planArchive(context)

        XCTAssertEqual(try archive.load(), [plan])
        XCTAssertEqual(try archive.loadTrackingAttempts(), [attempt])
        let canonical = try archive.persistenceValues()
        XCTAssertEqual(canonical[planKey] as? Data, planBytes)
        XCTAssertEqual(canonical[planKey + ".trackingAttempts"] as? Data, journalBytes)
        XCTAssertEqual(context.defaults.data(forKey: planKey), planBytes)
        XCTAssertEqual(context.defaults.data(forKey: planKey + ".trackingAttempts"), journalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.journalURL.path))

        try legacy.save([])
        try legacy.saveTrackingAttempts([])
        let reopened = planArchive(context)
        XCTAssertEqual(try reopened.load(), [plan])
        XCTAssertEqual(try reopened.loadTrackingAttempts(), [attempt])
    }

    func testResetTripContainerKeepsCanonicalEmptyAndCannotResurrectLegacy() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let legacy = TripArchive(defaults: context.defaults, key: tripKey)
        try legacy.save([trip], lastChecks: [trip.id: checkedAt])
        let legacyBytes = try XCTUnwrap(context.defaults.data(forKey: tripKey))
        let archive = tripArchive(context)
        XCTAssertEqual(archive.load(), [trip])
        let corrupt = Data("broken trip container".utf8)
        try corrupt.write(to: context.fileURL, options: .atomic)

        try archive.resetRecovery()

        let reopened = tripArchive(context)
        XCTAssertFalse(reopened.recoveryRequired)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertEqual(reopened.loadLastChecks(), [:])
        XCTAssertEqual(context.defaults.data(forKey: tripKey), legacyBytes)
        XCTAssertEqual(try backupPayloads(in: context, for: context.fileURL), [corrupt])
    }

    func testTwoTripInstancesReadFreshDiskBeforeUpdatingTheirOwnComponent() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let trips = JourneyPlanTestFixtures.makeTrips()
        let first = tripArchive(context)
        let second = tripArchive(context)
        XCTAssertTrue(first.load().isEmpty)
        XCTAssertTrue(second.load().isEmpty)
        try first.save([trips[0]], lastChecks: [trips[0].id: checkedAt])
        XCTAssertEqual(second.load(), [trips[0]])
        let later = checkedAt.addingTimeInterval(60)
        XCTAssertTrue(second.saveLastChecks([trips[0].id: later]))

        try first.saveOrThrow(Array(trips.prefix(2)))

        XCTAssertEqual(second.load(), Array(trips.prefix(2)))
        XCTAssertEqual(first.loadLastChecks(), [trips[0].id: later])
        let canonical = try first.persistenceValues()
        XCTAssertEqual(try JSONDecoder().decode([TrainTrip].self, from: XCTUnwrap(canonical[tripKey] as? Data)),
                       Array(trips.prefix(2)))
        XCTAssertEqual(canonical[tripKey + ".lastSuccessfulChecks"] as? [String: Double],
                       [trips[0].id.rawValue: later.timeIntervalSince1970])
    }

    func testCorruptTripContainerBlocksEveryWriteAndExportsOriginalBytes() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let corrupt = Data([0x00, 0xFF, 0x41, 0x52, 0x43])
        try corrupt.write(to: context.fileURL)
        let archive = tripArchive(context)

        XCTAssertTrue(archive.recoveryRequired)
        XCTAssertFalse(archive.storageUnavailable, "Readable corrupt bytes need recovery, not an unlock retry")
        XCTAssertThrowsError(try archive.save(JourneyPlanTestFixtures.makeTrips(), lastChecks: [:]))
        XCTAssertFalse(archive.saveLastChecks([:]))
        XCTAssertThrowsError(try archive.persistenceValues())
        XCTAssertEqual(try archive.preservedRecoveryPayload(), corrupt)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), corrupt)
    }

    func testCorruptPlanContainerResetPreservesHealthyJournalAndLegacyPlans() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let plan = makePlan()
        let attempt = makeAttempt()
        try JourneyPlanArchive(defaults: context.defaults, key: planKey).save([plan])
        let legacyBytes = try XCTUnwrap(context.defaults.data(forKey: planKey))
        let archive = planArchive(context)
        XCTAssertEqual(try archive.load(), [plan])
        try archive.saveTrackingAttempts([attempt])
        let journalBytes = try Data(contentsOf: context.journalURL)
        let corrupt = Data("corrupt plans plist".utf8)
        try corrupt.write(to: context.fileURL, options: .atomic)

        XCTAssertThrowsError(try archive.save([]))
        XCTAssertEqual(try archive.preservedRecoveryPayload(for: .plans), corrupt)
        try archive.resetRecoveryStorage(for: .plans)

        let reopened = planArchive(context)
        XCTAssertEqual(try reopened.load(), [])
        XCTAssertEqual(try reopened.loadTrackingAttempts(), [attempt])
        XCTAssertEqual(try Data(contentsOf: context.journalURL), journalBytes)
        XCTAssertEqual(context.defaults.data(forKey: planKey), legacyBytes)
        XCTAssertEqual(try backupPayloads(in: context, for: context.fileURL), [corrupt])
    }

    func testCorruptJournalContainerResetPreservesHealthyPlansAndLegacyJournal() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let plan = makePlan()
        let attempt = makeAttempt()
        let legacy = JourneyPlanArchive(defaults: context.defaults, key: planKey)
        try legacy.saveTrackingAttempts([attempt])
        let legacyBytes = try XCTUnwrap(context.defaults.data(forKey: planKey + ".trackingAttempts"))
        let archive = planArchive(context)
        try archive.save([plan])
        XCTAssertEqual(try archive.loadTrackingAttempts(), [attempt])
        let planBytes = try Data(contentsOf: context.fileURL)
        let corrupt = Data("corrupt journal plist".utf8)
        try corrupt.write(to: context.journalURL, options: .atomic)

        XCTAssertThrowsError(try archive.saveTrackingAttempts([]))
        XCTAssertEqual(try archive.preservedRecoveryPayload(for: .transactionJournal), corrupt)
        try archive.resetRecoveryStorage(for: .transactionJournal)

        let reopened = planArchive(context)
        XCTAssertEqual(try reopened.load(), [plan])
        XCTAssertEqual(try reopened.loadTrackingAttempts(), [])
        XCTAssertEqual(try Data(contentsOf: context.fileURL), planBytes)
        XCTAssertEqual(context.defaults.data(forKey: planKey + ".trackingAttempts"), legacyBytes)
        XCTAssertEqual(try backupPayloads(in: context, for: context.journalURL), [corrupt])
    }

    func testTwoJourneyInstancesPreserveTheOtherComponentWhenSaving() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let first = planArchive(context)
        let second = planArchive(context)
        let plan = makePlan()
        let attempt = makeAttempt()
        XCTAssertTrue(try second.load().isEmpty)
        XCTAssertTrue(try second.loadTrackingAttempts().isEmpty)
        try first.save([plan])
        try second.saveTrackingAttempts([attempt])
        XCTAssertEqual(try first.loadTrackingAttempts(), [attempt])
        XCTAssertEqual(try second.load(), [plan])

        try first.save([])

        XCTAssertEqual(try second.load(), [])
        XCTAssertEqual(try second.loadTrackingAttempts(), [attempt])
    }

    func testFailedAtomicTripReplacementPreservesSnapshotAndSuccessfulCheckTogether() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let trips = JourneyPlanTestFixtures.makeTrips()
        let archive = tripArchive(context)
        try archive.save([trips[0]], lastChecks: [trips[0].id: checkedAt])
        let original = try Data(contentsOf: context.fileURL)
        try context.makeReadOnly()
        defer { context.makeWritable() }

        XCTAssertThrowsError(try archive.save([trips[1]], lastChecks: [trips[1].id: checkedAt]))
        XCTAssertEqual(try Data(contentsOf: context.fileURL), original)
        XCTAssertEqual(tripArchive(context).load(), [trips[0]])
        XCTAssertEqual(tripArchive(context).loadLastChecks(), [trips[0].id: checkedAt])
    }

    func testFailedAtomicJourneyReplacementPreservesPlansAndJournal() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let plan = makePlan()
        let attempt = makeAttempt()
        let archive = planArchive(context)
        try archive.save([plan])
        try archive.saveTrackingAttempts([attempt])
        let planBytes = try Data(contentsOf: context.fileURL)
        let journalBytes = try Data(contentsOf: context.journalURL)
        try context.makeReadOnly()
        defer { context.makeWritable() }

        XCTAssertThrowsError(try archive.save([]))
        XCTAssertThrowsError(try archive.saveTrackingAttempts([]))
        XCTAssertEqual(try Data(contentsOf: context.fileURL), planBytes)
        XCTAssertEqual(try Data(contentsOf: context.journalURL), journalBytes)
        XCTAssertEqual(try planArchive(context).load(), [plan])
        XCTAssertEqual(try planArchive(context).loadTrackingAttempts(), [attempt])
    }

    func testUnavailableProtectedDataCannotCommitEmptyMigrationOrResetBeforeUnlock() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        try TripArchive(defaults: context.defaults, key: tripKey).save([trip], lastChecks: [trip.id: checkedAt])
        let legacyBytes = try XCTUnwrap(context.defaults.data(forKey: tripKey))
        let gate = ProtectedDataGate()
        let archive = TripArchive(defaults: context.defaults, key: tripKey, fileURL: context.fileURL,
                                  canReadLegacyData: { gate.isAvailable })

        XCTAssertTrue(archive.storageUnavailable)
        XCTAssertTrue(archive.load().isEmpty)
        XCTAssertThrowsError(try archive.save([], lastChecks: [:]))
        XCTAssertThrowsError(try archive.resetRecovery())
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.fileURL.path))
        XCTAssertEqual(context.defaults.data(forKey: tripKey), legacyBytes)

        gate.isAvailable = true
        XCTAssertEqual(try archive.retryRecovery(), [trip])
        XCTAssertFalse(archive.storageUnavailable)
        XCTAssertFalse(archive.recoveryRequired)
        XCTAssertEqual(archive.loadLastChecks(), [trip.id: checkedAt])
    }

    func testUnavailableProtectedPlanDataCannotMigrateOrResetEitherComponent() throws {
        let context = try Context()
        defer { context.cleanUp() }
        let plan = makePlan()
        let attempt = makeAttempt()
        let legacy = JourneyPlanArchive(defaults: context.defaults, key: planKey)
        try legacy.save([plan])
        try legacy.saveTrackingAttempts([attempt])
        let gate = ProtectedDataGate()
        let archive = JourneyPlanArchive(defaults: context.defaults, key: planKey, fileURL: context.fileURL,
                                         canReadLegacyData: { gate.isAvailable })

        XCTAssertThrowsError(try archive.load()) { XCTAssertEqual($0 as? JourneyPlanArchive.ArchiveError, .storageUnavailable) }
        XCTAssertThrowsError(try archive.loadTrackingAttempts()) { XCTAssertEqual($0 as? JourneyPlanArchive.ArchiveError, .storageUnavailable) }
        XCTAssertThrowsError(try archive.resetRecoveryStorage(for: .plans))
        XCTAssertThrowsError(try archive.resetRecoveryStorage(for: .transactionJournal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.journalURL.path))

        gate.isAvailable = true
        XCTAssertEqual(try archive.load(), [plan])
        XCTAssertEqual(try archive.loadTrackingAttempts(), [attempt])
        XCTAssertEqual(try legacy.load(), [plan])
        XCTAssertEqual(try legacy.loadTrackingAttempts(), [attempt])
    }

    private func tripArchive(_ context: Context) -> TripArchive {
        TripArchive(defaults: context.defaults, key: tripKey, fileURL: context.fileURL, canReadLegacyData: { true })
    }

    private func planArchive(_ context: Context) -> JourneyPlanArchive {
        JourneyPlanArchive(defaults: context.defaults, key: planKey, fileURL: context.fileURL, canReadLegacyData: { true })
    }

    private func makePlan() -> TrackedJourneyPlan {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        return TrackedJourneyPlan(
            id: UUID(), createdAt: checkedAt, origin: place(trip.stopTimes.first!.station),
            destination: place(trip.stopTimes.last!.station),
            outbound: JourneyPlanDirection(fingerprint: "atomic-test", departure: checkedAt,
                                           arrival: checkedAt.addingTimeInterval(3600), childTripIDs: [trip.id]),
            returnDirection: nil, preExistingChildTripIDs: []
        )
    }

    private func place(_ station: Station) -> RailPlace {
        RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "",
                  countryCode: station.countryCode, timeZoneIdentifier: "Europe/Paris", location: station.location,
                  eligibleModes: ["rail"], attributions: [])
    }

    private func makeAttempt() -> JourneyPlanTrackingAttempt {
        JourneyPlanTrackingAttempt(id: UUID(), insertedChildTripIDs: [JourneyPlanTestFixtures.makeTrips()[0].id],
                                   pendingInsertionChildTripID: nil, preExistingChildTripIDs: [])
    }

    private func backupPayloads(in context: Context, for file: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: context.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".recovery-") }
            .map { try Data(contentsOf: $0) }
    }

    @MainActor
    private final class ProtectedDataGate {
        var isAvailable = false
    }

    private struct Context {
        let suiteName: String
        let defaults: UserDefaults
        let directory: URL
        var fileURL: URL { directory.appendingPathComponent("archive.plist") }
        var journalURL: URL { fileURL.appendingPathExtension("journal") }

        init() throws {
            suiteName = "AtomicArchivePersistenceTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func makeReadOnly() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }

        func makeWritable() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        func cleanUp() {
            makeWritable()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
