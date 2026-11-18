import Foundation
import Testing
@testable import TrainTrackerCore

@Test func realtimeEnricherUsesFreshestCountryPlatformUpdate() async throws {
    let now = Date(timeIntervalSince1970: 1_784_600_000)
    let station = Station(
        id: RailIdentifier(region: "eu", source: "transitous", nativeID: "de-test"),
        names: [LocalizedStationName("Berlin Hbf")],
        location: GeoCoordinate(latitude: 52.5, longitude: 13.3),
        countryCode: "DE"
    )
    let tripID = RailIdentifier(region: "eu", source: "transitous", nativeID: "ice-1")
    let trip = TrainTrip(
        id: tripID,
        source: "transitous",
        serviceDate: now,
        operatorName: "DB",
        product: "ICE 1",
        headsign: "Paris",
        stopTimes: [
            StopTime(
                station: station,
                sequence: 1,
                scheduledDeparture: now,
                plannedPlatform: "7",
                expectedPlatform: "7"
            ),
        ],
        capabilities: TransitousMapper.capabilities
    )
    let older = PlatformFixtureOverlay(platform: "8", observedAt: now, sourceName: "unified")
    let country = PlatformFixtureOverlay(
        platform: "9",
        observedAt: now.addingTimeInterval(10),
        sourceName: "db-timetables"
    )
    let enricher = RealtimeTripEnricher(overlays: [older, country])

    let enriched = await enricher.enrich(trip)

    #expect(enriched.stopTimes.first?.plannedPlatform == "7")
    #expect(enriched.stopTimes.first?.expectedPlatform == "9")
    #expect(enriched.stopTimes.first?.didPlatformChange == true)
}

private struct PlatformFixtureOverlay: PlatformRealtimeOverlay {
    let platform: String
    let observedAt: Date
    let sourceName: String
    let supportedCountryCodes: Set<String> = ["DE"]

    func platformUpdates(for trip: TrainTrip) async throws -> [PlatformUpdate] {
        [
            PlatformUpdate(
                tripID: trip.id,
                stopSequence: 1,
                expectedPlatform: platform,
                observedAt: observedAt,
                source: sourceName
            ),
        ]
    }
}
