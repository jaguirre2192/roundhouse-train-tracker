import Foundation
import TrainTrackerCore

extension JourneyPlanLibrary {
    func plan(importedFrom eventKey: String) -> TrackedJourneyPlan? {
        plans.first { $0.calendarSource?.eventKey == eventKey }
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
