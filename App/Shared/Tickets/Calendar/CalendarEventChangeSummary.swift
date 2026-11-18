import Foundation
import TrainTrackerCore

/// Compares confirmed journey fields with the current Calendar extraction. A revision hash
/// alone cannot tell us which event field changed, so it never generates an invented delta.
struct CalendarEventChangeSummary: Equatable, Sendable {
    enum Field: String, Hashable, Sendable {
        case origin, destination, trainNumber, departure, timeZone, calendarTiming

        var title: String {
            switch self {
            case .origin: "Origin"
            case .destination: "Destination"
            case .trainNumber: "Train number"
            case .departure: "Departure"
            case .timeZone: "Time zone"
            case .calendarTiming: "Calendar timing"
            }
        }
    }

    enum Value: Equatable, Sendable {
        case text(String?)
        case departure(Date, timeZoneIdentifier: String?, includesTime: Bool)
        case timeZone(String?)
        case allDay(Bool)
    }

    struct Change: Identifiable, Equatable, Sendable {
        let field: Field
        let previouslyImported: Value
        let calendarEvent: Value
        var id: Field { field }
    }

    enum Explanation: Equatable, Sendable {
        case previousDetailsUnavailable
        case differentEvent
        case unrecordedChange
        case unchanged

        var message: String {
            switch self {
            case .previousDetailsUnavailable:
                "Earlier journey details weren’t saved with this import, so a field comparison isn’t available. Review the current Calendar event before updating."
            case .differentEvent:
                "This saved journey is linked to a different Calendar event. Its earlier values can’t be used for this comparison."
            case .unrecordedChange:
                "The Calendar event changed, but the comparable journey details are the same. Its title, notes, location, or another event detail may have changed. Review the event before updating."
            case .unchanged:
                "The Calendar event matches the version previously imported."
            }
        }
    }

    let changes: [Change]
    let explanation: Explanation?

    init(candidate: CalendarJourneyCandidate, savedPlan: TrackedJourneyPlan?) {
        self.init(candidate: candidate, previousSource: savedPlan?.calendarSource)
    }

    init(candidate: CalendarJourneyCandidate, previousSource: CalendarJourneySource?) {
        guard let previousSource else {
            self.init(explanation: .previousDetailsUnavailable)
            return
        }
        guard previousSource.eventKey == candidate.id else {
            self.init(explanation: .differentEvent)
            return
        }
        guard let details = previousSource.details else {
            self.init(explanation: .previousDetailsUnavailable)
            return
        }
        guard previousSource.revision != candidate.snapshot.importSource.revision else {
            self.init(explanation: .unchanged)
            return
        }

        let event = candidate.snapshot
        var differences: [Change] = []
        let textFields: [(Field, String?, String?)] = [
            (.origin, details.originName, candidate.classification.originGuess),
            (.destination, details.destinationName, candidate.classification.destinationGuess),
            (.trainNumber, details.trainNumber, candidate.classification.trainNumberGuess)
        ]
        for (field, old, new) in textFields where Self.normalized(old) != Self.normalized(new) {
            differences.append(Change(field: field, previouslyImported: .text(old), calendarEvent: .text(new)))
        }
        if !Self.sameDeparture(details, event) {
            differences.append(Change(
                field: .departure,
                previouslyImported: .departure(details.departureDate, timeZoneIdentifier: details.timeZoneIdentifier, includesTime: true),
                calendarEvent: .departure(event.startDate, timeZoneIdentifier: event.timeZoneIdentifier, includesTime: !event.isAllDay)
            ))
        }
        if details.timeZoneIdentifier != event.timeZoneIdentifier {
            differences.append(Change(
                field: .timeZone,
                previouslyImported: .timeZone(details.timeZoneIdentifier),
                calendarEvent: .timeZone(event.timeZoneIdentifier)
            ))
        }
        if details.isAllDay != event.isAllDay {
            differences.append(Change(
                field: .calendarTiming,
                previouslyImported: .allDay(details.isAllDay), calendarEvent: .allDay(event.isAllDay)
            ))
        }
        self.init(changes: differences, explanation: differences.isEmpty ? .unrecordedChange : nil)
    }

    private init(changes: [Change] = [], explanation: Explanation?) {
        self.changes = changes
        self.explanation = explanation
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func sameDeparture(_ details: CalendarJourneyDetails, _ event: CalendarEventSnapshot) -> Bool {
        if details.isAllDay && event.isAllDay {
            var oldCalendar = Calendar(identifier: .gregorian)
            oldCalendar.timeZone = details.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            var newCalendar = Calendar(identifier: .gregorian)
            newCalendar.timeZone = event.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            return oldCalendar.dateComponents([.year, .month, .day], from: details.departureDate)
                == newCalendar.dateComponents([.year, .month, .day], from: event.startDate)
        }
        // The review UI displays minutes. Sub-minute storage differences do not become a
        // visually identical “before/after” row.
        return floor(details.departureDate.timeIntervalSince1970 / 60) == floor(event.startDate.timeIntervalSince1970 / 60)
    }
}
