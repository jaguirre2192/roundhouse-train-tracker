import Foundation
import TrainTrackerCore

enum TicketJourneySearchPrefill {
    static func bestPlace(named name: String, from candidates: [RailPlace]) -> RailPlace? {
        ImportedStationMatcher.bestPlace(named: name, from: candidates)
    }

    static func departureDate(
        _ value: String?,
        timeZoneIdentifier: String?
    ) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let values = value.split(separator: "-").compactMap { Int($0) }
            guard values.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            return calendar.date(from: DateComponents(
                year: values[0],
                month: values[1],
                day: values[2],
                hour: 12
            ))
        }
        // A ticket's printed local time belongs to the matched boarding station, not the device.
        if let clock = TicketWallClock(requestValue: value), clock.hasTime {
            return clock.date(in: timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent)
        }
        return ISO8601DateFormatter().date(from: value)
    }

}
