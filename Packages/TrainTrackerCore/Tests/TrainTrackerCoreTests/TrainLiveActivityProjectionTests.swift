import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct TrainLiveActivityProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func matchesSharedServerProjectionCases() throws {
        let url = try #require(Bundle.module.url(forResource: "projection-cases", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(ProjectionFixtures.self, from: Data(contentsOf: url))
        #expect(fixtures.schemaVersion == 1)
        #expect(fixtures.cases.count >= 27)
        for fixture in fixtures.cases {
            let projection = fixture.input.projection
            #expect(projection.state == fixture.expected.state, "\(fixture.name)")
            #expect(projection.eligibility == fixture.expected.availability, "\(fixture.name)")
            #expect(projection.nextTransitionDate?.timeIntervalSince1970 == fixture.expected.nextTransitionDate,
                    "\(fixture.name)")
            #expect(projection.shouldEnd == fixture.expected.shouldEnd, "\(fixture.name)")
            let encoded = try JSONEncoder().encode(projection.state)
            #expect(encoded.count < 2_048, "\(fixture.name)")
            #expect(try JSONDecoder().decode(TrainLiveActivityState.self, from: encoded) == projection.state)
        }
    }

    @Test func likelyPlatformExpiresAndNeverBecomesReported() {
        let forecast = forecast(state: .likelyPlatform, expiresAt: now.addingTimeInterval(120))
        let trip = trip(originForecast: forecast)
        let current = TrainLiveActivityProjection(trip: trip, referenceDate: now, lastSuccessfulCheck: now)
        #expect(current.state.platform == "9")
        #expect(current.state.platformBasis == .predicted)
        #expect(!current.state.platformChanged)
        #expect(current.state.validUntil == now.addingTimeInterval(120).timeIntervalSince1970)
        #expect(current.nextTransitionDate == now.addingTimeInterval(120))

        let expired = TrainLiveActivityProjection(
            trip: trip, referenceDate: now.addingTimeInterval(120), lastSuccessfulCheck: now
        )
        #expect(expired.state.platform == nil)
        #expect(expired.state.platformBasis == .unavailable)
    }

    @Test func positioningZoneDoesNotMasqueradeAsAnExactPlatform() {
        let projection = TrainLiveActivityProjection(
            trip: trip(originForecast: forecast(state: .positioning, expiresAt: now.addingTimeInterval(120))),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(projection.state.platform == nil)
        #expect(projection.state.platformBasis == .unavailable)
    }

    @Test func forecastGeneratedInTheFutureIsUnavailable() {
        let projection = TrainLiveActivityProjection(
            trip: trip(originForecast: forecast(
                state: .likelyPlatform, expiresAt: now.addingTimeInterval(120),
                generatedAt: now.addingTimeInterval(60)
            )),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(projection.state.platform == nil)
        #expect(projection.state.platformBasis == .unavailable)
    }

    @Test func freshOfficialPlatformTakesPrecedenceOverForecast() {
        let projection = TrainLiveActivityProjection(
            trip: trip(
                plannedPlatform: " 2 ", expectedPlatform: " 5 ",
                originForecast: forecast(state: .likelyPlatform, expiresAt: now.addingTimeInterval(120))
            ),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(projection.state.platform == "5")
        #expect(projection.state.platformBasis == .reported)
        #expect(projection.state.platformChanged)
        #expect(projection.state.validUntil == now.addingTimeInterval(300).timeIntervalSince1970)
    }

    @Test func invalidNumbersNeverEscapeIntoTheActivityPayload() throws {
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let projection = TrainLiveActivityProjection(
                trip: trip(), referenceDate: Date(timeIntervalSince1970: invalid),
                lastSuccessfulCheck: Date(timeIntervalSince1970: invalid)
            )
            #expect(projection.eligibility == .unavailable)
            #expect(!projection.shouldEnd)
            #expect(projection.state.checkedAt == nil)
            #expect(projection.state.validUntil == 0)
            _ = try JSONEncoder().encode(projection.state)

            let state = TrainLiveActivityState(
                phase: .upcoming, focusName: "Origin", eventTime: invalid,
                timingBasis: .estimated, delayMinutes: .max, checkedAt: invalid, validUntil: invalid
            )
            #expect(state.eventTime == nil)
            #expect(state.timingBasis == .unavailable)
            #expect(state.delayMinutes == nil)
            #expect(state.checkedAt == nil)
            #expect(state.validUntil == 0)
            _ = try JSONEncoder().encode(state)
        }
    }

    @Test func contentRemainsSmallAndSanitizedAfterRemoteDecoding() throws {
        let original = TrainLiveActivityState(
            phase: .upcoming, focusName: "Origin", eventTime: now.timeIntervalSince1970,
            timeZoneIdentifier: "Europe/London", timingBasis: .scheduled,
            platform: "2", platformBasis: .reported, validUntil: now.timeIntervalSince1970
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["focusName"] = String(repeating: "🚆\n\t\\\"", count: 5_000)
        object["platform"] = String(repeating: "東\r", count: 5_000)
        object["timeZoneIdentifier"] = "Unknown/Station"
        let state = try JSONDecoder().decode(
            TrainLiveActivityState.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(state.focusName.utf8.count <= 160)
        #expect((state.platform?.utf8.count ?? 0) <= 32)
        #expect(!state.focusName.contains("\n"))
        #expect(!state.focusName.contains("\t"))
        #expect(state.timeZoneIdentifier == nil)
        #expect(try JSONEncoder().encode(state).count < 2_048)
    }

    @Test func expiredTimetableCannotEndActivityWithoutObservedArrival() {
        let expired = observedTrip()
        let unknown = TrainLiveActivityProjection(trip: expired, referenceDate: now, lastSuccessfulCheck: now)
        #expect(unknown.state.phase == .unavailable)
        #expect(unknown.eligibility == .unavailable)
        #expect(unknown.state.validUntil == now.timeIntervalSince1970)
        #expect(!unknown.shouldEnd)

        let freshPosition = VehiclePosition(coordinate: GeoCoordinate(latitude: 39.5, longitude: -76.5),
                                            source: .real, confidence: 1, asOf: now.addingTimeInterval(-60))
        let underway = TrainLiveActivityProjection(trip: observedTrip(position: freshPosition),
                                                  referenceDate: now, lastSuccessfulCheck: now)
        #expect(underway.state.phase == .underway)
        #expect(underway.eligibility == .available)
        #expect(!underway.shouldEnd)
        let stale = TrainLiveActivityProjection(trip: observedTrip(position: freshPosition),
                                               referenceDate: now.addingTimeInterval(301),
                                               lastSuccessfulCheck: now.addingTimeInterval(301))
        #expect(stale.state.phase == .unavailable)
        #expect(!stale.shouldEnd)
    }

    @Test func observedArrivalEndsOnlyAfterRecoveryAndLegacyPassedFlagDoesNot() {
        let legacy = TrainLiveActivityProjection(trip: observedTrip(passed: true),
                                               referenceDate: now, lastSuccessfulCheck: now)
        #expect(legacy.state.phase == .unavailable)
        #expect(!legacy.shouldEnd)
        let arrived = TrainLiveActivityProjection(
            trip: observedTrip(arrivalObservedAt: now.addingTimeInterval(-1_800)),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(arrived.state.phase == .ended)
        #expect(arrived.shouldEnd)
        let justArrived = TrainLiveActivityProjection(trip: observedTrip(arrivalObservedAt: now, expectedArrival: now),
                                                    referenceDate: now, lastSuccessfulCheck: now)
        #expect(justArrived.state.phase == .ended)
        #expect(!justArrived.shouldEnd)
        let implausible = TrainLiveActivityProjection(
            trip: observedTrip(arrivalObservedAt: now.addingTimeInterval(121)),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(!implausible.shouldEnd)
        #expect(implausible.state.phase == .unavailable)
    }

    @Test func newerPositionBeforeDestinationOverridesOlderArrivalReport() {
        let position = VehiclePosition(coordinate: GeoCoordinate(latitude: 39.5, longitude: -77),
                                       source: .real, confidence: 1, asOf: now.addingTimeInterval(-60))
        let projection = TrainLiveActivityProjection(
            trip: observedTrip(position: position, arrivalObservedAt: now.addingTimeInterval(-1_800),
                               validStationLocations: true),
            referenceDate: now, lastSuccessfulCheck: now
        )
        #expect(projection.state.phase == .underway)
        #expect(!projection.shouldEnd)
    }

    private func observedTrip(position: VehiclePosition? = nil, passed: Bool = false,
                              arrivalObservedAt: Date? = nil, expectedArrival: Date? = nil,
                              validStationLocations: Bool = false) -> TrainTrip {
        TrainTrip(id: RailIdentifier(rawValue: "us:amtraker:171-13"), source: "amtraker", serviceDate: now,
                  operatorName: "Amtrak", product: "171", headsign: "Destination", stopTimes: [
                    StopTime(station: station("Origin", latitude: validStationLocations ? 40 : 0,
                                             longitude: validStationLocations ? -77 : 0),
                             sequence: 1, scheduledDeparture: now.addingTimeInterval(-7_200)),
                    StopTime(station: station("Destination", latitude: validStationLocations ? 39 : 0,
                                             longitude: validStationLocations ? -77 : 0),
                             sequence: 2, scheduledArrival: now.addingTimeInterval(-3_600),
                             expectedArrival: expectedArrival, isPassed: passed, arrivalObservedAt: arrivalObservedAt)
                  ], positions: position.map { [$0] } ?? [],
                  capabilities: RealtimeCapabilities(hasPositions: position != nil, hasPlatforms: false,
                      hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop))
    }

    private func trip(
        plannedPlatform: String? = nil, expectedPlatform: String? = nil,
        originForecast: PlatformForecast? = nil
    ) -> TrainTrip {
        TrainTrip(
            id: RailIdentifier(rawValue: "eu:test:train"), source: "test", serviceDate: now,
            operatorName: "Rail", product: "Regional", headsign: "Destination",
            stopTimes: [
                StopTime(
                    station: station("Origin"), sequence: 1,
                    scheduledDeparture: now.addingTimeInterval(600),
                    plannedPlatform: plannedPlatform, expectedPlatform: expectedPlatform,
                    platformForecast: originForecast
                ),
                StopTime(
                    station: station("Destination"), sequence: 2,
                    scheduledArrival: now.addingTimeInterval(3_600)
                ),
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true,
                hasAlerts: false, granularity: .perStop
            )
        )
    }

    private func station(_ name: String, latitude: Double = 0, longitude: Double = 0) -> Station {
        Station(
            id: RailIdentifier(rawValue: "eu:test:\(name)"), names: [LocalizedStationName(name)],
            location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: "GB"
        )
    }

    private func forecast(
        state: PlatformForecast.State, expiresAt: Date, generatedAt: Date? = nil
    ) -> PlatformForecast {
        PlatformForecast(
            state: state,
            zone: .init(id: "west", label: "west concourse", platforms: ["8", "9"], probability: 0.8),
            candidates: [.init(platform: "9", probability: 0.8, observationCount: 30)],
            likelyPlatform: "9", confidence: .high, evidenceCount: 30, explanation: "Prediction",
            horizon: .underFifteenMinutes, modelVersion: "1", timetablePeriod: "test",
            stationMapVersion: "1", generatedAt: generatedAt ?? now.addingTimeInterval(-60), expiresAt: expiresAt
        )
    }
}

private struct ProjectionFixtures: Decodable {
    let schemaVersion: Int
    let cases: [ProjectionFixture]
}

private struct ProjectionFixture: Decodable {
    let name: String
    let input: Input
    let expected: Expected

    struct Input: Decodable {
        let referenceDate: Double
        let lastSuccessfulCheck: Double?
        let refreshFailed: Bool
        let boardingStationID: String?
        let alightingStationID: String?
        let stationTimeZones: [String: String]
        let trip: Trip

        var projection: TrainLiveActivityProjection {
            TrainLiveActivityProjection(
                trip: trip.model, referenceDate: Date(timeIntervalSince1970: referenceDate),
                boardingStationID: boardingStationID.map { RailIdentifier(rawValue: $0) },
                alightingStationID: alightingStationID.map { RailIdentifier(rawValue: $0) },
                stationTimeZones: Dictionary(uniqueKeysWithValues: stationTimeZones.map {
                    (RailIdentifier(rawValue: $0.key), $0.value)
                }),
                lastSuccessfulCheck: lastSuccessfulCheck.map { Date(timeIntervalSince1970: $0) },
                refreshFailed: refreshFailed
            )
        }
    }

    struct Trip: Decodable {
        let id: String
        let source: String
        let stops: [Stop]

        var model: TrainTrip {
            TrainTrip(
                id: RailIdentifier(rawValue: id), source: source,
                serviceDate: Date(timeIntervalSince1970: 1_800_000_000),
                operatorName: "Rail", product: "Regional", headsign: "Destination",
                stopTimes: stops.map(\.model),
                capabilities: RealtimeCapabilities(
                    hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true,
                    hasAlerts: false, granularity: .perStop
                )
            )
        }
    }

    struct Stop: Decodable {
        let stationID: String
        let stationName: String
        let sequence: Int
        let scheduledArrival: Double?
        let scheduledDeparture: Double?
        let expectedArrival: Double?
        let expectedDeparture: Double?
        let plannedPlatform: String?
        let expectedPlatform: String?
        let isCancelled: Bool?
        let isPassed: Bool?

        var model: StopTime {
            StopTime(
                station: Station(
                    id: RailIdentifier(rawValue: stationID), names: [LocalizedStationName(stationName)],
                    location: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "GB"
                ),
                sequence: sequence,
                scheduledArrival: scheduledArrival.map { Date(timeIntervalSince1970: $0) },
                scheduledDeparture: scheduledDeparture.map { Date(timeIntervalSince1970: $0) },
                expectedArrival: expectedArrival.map { Date(timeIntervalSince1970: $0) },
                expectedDeparture: expectedDeparture.map { Date(timeIntervalSince1970: $0) },
                plannedPlatform: plannedPlatform, expectedPlatform: expectedPlatform,
                isCancelled: isCancelled ?? false, isPassed: isPassed ?? false
            )
        }
    }

    struct Expected: Decodable {
        let state: TrainLiveActivityState
        let eligibility: String
        let eligibleAt: Double?
        let nextTransitionDate: Double?
        let shouldEnd: Bool

        var availability: TrainLiveActivityProjection.Eligibility {
            switch eligibility {
            case "available": .available
            case "tooEarly": .tooEarly(Date(timeIntervalSince1970: eligibleAt ?? 0))
            case "ended": .ended
            case "cancelled": .cancelled
            default: .unavailable
            }
        }
    }
}
