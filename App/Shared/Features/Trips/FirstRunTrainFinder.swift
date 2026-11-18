import Foundation
import Observation
import TrainTrackerCore

/// Finds a real train that is running now and keeps it current while it is on screen. Nothing
/// is saved and no alerts are registered until the rider chooses to follow it.
@MainActor
@Observable
final class FirstRunTrainFinder {
    struct Featured: Equatable, Sendable {
        var trip: TrainTrip
        var checkedAt: Date
        var refreshFailed = false

        func trust(at date: Date) -> JourneyTrust {
            trust(at: date, progress: RailJourneyProgress(trip: trip, referenceDate: date))
        }

        private func trust(at date: Date, progress: RailJourneyProgress) -> JourneyTrust {
            JourneyTrust(
                freshness: TripFreshness(lastSuccessfulCheck: checkedAt, lastRefreshFailed: refreshFailed),
                timingBasis: progress.timingBasis, phase: progress.phase, referenceDate: date
            )
        }

        func title(at date: Date) -> String {
            let progress = RailJourneyProgress(trip: trip, referenceDate: date)
            let trust = trust(at: date, progress: progress)
            if !trip.isCancelled, progress.phase == .underway, !refreshFailed,
               trust == .live || progress.evidence.basis == .vehiclePosition {
                return "Running right now"
            }
            return trust == .timetable ? "On the timetable" : "Featured train"
        }

        func isUnderway(at date: Date) -> Bool {
            !trip.isCancelled && RailJourneyProgress(trip: trip, referenceDate: date).phase == .underway
        }
    }

    enum State: Equatable, Sendable {
        case looking
        case found(Featured)
        /// The boards returned successfully and had no suitable service.
        case none
        case unavailable
    }

    private(set) var state = State.looking
    private(set) var isRefreshing = false
    private(set) var lookupRevision = 0
    let hubs: [FirstRunHub]
    @ObservationIgnored private var lastLookupAt: Date?
    @ObservationIgnored private var currentLookup: UUID?

    init(regionCode: String? = Locale.autoupdatingCurrent.region?.identifier) {
        hubs = FirstRunHub.hubs(regionCode: regionCode)
    }

    var featured: Featured? {
        if case let .found(featured) = state { return featured }
        return nil
    }

    func load(library: TripLibrary, at date: Date = .now) async {
        guard !Task.isCancelled else { return }
        if let featured {
            if featured.isUnderway(at: date) {
                if featured.refreshFailed || date.timeIntervalSince(featured.checkedAt) > JourneyTrust.liveWindow {
                    await refresh(library: library, at: date)
                }
                return
            }
            // This task already owns discovery. Remove the old Follow action before the
            // first network suspension, then look for a train on the current service day.
            resetLookup()
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-FirstRunPreviewEmpty") {
            state = .none
            return
        }
        #if DEBUG
        if arguments.contains("-FirstRunPreviewRetry") {
            let retries = lookupRevision
            await discover { _ in
                guard retries > 0 else { throw URLError(.notConnectedToInternet) }
                return PreviewTrips.make(referenceDate: .now).first
            }
            return
        }
        let usesHistoryFixture = arguments.contains("-MyTripsPastOnlyQA") || arguments.contains("-MyTripsPastPlansQA")
        #else
        let usesHistoryFixture = false
        #endif
        if arguments.contains("-FirstRunPreview") || usesHistoryFixture {
            // A fixture train, so the screen can be checked without the network.
            let date = JourneyPlanPreviewData.resolve(arguments: arguments)?.referenceDate ?? .now
            state = PreviewTrips.make(referenceDate: date).first.map { .found(Featured(trip: $0, checkedAt: date)) } ?? .none
            return
        }
        guard !LaunchFixtures.isActive else {
            state = .none
            return
        }
        await discover { hub in try await Self.find(at: hub, library: library) }
    }

    /// The view owns the task. A timed-out or cancelled request must never replace a newer ticket.
    func discover(
        timeout: Duration = .seconds(18),
        fallbackAfter: Duration = .seconds(5),
        find: @escaping @MainActor @Sendable (FirstRunHub) async throws -> TrainTrip?
    ) async {
        guard !Task.isCancelled, featured == nil else { return }
        if let lastLookupAt, Date.now.timeIntervalSince(lastLookupAt) < 5 * 60 { return }
        let request = UUID()
        currentLookup = request
        state = .looking
        await withTaskGroup(of: LookupEvent.self) { group in
            defer { group.cancelAll() }
            var stations = hubs.makeIterator()
            var activeHubs = 0
            var hadFailure = false
            func startNextHub(in group: inout TaskGroup<LookupEvent>) {
                guard let hub = stations.next() else { return }
                activeHubs += 1
                group.addTask {
                    do { return .answer(try await find(hub)) }
                    catch { return .failure }
                }
            }

            startNextHub(in: &group)
            group.addTask {
                try? await Task.sleep(for: fallbackAfter)
                return .startFallback
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .deadline
            }
            while let event = await group.next() {
                guard !Task.isCancelled, currentLookup == request else { return }
                switch event {
                case .answer(let trip?):
                    state = .found(Featured(trip: trip, checkedAt: .now))
                case .startFallback:
                    startNextHub(in: &group)
                    continue
                case .answer(nil), .failure:
                    activeHubs -= 1
                    if case .failure = event { hadFailure = true }
                    startNextHub(in: &group)
                    guard activeHubs == 0 else { continue }
                    state = hadFailure ? .unavailable : .none
                case .deadline:
                    state = .unavailable
                }
                lastLookupAt = .now
                return
            }
        }
    }

    private enum LookupEvent: Sendable {
        case answer(TrainTrip?), failure, startFallback, deadline
    }

    func retry() {
        guard state == .unavailable else { return }
        restartLookup()
    }

    private func restartLookup() {
        resetLookup()
        lookupRevision += 1
    }

    private func resetLookup() {
        currentLookup = nil
        lastLookupAt = nil
        state = .looking
    }

    /// Checks the shown train again. A failure keeps the train and marks it, so the trust word
    /// falls back to Saved instead of the train vanishing.
    func refresh(library: TripLibrary, at referenceDate: Date? = nil) async {
        guard var featured, !isRefreshing, !LaunchFixtures.isActive else { return }
        let request = currentLookup
        let originalTripID = featured.trip.id
        isRefreshing = true
        defer { isRefreshing = false }
        let fresh = await library.refreshedUntracked(featured.trip)
        guard !Task.isCancelled, currentLookup == request, self.featured?.trip.id == originalTripID else { return }
        let date = referenceDate ?? .now
        if let fresh {
            featured = Featured(trip: fresh, checkedAt: date)
        } else {
            featured.refreshFailed = true
        }
        if featured.isUnderway(at: date) {
            state = .found(featured)
        } else {
            restartLookup()
        }
    }

    private static func find(at hub: FirstRunHub, library: TripLibrary) async throws -> TrainTrip? {
        let now = Date.now
        let stations = try await library.searchStations(query: hub.query, source: hub.source)
        guard let station = FirstRunTrainPicker.station(in: stations, near: hub) else { return nil }
        let board = try await library.board(stationID: station.id, source: hub.source, at: now.addingTimeInterval(-45 * 60))
        let candidates = FirstRunTrainPicker.departed(board, at: now)
        guard !candidates.isEmpty else { return nil }
        let trips = await withTaskGroup(of: TrainTrip?.self) { group in
            for candidate in candidates {
                group.addTask { try? await library.untrackedTrip(candidate) }
            }
            var found: [TrainTrip] = []
            for await trip in group { if let trip { found.append(trip) } }
            return found
        }
        try Task.checkCancellation()
        guard !trips.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
        return FirstRunTrainPicker.best(trips, at: .now)
    }
}
