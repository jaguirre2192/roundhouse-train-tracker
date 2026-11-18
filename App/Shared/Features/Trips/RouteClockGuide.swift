import Foundation
import TrainTrackerCore

/// Each reading describes one absolute instant. Comparing both offsets at that instant
/// avoids inventing a border crossing when a train simply travels past a DST transition.
struct RouteClockComparison: Equatable {
    struct StationClock: Equatable {
        let name: String
        let zone: TimeZone
    }

    let previous: StationClock
    let current: StationClock
    let instant: Date
    let event: String

    var offsetMinutes: Int {
        (current.zone.secondsFromGMT(for: instant) - previous.zone.secondsFromGMT(for: instant)) / 60
    }

    var shift: String {
        let minutes = abs(offsetMinutes)
        let amount: String
        switch (minutes / 60, minutes % 60) {
        case (0, let m): amount = "\(m) min"
        case (let h, 0): amount = h == 1 ? "1 hour" : "\(h) hours"
        case (let h, let m): amount = "\(h) hr \(m) min"
        }
        return "\(amount) \(offsetMinutes > 0 ? "ahead" : "behind")"
    }
}

struct RouteClockGuide {
    private(set) var changes: Set<StopTime.ID> = []
    private(set) var comparisons: [StopTime.ID: RouteClockComparison] = [:]

    init(stops: [StopTime], zones: TripDetailTimeZoneContext) {
        var last: RouteClockComparison.StationClock?
        var across: RouteClockComparison.StationClock?
        for stop in stops where !stop.isCancelled {
            guard let zone = zones.stationClockZone(for: stop) else { continue }
            let current = RouteClockComparison.StationClock(name: stop.station.displayName, zone: zone)
            let event: StopTimelineTimePresentation.Event = stop.id == stops.last?.id ? .arrival : .departure
            let reading = StopTimelineTimePresentation.reading(for: stop, event: event)
            guard let reading else { continue }
            let instant = reading.date
            if let last, last.zone.secondsFromGMT(for: instant) != zone.secondsFromGMT(for: instant) {
                changes.insert(stop.id)
                across = last
            }
            if let across, across.zone.secondsFromGMT(for: instant) != zone.secondsFromGMT(for: instant) {
                let basis = reading.basis == .estimated ? "Estimated" : "Timetable"
                let label = reading.event == .arrival ? "arrival" : "departure"
                comparisons[stop.id] = .init(previous: across, current: current, instant: instant, event: "\(basis) \(label)")
            }
            last = current
        }
    }
}
