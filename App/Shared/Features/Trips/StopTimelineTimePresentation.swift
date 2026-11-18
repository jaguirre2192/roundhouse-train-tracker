import Foundation
import TrainTrackerCore

struct StopTimelineTimePresentation {
    enum Event {
        case departure
        case arrival
    }

    let date: Date?
    let timeText: String?
    let timingBasis: RailJourneyProgress.TimingBasis?
    let delayMinutes: Int?
    /// The event whose time was shown. A stop without a departure time falls back to its
    /// arrival (and the reverse), so the label names what the time actually is.
    let resolvedEvent: Event?

    /// "departure" or "arrival", for labels such as "Expected arrival".
    var eventNoun: String? {
        resolvedEvent.map { $0 == .departure ? "departure" : "arrival" }
    }

    var timingLabel: String? {
        switch timingBasis {
        case .estimated: "Estimated"
        case .scheduled: "Scheduled"
        case nil: nil
        }
    }

    typealias Reading = (date: Date, basis: RailJourneyProgress.TimingBasis, scheduled: Date?, event: Event)

    static func reading(for stop: StopTime, event: Event) -> Reading? {
        let candidates: [(date: Date?, basis: RailJourneyProgress.TimingBasis, scheduled: Date?, event: Event)]
        let departures: [(date: Date?, basis: RailJourneyProgress.TimingBasis, scheduled: Date?, event: Event)] = [
            (stop.expectedDeparture, .estimated, stop.scheduledDeparture, .departure),
            (stop.scheduledDeparture, .scheduled, nil, .departure)
        ]
        let arrivals: [(date: Date?, basis: RailJourneyProgress.TimingBasis, scheduled: Date?, event: Event)] = [
            (stop.expectedArrival, .estimated, stop.scheduledArrival, .arrival),
            (stop.scheduledArrival, .scheduled, nil, .arrival)
        ]
        switch event {
        case .departure: candidates = departures + arrivals
        case .arrival: candidates = arrivals + departures
        }
        guard let selected = candidates.first(where: { $0.date != nil }),
              let date = selected.date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return (date, selected.basis, selected.scheduled, selected.event)
    }

    init(
        stop: StopTime,
        event: Event = .departure,
        timeZoneIdentifier: String? = nil,
        fallbackTimeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .trainTrackerTime
    ) {
        guard let selected = Self.reading(for: stop, event: event) else {
            self.date = nil
            timeText = nil
            timingBasis = nil
            delayMinutes = nil
            resolvedEvent = nil
            return
        }
        let date = selected.date
        self.date = date
        timingBasis = selected.basis
        resolvedEvent = selected.event
        if let scheduled = selected.scheduled {
            let delay = date.timeIntervalSince(scheduled) / 60
            delayMinutes = delay.isFinite && delay > Double(Int.min) && delay < Double(Int.max)
                ? Int(delay) : nil
        } else {
            delayMinutes = nil
        }
        if let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) != nil {
            timeText = JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: timeZoneIdentifier)
        } else {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = fallbackTimeZone
            formatter.timeStyle = .short
            timeText = formatter.string(from: date)
        }
    }
}
