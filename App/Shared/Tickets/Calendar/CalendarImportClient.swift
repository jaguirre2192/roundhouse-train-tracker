import EventKit
import Foundation

/// Thin, testable wrapper around EventKit. Access is requested only when the caller explicitly
/// asks for it, and only events inside the supplied bounded window are ever read.
actor CalendarImportClient: CalendarImportClientProtocol {
    enum ClientError: LocalizedError, Equatable {
        case accessDenied
        case accessRestricted

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Roundhouse doesn't have permission to read your calendar."
            case .accessRestricted: "Calendar access is restricted on this device."
            }
        }
    }

    /// Created on first explicit use, so constructing a client never touches EventKit.
    private lazy var store = EKEventStore()

    nonisolated var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async throws -> Bool {
        try Task.checkCancellation()
        let granted = try await store.requestFullAccessToEvents()
        try Task.checkCancellation()
        return granted
    }

    func fetchCalendars() throws -> [CalendarDescriptor] {
        try requireReadAccess()
        store.reset()
        return store.calendars(for: .event).map {
            CalendarDescriptor(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "Calendar")
        }.sorted {
            if $0.sourceTitle != $1.sourceTitle {
                return $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending
            }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func requireReadAccess() throws {
        try Task.checkCancellation()
        switch authorizationStatus {
        case .fullAccess: break
        case .restricted: throw ClientError.accessRestricted
        default: throw ClientError.accessDenied
        }
    }

    func fetchCandidates(
        window: DateInterval,
        includingEventKeys: Set<String> = [],
        selectedCalendarIDs: Set<String>? = nil
    ) throws -> [CalendarJourneyCandidate] {
        try requireReadAccess()
        if selectedCalendarIDs?.isEmpty == true { return [] }

        // This client never writes calendar data. Discard cached EventKit objects so a
        // refresh after edits or Settings changes creates current, independent snapshots.
        store.reset()
        let calendars: [EKCalendar]?
        if let selectedCalendarIDs {
            let selected = store.calendars(for: .event).filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
            // A removed or unavailable selection must never turn into an all-calendar query.
            guard !selected.isEmpty else { return [] }
            calendars = selected
        } else {
            calendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: calendars
        )
        let events = store.events(matching: predicate)
        return try events.compactMap { event -> CalendarJourneyCandidate? in
            try Task.checkCancellation()
            let snapshot = CalendarEventSnapshot(
                eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                calendarTitle: event.calendar?.title ?? "Calendar",
                title: event.title ?? "",
                notes: event.notes,
                location: event.location,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                timeZoneIdentifier: event.timeZone?.identifier,
                isCancelled: event.status == .canceled,
                occurrenceDate: event.occurrenceDate,
                isRecurring: event.hasRecurrenceRules || event.isDetached
            )
            return Self.candidate(for: snapshot, includingEventKeys: includingEventKeys)
        }
        .sorted {
            if $0.snapshot.startDate == $1.snapshot.startDate { return $0.id < $1.id }
            return $0.snapshot.startDate < $1.snapshot.startDate
        }
    }

    nonisolated static func candidate(
        for snapshot: CalendarEventSnapshot,
        includingEventKeys: Set<String>
    ) -> CalendarJourneyCandidate? {
        if let classification = CalendarJourneyClassifier.classify(snapshot) {
            return CalendarJourneyCandidate(snapshot: snapshot, classification: classification)
        }
        // A previously imported event can lose its train keywords when renamed or
        // cancelled. Keep that exact occurrence visible so the person can review it.
        guard includingEventKeys.contains(snapshot.importSource.eventKey)
            || includingEventKeys.contains(snapshot.legacyImportSource.eventKey) else { return nil }
        return CalendarJourneyCandidate(
            snapshot: snapshot,
            classification: CalendarJourneyClassification(
                confidence: .medium,
                evidence: ["Previously imported calendar event"],
                originGuess: nil,
                destinationGuess: nil,
                trainNumberGuess: nil
            )
        )
    }
}
