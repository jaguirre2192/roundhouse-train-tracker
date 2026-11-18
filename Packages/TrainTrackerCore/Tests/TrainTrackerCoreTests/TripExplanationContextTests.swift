import Foundation
import Testing
@testable import TrainTrackerCore

@Suite("TripExplanationContextTests")
struct TripExplanationContextTests {
    @Test func preservesOfficialOperationalFactsAndFiltersExpiredAlerts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = makeTrip(
            alerts: [
                RailAlert(
                    id: RailIdentifier(rawValue: "eu:fixture:active-alert"),
                    severity: .major,
                    cause: "Signal failure",
                    message: "Expect delays between Alpha and Bravo.",
                    validFrom: now.addingTimeInterval(-300),
                    validUntil: now.addingTimeInterval(300)
                ),
                RailAlert(
                    id: RailIdentifier(rawValue: "eu:fixture:expired-alert"),
                    severity: .minor,
                    message: "Old disruption",
                    validUntil: now.addingTimeInterval(-1)
                ),
            ]
        )

        guard case .ready(let context) = TripExplanationContextBuilder.readiness(
            for: trip,
            at: now
        ) else {
            Issue.record("Expected sourced trip facts to be explanation-ready")
            return
        }

        #expect(context.providerSource == "Fixture Rail API")
        #expect(context.stops.map(\.stationName) == ["Alpha", "Bravo"])
        #expect(context.stops[0].plannedPlatform == "4")
        #expect(context.stops[0].expectedPlatform == "7")
        #expect(context.stops[1].isCancelled)
        #expect(context.alerts.map(\.message) == ["Expect delays between Alpha and Bravo."])
    }

    @Test func excludesVehiclePositionsFromTheExplanationContract() throws {
        let trip = makeTrip(positions: [
            VehiclePosition(
                coordinate: GeoCoordinate(latitude: 48.86, longitude: 2.35),
                source: .inferred,
                confidence: 0.9,
                asOf: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ])

        guard case .ready(let context) = TripExplanationContextBuilder.readiness(for: trip) else {
            Issue.record("Expected sourced trip facts to be explanation-ready")
            return
        }
        let encoded = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)

        #expect(!encoded.contains("latitude"))
        #expect(!encoded.contains("longitude"))
        #expect(!encoded.contains("position"))
    }

    @Test func abstainsWithoutProviderProvenanceOrAUsableRoute() {
        let missingSource = makeTrip(source: "   ")
        let oneStop = makeTrip(stopTimes: [makeStop(name: "Alpha", sequence: 1)])

        #expect(
            TripExplanationContextBuilder.readiness(for: missingSource)
                == .abstain(.missingProviderSource)
        )
        #expect(
            TripExplanationContextBuilder.readiness(for: oneStop)
                == .abstain(.insufficientRouteFacts)
        )
    }
}

private func makeTrip(
    source: String = "Fixture Rail API",
    stopTimes: [StopTime]? = nil,
    positions: [VehiclePosition] = [],
    alerts: [RailAlert] = []
) -> TrainTrip {
    let scheduled = Date(timeIntervalSince1970: 1_800_000_000)
    return TrainTrip(
        id: RailIdentifier(rawValue: "eu:fixture:train-1"),
        source: source,
        serviceDate: scheduled,
        operatorName: "Fixture Rail",
        product: "Intercity 10",
        headsign: "Bravo",
        stopTimes: stopTimes ?? [
            makeStop(
                name: "Alpha",
                sequence: 1,
                scheduledDeparture: scheduled,
                expectedDeparture: scheduled.addingTimeInterval(8 * 60),
                plannedPlatform: " 4 ",
                expectedPlatform: " 7 "
            ),
            makeStop(
                name: "Bravo",
                sequence: 2,
                scheduledArrival: scheduled.addingTimeInterval(3_600),
                isCancelled: true
            ),
        ],
        positions: positions,
        alerts: alerts,
        capabilities: RealtimeCapabilities(
            hasPositions: !positions.isEmpty,
            hasPlatforms: true,
            hasRealtimeDelays: true,
            hasAlerts: !alerts.isEmpty,
            granularity: .perStop
        )
    )
}

private func makeStop(
    name: String,
    sequence: Int,
    scheduledArrival: Date? = nil,
    scheduledDeparture: Date? = nil,
    expectedArrival: Date? = nil,
    expectedDeparture: Date? = nil,
    plannedPlatform: String? = nil,
    expectedPlatform: String? = nil,
    isCancelled: Bool = false
) -> StopTime {
    StopTime(
        station: Station(
            id: RailIdentifier(rawValue: "eu:fixture:\(name.lowercased())"),
            names: [LocalizedStationName(name)],
            location: GeoCoordinate(latitude: 48, longitude: 2),
            countryCode: "FR"
        ),
        sequence: sequence,
        scheduledArrival: scheduledArrival,
        scheduledDeparture: scheduledDeparture,
        expectedArrival: expectedArrival,
        expectedDeparture: expectedDeparture,
        plannedPlatform: plannedPlatform,
        expectedPlatform: expectedPlatform,
        isCancelled: isCancelled
    )
}
