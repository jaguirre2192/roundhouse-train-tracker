import Foundation
import Observation

@MainActor
@Observable
final class JourneyPlanRemovalController {
    enum State: Equatable {
        case idle
        case failed
    }

    private(set) var state: State = .idle
    private(set) var failureMessage: String?
    /// The group the last successful `removeGrouping()` removed, so the screen can offer Undo.
    private(set) var removedGroup: JourneyIntakeModel.RemovedPlan?

    let planID: UUID
    private let library: JourneyPlanLibrary

    init(planID: UUID, library: JourneyPlanLibrary) {
        self.planID = planID
        self.library = library
    }

    var preview: JourneyPlanRemovalPreview {
        library.removalPreview(for: planID)
    }

    @discardableResult
    func removeGrouping() -> Bool {
        let index = library.plans.firstIndex { $0.id == planID }
        let removed = index.map { JourneyIntakeModel.RemovedPlan(plan: library.plans[$0], index: $0) }
        let succeeded = perform(
            failure: JourneySearchCopy.Plan.removalFailure
        ) {
            try library.removePlan(id: planID)
        }
        if succeeded { removedGroup = removed }
        return succeeded
    }

    @discardableResult
    func stopTrackingChildren() -> Bool {
        perform(
            failure: JourneySearchCopy.Plan.trainRemovalFailure
        ) {
            try library.removePlanAndStopTrackingChildren(id: planID)
        }
    }

    func prepareDestructiveReview() {
        clearFailure()
    }

    private func clearFailure() {
        state = .idle
        failureMessage = nil
    }

    private func perform(failure: String, action: () throws -> Void) -> Bool {
        do {
            try action()
            clearFailure()
            return true
        } catch {
            state = .failed
            failureMessage = failure
            return false
        }
    }
}
