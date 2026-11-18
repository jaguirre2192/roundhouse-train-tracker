import Foundation
import TrainTrackerCore

/// A timetable range describes both endpoint events, independently of the current journey phase.
struct JourneyItineraryTimePresentation {
    struct Endpoint {
        let date: Date
        let timingBasis: RailJourneyProgress.TimingBasis
        let timeZoneIdentifier: String

        var timeText: String { JourneyExperienceClock.labeledTime(date, zone: timeZoneIdentifier) }
        var label: String { timingBasis == .estimated ? JourneyTrust.estimated.title : JourneyTrust.timetable.title }

        fileprivate var localDay: DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
            return calendar.dateComponents([.year, .month, .day], from: date)
        }

        fileprivate func displayText(includesDate: Bool) -> String {
            includesDate
                ? "\(JourneyExperienceClock.date(date, zone: timeZoneIdentifier)), \(timeText)"
                : timeText
        }
    }

    let departure: Endpoint?
    let arrival: Endpoint?

    var showsDateChange: Bool {
        guard let departure, let arrival else { return false }
        return departure.localDay != arrival.localDay
    }

    var text: String? {
        guard let departure, let arrival else { return nil }
        let start = departure.displayText(includesDate: showsDateChange)
        let end = arrival.displayText(includesDate: showsDateChange)
        if departure.timingBasis == arrival.timingBasis {
            return "\(departure.label) \(start) – \(end)"
        }
        return "\(departure.label) \(start) – \(arrival.label) \(end)"
    }

    init(segment: JourneyPlanSegment, trip: TrainTrip?, referenceDate: Date) {
        let stops: [StopTime]
        if segment.kind == .rail, let trip, trip.id == segment.resolvedTripID {
            stops = RailJourneyProgress(
                trip: trip, referenceDate: referenceDate,
                boardingPlace: segment.from, alightingPlace: segment.to
            ).stops
        } else {
            stops = []
        }
        departure = Self.endpoint(
            stop: stops.first, event: .departure, savedDate: segment.departure,
            timeZone: segment.from.timeZoneIdentifier
        )
        arrival = Self.endpoint(
            stop: stops.last, event: .arrival, savedDate: segment.arrival,
            timeZone: segment.to.timeZoneIdentifier
        )
    }

    private static func endpoint(
        stop: StopTime?, event: StopTimelineTimePresentation.Event, savedDate: Date?, timeZone: String
    ) -> Endpoint? {
        if let stop {
            let time = StopTimelineTimePresentation(stop: stop, event: event)
            if let date = time.date, let basis = time.timingBasis {
                return Endpoint(date: date, timingBasis: basis, timeZoneIdentifier: timeZone)
            }
        }
        return savedDate.map { Endpoint(date: $0, timingBasis: .scheduled, timeZoneIdentifier: timeZone) }
    }
}
