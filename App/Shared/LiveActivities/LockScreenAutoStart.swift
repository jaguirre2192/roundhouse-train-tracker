import Foundation
import TrainTrackerCore

/// Puts the rider's train on the Lock Screen by itself. iOS only lets an app start a Live
/// Activity while it is in front, so this runs whenever Train Tracker is opened or comes back to
/// the front: if a tracked train is underway or leaves within the hour, its Live Activity starts,
/// and is there when the rider goes back to the Home Screen.
///
/// It starts each train once. Ending the activity by hand is respected: it does not come back
/// for that train. A setting turns the whole thing off.
@MainActor
enum LockScreenAutoStart {
    static let startedKey = "liveActivity.autoStartedTripIDs"

    /// The train to put on the Lock Screen now, with the leg the rider is on, if there is one:
    /// the train underway, otherwise the next to leave, once it is inside the window a Live
    /// Activity can start in. Nil when that train has already been started automatically.
    static func candidate(
        trips: [TrainTrip],
        plans: [TrackedJourneyPlan],
        at date: Date,
        alreadyStarted: Set<String>,
        lastSuccessfulCheck: (RailIdentifier) -> Date?,
        lastRefreshFailed: (RailIdentifier) -> Bool
    ) -> (trip: TrainTrip, segment: JourneyPlanSegment?)? {
        guard let trip = TripAutomaticRefreshPolicy.preferredActiveTrip(in: trips, at: date),
              !alreadyStarted.contains(trip.id.rawValue) else { return nil }
        let segment = JourneyTripContext.selectedSegment(for: trip.id, plans: plans)
        guard let selection = TrainLiveActivitySelection(trip: trip, segment: segment, plans: plans),
              selection.projection(
                  at: date, checkedAt: lastSuccessfulCheck(trip.id), refreshFailed: lastRefreshFailed(trip.id)
              ).eligibility == .available
        else { return nil }
        return (trip, segment)
    }

    /// Starts the due train's Live Activity, if the rider allows it and none is running.
    static func startIfDue(
        library: TripLibrary,
        plans: JourneyPlanLibrary,
        manager: TrainLiveActivityManager = .shared,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) {
        guard !LaunchFixtures.isActive,
              defaults.object(forKey: TrainTrackerPreference.autoLockScreen) as? Bool ?? true,
              manager.areActivitiesEnabled, manager.activeAttributes == nil, !manager.isBusy else { return }
        var started = defaults.stringArray(forKey: startedKey) ?? []
        guard let due = candidate(
            trips: library.trips, plans: plans.plans, at: now, alreadyStarted: Set(started),
            lastSuccessfulCheck: { library.lastSuccessfulCheck(for: $0) },
            lastRefreshFailed: { library.lastRefreshFailed(for: $0) }
        ) else { return }
        // Recorded before starting, so a failed start is not retried every minute.
        started.append(due.trip.id.rawValue)
        defaults.set(Array(started.suffix(100)), forKey: startedKey)
        manager.connect(library: library, plans: plans)
        Task { try? await manager.start(tripID: due.trip.id, segment: due.segment) }
    }
}
