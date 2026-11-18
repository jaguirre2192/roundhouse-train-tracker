import Foundation

/// A read-only snapshot of the calendar event fields we look at. Decoupled from EventKit so
/// classification can be unit tested without calendar permission.
struct CalendarEventSnapshot: Sendable, Hashable {
    let eventIdentifier: String
    let calendarTitle: String
    let title: String
    let notes: String?
    let location: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let timeZoneIdentifier: String?
    let isCancelled: Bool
    let occurrenceDate: Date?
    /// True for an occurrence of a repeating series (including a detached, individually edited
    /// occurrence). Only these need the occurrence date to tell one trip from the next.
    let isRecurring: Bool

    init(
        eventIdentifier: String, calendarTitle: String, title: String,
        notes: String?, location: String?, startDate: Date, endDate: Date,
        isAllDay: Bool, timeZoneIdentifier: String? = nil,
        isCancelled: Bool = false, occurrenceDate: Date? = nil, isRecurring: Bool = false
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarTitle = calendarTitle
        self.title = title
        self.notes = notes
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isCancelled = isCancelled
        self.occurrenceDate = occurrenceDate
        self.isRecurring = isRecurring
    }
}

struct CalendarJourneyClassification: Sendable, Hashable {
    let confidence: TicketRouteConfidence
    let evidence: [String]
    let originGuess: String?
    let destinationGuess: String?
    let trainNumberGuess: String?
    var hasConflictingTrainProducts = false
}

struct CalendarJourneyCandidate: Identifiable, Sendable, Hashable {
    let snapshot: CalendarEventSnapshot
    let classification: CalendarJourneyClassification

    var id: String { snapshot.importSource.eventKey }
}

enum CalendarJourneyClassifier {
    /// Conservatively classifies an event as a likely train journey. Returns `nil` unless the
    /// event has a real train-journey signal — an ordinary meeting or reminder should never
    /// surface in the picker.
    static func classify(_ snapshot: CalendarEventSnapshot) -> CalendarJourneyClassification? {
        guard let match = TicketRouteTextHeuristics.match(
            title: snapshot.title,
            supportingText: [snapshot.location, snapshot.notes]
        ) else { return nil }

        var origin = match.originGuess
        var destination = match.destinationGuess
        if origin == nil || destination == nil, let location = snapshot.location,
           let route = TicketRouteTextHeuristics.extractRoute(from: location) {
            origin = origin ?? route.origin
            destination = destination ?? route.destination
        }

        return CalendarJourneyClassification(
            confidence: (origin != nil && destination != nil) ? .high : match.confidence,
            evidence: match.evidence,
            originGuess: origin,
            destinationGuess: destination,
            trainNumberGuess: match.trainMatchingIdentifier ?? match.trainNumberGuess,
            hasConflictingTrainProducts: match.hasConflictingTrainProducts
        )
    }
}
