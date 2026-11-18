import Foundation
import TrainTrackerCore

struct ConnectionTimetable: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        let planned: Date?
        let estimate: Date?
        let place: RailPlace
        let reportedZone: String?
        var date: Date? { estimate ?? planned }
        var usesEstimate: Bool { estimate != nil && estimate != planned }
        var timingLabel: String {
            guard let estimate else { return planned == nil ? "Time unavailable" : "Timetable" }
            return estimate == planned ? "Matches timetable" : "Last estimate"
        }
        var stationZone: TimeZone? {
            (reportedZone.flatMap(TimeZone.init(identifier:)))
                ?? TripDetailTimeZoneContext.savedPlaceZone(place.timeZoneIdentifier).flatMap(TimeZone.init(identifier:))
        }
    }

    let incoming: Event
    let onward: Event
    let published: PublishedStationTransfer?
    let planningMinutes: Int?

    var availableMinutes: Int? {
        guard let arrival = incoming.date, let departure = onward.date else { return nil }
        return Self.wholeMinutes(departure.timeIntervalSince(arrival))
    }

    var allowanceMinutes: Int? { published?.minutes ?? planningMinutes }
    /// Print one zone only when all the figures, including struck-through times, share it.
    var sharedClockLabel: String? {
        guard let zone = incoming.stationZone, zone == onward.stationZone,
              let first = incoming.date, onward.date != nil else { return nil }
        let offset = zone.secondsFromGMT(for: first)
        let readings = [incoming.planned, incoming.estimate, onward.planned, onward.estimate].compactMap { $0 }
        guard readings.allSatisfy({ zone.secondsFromGMT(for: $0) == offset }) else { return nil }
        return zone.abbreviation(for: first) ?? zone.identifier
    }
    var marginMinutes: Int? {
        guard let availableMinutes, let allowanceMinutes else { return nil }
        return availableMinutes - allowanceMinutes
    }

    init?(previous: JourneyPlanSegment, next: JourneyPlanSegment, walks: [JourneyPlanSegment],
          arrival: StopTime?, departure: StopTime?) {
        guard previous.kind == .rail, next.kind == .rail,
              arrival?.isCancelled != true, departure?.isCancelled != true else { return nil }
        incoming = Event(planned: arrival?.scheduledArrival ?? previous.arrival,
                         estimate: arrival?.expectedArrival, place: previous.to, reportedZone: arrival?.station.timeZoneIdentifier)
        onward = Event(planned: departure?.scheduledDeparture ?? next.departure,
                       estimate: departure?.expectedDeparture, place: next.from, reportedZone: departure?.station.timeZoneIdentifier)
        guard incoming.date != nil || onward.date != nil else { return nil }
        // A same-station rule cannot establish how to cross town.
        if let arrival, let departure, let at = incoming.date, let leaving = onward.date,
           !walks.contains(where: \.isStationChange),
           JourneyTransferStation.matches(previous.to, next.from) {
            published = PublishedStationTransfer.find(arrival: arrival, departure: departure, at: at, onward: leaving)
        } else { published = nil }
        if let seconds = Self.walkingSeconds(walks) {
            planningMinutes = Self.wholeMinutes(JourneyPlanStage.Connection.planningAllowance(walkingSeconds: seconds))
        } else { planningMinutes = nil }
    }

    static func walkingSeconds(_ walks: [JourneyPlanSegment]) -> TimeInterval? {
        var total: TimeInterval = 0
        for walk in walks {
            guard walk.kind == .walk, let duration = walk.duration, duration.isFinite, duration >= 0 else { return nil }
            total += duration
        }
        return total.isFinite ? total : nil
    }

    private static func wholeMinutes(_ seconds: TimeInterval) -> Int? {
        let minutes = floor(seconds / 60)
        guard minutes.isFinite, abs(minutes) < Double(Int.max / 2) else { return nil }
        return Int(minutes)
    }
}
