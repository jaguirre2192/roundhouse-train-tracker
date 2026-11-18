import Foundation
import TrainTrackerCore
import UIKit
import WidgetKit

/// Writes the rider's next trains to the App Group whenever tracked trips or their check
/// times change, then asks WidgetKit to reload. The widgets never read the app's stores.
/// The shared publisher also hands each snapshot to the Apple Watch app.
@MainActor
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher(watch: WatchRelay.shared)

    private weak var library: TripLibrary?
    private weak var plans: JourneyPlanLibrary?
    private let store: WidgetSnapshotStore
    private let reload: @MainActor () -> Void
    private let now: () -> Date
    private let watch: WatchRelay?
    private var pendingWrite: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    init(
        store: WidgetSnapshotStore = .shared,
        reload: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
        },
        now: @escaping () -> Date = Date.init,
        watch: WatchRelay? = nil
    ) {
        self.store = store
        self.reload = reload
        self.now = now
        self.watch = watch
    }

    func connect(library: TripLibrary, plans: JourneyPlanLibrary?) {
        self.library = library
        self.plans = plans
        watch?.connect(library: library)
        library.widgetSnapshotNeedsUpdate = { [weak self] in self?.scheduleWrite() }
        if backgroundObserver == nil {
            // A saved journey's plan can land just after its trip; leaving the app settles both.
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeNow() }
            }
        }
        scheduleWrite()
    }

    /// Coalesces a refresh pass's per-train changes into one write.
    func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let library, !library.tripArchiveRecoveryRequired,
              plans?.recoveryIssues.isEmpty != false else { return }
        let snapshot = Self.snapshot(
            trips: library.trips, plans: plans?.plans ?? [], at: now(),
            lastSuccessfulCheck: { library.lastSuccessfulCheck(for: $0) },
            lastRefreshFailed: { library.lastRefreshFailed(for: $0) }
        )
        if (try? store.save(snapshot)) == true { reload() }
        watch?.send(snapshot)
    }

    /// Each tracked train's selected leg, with real station codes and station time zones.
    static func snapshot(
        trips: [TrainTrip],
        plans: [TrackedJourneyPlan],
        at date: Date,
        lastSuccessfulCheck: (RailIdentifier) -> Date? = { _ in nil },
        lastRefreshFailed: (RailIdentifier) -> Bool = { _ in false }
    ) -> WidgetTripSnapshot {
        let trains = trips.compactMap { trip -> WidgetTripSnapshot.Train? in
            var codes: [RailIdentifier: String] = [:]
            for stop in trip.stopTimes {
                if let code = StationShortCode.code(for: stop.station) { codes[stop.station.id] = code }
            }
            let chosenLeg = JourneyTripContext.selectedSegment(for: trip.id, plans: plans) != nil
            let selection = TrainLiveActivitySelection(trip: trip, segment: nil, plans: plans)
            let zones = selection?.stationTimeZones ?? Self.timeZones(trip: trip, plans: plans)
            return WidgetTripSnapshot.Train(
                trip: trip,
                boardingStationID: chosenLeg ? selection?.boarding.station.id : nil,
                alightingStationID: chosenLeg ? selection?.alighting.station.id : nil,
                stationCodes: codes, stationTimeZones: zones,
                lastSuccessfulCheck: lastSuccessfulCheck(trip.id),
                lastRefreshFailed: lastRefreshFailed(trip.id),
                referenceDate: date
            )
        }
        return WidgetTripSnapshot.make(trains: trains, generatedAt: date)
    }

    private static func timeZones(trip: TrainTrip, plans: [TrackedJourneyPlan]) -> [RailIdentifier: String] {
        let context = TripDetailTimeZoneContext(trip: trip, plans: plans)
        var zones: [RailIdentifier: String] = [:]
        for stop in trip.stopTimes {
            if let zone = context.timeZoneIdentifier(for: stop) { zones[stop.station.id] = zone }
        }
        return zones
    }
}
