import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyNavigationRequestTests: XCTestCase {
    func testActivityDeepLinkRoundTripsPercentEncodedIdentifiers() throws {
        let attributes = TrainJourneyAttributes(
            activityKey: "test", tripID: "eu:transitous:ICE 42/A&B?λ=7#tag%25",
            boardingStationID: "de:station:Berlin & Süd/α?",
            alightingStationID: "fr:station:Paris+Nord=1#quai",
            serviceName: "Intercity", originName: "Berlin", destinationName: "Paris",
            startedAt: 1_800_000_000
        )
        let request = try XCTUnwrap(JourneyNavigationRequest(url: try XCTUnwrap(attributes.deepLinkURL)))
        XCTAssertEqual(request.tripID.rawValue, attributes.tripID)
        XCTAssertEqual(request.boardingStationID, attributes.boardingStationID)
        XCTAssertEqual(request.alightingStationID, attributes.alightingStationID)
    }

    func testTripOnlyLinkPreservesLegacyNavigationWithoutInventingEndpoints() throws {
        let request = try XCTUnwrap(JourneyNavigationRequest(url: url(query: "trip=us:amtrak:2162")))
        XCTAssertEqual(request.tripID.rawValue, "us:amtrak:2162")
        XCTAssertNil(request.boardingStationID)
        XCTAssertNil(request.alightingStationID)
    }

    func testMissingMixedEmptyAndDuplicateIdentifiersAreRejected() throws {
        let queries = [
            "", "boarding=a&alighting=b", "trip", "trip=",
            "trip=t&boarding=a", "trip=t&alighting=b",
            "trip=t&boarding=&alighting=b", "trip=t&boarding=a&alighting=",
            "trip=t&boarding&alighting", "trip=t&boarding=&alighting=",
            "trip=t&trip=u", "trip=t&boarding=a&boarding=c&alighting=b",
            "trip=t&boarding=a&alighting=b&alighting=c",
        ]
        for query in queries {
            XCTAssertNil(JourneyNavigationRequest(url: try url(query: query)), query)
        }
    }

    func testExternalURLsAndUnexpectedAuthorityPathOrFragmentAreRejected() throws {
        let values = [
            "https://journey?trip=t", "https://example.test/journey?trip=t",
            "http://journey?trip=t", "otherapp://journey?trip=t",
            "traintracker://other?trip=t", "traintracker://journey/extra?trip=t",
            "traintracker://user@journey?trip=t", "traintracker://user:password@journey?trip=t",
            "traintracker://journey?trip=t#fragment",
        ]
        for value in values {
            XCTAssertNil(JourneyNavigationRequest(url: try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testIdentifierLimitsApplyToDecodedUTF8Bytes() throws {
        for (trip, boarding, alighting) in [
            (String(repeating: "t", count: 513), "a", "b"),
            ("trip", String(repeating: "a", count: 257), "b"),
            ("trip", "a", String(repeating: "東", count: 86)),
        ] {
            let attributes = TrainJourneyAttributes(
                activityKey: "test", tripID: trip, boardingStationID: boarding,
                alightingStationID: alighting, serviceName: "Train", originName: "Origin",
                destinationName: "Destination", startedAt: 1_800_000_000
            )
            XCTAssertNil(JourneyNavigationRequest(url: try XCTUnwrap(attributes.deepLinkURL)))
        }
    }

    func testExplicitSelectedStopsResolveTheirOwnTimesAndStations() throws {
        let fixture = TripDetailTimeZoneFixtures.easternRoute()
        let trip = fixture.trip
        let request = JourneyNavigationRequest(
            tripID: trip.id, boardingStationID: trip.stopTimes[1].station.id.rawValue,
            alightingStationID: trip.stopTimes[2].station.id.rawValue
        )
        let selected = try XCTUnwrap(request.selectedSegment(trip: trip, plans: [fixture.plan]))
        XCTAssertEqual(selected.kind, .rail)
        XCTAssertEqual(selected.resolvedTripID, trip.id)
        XCTAssertEqual(selected.from.id, trip.stopTimes[1].station.id)
        XCTAssertEqual(selected.to.id, trip.stopTimes[2].station.id)
        XCTAssertEqual(selected.departure, trip.stopTimes[1].scheduledDeparture)
        XCTAssertEqual(selected.arrival, trip.stopTimes[2].scheduledArrival)
        XCTAssertEqual(selected.from.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(selected.to.timeZoneIdentifier, "America/New_York")
    }

    func testInvalidSelectedBoundsNeverFallBackToAnAvailableSavedSegment() {
        let fixture = TripDetailTimeZoneFixtures.easternRoute()
        let trip = fixture.trip
        let validRequest = JourneyNavigationRequest(
            tripID: trip.id, boardingStationID: trip.stopTimes[0].station.id.rawValue,
            alightingStationID: trip.stopTimes[2].station.id.rawValue
        )
        let savedSegment = validRequest.selectedSegment(trip: trip, plans: [fixture.plan])
        let savedPlan = TrackedJourneyPlan(
            id: fixture.plan.id, createdAt: fixture.plan.createdAt,
            origin: fixture.plan.origin, destination: fixture.plan.destination,
            outbound: JourneyPlanDirection(
                fingerprint: "selected", departure: fixture.plan.outbound.departure,
                arrival: fixture.plan.outbound.arrival, childTripIDs: [trip.id],
                selectedSegments: savedSegment.map { [$0] }
            ),
            returnDirection: nil, preExistingChildTripIDs: []
        )
        let origin = trip.stopTimes[0].station.id.rawValue
        let destination = trip.stopTimes[2].station.id.rawValue
        for (boarding, alighting) in [("missing", destination), (destination, origin), (origin, origin)] {
            let invalid = JourneyNavigationRequest(
                tripID: trip.id, boardingStationID: boarding, alightingStationID: alighting
            )
            XCTAssertNil(invalid.selectedSegment(trip: trip, plans: [savedPlan]))
        }
    }

    func testRepeatedStationCallsDoNotSelectAnArbitraryOccurrence() {
        let original = TripDetailTimeZoneFixtures.easternRoute().trip
        let trip = TripDetailTimeZoneFixtures.trip(stations: [
            original.stopTimes[0].station, original.stopTimes[1].station, original.stopTimes[0].station,
        ])
        let request = JourneyNavigationRequest(
            tripID: trip.id, boardingStationID: trip.stopTimes[0].station.id.rawValue,
            alightingStationID: trip.stopTimes[1].station.id.rawValue
        )
        XCTAssertNil(request.selectedSegment(trip: trip, plans: []))
    }

    func testSelectionRejectsATrainWhoseIdentityDoesNotMatchTheRequest() {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let request = JourneyNavigationRequest(
            tripID: RailIdentifier(rawValue: "us:amtrak:another-train"),
            boardingStationID: trip.stopTimes[0].station.id.rawValue,
            alightingStationID: trip.stopTimes[2].station.id.rawValue
        )
        XCTAssertNil(request.selectedSegment(trip: trip, plans: []))
    }

    private func url(query: String) throws -> URL {
        try XCTUnwrap(URL(string: "traintracker://journey?\(query)"))
    }
}
