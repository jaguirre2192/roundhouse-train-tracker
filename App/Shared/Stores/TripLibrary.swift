import Foundation
import Observation
import TrainTrackerCore

@MainActor
@Observable
final class TripLibrary {
    struct TrackedTripRemoval {
        fileprivate let remainingTrips: [TrainTrip]
        fileprivate let removedTrips: [TrainTrip]
    }

    private(set) var trips: [TrainTrip] {
        didSet { widgetSnapshotNeedsUpdate?() }
    }
    private(set) var watchingOnlyIDs: Set<RailIdentifier>
    private(set) var tripArchiveRecoveryRequired = false
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private(set) var lastUpdated: Date?
    private(set) var shareImportMessage: String?
    private(set) var lastImportedTripID: RailIdentifier?
    private(set) var pushDeliveryWarning = false
    private(set) var pushDeliveryWarningReason: PushDeliveryWarningReason?
    private(set) var journeySavePushDeliveryWarning = false
    /// Trains whose alerts the service refused individually, for example past the watch limit.
    private(set) var pushAlertRejections: [RailIdentifier: PushTripAlertRejection] = [:]
    var liveActivityStateDidChange: (() -> Void)?
    /// Trips or their check times changed; the widget snapshot publisher rewrites its copy.
    var widgetSnapshotNeedsUpdate: (() -> Void)?

    private let backendSnapshots: any TripDataProviding
    private let sharingClient: TripSharingClient
    private let pushCoordinator: any PushCoordinating
    private let archive: TripArchive?
    private let automaticRefreshEnabled: Bool
    private let now: @Sendable () -> Date
    private var didRequestInitialRefresh = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var pushWarningAffectedTripIDs: Set<RailIdentifier> = []
    private var pendingJourneySavePushScopes: [UUID: Set<RailIdentifier>] = [:]
    private var persistedJourneySavePushScopes: [UUID: Set<RailIdentifier>] = [:]
    private var refreshEvidence: [RailIdentifier: TripRefreshEvidence] = [:]
    private var refreshAttemptIDs: [RailIdentifier: UUID] = [:]

    init(
        trips: [TrainTrip]? = nil,
        backendSnapshots: any TripDataProviding = TripSnapshotBackendClient(),
        sharingClient: TripSharingClient = TripSharingClient(),
        pushCoordinator: any PushCoordinating = PushRegistrationCoordinator(),
        archive: TripArchive? = .standard,
        automaticRefreshEnabled: Bool = true,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.archive = archive
        let loadedTrips = trips ?? archive?.load() ?? []
        self.trips = loadedTrips
        self.tripArchiveRecoveryRequired = archive?.recoveryRequired ?? false
        let savedIDs = Set(loadedTrips.map(\.id))
        watchingOnlyIDs = (archive?.loadWatchingIDs() ?? []).intersection(savedIDs)
        self.refreshEvidence = archive?.loadRefreshEvidence(for: savedIDs) ?? [:]
        self.backendSnapshots = backendSnapshots
        self.sharingClient = sharingClient
        self.pushCoordinator = pushCoordinator
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.now = now
        self.pushCoordinator.deliveryWarningHandler = { [weak self] event in
            guard let self else { return }
            self.pushAlertRejections = event.tripAlertRejections
            self.pushDeliveryWarning = event.hasWarning
            self.pushDeliveryWarningReason = event.reason
            if event.hasWarning {
                self.pushWarningAffectedTripIDs = event.affectedTripIDs
                let affectsSavedJourney = self.persistedJourneySavePushScopes.values.contains(where: {
                    !$0.isDisjoint(with: event.affectedTripIDs)
                })
                self.journeySavePushDeliveryWarning = affectsSavedJourney
            } else {
                self.journeySavePushDeliveryWarning = false
                self.pushDeliveryWarningReason = nil
                self.pushWarningAffectedTripIDs.removeAll()
                self.pendingJourneySavePushScopes.removeAll()
                self.persistedJourneySavePushScopes.removeAll()
            }
        }
    }

    var tripArchiveTemporarilyUnavailable: Bool {
        tripArchiveRecoveryRequired && archive?.storageUnavailable == true
    }

    /// A discovery suggestion is never enrolled until Follow. A startup failure can instead
    /// concern the device or an old watch removal, so the notice must identify its real scope.
    var pushDeliveryWarningContext: PushDeliveryWarningContext {
        // An unreadable archive cannot prove a train was removed. Keep that failure neutral
        // while the separate storage-recovery notice continues to explain the saved data.
        guard !tripArchiveRecoveryRequired else { return .deviceSetup }
        let savedIDs = Set(trips.map(\.id))
        if pushWarningAffectedTripIDs.isEmpty {
            return savedIDs.isEmpty ? .deviceSetup : .savedTrains
        }
        return savedIDs.isDisjoint(with: pushWarningAffectedTripIDs) ? .previousTrains : .savedTrains
    }

    func preservedTripArchiveRecoveryPayload() throws -> Data {
        guard let archive else { throw TripArchive.RecoveryError.noPayload }
        return try archive.preservedRecoveryPayload()
    }

    func retryTripArchiveRecovery() throws {
        guard tripArchiveRecoveryRequired else { return }
        guard let archive else { throw TripArchive.RecoveryError.noPayload }
        let recovered = try archive.retryRecovery()
        let ids = Set(recovered.map(\.id))
        watchingOnlyIDs = archive.loadWatchingIDs().intersection(ids)
        refreshEvidence = archive.loadRefreshEvidence(for: ids)
        tripArchiveRecoveryRequired = false
        trips = recovered
    }

    func resetTripArchiveRecovery() throws {
        guard tripArchiveRecoveryRequired else { return }
        guard let archive else { throw TripArchive.RecoveryError.noPayload }
        try archive.resetRecovery()
        watchingOnlyIDs = []
        refreshEvidence = [:]
        tripArchiveRecoveryRequired = false
        trips = []
    }

    func beginJourneySavePushScope(tripIDs: Set<RailIdentifier>) -> UUID {
        let id = UUID()
        pendingJourneySavePushScopes[id] = tripIDs
        return id
    }

    func completeJourneySavePushScope(_ id: UUID) {
        guard let tripIDs = pendingJourneySavePushScopes.removeValue(forKey: id) else { return }
        persistedJourneySavePushScopes[id] = tripIDs
        // The saved journey may select a different boarding leg; alerts follow the rider's stops.
        for tripID in tripIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let trip = trip(id: tripID) { pushCoordinator.watch(trip) }
        }
        if pushDeliveryWarning, !tripIDs.isDisjoint(with: pushWarningAffectedTripIDs) {
            journeySavePushDeliveryWarning = true
        }
    }

    func cancelJourneySavePushScope(_ id: UUID) {
        pendingJourneySavePushScopes.removeValue(forKey: id)
        persistedJourneySavePushScopes.removeValue(forKey: id)
    }

    var activeTrip: TrainTrip? {
        TripAutomaticRefreshPolicy.preferredActiveTrip(in: trips, at: now())
    }

    var upcomingTrips: [TrainTrip] {
        guard let activeTrip else { return trips }
        return trips.filter { $0.id != activeTrip.id }
    }

    var hasRefreshableTrips: Bool {
        let date = now()
        return trips.contains { foregroundCadence(for: $0, at: date) != nil }
    }

    func trip(id: RailIdentifier) -> TrainTrip? {
        trips.first { $0.id == id }
    }

    func containsTrip(id: RailIdentifier) -> Bool {
        trips.contains { $0.id == id }
    }

    func lastSuccessfulCheck(for tripID: RailIdentifier) -> Date? {
        refreshEvidence[tripID]?.lastSuccessfulCheck
    }

    func lastRefreshFailed(for tripID: RailIdentifier) -> Bool {
        refreshEvidence[tripID]?.lastRefreshFailed ?? false
    }

    func changeJournal(for tripID: RailIdentifier) -> TripChangeJournal {
        refreshEvidence[tripID]?.changes ?? TripChangeJournal()
    }

    func keepDeliveredAlerts(_ alerts: [TripDeliveredAlert]) throws {
        guard !tripArchiveRecoveryRequired, !alerts.isEmpty else { return }
        var updates: [RailIdentifier: TripChangeJournal] = [:]
        let checkedAt = now()
        for alert in alerts.sorted(by: { $0.date > $1.date }) {
            guard let trip = trip(id: alert.tripID) else { continue }
            var journal = updates[trip.id] ?? changeJournal(for: trip.id)
            if journal.accept(alert, for: trip, at: checkedAt) { updates[trip.id] = journal }
        }
        guard !updates.isEmpty else { return }
        try archive?.saveChangeJournals(updates)
        for (id, journal) in updates { refreshEvidence[id, default: TripRefreshEvidence()].changes = journal }
    }

    @discardableResult
    func storeTrackedTrip(_ trip: TrainTrip, watchingOnly: Bool = false) throws -> Bool {
        guard !tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        guard !containsTrip(id: trip.id) else { return false }
        let updated = [trip] + trips
        var watching = watchingOnlyIDs
        if watchingOnly { watching.insert(trip.id) }
        try archive?.saveOrThrow(updated, watching: watching)
        watchingOnlyIDs = watching
        trips = updated
        pushCoordinator.watch(trip)
        return true
    }

    func isWatchingOnly(_ id: RailIdentifier) -> Bool { watchingOnlyIDs.contains(id) }

    func markAsWatching(_ id: RailIdentifier) throws {
        guard !tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        guard containsTrip(id: id), !watchingOnlyIDs.contains(id) else { return }
        let watching = watchingOnlyIDs.union([id])
        try archive?.saveOrThrow(trips, watching: watching)
        watchingOnlyIDs = watching
    }

    func markAsRiding(_ ids: Set<RailIdentifier>) throws {
        guard !tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        let watching = watchingOnlyIDs.subtracting(ids)
        guard watching != watchingOnlyIDs else { return }
        try archive?.saveOrThrow(trips, watching: watching)
        watchingOnlyIDs = watching
    }

    func moveTrackedTripsToFront(inOrder tripIDs: [RailIdentifier]) throws {
        var seen: Set<RailIdentifier> = []
        let orderedIDs = tripIDs.filter { seen.insert($0).inserted }
        let orderedSet = Set(orderedIDs)
        let orderedTrips = orderedIDs.compactMap(trip(id:))
        let updated = orderedTrips + trips.filter { !orderedSet.contains($0.id) }
        guard updated.map(\.id) != trips.map(\.id) else { return }
        try archive?.saveOrThrow(updated)
        trips = updated
    }

    func refreshIfNeeded() async {
        guard automaticRefreshEnabled, !didRequestInitialRefresh else { return }
        didRequestInitialRefresh = true
        await refreshTrackedTrips()
    }

    func refreshTrackedTrips() async {
        guard automaticRefreshEnabled else { return }
        if tripArchiveRecoveryRequired {
            do { try retryTripArchiveRecovery() }
            catch { refreshError = error.localizedDescription; return }
        }
        let date = now()
        let activeTrips = trips.filter { foregroundCadence(for: $0, at: date) != nil }
        guard !activeTrips.isEmpty else {
            refreshError = nil
            return
        }
        let due = activeTrips.filter { foregroundCheckIsDue(for: $0, at: date) }
        await refresh(due, automated: true)
    }

    /// Explicit refreshes may check historical trips; polling callers pass false.
    func refreshTrackedTrip(id: RailIdentifier, allowEnded: Bool = true) async {
        guard automaticRefreshEnabled,
              let trackedTrip = trip(id: id)
        else { return }
        guard allowEnded || foregroundCheckIsDue(for: trackedTrip, at: now()) else {
            return
        }
        await refresh([trackedTrip], automated: !allowEnded)
    }

    private func foregroundCadence(for trip: TrainTrip, at date: Date) -> TripForegroundCadence? {
        .forTrip(trip, journal: changeJournal(for: trip.id), at: date)
    }

    private func foregroundCheckIsDue(for trip: TrainTrip, at date: Date) -> Bool {
        let journal = changeJournal(for: trip.id)
        switch TripForegroundCadence.forTrip(trip, journal: journal, at: date) {
        case .regular: return true
        case .occasional: return journal.recoveryForPolling(trip, at: date)?.checkIsDue(at: date, lastSuccess: lastSuccessfulCheck(for: trip.id)) == true
        case nil: return false
        }
    }

    private func reserveForegroundCheck(for trip: TrainTrip, at date: Date) -> Bool {
        switch foregroundCadence(for: trip, at: date) {
        case .regular: return true
        case nil: return false
        case .occasional:
            var evidence = refreshEvidence[trip.id] ?? TripRefreshEvidence()
            guard evidence.changes.reserveSlowCheck(for: trip, at: date, lastSuccess: evidence.lastSuccessfulCheck) else { return false }
            refreshEvidence[trip.id] = evidence
            // Reserve before transport. A failed request, route change, or relaunch must
            // not transform an occasional check into another request every twenty seconds.
            try? archive?.saveChangeJournals([trip.id: evidence.changes])
            return true
        }
    }

    private func refresh(_ activeTrips: [TrainTrip], automated: Bool) async {
        guard !activeTrips.isEmpty else { return }
        // A caller arriving mid-pass (pull to refresh during a poll) waits for that pass
        // instead of returning at once, so its spinner ends with fresh data.
        guard !isRefreshing else {
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters = []
            waiters.forEach { $0.resume() }
        }

        var failures: [Error] = []
        var refreshedCount = 0
        var wasCancelled = false
        for trackedTrip in activeTrips {
            guard !Task.isCancelled else {
                wasCancelled = true
                break
            }
            guard containsTrip(id: trackedTrip.id), !automated || reserveForegroundCheck(for: trackedTrip, at: now()) else { continue }
            let attemptID = UUID()
            refreshAttemptIDs[trackedTrip.id] = attemptID
            do {
                let liveTrip = try await backendSnapshots.enrichedTrip(trackedTrip)
                try Task.checkCancellation()
                guard liveTrip.id == trackedTrip.id, liveTrip.source == trackedTrip.source,
                      liveTrip.serviceDate == trackedTrip.serviceDate else { throw TripSnapshotBackendClient.ClientError.invalidResponse }
                guard refreshAttemptIDs[trackedTrip.id] == attemptID,
                      containsTrip(id: trackedTrip.id)
                else { continue }
                var updated = trips
                guard let index = updated.firstIndex(where: { $0.id == trackedTrip.id }) else { continue }
                updated[index] = liveTrip
                let checkedAt = liveTrip.source == "srbijavoz" ? (liveTrip.sourceFetchedAt ?? now()) : now()
                var evidence = refreshEvidence
                var nextCheck = evidence[trackedTrip.id] ?? TripRefreshEvidence()
                let priorChanges = nextCheck.changes
                nextCheck.changes.observe(previous: trips[index], current: liveTrip,
                                          hadConfirmedCheck: nextCheck.lastSuccessfulCheck != nil, at: now(), since: nextCheck.lastSuccessfulCheck)
                nextCheck.recordSuccess(at: checkedAt)
                evidence[trackedTrip.id] = nextCheck
                try archive?.save(updated, lastChecks: evidence.compactMapValues(\.lastSuccessfulCheck),
                                  journalUpdate: nextCheck.changes == priorChanges ? nil : (trackedTrip.id, nextCheck.changes))
                refreshEvidence = evidence
                trips = updated
                refreshAttemptIDs[trackedTrip.id] = nil
                refreshedCount += 1
            } catch {
                guard refreshAttemptIDs[trackedTrip.id] == attemptID,
                      containsTrip(id: trackedTrip.id)
                else { continue }
                refreshAttemptIDs[trackedTrip.id] = nil
                if Self.isCancellation(error) {
                    wasCancelled = true
                    break
                }
                refreshEvidence[trackedTrip.id, default: TripRefreshEvidence()].recordFailure()
                failures.append(error)
            }
        }
        if !wasCancelled {
            refreshError = failures.first?.localizedDescription
        }
        if refreshedCount > 0 { lastUpdated = now() }
        liveActivityStateDidChange?()
        widgetSnapshotNeedsUpdate?()
    }

    func searchStations(query: String, source: RailSource) async throws -> [Station] {
        try await backendSnapshots.searchStations(query: query, source: source)
    }

    /// Searches backend station scopes in parallel, retaining each result’s rail scope for
    /// legacy station and train references.
    func searchStations(query: String) async throws -> [RailStationMatch] {
        async let unitedStates = stationSearchAttempt(query: query, source: .unitedStates)
        async let international = stationSearchAttempt(query: query, source: .europe)
        let attempts = await [unitedStates, international]
        let successfulMatches = attempts.compactMap { $0 }.flatMap { $0 }

        if successfulMatches.isEmpty, attempts.contains(where: { $0 == nil }) {
            throw RailStationSearchError.unavailable
        }
        return RailStationMatchMerger.merge(successfulMatches, query: query)
    }

    func board(
        stationID: RailIdentifier,
        source: RailSource,
        at date: Date
    ) async throws -> [StopTimeSummary] {
        try await backendSnapshots.board(stationID: stationID, at: date, direction: .departures, source: source)
    }

    func addTrip(_ summary: StopTimeSummary, source: RailSource) async throws {
        let trip = try await backendSnapshots.trip(id: summary.tripID, serviceDate: summary.serviceDate, source: source)
        try followStandalone(trip)
    }

    /// A train to look at without tracking it: nothing is saved and no alerts are registered.
    /// Backend snapshot only, like every other trip lookup.
    func untrackedTrip(_ summary: StopTimeSummary) async throws -> TrainTrip {
        try await backendSnapshots.trip(id: summary.tripID, serviceDate: summary.serviceDate, source: nil)
    }

    /// The latest details for a train that is not tracked, or nil when the check fails.
    func refreshedUntracked(_ trip: TrainTrip) async -> TrainTrip? {
        try? await backendSnapshots.enrichedTrip(trip)
    }

    func shareURL(for trip: TrainTrip) async throws -> URL {
        try await sharingClient.createLink(for: trip)
    }

    func arrivalBoard(for trip: TrainTrip, stop: StopTime, zone: TimeZone?, note: String) async throws -> TripSharingClient.ArrivalLink {
        guard !isWatchingOnly(trip.id) else { throw TripSharingClient.ArrivalError.callChanged }
        return try await sharingClient.createArrivalBoard(for: trip, stop: stop, zone: zone, note: note)
    }

    func importSharedTrip(from url: URL) async {
        guard TripSharingClient.token(from: url) != nil else { return }
        do {
            let shared = try await sharingClient.resolve(url)
            let serviceDate = try Self.dateOnly(shared.trip.serviceDate)
            let trip = try await backendSnapshots.trip(
                id: RailIdentifier(rawValue: shared.trip.id),
                serviceDate: serviceDate, source: nil
            )
            try followStandalone(trip)
            lastImportedTripID = trip.id
            shareImportMessage = "Added \(trip.product) to My Trips."
        } catch {
            shareImportMessage = "This shared train could not be added. The link may have expired."
        }
    }

    func dismissShareImportMessage() {
        shareImportMessage = nil
    }

    /// A public board or a shared link identifies a train. Only the passenger can say they rode it.
    private func followStandalone(_ trip: TrainTrip) throws {
        guard !tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        if !containsTrip(id: trip.id) {
            try storeTrackedTrip(trip, watchingOnly: true)
            return
        }
        let updated = [trip] + trips.filter { $0.id != trip.id }
        try archive?.saveOrThrow(updated)
        trips = updated
        pushCoordinator.watch(trip)
    }

    func resumePushWatches() {
        let date = now()
        for trip in trips where TripAutomaticRefreshPolicy.isWithinRecoveryWindow(trip, at: date) {
            pushCoordinator.watch(trip)
        }
    }

    func retryPushDelivery() {
        resumePushWatches()
        pushCoordinator.retryDelivery()
    }

    @discardableResult
    func removeTrip(id: RailIdentifier) -> Bool {
        do {
            guard let removal = try prepareTrackedTripRemoval(ids: Set([id])) else { return false }
            try commitTrackedTripRemoval(removal)
            return true
        } catch {
            refreshError = error.localizedDescription
            return false
        }
    }

    func prepareTrackedTripRemoval(ids: Set<RailIdentifier>) throws -> TrackedTripRemoval? {
        guard !tripArchiveRecoveryRequired else { throw TripArchive.RecoveryError.required }
        let removed = trips.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return nil }
        let remaining = trips.filter { !ids.contains($0.id) }
        _ = try archive?.encode(remaining)
        return TrackedTripRemoval(
            remainingTrips: remaining,
            removedTrips: removed
        )
    }

    func commitTrackedTripRemoval(_ removal: TrackedTripRemoval) throws {
        let remainingIDs = Set(removal.remainingTrips.map(\.id))
        let checks = refreshEvidence.compactMapValues(\.lastSuccessfulCheck).filter { remainingIDs.contains($0.key) }
        try archive?.save(removal.remainingTrips, lastChecks: checks)
        watchingOnlyIDs.formIntersection(remainingIDs)
        trips = removal.remainingTrips
        for trip in removal.removedTrips {
            refreshEvidence[trip.id] = nil
            refreshAttemptIDs[trip.id] = nil
        }
        if !hasRefreshableTrips {
            refreshError = nil
        }
        removal.removedTrips.forEach(pushCoordinator.unwatch)
        liveActivityStateDidChange?()
    }

    static func preview(
        referenceDate: Date = .now,
        pushCoordinator: PushRegistrationCoordinator = PushRegistrationCoordinator()
    ) -> TripLibrary {
        TripLibrary(
            trips: PreviewTrips.make(referenceDate: referenceDate),
            pushCoordinator: pushCoordinator,
            archive: nil,
            automaticRefreshEnabled: false
        )
    }

    private func stationSearchAttempt(
        query: String,
        source: RailSource
    ) async -> [RailStationMatch]? {
        do {
            return try await searchStations(query: query, source: source).map {
                RailStationMatch(station: $0, source: source)
            }
        } catch {
            return nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func dateOnly(_ value: String) throws -> Date {
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { throw TripSharingClient.ClientError.invalidLink }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) else {
            throw TripSharingClient.ClientError.invalidLink
        }
        return date
    }
}
