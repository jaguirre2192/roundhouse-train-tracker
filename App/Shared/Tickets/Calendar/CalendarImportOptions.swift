import Foundation

struct CalendarImportOptions: Codable, Equatable, Sendable {
    enum DatePreset: String, CaseIterable, Codable, Identifiable, Sendable {
        case recentAndUpcoming
        case next30Days
        case next120Days
        case custom

        var id: Self { self }
        var title: String {
            switch self {
            case .recentAndUpcoming: "Recent and Upcoming"
            case .next30Days: "Next 30 Days"
            case .next120Days: "Next 120 Days"
            case .custom: "Custom Dates"
            }
        }
    }

    enum ValidationError: LocalizedError, Equatable {
        case missingCustomDates
        case invalidDates
        case endBeforeStart
        case rangeTooLong

        var errorDescription: String? {
            switch self {
            case .missingCustomDates: "Choose a start date and an end date."
            case .invalidDates: "Choose valid calendar dates."
            case .endBeforeStart: "The end date must be on or after the start date."
            case .rangeTooLong: "Choose a date range of 366 days or fewer."
            }
        }
    }

    /// nil includes all calendars, including future additions. An empty set includes none.
    var selectedCalendarIDs: Set<String>?
    var datePreset: DatePreset
    var customStartDate: Date?
    var customEndDate: Date?

    init(
        selectedCalendarIDs: Set<String>? = nil,
        datePreset: DatePreset = .recentAndUpcoming,
        customStartDate: Date? = nil,
        customEndDate: Date? = nil
    ) {
        self.selectedCalendarIDs = selectedCalendarIDs
        self.datePreset = datePreset
        self.customStartDate = customStartDate
        self.customEndDate = customEndDate
    }

    func dateInterval(referenceDate: Date = .now, calendar: Calendar = .current) throws -> DateInterval {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { throw ValidationError.invalidDates }
        switch datePreset {
        case .recentAndUpcoming:
            return try relativeInterval(from: -14, through: 120, referenceDate: referenceDate, calendar: calendar)
        case .next30Days:
            return try relativeInterval(from: 0, through: 30, referenceDate: referenceDate, calendar: calendar)
        case .next120Days:
            return try relativeInterval(from: 0, through: 120, referenceDate: referenceDate, calendar: calendar)
        case .custom:
            guard let customStartDate, let customEndDate else { throw ValidationError.missingCustomDates }
            guard customStartDate.timeIntervalSinceReferenceDate.isFinite,
                  customEndDate.timeIntervalSinceReferenceDate.isFinite else { throw ValidationError.invalidDates }
            let start = calendar.startOfDay(for: customStartDate)
            let lastDay = calendar.startOfDay(for: customEndDate)
            guard lastDay >= start else { throw ValidationError.endBeforeStart }
            guard let days = calendar.dateComponents([.day], from: start, to: lastDay).day,
                  let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
                throw ValidationError.invalidDates
            }
            guard days < 366 else { throw ValidationError.rangeTooLong }
            return DateInterval(start: start, end: exclusiveEnd)
        }
    }

    var dateRangeSummary: String {
        switch datePreset {
        case .recentAndUpcoming: "Past 14 and next 120 days"
        case .next30Days: "Next 30 days"
        case .next120Days: "Next 120 days"
        case .custom:
            if let customStartDate, let customEndDate {
                "\(customStartDate.formatted(date: .abbreviated, time: .omitted)) – \(customEndDate.formatted(date: .abbreviated, time: .omitted))"
            } else {
                "Custom dates"
            }
        }
    }

    func calendarSummary(availableCalendars: [CalendarDescriptor]) -> String {
        guard let selectedCalendarIDs else { return "All calendars" }
        guard !selectedCalendarIDs.isEmpty else { return "No calendars selected" }
        let selected = availableCalendars.filter { selectedCalendarIDs.contains($0.id) }
        if selected.count == 1, selectedCalendarIDs.count == 1 { return selected[0].title }
        let count = selectedCalendarIDs.count
        return count == 1 ? "1 selected calendar" : "\(count) selected calendars"
    }

    private func relativeInterval(
        from startOffset: Int, through endOffset: Int,
        referenceDate: Date, calendar: Calendar
    ) throws -> DateInterval {
        guard let start = calendar.date(byAdding: .day, value: startOffset, to: referenceDate),
              let end = calendar.date(byAdding: .day, value: endOffset, to: referenceDate) else {
            throw ValidationError.invalidDates
        }
        return DateInterval(start: start, end: end)
    }
}
