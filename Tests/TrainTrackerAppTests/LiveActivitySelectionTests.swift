import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class LiveActivitySelectionTests: XCTestCase {
    func testExplicitSegmentPreservesSelectedEndpointsInProjectionAttributesAndDeepLink() throws {
        let (trip, _) = TripDetailTimeZoneFixtures.easternRoute()
        let segment = segment(trip, from: 1, to: 2)
        let selection = try XCTUnwrap(TrainLiveActivitySelection(trip: trip, segment: segment, plans: []))
        let date = TripDetailTimeZoneFixtures.date("2026-09-15T22:10:00Z")
        let projection = selection.projection(at: date, checkedAt: date, refreshFailed: false)
        let attributes = selection.attributes(at: date)

        XCTAssertEqual(selection.boarding.station.id, trip.stopTimes[1].station.id)
        XCTAssertEqual(selection.alighting.station.id, trip.stopTimes[2].station.id)
        XCTAssertEqual(projection.eligibility, .available)
        XCTAssertEqual(projection.state.focusName, trip.stopTimes[1].station.displayName)
        XCTAssertEqual(projection.state.eventTime, trip.stopTimes[1].scheduledDeparture?.timeIntervalSince1970)
        XCTAssertEqual(projection.state.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(attributes.boardingStationID, segment.from.id.rawValue)
        XCTAssertEqual(attributes.alightingStationID, segment.to.id.rawValue)
        XCTAssertEqual(attributes.boardingStopSequence, 1)
        XCTAssertEqual(attributes.alightingStopSequence, 2)
        XCTAssertEqual(attributes.startedAt, date.timeIntervalSince1970)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(attributes.deepLinkURL), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.scheme, "traintracker")
        XCTAssertEqual(components.host, "journey")
        XCTAssertEqual(components.queryItems?.first { $0.name == "trip" }?.value, trip.id.rawValue)
        XCTAssertEqual(components.queryItems?.first { $0.name == "boarding" }?.value, segment.from.id.rawValue)
        XCTAssertEqual(components.queryItems?.first { $0.name == "alighting" }?.value, segment.to.id.rawValue)
    }

    func testOpaqueJourneyPlaceIDsResolveToCanonicalTripStopsByUniqueLocation() throws {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let source = segment(trip, from: 1, to: 2)
        let opaque = JourneyPlanSegment(
            id: source.id,
            kind: .rail,
            from: opaquePlace(source.from, suffix: "search-was"),
            to: opaquePlace(source.to, suffix: "search-nyp"),
            departure: source.departure,
            arrival: source.arrival,
            serviceName: source.serviceName,
            resolvedTripID: trip.id
        )

        let selection = try XCTUnwrap(
            TrainLiveActivitySelection(trip: trip, segment: opaque, plans: [])
        )
        let attributes = selection.attributes(at: trip.serviceDate)

        XCTAssertEqual(selection.boarding.station.id, trip.stopTimes[1].station.id)
        XCTAssertEqual(selection.alighting.station.id, trip.stopTimes[2].station.id)
        XCTAssertEqual(attributes.boardingStationID, trip.stopTimes[1].station.id.rawValue)
        XCTAssertEqual(attributes.alightingStationID, trip.stopTimes[2].station.id.rawValue)
    }

    func testStandaloneTrainRetainsFullEndpointsWithoutInventingAStationTimeZone() throws {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let selection = try XCTUnwrap(TrainLiveActivitySelection(trip: trip, segment: nil, plans: []))
        XCTAssertEqual(selection.boarding, trip.stopTimes.first)
        XCTAssertEqual(selection.alighting, trip.stopTimes.last)
        XCTAssertTrue(selection.stationTimeZones.isEmpty)
    }

    func testUnknownReversedAndIdenticalSelectedEndpointsAreRejected() {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let missing = RailPlace(
            id: RailIdentifier(rawValue: "us:station:missing"), kind: .station,
            displayName: "Missing", context: "", countryCode: "US",
            timeZoneIdentifier: "America/New_York", location: .init(latitude: 0, longitude: 0),
            eligibleModes: ["longDistanceRail"], attributions: []
        )
        let unknown = JourneyPlanSegment(
            id: "unknown", kind: .rail, from: missing, to: place(trip.stopTimes[2].station),
            resolvedTripID: trip.id
        )
        for invalid in [unknown, segment(trip, from: 2, to: 1), segment(trip, from: 1, to: 1)] {
            XCTAssertNil(TrainLiveActivitySelection(trip: trip, segment: invalid, plans: []))
        }
    }

    func testRepeatedEndpointStationCannotSelectAnArbitraryCall() {
        let original = TripDetailTimeZoneFixtures.easternRoute().trip
        let repeated = TripDetailTimeZoneFixtures.trip(stations: [
            original.stopTimes[0].station, original.stopTimes[1].station, original.stopTimes[0].station,
        ])
        XCTAssertNil(TrainLiveActivitySelection(trip: repeated, segment: nil, plans: []))
        XCTAssertNil(TrainLiveActivitySelection(
            trip: repeated, segment: segment(repeated, from: 0, to: 1), plans: []
        ))
    }

    func testExplicitWalkingUnresolvedAndUnrelatedRailSegmentsAreRejected() {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let from = place(trip.stopTimes[0].station)
        let to = place(trip.stopTimes[2].station)
        let invalid = [
            JourneyPlanSegment(id: "walk", kind: .walk, from: from, to: to, resolvedTripID: trip.id),
            JourneyPlanSegment(id: "unresolved", kind: .rail, from: from, to: to),
            JourneyPlanSegment(
                id: "unrelated", kind: .rail, from: from, to: to,
                resolvedTripID: RailIdentifier(rawValue: "us:amtrak:other-train")
            ),
            JourneyPlanSegment(
                id: "unavailable", kind: .rail, from: from, to: to, resolvedTripID: trip.id,
                unavailableReason: "This selected leg is unavailable."
            ),
        ]
        for segment in invalid {
            XCTAssertNil(TrainLiveActivitySelection(trip: trip, segment: segment, plans: []), segment.id)
        }
    }

    func testAmbiguousSavedLegsRequireAnExplicitSelection() throws {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let first = segment(trip, id: "first", from: 0, to: 1)
        let second = segment(trip, id: "second", from: 1, to: 2)
        let saved = plan(trip, segments: [first, second])
        XCTAssertNil(JourneyTripContext.selectedSegment(for: trip.id, plans: [saved]))
        XCTAssertNil(TrainLiveActivitySelection(trip: trip, segment: nil, plans: [saved]))
        let explicit = try XCTUnwrap(TrainLiveActivitySelection(trip: trip, segment: second, plans: [saved]))
        XCTAssertEqual(explicit.boarding.station.id, second.from.id)
        XCTAssertEqual(explicit.alighting.station.id, second.to.id)
    }

    func testExplicitEmptySavedSelectionCannotExpandToFullTrain() {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        XCTAssertNil(TrainLiveActivitySelection(trip: trip, segment: nil, plans: [plan(trip, segments: [])]))
    }

    func testFailedRefreshPreservesSuccessfulCheckAndMakesSelectedContentStale() throws {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let selection = try XCTUnwrap(TrainLiveActivitySelection(
            trip: trip, segment: segment(trip, from: 1, to: 2), plans: []
        ))
        let date = TripDetailTimeZoneFixtures.date("2026-09-15T22:10:00Z")
        let checkedAt = date.addingTimeInterval(-30)
        let projection = selection.projection(at: date, checkedAt: checkedAt, refreshFailed: true)
        XCTAssertEqual(projection.state.checkedAt, checkedAt.timeIntervalSince1970)
        XCTAssertEqual(projection.state.validUntil, date.timeIntervalSince1970)
        XCTAssertFalse(projection.shouldEnd)
    }

    private func segment(_ trip: TrainTrip, id: String = "selected", from: Int, to: Int) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: id, kind: .rail,
            from: place(trip.stopTimes[from].station), to: place(trip.stopTimes[to].station),
            departure: trip.stopTimes[from].scheduledDeparture, arrival: trip.stopTimes[to].scheduledArrival,
            serviceName: trip.product, resolvedTripID: trip.id
        )
    }

    private func place(_ station: Station) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName, context: "US",
            countryCode: "US", timeZoneIdentifier: "America/New_York", location: station.location,
            eligibleModes: ["longDistanceRail"], attributions: []
        )
    }

    private func opaquePlace(_ place: RailPlace, suffix: String) -> RailPlace {
        let payload = Data("\(suffix)\u{1f}\(place.countryCode)\u{1f}\u{1f}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return RailPlace(
            id: RailIdentifier(rawValue: "rail:transitous:station:\(payload)"),
            kind: .station,
            displayName: place.displayName,
            context: place.context,
            countryCode: place.countryCode,
            timeZoneIdentifier: place.timeZoneIdentifier,
            location: place.location,
            eligibleModes: place.eligibleModes,
            attributions: place.attributions
        )
    }

    private func plan(_ trip: TrainTrip, segments: [JourneyPlanSegment]) -> TrackedJourneyPlan {
        TrackedJourneyPlan(
            id: UUID(), createdAt: trip.serviceDate,
            origin: place(trip.stopTimes[0].station), destination: place(trip.stopTimes[2].station),
            outbound: JourneyPlanDirection(
                fingerprint: "test", departure: trip.serviceDate,
                arrival: trip.stopTimes[2].scheduledArrival ?? trip.serviceDate,
                childTripIDs: [trip.id], selectedSegments: segments
            ),
            returnDirection: nil, preExistingChildTripIDs: []
        )
    }
}
