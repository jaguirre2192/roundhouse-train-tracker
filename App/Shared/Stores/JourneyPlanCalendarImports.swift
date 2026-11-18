import Foundation
import TrainTrackerCore

extension JourneyPlanLibrary {
    func plan(importedFrom eventKey: String) -> TrackedJourneyPlan? {
        plans.first { $0.calendarSource?.eventKey == eventKey }
    }

    /// Resolve old identity formats without replacing the journey or its reviewed revision.
    func plansWithMigratedCalendarKeys(for candidates: [CalendarJourneyCandidate]) -> [TrackedJourneyPlan]? {
        let sources = plans.compactMap(\.calendarSource)
        guard !sources.isEmpty else { return nil }
        let byKey = Dictionary(grouping: sources, by: \.eventKey)
        let byRevision = Dictionary(grouping: sources, by: \.revision)
        var remap: [String: String] = [:]
        for candidate in candidates {
            let source = candidate.snapshot.importSource
            guard byKey[source.eventKey] == nil else { continue }
            let legacy = candidate.snapshot.legacyImportSource.eventKey
            // A matching revision can locate the previous zone's identity, even for a
            // daily series on the other side of the date line. Prefer that exact match.
            if let peers = byRevision[source.revision],
               let old = candidate.snapshot.priorFloatingKey(among: Set(peers.map(\.eventKey))) {
                remap[old] = source.eventKey
            } else if let savedSources = byKey[legacy], remap[legacy] == nil,
                      savedSources.allSatisfy({ candidate.snapshot.acceptsLegacyRevision($0.revision) }) {
                remap[legacy] = source.eventKey
            }
        }
        guard !remap.isEmpty else { return nil }
        return plans.map { plan -> TrackedJourneyPlan in
            guard let source = plan.calendarSource, let stable = remap[source.eventKey] else { return plan }
            return TrackedJourneyPlan(
                id: plan.id, createdAt: plan.createdAt, origin: plan.origin, destination: plan.destination,
                outbound: plan.outbound, returnDirection: plan.returnDirection,
                preExistingChildTripIDs: plan.preExistingChildTripIDs,
                calendarSource: CalendarJourneySource(eventKey: stable, revision: source.revision, details: source.details)
            )
        }
    }

    /// Re-importing an edited event updates its existing plan, even if a new search draft
    /// was created. The source revision is committed atomically with the selected journey.
    func canonicalCalendarDraft(
        _ draft: JourneyPlanDraft,
        pendingAttempts: [JourneyPlanTrackingAttempt]
    ) -> JourneyPlanDraft {
        guard let source = draft.calendarSource else { return draft }
        let savedID = plan(importedFrom: source.eventKey)?.id
        let pendingID = pendingAttempts
            .filter { $0.calendarEventKey == source.eventKey }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .first?.id
        guard let id = savedID ?? pendingID else { return draft }
        return JourneyPlanDraft(
            id: id, origin: draft.origin, destination: draft.destination,
            outbound: draft.outbound, returnOption: draft.returnOption,
            calendarSource: source
        )
    }

    /// An unsuccessful save may already have inserted children. If the person chooses
    /// another itinerary on retry, remove those abandoned children only after saving the
    /// replacement plan, with the same ownership protections as normal plan removal.
    func calendarReplacementTripIDs(
        for draft: JourneyPlanDraft,
        selectedTripIDs: Set<RailIdentifier>,
        pendingAttempt: JourneyPlanTrackingAttempt?
    ) -> Set<RailIdentifier> {
        guard draft.calendarSource != nil else { return [] }
        let shared = Set(plans.filter { $0.id != draft.id }.flatMap {
            $0.outbound.childTripIDs + ($0.returnDirection?.childTripIDs ?? [])
        })
        let pendingOwned = (pendingAttempt?.insertedChildTripIDs ?? [])
            .subtracting(pendingAttempt?.preExistingChildTripIDs ?? [])
        let priorPlanOwned = Set(removalPreview(for: draft.id).removableChildTripIDs)
        return priorPlanOwned.union(pendingOwned)
            .subtracting(selectedTripIDs)
            .subtracting(shared)
    }
}
