import Foundation
import Testing
@testable import TrainTrackerCore

@Test func tripSortsStopsAndReportsNextDelay() {
    let scheduled = Date(timeIntervalSince1970: 1_800_000_000)
    let stationA = Station(
        id: RailIdentifier(region: "us", source: "gtfs", nativeID: "A"),
        names: [LocalizedStationName("Alpha")],
        location: GeoCoordinate(latitude: 0, longitude: 0),
        countryCode: "US"
    )
    let stationB = Station(
        id: RailIdentifier(region: "us", source: "gtfs", nativeID: "B"),
        names: [LocalizedStationName("Bravo")],
        location: GeoCoordinate(latitude: 1, longitude: 1),
        countryCode: "US"
    )
    let laterStop = StopTime(
        station: stationB,
        sequence: 2,
        scheduledArrival: scheduled,
        expectedArrival: scheduled.addingTimeInterval(7 * 60)
    )
    let passedStop = StopTime(
        station: stationA,
        sequence: 1,
        scheduledDeparture: scheduled,
        expectedDeparture: scheduled.addingTimeInterval(5 * 60),
        isPassed: true,
        passageObservedAt: .now.addingTimeInterval(-60)
    )
    let trip = TrainTrip(
        id: RailIdentifier(region: "us", source: "amtraker", nativeID: "171"),
        source: "amtraker",
        serviceDate: scheduled,
        operatorName: "Amtrak",
        product: "Northeast Regional",
        headsign: "Boston",
        stopTimes: [laterStop, passedStop],
        capabilities: RealtimeCapabilities(
            hasPositions: true,
            hasPlatforms: true,
            hasRealtimeDelays: true,
            hasAlerts: true,
            granularity: .perStop
        )
    )

    #expect(trip.origin?.displayName == "Alpha")
    #expect(trip.nextStop?.station.displayName == "Bravo")
    #expect(trip.currentDelayMinutes == 7)
}
