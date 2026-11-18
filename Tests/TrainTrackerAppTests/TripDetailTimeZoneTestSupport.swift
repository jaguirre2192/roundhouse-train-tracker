import Foundation
import TrainTrackerCore
@testable import TrainTracker

enum TripDetailTimeZoneFixtures {
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    static let eastern = JourneyPlanRouteTimeZones(
        departureTimeZoneIdentifier: "America/New_York", arrivalTimeZoneIdentifier: "America/New_York"
    )

    static func easternRoute() -> (trip: TrainTrip, plan: TrackedJourneyPlan) {
        let trip = trip(stations: [
            station("WAS", "Washington Union Station", 38.897, -77.006),
            station("NYP", "New York Penn Station", 40.750, -73.994),
            station("BOS", "Boston South Station", 42.352, -71.055),
        ])
        return (trip, plan(trip, departureZone: "America/New_York", arrivalZone: "America/New_York"))
    }

    static func westernRoute() -> (trip: TrainTrip, plan: TrackedJourneyPlan, denverPlan: TrackedJourneyPlan) {
        let chicago = station("CHI", "Chicago Union Station", 41.879, -87.640)
        let denver = station("DEN", "Denver Union Station", 39.753, -104.999)
        let losAngeles = station("LAX", "Los Angeles Union Station", 34.056, -118.237)
        let trip = trip(stations: [chicago, denver, losAngeles])
        let otherTrip = self.trip(id: "denver-connection", stations: [denver, losAngeles])
        return (
            trip,
            plan(trip, departureZone: "America/Chicago", arrivalZone: "America/Los_Angeles"),
            plan(otherTrip, departureZone: "America/Denver", arrivalZone: "America/Los_Angeles")
        )
    }

    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    static func plan(
        _ trip: TrainTrip,
        departureZone: String,
        arrivalZone: String,
        childTripIDs: [RailIdentifier]? = nil,
        returnTripIDs: [RailIdentifier]? = nil
    ) -> TrackedJourneyPlan {
        TrackedJourneyPlan(
            id: UUID(), createdAt: date("2026-09-05T12:00:00Z"),
            origin: place(trip.origin!, zone: departureZone), destination: place(trip.destination!, zone: arrivalZone),
            outbound: JourneyPlanDirection(
                fingerprint: "outbound", departure: date("2026-09-15T20:20:00Z"), arrival: date("2026-09-16T03:37:00Z"),
                childTripIDs: childTripIDs ?? [trip.id]
            ),
            returnDirection: returnTripIDs.map {
                JourneyPlanDirection(
                    fingerprint: "return", departure: date("2026-09-17T20:20:00Z"), arrival: date("2026-09-18T03:37:00Z"),
                    childTripIDs: $0
                )
            },
            preExistingChildTripIDs: []
        )
    }

    static func trip(id: String = "2162", stations: [Station]) -> TrainTrip {
        let times = [date("2026-09-15T20:20:00Z"), date("2026-09-15T22:40:00Z"), date("2026-09-16T03:37:00Z")]
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:amtrak:\(id)"), source: "amtrak", serviceDate: times[0],
            operatorName: "Amtrak", product: "Acela \(id)", headsign: stations.last!.displayName,
            stopTimes: stations.enumerated().map { index, station in
                StopTime(
                    station: station, sequence: index,
                    scheduledArrival: index == 0 ? nil : times[index == stations.count - 1 ? 2 : 1],
                    scheduledDeparture: index == stations.count - 1 ? nil : times[index]
                )
            },
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop
            )
        )
    }

    private static func station(_ code: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
        Station(
            id: RailIdentifier(rawValue: "us:station:\(code)"), names: [LocalizedStationName(name)],
            codes: [.sourceNative: code], location: GeoCoordinate(latitude: lat, longitude: lon), countryCode: "US"
        )
    }

    private static func place(_ station: Station, zone: String) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName, context: "US", countryCode: "US",
            timeZoneIdentifier: zone, location: station.location, eligibleModes: ["longDistanceRail"], attributions: []
        )
    }
}
