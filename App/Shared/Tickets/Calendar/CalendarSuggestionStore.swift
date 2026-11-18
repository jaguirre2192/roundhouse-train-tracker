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
    func enable() async {
        guard !Task.isCancelled else { return }
        isEnabled = true
        defaults?.set(true, forKey: preferenceKey + ".enabled")
        lastRefresh = now()
        await importStore.beginImport()
    }

    func disable() {
        isEnabled = false
        defaults?.set(false, forKey: preferenceKey + ".enabled")
        importStore.reset()
    }

    /// Foreground refresh never asks for access, including after permission revocation.
    func refresh() async {
        guard isEnabled, !Task.isCancelled else { return }
        lastRefresh = now()
        await importStore.refresh()
    }

    /// Returning to My Trips reuses recent results instead of reading Calendar again.
    func refreshIfStale(minimumInterval: TimeInterval = 300) async {
        guard isEnabled else { return }
        if let lastRefresh, now().timeIntervalSince(lastRefresh) < minimumInterval, importStore.state != .idle { return }
        await refresh()
    }

    /// "Not Now" hides the invitation. Suggestions stay off and Calendar is not read.
    func dismissIntroduction() {
        isIntroductionDismissed = true
        defaults?.set(true, forKey: preferenceKey + ".introductionDismissed")
    }

    /// Stop reads on background/disappearance without changing the person's preference.
    func suspend() { importStore.reset() }

    func dismiss(_ candidate: CalendarJourneyCandidate) {
        dismissedRevisions.insert(Self.dismissalKey(candidate))
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
            guard let revision = savedRevisions[candidate.id]
                ?? savedRevisions[candidate.snapshot.legacyImportSource.eventKey] else { return false }
            return candidate.snapshot.isCancelled || !candidate.snapshot.matchesRevision(revision)
        }
    }

    private func candidates(savedEventKeys savedKeys: Set<String>, savedPlans: [TrackedJourneyPlan]) -> [CalendarJourneyCandidate] {
        guard isEnabled, case let .loaded(candidates) = importStore.state else { return [] }
        var seenKeys: Set<String> = []
        var seenTrips: Set<String> = []
        return candidates
            .sorted { $0.snapshot.startDate < $1.snapshot.startDate }
            .filter { candidate in
                guard !candidate.snapshot.isCancelled,
                      !savedKeys.contains(candidate.id),
                      !savedKeys.contains(candidate.snapshot.legacyImportSource.eventKey),
                      !isDismissed(candidate),
                      !CalendarSuggestionMatching.duplicatesSavedPlan(candidate, in: savedPlans),
                      seenKeys.insert(candidate.id).inserted else { return false }
                return seenTrips.insert(CalendarSuggestionMatching.tripSignature(candidate)).inserted
            }
    }

    private func isDismissed(_ candidate: CalendarJourneyCandidate) -> Bool {
        dismissedRevisions.contains(Self.dismissalKey(candidate))
            || dismissedRevisions.contains(Self.legacyDismissalKey(candidate))
    }

    private static func dismissalKey(_ candidate: CalendarJourneyCandidate) -> String {
        let source = candidate.snapshot.importSource
        return source.eventKey + ":" + source.revision
    }

    private static func legacyDismissalKey(_ candidate: CalendarJourneyCandidate) -> String {
        let source = candidate.snapshot.legacyImportSource
        return source.eventKey + ":" + source.revision
    }
}

/// Heuristics that keep one real trip from appearing twice among suggestions.
enum CalendarSuggestionMatching {
    /// Journeys saved by hand are matched by route and time, since they carry no event link.
    static let savedPlanTimeTolerance: TimeInterval = 45 * 60

    /// The same trip copied into two calendars: same route (or title) leaving in the same minute.
    static func tripSignature(_ candidate: CalendarJourneyCandidate) -> String {
        let minute = Int(candidate.snapshot.startDate.timeIntervalSince1970 / 60)
        let route: String
        if let origin = candidate.classification.originGuess, let destination = candidate.classification.destinationGuess {
            route = normalized(origin) + ">" + normalized(destination)
        } else {
            route = normalized(candidate.snapshot.title)
        }
        return "\(route)|\(candidate.classification.trainNumberGuess ?? "")|\(minute)"
    }

    /// True when a saved journey already covers this event: same origin and destination, with
    /// the event starting within 45 minutes of the journey's departure.
    static func duplicatesSavedPlan(_ candidate: CalendarJourneyCandidate, in plans: [TrackedJourneyPlan]) -> Bool {
        guard let origin = candidate.classification.originGuess,
              let destination = candidate.classification.destinationGuess else { return false }
        let start = candidate.snapshot.startDate
        return plans.contains { plan in
            abs(plan.outbound.departure.timeIntervalSince(start)) <= savedPlanTimeTolerance
                && sameStation(origin, plan.origin.displayName)
                && sameStation(destination, plan.destination.displayName)
        }
    }

    static func sameStation(_ guess: String, _ name: String) -> Bool {
        let lhs = normalized(guess)
        let rhs = normalized(name)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    /// Lowercased letters and digits only, without diacritics or generic station words.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["station", "stn", "the"].contains($0) }
        return words.joined()
    }
}
