import Foundation
import Observation
import TrainTrackerCore

struct JourneyPlanRemovalPreview: Equatable {
    let removableChildTripIDs: [RailIdentifier]
    let preservedChildTripIDs: [RailIdentifier]
    let sharedChildTripIDs: [RailIdentifier]
    let preExistingChildTripIDs: [RailIdentifier]
}

struct JourneyPlanStorageRecoveryIssue: Identifiable, Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case corruptData
        case storageUnavailable
        case unsupportedVersion(Int)
    }

    let component: JourneyPlanStorageComponent
    let failure: Failure

    var id: JourneyPlanStorageComponent { component }

    fileprivate init(
        component: JourneyPlanStorageComponent,
        archiveError: JourneyPlanArchive.ArchiveError
    ) {
        self.component = component
        failure = switch archiveError {
        case .corruptData: .corruptData
        case .storageUnavailable: .storageUnavailable
        case let .unsupportedVersion(version): .unsupportedVersion(version)
        }
    }
}

@MainActor
@Observable
final class JourneyPlanLibrary {
    enum LibraryError: LocalizedError, Equatable {
        case missingOutboundResolution
        case missingReturnResolution
        case recoveryRequired(JourneyPlanStorageComponent)

        var errorDescription: String? {
            switch self {
            case .missingOutboundResolution:
                "The outbound journey is no longer available. Search again to choose another option."
            case .missingReturnResolution:
                "The return journey is no longer available. Search again to choose another option."
            case let .recoveryRequired(component):
                "Journey Plan editing is paused while \(component.title) needs recovery. Open Settings to retry, export, or reset that data."
            }
        }
    }

    private(set) var plans: [TrackedJourneyPlan]
    private(set) var recoveryIssues: [JourneyPlanStorageRecoveryIssue]

    private let tripLibrary: TripLibrary
    private let archive: any JourneyPlanArchiving
    private let now: () -> Date
    private var trackingAttempts: [UUID: JourneyPlanTrackingAttempt]

    init(
        tripLibrary: TripLibrary,
        archive: any JourneyPlanArchiving = JourneyPlanArchive.standard,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.tripLibrary = tripLibrary
        self.archive = archive
        self.now = now
        var loadedPlans: [TrackedJourneyPlan] = []
        var loadedAttempts: [JourneyPlanTrackingAttempt] = []
        var issues: [JourneyPlanStorageRecoveryIssue] = []
        do {
            loadedPlans = try archive.load()
        } catch let error as JourneyPlanArchive.ArchiveError {
            issues.append(JourneyPlanStorageRecoveryIssue(component: .plans, archiveError: error))
        }
        do {
            loadedAttempts = try archive.loadTrackingAttempts()
        } catch let error as JourneyPlanArchive.ArchiveError {
            issues.append(
                JourneyPlanStorageRecoveryIssue(component: .transactionJournal, archiveError: error)
            )
        }

        plans = loadedPlans
        recoveryIssues = issues
        trackingAttempts = [:]
        for attempt in loadedAttempts {
            trackingAttempts[attempt.id] = attempt
        }
        reconcileReadableStorage()
    }

    func preservedRecoveryPayload(for component: JourneyPlanStorageComponent) throws -> Data {
        guard recoveryIssues.contains(where: { $0.component == component }) else {
            throw JourneyPlanRecoveryAccessError.noStoredPayload
        }
        return try archive.preservedRecoveryPayload(for: component)
    }

    func retryRecovery() throws {
        guard !recoveryIssues.isEmpty else { reconcileReadableStorage(); return }

        var loadedPlans = plans
        var loadedAttempts = trackingAttempts
        var unresolved: [JourneyPlanStorageRecoveryIssue] = []
        for issue in recoveryIssues {
            do {
                switch issue.component {
                case .plans:
                    loadedPlans = try archive.load()
                case .transactionJournal:
                    loadedAttempts = Self.attemptsByID(try archive.loadTrackingAttempts())
                }
            } catch let error as JourneyPlanArchive.ArchiveError {
                unresolved.append(
                    JourneyPlanStorageRecoveryIssue(
                        component: issue.component,
                        archiveError: error
                    )
                )
            }
        }

        plans = loadedPlans
        trackingAttempts = loadedAttempts
        recoveryIssues = unresolved
        reconcileReadableStorage()
    }

    func resetRecovery(for component: JourneyPlanStorageComponent) throws {
        guard recoveryIssues.contains(where: { $0.component == component }) else { return }
        try archive.resetRecoveryStorage(for: component)
        try retryRecovery()
    }

    @discardableResult
    func track(
        draft: JourneyPlanDraft,
        resolution: JourneyPlanResolution
    ) throws -> TrackedJourneyPlan {
        try save(draft: draft, resolution: resolution, watchingOnly: false)
    }

    @discardableResult
    func followAlternative(draft: JourneyPlanDraft, resolution: JourneyPlanResolution) throws -> TrackedJourneyPlan {
        try save(draft: draft, resolution: resolution, watchingOnly: true)
    }

    private func save(draft: JourneyPlanDraft, resolution: JourneyPlanResolution, watchingOnly: Bool) throws -> TrackedJourneyPlan {
        try requireHealthyStorage()
        let draft = canonicalCalendarDraft(draft, pendingAttempts: Array(trackingAttempts.values))
        guard let resolvedOutbound = resolution.directions.first else {
            throw LibraryError.missingOutboundResolution
        }
        if draft.returnOption != nil, resolution.directions.count < 2 {
            throw LibraryError.missingReturnResolution
        }
        try reconcilePendingInsertions()

        let resolvedDirections = draft.returnOption == nil
            ? [resolvedOutbound]
            : Array(resolution.directions.prefix(2))
        let trips = uniqueTrips(in: resolvedDirections)
        let tripIDs = Set(trips.map(\.id))
        let previousPlan = plans.first { $0.id == draft.id }
        let replacedTripIDs = calendarReplacementTripIDs(
            for: draft, selectedTripIDs: tripIDs, pendingAttempt: trackingAttempts[draft.id]
        )
        let carriedPreExisting = (trackingAttempts[draft.id]?.preExistingChildTripIDs ?? [])
            .union(previousPlan?.preExistingChildTripIDs ?? [])
        let preExisting = carriedPreExisting.union(
            tripIDs.filter {
                tripLibrary.containsTrip(id: $0) && !journeyOwnedChildTripIDs.contains($0)
            }
        ).intersection(tripIDs)
        var attempt = JourneyPlanTrackingAttempt(
            id: draft.id,
            insertedChildTripIDs: trackingAttempts[draft.id]?.insertedChildTripIDs ?? [],
            pendingInsertionChildTripID: nil,
            preExistingChildTripIDs: preExisting,
            calendarEventKey: draft.calendarSource?.eventKey,
            rideAfterCommit: watchingOnly ? nil : .init(outboundFingerprint: resolvedOutbound.fingerprint,
                returnFingerprint: resolvedDirections.dropFirst().first?.fingerprint, tripIDs: tripIDs)
        )
        try saveTrackingAttempt(attempt)
        let pushWarningScope = tripLibrary.beginJourneySavePushScope(tripIDs: tripIDs)
        var didPersistPlan = false
        defer {
            if !didPersistPlan {
                tripLibrary.cancelJourneySavePushScope(pushWarningScope)
            }
        }

        for trip in trips {
            guard !tripLibrary.containsTrip(id: trip.id) else { continue }
            attempt.pendingInsertionChildTripID = trip.id
            try saveTrackingAttempt(attempt)
            let inserted: Bool
            do {
                // A staged child can survive a failed save. It becomes a ride only after the booking commits.
                inserted = try tripLibrary.storeTrackedTrip(trip, watchingOnly: true)
            } catch let storageError {
                attempt.pendingInsertionChildTripID = nil
                try saveTrackingAttempt(attempt)
                throw storageError
            }
            if inserted {
                attempt.insertedChildTripIDs.insert(trip.id)
            }
            attempt.pendingInsertionChildTripID = nil
            try saveTrackingAttempt(attempt)
        }
        try tripLibrary.moveTrackedTripsToFront(inOrder: trips.map(\.id))

        let plan = TrackedJourneyPlan(
            id: draft.id,
            createdAt: previousPlan?.createdAt ?? now(),
            origin: draft.origin,
            destination: draft.destination,
            outbound: direction(from: resolvedOutbound, selected: draft.outbound),
            returnDirection: draft.returnOption.map {
                direction(from: resolution.directions[1], selected: $0)
            },
            preExistingChildTripIDs: preExisting,
            calendarSource: draft.calendarSource
        )
        let replacedTrips = try tripLibrary.prepareTrackedTripRemoval(ids: replacedTripIDs)
        var updated = plans.filter { $0.id != draft.id }
        updated.append(plan)
        try commitPlans(updated, removing: replacedTrips)
        if let ride = attempt.rideAfterCommit { try tripLibrary.markAsRiding(ride.tripIDs) }
        try removeTrackingAttempt(id: draft.id)
        tripLibrary.completeJourneySavePushScope(pushWarningScope)
        didPersistPlan = true
        return plan
    }

    /// Adopt older one-off and floating recurrence identities while their Calendar event
    /// can be recognised. Preserve the last reviewed revision so edits still require review.
    func adoptStableCalendarKeys(for candidates: [CalendarJourneyCandidate]) {
        guard let updated = plansWithMigratedCalendarKeys(for: candidates), (try? requireHealthyStorage()) != nil else { return }
        do {
            try archive.save(updated)
            plans = updated
        } catch {
            // Leave the legacy keys in place; the next read tries again.
        }
    }

    func removePlan(id: UUID) throws {
        try requireHealthyStorage()
        guard plans.contains(where: { $0.id == id }) else { return }
        let updated = plans.filter { $0.id != id }
        try archive.save(updated)
        plans = updated
        try removeTrackingAttempt(id: id)
    }

    /// Puts back a journey group removed with `removePlan(id:)` (Undo) at its old position.
    /// Its trains were never stopped, so only the grouping returns.
    func restorePlan(_ plan: TrackedJourneyPlan, at index: Int) throws {
        try requireHealthyStorage()
        guard !plans.contains(where: { $0.id == plan.id }) else { return }
        var updated = plans
        updated.insert(plan, at: min(max(index, 0), updated.count))
        try archive.save(updated)
        plans = updated
    }

    /// Retain the selected endpoints before allowing the train into the rider's log. Retrying
    /// a partially completed save uses the same section and cannot create a second journey.
    func saveRiddenSection(_ plan: TrackedJourneyPlan, for train: RailIdentifier) throws {
        try requireHealthyStorage()
        guard tripLibrary.isWatchingOnly(train), tripLibrary.containsTrip(id: train) else { return }
        if !plans.contains(where: { $0.outbound.fingerprint == plan.outbound.fingerprint }) {
            let updated = plans + [plan]
            try archive.save(updated)
            plans = updated
        }
        try tripLibrary.markAsRiding([train])
    }

    func removalPreview(for planID: UUID) -> JourneyPlanRemovalPreview {
        guard let plan = plans.first(where: { $0.id == planID }) else {
            return JourneyPlanRemovalPreview(
                removableChildTripIDs: [],
                preservedChildTripIDs: [],
                sharedChildTripIDs: [],
                preExistingChildTripIDs: []
            )
        }

        let shared = Set(
            plans.lazy
                .filter { $0.id != planID }
                .flatMap(Self.childTripIDs)
        )
        let preserved = shared.union(plan.preExistingChildTripIDs)
        let childIDs = Self.childTripIDs(plan)
        return JourneyPlanRemovalPreview(
            removableChildTripIDs: childIDs.filter { !preserved.contains($0) },
            preservedChildTripIDs: childIDs.filter(preserved.contains),
            sharedChildTripIDs: childIDs.filter(shared.contains),
            preExistingChildTripIDs: childIDs.filter(plan.preExistingChildTripIDs.contains)
        )
    }

    func removePlanAndStopTrackingChildren(id: UUID) throws {
        try requireHealthyStorage()
        guard plans.contains(where: { $0.id == id }) else { return }
        let preview = removalPreview(for: id)
        let removal = try tripLibrary.prepareTrackedTripRemoval(
            ids: Set(preview.removableChildTripIDs)
        )
        try commitPlans(plans.filter { $0.id != id }, removing: removal)
        try removeTrackingAttempt(id: id)
    }

    /// Child removal is atomic. If it fails, restore the prior grouping; never claim that
    /// tracking stopped when its archive write failed. A failed rollback leaves memory
    /// matching the grouping already on disk and propagates the storage error.
    private func commitPlans(_ updated: [TrackedJourneyPlan], removing removal: TripLibrary.TrackedTripRemoval?) throws {
        let previous = plans
        try archive.save(updated)
        do {
            if let removal { try tripLibrary.commitTrackedTripRemoval(removal) }
        } catch {
            let removalError = error
            do { try archive.save(previous) }
            catch { plans = updated; throw error }
            throw removalError
        }
        plans = updated
    }

    private func uniqueTrips(
        in directions: [JourneyPlanResolution.Direction]
    ) -> [TrainTrip] {
        var seen: Set<RailIdentifier> = []
        return directions
            .flatMap(\.segments)
            .compactMap(\.trip)
            .filter { seen.insert($0.id).inserted }
    }

    private func direction(
        from resolved: JourneyPlanResolution.Direction,
        selected option: JourneyOption
    ) -> JourneyPlanDirection {
        JourneyPlanDirection(
            fingerprint: resolved.fingerprint,
            departure: resolved.departure,
            arrival: resolved.arrival,
            childTripIDs: Self.uniqueIDs(resolved.segments.compactMap { $0.trip?.id }),
            selectedSegments: selectedSegments(from: option, resolved: resolved)
        )
    }

    private func selectedSegments(
        from option: JourneyOption,
        resolved: JourneyPlanResolution.Direction
    ) -> [JourneyPlanSegment]? {
        guard option.fingerprint == resolved.fingerprint else { return nil }
        let resolutions = Dictionary(grouping: resolved.segments, by: \.segmentID)
        return option.segments.map { segment in
            switch segment {
            case let .rail(rail):
                let matches = resolutions[rail.id] ?? []
                let match = matches.count == 1 ? matches.first : nil
                let tripID = match?.failure == nil ? match?.trip?.id : nil
                let serviceName = [rail.trainName ?? rail.product, rail.trainNumber]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return JourneyPlanSegment(
                    id: rail.id,
                    kind: .rail,
                    from: rail.from.place,
                    to: rail.to.place,
                    departure: rail.from.scheduledDeparture,
                    arrival: rail.to.scheduledArrival,
                    serviceName: serviceName.isEmpty ? nil : serviceName,
                    resolvedTripID: tripID,
                    unavailableReason: tripID == nil
                        ? (match?.failure?.message ?? rail.untrackableReason)
                        : nil
                )
            case let .walk(walk):
                return JourneyPlanSegment(
                    id: walk.id,
                    kind: .walk,
                    from: walk.from,
                    to: walk.to,
                    duration: walk.duration,
                    isStationChange: walk.isStationChange
                )
            }
        }
    }

    private var journeyOwnedChildTripIDs: Set<RailIdentifier> {
        let planOwned = plans.reduce(into: Set<RailIdentifier>()) { result, plan in
            result.formUnion(Set(Self.childTripIDs(plan)).subtracting(plan.preExistingChildTripIDs))
        }
        return trackingAttempts.values.reduce(into: planOwned) { result, attempt in
            result.formUnion(
                attempt.insertedChildTripIDs.subtracting(attempt.preExistingChildTripIDs)
            )
        }
    }

    private func reconcileReadableStorage() {
        guard recoveryIssues.isEmpty, !tripLibrary.tripArchiveRecoveryRequired else { return }
        do { try reconcilePendingInsertions() }
        catch {
            recoveryIssues = [JourneyPlanStorageRecoveryIssue(
                component: .transactionJournal,
                archiveError: (error as? JourneyPlanArchive.ArchiveError) ?? .storageUnavailable
            )]
        }
    }

    private func reconcilePendingInsertions() throws {
        guard !tripLibrary.tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        var updated = trackingAttempts
        var changed = false
        for (id, storedAttempt) in trackingAttempts {
            if let ride = storedAttempt.rideAfterCommit, let saved = plans.first(where: { $0.id == id }),
               ride.matches(saved) {
                try tripLibrary.markAsRiding(ride.tripIDs)
                updated[id] = nil
                changed = true
                continue
            }
            guard let pendingID = storedAttempt.pendingInsertionChildTripID else { continue }
            var attempt = storedAttempt
            if tripLibrary.containsTrip(id: pendingID),
               !attempt.preExistingChildTripIDs.contains(pendingID) {
                attempt.insertedChildTripIDs.insert(pendingID)
            }
            attempt.pendingInsertionChildTripID = nil
            updated[id] = attempt
            changed = true
        }
        guard changed else { return }
        try archive.saveTrackingAttempts(Self.sortedAttempts(Array(updated.values)))
        trackingAttempts = updated
    }

    private func saveTrackingAttempt(_ attempt: JourneyPlanTrackingAttempt) throws {
        var updated = trackingAttempts
        updated[attempt.id] = attempt
        try archive.saveTrackingAttempts(Self.sortedAttempts(Array(updated.values)))
        trackingAttempts = updated
    }

    private func removeTrackingAttempt(id: UUID) throws {
        guard trackingAttempts[id] != nil else { return }
        var updated = trackingAttempts
        updated[id] = nil
        try archive.saveTrackingAttempts(Self.sortedAttempts(Array(updated.values)))
        trackingAttempts = updated
    }

    private func requireHealthyStorage() throws {
        guard !tripLibrary.tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        if let component = recoveryIssues.first?.component {
            throw LibraryError.recoveryRequired(component)
        }
    }

    private static func sortedAttempts(
        _ attempts: [JourneyPlanTrackingAttempt]
    ) -> [JourneyPlanTrackingAttempt] {
        attempts.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func attemptsByID(
        _ attempts: [JourneyPlanTrackingAttempt]
    ) -> [UUID: JourneyPlanTrackingAttempt] {
        attempts.reduce(into: [:]) { result, attempt in
            result[attempt.id] = attempt
        }
    }

    private static func childTripIDs(_ plan: TrackedJourneyPlan) -> [RailIdentifier] {
        uniqueIDs(plan.outbound.childTripIDs + (plan.returnDirection?.childTripIDs ?? []))
    }

    private static func uniqueIDs(_ ids: [RailIdentifier]) -> [RailIdentifier] {
        var seen: Set<RailIdentifier> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
