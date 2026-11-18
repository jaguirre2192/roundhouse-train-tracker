import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanPresentationTests: XCTestCase {
    private let fixtureReferenceDate = Date(timeIntervalSince1970: 1_721_814_000)

    @MainActor
    func testPlanDatesAndEndpointTimesUseRouteLocalZonesInsteadOfDeviceZone() {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        let trips = JourneyPlanTestFixtures.makeTrips()
        let plan = makePlan(
            outboundIDs: [trips[0].id],
            returnIDs: [trips[1].id],
            outboundDeparture: date("2026-07-22T22:30:00Z"),
            outboundArrival: date("2026-07-23T01:00:00Z"),
            returnDeparture: date("2026-07-24T22:30:00Z"),
            returnArrival: date("2026-07-25T01:00:00Z"),
            originTimeZone: "Europe/Paris",
            destinationTimeZone: "Europe/Amsterdam"
        )

        let presentation = JourneyPlanPresentation(plan: plan, trips: trips)

        XCTAssertEqual(presentation.outboundDateText, "Thu, Jul 23")
        XCTAssertEqual(presentation.returnDateText, "Sat, Jul 25")
        XCTAssertEqual(presentation.directions[0].departureTimeText, localTime("12:30 AM", date("2026-07-22T22:30:00Z"), "Europe/Paris"))
        XCTAssertEqual(presentation.directions[0].arrivalTimeText, localTime("3:00 AM", date("2026-07-23T01:00:00Z"), "Europe/Amsterdam"))
        XCTAssertEqual(presentation.directions[0].departureTimeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(presentation.directions[0].arrivalTimeZoneIdentifier, "Europe/Amsterdam")
        XCTAssertEqual(presentation.directions[1].departureTimeText, localTime("12:30 AM", date("2026-07-24T22:30:00Z"), "Europe/Amsterdam"))
        XCTAssertEqual(presentation.directions[1].arrivalTimeText, localTime("3:00 AM", date("2026-07-25T01:00:00Z"), "Europe/Paris"))
        XCTAssertEqual(presentation.directions[1].departureTimeZoneIdentifier, "Europe/Amsterdam")
        XCTAssertEqual(presentation.directions[1].arrivalTimeZoneIdentifier, "Europe/Paris")
    }

    @MainActor
    func testNextActionableTimeUsesOwningReturnDirectionZone() {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        let trips = JourneyPlanTestFixtures.makeTrips()
        let completed = completedTrip(from: trips[0])
        let plan = makePlan(
            outboundIDs: [completed.id],
            returnIDs: [trips[1].id],
            originTimeZone: "Europe/Paris",
            destinationTimeZone: "Europe/Amsterdam"
        )

        let presentation = JourneyPlanPresentation(
            plan: plan,
            trips: [completed, trips[1]],
            at: fixtureReferenceDate.addingTimeInterval(4 * 3_600)
        )

        XCTAssertEqual(presentation.nextActionableTrip?.id, trips[1].id)
        XCTAssertEqual(presentation.nextActionableDirectionTitle, "Return")
        XCTAssertEqual(presentation.nextActionableTimeZoneIdentifier, "Europe/Amsterdam")
        XCTAssertEqual(presentation.nextActionableTimeText?.hasPrefix("12:55 PM"), true)
    }

    @MainActor
    func testOneWaySummaryShowsRouteDateNextTrainAndChildCount() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let plan = makePlan(outboundIDs: trips.map(\.id))

        let presentation = JourneyPlanPresentation(
            plan: plan,
            trips: trips,
            at: fixtureReferenceDate
        )

        XCTAssertEqual(presentation.routeTitle, "Paris → Amsterdam")
        XCTAssertEqual(presentation.outboundDate, plan.outbound.departure)
        XCTAssertNil(presentation.returnDate)
        XCTAssertEqual(presentation.childCountText, "2 trains")
        XCTAssertEqual(presentation.nextActionableTrip?.id, trips[0].id)
        XCTAssertEqual(presentation.directions.map(\.title), ["Outbound"])
    }

    @MainActor
    func testRoundTripSummaryShowsBothDatesAndDirections() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let plan = makePlan(
            outboundIDs: [trips[0].id],
            returnIDs: [trips[1].id]
        )

        let presentation = JourneyPlanPresentation(plan: plan, trips: trips)

        XCTAssertEqual(presentation.outboundDate, plan.outbound.departure)
        XCTAssertEqual(presentation.returnDate, plan.returnDirection?.departure)
        XCTAssertEqual(presentation.directions.map(\.title), ["Outbound", "Return"])
        XCTAssertEqual(
            presentation.directions.map(\.routeTitle),
            ["Paris → Amsterdam", "Amsterdam → Paris"]
        )
    }

    @MainActor
    func testNextActionableTrainSkipsMissingAndCompletedChildren() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let completed = completedTrip(from: trips[0])
        let missingID = RailIdentifier(rawValue: "eu:transitous:missing")
        let plan = makePlan(outboundIDs: [missingID, completed.id, trips[1].id])

        let presentation = JourneyPlanPresentation(
            plan: plan,
            trips: [completed, trips[1]],
            at: fixtureReferenceDate.addingTimeInterval(4 * 3_600)
        )

        XCTAssertEqual(presentation.nextActionableTrip?.id, trips[1].id)
    }

    @MainActor
    func testPrematurePassedFlagKeepsChildActionableThroughRecoveryWindow() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let prematurelyPassed = completedTrip(from: trips[0])
        let plan = makePlan(outboundIDs: [prematurelyPassed.id, trips[1].id])

        let presentation = JourneyPlanPresentation(
            plan: plan,
            trips: [prematurelyPassed, trips[1]],
            at: fixtureReferenceDate
        )

        XCTAssertFalse(prematurelyPassed.isComplete, "Unstamped passage flags do not confirm arrival")
        XCTAssertEqual(presentation.nextActionableTrip?.id, prematurelyPassed.id)
    }

    @MainActor
    func testUpcomingConnectionTakesPriorityOverCompletedRecoveryChild() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let completed = completedTrip(from: trips[0])
        let plan = makePlan(outboundIDs: [completed.id, trips[1].id])

        let presentation = JourneyPlanPresentation(
            plan: plan,
            trips: [completed, trips[1]],
            at: fixtureReferenceDate.addingTimeInterval(4 * 3_600)
        )

        XCTAssertEqual(presentation.nextActionableTrip?.id, trips[1].id)
    }

    @MainActor
    func testGroupedActiveAndUpcomingChildrenStayInsideTheirSavedJourney() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let plan = makePlan(outboundIDs: trips.map(\.id))

        let presentation = JourneyPlanListPresentation(
            plans: [plan],
            trips: trips,
            activeTrip: trips[0],
            at: fixtureReferenceDate
        )

        XCTAssertNil(presentation.activeTrip)
        XCTAssertNil(presentation.activeTripRouteTimeZones)
        XCTAssertEqual(presentation.journeyPlans.map(\.id), [plan.id])
        XCTAssertTrue(presentation.individualTrips.isEmpty)
    }

    @MainActor
    func testImportedAndLegacyTripsRemainUngrouped() {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let legacy = copy(trips[1], id: RailIdentifier(rawValue: "legacy:individual"))
        let plan = makePlan(outboundIDs: [trips[0].id])

        let presentation = JourneyPlanListPresentation(
            plans: [plan],
            trips: [trips[0], legacy],
            activeTrip: trips[0]
        )

        XCTAssertEqual(presentation.individualTrips.map(\.id), [legacy.id])
    }

    @MainActor
    func testTrainMovesFromUpcomingToCurrentToPastAtTimetableBoundaries() {
        let trip = timedTrip(id: "boundary", departure: fixtureReferenceDate, arrival: fixtureReferenceDate.addingTimeInterval(3_600))
        let presentation = JourneyPlanListPresentation(plans: [], trips: [trip], activeTrip: nil)

        XCTAssertEqual(presentation.upcomingTrains(asOf: fixtureReferenceDate.addingTimeInterval(-1)).map(\.id), [trip.id])
        XCTAssertTrue(presentation.pastTrains(asOf: fixtureReferenceDate).isEmpty)
        XCTAssertEqual(presentation.currentTrains(asOf: fixtureReferenceDate).map(\.id), [trip.id])
        XCTAssertEqual(presentation.pastTrains(asOf: fixtureReferenceDate.addingTimeInterval(3_600)).map(\.id), [trip.id])
        XCTAssertTrue(presentation.currentTrains(asOf: fixtureReferenceDate.addingTimeInterval(3_600)).isEmpty)
    }

    @MainActor
    func testUpcomingTrainsUseEffectiveDepartureOrderInsteadOfSaveOrder() {
        let early = timedTrip(id: "early", departure: fixtureReferenceDate.addingTimeInterval(600), arrival: fixtureReferenceDate.addingTimeInterval(3_600))
        let delayed = timedTrip(id: "delayed", departure: fixtureReferenceDate.addingTimeInterval(300), arrival: fixtureReferenceDate.addingTimeInterval(4_000), expectedDeparture: fixtureReferenceDate.addingTimeInterval(1_200))
        let later = timedTrip(id: "later", departure: fixtureReferenceDate.addingTimeInterval(1_800), arrival: fixtureReferenceDate.addingTimeInterval(5_000))
        let presentation = JourneyPlanListPresentation(plans: [], trips: [later, delayed, early], activeTrip: nil)

        XCTAssertEqual(presentation.upcomingTrains(asOf: fixtureReferenceDate).map(\.id), [early.id, delayed.id, later.id])
    }

    @MainActor
    func testSecondUnderwayTrainAndDelayedArrivalRemainCurrent() {
        let active = timedTrip(id: "active", departure: fixtureReferenceDate.addingTimeInterval(-3_600), arrival: fixtureReferenceDate.addingTimeInterval(600))
        let delayed = timedTrip(id: "delayed", departure: fixtureReferenceDate.addingTimeInterval(-7_200), arrival: fixtureReferenceDate.addingTimeInterval(-600), expectedArrival: fixtureReferenceDate.addingTimeInterval(1_200))
        let presentation = JourneyPlanListPresentation(plans: [], trips: [active, delayed], activeTrip: active, at: fixtureReferenceDate)
        XCTAssertEqual(presentation.activeTrip?.id, active.id)

        XCTAssertEqual(presentation.currentTrains(asOf: fixtureReferenceDate).map(\.id), [delayed.id])
        XCTAssertTrue(presentation.pastTrains(asOf: fixtureReferenceDate).isEmpty)
    }

    @MainActor
    func testMissingTimesStayOtherAcrossUTCMidnightAndDeviceZones() {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        let untimed = timedTrip(id: "untimed", departure: nil, arrival: nil)
        let presentation = JourneyPlanListPresentation(plans: [], trips: [untimed], activeTrip: nil)
        let afterServiceDay = fixtureReferenceDate.addingTimeInterval(36 * 3_600)

        XCTAssertEqual(presentation.otherTrains(asOf: afterServiceDay).map(\.id), [untimed.id])
        XCTAssertTrue(presentation.pastTrains(asOf: afterServiceDay).isEmpty)
        XCTAssertTrue(presentation.upcomingTrains(asOf: afterServiceDay).isEmpty)
        XCTAssertEqual(TicketStubCardContent(trip: untimed, routeTimeZones: nil).whenText, "Departure time unavailable")
    }

    @MainActor
    func testPastTrainsSortByFinalArrivalIncludingOvernight() {
        let overnight = timedTrip(id: "overnight", departure: fixtureReferenceDate.addingTimeInterval(-86_400), arrival: fixtureReferenceDate.addingTimeInterval(-600))
        let earlierArrival = timedTrip(id: "earlier-arrival", departure: fixtureReferenceDate.addingTimeInterval(-7_200), arrival: fixtureReferenceDate.addingTimeInterval(-1_200))
        let presentation = JourneyPlanListPresentation(plans: [], trips: [earlierArrival, overnight], activeTrip: nil)

        XCTAssertEqual(presentation.pastTrains(asOf: fixtureReferenceDate).map(\.id), [overnight.id, earlierArrival.id])
    }

    @MainActor
    func testEmptyAndCancelledTimetablesRemainOther() {
        let cancelled = timedTrip(id: "cancelled", departure: fixtureReferenceDate.addingTimeInterval(-3_600), arrival: fixtureReferenceDate.addingTimeInterval(-600), cancelled: true)
        let empty = TrainTrip(id: RailIdentifier(rawValue: "test:empty"), source: cancelled.source,
                              serviceDate: fixtureReferenceDate, operatorName: cancelled.operatorName,
                              product: cancelled.product, headsign: cancelled.headsign,
                              stopTimes: [], capabilities: cancelled.capabilities)
        let presentation = JourneyPlanListPresentation(plans: [], trips: [empty, cancelled], activeTrip: nil)

        XCTAssertEqual(presentation.otherTrains(asOf: fixtureReferenceDate).map(\.id), [empty.id, cancelled.id])
        XCTAssertTrue(presentation.pastTrains(asOf: fixtureReferenceDate).isEmpty)
        XCTAssertTrue(presentation.currentTrains(asOf: fixtureReferenceDate).isEmpty)
    }

    @MainActor
    func testGroupedChildrenStaySuppressedAndEndedStandaloneHighlightsReturnToHistory() {
        let grouped = timedTrip(id: "grouped", departure: fixtureReferenceDate, arrival: fixtureReferenceDate.addingTimeInterval(3_600))
        let active = timedTrip(id: "active", departure: fixtureReferenceDate, arrival: fixtureReferenceDate.addingTimeInterval(3_600))
        let plan = makePlan(outboundIDs: [grouped.id])
        for date in [fixtureReferenceDate.addingTimeInterval(-1), fixtureReferenceDate, fixtureReferenceDate.addingTimeInterval(4_000)] {
            let presentation = JourneyPlanListPresentation(plans: [plan], trips: [active, grouped], activeTrip: active, at: date)
            XCTAssertTrue(presentation.upcomingTrains(asOf: date).isEmpty)
            XCTAssertTrue(presentation.currentTrains(asOf: date).isEmpty)
            XCTAssertTrue(presentation.otherTrains(asOf: date).isEmpty)
            if date >= fixtureReferenceDate.addingTimeInterval(3_600) {
                XCTAssertNil(presentation.activeTrip)
                XCTAssertEqual(presentation.pastTrains(asOf: date).map(\.id), [active.id])
            } else {
                XCTAssertEqual(presentation.activeTrip?.id, active.id)
                XCTAssertTrue(presentation.pastTrains(asOf: date).isEmpty)
            }
        }
    }

    @MainActor
    func testJourneyBecomesPastAtFinalArrivalAndRoundTripWaitsForReturn() {
        let oneWay = makePlan(outboundIDs: [], outboundDeparture: fixtureReferenceDate.addingTimeInterval(-3_600), outboundArrival: fixtureReferenceDate)
        let roundTrip = makePlan(outboundIDs: [], returnIDs: [], outboundDeparture: fixtureReferenceDate.addingTimeInterval(-3_600), outboundArrival: fixtureReferenceDate, returnDeparture: fixtureReferenceDate.addingTimeInterval(3_600), returnArrival: fixtureReferenceDate.addingTimeInterval(7_200))
        let presentation = JourneyPlanListPresentation(plans: [oneWay, roundTrip], trips: [], activeTrip: nil, at: fixtureReferenceDate)

        XCTAssertEqual(presentation.upcomingJourneys(asOf: fixtureReferenceDate).map(\.id), [roundTrip.id])
        XCTAssertEqual(presentation.pastJourneys(asOf: fixtureReferenceDate).map(\.id), [oneWay.id])
        XCTAssertEqual(presentation.pastJourneys(asOf: fixtureReferenceDate.addingTimeInterval(7_200)).map(\.id), [roundTrip.id, oneWay.id])
    }

    @MainActor
    private func timedTrip(id: String, departure: Date?, arrival: Date?, expectedDeparture: Date? = nil, expectedArrival: Date? = nil, cancelled: Bool = false) -> TrainTrip {
        let base = JourneyPlanTestFixtures.makeTrips()[0]
        return TrainTrip(
            id: RailIdentifier(rawValue: "test:\(id)"), source: base.source,
            serviceDate: fixtureReferenceDate, operatorName: base.operatorName,
            product: base.product, headsign: base.headsign,
            stopTimes: [
                StopTime(station: base.stopTimes[0].station, sequence: 0, scheduledDeparture: departure, expectedDeparture: expectedDeparture, isCancelled: cancelled),
                StopTime(station: base.stopTimes.last!.station, sequence: 1, scheduledArrival: arrival, expectedArrival: expectedArrival, isCancelled: cancelled)
            ], capabilities: base.capabilities
        )
    }

    @MainActor
    func testRemovedIndividualChildLeavesPlanAndRendersNoLongerTracked() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let plan = makePlan(outboundIDs: [trips[0].id])
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0]])
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive(plans: [plan])
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: context.library,
            archive: archive
        )

        context.library.removeTrip(id: trips[0].id)

        XCTAssertEqual(planLibrary.plans, [plan])
        let child = try XCTUnwrap(
            JourneyPlanPresentation(plan: plan, trips: context.library.trips)
                .directions.first?.children.first
        )
        XCTAssertEqual(child.status, .missing)
        XCTAssertEqual(child.statusText, "No longer tracked")
    }

    @MainActor
    func testFailedIndividualRemovalKeepsTripAndReportsFailure() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let invalid = JourneyPlanTestFixtures.replacingCoordinate(
            in: trips[1],
            latitude: .nan
        )
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trips[0], invalid])
        defer { context.cleanup() }

        XCTAssertFalse(context.library.removeTrip(id: trips[0].id))

        XCTAssertEqual(Set(context.library.trips.map(\.id)), Set([trips[0].id, invalid.id]))
    }

    @MainActor
    func testSharedChildPreservationExplainsWhyTrainRemains() {
        let shared = RailIdentifier(rawValue: "shared:train")
        let trip = copy(JourneyPlanTestFixtures.makeTrips()[0], id: shared)
        let preview = JourneyPlanRemovalPreview(
            removableChildTripIDs: [],
            preservedChildTripIDs: [shared],
            sharedChildTripIDs: [shared],
            preExistingChildTripIDs: []
        )

        let presentation = JourneyPlanRemovalPresentation(preview: preview, trips: [trip])

        XCTAssertEqual(presentation.preservedChildren.first?.reason, .shared)
        XCTAssertEqual(
            presentation.preservedChildren.first?.reasonText,
            "Tracked by another journey"
        )
    }

    @MainActor
    func testPreExistingChildPreservationExplainsWhyTrainRemains() {
        let preExisting = RailIdentifier(rawValue: "existing:train")
        let trip = copy(JourneyPlanTestFixtures.makeTrips()[0], id: preExisting)
        let preview = JourneyPlanRemovalPreview(
            removableChildTripIDs: [],
            preservedChildTripIDs: [preExisting],
            sharedChildTripIDs: [],
            preExistingChildTripIDs: [preExisting]
        )

        let presentation = JourneyPlanRemovalPresentation(preview: preview, trips: [trip])

        XCTAssertEqual(presentation.preservedChildren.first?.reason, .preExisting)
        XCTAssertEqual(
            presentation.preservedChildren.first?.reasonText,
            "Tracked before this journey"
        )
    }

    func testMissingUniqueChildIsNotCountedAsAStoppedTrain() {
        let missing = RailIdentifier(rawValue: "missing:unique")
        let preview = JourneyPlanRemovalPreview(
            removableChildTripIDs: [missing],
            preservedChildTripIDs: [],
            sharedChildTripIDs: [],
            preExistingChildTripIDs: []
        )

        let presentation = JourneyPlanRemovalPresentation(preview: preview, trips: [])

        XCTAssertTrue(presentation.removableChildren.isEmpty)
        XCTAssertTrue(presentation.preservedChildren.isEmpty)
        XCTAssertEqual(presentation.missingChildren.map(\.id), [missing])
        XCTAssertEqual(presentation.missingChildren.first?.reasonText, "No longer tracked")
        XCTAssertEqual(presentation.actionTitle, "Remove Journey Group")
        XCTAssertEqual(
            presentation.warningMessage,
            "This removes the journey group. Any trains still in My Trips remain tracked."
        )
        XCTAssertFalse(presentation.hasTrackedTrainsToRemove)
    }

    func testMissingSharedAndPreExistingChildIsNotCalledStillTracked() {
        let missing = RailIdentifier(rawValue: "missing:shared")
        let preview = JourneyPlanRemovalPreview(
            removableChildTripIDs: [],
            preservedChildTripIDs: [missing],
            sharedChildTripIDs: [missing],
            preExistingChildTripIDs: [missing]
        )

        let presentation = JourneyPlanRemovalPresentation(preview: preview, trips: [])

        XCTAssertTrue(presentation.removableChildren.isEmpty)
        XCTAssertTrue(presentation.preservedChildren.isEmpty)
        XCTAssertEqual(presentation.missingChildren.map(\.id), [missing])
        XCTAssertEqual(presentation.missingChildren.first?.reason, .missing)
        XCTAssertEqual(presentation.actionTitle, "Remove Journey Group")
    }

    @MainActor
    func testFailedGroupingRemovalKeepsPlanAndExposesRetryableFailure() throws {
        let plan = makePlan(outboundIDs: [JourneyPlanTestFixtures.makeTrips()[0].id])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive(plans: [plan])
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let controller = JourneyPlanRemovalController(planID: plan.id, library: library)
        archive.shouldFailSave = true

        XCTAssertFalse(controller.removeGrouping())

        XCTAssertEqual(library.plans, [plan])
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(
            controller.failureMessage,
            "The journey group couldn’t be removed. Your tracked trains are unchanged. Try again."
        )

        controller.prepareDestructiveReview()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.failureMessage)
    }

    @MainActor
    func testFailedDestructiveRemovalKeepsPlanAndTripsAndExposesRetryableFailure() throws {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let plan = makePlan(outboundIDs: [trip.id])
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip])
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive(plans: [plan])
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let controller = JourneyPlanRemovalController(planID: plan.id, library: library)
        archive.shouldFailSave = true

        XCTAssertFalse(controller.stopTrackingChildren())

        XCTAssertEqual(library.plans, [plan])
        XCTAssertEqual(context.library.trips.map(\.id), [trip.id])
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(
            controller.failureMessage,
            "The journey trains couldn’t be removed. The journey group and tracked trains are unchanged. Try again."
        )
    }

    @MainActor
    func testConfirmingWithOnlyMissingChildrenRemovesGroupingAndNoTrips() throws {
        let missing = RailIdentifier(rawValue: "missing:only-child")
        let plan = makePlan(outboundIDs: [missing])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive(plans: [plan])
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let controller = JourneyPlanRemovalController(planID: plan.id, library: library)

        XCTAssertTrue(controller.stopTrackingChildren())

        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertTrue(context.library.trips.isEmpty)
    }

    func testBackendPushWarningUsesSpecificRetryGuidanceWithoutClaimingSaveSuccess() {
        let presentation = PushDeliveryWarningPresentation(
            reason: .backendSynchronizationFailed
        )

        XCTAssertEqual(presentation.title, "Train alerts aren’t synced")
        XCTAssertEqual(presentation.actionTitle, "Try Again")
        XCTAssertEqual(presentation.action, .retry)
        XCTAssertTrue(presentation.message.contains("still tracked"))
        XCTAssertFalse(presentation.message.contains("Your journey is saved"))
    }

    func testTripAlertRejectionsExplainTheQuotaBeforeOtherRefusals() {
        XCTAssertNil(PushTripRejectionPresentation(rejections: []))

        let quota = try? XCTUnwrap(PushTripRejectionPresentation(rejections: [.invalidTrip, .quotaExceeded]))
        XCTAssertEqual(quota?.title, "Alert limit reached")
        XCTAssertTrue(quota?.message.contains("2 trains") == true)
        XCTAssertTrue(quota?.message.contains("24") == true)

        let single = try? XCTUnwrap(PushTripRejectionPresentation(rejections: [.tripConflict]))
        XCTAssertEqual(single?.title, "No alerts for 1 train")
        XCTAssertTrue(single?.message.contains("still tracked") == true)
    }

    func testDeniedPushWarningRoutesTheUserToNotificationSettings() {
        let presentation = PushDeliveryWarningPresentation(reason: .authorizationDenied)

        XCTAssertEqual(presentation.title, "Train alerts are off")
        XCTAssertEqual(presentation.actionTitle, "Open Notification Settings")
        XCTAssertEqual(presentation.action, .openNotificationSettings)
        XCTAssertTrue(presentation.message.contains("still tracked"))
    }

    @MainActor
    private func makePlan(
        outboundIDs: [RailIdentifier],
        returnIDs: [RailIdentifier]? = nil,
        outboundDeparture: Date = Date(timeIntervalSince1970: 1_721_890_000),
        outboundArrival: Date = Date(timeIntervalSince1970: 1_721_930_000),
        returnDeparture: Date = Date(timeIntervalSince1970: 1_722_150_000),
        returnArrival: Date = Date(timeIntervalSince1970: 1_722_190_000),
        originTimeZone: String = "Europe/Paris",
        destinationTimeZone: String = "Europe/Amsterdam"
    ) -> TrackedJourneyPlan {
        let draft = JourneyPlanTestFixtures.makeDraft(includesReturn: returnIDs != nil)
        return TrackedJourneyPlan(
            id: draft.id,
            createdAt: Date(timeIntervalSince1970: 1_721_800_000),
            origin: place(draft.origin, timeZoneIdentifier: originTimeZone),
            destination: place(draft.destination, timeZoneIdentifier: destinationTimeZone),
            outbound: JourneyPlanDirection(
                fingerprint: "outbound-fingerprint",
                departure: outboundDeparture,
                arrival: outboundArrival,
                childTripIDs: outboundIDs
            ),
            returnDirection: returnIDs.map {
                JourneyPlanDirection(
                    fingerprint: "return-fingerprint",
                    departure: returnDeparture,
                    arrival: returnArrival,
                    childTripIDs: $0
                )
            },
            preExistingChildTripIDs: []
        )
    }

    private func place(
        _ place: RailPlace,
        timeZoneIdentifier: String
    ) -> RailPlace {
        RailPlace(
            id: place.id,
            kind: place.kind,
            displayName: place.displayName,
            context: place.context,
            countryCode: place.countryCode,
            timeZoneIdentifier: timeZoneIdentifier,
            location: place.location,
            eligibleModes: place.eligibleModes,
            attributions: place.attributions
        )
    }

    private func date(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            preconditionFailure("Invalid fixture date: \(value)")
        }
        return date
    }

    private func completedTrip(from trip: TrainTrip) -> TrainTrip {
        let completedStops = trip.stopTimes.map { stop in
            StopTime(
                station: stop.station,
                sequence: stop.sequence,
                scheduledArrival: stop.scheduledArrival,
                scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival,
                expectedDeparture: stop.expectedDeparture,
                plannedPlatform: stop.plannedPlatform,
                expectedPlatform: stop.expectedPlatform,
                isCancelled: stop.isCancelled,
                isPassed: true
            )
        }
        return TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: completedStops,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }

    private func copy(_ trip: TrainTrip, id: RailIdentifier) -> TrainTrip {
        TrainTrip(
            id: id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: trip.stopTimes,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }

    /// A station-local time carries its zone only when that clock differs from the device's.
    private func localTime(_ time: String, _ instant: Date, _ zone: String) -> String {
        JourneyPlanDateTimePresentation.zoneSuffix(instant, timeZoneIdentifier: zone).map { "\(time) \($0)" } ?? time
    }

    func testZoneSuffixOnlyWhenTheStationClockDiffersFromTheDevice() {
        let instant = Date(timeIntervalSince1970: 1_784_800_000)
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertNotNil(JourneyPlanDateTimePresentation.zoneSuffix(instant, timeZoneIdentifier: "Europe/Paris", deviceTimeZone: losAngeles))
        XCTAssertNil(JourneyPlanDateTimePresentation.zoneSuffix(
            instant, timeZoneIdentifier: "Europe/Paris", deviceTimeZone: TimeZone(identifier: "Europe/Berlin")!
        ), "Same clock, no label")
        XCTAssertTrue(JourneyPlanDateTimePresentation.labeledTime(
            instant, timeZoneIdentifier: "Europe/Paris", deviceTimeZone: losAngeles
        ).hasSuffix(JourneyPlanDateTimePresentation.zoneSuffix(instant, timeZoneIdentifier: "Europe/Paris", deviceTimeZone: losAngeles)!))
    }
}
