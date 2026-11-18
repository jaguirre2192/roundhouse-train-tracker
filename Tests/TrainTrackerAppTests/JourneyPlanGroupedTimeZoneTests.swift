import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanGroupedTimeZoneTests: XCTestCase {
    @MainActor
    func testGroupedSummaryChildRowAndLiveCardUseOwningDirectionZones() throws {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        let preview = try XCTUnwrap(JourneyPlanPreviewData.resolve(
            arguments: ["-JourneyPlanPreview"],
            now: date("2026-07-22T12:30:00Z")
        ))
        let activeTrip = try XCTUnwrap(preview.trips.first)
        let plan = try XCTUnwrap(preview.plans.first)
        let planPresentation = JourneyPlanPresentation(
            plan: plan,
            trips: preview.trips,
            at: date("2026-07-22T12:30:00Z")
        )
        let outbound = try XCTUnwrap(planPresentation.directions.first)
        let listPresentation = JourneyPlanListPresentation(
            plans: preview.plans,
            trips: preview.trips,
            activeTrip: activeTrip,
            at: date("2026-07-22T12:30:00Z")
        )

        XCTAssertNil(listPresentation.activeTrip)
        XCTAssertNil(listPresentation.activeTripRouteTimeZones)
        XCTAssertEqual(Set(listPresentation.journeyPlans.map(\.id)), Set(preview.plans.map(\.id)))
        let detailZones = TripDetailTimeZoneContext(trip: activeTrip, plans: preview.plans)
        XCTAssertEqual(detailZones.timeZoneIdentifier(for: activeTrip.stopTimes[0]), "Europe/Paris")
        XCTAssertNil(detailZones.timeZoneIdentifier(for: activeTrip.stopTimes[1]), "A legacy intermediate station has no persisted zone evidence")

        let childRow = TripRowSchedulePresentation(
            trip: activeTrip,
            routeTimeZones: outbound.routeTimeZones
        )
        let liveCard = ActiveTripCardPresentation(
            trip: activeTrip,
            routeTimeZones: outbound.routeTimeZones,
            referenceDate: date("2026-07-22T12:30:00Z")
        )

        XCTAssertEqual(planPresentation.nextActionableTimeText?.hasPrefix("2:00 PM"), true)
        XCTAssertEqual(childRow.departureTimeText, planPresentation.nextActionableTimeText)
        XCTAssertEqual(childRow.serviceDateText, "Wed, Jul 22")
        XCTAssertEqual(liveCard.departureTimeText, "2:07 PM")
        XCTAssertEqual(liveCard.arrivalTimeText, "3:39 PM")
        XCTAssertNotEqual(liveCard.departureTimeText, "5:07 AM")
        XCTAssertTrue(
            tripAccessibilitySummary(
                activeTrip,
                timeZoneIdentifier: outbound.routeTimeZones.arrivalTimeZoneIdentifier,
                referenceDate: date("2026-07-22T12:30:00Z")
            ).contains("3:39 PM")
        )
    }

    @MainActor
    func testUngroupedTripPresentationsKeepSystemTimeZoneFallback() throws {
        let preview = try XCTUnwrap(JourneyPlanPreviewData.resolve(
            arguments: ["-JourneyPlanPreview"],
            now: date("2026-07-22T12:30:00Z")
        ))
        let legacyTrip = try XCTUnwrap(preview.trips.last)
        let listPresentation = JourneyPlanListPresentation(
            plans: preview.plans,
            trips: preview.trips,
            activeTrip: legacyTrip
        )

        XCTAssertNil(listPresentation.activeTripRouteTimeZones)
        XCTAssertNil(TripRowSchedulePresentation(trip: legacyTrip).departureTimeText)
        XCTAssertNil(TripRowSchedulePresentation(trip: legacyTrip).serviceDateText)
        XCTAssertNil(ActiveTripCardPresentation(trip: legacyTrip).departureTimeText)
        XCTAssertNil(ActiveTripCardPresentation(trip: legacyTrip).arrivalTimeText)
        XCTAssertEqual(
            tripAccessibilitySummary(legacyTrip),
            tripAccessibilitySummary(legacyTrip, timeZoneIdentifier: nil)
        )
    }

    @MainActor
    func testGroupedChildDateUsesRouteLocalScheduledDepartureDay() throws {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        let preview = try XCTUnwrap(JourneyPlanPreviewData.resolve(
            arguments: ["-JourneyPlanPreview"],
            now: date("2026-07-23T00:40:00Z")
        ))
        let originalTrip = try XCTUnwrap(preview.trips.first)
        let trip = replacingServiceDate(
            in: originalTrip,
            with: date("2026-07-22T00:00:00Z")
        )
        let plan = try XCTUnwrap(preview.plans.first)
        let planPresentation = JourneyPlanPresentation(
            plan: plan,
            trips: [trip] + preview.trips.dropFirst(),
            at: date("2026-07-23T00:40:00Z")
        )
        let outbound = try XCTUnwrap(planPresentation.directions.first)

        let childRow = TripRowSchedulePresentation(
            trip: trip,
            routeTimeZones: outbound.routeTimeZones
        )

        XCTAssertEqual(planPresentation.outboundDateText, "Thu, Jul 23")
        XCTAssertEqual(childRow.serviceDateText, planPresentation.outboundDateText)
        XCTAssertEqual(childRow.departureTimeText?.hasPrefix("2:10 AM"), true)
    }

    @MainActor
    func testUngroupedTripDateFollowsScheduledDepartureNotServiceMidnight() throws {
        let previousZone = NSTimeZone.default
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        NSTimeZone.default = losAngeles
        defer { NSTimeZone.default = previousZone }
        let preview = try XCTUnwrap(JourneyPlanPreviewData.resolve(
            arguments: ["-JourneyPlanPreview"],
            now: date("2026-07-22T12:30:00Z")
        ))
        let legacyTrip = try XCTUnwrap(preview.trips.last)
        let departure = try XCTUnwrap(legacyTrip.stopTimes.first?.scheduledDeparture)
        // The backend sends the service day as "YYYY-MM-DD", parsed as UTC midnight,
        // which falls on the previous evening anywhere in the Americas.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = losAngeles
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let serviceMidnight = try XCTUnwrap(utc.date(from: local.dateComponents([.year, .month, .day], from: departure)))
        let trip = replacingServiceDate(in: legacyTrip, with: serviceMidnight)

        let stub = TicketStubCardContent(trip: trip, routeTimeZones: nil)
        let departureDay = departure.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())

        XCTAssertTrue(stub.whenText.hasPrefix(departureDay), "\(stub.whenText) should start with \(departureDay)")
    }

    private func date(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            preconditionFailure("Invalid fixture date: \(value)")
        }
        return date
    }

    private func replacingServiceDate(
        in trip: TrainTrip,
        with serviceDate: Date
    ) -> TrainTrip {
        TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: trip.stopTimes,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }
}
