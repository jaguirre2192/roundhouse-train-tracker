import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TripDetailTimeZoneContextTests: XCTestCase {
    func testEasternRouteDetailAndEveryStopStayEasternOnLADevice() {
        let fixture = TripDetailTimeZoneFixtures.easternRoute()
        let context = TripDetailTimeZoneContext(
            trip: fixture.trip, routeTimeZones: TripDetailTimeZoneFixtures.eastern,
            plans: [fixture.plan], fallbackTimeZone: TripDetailTimeZoneFixtures.losAngeles
        )
        XCTAssertEqual(context.routeTimeZones, TripDetailTimeZoneFixtures.eastern)
        XCTAssertEqual(times(fixture.trip, context: context), ["4:20 PM", "6:40 PM", "11:37 PM"])
    }

    @MainActor
    func testActiveTripCardKeepsEasternTimesOnLADevice() {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TripDetailTimeZoneFixtures.losAngeles
        defer { NSTimeZone.default = previousZone }
        let fixture = TripDetailTimeZoneFixtures.easternRoute()
        let context = TripDetailTimeZoneContext(trip: fixture.trip, plans: [fixture.plan])
        let presentation = ActiveTripCardPresentation(
            trip: fixture.trip, routeTimeZones: context.routeTimeZones
        )
        XCTAssertEqual(presentation.departureTimeText, "4:20 PM")
        XCTAssertEqual(presentation.arrivalTimeText, "11:37 PM")
    }

    func testDeepLinkDerivesOwningPlanWithoutNavigationArguments() {
        let fixture = TripDetailTimeZoneFixtures.easternRoute()
        let context = TripDetailTimeZoneContext(
            trip: fixture.trip, plans: [fixture.plan], fallbackTimeZone: TripDetailTimeZoneFixtures.losAngeles
        )
        XCTAssertEqual(context.routeTimeZones, TripDetailTimeZoneFixtures.eastern)
        XCTAssertEqual(times(fixture.trip, context: context), ["4:20 PM", "6:40 PM", "11:37 PM"])
    }

    func testCrossZoneTimelineUsesEachKnownStationInsteadOfDestinationZone() {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let context = TripDetailTimeZoneContext(
            trip: fixture.trip, plans: [fixture.plan, fixture.denverPlan],
            fallbackTimeZone: TripDetailTimeZoneFixtures.losAngeles
        )
        XCTAssertEqual(
            fixture.trip.stopTimes.map { context.timeZoneIdentifier(for: $0) },
            ["America/Chicago", "America/Denver", "America/Los_Angeles"]
        )
        XCTAssertEqual(times(fixture.trip, context: context), ["3:20 PM", "4:40 PM", "8:37 PM"])
    }

    func testUnknownIntermediateStationOnCrossZoneRouteKeepsSystemFallback() {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let context = TripDetailTimeZoneContext(trip: fixture.trip, plans: [fixture.plan])
        XCTAssertNil(context.timeZoneIdentifier(for: fixture.trip.stopTimes[1]))
        XCTAssertEqual(times(fixture.trip, context: context), ["3:20 PM", "3:40 PM", "8:37 PM"])
    }

    func testUnknownUngroupedTripKeepsExistingSystemFallback() {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let context = TripDetailTimeZoneContext(trip: trip)
        XCTAssertNil(context.routeTimeZones)
        XCTAssertTrue(trip.stopTimes.allSatisfy { context.timeZoneIdentifier(for: $0) == nil })
        XCTAssertEqual(times(trip, context: context), ["1:20 PM", "3:40 PM", "8:37 PM"])
    }

    func testIntermediateLegDoesNotInheritUnrelatedWholeJourneyEndpoints() {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let middleTrip = TripDetailTimeZoneFixtures.trip(
            id: "middle", stations: [fixture.trip.stopTimes[1].station, fixture.trip.stopTimes[1].station]
        )
        let plan = TripDetailTimeZoneFixtures.plan(
            fixture.trip, departureZone: "America/Chicago", arrivalZone: "America/Los_Angeles",
            childTripIDs: [RailIdentifier(rawValue: "before"), middleTrip.id, RailIdentifier(rawValue: "after")]
        )
        let context = TripDetailTimeZoneContext(trip: middleTrip, plans: [plan])
        XCTAssertNil(context.routeTimeZones)
        XCTAssertTrue(middleTrip.stopTimes.allSatisfy { context.timeZoneIdentifier(for: $0) == nil })
    }

    func testReturnDirectionResolvesReversedEndpointZones() {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let returnTrip = TripDetailTimeZoneFixtures.trip(
            id: "return", stations: [fixture.trip.destination!, fixture.trip.origin!]
        )
        let plan = TripDetailTimeZoneFixtures.plan(
            fixture.trip, departureZone: "America/Chicago", arrivalZone: "America/Los_Angeles",
            returnTripIDs: [returnTrip.id]
        )
        let context = TripDetailTimeZoneContext(trip: returnTrip, plans: [plan])
        XCTAssertEqual(context.routeTimeZones?.departureTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(context.routeTimeZones?.arrivalTimeZoneIdentifier, "America/Chicago")
    }

    private func times(_ trip: TrainTrip, context: TripDetailTimeZoneContext) -> [String?] {
        trip.stopTimes.map {
            StopTimelineTimePresentation(
                stop: $0, timeZoneIdentifier: context.timeZoneIdentifier(for: $0),
                fallbackTimeZone: TripDetailTimeZoneFixtures.losAngeles, locale: Locale(identifier: "en_US_POSIX")
            ).timeText.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
    }
}
