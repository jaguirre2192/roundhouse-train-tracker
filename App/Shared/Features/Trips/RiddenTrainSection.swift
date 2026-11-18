import Foundation
import TrainTrackerCore

/// A passenger chooses calls from the train already on screen. This works on a saved snapshot.
struct RiddenTrainSection {
    let calls: [StopTime]

    init(trip: TrainTrip) {
        calls = trip.stopTimes.filter { !$0.isCancelled }.sorted { $0.sequence < $1.sequence }
    }

    func plan(on trip: TrainTrip, from boardingID: String, to alightingID: String,
              at date: Date, knownPlans: [TrackedJourneyPlan]) -> TrackedJourneyPlan? {
        guard let start = calls.firstIndex(where: { $0.id == boardingID }),
              let end = calls.firstIndex(where: { $0.id == alightingID }), start < end else { return nil }
        let from = calls[start], to = calls[end]
        guard let departure = from.scheduledDeparture ?? from.scheduledArrival ?? from.expectedDeparture ?? from.expectedArrival,
              let arrival = to.scheduledArrival ?? to.scheduledDeparture ?? to.expectedArrival ?? to.expectedDeparture,
              arrival > departure else { return nil }
        let zones = TripDetailTimeZoneContext(trip: trip, plans: knownPlans)
        func place(_ stop: StopTime) -> RailPlace {
            let station = stop.station
            return RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "",
                             countryCode: station.countryCode, timeZoneIdentifier: zones.timeZoneIdentifier(for: stop)
                               ?? StationTimeZoneResolver.cached(for: station.id)?.identifier ?? "",
                             location: station.location, eligibleModes: ["rail"], attributions: [])
        }
        let origin = place(from), destination = place(to)
        let key = "ride-\(trip.id.rawValue)-\(boardingID)-\(alightingID)"
        let segment = JourneyPlanSegment(id: key, kind: .rail, from: origin, to: destination,
                                         departure: from.scheduledDeparture ?? from.scheduledArrival,
                                         arrival: to.scheduledArrival ?? to.scheduledDeparture,
                                         serviceName: LiveLineTicketPresentation.serviceName(for: trip), resolvedTripID: trip.id)
        let direction = JourneyPlanDirection(fingerprint: key, departure: departure, arrival: arrival,
                                             childTripIDs: [trip.id], selectedSegments: [segment])
        return TrackedJourneyPlan(id: UUID(), createdAt: date, origin: origin, destination: destination,
                                  outbound: direction, returnDirection: nil, preExistingChildTripIDs: [trip.id])
    }
}
