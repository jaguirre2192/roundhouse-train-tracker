import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class PushRegistrationCoordinatorTests: XCTestCase {
    @MainActor
    func testRetryFinishesReenrollmentAfterAnOldRegistrationReturns() async throws {
        try await assertRetryFinishesReenrollment(staleRegistrationSucceeds: false)
    }

    @MainActor
    func testRetryFinishesReenrollmentAfterAnOldRegistrationSucceeds() async throws {
        try await assertRetryFinishesReenrollment(staleRegistrationSucceeds: true)
    }

    @MainActor
    private func assertRetryFinishesReenrollment(staleRegistrationSucceeds: Bool) async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredID = UUID()
        defaults.set(restoredID.uuidString, forKey: "pushInstallationID")
        let backend = RestoredInstallationPushBackend(
            rejectedID: restoredID, suspendRejectedRetry: true,
            staleRegistrationSucceeds: staleRegistrationSucceeds
        )
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60)
        )
        var warning: PushDeliveryWarningReason?
        coordinator.deliveryWarningHandler = { warning = $0.reason }
        let token = Data(repeating: 0xab, count: 32)
        coordinator.receivedDeviceToken(token)
        await JourneyPlanTestFixtures.waitUntil { warning == .backendSetupRejected }
        coordinator.receivedDeviceToken(token)
        for _ in 0..<100 {
            if await backend.registrationCount() >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        coordinator.retryDelivery()
        await backend.releaseRejectedRetry()
        for _ in 0..<100 {
            if let acceptedID = await backend.acceptedInstallationID(), acceptedID != restoredID { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let enrolledID = await backend.acceptedInstallationID()
        XCTAssertNotNil(enrolledID)
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), enrolledID?.uuidString)
        XCTAssertNil(warning)
    }

    @MainActor
    func testRetryReenrollsRejectedInstallationAndPreservesSavedTrip() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredID = UUID()
        defaults.set(restoredID.uuidString, forKey: "pushInstallationID")
        let backend = RestoredInstallationPushBackend(rejectedID: restoredID)
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {},
            retryDelay: .seconds(60)
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        coordinator.receivedDeviceToken(Data(repeating: 0xab, count: 32))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        coordinator.retryDelivery()
        for _ in 0..<100 {
            if await backend.watchedIDs().contains(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let watchedIDs = await backend.watchedIDs()
        XCTAssertEqual(watchedIDs, [trip.id])
        XCTAssertFalse(context.library.pushDeliveryWarning)
        XCTAssertTrue(context.library.containsTrip(id: trip.id))
        XCTAssertNotEqual(defaults.string(forKey: "pushInstallationID"), restoredID.uuidString)
        let acceptedID = await backend.acceptedInstallationID()
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), acceptedID?.uuidString)
    }

    @MainActor
    func testRejectedReenrollmentDoesNotKeepRotatingOnRetry() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredID = UUID()
        defaults.set(restoredID.uuidString, forKey: "pushInstallationID")
        let backend = RestoredInstallationPushBackend(rejectedID: restoredID, rejectAllEnrollment: true)
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60)
        )
        var warning: PushDeliveryWarningReason?
        coordinator.deliveryWarningHandler = { warning = $0.reason }
        coordinator.receivedDeviceToken(Data(repeating: 0xab, count: 32))
        await JourneyPlanTestFixtures.waitUntil { warning == .backendSetupRejected }
        coordinator.retryDelivery()
        for _ in 0..<100 {
            if await backend.registrationCount() >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let recoveryID = defaults.string(forKey: "pushInstallationID")
        XCTAssertNotEqual(recoveryID, restoredID.uuidString)

        coordinator.retryDelivery()
        for _ in 0..<100 {
            if await backend.registrationCount() >= 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), recoveryID)
        XCTAssertEqual(warning, .backendSetupRejected)
    }

    @MainActor
    func testSubscriptionRejectionDoesNotReplaceEnrolledIdentity() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let installedID = UUID()
        defaults.set(installedID.uuidString, forKey: "pushInstallationID")
        let backend = RestoredInstallationPushBackend(rejectedID: UUID(), rejectSubscriptions: true)
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60)
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        coordinator.receivedDeviceToken(Data(repeating: 0xab, count: 32))
        XCTAssertTrue(try context.library.storeTrackedTrip(JourneyPlanTestFixtures.makeTrips()[0]))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        coordinator.retryDelivery()
        for _ in 0..<100 {
            if await backend.registrationCount() >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), installedID.uuidString)
        XCTAssertTrue(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testUnwatchDuringInFlightSubscribeLeavesServerWatchInactive() async throws {
        let backend = SuspendingPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        await backend.waitUntilStarted(count: 1)

        XCTAssertTrue(context.library.removeTrip(id: trip.id))
        await backend.release(trip.id)
        for _ in 0..<100 {
            if await backend.unsubscribedIDs().contains(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let isActive = await backend.isActive(trip.id)
        let unsubscribedIDs = await backend.unsubscribedIDs()
        XCTAssertFalse(isActive)
        XCTAssertEqual(unsubscribedIDs, [trip.id])
    }

    @MainActor
    func testUnsubscribeRejectionDoesNotReplaceEnrolledIdentity() async throws {
        let suite = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installedID = UUID()
        defaults.set(installedID.uuidString, forKey: "pushInstallationID")
        let backend = RestoredInstallationPushBackend(rejectedID: UUID(), rejectUnsubscriptions: true)
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60)
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        coordinator.receivedDeviceToken(Data(repeating: 0xab, count: 32))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        for _ in 0..<100 {
            if await backend.watchedIDs().contains(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(context.library.removeTrip(id: trip.id))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }
        coordinator.retryDelivery()
        for _ in 0..<100 {
            if await backend.registrationCount() >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), installedID.uuidString)
        XCTAssertTrue(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testRewatchDuringInFlightSubscribeConvergesToActiveServerWatch() async throws {
        let backend = SuspendingPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        await backend.waitUntilStarted(count: 1)

        XCTAssertTrue(context.library.removeTrip(id: trip.id))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        coordinator.registrationFailed(JourneyPlanTestFixtures.TestFailure())
        XCTAssertTrue(context.library.pushDeliveryWarning)
        await backend.release(trip.id)
        await backend.waitUntilStarted(count: 2)
        await backend.release(trip.id)
        await JourneyPlanTestFixtures.waitUntil { !context.library.pushDeliveryWarning }

        let isActive = await backend.isActive(trip.id)
        let unsubscribedIDs = await backend.unsubscribedIDs()
        XCTAssertTrue(isActive)
        XCTAssertEqual(unsubscribedIDs, [trip.id])
    }

    @MainActor
    func testFailedUnwatchSurvivesRestartAndRetriesWithoutDeviceToken() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backend = TestPushBackend()
        let firstCoordinator = PushRegistrationCoordinator(
            backend: backend,
            defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {},
            retryDelay: .seconds(60)
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(
            pushCoordinator: firstCoordinator
        )
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        firstCoordinator.receivedDeviceToken(Data([1, 2, 3]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        for _ in 0..<100 {
            if await backend.isActive(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await backend.setUnsubscriptionFailure(true)
        XCTAssertTrue(context.library.removeTrip(id: trip.id))
        await JourneyPlanTestFixtures.waitUntil { context.library.pushDeliveryWarning }

        await backend.setUnsubscriptionFailure(false)
        let relaunchedCoordinator = PushRegistrationCoordinator(
            backend: backend,
            defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        relaunchedCoordinator.connect()
        for _ in 0..<100 {
            if !(await backend.isActive(trip.id)) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let isActive = await backend.isActive(trip.id)
        let unsubscribedIDs = await backend.unsubscribedIDs()
        XCTAssertFalse(isActive)
        XCTAssertEqual(unsubscribedIDs, [trip.id])
    }

    @MainActor
    func testNewDeviceTokenArrivingDuringRegistrationIsNotLost() async throws {
        let backend = SuspendingDeviceRegistrationBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let firstToken = Data([1, 2, 3])
        let secondToken = Data([4, 5, 6])
        var hasWarning = true
        coordinator.deliveryWarningHandler = { hasWarning = $0.hasWarning }

        coordinator.receivedDeviceToken(firstToken)
        await backend.waitUntilStarted(count: 1)
        coordinator.receivedDeviceToken(secondToken)
        await backend.release(firstToken)
        await backend.waitUntilStarted(count: 2)
        await backend.release(secondToken)
        await JourneyPlanTestFixtures.waitUntil { !hasWarning }

        let completedTokens = await backend.completedRegistrationTokens()
        XCTAssertEqual(completedTokens, [firstToken, secondToken])
    }

    @MainActor
    func testTokenRegistrationRetriesAutomaticallyAndClearsWarning() async throws {
        let backend = TestPushBackend()
        await backend.setFailures(registration: true, subscription: false)
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {},
            retryDelay: .milliseconds(10)
        )
        var hasWarning = false
        coordinator.deliveryWarningHandler = { hasWarning = $0.hasWarning }

        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        await JourneyPlanTestFixtures.waitUntil { hasWarning }
        await backend.setFailures(registration: false, subscription: false)
        await JourneyPlanTestFixtures.waitUntil { !hasWarning }

        let registeredTokens = await backend.registeredTokens()
        XCTAssertEqual(registeredTokens, [Data([1, 2, 3])])
    }

    @MainActor
    func testUnwatchWithRegisteredTokenDoesNotRegisterDeviceAgain() async throws {
        let backend = TestPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend,
            authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        let token = Data([1, 2, 3])
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        coordinator.receivedDeviceToken(token)
        for _ in 0..<100 {
            if await backend.registeredTokens().count == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        for _ in 0..<100 {
            if await backend.isActive(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(context.library.removeTrip(id: trip.id))
        for _ in 0..<100 {
            if await backend.unsubscribedIDs().contains(trip.id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let registeredTokens = await backend.registeredTokens()
        XCTAssertEqual(registeredTokens, [token])
        XCTAssertFalse(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testRejectedTrainIsSkippedAndRemainingTrainsStillSubscribe() async throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let backend = ScriptedPushBackend(rejections: [trips[0].id: .quotaExceeded])
        let coordinator = PushRegistrationCoordinator(
            backend: backend, authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60),
            selectedSegment: { _ in nil }, liveActivities: FakeLiveActivityInstallation()
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(pushCoordinator: coordinator)
        defer { context.cleanup() }
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trips[0]))
        XCTAssertTrue(try context.library.storeTrackedTrip(trips[1]))
        await JourneyPlanTestFixtures.waitUntil {
            context.library.pushAlertRejections[trips[0].id] == .quotaExceeded
        }
        for _ in 0..<100 {
            if await backend.subscribedTripIDs().contains(trips[1].id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let subscribed = await backend.subscribedTripIDs()
        XCTAssertTrue(subscribed.contains(trips[1].id))
        XCTAssertEqual(coordinator.tripAlertRejections, [trips[0].id: .quotaExceeded])
        XCTAssertFalse(context.library.pushDeliveryWarning)
    }

    @MainActor
    func testWatchFollowsSelectedLegAndResendsWhenTheLegChanges() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let stops = trip.stopTimes
        var segment = Self.segment(trip: trip, from: stops[1].station, to: stops[3].station)
        let backend = ScriptedPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults, authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60),
            selectedSegment: { _ in segment }, liveActivities: FakeLiveActivityInstallation()
        )
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        coordinator.watch(trip)
        await backend.waitForSubscriptions(1)
        try? await Task.sleep(for: .milliseconds(50))
        coordinator.watch(trip)
        segment = Self.segment(trip: trip, from: stops[2].station, to: stops[3].station)
        coordinator.watch(trip)
        await backend.waitForSubscriptions(2)

        let ranges = await backend.subscribedRanges()
        XCTAssertEqual(ranges.map(\.0), [stops[1].station.id, stops[2].station.id])
        XCTAssertEqual(ranges.map(\.1), [stops[3].station.id, stops[3].station.id])
        // The first watch retires a possible whole-train watch; the change retires the old leg.
        let unsubscribed = await backend.unsubscribedTripIDs()
        XCTAssertEqual(unsubscribed, [trip.id, trip.id])
    }

    @MainActor
    func testDefaultPassengerLookupReadsUpdatedCanonicalArchiveInsteadOfLegacyPreferences() async throws {
        let suite = "PushCanonicalArchive.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let stops = trip.stopTimes
        let planID = UUID()
        func plan(from: Int, to: Int) -> TrackedJourneyPlan {
            let segment = Self.segment(trip: trip, from: stops[from].station, to: stops[to].station)
            return TrackedJourneyPlan(
                id: planID, createdAt: trip.serviceDate, origin: segment.from, destination: segment.to,
                outbound: JourneyPlanDirection(fingerprint: "canonical-passenger", departure: trip.serviceDate,
                    arrival: trip.serviceDate.addingTimeInterval(3600), childTripIDs: [trip.id], selectedSegments: [segment]),
                returnDirection: nil, preExistingChildTripIDs: [])
        }
        let legacy = JourneyPlanArchive(defaults: defaults)
        try legacy.save([plan(from: 0, to: 3)])
        let archive = JourneyPlanArchive(defaults: defaults, fileURL: directory.appending(path: "plans.plist"))
        XCTAssertEqual(try archive.load(), try legacy.load())
        let backend = ScriptedPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend, defaults: defaults, authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, retryDelay: .seconds(60),
            liveActivities: FakeLiveActivityInstallation(), planArchive: archive)
        // An unreadable canonical archive must not fall back to legacy or a whole-route watch.
        let file = directory.appending(path: "plans.plist")
        let preserved = try Data(contentsOf: file)
        try Data("unreadable canonical plans".utf8).write(to: file, options: .atomic)
        var warning: PushDeliveryWarningReason?
        coordinator.deliveryWarningHandler = { warning = $0.reason }
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        coordinator.watch(trip)
        await JourneyPlanTestFixtures.waitUntil { warning != nil }
        let premature = await backend.subscribedTripIDs()
        XCTAssertTrue(premature.isEmpty)
        XCTAssertEqual(warning, .backendSynchronizationFailed)

        // Read at send time, after coordinator construction; legacy deliberately remains different.
        try preserved.write(to: file, options: .atomic)
        try archive.save([plan(from: 1, to: 2)])
        coordinator.retryDelivery()
        await backend.waitForSubscriptions(1)
        let ranges = await backend.subscribedRanges()
        XCTAssertEqual(ranges.map(\.0), [stops[1].station.id])
        XCTAssertEqual(ranges.map(\.1), [stops[2].station.id])
        XCTAssertEqual(try legacy.load(), [plan(from: 0, to: 3)])
    }

    @MainActor
    func testLiveActivityRejectionReplacesInstallationOnceWithoutDeviceToken() throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredID = UUID()
        defaults.set(restoredID.uuidString, forKey: "pushInstallationID")
        let liveActivities = FakeLiveActivityInstallation()
        let coordinator = PushRegistrationCoordinator(
            backend: ScriptedPushBackend(), defaults: defaults,
            authorizer: TestPushAuthorizer(status: .denied), registerForRemoteNotifications: {},
            liveActivities: liveActivities
        )
        coordinator.connect()

        liveActivities.installationRejectionHandler?()
        let replacementID = defaults.string(forKey: "pushInstallationID")
        liveActivities.installationRejectionHandler?()

        XCTAssertNotEqual(replacementID, restoredID.uuidString)
        XCTAssertEqual(defaults.string(forKey: "pushInstallationID"), replacementID)
        XCTAssertEqual(liveActivities.replacementCount, 1)
    }

    @MainActor
    func testRetryReplacementMovesLiveActivitiesInsteadOfEndingThem() async throws {
        let suiteName = "PushRegistrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredID = UUID()
        defaults.set(restoredID.uuidString, forKey: "pushInstallationID")
        let liveActivities = FakeLiveActivityInstallation()
        let coordinator = PushRegistrationCoordinator(
            backend: RestoredInstallationPushBackend(rejectedID: restoredID), defaults: defaults,
            authorizer: TestPushAuthorizer(status: .authorized), registerForRemoteNotifications: {},
            retryDelay: .seconds(60), liveActivities: liveActivities
        )
        var warning: PushDeliveryWarningReason?
        coordinator.deliveryWarningHandler = { warning = $0.reason }
        coordinator.receivedDeviceToken(Data(repeating: 0xab, count: 32))
        await JourneyPlanTestFixtures.waitUntil { warning == .backendSetupRejected }
        coordinator.retryDelivery()
        XCTAssertEqual(liveActivities.replacementCount, 1)
    }

    @MainActor
    func testDeviceRegistrationUsesConfiguredAPNsEnvironment() async throws {
        let backend = ScriptedPushBackend()
        let coordinator = PushRegistrationCoordinator(
            backend: backend, authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, environment: .production,
            liveActivities: FakeLiveActivityInstallation()
        )
        coordinator.receivedDeviceToken(Data([1, 2, 3]))
        for _ in 0..<100 {
            if await !backend.environments().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let environments = await backend.environments()
        XCTAssertEqual(environments, [.production])
        XCTAssertEqual(PushBackendClient.Environment.configured.rawValue, LiveActivityBackendClient.pushEnvironment)
        XCTAssertEqual(TrainTrackerBackendConfiguration.apnsEnvironment(infoPlistValue: "production"), "production")
        XCTAssertEqual(TrainTrackerBackendConfiguration.apnsEnvironment(infoPlistValue: "sandbox"), "sandbox")
    }

    @MainActor
    func testBridgeDeliversRegistrationFailureThatArrivedBeforeConnect() {
        let bridge = PushRegistrationBridge()
        let coordinator = PushRegistrationCoordinator(
            backend: ScriptedPushBackend(), authorizer: TestPushAuthorizer(status: .authorized),
            registerForRemoteNotifications: {}, liveActivities: FakeLiveActivityInstallation()
        )
        var warning: PushDeliveryWarningReason?
        coordinator.deliveryWarningHandler = { warning = $0.reason }
        bridge.fail(JourneyPlanTestFixtures.TestFailure())
        bridge.connect(coordinator)
        XCTAssertEqual(warning, .remoteRegistrationFailed)
    }

    private static func segment(trip: TrainTrip, from: Station, to: Station) -> JourneyPlanSegment {
        func place(_ station: Station) -> RailPlace {
            RailPlace(
                id: station.id, kind: .station, displayName: station.displayName, context: "",
                countryCode: station.countryCode, timeZoneIdentifier: "Europe/Paris",
                location: station.location, eligibleModes: [], attributions: []
            )
        }
        return JourneyPlanSegment(id: "leg", kind: .rail, from: place(from), to: place(to), resolvedTripID: trip.id)
    }
}

@MainActor
private final class FakeLiveActivityInstallation: LiveActivityInstallationHandling {
    var installationRejectionHandler: (() -> Void)?
    private(set) var replacementCount = 0
    func installationWasReplaced() { replacementCount += 1 }
}

private actor ScriptedPushBackend: PushBackendServing {
    nonisolated let isConfigured = true
    private let rejections: [RailIdentifier: PushTripAlertRejection]
    private var subscriptions: [PushBackendClient.TripWatchRequest] = []
    private var unsubscriptions: [RailIdentifier] = []
    private var registeredEnvironments: [PushBackendClient.Environment] = []

    init(rejections: [RailIdentifier: PushTripAlertRejection] = [:]) {
        self.rejections = rejections
    }

    func registerDevice(
        token: Data, installationID: UUID,
        environment: PushBackendClient.Environment, platform: PushBackendClient.Platform
    ) async throws {
        registeredEnvironments.append(environment)
    }

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {
        if let rejection = rejections[request.trip.id] {
            throw PushBackendClient.ClientError.tripRejected(rejection)
        }
        subscriptions.append(request)
    }

    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
        unsubscriptions.append(tripID)
    }

    func waitForSubscriptions(_ count: Int) async {
        for _ in 0..<200 where subscriptions.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func subscribedTripIDs() -> [RailIdentifier] { subscriptions.map(\.trip.id) }
    func subscribedRanges() -> [(RailIdentifier?, RailIdentifier?)] {
        subscriptions.map { ($0.boardingStationID, $0.alightingStationID) }
    }
    func unsubscribedTripIDs() -> [RailIdentifier] { unsubscriptions }
    func environments() -> [PushBackendClient.Environment] { registeredEnvironments }
}

private actor RestoredInstallationPushBackend: PushBackendServing {
    nonisolated let isConfigured = true
    private let rejectedID: UUID
    private let rejectAllEnrollment: Bool
    private let rejectSubscriptions: Bool
    private let rejectUnsubscriptions: Bool
    private let suspendRejectedRetry: Bool
    private let staleRegistrationSucceeds: Bool
    private var acceptedID: UUID?
    private var watches: [RailIdentifier] = []
    private var registrations = 0
    private var rejectedRetryContinuation: CheckedContinuation<Void, Never>?

    init(
        rejectedID: UUID, rejectAllEnrollment: Bool = false,
        rejectSubscriptions: Bool = false, suspendRejectedRetry: Bool = false,
        staleRegistrationSucceeds: Bool = false, rejectUnsubscriptions: Bool = false
    ) {
        self.rejectedID = rejectedID
        self.rejectAllEnrollment = rejectAllEnrollment
        self.rejectSubscriptions = rejectSubscriptions
        self.rejectUnsubscriptions = rejectUnsubscriptions
        self.suspendRejectedRetry = suspendRejectedRetry
        self.staleRegistrationSucceeds = staleRegistrationSucceeds
    }

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws {
        registrations += 1
        if installationID == rejectedID, registrations == 2, suspendRejectedRetry {
            await withCheckedContinuation { rejectedRetryContinuation = $0 }
            if staleRegistrationSucceeds {
                acceptedID = installationID
                return
            }
        }
        guard installationID != rejectedID, !rejectAllEnrollment else {
            throw PushBackendClient.ClientError.rejected(401)
        }
        acceptedID = installationID
    }

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {
        guard request.installationID == acceptedID, !rejectSubscriptions else {
            throw PushBackendClient.ClientError.rejected(401)
        }
        watches.append(request.trip.id)
    }

    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
        guard installationID == acceptedID, !rejectUnsubscriptions else {
            throw PushBackendClient.ClientError.rejected(401)
        }
        watches.removeAll { $0 == tripID }
    }

    func watchedIDs() -> [RailIdentifier] { watches }
    func acceptedInstallationID() -> UUID? { acceptedID }
    func registrationCount() -> Int { registrations }
    func releaseRejectedRetry() {
        rejectedRetryContinuation?.resume()
        rejectedRetryContinuation = nil
    }
}
