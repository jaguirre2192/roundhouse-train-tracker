import Foundation
import TrainTrackerCore

enum JourneyTripContext {
    /// A train may occur in several saved journeys. Only an explicit selection or
    /// a unique saved binding can describe this passenger's boarding section.
    static func selectedSegment(
        for tripID: RailIdentifier,
        plans: [TrackedJourneyPlan]
    ) -> JourneyPlanSegment? {
        let directions = plans.flatMap { plan in
            [plan.outbound] + (plan.returnDirection.map { [$0] } ?? [])
        }.filter { $0.childTripIDs.contains(tripID) }
        guard directions.count == 1 else { return nil }
        return directions[0].selectedSegment(for: tripID)
    }
}
