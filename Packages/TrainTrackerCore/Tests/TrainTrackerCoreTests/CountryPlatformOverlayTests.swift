import Foundation
import Testing
@testable import TrainTrackerCore

@Test func irailMatchesBelgianTrainNumberAndPlatform() async throws {
    let client = try FixtureHTTPClient(routes: [
        "/v1/liveboard": fixture("liveboard", directory: "IRail"),
    ])
    let scheduled = Date(timeIntervalSince1970: 1_784_575_200)
    let trip = fixtureTrip(
        countryCode: "BE",
        nativeStationID: "be-brussels",
        product: "IC 1234",
        scheduled: scheduled
    )
    let overlay = IRailPlatformOverlay(
        client: client,
        baseURL: try #require(URL(string: "https://fixture.test/v1")),
        now: { scheduled }
    )

    let updates = try await overlay.platformUpdates(for: trip)

    #expect(updates.first?.expectedPlatform == "5")
    #expect(updates.first?.stopSequence == 1)
}

@Test func renfeParsesPlatformFromOfficialVehicleLabel() async throws {
    let client = try FixtureHTTPClient(routes: [
        "/vehicle_positions.json": fixture("vehicle_positions", directory: "RenfeRealtime"),
    ])
    let trip = fixtureTrip(
        countryCode: "ES",
        nativeStationID: "es-feed-51003",
        product: "C1 23573",
        scheduled: Date(timeIntervalSince1970: 1_784_575_200)
    )
    let overlay = RenfePlatformOverlay(
        client: client,
        feedURL: try #require(URL(string: "https://fixture.test/vehicle_positions.json"))
    )

    let updates = try await overlay.platformUpdates(for: trip)

    #expect(updates.first?.expectedPlatform == "8")
    #expect(updates.first?.stationID?.nativeID == "es-feed-51003")
}

private func fixtureTrip(
    countryCode: String,
    nativeStationID: String,
    product: String,
    scheduled: Date
) -> TrainTrip {
    let station = Station(
        id: RailIdentifier(region: "eu", source: "transitous", nativeID: nativeStationID),
        names: [LocalizedStationName("Fixture Central")],
        location: GeoCoordinate(latitude: 0, longitude: 0),
        countryCode: countryCode
    )
    return TrainTrip(
        id: RailIdentifier(region: "eu", source: "transitous", nativeID: "fixture-trip"),
        source: "transitous",
        serviceDate: scheduled,
        operatorName: "Fixture Rail",
        product: product,
        headsign: "Destination",
        stopTimes: [
            StopTime(station: station, sequence: 1, scheduledDeparture: scheduled),
        ],
        capabilities: TransitousMapper.capabilities
    )
}
