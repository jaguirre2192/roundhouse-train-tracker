import Foundation
import TrainTrackerCore

struct TrainLiveActivitySelection: Equatable, Sendable {
    let trip: TrainTrip
    let boarding: StopTime
    let alighting: StopTime
    let stationTimeZones: [RailIdentifier: String]

    init?(trip: TrainTrip, segment: JourneyPlanSegment?, plans: [TrackedJourneyPlan]) {
        let selected = segment ?? JourneyTripContext.selectedSegment(for: trip.id, plans: plans)
        if let selected {
            guard selected.kind == .rail, selected.resolvedTripID == trip.id,
                  selected.unavailableReason == nil else { return nil }
        } else {
            let directions = plans.flatMap { [$0.outbound] + ($0.returnDirection.map { [$0] } ?? []) }
            guard !directions.contains(where: { $0.childTripIDs.contains(trip.id) && $0.selectedSegments != nil }) else {
                return nil
            }
        }
        let progress: RailJourneyProgress
        if let selected {
            progress = RailJourneyProgress(
                trip: trip,
                referenceDate: .now,
                boardingPlace: selected.from,
                alightingPlace: selected.to
            )
        } else {
            progress = RailJourneyProgress(trip: trip, referenceDate: .now)
        }
        guard progress.stops.count >= 2,
              let boarding = progress.stops.first, let alighting = progress.stops.last,
              boarding.sequence < alighting.sequence,
              trip.stopTimes.filter({ $0.station.id == boarding.station.id }).count == 1,
              trip.stopTimes.filter({ $0.station.id == alighting.station.id }).count == 1
        else { return nil }
        self.trip = trip
        self.boarding = boarding
        self.alighting = alighting
        let context = TripDetailTimeZoneContext(
            trip: trip, plans: plans,
            additionalPlaces: selected.map { [$0.from, $0.to] } ?? []
        )
        var zones: [RailIdentifier: String] = [:]
        for stop in trip.stopTimes {
            if let zone = context.timeZoneIdentifier(for: stop) { zones[stop.station.id] = zone }
        }
        stationTimeZones = zones
    }

    func projection(at date: Date, checkedAt: Date?, refreshFailed: Bool) -> TrainLiveActivityProjection {
        TrainLiveActivityProjection(
            trip: trip, referenceDate: date,
            boardingStationID: boarding.station.id, alightingStationID: alighting.station.id,
            stationTimeZones: stationTimeZones,
            lastSuccessfulCheck: checkedAt, refreshFailed: refreshFailed
        )
    }

    func attributes(at date: Date, isRiding: Bool? = nil) -> TrainJourneyAttributes {
        TrainJourneyAttributes(
            activityKey: UUID().uuidString.lowercased(), tripID: trip.id.rawValue,
            boardingStationID: boarding.station.id.rawValue,
            alightingStationID: alighting.station.id.rawValue,
            serviceName: trip.product, originName: boarding.station.displayName,
            destinationName: alighting.station.displayName, startedAt: date.timeIntervalSince1970,
            boardingStopSequence: boarding.sequence, alightingStopSequence: alighting.sequence,
            originCode: StationShortCode.code(for: boarding.station),
            destinationCode: StationShortCode.code(for: alighting.station), isRiding: isRiding
        )
    }
}
