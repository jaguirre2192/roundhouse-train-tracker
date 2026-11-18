import Foundation
import Testing
@testable import TrainTrackerCore

@Suite("JourneySearchModelTests")
struct JourneySearchModelTests {
    @Test func searchValuesRoundTripAndExposeIdentityAndTrackability() throws {
        let option = makeJourneyOption()
        let page = JourneySearchPage(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
            options: [option],
            previousCursor: "previous",
            nextCursor: "next",
            warnings: ["Realtime coverage varies."],
            attributions: ["Fixture Rail"]
        )
        let criteria = JourneySearchCriteria(
            originID: makePlace(id: "origin").id,
            destinationID: makePlace(id: "destination").id,
            requestedTime: Date(timeIntervalSince1970: 1_800_100_000),
            timeZoneIdentifier: "Europe/Paris",
            arriveBy: false,
            maximumTransfers: 2,
            cursor: "later"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(JourneySearchPage.self, from: encoder.encode(page)) == page)
        #expect(try decoder.decode(JourneySearchCriteria.self, from: encoder.encode(criteria)) == criteria)
        #expect(option.id == "option-1")
        #expect(option.segments.map(\.id) == ["rail-1", "walk-1"])
        #expect(option.trackability.trackableRailSegments == 1)
        #expect(option.trackability.totalRailSegments == 2)
        #expect(option.badges == [.direct, .fastest, .fewestChanges])
        #expect(Set([makePlace(id: "origin")]).count == 1)
        requireSendable(page)
    }

    @Test func railSegmentCodableUsesExplicitDiscriminatorShape() throws {
        let segment = JourneySegment.rail(makeRailSegment())

        let data = try JSONEncoder().encode(segment)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try #require(object["rail"] as? [String: Any])

        #expect(object["id"] as? String == "rail-1")
        #expect(object["kind"] as? String == "rail")
        #expect(object["walk"] is NSNull)
        #expect(rail["id"] == nil)
        #expect(rail["tripId"] as? String == "eu:fixture:train-1")
        #expect(try JSONDecoder().decode(JourneySegment.self, from: data) == segment)
    }

    @Test func walkSegmentCodableUsesExplicitDiscriminatorShape() throws {
        let segment = JourneySegment.walk(makeWalkSegment())

        let data = try JSONEncoder().encode(segment)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let walk = try #require(object["walk"] as? [String: Any])

        #expect(object["id"] as? String == "walk-1")
        #expect(object["kind"] as? String == "walk")
        #expect(object["rail"] is NSNull)
        #expect(walk["id"] == nil)
        #expect(walk["isStationChange"] as? Bool == true)
        #expect(try JSONDecoder().decode(JourneySegment.self, from: data) == segment)
    }
}

private func makeJourneyOption() -> JourneyOption {
    JourneyOption(
        id: "option-1",
        fingerprint: "fingerprint-1",
        startTime: Date(timeIntervalSince1970: 1_800_100_000),
        endTime: Date(timeIntervalSince1970: 1_800_107_200),
        duration: 7_200,
        transferCount: 1,
        segments: [.rail(makeRailSegment()), .walk(makeWalkSegment())],
        badges: [.direct, .fastest, .fewestChanges],
        trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 2),
        realtimeFreshness: Date(timeIntervalSince1970: 1_800_099_970),
        attributions: ["Fixture Rail"],
        trackingToken: "tracking-token"
    )
}

private func makeRailSegment() -> RailJourneySegment {
    RailJourneySegment(
        id: "rail-1",
        tripID: RailIdentifier(rawValue: "eu:fixture:train-1"),
        serviceDate: Date(timeIntervalSince1970: 1_800_057_600),
        operatorName: "Fixture Rail",
        product: "Intercity",
        trainNumber: "IC 1",
        trainName: "Fixture Express",
        from: makeCall(id: "origin", departure: Date(timeIntervalSince1970: 1_800_100_000)),
        to: makeCall(id: "destination", arrival: Date(timeIntervalSince1970: 1_800_107_200)),
        intermediateCalls: [],
        isCancelled: false,
        isRealtime: true,
        isTrackable: true,
        untrackableReason: nil
    )
}

private func makeWalkSegment() -> WalkJourneySegment {
    WalkJourneySegment(
        id: "walk-1",
        from: makePlace(id: "platform-a"),
        to: makePlace(id: "platform-b"),
        duration: 420,
        distance: 350,
        isStationChange: true
    )
}

private func makeCall(id: String, arrival: Date? = nil, departure: Date? = nil) -> JourneyCall {
    JourneyCall(
        place: makePlace(id: id),
        city: makePlace(id: "\(id)-city", kind: .city),
        scheduledArrival: arrival,
        scheduledDeparture: departure,
        expectedArrival: arrival,
        expectedDeparture: departure,
        plannedPlatform: "1",
        expectedPlatform: "2",
        isCancelled: false
    )
}

private func makePlace(id: String, kind: RailPlace.Kind = .station) -> RailPlace {
    RailPlace(
        id: RailIdentifier(rawValue: "eu:fixture:\(id)"),
        kind: kind,
        displayName: id.capitalized,
        context: "Fixtureland",
        countryCode: "FX",
        timeZoneIdentifier: "Europe/Paris",
        location: GeoCoordinate(latitude: 48.8, longitude: 2.3),
        eligibleModes: ["longDistanceRail"],
        attributions: ["Fixture Rail"]
    )
}

private func requireSendable<T: Sendable>(_ value: T) {}
