import Foundation
import TrainTrackerCore

struct JourneyNavigationRequest: Hashable, Identifiable {
    let id = UUID()
    let tripID: RailIdentifier
    let boardingStationID: String?
    let alightingStationID: String?

    init(tripID: RailIdentifier, boardingStationID: String? = nil, alightingStationID: String? = nil) {
        self.tripID = tripID
        self.boardingStationID = boardingStationID
        self.alightingStationID = alightingStationID
    }

    init?(url: URL) {
        guard url.scheme == "traintracker", url.host == "journey", url.path.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              let trip = items.first(where: { $0.name == "trip" })?.value,
              !trip.isEmpty, trip.utf8.count <= 512 else { return nil }
        let boarding = items.first(where: { $0.name == "boarding" })?.value
        let alighting = items.first(where: { $0.name == "alighting" })?.value
        let includesEndpoints = items.contains { $0.name == "boarding" || $0.name == "alighting" }
        guard (boarding == nil) == (alighting == nil),
              (!includesEndpoints || (boarding != nil && alighting != nil)),
              [boarding, alighting].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { return nil }
        self.init(tripID: RailIdentifier(rawValue: trip), boardingStationID: boarding, alightingStationID: alighting)
    }

    func selectedSegment(trip: TrainTrip, plans: [TrackedJourneyPlan]) -> JourneyPlanSegment? {
        guard trip.id == tripID else { return nil }
        guard let boardingStationID, let alightingStationID else {
            return JourneyTripContext.selectedSegment(for: tripID, plans: plans)
        }
        let boarding = trip.stopTimes.filter { $0.station.id.rawValue == boardingStationID }
        let alighting = trip.stopTimes.filter { $0.station.id.rawValue == alightingStationID }
        guard boarding.count == 1, alighting.count == 1,
              let from = boarding.first, let to = alighting.first, from.sequence < to.sequence else { return nil }
        let context = TripDetailTimeZoneContext(trip: trip, plans: plans)
        func place(_ stop: StopTime) -> RailPlace {
            RailPlace(
                id: stop.station.id, kind: .station, displayName: stop.station.displayName,
                context: "", countryCode: stop.station.countryCode,
                timeZoneIdentifier: context.timeZoneIdentifier(for: stop) ?? "",
                location: stop.station.location, eligibleModes: ["rail"], attributions: []
            )
        }
        return JourneyPlanSegment(
            id: "activity-\(from.id)-\(to.id)", kind: .rail, from: place(from), to: place(to),
            departure: from.scheduledDeparture ?? from.scheduledArrival,
            arrival: to.scheduledArrival ?? to.scheduledDeparture,
            serviceName: trip.product, resolvedTripID: tripID
        )
    }
}
