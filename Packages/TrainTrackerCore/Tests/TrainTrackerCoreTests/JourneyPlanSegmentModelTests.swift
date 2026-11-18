import Foundation
import Testing
@testable import TrainTrackerCore

@Suite("JourneyPlanSegmentModelTests")
struct JourneyPlanSegmentModelTests {
    @Test func legacyDirectionDecodesWithoutInventedSegments() throws {
        let data = Data(#"{"fingerprint":"legacy","departure":100,"arrival":200,"childTripIDs":["us:fixture:full-trip"]}"#.utf8)
        let direction = try JSONDecoder().decode(JourneyPlanDirection.self, from: data)

        #expect(direction.selectedSegments == nil)
        #expect(direction.selectedSegment(for: tripID) == nil)
        #expect(direction.ambiguousTripIDs.isEmpty)
        let reencoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(direction)
        ) as? [String: Any])
        #expect(reencoded["selectedSegments"] == nil)
    }

    @Test func orderedRailWalkAndUnsupportedSegmentsRoundTrip() throws {
        let first = leg(id: "board", tripID: tripID)
        let walk = JourneyPlanSegment(
            id: "station-change", kind: .walk, from: place("transfer"), to: place("other-station"),
            duration: 420, isStationChange: true
        )
        let unsupported = JourneyPlanSegment(
            id: "unsupported", kind: .rail, from: walk.to, to: place("destination"),
            departure: Date(timeIntervalSince1970: 500),
            arrival: Date(timeIntervalSince1970: 800),
            serviceName: "Regional 10", unavailableReason: "Tracking is unavailable."
        )
        let direction = direction(segments: [first, walk, unsupported])
        let decoded = try JSONDecoder().decode(
            JourneyPlanDirection.self, from: JSONEncoder().encode(direction)
        )

        #expect(decoded == direction)
        #expect(decoded.selectedSegments?.map(\.id) == ["board", "station-change", "unsupported"])
        #expect(decoded.selectedSegment(for: tripID) == first)
        #expect(decoded.selectedSegments?[1].departure == nil)
        #expect(decoded.selectedSegments?[1].arrival == nil)
        #expect(decoded.selectedSegments?[1].duration == 420)
        #expect(decoded.selectedSegments?[1].isStationChange == true)
        #expect(decoded.selectedSegments?[2].resolvedTripID == nil)
        #expect(decoded.selectedSegments?[2].unavailableReason == "Tracking is unavailable.")
        assertSendable(decoded)
    }

    @Test func duplicateFullTrainUseIsAmbiguousAndCannotSelectAnArbitraryLeg() {
        let first = leg(id: "first-use", tripID: tripID)
        let second = leg(id: "second-use", tripID: tripID)
        let uniqueID = RailIdentifier(rawValue: "us:fixture:other-trip")
        let unique = leg(id: "unique", tripID: uniqueID)
        let direction = direction(segments: [first, unique, second])

        #expect(direction.ambiguousTripIDs == [tripID])
        #expect(direction.selectedSegment(for: tripID) == nil)
        #expect(direction.selectedSegment(for: uniqueID) == unique)
        #expect(direction.selectedSegment(for: RailIdentifier(rawValue: "us:fixture:absent")) == nil)
    }

    @Test func missingContextAndExplicitEmptySelectionStayDistinct() throws {
        let empty = direction(segments: [])
        let decoded = try JSONDecoder().decode(
            JourneyPlanDirection.self, from: JSONEncoder().encode(empty)
        )
        #expect(decoded.selectedSegments == [])
        #expect(decoded.selectedSegment(for: tripID) == nil)
    }

    private var tripID: RailIdentifier { RailIdentifier(rawValue: "us:fixture:full-trip") }

    private func direction(segments: [JourneyPlanSegment]) -> JourneyPlanDirection {
        JourneyPlanDirection(
            fingerprint: "selected", departure: Date(timeIntervalSince1970: 100),
            arrival: Date(timeIntervalSince1970: 800), childTripIDs: [tripID],
            selectedSegments: segments
        )
    }

    private func leg(id: String, tripID: RailIdentifier) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: id, kind: .rail, from: place("boarding"), to: place("alighting"),
            departure: Date(timeIntervalSince1970: 100),
            arrival: Date(timeIntervalSince1970: 400),
            serviceName: "Express 5", resolvedTripID: tripID
        )
    }

    private func place(_ name: String) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: "us:fixture:\(name)"), kind: .station,
            displayName: name, context: "Fixture", countryCode: "US",
            timeZoneIdentifier: "America/New_York",
            location: GeoCoordinate(latitude: 40, longitude: -74),
            eligibleModes: ["longDistanceRail"], attributions: ["Fixture"]
        )
    }

    private func assertSendable<T: Sendable>(_ value: T) {}
}
