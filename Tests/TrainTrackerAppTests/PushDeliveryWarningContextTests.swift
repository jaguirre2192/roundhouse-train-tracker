import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class PushDeliveryWarningContextTests: XCTestCase {
    @MainActor
    func testFailureBeforeFollowingAnyTrainIsDeviceSetupAndStaysVisible() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }

        context.push.reportDeliveryWarning(true)

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .deviceSetup)
        XCTAssertTrue(context.library.trips.isEmpty)
        XCTAssertTrue(context.push.watchedTripIDs.isEmpty)
        let notice = presentation(context.library)
        XCTAssertEqual(notice.title, "Notification setup needs attention")
        XCTAssertTrue(notice.message.contains("hasn’t reached"))
        XCTAssertFalse(notice.message.contains("tracked"))
        XCTAssertEqual(notice.action, .retry)
    }

    @MainActor
    func testFailureForRemovedTrainDescribesPreviousAlertsWithoutInventingRemoval() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        context.push.reportDeliveryWarning(true, affectedTripIDs: [JourneyPlanTestFixtures.makeTrips()[0].id])

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .previousTrains)
        let notice = presentation(context.library)
        XCTAssertEqual(notice.title, "Previous train alerts need attention")
        XCTAssertTrue(notice.message.contains("trains you no longer follow"))
        XCTAssertTrue(notice.message.contains("hasn’t reached"))
        XCTAssertFalse(notice.message.contains("still tracked"))
        XCTAssertFalse(notice.message.contains("remove"))
        XCTAssertEqual(notice.action, .retry)
        XCTAssertTrue(notice.accessibilityHint.contains("previous trains"))
    }

    @MainActor
    func testSavedAndRemovedTrainFailuresStillWarnForSavedTrains() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0]])
        defer { context.cleanup() }
        context.push.reportDeliveryWarning(true, affectedTripIDs: Set(trips.map(\.id)))

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .savedTrains)
        XCTAssertTrue(presentation(context.library).message.contains("Your saved trains are still tracked"))
    }

    @MainActor
    func testGeneralDeviceFailureStillAppliesToSavedTrains() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: JourneyPlanTestFixtures.makeTrips())
        defer { context.cleanup() }
        context.push.reportDeliveryWarning(true, reason: .remoteRegistrationFailed)

        XCTAssertEqual(context.library.pushDeliveryWarningContext, .savedTrains)
        XCTAssertEqual(presentation(context.library).title, "Train alerts couldn’t connect")
    }

    @MainActor
    func testHistoricalSavedTrainFailureIsQualifiedAndNeverHidden() throws {
        let date = Date(timeIntervalSince1970: 1_794_960_000)
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip], now: { date })
        defer { context.cleanup() }
        XCTAssertFalse(context.library.hasRefreshableTrips)
        context.push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .savedTrains)
        XCTAssertTrue(presentation(context.library).message.contains("saved trains"))
    }

    @MainActor
    func testRemovingAffectedTrainUpdatesScopeWithoutClearingRealFailure() throws {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip])
        defer { context.cleanup() }
        context.push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .savedTrains)

        XCTAssertTrue(context.library.removeTrip(id: trip.id))

        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertEqual(context.library.pushDeliveryWarningReason, .backendSynchronizationFailed)
        XCTAssertEqual(context.library.pushDeliveryWarningContext, .previousTrains)
        context.push.reportDeliveryWarning(false)
        XCTAssertFalse(context.library.pushDeliveryWarning)
        XCTAssertNil(context.library.pushDeliveryWarningReason)
    }

    @MainActor
    func testUnreadableArchiveDoesNotMislabelUnknownTrainsAsRemoved() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        context.defaults.set(Data("unreadable archive".utf8), forKey: "savedTrips")
        let library = TripLibrary(pushCoordinator: context.push, archive: context.archive, automaticRefreshEnabled: false)
        XCTAssertTrue(library.tripArchiveRecoveryRequired)
        context.push.reportDeliveryWarning(true, affectedTripIDs: [JourneyPlanTestFixtures.makeTrips()[0].id])

        XCTAssertTrue(library.pushDeliveryWarning)
        XCTAssertTrue(library.tripArchiveRecoveryRequired)
        XCTAssertEqual(library.pushDeliveryWarningContext, .deviceSetup)
        XCTAssertFalse(presentation(library).message.contains("no longer follow"))
        XCTAssertFalse(try library.preservedTripArchiveRecoveryPayload().isEmpty)
    }

    func testEveryContextKeepsTheFailureReasonAndRecoveryAction() {
        let failures: [(PushDeliveryWarningReason, String)] = [
            (.authorizationDenied, "Turn on notifications in Settings"),
            (.authorizationFailed, "couldn’t verify notification access"),
            (.remoteRegistrationFailed, "iPhone Duo couldn’t register"),
            (.backendSynchronizationFailed, "hasn’t reached Roundhouse’s service"),
            (.backendSetupRejected, "couldn't accept the alert setup"),
            (.backendRateLimited, "will retry automatically"),
        ]
        for scope in [PushDeliveryWarningContext.savedTrains, .previousTrains, .deviceSetup] {
            for (reason, explanation) in failures {
                let notice = PushDeliveryWarningPresentation(reason: reason, deviceName: "iPhone Duo", context: scope)
                XCTAssertTrue(notice.message.contains(explanation), "\(scope), \(reason)")
                XCTAssertEqual(notice.action, reason == .authorizationDenied ? .openNotificationSettings : .retry)
                XCTAssertEqual(notice.actionTitle, reason == .authorizationDenied ? "Open Notification Settings" : "Try Again")
                XCTAssertFalse(notice.message.contains("restored"))
                XCTAssertFalse(notice.message.contains("Your journey is saved"))
            }
        }
    }

    @MainActor
    private func presentation(_ library: TripLibrary) -> PushDeliveryWarningPresentation {
        PushDeliveryWarningPresentation(
            reason: library.pushDeliveryWarningReason, context: library.pushDeliveryWarningContext
        )
    }
}
