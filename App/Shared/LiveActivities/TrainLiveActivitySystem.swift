import ActivityKit
import Foundation
import TrainTrackerCore

/// Reacquire framework handles inside the asynchronous operation. ActivityKit's
/// handles aren't Sendable in this SDK; only immutable IDs and states cross actors.
enum TrainLiveActivitySystem {
    static var activityIDs: Set<String> { Set(Activity<TrainJourneyAttributes>.activities.map(\.id)) }

    static func endImmediately(id: String) async {
        guard let activity = Activity<TrainJourneyAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(activity.content, dismissalPolicy: .immediate)
    }

    static func update(id: String, state: TrainLiveActivityState) async {
        guard let activity = Activity<TrainJourneyAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content(state))
    }

    static func end(id: String, state: TrainLiveActivityState, immediately: Bool) async {
        guard let activity = Activity<TrainJourneyAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content(state),
            dismissalPolicy: immediately ? .immediate : .after(Date.now.addingTimeInterval(300)))
    }

    private static func content(_ state: TrainLiveActivityState) -> ActivityContent<TrainLiveActivityState> {
        ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.validUntil), relevanceScore: 75)
    }
}
