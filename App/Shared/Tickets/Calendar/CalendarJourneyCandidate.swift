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
    /// EventKit materializes floating dates in this zone at read time.
    let readTimeZone: TimeZone
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
        self.readTimeZone = NSTimeZone.default
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
    var retainedForSavedJourney = false

    var id: String { snapshot.importSource.eventKey }
}

enum CalendarJourneyClassifier {
    private static let otherActivity = [
        #"^\s*(?:(?:outbound|return|inbound|connecting|domestic|international)\s+)?(?:flight|vol|vuelo|flug)\b"#,
        #"^\s*(?:boarding\s+pass|pick[ -]?up|drop[ -]?off|accommodation)\b"#,
        #"^\s*(?:book|buy|refund|cancel)\s+(?:(?:a|the|my|our)\s+)?(?:train|rail)\s+ticket|^\s*(?:train|rail)\s+ticket\s+refund\b"#,
        #"^\s*train\s+(?:the\s+trainer|for\s+(?:(?:a|an|the)\s+)?(?:marathon|race|triathlon|competition))\b"#
    ].joined(separator: "|")

    private static let eventPurpose = [
        #"\b(?:dinner|luncheon|lunch|breakfast|banquet)\b|\b(?:conference|symposium)\s*(?:$|[:—])"#,
        #"\b(?:tour|visit)\b.*\bmuseum\b|\bmuseum\s+(?:tour|visit)\b|\b(?:summit|conference|symposium)\s+(?:19|20)[0-9]{2}\b"#
    ].joined(separator: "|")

    private static let accessDirections = [
        #"^\s*(?:directions|getting\s+(?:there|here)|ground\s+(?:transfers?|transportation)|nearest\s+(?:(?:train|rail|metro)\s+)?station)\s*:"#,
        #"\b(?:upon|after)\s+landing\b|\b(?:connects?|links?)\s+(?:the\s+)?airport\s+(?:with|to)\b"#,
        #"\b(?:nearest|closest)\s+(?:train|rail(?:way)?)\s+station\b|\b(?:near|by|next\s+to)\s+(?:the\s+)?(?:train|railway)\s+station\b"#
    ].joined(separator: "|")

    /// Conservatively classifies an event as a likely train journey. Returns `nil` unless the
    /// event has a real train-journey signal — an ordinary meeting or reminder should never
    /// surface in the picker.
    static func classify(_ snapshot: CalendarEventSnapshot) -> CalendarJourneyClassification? {
        // The event's time belongs to its main activity. Rail directions in the notes of a
        // flight, dinner or appointment must never turn that activity into a train journey.
        let heading = String(snapshot.title.prefix(8_000).prefix { !$0.isNewline })
        guard !describesAnotherActivity(heading) else { return nil }
        // Event notes often include a venue's directions underneath the actual booking.
        // Drop those lines before they can lend a service number to an unrelated route.
        let notes = snapshot.notes.map { text in
            String(text.prefix(8_000)).components(separatedBy: .newlines)
                .filter { !TicketTextPattern.contains(accessDirections, in: $0) }
                .joined(separator: "\n")
        }
        guard let match = TicketRouteTextHeuristics.match(
            title: snapshot.title,
            supportingText: [notes],
            location: snapshot.location
        ) else { return nil }

        return CalendarJourneyClassification(
            confidence: match.confidence,
            evidence: match.evidence,
            originGuess: match.originGuess,
            destinationGuess: match.destinationGuess,
            trainNumberGuess: match.trainMatchingIdentifier ?? match.trainNumberGuess,
            hasConflictingTrainProducts: match.hasConflictingTrainProducts
        )
    }

    private static func describesAnotherActivity(_ heading: String) -> Bool {
        if TicketTextPattern.contains(otherActivity, in: heading) { return true }
        return TicketTextPattern.contains(eventPurpose, in: heading)
            && !TicketTrainNumberParser.startsWithPassengerJourney(heading)
    }
}
