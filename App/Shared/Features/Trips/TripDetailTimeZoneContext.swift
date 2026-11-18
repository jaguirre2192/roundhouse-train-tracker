import Foundation
import TrainTrackerCore

struct TripDetailTimeZoneContext {
    let routeTimeZones: JourneyPlanRouteTimeZones?
    private let stopTimeZones: [String: String]
    /// Only station-specific evidence can support a clock change. Route and device fallbacks
    /// still format the regular timetable, but cannot establish where the clocks change.
    private let stationClockZones: [String: String]

    init(
        trip: TrainTrip,
        routeTimeZones suppliedZones: JourneyPlanRouteTimeZones? = nil,
        plans: [TrackedJourneyPlan] = [],
        additionalPlaces: [RailPlace] = [],
        fallbackTimeZone: TimeZone = .autoupdatingCurrent
    ) {
        let directions = plans.sorted { $0.outbound.departure < $1.outbound.departure }.flatMap { plan in
            var values = [Direction(plan.outbound, origin: plan.origin, destination: plan.destination)]
            if let direction = plan.returnDirection {
                values.append(Direction(direction, origin: plan.destination, destination: plan.origin))
            }
            return values.filter { $0.childTripIDs.contains(trip.id) }
        }
        let owner = directions.first { $0.zones == suppliedZones } ?? directions.first
        let suggested = suppliedZones ?? owner?.zones
        let sharedZone = suggested.flatMap {
            $0.departureTimeZoneIdentifier == $0.arrivalTimeZoneIdentifier
                ? Self.savedPlaceZone($0.departureTimeZoneIdentifier) : nil
        }
        let knownPlaces = additionalPlaces + plans.flatMap { plan in
            let segments = (plan.outbound.selectedSegments ?? []) + (plan.returnDirection?.selectedSegments ?? [])
            return [plan.origin, plan.destination] + segments.flatMap { [$0.from, $0.to] }
        }
        var resolved: [String: String] = [:]
        var stationClocks: [String: String] = [:]
        for (index, stop) in trip.stopTimes.enumerated() {
            let known = Self.validZone(stop.station.timeZoneIdentifier)
                ?? Self.stationTimeZone(stop.station, places: knownPlaces)
            if let known { stationClocks[stop.id] = known }
            let endpointFallback: String?
            if index == 0, owner == nil || owner?.childTripIDs.first == trip.id {
                endpointFallback = Self.savedPlaceZone(suggested?.departureTimeZoneIdentifier)
            } else if index == trip.stopTimes.count - 1, owner == nil || owner?.childTripIDs.last == trip.id {
                endpointFallback = Self.savedPlaceZone(suggested?.arrivalTimeZoneIdentifier)
            } else {
                endpointFallback = nil
            }
            resolved[stop.id] = known ?? endpointFallback ?? sharedZone
        }
        stopTimeZones = resolved
        stationClockZones = stationClocks
        let departure = trip.stopTimes.first.flatMap { resolved[$0.id] }
        let arrival = trip.stopTimes.last.flatMap { resolved[$0.id] }
        routeTimeZones = departure == nil && arrival == nil ? nil : JourneyPlanRouteTimeZones(
            departureTimeZoneIdentifier: departure ?? fallbackTimeZone.identifier,
            arrivalTimeZoneIdentifier: arrival ?? fallbackTimeZone.identifier
        )
    }

    func timeZoneIdentifier(for stop: StopTime) -> String? {
        stopTimeZones[stop.id]
    }

    func stationClockZone(for stop: StopTime) -> TimeZone? {
        stationClockZones[stop.id].flatMap(TimeZone.init(identifier:))
    }

    private static func stationTimeZone(_ station: Station, places: [RailPlace]) -> String? {
        let zones = Set(places.compactMap { place -> String? in
            guard station.id == place.id || sameLocation(station, place) else { return nil }
            return savedPlaceZone(place.timeZoneIdentifier)
        })
        return zones.count == 1 ? zones.first : nil
    }

    private static func sameLocation(_ station: Station, _ place: RailPlace) -> Bool {
        guard !station.countryCode.isEmpty, station.countryCode == place.countryCode,
              station.location.latitude != 0 || station.location.longitude != 0,
              place.location.latitude != 0 || place.location.longitude != 0 else { return false }
        // Provider station IDs can differ. A close persisted endpoint is useful
        // timezone evidence; a city name or a country's longitude is not.
        return abs(station.location.latitude - place.location.latitude) < 0.002
            && abs(station.location.longitude - place.location.longitude) < 0.002
    }

    private static func validZone(_ identifier: String?) -> String? {
        guard let identifier, TimeZone(identifier: identifier) != nil else { return nil }
        return identifier
    }

    /// Older search results use UTC when the supplier omitted a station's zone.
    /// A timezone explicitly reported on a snapshot stop has independent provenance.
    static func savedPlaceZone(_ identifier: String?) -> String? {
        guard let id = validZone(identifier), id.contains("/"), !id.hasPrefix("Etc/") else { return nil }
        return id
    }

    private struct Direction {
        let childTripIDs: [RailIdentifier]
        let zones: JourneyPlanRouteTimeZones

        init(_ direction: JourneyPlanDirection, origin: RailPlace, destination: RailPlace) {
            childTripIDs = direction.childTripIDs
            zones = JourneyPlanRouteTimeZones(
                departureTimeZoneIdentifier: origin.timeZoneIdentifier,
                arrivalTimeZoneIdentifier: destination.timeZoneIdentifier
            )
        }
    }
}
