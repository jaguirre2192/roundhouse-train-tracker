import CryptoKit
import Foundation
import TrainTrackerCore

extension CalendarEventSnapshot {
    /// Identity: the event, plus the occurrence date only for repeating events. EventKit reports
    /// a one-off event's start as its occurrence date, so keying on it made a rescheduled trip
    /// look like a new event and orphaned its saved journey.
    ///
    /// Revision: what the person could change. All-day and floating events are compared by their
    /// calendar date and clock time, because EventKit places them in the device's current time
    /// zone; travelling must not make them look edited.
    var importSource: CalendarJourneySource {
        CalendarJourneySource(
            eventKey: Self.digest([eventIdentifier, occurrenceKey]),
            revision: Self.digest([
                title, notes ?? "", location ?? "",
                revisionDate(startDate), revisionDate(endDate),
                String(isAllDay), timeZoneIdentifier ?? "floating", String(isCancelled)
            ])
        )
    }

    var hasFloatingOccurrence: Bool { isRecurring && (isAllDay || timeZoneIdentifier == nil) }

    private var occurrenceKey: String {
        guard isRecurring else { return "single" }
        let original = occurrenceDate ?? startDate
        guard hasFloatingOccurrence else { return String(original.timeIntervalSince1970) }
        // EventKit expresses a floating occurrence in the device's current zone. The
        // local calendar date and clock identify this occurrence even after travelling.
        return "local:" + String(localSeconds(original))
    }

    private func localSeconds(_ date: Date) -> TimeInterval {
        date.timeIntervalSince1970 + TimeInterval(readTimeZone.secondsFromGMT(for: date))
    }

    /// Past releases hashed floating occurrences as absolute instants. If a traveller
    /// upgrades in another zone, recognise the old hash only when the saved revision
    /// still describes this exact local occurrence. A hash match alone is ambiguous
    /// across adjacent occurrences of a frequent series.
    func priorFloatingKey(among keysWithMatchingRevision: Set<String>) -> String? {
        guard hasFloatingOccurrence, let occurrenceDate,
              !keysWithMatchingRevision.isEmpty else { return nil }
        let clock = localSeconds(occurrenceDate)
        let offsets = Set(TimeZone.knownTimeZoneIdentifiers.compactMap {
            TimeZone(identifier: $0)?.secondsFromGMT(for: occurrenceDate)
        })
        let matches = offsets.compactMap { offset -> String? in
            let key = Self.digest([eventIdentifier, String(clock - TimeInterval(offset))])
            return keysWithMatchingRevision.contains(key) ? key : nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// The identity and revision written before 2026-09-30, used to recognise journeys saved then.
    var legacyImportSource: CalendarJourneySource {
        CalendarJourneySource(
            eventKey: Self.digest([
                eventIdentifier,
                occurrenceDate.map { String($0.timeIntervalSince1970) } ?? "single"
            ]),
            revision: Self.digest([
                title, notes ?? "", location ?? "",
                String(startDate.timeIntervalSince1970), String(endDate.timeIntervalSince1970),
                String(isAllDay), timeZoneIdentifier ?? "floating", String(isCancelled)
            ])
        )
    }

    /// True when a saved revision still describes this event, whichever format saved it.
    func matchesRevision(_ revision: String) -> Bool {
        revision == importSource.revision || revision == legacyImportSource.revision
    }

    /// The same absolute instant can be adjacent local occurrences in two different
    /// zones. For old floating keys, require the revision as independent evidence.
    func acceptsLegacyRevision(_ revision: String) -> Bool {
        !hasFloatingOccurrence || matchesRevision(revision)
    }

    private func revisionDate(_ date: Date) -> String {
        guard isAllDay || timeZoneIdentifier == nil else { return String(date.timeIntervalSince1970) }
        // Floating times read in the device's zone; their wall-clock value is the event.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = readTimeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let time = isAllDay ? "" : String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return String(format: "local:%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) + time
    }

    private static func digest(_ fields: [String]) -> String {
        // Length-prefix each field so text containing separators cannot alias another event.
        let text = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum CalendarImportDisposition: Equatable {
    case newJourney
    case alreadyAdded
    case changed
    case cancelled

    init(candidate: CalendarJourneyCandidate, savedPlan: TrackedJourneyPlan?) {
        if candidate.snapshot.isCancelled {
            self = .cancelled
        } else if let source = savedPlan?.calendarSource {
            self = candidate.snapshot.matchesRevision(source.revision) ? .alreadyAdded : .changed
        } else {
            self = .newJourney
        }
    }
}
