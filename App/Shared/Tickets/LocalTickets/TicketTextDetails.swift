import Foundation

/// A departure exactly as a ticket prints it: local wall-clock values at the boarding station.
/// The station's time zone is only known after matching, so no absolute instant is invented.
struct TicketWallClock: Codable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?

    init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// Wall-clock values of an absolute date in a known zone.
    init(date: Date, timeZone: TimeZone, includesTime: Bool) {
        let parts = Self.calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(
            year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1,
            hour: includesTime ? parts.hour : nil, minute: includesTime ? parts.minute : nil
        )
    }

    /// Parses `requestValue`. Values carrying a zone or offset are not wall-clock values.
    init?(requestValue value: String) {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::00)?)?$"#
        guard let regex = TicketTextPattern.expression(pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ index: Int) -> Int? {
            Range(match.range(at: index), in: value).flatMap { Int(value[$0]) }
        }
        guard let year = group(1), let month = group(2), let day = group(3) else { return nil }
        self.init(year: year, month: month, day: day, hour: group(4), minute: group(5))
        guard isValid else { return nil }
    }

    var hasTime: Bool { hour != nil && minute != nil }

    var isValid: Bool {
        guard (1...12).contains(month), (0...23).contains(hour ?? 12), (0...59).contains(minute ?? 0) else { return false }
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = Self.calendar(TimeZone(secondsFromGMT: 0) ?? .gmt)
        return components.isValidDate
    }

    /// `yyyy-MM-dd` when only the day is known, otherwise a local `yyyy-MM-ddTHH:mm:00` value
    /// that `TicketJourneySearchPrefill` resolves in the matched boarding station's zone.
    var requestValue: String {
        let dayText = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour, let minute else { return dayText }
        return dayText + String(format: "T%02d:%02d:00", hour, minute)
    }

    /// Noon stands in for an unknown time so a day never shifts across a zone boundary.
    func date(in timeZone: TimeZone) -> Date? {
        Self.calendar(timeZone).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour ?? 12, minute: minute ?? 0
        ))
    }

    /// Calendar normalizes a skipped spring-forward hour into the following hour.
    func exactTime(in timeZone: TimeZone) -> Date? {
        guard hasTime, let instant = date(in: timeZone),
              Self(date: instant, timeZone: timeZone, includesTime: true) == self else { return nil }
        return instant
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// Explicit ticket labels extracted locally. Anything ambiguous stays `nil` for the person to
/// supply; an email's sent date, a booking date or a reference number is never a departure.
struct TicketTextDetails: Codable, Hashable, Sendable {
    var coach: String?
    var seat: String?
    var bookingReference: String?
    var departure: TicketWallClock?
    /// Present only when the text carried an explicit UTC offset for the departure.
    var departureInstant: Date?
    /// A boarding-station zone guessed from well-known station names, used for display only.
    var timeZoneIdentifier: String?
    /// More than one candidate departure date or time was found, so none was chosen.
    var hasConflictingDates = false

    init(
        coach: String? = nil, seat: String? = nil, bookingReference: String? = nil,
        departure: TicketWallClock? = nil, departureInstant: Date? = nil,
        timeZoneIdentifier: String? = nil, hasConflictingDates: Bool = false
    ) {
        self.coach = coach
        self.seat = seat
        self.bookingReference = bookingReference
        self.departure = departure
        self.departureInstant = departureInstant
        self.timeZoneIdentifier = timeZoneIdentifier
        self.hasConflictingDates = hasConflictingDates
    }

    static let maxCharacters = 12_000

    static func extract(from text: String, origin: String?) -> Self {
        let lines = String(text.prefix(maxCharacters)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 400 }
        var result = Self(
            coach: labelledValue(#"\b(?:coach|carriage|car)(?:\s+(?:no\.?|number))?\s*[:#]?\s*([A-Z]?[0-9]{1,3}[A-Z]?)\b"#, in: lines),
            seat: labelledValue(#"\bseats?(?:\s+(?:no\.?|number))?\s*[:#]?\s*([0-9]{1,3}[A-Z]?)\b"#, in: lines),
            bookingReference: labelledValue(#"\b(?:booking\s*(?:reference|ref\.?|number|code)|reservation\s*(?:number|code)|confirmation\s*(?:number|code|#)|PNR|ticket\s*number)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{4,24})\b"#, in: lines),
            timeZoneIdentifier: origin.flatMap(stationTimeZone)
        )
        let departure = departureValue(in: lines)
        result.departure = departure.clock
        result.departureInstant = departure.instant
        result.hasConflictingDates = departure.conflicting
        return result
    }

    /// A service number must never be a copy of the booking reference.
    func acceptsTrainNumber(_ number: String?) -> Bool {
        guard let number, let bookingReference else { return true }
        func key(_ value: String) -> String { String(value.uppercased().filter { $0.isLetter || $0.isNumber }) }
        return key(number).isEmpty || key(bookingReference) != key(number)
    }

    // MARK: - Labels

    private static func labelledValue(_ pattern: String, in lines: [String]) -> String? {
        let values = Set(lines.compactMap { TicketTextPattern.firstCapture(pattern, in: $0)?.uppercased() })
        return values.count == 1 ? values.first : nil
    }

    // MARK: - Departure

    private static let departureLabel = #"^(?:outbound|departure(?:\s+(?:date|time|date\s*(?:and|&)\s*time))?|depart(?:s|ing)?|travel\s+date|date\s+of\s+travel|journey\s+date|leaving)\b"#
    /// Header and commerce dates that must never be taken as a travel date.
    private static let excludedLine = #"^(?:date|sent|received|from|to|subject|cc|bcc|reply-to)\s*:|\b(?:booked|booking\s+date|purchased?|issued|order(?:ed)?|payment|paid|valid\s+(?:until|through)|expires?|expiry|refund|printed|generated|created|arriv(?:e|es|al|ing))\b|\barr\."#
    private static let arrivalLabel = #"^\s*(?:arriv(?:e|es|al|ing)|arr\.)"#
    private static let months = #"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    private static let isoInstant = #"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2}))"#

    private struct DayValue: Hashable {
        let year: Int, month: Int, day: Int
    }

    private struct TimeValue: Hashable {
        let hour: Int, minute: Int
    }

    private static func departureValue(in lines: [String]) -> (clock: TicketWallClock?, instant: Date?, conflicting: Bool) {
        // 1. Departure-labelled lines, including a value printed on the line after a bare label.
        var labelled: [String] = []
        for (index, line) in lines.enumerated() where TicketTextPattern.contains(departureLabel, in: line) {
            labelled.append(line)
            if days(in: line).isEmpty, times(in: line).isEmpty, lines.indices.contains(index + 1),
               !TicketTextPattern.contains(arrivalLabel, in: lines[index + 1]) {
                labelled.append(lines[index + 1])
            }
        }
        let labelledDays = Set(labelled.flatMap(days))
        if labelledDays.count > 1 { return (nil, nil, true) }
        if hasConflictingInstants(in: labelled) { return (nil, nil, true) }
        if let explicit = instant(in: labelled) { return (explicit.clock, explicit.date, false) }

        // 2. Otherwise one unambiguous date anywhere outside header and purchase lines.
        let eligible = lines.filter { !TicketTextPattern.contains(excludedLine, in: $0) }
        let day: DayValue
        if let only = labelledDays.first {
            day = only
        } else {
            if hasConflictingInstants(in: eligible) { return (nil, nil, true) }
            if Set(eligible.flatMap(days)).count > 1 { return (nil, nil, true) }
            if let explicit = instant(in: eligible) { return (explicit.clock, explicit.date, false) }
            let found = Set(eligible.flatMap(days))
            guard found.count == 1, let only = found.first else { return (nil, nil, found.count > 1) }
            day = only
        }

        // A time printed with the departure label wins, then one on the same line as the day.
        let labelledTimes = Set(labelled.flatMap(times))
        let sameLineTimes = Set(eligible.filter { days(in: $0).contains(day) }.flatMap(times))
        let candidates = labelledTimes.isEmpty ? sameLineTimes : labelledTimes
        var clock = TicketWallClock(year: day.year, month: day.month, day: day.day)
        if candidates.count == 1, let time = candidates.first {
            clock.hour = time.hour
            clock.minute = time.minute
        }
        guard clock.isValid else { return (nil, nil, false) }
        return (clock, nil, candidates.count > 1)
    }

    private static func hasConflictingInstants(in lines: [String]) -> Bool {
        let values = Set(lines.flatMap { line in
            TicketTextPattern.ranges(isoInstant, in: line).map { String(line[$0]) }
        })
        if values.count > 1 { return true }
        guard let explicit = instant(in: lines) else { return false }
        return lines.flatMap(times).contains {
            $0.hour != explicit.clock.hour || $0.minute != explicit.clock.minute
        }
    }

    private static func instant(in lines: [String]) -> (clock: TicketWallClock, date: Date)? {
        let values = Set(lines.compactMap { TicketTextPattern.firstCapture(isoInstant, in: $0) })
        guard values.count == 1, let value = values.first else { return nil }
        var normalized = value
        if let range = TicketTextPattern.ranges(#"T\d{2}:\d{2}(?=Z|[+-])"#, in: value).first {
            normalized.insert(contentsOf: ":00", at: range.upperBound)
        }
        guard let date = ISO8601DateFormatter().date(from: normalized) else { return nil }
        let offset = TicketTextPattern.firstCapture(#"(Z|[+-]\d{2}:?\d{2})$"#, in: value) ?? "Z"
        guard let zone = offsetZone(offset) else { return nil }
        return (TicketWallClock(date: date, timeZone: zone, includesTime: true), date)
    }

    private static func offsetZone(_ value: String) -> TimeZone? {
        guard value.uppercased() != "Z" else { return TimeZone(secondsFromGMT: 0) }
        let digits = value.filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (value.hasPrefix("-") ? -1 : 1))
    }

    private static func days(in line: String) -> [DayValue] {
        let weekday = #"(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?"#
        // ISO, English month-first and day-first dates. Numeric slash dates are ambiguous.
        let iso = #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#
        let monthFirst = #"\b"# + weekday + "(" + months + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#
        let dayFirst = #"\b"# + weekday + #"(\d{1,2})(?:st|nd|rd|th)?\s+("# + months + #")\.?,?\s+(\d{4})\b"#
        var found: [DayValue] = []
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            TicketTextPattern.expression(pattern)?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? []
        }
        for match in matches(iso) {
            if let y = int(match, 1, line), let m = int(match, 2, line), let d = int(match, 3, line) {
                found.append(DayValue(year: y, month: m, day: d))
            }
        }
        for match in matches(monthFirst) {
            if let m = month(match, 1, line), let d = int(match, 2, line), let y = int(match, 3, line) {
                found.append(DayValue(year: y, month: m, day: d))
            }
        }
        for match in matches(dayFirst) {
            if let d = int(match, 1, line), let m = month(match, 2, line), let y = int(match, 3, line) {
                found.append(DayValue(year: y, month: m, day: d))
            }
        }
        return found.filter { TicketWallClock(year: $0.year, month: $0.month, day: $0.day).isValid }
    }

    private static func times(in line: String) -> [TimeValue] {
        // Skip ISO timestamps and durations such as "2:45 hrs".
        // Removing the entire timestamp also excludes its offset (for example -05:00).
        var line = line
        for range in TicketTextPattern.ranges(isoInstant, in: line).reversed() {
            line.removeSubrange(range)
        }
        let pattern = #"(?<![\d:T])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])(?:\s*([ap])\.?\s?m\b\.?)?(?!\s*(?:hrs?|hours?|mins?)\b)"#
        guard let regex = TicketTextPattern.expression(pattern) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard var hour = int(match, 1, line), let minute = int(match, 2, line) else { return nil }
            if let range = Range(match.range(at: 3), in: line) {
                guard (1...12).contains(hour) else { return nil }
                let isAfternoon = line[range].lowercased() == "p"
                if isAfternoon, hour != 12 { hour += 12 }
                if !isAfternoon, hour == 12 { hour = 0 }
            }
            return TimeValue(hour: hour, minute: minute)
        }
    }

    private static func int(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> Int? {
        Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
    }

    private static func month(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(text[range].lowercased().prefix(3))).map { $0 + 1 }
    }

    static func stationTimeZone(_ station: String) -> String? {
        let name = station.lowercased()
        let zones: [(String, [String])] = [
            ("America/New_York", ["washington", "new york", "moynihan", "boston", "philadelphia", "baltimore", "newark", "new haven", "providence"]),
            ("America/Chicago", ["chicago", "milwaukee", "st. louis", "st louis", "new orleans"]),
            ("America/Los_Angeles", ["los angeles", "san diego", "seattle", "sacramento", "emeryville", "oakland"]),
            ("Europe/London", ["london", "edinburgh", "manchester"]),
            ("Europe/Paris", ["paris", "lyon", "marseille"]),
            ("Europe/Brussels", ["brussels", "bruxelles"]),
            ("Europe/Amsterdam", ["amsterdam", "rotterdam"]),
            ("Asia/Tokyo", ["tokyo", "kyoto", "東京", "京都"])
        ]
        return zones.first { _, names in names.contains { name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + ",") } }?.0
    }
}
