import CoreLocation
import Foundation
import TrainTrackerCore

/// A search starting where the passenger can change, bounded by their selected itinerary.
struct JourneyRecoveryRequest: Hashable {
    let origin: RailPlace
    let destination: RailPlace
    let readyAt: Date
    let original: JourneyPlanSegment

    func criteria(at date: Date) -> JourneySearchCriteria {
        JourneySearchCriteria(originID: origin.id, destinationID: destination.id,
                              requestedTime: max(date, readyAt), timeZoneIdentifier: origin.timeZoneIdentifier,
                              arriveBy: false, maximumTransfers: 3, cursor: nil)
    }

    func searchRequest(at date: Date) -> TicketJourneySearchRequest {
        TicketJourneySearchRequest(originName: origin.displayName, destinationName: destination.displayName,
            departureTime: ISO8601DateFormatter().string(from: max(date, readyAt)), trainNumber: nil,
            originPlace: origin, destinationPlace: destination)
    }

    static func make(stage: JourneyPlanStage, trips: [TrainTrip], at date: Date) -> Self? {
        guard let segments = stage.direction.selectedSegments, let destination = segments.last?.to,
              let focus = stage.focusSegment, let index = segments.firstIndex(of: focus),
              Set(segments.map(\.id)).count == segments.count,
              stage.direction.arrival > date || stage.hasObservedUnfinishedJourney else { return nil }
        if let connection = stage.connection, connection.isMissed || connection.isTight {
            return make(for: connection.next, after: connection.previous, walks: connection.walks,
                        destination: destination, trips: trips, date: date)
        }

        // An onward cancellation can be known while the passenger is still on the incoming train.
        guard let firstRail = segments[index...].firstIndex(where: { $0.kind == .rail }) else { return nil }
        let candidates = segments.indices.dropFirst(firstRail).filter { segments[$0].kind == .rail }.prefix(2)
        guard let cancelledIndex = candidates.first(where: { i in
            guard let bounded = progress(segments[i], trips: trips, at: date) else { return false }
            return bounded.isCancelled || bounded.stops.first?.isCancelled == true
                || (bounded.stops.last?.isCancelled == true && bounded.departureDate.map { $0 > date } == true)
        }) else { return nil }
        let cancelled = segments[cancelledIndex]
        if let previousIndex = segments.indices.prefix(cancelledIndex).last(where: { segments[$0].kind == .rail }) {
            return make(for: cancelled, after: segments[previousIndex],
                        walks: Array(segments[(previousIndex + 1)..<cancelledIndex]),
                        destination: destination, trips: trips, date: date)
        }
        guard let planned = cancelled.departure, cancelled.from.kind == .station,
              !JourneyTransferStation.matches(cancelled.from, destination) else { return nil }
        return Self(origin: cancelled.from, destination: destination, readyAt: planned, original: cancelled)
    }

    private static func make(for next: JourneyPlanSegment, after previous: JourneyPlanSegment,
                             walks: [JourneyPlanSegment], destination: RailPlace, trips: [TrainTrip],
                             date: Date) -> Self? {
        guard next.from.kind == .station, !JourneyTransferStation.matches(next.from, destination),
              let incoming = progress(previous, trips: trips, at: date), !incoming.isCancelled,
              let last = incoming.stops.last, !last.isCancelled, let expected = incoming.arrivalDate else { return nil }
        let report = [last.arrivalObservedAt, last.passageObservedAt].compactMap { $0 }
            .filter { $0 <= date.addingTimeInterval(120) }.max()
        let arrival = incoming.evidence.isArrivalConfirmed ? max(report ?? expected, expected) : expected
        if arrival <= date && incoming.evidence.observedFocusStopID != nil && incoming.phase == .underway
            && !incoming.evidence.isArrivalConfirmed { return nil }
        var station = previous.to
        var walkingTime: TimeInterval = 0
        for walk in walks {
            guard walk.kind == .walk, JourneyTransferStation.matches(walk.from, station), let duration = walk.duration,
                  duration.isFinite, duration >= 0 else { return nil }
            station = walk.to
            walkingTime += duration
        }
        guard JourneyTransferStation.matches(station, next.from), walkingTime.isFinite else { return nil }
        let allowance = JourneyPlanStage.Connection.planningAllowance(walkingSeconds: walkingTime)
        return Self(origin: next.from, destination: destination,
                    readyAt: arrival.addingTimeInterval(allowance), original: next)
    }

    static func progress(_ segment: JourneyPlanSegment, trips: [TrainTrip], at date: Date) -> RailJourneyProgress? {
        guard let id = segment.resolvedTripID, segment.unavailableReason == nil,
              let trip = trips.first(where: { $0.id == id }) else { return nil }
        let result = RailJourneyProgress(trip: trip, referenceDate: date,
                                         boardingPlace: segment.from, alightingPlace: segment.to)
        return result.stops.isEmpty ? nil : result
    }
}

/// Place search may return a station building while route results identify a platform in a
/// different feed. Require both a station-specific name and a small geographic separation.
enum JourneyTransferStation {
    static func matches(_ lhs: RailPlace, _ rhs: RailPlace) -> Bool {
        if lhs.id == rhs.id { return true }
        let country = lhs.countryCode.uppercased()
        guard lhs.kind == .station, rhs.kind == .station, !country.isEmpty, country == rhs.countryCode.uppercased(),
              let first = location(lhs.location), let second = location(rhs.location),
              first.distance(from: second) <= 250 else { return false }
        let a = ImportedStationMatcher.key(lhs.displayName)
        let b = ImportedStationMatcher.key(rhs.displayName)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard let alias = ImportedStationAlias.matching([a, b]), alias.countryCode == country else { return false }
        return alias.stationNames.contains(a) && alias.stationNames.contains(b)
    }

    private static func location(_ coordinate: GeoCoordinate) -> CLLocation? {
        let point = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard CLLocationCoordinate2DIsValid(point), point.latitude != 0 || point.longitude != 0 else { return nil }
        return CLLocation(latitude: point.latitude, longitude: point.longitude)
    }
}

extension JourneyHomeGuidance {
    static func alternatives(for trip: TrainTrip, segment: JourneyPlanSegment?, at date: Date) -> TicketJourneySearchRequest? {
        let progress = segment.map {
            RailJourneyProgress(trip: trip, referenceDate: date, boardingPlace: $0.from, alightingPlace: $0.to)
        } ?? RailJourneyProgress(trip: trip, referenceDate: date)
        guard let first = progress.stops.first, let last = progress.stops.last,
              first.station.id != last.station.id else { return nil }
        return TicketJourneySearchRequest(originName: first.station.displayName, destinationName: last.station.displayName,
            departureTime: ISO8601DateFormatter().string(from: max(date, progress.departureDate ?? date)), trainNumber: nil,
            originPlace: segment?.from, destinationPlace: segment?.to)
    }
}
