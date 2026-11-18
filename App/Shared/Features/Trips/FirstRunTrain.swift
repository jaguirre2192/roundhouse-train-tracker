import CoreLocation
import Foundation
import TrainTrackerCore

/// A big station to look for a running train at, for someone who has no journeys yet.
struct FirstRunHub: Equatable, Sendable {
    let query: String
    let source: RailSource
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    static let newYork = FirstRunHub(query: "New York Penn", source: .unitedStates, latitude: 40.7505, longitude: -73.9934)
    static let chicago = FirstRunHub(query: "Chicago Union", source: .unitedStates, latitude: 41.8787, longitude: -87.6394)
    static let berlin = FirstRunHub(query: "Berlin Hbf", source: .europe, latitude: 52.5251, longitude: 13.3694)

    private static let europe: [String: FirstRunHub] = [
        "DE": berlin,
        "FR": FirstRunHub(query: "Paris Gare de Lyon", source: .europe, latitude: 48.8443, longitude: 2.3744),
        "GB": FirstRunHub(query: "London Euston", source: .europe, latitude: 51.5282, longitude: -0.1337),
        "IT": FirstRunHub(query: "Roma Termini", source: .europe, latitude: 41.9009, longitude: 12.5020),
        "ES": FirstRunHub(query: "Madrid Chamartín", source: .europe, latitude: 40.4722, longitude: -3.6825),
        "PT": FirstRunHub(query: "Lisboa Oriente", source: .europe, latitude: 38.7678, longitude: -9.0991),
        "NL": FirstRunHub(query: "Amsterdam Centraal", source: .europe, latitude: 52.3791, longitude: 4.9003),
        "BE": FirstRunHub(query: "Bruxelles-Midi", source: .europe, latitude: 50.8357, longitude: 4.3366),
        "CH": FirstRunHub(query: "Zürich HB", source: .europe, latitude: 47.3782, longitude: 8.5402),
        "AT": FirstRunHub(query: "Wien Hbf", source: .europe, latitude: 48.1853, longitude: 16.3761),
    ]

    private static let americas: Set<String> = ["US", "CA", "MX"]

    /// Hubs to try, nearest to the rider's region first. The region comes from the device's
    /// settings and never leaves it; only a station name is sent to look up departures.
    static func hubs(regionCode: String?) -> [FirstRunHub] {
        guard let regionCode else { return [newYork, berlin] }
        if americas.contains(regionCode) { return [newYork, chicago] }
        if let home = europe[regionCode] { return home == berlin ? [berlin, newYork] : [home, berlin] }
        return [berlin, newYork]
    }
}

/// Chooses which running train to show. Kept apart from the network so it can be tested.
enum FirstRunTrainPicker {
    /// Departures worth asking about: left between 8 minutes and 2½ hours ago, so the train is
    /// clear of the station and likely still on its way. Closest to half an hour out first.
    static func departed(_ board: [StopTimeSummary], at now: Date, limit: Int = 4) -> [StopTimeSummary] {
        let candidates = board.compactMap { entry -> (StopTimeSummary, TimeInterval)? in
            guard !entry.stopTime.isCancelled,
                  let departure = entry.stopTime.expectedDeparture ?? entry.stopTime.scheduledDeparture else { return nil }
            let age = now.timeIntervalSince(departure)
            guard age >= 8 * 60, age <= 150 * 60 else { return nil }
            return (entry, abs(age - 35 * 60))
        }
        return candidates.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// The station among search results that is the hub itself, not a namesake elsewhere.
    static func station(in results: [Station], near hub: FirstRunHub) -> Station? {
        let center = CLLocation(latitude: hub.latitude, longitude: hub.longitude)
        return results
            .map { ($0, CLLocation(latitude: $0.location.latitude, longitude: $0.location.longitude).distance(from: center)) }
            .filter { $0.1 <= 3_000 }
            .min { $0.1 < $1.1 }?.0
    }

    /// A train is worth showing while it is underway with at least a quarter of an hour to run.
    static func isShowable(_ trip: TrainTrip, at now: Date) -> Bool {
        guard !trip.isCancelled, trip.stopTimes.count >= 3 else { return false }
        let progress = RailJourneyProgress(trip: trip, referenceDate: now)
        guard progress.phase == .underway, !progress.isCancelled, let arrival = progress.arrivalDate else { return false }
        return arrival.timeIntervalSince(now) >= 15 * 60
    }

    /// The best of the candidates: a reported position first, then a drawn track, then the
    /// train with the longest still to run.
    static func best(_ trips: [TrainTrip], at now: Date) -> TrainTrip? {
        trips.filter { isShowable($0, at: now) }.max { score($0, at: now) < score($1, at: now) }
    }

    private static func score(_ trip: TrainTrip, at now: Date) -> Double {
        let reported = RailJourneyEvidence.latestRealPosition(in: trip, at: now, maximumAge: 10 * 60) != nil
        let remaining = RailJourneyProgress(trip: trip, referenceDate: now).arrivalDate?.timeIntervalSince(now) ?? 0
        return (reported ? 2_000_000 : 0) + (trip.routeGeometry != nil ? 1_000_000 : 0) + min(remaining, 900_000)
    }
}
