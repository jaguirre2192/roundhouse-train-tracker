import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyResolutionSummaryTests: XCTestCase {
    @MainActor
    func testAllAvailableOneWayIsReadyToTrack() {
        let outbound = journeyOutboundOption()
        let trips = JourneyPlanTestFixtures.makeTrips()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: trips
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: false
        )

        XCTAssertEqual(summary.state, .all)
        // This fixture carries no coverage, as a response from an older backend would: the trains
        // resolve and can be tracked, but nothing is promised about live data.
        XCTAssertEqual(summary.statusTitle, "Ready to save")
        XCTAssertEqual(summary.primaryActionTitle, "Track Journey")
        XCTAssertEqual(summary.availableTripCount, 2)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertTrue(summary.canTrack)
        XCTAssertFalse(summary.showsSubsetConsent)
    }

    @MainActor
    func testAllAvailableRoundTripUsesRoundTripActionTitle() {
        let outbound = journeyOutboundOption()
        let returnOption = journeyReturnOption()
        let trips = JourneyPlanTestFixtures.makeTrips()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [trips[0]],
            returnOption: returnOption,
            returnTrips: [trips[1]]
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: true,
            availableSubsetConfirmed: false
        )

        XCTAssertEqual(summary.state, .all)
        XCTAssertEqual(summary.primaryActionTitle, "Track Round Trip")
        XCTAssertTrue(summary.canTrack)
    }

    @MainActor
    func testPartialResolutionListsEveryFailureAndRequiresExplicitConsent() {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]],
            outboundFailures: [
                ("missing", JourneySearchStoreFixtures.failure(
                    code: .notFound,
                    message: "Train could not be matched"
                )),
                ("provider", JourneySearchStoreFixtures.failure(
                    code: .providerUnavailable,
                    message: "Provider unavailable"
                )),
            ]
        )

        let unconfirmed = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: false
        )
        let confirmed = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: true
        )

        XCTAssertEqual(unconfirmed.state, .partial)
        XCTAssertEqual(unconfirmed.statusTitle, "Some trains are unavailable")
        XCTAssertEqual(
            unconfirmed.failures.map(\.message),
            ["Train could not be matched", "Provider unavailable"]
        )
        XCTAssertEqual(unconfirmed.primaryActionTitle, "Track 1 Available Train")
        XCTAssertEqual(unconfirmed.subsetConsentLabel, "Track only the 1 available train")
        XCTAssertTrue(unconfirmed.showsSubsetConsent)
        XCTAssertFalse(unconfirmed.canTrack)
        XCTAssertTrue(unconfirmed.showsRetryAction)
        XCTAssertEqual(unconfirmed.retryActionTitle, "Retry unavailable trains")
        XCTAssertTrue(confirmed.canTrack)
    }

    @MainActor
    func testPartialPluralizesAvailableTrainCopy() {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: JourneyPlanTestFixtures.makeTrips(),
            outboundFailures: [(
                "missing",
                JourneySearchStoreFixtures.failure(code: .notFound, message: "Unavailable")
            )]
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: false
        )

        XCTAssertEqual(summary.primaryActionTitle, "Track 2 Available Trains")
        XCTAssertEqual(summary.subsetConsentLabel, "Track only the 2 available trains")
    }

    @MainActor
    func testNoAvailableTripsKeepsScheduleButDisablesTracking() {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [],
            outboundFailures: [(
                "missing",
                JourneySearchStoreFixtures.failure(code: .notFound, message: "Unavailable")
            )]
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: true
        )

        XCTAssertEqual(summary.state, .none)
        XCTAssertEqual(summary.statusTitle, "No trains can be tracked")
        XCTAssertEqual(summary.primaryActionTitle, "Track Journey")
        XCTAssertEqual(summary.availableTripCount, 0)
        XCTAssertFalse(summary.canTrack)
        XCTAssertFalse(summary.showsSubsetConsent)
        XCTAssertTrue(summary.showsRetryAction)
        XCTAssertEqual(summary.failures.map(\.message), ["Unavailable"])
    }

    @MainActor
    func testDuplicateResolvedTripsCountOnce() {
        let outbound = journeyOutboundOption()
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [trip, trip]
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            isRoundTrip: false,
            availableSubsetConfirmed: false
        )

        XCTAssertEqual(summary.availableTripCount, 1)
        XCTAssertEqual(summary.state, .all)
    }

    @MainActor
    func testRepeatedKnownUntrackableLegsRemainIndividuallyListed() throws {
        let base = journeyOutboundOption(
            isTrackable: false,
            untrackableReason: "No stable identity"
        )
        guard case let .rail(rail) = try XCTUnwrap(base.segments.first) else {
            return XCTFail("Expected a rail fixture")
        }
        let repeated = JourneyOption(
            id: base.id,
            fingerprint: base.fingerprint,
            startTime: base.startTime,
            endTime: base.endTime,
            duration: base.duration,
            transferCount: 1,
            segments: [.rail(rail), .rail(rail)],
            badges: [],
            trackability: JourneyTrackability(
                trackableRailSegments: 0,
                totalRailSegments: 2
            ),
            realtimeFreshness: nil,
            attributions: base.attributions,
            trackingToken: base.trackingToken
        )
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: repeated,
            outboundTrips: []
        )

        let summary = JourneyResolutionSummary(
            resolution: resolution,
            selectedOptions: [repeated],
            isRoundTrip: false,
            availableSubsetConfirmed: false
        )

        XCTAssertEqual(summary.failures.map(\.segmentID), [rail.id, rail.id])
        XCTAssertEqual(summary.failures.map(\.message), ["No stable identity", "No stable identity"])
        XCTAssertEqual(Set(summary.failures.map(\.id)).count, 2)
    }

    func testPushWarningCopyIsStableAndNonBlocking() {
        XCTAssertEqual(
            JourneyResolutionSummary.pushWarningCopy,
            "Journey saved. Open My Trips to retry alerts."
        )
    }

    @MainActor
    func testNavigationRequestIsConsumedAndClearedExactlyOnce() {
        let navigation = AppNavigationModel()

        navigation.open(.trips)

        XCTAssertEqual(navigation.consumeRequestedSection(), .trips)
        XCTAssertNil(navigation.requestedSection)
        XCTAssertNil(navigation.consumeRequestedSection())
    }

    @MainActor
    func testLatestNavigationRequestCanBeConsumedByEitherRoot() {
        let navigation = AppNavigationModel()
        navigation.open(.stations)
        navigation.open(.trips)

        let consumed = navigation.consumeRequestedSection()

        XCTAssertEqual(consumed, .trips)
        XCTAssertNil(navigation.requestedSection)
    }

    @MainActor
    func testTicketJourneyRequestOpensSearchAndIsConsumedExactlyOnce() {
        let navigation = AppNavigationModel()
        let request = TicketJourneySearchRequest(
            originName: "London St Pancras",
            destinationName: "Paris Gare du Nord",
            departureTime: "2026-08-14T15:09:00+02:00",
            trainNumber: "9032"
        )

        navigation.openTicketJourneySearch(request)

        XCTAssertEqual(navigation.requestedSection, .stations)
        XCTAssertEqual(navigation.consumeTicketJourneySearch(), request)
        XCTAssertNil(navigation.requestedTicketJourneySearch)
        XCTAssertNil(navigation.consumeTicketJourneySearch())
    }

    @MainActor
    func testConditionalTicketJourneyConsumptionDoesNotRemoveANewerRequest() {
        let navigation = AppNavigationModel()
        let stale = TicketJourneySearchRequest(
            originName: "London St Pancras",
            destinationName: "Paris Gare du Nord",
            departureTime: nil,
            trainNumber: "9032"
        )
        let fresh = TicketJourneySearchRequest(
            originName: "València-Joaquín Sorolla",
            destinationName: "Madrid-Puerta de Atocha-Almudena Grandes",
            departureTime: "2026-08-14T15:09:00+02:00",
            trainNumber: "AVE 05951"
        )
        navigation.openTicketJourneySearch(stale)
        navigation.openTicketJourneySearch(fresh)

        XCTAssertNil(navigation.consumeTicketJourneySearch(ifMatching: stale.id))
        XCTAssertEqual(navigation.requestedTicketJourneySearch, fresh)
        XCTAssertEqual(navigation.consumeTicketJourneySearch(ifMatching: fresh.id), fresh)
    }
}
