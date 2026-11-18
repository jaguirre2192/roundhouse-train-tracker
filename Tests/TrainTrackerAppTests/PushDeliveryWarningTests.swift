import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class PushDeliveryWarningTests: XCTestCase {
    @MainActor
    func testPersistedUnwatchAdoptsLegacyDeviceBeforeUnsubscribing() async throws {
        let suiteName = "PushDeliveryWarningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripID = JourneyPlanTestFixtures.makeTrips()[0].id
        defaults.set(UUID().uuidString, forKey: "pushInstallationID")
        defaults.set([tripID.rawValue], forKey: "pushPendingUnwatchTripIDs")
        let registrationRequested = expectation(description: "APNs registration requested")
        let backend = LegacyAdoptionPushBackend()
        var warningEvents: [Bool] = []
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: { registrationRequested.fulfill() },
            retryDelay: .seconds(60)
        )
        coordinator.deliveryWarningHandler = { warningEvents.append($0.hasWarning) }

        coordinator.connect()
        await fulfillment(of: [registrationRequested], timeout: 1)
        coordinator.receivedDeviceToken(Data([1, 2, 3]))

        for _ in 0..<100 {
            if await backend.operations() == [.register, .unsubscribe(tripID)] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let operations = await backend.operations()
        XCTAssertEqual(operations, [.register, .unsubscribe(tripID)])
        XCTAssertNil(defaults.stringArray(forKey: "pushPendingUnwatchTripIDs"))
        XCTAssertEqual(warningEvents.last, false)
    }

    @MainActor
    func testPersistedUnwatchSurvivesRegistrationFailureAndClearsAfterRetry() async throws {
        let suiteName = "PushDeliveryWarningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tripID = JourneyPlanTestFixtures.makeTrips()[0].id
        defaults.set(UUID().uuidString, forKey: "pushInstallationID")
        defaults.set([tripID.rawValue], forKey: "pushPendingUnwatchTripIDs")
        let registrationRequested = expectation(description: "APNs registration requested")
        let backend = LegacyAdoptionPushBackend(registrationFailures: 1)
        var warningEvents: [Bool] = []
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: { registrationRequested.fulfill() },
            retryDelay: .milliseconds(100)
        )
        coordinator.deliveryWarningHandler = { warningEvents.append($0.hasWarning) }

        coordinator.connect()
        await fulfillment(of: [registrationRequested], timeout: 1)
        coordinator.receivedDeviceToken(Data([1, 2, 3]))

        for _ in 0..<100 {
            if await backend.operations().contains(.registrationFailed) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(defaults.stringArray(forKey: "pushPendingUnwatchTripIDs"), [tripID.rawValue])

        for _ in 0..<100 {
            if await backend.operations().suffix(2) == [.register, .unsubscribe(tripID)] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let operations = await backend.operations()
        XCTAssertEqual(
            Array(operations.suffix(3)),
            [.registrationFailed, .register, .unsubscribe(tripID)]
        )
        XCTAssertNil(defaults.stringArray(forKey: "pushPendingUnwatchTripIDs"))
        XCTAssertEqual(warningEvents.last, false)
    }

    @MainActor
    func testDeviceRegistrationUsesTheOnlyShippingIOSPlatform() async {
        let backend = TestPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        for _ in 0..<100 {
            if await backend.registeredPlatforms().count == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let registeredPlatforms = await backend.registeredPlatforms()
        XCTAssertEqual(registeredPlatforms, [.ios])
    }

    @MainActor
    func testSuccessfulJourneySaveIsNotRolledBackWhenPushSetupWarns() throws {
        let push = RecordingPushCoordinator()
        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        archive.onSave = { _ in
            XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
        }
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: archive
        )

        let plan = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        )

        XCTAssertEqual(planLibrary.plans, [plan])
        XCTAssertEqual(archive.storedPlans, [plan])
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertTrue(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testHistoricalPlanAndStandaloneTripFailureDoNotShowJourneySaveWarning() throws {
        let push = RecordingPushCoordinator()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let seededPlan = try RecordingJourneyPlanTracker().track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        )
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive(plans: [seededPlan])
        )
        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }

        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[1]))

        XCTAssertEqual(planLibrary.plans, [seededPlan])
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testHistoricalPlanAndGeneralAPNsFailureDoNotShowJourneySaveWarning() throws {
        let push = RecordingPushCoordinator()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let seededPlan = try RecordingJourneyPlanTracker().track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        )
        _ = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive(plans: [seededPlan])
        )

        push.reportDeliveryWarning(true)

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testFailedNewPlanArchiveNeverShowsJourneySaveWarningWithHistoricalPlan() throws {
        let push = RecordingPushCoordinator()
        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let seededPlan = try RecordingJourneyPlanTracker().track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[1]]
            )
        )
        let archive = RecordingJourneyPlanArchive(plans: [seededPlan])
        archive.shouldFailSave = true
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: archive
        )

        XCTAssertThrowsError(try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(id: UUID()),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        ))

        XCTAssertEqual(planLibrary.plans, [seededPlan])
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testStandaloneFailureAfterJourneyPushRecoveryDoesNotResurrectJourneyWarning() throws {
        let push = RecordingPushCoordinator()
        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        _ = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        )
        XCTAssertTrue(context.library.journeySavePushDeliveryWarning)

        push.reportDeliveryWarning(false)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)

        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[1]))
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testStandaloneFailureAfterCleanJourneySaveDoesNotCreateJourneyWarning() throws {
        let push = RecordingPushCoordinator()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        _ = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(
                outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
            )
        )
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)

        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }
        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[1]))

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testJourneyWarningClearsWhenCurrentFailuresContainOnlyStandaloneTrip() throws {
        let push = RecordingPushCoordinator()
        push.onWatch = { trip in
            push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        }
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: push)
        defer { context.cleanup() }
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: RecordingJourneyPlanArchive()
        )
        let trips = JourneyPlanTestFixtures.makeTrips()
        _ = try planLibrary.track(
            draft: JourneyPlanTestFixtures.makeDraft(),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [trips[0]])
        )
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertTrue(context.library.journeySavePushDeliveryWarning)

        push.onWatch = nil
        XCTAssertTrue(try context.library.storeTrackedTrip(trips[1]))
        push.reportDeliveryWarning(true, affectedTripIDs: [trips[1].id])

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertFalse(context.library.journeySavePushDeliveryWarning)
    }

    @MainActor
    func testDeniedAuthorizationSetsPushWarning() async throws {
        let coordinator = PushRegistrationCoordinator(
            backend: TestPushBackend(),
            authorizer: TestPushAuthorizer(status: .denied),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }

        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[0]))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningReason, .authorizationDenied)
    }

    @MainActor
    func testRegistrationFailureSetsPushWarning() throws {
        let coordinator = PushRegistrationCoordinator(
            backend: TestPushBackend(),
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }

        coordinator.registrationFailed(JourneyPlanTestFixtures.TestFailure())

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningReason, .remoteRegistrationFailed)
    }

    @MainActor
    func testBackendRegistrationFailureSetsWarningAndSuccessfulRetryClearsIt() async throws {
        let backend = TestPushBackend()
        await backend.setFailures(registration: true, subscription: false)
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[0]))

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        XCTAssertEqual(
            context.library.pushDeliveryWarningReason,
            .backendSynchronizationFailed
        )

        await backend.setFailures(registration: false, subscription: false)
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        await JourneyPlanTestFixtures.waitUntil { !context.library.pushDeliveryWarning }
        XCTAssertFalse(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testSubscriptionFailureSetsWarningAndLaterSuccessfulFlushClearsIt() async throws {
        let backend = TestPushBackend()
        await backend.setFailures(registration: false, subscription: true)
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        XCTAssertTrue(context.library.containsTrip(id: trip.id))

        await backend.setFailures(registration: false, subscription: false)
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        await JourneyPlanTestFixtures.waitUntil { !context.library.pushDeliveryWarning }
        XCTAssertFalse(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testWatchAddedDuringFlushIsDeliveredBeforeWarningClears() async throws {
        let backend = SuspendingPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trips = JourneyPlanTestFixtures.makeTrips()

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trips[0]))
        await backend.waitUntilStarted(count: 1)

        XCTAssertTrue(try context.library.storeTrackedTrip(trips[1]))
        coordinator.registrationFailed(JourneyPlanTestFixtures.TestFailure())
        XCTAssertTrue(context.library.pushDeliveryWarning)
        await backend.release(trips[0].id)

        for _ in 0..<100 {
            if await backend.startedIDs().count == 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await backend.startedIDs().count == 2 else {
            XCTFail("The watch queued during an in-flight flush was not started")
            return
        }
        XCTAssertTrue(context.library.pushDeliveryWarning)
        await backend.release(trips[1].id)
        for _ in 0..<100 {
            if await backend.completedIDs().count == 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let completedIDs = await backend.completedIDs()
        XCTAssertEqual(Set(completedIDs), Set(trips.map(\.id)))
        await JourneyPlanTestFixtures.waitUntil { !context.library.pushDeliveryWarning }
    }

}

private actor LegacyAdoptionPushBackend: PushBackendServing {
    enum Operation: Equatable {
        case registrationFailed
        case register
        case unsubscribe(RailIdentifier)
    }

    nonisolated let isConfigured = true
    private var isRegistered = false
    private var registrationFailures: Int
    private var recordedOperations: [Operation] = []

    init(registrationFailures: Int = 0) {
        self.registrationFailures = registrationFailures
    }

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws {
        if registrationFailures > 0 {
            registrationFailures -= 1
            recordedOperations.append(.registrationFailed)
            throw PushBackendClient.ClientError.rejected(503)
        }
        isRegistered = true
        recordedOperations.append(.register)
    }

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {}

    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
        guard isRegistered else { throw PushBackendClient.ClientError.rejected(401) }
        recordedOperations.append(.unsubscribe(tripID))
    }

    func operations() -> [Operation] { recordedOperations }
}
