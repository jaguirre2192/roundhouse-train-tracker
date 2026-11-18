import Foundation
import TrainTrackerCore

extension TravelLog {
    /// Older releases kept every finished train. Only the rider can correct one of those stubs.
    func correctWatchedTrain(_ entry: TravelLogEntry, in library: TripLibrary) throws {
        try library.markAsWatching(RailIdentifier(rawValue: entry.id))
        try removePersisting(id: entry.id)
    }

    /// Following a service keeps its updates coming. Only a passenger journey earns a stub.
    func recordFinishedRides(in library: TripLibrary, plans: [TrackedJourneyPlan], at date: Date) {
        for trip in library.trips {
            guard entry(id: trip.id.rawValue)?.isArrivalConfirmed != true else { continue }
            if let stub = Self.finishedRide(trip, in: library, plans: plans, at: date) { record(stub) }
        }
    }

    static func finishedRide(_ trip: TrainTrip, in library: TripLibrary, plans: [TrackedJourneyPlan], at date: Date) -> TravelLogEntry? {
        guard !library.isWatchingOnly(trip.id), !trip.isCancelled else { return nil }
        let sections = plans.flatMap { [$0.outbound, $0.returnDirection].compactMap { $0 } }
            .filter { $0.childTripIDs.contains(trip.id) }
            .flatMap { $0.selectedSegments ?? [] }
            .filter { $0.resolvedTripID == trip.id && $0.kind == .rail }
        // One train can belong to a booking and a later replan. Only identical passenger
        // sections establish the same ride. A conflict must never award the whole train.
        let segment = sections.first
        guard sections.dropFirst().allSatisfy({
            $0.from.id == segment?.from.id && $0.to.id == segment?.to.id &&
                $0.departure == segment?.departure && $0.arrival == segment?.arrival
        }) else { return nil }
        let progress = ActiveTripCardPresentation(
            trip: trip, routeTimeZones: nil, referenceDate: date,
            lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
            lastRefreshFailed: library.lastRefreshFailed(for: trip.id), selectedSegment: segment
        ).effectiveProgress
        guard progress.phase == .ended, !progress.isCancelled, let boarding = progress.stops.first else { return nil }
        let confirmed = ArrivalEvidence.arrivalIsConfirmed(progress: progress)
        if !confirmed, let due = progress.arrivalDate, date < due.addingTimeInterval(ArrivalEvidence.unconfirmedGrace) { return nil }
        let zones = TripDetailTimeZoneContext(trip: trip, plans: plans)
        let zone = zones.timeZoneIdentifier(for: boarding).flatMap(TimeZone.init(identifier:))
            ?? StationTimeZoneResolver.cached(for: boarding.station.id)
        return TravelLogEntry(trip: trip, stops: progress.stops, arrivalConfirmed: confirmed, departureTimeZone: zone)
    }
}
