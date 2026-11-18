import Foundation
import TrainTrackerCore

enum JourneyPlanDateTimePresentation {
    static func date(_ date: Date, timeZoneIdentifier: String) -> String {
        formatter(
            dateFormat: "EEE, MMM d",
            timeZoneIdentifier: timeZoneIdentifier
        ).string(from: date)
    }

    static func time(_ date: Date, timeZoneIdentifier: String) -> String {
        formatter(
            dateFormat: TimeFormatPreference.stored().clockPattern(),
            timeZoneIdentifier: timeZoneIdentifier
        ).string(from: date)
    }

    /// The station zone's abbreviation (for example "GMT+2") when its clock differs from the
    /// device's, so a station-local time is never mistaken for the traveller's own clock.
    static func zoneSuffix(
        _ date: Date,
        timeZoneIdentifier: String?,
        deviceTimeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier),
              zone.secondsFromGMT(for: date) != deviceTimeZone.secondsFromGMT(for: date) else { return nil }
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    /// `time` followed by the zone suffix when the station's clock differs from the device's.
    static func labeledTime(
        _ date: Date,
        timeZoneIdentifier: String,
        deviceTimeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let time = time(date, timeZoneIdentifier: timeZoneIdentifier)
        guard let suffix = zoneSuffix(date, timeZoneIdentifier: timeZoneIdentifier, deviceTimeZone: deviceTimeZone) else {
            return time
        }
        return "\(time) \(suffix)"
    }

    private static func formatter(
        dateFormat: String,
        timeZoneIdentifier: String
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateFormat
        return formatter
    }
}
