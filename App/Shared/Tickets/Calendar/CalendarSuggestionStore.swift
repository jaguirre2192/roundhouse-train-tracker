import EventKit
import Foundation
import Observation
import TrainTrackerCore

/// Suggestions are a separate opt-in from opening the Calendar importer manually.
/// Event access and operation cancellation remain owned by CalendarImportStore.
@MainActor
@Observable
final class CalendarSuggestionStore {
    private(set) var isEnabled: Bool
    private(set) var dismissedRevisions: Set<String>
    private(set) var isIntroductionDismissed: Bool
    let importStore: CalendarImportStore

    @ObservationIgnored private let client: any CalendarImportClientProtocol
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let preferenceKey: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastEventKeys: Set<String> = []

    init(
        client: any CalendarImportClientProtocol = CalendarImportClient(),
        preferences: CalendarImportPreferences = CalendarImportPreferences(),
        defaults: UserDefaults? = .standard,
        preferenceKey: String = "calendarSuggestions.v1",
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.client = client
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        isEnabled = defaults?.bool(forKey: preferenceKey + ".enabled") ?? false
        dismissedRevisions = Set(defaults?.stringArray(forKey: preferenceKey + ".dismissed") ?? [])
        isIntroductionDismissed = defaults?.bool(forKey: preferenceKey + ".introductionDismissed") ?? false
        importStore = CalendarImportStore(client: client, preferences: preferences)
    }

    var needsAccessRequest: Bool {
        [.notDetermined, .writeOnly].contains(client.authorizationStatus)
    }

    var state: CalendarImportStore.State { isEnabled ? importStore.state : .idle }

    /// Only a person's explicit Enable/Allow action may request system permission.
    func enable(includingEventKeys eventKeys: Set<String> = []) async {
        guard !Task.isCancelled else { return }
        isEnabled = true
        defaults?.set(true, forKey: preferenceKey + ".enabled")
        lastRefresh = now()
        lastEventKeys = eventKeys
        await importStore.beginImport(includingEventKeys: eventKeys)
    }

    func disable() {
        isEnabled = false
        defaults?.set(false, forKey: preferenceKey + ".enabled")
        importStore.reset()
    }

    /// Foreground refresh never asks for access, including after permission revocation.
    func refresh(includingEventKeys eventKeys: Set<String> = []) async {
        guard isEnabled, !Task.isCancelled else { return }
        lastRefresh = now()
        lastEventKeys = eventKeys
        await importStore.refresh(includingEventKeys: eventKeys)
    }

    /// Returning to My Trips reuses recent results instead of reading Calendar again.
    func refreshIfStale(includingEventKeys eventKeys: Set<String> = [], minimumInterval: TimeInterval = 300) async {
        guard isEnabled else { return }
        if let lastRefresh, eventKeys == lastEventKeys, now().timeIntervalSince(lastRefresh) < minimumInterval,
           importStore.state != .idle { return }
        await refresh(includingEventKeys: eventKeys)
    }

    /// "Not Now" hides the invitation. Suggestions stay off and Calendar is not read.
    func dismissIntroduction() {
        isIntroductionDismissed = true
        defaults?.set(true, forKey: preferenceKey + ".introductionDismissed")
    }

    /// Stop reads on background/disappearance without changing the person's preference.
    func suspend() { importStore.reset() }

    func dismiss(_ candidate: CalendarJourneyCandidate) {
        // Copies may use different event IDs or titles. Dismiss the displayed group's current
        // revisions so a genuinely edited booking can still return for review.
        let signature = CalendarSuggestionMatching.tripSignature(candidate)
        dismissedRevisions.insert(Self.copyDismissalKey(candidate))
        if case let .loaded(loaded) = importStore.state {
            for copy in loaded where CalendarSuggestionMatching.tripSignature(copy) == signature {
                dismissedRevisions.insert(Self.copyDismissalKey(copy))
            }
        }
        defaults?.set(dismissedRevisions.sorted(), forKey: preferenceKey + ".dismissed")
    }

    /// Evaluate saved IDs at render time so a completed review disappears immediately.
    /// A changed saved event is surfaced separately by `changedSavedEvents(savedPlans:)`.
    func candidates(excludingSavedEventKeys savedKeys: Set<String>) -> [CalendarJourneyCandidate] {
        candidates(savedEventKeys: savedKeys, savedPlans: [])
    }

    /// New suggestions only: not cancelled, not already saved from Calendar, not dismissed, not
    /// the same trip listed in another calendar, and not a trip already saved by hand.
    func candidates(savedPlans: [TrackedJourneyPlan]) -> [CalendarJourneyCandidate] {
        candidates(savedEventKeys: Set(savedPlans.compactMap { $0.calendarSource?.eventKey }), savedPlans: savedPlans)
    }

    /// Saved Calendar journeys whose event has since been edited or cancelled. They are reviewed
    /// in the importer, which compares old and new details field by field.
    func changedSavedEvents(savedPlans: [TrackedJourneyPlan]) -> [CalendarJourneyCandidate] {
        guard isEnabled, case let .loaded(candidates) = importStore.state else { return [] }
        let savedRevisions = Dictionary(
            savedPlans.compactMap { plan in plan.calendarSource.map { ($0.eventKey, $0.revision) } },
            uniquingKeysWith: { first, _ in first }
        )
        return candidates.filter { candidate in
            let snapshot = candidate.snapshot
            if let revision = savedRevisions[candidate.id] {
                return snapshot.isCancelled || !snapshot.matchesRevision(revision)
            }
            guard let revision = savedRevisions[snapshot.legacyImportSource.eventKey],
                  snapshot.acceptsLegacyRevision(revision) else { return false }
            return snapshot.isCancelled || !snapshot.matchesRevision(revision)
        }
    }

    private func candidates(savedEventKeys savedKeys: Set<String>, savedPlans: [TrackedJourneyPlan]) -> [CalendarJourneyCandidate] {
        guard isEnabled, case let .loaded(candidates) = importStore.state else { return [] }
        var seenKeys: Set<String> = []
        var seenTrips: Set<String> = []
        return candidates
            .sorted { $0.snapshot.startDate < $1.snapshot.startDate }
            .filter { candidate in
                guard !candidate.snapshot.isCancelled, !candidate.retainedForSavedJourney,
                      !savedKeys.contains(candidate.id),
                      (candidate.snapshot.hasFloatingOccurrence || !savedKeys.contains(candidate.snapshot.legacyImportSource.eventKey)),
                      !isDismissed(candidate),
                      !CalendarSuggestionMatching.duplicatesSavedPlan(candidate, in: savedPlans),
                      seenKeys.insert(candidate.id).inserted else { return false }
                return seenTrips.insert(CalendarSuggestionMatching.tripSignature(candidate)).inserted
            }
    }

    private func isDismissed(_ candidate: CalendarJourneyCandidate) -> Bool {
        guard !dismissedRevisions.isEmpty else { return false }
        let source = candidate.snapshot.importSource
        let legacy = candidate.snapshot.legacyImportSource
        if dismissedRevisions.contains("copy:" + source.revision)
            || dismissedRevisions.contains(source.eventKey + ":" + source.revision)
            || dismissedRevisions.contains(legacy.eventKey + ":" + source.revision)
            || dismissedRevisions.contains(legacy.eventKey + ":" + legacy.revision) { return true }
        guard candidate.snapshot.hasFloatingOccurrence else { return false }
        let suffix = ":" + source.revision
        let matchingKeys = dismissedRevisions.compactMap { key in
            key.hasSuffix(suffix) ? String(key.dropLast(suffix.count)) : nil
        }
        return candidate.snapshot.priorFloatingKey(among: Set(matchingKeys)) != nil
    }

    private static func copyDismissalKey(_ candidate: CalendarJourneyCandidate) -> String {
        // The revision hashes the full event content and dates, but excludes the Calendar ID.
        "copy:" + candidate.snapshot.importSource.revision
    }
}

/// Heuristics that keep one real trip from appearing twice among suggestions.
enum CalendarSuggestionMatching {
    /// Group numbered services copied into calendars even if their titles differ. An
    /// unnumbered or untimed entry needs identical content to stand in for another.
    static func tripSignature(_ candidate: CalendarJourneyCandidate) -> String {
        let details = candidate.classification
        guard !candidate.snapshot.isAllDay, !details.hasConflictingTrainProducts,
              let number = details.trainNumberGuess,
              let origin = details.originGuess, let destination = details.destinationGuess else {
            return candidate.snapshot.importSource.revision
        }
        let minute = Int(candidate.snapshot.startDate.timeIntervalSince1970 / 60)
        return [origin, destination, number, String(minute)].map(ImportedStationMatcher.key).joined(separator: "|")
    }

    static func duplicatesSavedPlan(_ candidate: CalendarJourneyCandidate, in plans: [TrackedJourneyPlan]) -> Bool {
        guard !plans.isEmpty else { return false }
        let snapshot = candidate.snapshot
        let revisions = [snapshot.importSource.revision, snapshot.legacyImportSource.revision]
        if plans.contains(where: { plan in
            plan.calendarSource.map { revisions.contains($0.revision) } == true
        }) { return true }
        let details = candidate.classification
        guard !snapshot.isAllDay, !details.hasConflictingTrainProducts,
              let number = details.trainNumberGuess,
              let origin = details.originGuess, let destination = details.destinationGuess else { return false }
        let zone = snapshot.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        let clock = TicketWallClock(date: snapshot.startDate, timeZone: zone ?? snapshot.readTimeZone, includesTime: true)
        return ImportedSavedJourneyMatcher.match(
            origin: origin, destination: destination, trainNumber: number,
            departure: clock, departureInstant: zone == nil ? nil : snapshot.startDate, knownTimeZone: zone,
            plans: plans, originPlace: nil, destinationPlace: nil
        ) != nil
    }
}
