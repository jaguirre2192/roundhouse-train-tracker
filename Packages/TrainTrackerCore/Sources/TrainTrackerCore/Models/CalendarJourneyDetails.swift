import Foundation

/// The structured fields a person confirmed when importing a Calendar journey. This is
/// deliberately not a copy of the event: no title, notes, location, or raw identifiers.
public struct CalendarJourneyDetails: Codable, Hashable, Sendable {
    public let originName: String
    public let destinationName: String
    public let trainNumber: String?
    public let departureDate: Date
    public let timeZoneIdentifier: String?
    /// Set when the boarding station supplied the zone for a floating or all-day event.
    public let boardingTimeZoneIdentifier: String?
    /// Whether the Calendar event required the person to supply a departure time.
    public let isAllDay: Bool

    public init(
        originName: String, destinationName: String, trainNumber: String?,
        departureDate: Date, timeZoneIdentifier: String?, isAllDay: Bool, boardingTimeZoneIdentifier: String? = nil
    ) {
        self.originName = originName
        self.destinationName = destinationName
        self.trainNumber = trainNumber
        self.departureDate = departureDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.boardingTimeZoneIdentifier = boardingTimeZoneIdentifier
        self.isAllDay = isAllDay
    }
}
