import Foundation

/// Matches the backend's service-day convention: MOTIS origin day, then the boarding
/// station's local day. Calendar days are represented at midnight UTC on the wire.
enum TransitousServiceDate {
    static func resolve(tripID: String, place: TransitousPlaceDTO, fallback: Date) -> Date {
        let event = [place.scheduledDeparture, place.scheduledArrival, place.departure, place.arrival]
            .compactMap(normalized).first
        let localDay = event.flatMap(RailDateParser.parse).map {
            calendarDay($0, in: normalized(place.tz).flatMap(TimeZone.init(identifier:)) ?? .gmt)
        }
        if let origin = originDay(tripID) {
            // Long-distance services can reach a stop days later; one day backwards
            // accommodates westward time-zone crossings near midnight.
            let elapsed = localDay?.timeIntervalSince(origin) ?? 0
            if (-86_400...259_200).contains(elapsed) { return origin }
        }
        return localDay ?? calendarDay(fallback, in: .gmt)
    }

    private static func originDay(_ tripID: String) -> Date? {
        let prefix = Array(tripID.prefix(9).utf8)
        guard prefix.count == 9, prefix[8] == 95,
              prefix.prefix(8).allSatisfy({ (48...57).contains($0) }) else { return nil }
        func number(_ range: Range<Int>) -> Int {
            prefix[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let expected = DateComponents(year: number(0..<4), month: number(4..<6), day: number(6..<8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: expected),
              calendar.dateComponents([.year, .month, .day], from: date) == expected else { return nil }
        return date
    }

    private static func calendarDay(_ date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = .gmt
        return calendar.date(from: components) ?? date
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
