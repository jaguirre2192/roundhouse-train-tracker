import ActivityKit
import Foundation
import Observation
import TrainTrackerCore
import UIKit

@MainActor
@Observable
final class TrainLiveActivityManager: LiveActivityInstallationHandling {
    static let shared = TrainLiveActivityManager()
    private(set) var activeAttributes: TrainJourneyAttributes?
    private(set) var deliveryMessage: String?
    private(set) var isBusy = false
    @ObservationIgnored var installationRejectionHandler: (() -> Void)?
    private let backend: any LiveActivityBackendServing
    private let registrations: LiveActivityRegistrationStore
    private let existingActivityIDs: () -> Set<String>
    private let retireActivity: (String) async -> Void
    private var installationID: UUID
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]
    private var registeredTokens: [String: Data] = [:]
    private var pendingTokens: [String: Data] = [:]
    private var uploadingIDs: Set<String> = []
    private var lifecycleEpoch = 0
    private var isRefreshingActivities = false
    private var needsAnotherRefresh = false
    /// Transient end-request failures wait before retrying instead of repeating on every pass.
    private var endRetries: [String: (attempts: Int, notBefore: Date)] = [:]
    private var endRetryTask: Task<Void, Never>?
    private let now: () -> Date
    private weak var library: TripLibrary?
    private weak var plans: JourneyPlanLibrary?

    init(
        backend: any LiveActivityBackendServing = LiveActivityBackendClient(),
        registrations: LiveActivityRegistrationStore = LiveActivityRegistrationStore(),
        existingActivityIDs: @escaping () -> Set<String> = {
            Set(Activity<TrainJourneyAttributes>.activities.map(\.id))
        },
        retireActivity: @escaping (String) async -> Void = { id in
            await TrainLiveActivitySystem.endImmediately(id: id)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend
        self.registrations = registrations
        self.existingActivityIDs = existingActivityIDs
        self.retireActivity = retireActivity
        self.now = now
        installationID = registrations.installationID
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func connect(library: TripLibrary, plans: JourneyPlanLibrary?) {
        self.library = library
        self.plans = plans
        library.liveActivityStateDidChange = { [weak self] in
            Task { await self?.refreshActivities() }
        }
    }

    func resume() async {
        // Retired IDs only need to outlive the activity they name; drop the rest so the list stays small.
        registrations.pruneRetiredActivityIDs(keeping: existingActivityIDs())
        await retireUnownedActivities()
        let activities = activeActivities
        let ids = Set(activities.map(\.id))
        for id in registrations.knownActivityIDs.subtracting(ids) { registrations.markEnded(id) }
        for activity in activities { observe(activity) }
        await refreshActivities()
        await flushEnds()
        for activity in activeActivities {
            if let token = activity.pushToken { await register(token, activity: activity) }
        }
        updateSummary()
    }

    func start(tripID: RailIdentifier, segment: JourneyPlanSegment? = nil) async throws {
        await retireUnownedActivities()
        guard !isBusy else { throw LiveActivityError.busy }
        guard areActivitiesEnabled else { throw LiveActivityError.disabled }
        guard let library, library.containsTrip(id: tripID) else { throw LiveActivityError.missingTrain }
        isBusy = true
        let epoch = lifecycleEpoch
        defer { isBusy = false }
        await library.refreshTrackedTrip(id: tripID)
        guard lifecycleEpoch == epoch else { throw CancellationError() }
        let (selection, _) = try validatedStart(tripID: tripID, segment: segment)
        if activeActivities.contains(where: {
            $0.attributes.tripID == tripID.rawValue
                && $0.attributes.isRiding == !library.isWatchingOnly(tripID)
                && $0.attributes.boardingStationID == selection.boarding.station.id.rawValue
                && $0.attributes.alightingStationID == selection.alighting.station.id.rawValue
        }) {
            await refreshActivities()
            return
        }
        for activity in activeActivities { await finish(activity, immediately: true) }
        // Teardown may wait for the network; recheck removal, timing, and selected stops afterward.
        let (latestSelection, projection) = try validatedStart(tripID: tripID, segment: segment)
        let attributes = latestSelection.attributes(at: .now, isRiding: !library.isWatchingOnly(tripID))
        // Combined static and dynamic data must fit ActivityKit's four-kilobyte budget.
        let encoder = JSONEncoder()
        guard try encoder.encode(attributes).count + encoder.encode(projection.state).count < 3_800 else {
            throw LiveActivityError.unavailable
        }
        guard lifecycleEpoch == epoch else { throw CancellationError() }
        let activity = try Activity.request(
            attributes: attributes, content: content(projection.state), pushType: .token
        )
        deliveryMessage = "Connecting background updates…"
        observe(activity)
        updateSummary()
        if let token = activity.pushToken { await register(token, activity: activity) }
    }

    func stop() async {
        await retireUnownedActivities()
        lifecycleEpoch += 1
        for activity in activeActivities { await finish(activity, immediately: true) }
        await flushEnds()
        updateSummary()
    }

    func refreshActivities() async {
        await retireUnownedActivities()
        if isRefreshingActivities {
            needsAnotherRefresh = true
            return
        }
        isRefreshingActivities = true
        defer { isRefreshingActivities = false }
        repeat {
            needsAnotherRefresh = false
            await refreshActivityPass()
        } while needsAnotherRefresh
    }

    private func refreshActivityPass() async {
        guard let library else { return }
        for activity in activeActivities {
            let attributes = activity.attributes
            let id = RailIdentifier(rawValue: attributes.tripID)
            guard let trip = library.trip(id: id), Date.now.timeIntervalSince1970 < attributes.startedAt + 28_800 else {
                await finish(activity, immediately: true)
                continue
            }
            let context = TripDetailTimeZoneContext(trip: trip, plans: plans?.plans ?? [])
            var zones: [RailIdentifier: String] = [:]
            for stop in trip.stopTimes {
                if let zone = context.timeZoneIdentifier(for: stop) { zones[stop.station.id] = zone }
            }
            let projection = TrainLiveActivityProjection(
                trip: trip, referenceDate: .now,
                boardingStationID: RailIdentifier(rawValue: attributes.boardingStationID),
                alightingStationID: RailIdentifier(rawValue: attributes.alightingStationID),
                stationTimeZones: zones, lastSuccessfulCheck: library.lastSuccessfulCheck(for: id),
                refreshFailed: library.lastRefreshFailed(for: id)
            )
            // A fresh server push must not be overwritten by older on-device data after launch.
            guard (projection.state.checkedAt ?? 0) >= (activity.content.state.checkedAt ?? 0) else { continue }
            if projection.shouldEnd {
                await TrainLiveActivitySystem.update(id: activity.id, state: projection.state)
                if library.trip(id: id) == trip,
                   library.lastSuccessfulCheck(for: id)?.timeIntervalSince1970 == projection.state.checkedAt,
                   (projection.state.phase != .ended || !library.lastRefreshFailed(for: id)),
                   (activity.content.state.checkedAt ?? 0) <= (projection.state.checkedAt ?? 0) {
                    await finish(activity, immediately: false)
                }
            } else if projection.state != activity.content.state {
                await TrainLiveActivitySystem.update(id: activity.id, state: projection.state)
            }
        }
        updateSummary()
    }

    private func validatedStart(
        tripID: RailIdentifier, segment: JourneyPlanSegment?
    ) throws -> (TrainLiveActivitySelection, TrainLiveActivityProjection) {
        guard let library, let trip = library.trip(id: tripID) else { throw LiveActivityError.missingTrain }
        guard let selection = TrainLiveActivitySelection(trip: trip, segment: segment, plans: plans?.plans ?? []) else {
            throw LiveActivityError.unavailable
        }
        let projection = selection.projection(at: .now, checkedAt: library.lastSuccessfulCheck(for: tripID),
            refreshFailed: library.lastRefreshFailed(for: tripID))
        switch projection.eligibility {
        case .available: return (selection, projection)
        case let .tooEarly(date): throw LiveActivityError.tooEarly(date)
        case .ended: throw LiveActivityError.ended
        case .cancelled: throw LiveActivityError.cancelled
        case .unavailable: throw LiveActivityError.unavailable
        }
    }

    private var activeActivities: [Activity<TrainJourneyAttributes>] {
        let retired = registrations.retiredActivityIDs
        return Activity<TrainJourneyAttributes>.activities.filter {
            !retired.contains($0.id) && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    func installationDidChange() {
        let currentID = registrations.installationID
        guard currentID != installationID else { return }
        installationID = currentID
        lifecycleEpoch += 1
        registrations.retireActivityIDs(existingActivityIDs().union(tokenTasks.keys).union(stateTasks.keys))
        for task in tokenTasks.values { task.cancel() }
        for task in stateTasks.values { task.cancel() }
        tokenTasks.removeAll()
        stateTasks.removeAll()
        registeredTokens.removeAll()
        pendingTokens.removeAll()
        uploadingIDs.removeAll()
        activeAttributes = nil
        deliveryMessage = nil
    }

    /// The push coordinator replaced a rejected installation. Running activities stay on screen
    /// and register their current tokens under the new identity instead of being ended.
    func installationWasReplaced() {
        // Adopt before reading the store, whose installation check would otherwise retire them.
        registrations.adoptReplacementInstallation(keepingActivityIDs: existingActivityIDs())
        installationID = registrations.installationID
        registeredTokens.removeAll()
        endRetries.removeAll()
        Task { [weak self] in await self?.registerActiveActivities() }
    }

    private func registerActiveActivities() async {
        for activity in activeActivities {
            observe(activity)
            if let token = activity.pushToken { await register(token, activity: activity) }
        }
        updateSummary()
    }

    private func retireUnownedActivities() async {
        installationDidChange()
        for id in existingActivityIDs().intersection(registrations.retiredActivityIDs) {
            // The previous installation still owns its server record. End only the local activity.
            await retireActivity(id)
        }
    }

    private func observe(_ activity: Activity<TrainJourneyAttributes>) {
        guard !registrations.retiredActivityIDs.contains(activity.id) else { return }
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.register(token, activity: activity)
            }
        }
        stateTasks[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self else { return }
                if state == .ended || state == .dismissed {
                    self.registrations.markEnded(activity.id)
                    self.tokenTasks.removeValue(forKey: activity.id)?.cancel()
                    self.registeredTokens[activity.id] = nil
                    self.pendingTokens[activity.id] = nil
                    await self.flushEnds()
                    self.stateTasks[activity.id] = nil
                    self.updateSummary()
                    return
                }
                self.updateSummary()
            }
        }
    }

    private func register(_ token: Data, activity: Activity<TrainJourneyAttributes>) async {
        await retireUnownedActivities()
        guard !registrations.retiredActivityIDs.contains(activity.id) else { return }
        guard registeredTokens[activity.id] != token else { return }
        pendingTokens[activity.id] = token
        guard uploadingIDs.insert(activity.id).inserted else { return }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Register train Live Activity")
        defer {
            uploadingIDs.remove(activity.id)
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        while let nextToken = pendingTokens.removeValue(forKey: activity.id) {
            guard activity.activityState == .active || activity.activityState == .stale,
                  let trip = library?.trip(id: RailIdentifier(rawValue: activity.attributes.tripID)),
                  let generation = registrations.generation(for: activity.id, token: nextToken)
            else { return }
            let context = TripDetailTimeZoneContext(trip: trip, plans: plans?.plans ?? [])
            var zones: [RailIdentifier: String] = [:]
            for stop in trip.stopTimes {
                if let zone = context.timeZoneIdentifier(for: stop) { zones[stop.station.id] = zone }
            }
            let environment = LiveActivityBackendClient.pushEnvironment
            let registration = LiveActivityRegistration(
                installationID: registrations.installationID, activityID: activity.id,
                token: nextToken, environment: environment, attributes: activity.attributes,
                trip: trip, state: activity.content.state, stationTimeZones: zones,
                tokenGeneration: generation
            )
            if await upload(registration) {
                registeredTokens[activity.id] = nextToken
            }
        }
    }

    func upload(_ registration: LiveActivityRegistration) async -> Bool {
        installationDidChange()
        let currentID = registrations.installationID
        let epoch = lifecycleEpoch
        guard registration.installationId == currentID.uuidString.lowercased(),
              !registrations.retiredActivityIDs.contains(registration.activityId) else { return false }
        do {
            try await backend.register(registration)
            guard registrations.installationID == currentID, lifecycleEpoch == epoch,
                  !registrations.retiredActivityIDs.contains(registration.activityId) else { return false }
            deliveryMessage = nil
            return true
        } catch {
            guard registrations.installationID == currentID, lifecycleEpoch == epoch,
                  !registrations.retiredActivityIDs.contains(registration.activityId) else { return false }
            deliveryMessage = "Background updates haven’t connected. Reopen Roundhouse to retry."
            if case LiveActivityBackendClient.ClientError.unauthorized = error {
                // A restored phone keeps its installation ID but not the device-only credential.
                // The coordinator replaces the installation once; this activity then re-registers.
                installationRejectionHandler?()
            }
            return false
        }
    }

    private func finish(_ activity: Activity<TrainJourneyAttributes>, immediately: Bool) async {
        registrations.markEnded(activity.id)
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        stateTasks.removeValue(forKey: activity.id)?.cancel()
        registeredTokens[activity.id] = nil
        pendingTokens[activity.id] = nil
        await TrainLiveActivitySystem.end(id: activity.id, state: activity.content.state, immediately: immediately)
        await flushEnds()
    }

    private func flushEnds() async {
        let currentID = registrations.installationID
        for id in registrations.pendingEnds {
            guard registrations.installationID == currentID else { return }
            guard !registrations.retiredActivityIDs.contains(id) else { continue }
            if let retry = endRetries[id], retry.notBefore > now() { continue }
            do {
                try await backend.end(activityID: id, installationID: currentID)
                guard registrations.installationID == currentID else { return }
                endRetries[id] = nil
                registrations.acknowledgeEnd(id)
            } catch {
                guard registrations.installationID == currentID else { return }
                if Self.isPermanentEndFailure(error) {
                    // Unknown, foreign, or already-stopped activities can never be ended by retrying.
                    endRetries[id] = nil
                    registrations.acknowledgeEnd(id)
                    continue
                }
                // Retain the end request across launches. The server also enforces an eight-hour cap.
                let attempts = (endRetries[id]?.attempts ?? 0) + 1
                let delay = min(30 * pow(2, Double(attempts - 1)), 900)
                endRetries[id] = (attempts, now().addingTimeInterval(delay))
                scheduleEndRetry(after: delay)
            }
        }
    }

    private static func isPermanentEndFailure(_ error: any Error) -> Bool {
        switch error as? LiveActivityBackendClient.ClientError {
        case .unauthorized: true
        case let .rejected(status): [401, 404, 409].contains(status)
        case .unavailable, nil: false
        }
    }

    private func scheduleEndRetry(after delay: TimeInterval) {
        guard endRetryTask == nil else { return }
        endRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.endRetryTask = nil
            await self.flushEnds()
        }
    }

    private func content(_ state: TrainLiveActivityState) -> ActivityContent<TrainLiveActivityState> {
        ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.validUntil), relevanceScore: 75)
    }

    private func updateSummary() {
        activeAttributes = activeActivities.first?.attributes
        if activeAttributes == nil { deliveryMessage = nil }
    }
}

enum LiveActivityError: LocalizedError {
    case busy, disabled, missingTrain, unavailable, tooEarly(Date), ended, cancelled

    var errorDescription: String? {
        switch self {
        case .busy: "A Live Activity is already being started. Try again in a moment."
        case .disabled: "Allow Live Activities for Roundhouse in Settings, then try again."
        case .missingTrain: "This train is no longer saved. Open Roundhouse to choose another train."
        case .unavailable: "This train needs a clear boarding station, destination, and timetable before a Live Activity can start."
        case let .tooEarly(date): "You can start this Live Activity from \(date.formatted(date: .abbreviated, time: .shortened)), one hour before departure."
        case .ended: "The saved arrival time has passed. Refresh the train if its timetable has changed."
        case .cancelled: "This train or one of your selected stops is canceled. Open the journey for details."
        }
    }
}
