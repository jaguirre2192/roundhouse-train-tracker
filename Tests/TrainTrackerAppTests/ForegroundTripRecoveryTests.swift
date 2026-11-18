import Foundation
import XCTest
import TrainTrackerCore
@testable import TrainTracker

@MainActor final class ForegroundTripRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_019_400)

    func testClearedAmtrakPositionGetsTwoHoursAndSlowForegroundPollSurvivesFailureAndReopen() async throws {
        let fixTime = now.addingTimeInterval(-60 * 60)
        let moving = train(fix: fixTime)
        let cleared = train()
        let clock = RecoveryClock(now)
        let provider = RecoveryProvider(moving)
        let suite = "Roundhouse.ForegroundTripRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = TripArchive(defaults: defaults)
        func open() -> TripLibrary {
            TripLibrary(backendSnapshots: provider, pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive, now: { clock.read() })
        }
        let library = open()
        try library.storeTrackedTrip(moving)
        await library.refreshTrackedTrip(id: moving.id)
        await provider.set(cleared)
        await library.refreshTrackedTrips()
        XCTAssertTrue(try XCTUnwrap(library.trip(id: moving.id)).positions.isEmpty)
        XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(cleared, at: now), "The public/background two-hour policy is unchanged")
        XCTAssertEqual(TripForegroundCadence.forTrip(cleared, journal: library.changeJournal(for: moving.id), at: now), .regular)
        await library.refreshTrackedTrips()
        var requests = await provider.requests
        XCTAssertEqual(requests, 3, "Clearing the position preserves the remaining normal polling allowance")

        clock.set(fixTime.addingTimeInterval(2 * 3_600 + 1))
        await provider.set(nil)
        await library.refreshTrackedTrips()
        XCTAssertTrue(library.lastRefreshFailed(for: moving.id))
        let reopened = open()
        await reopened.refreshTrackedTrip(id: moving.id, allowEnded: false)
        clock.set(clock.read().addingTimeInterval(14 * 60 + 59))
        await reopened.refreshTrackedTrips()
        requests = await provider.requests
        XCTAssertEqual(requests, 4, "A failed request and reopening cannot bypass fifteen-minute backoff")
        clock.set(clock.read().addingTimeInterval(1))
        let returning = train(fix: clock.read().addingTimeInterval(-10))
        await provider.set(returning)
        await reopened.refreshTrackedTrips()
        requests = await provider.requests
        XCTAssertEqual(requests, 5)
        XCTAssertEqual(reopened.changeJournal(for: moving.id).lastPositionReport, returning.positions.first?.asOf)
        XCTAssertEqual(reopened.changeJournal(for: moving.id).batches.first?.changes.first?.fact, .positionResumed)
        XCTAssertEqual(TripForegroundCadence.forTrip(returning, journal: reopened.changeJournal(for: moving.id), at: clock.read()), .regular)
    }

    func testEmptyOrRepeatedOldDataCannotRenewTheEightHourDeadline() throws {
        let observed = now.addingTimeInterval(-20 * 60)
        let evidence = train(fix: observed)
        var journal = TripChangeJournal()
        journal.observe(previous: evidence, current: evidence, hadConfirmedCheck: false, at: now)
        let empty = train()
        let lastChance = observed.addingTimeInterval(8 * 3_600)
        journal.observe(previous: evidence, current: empty, hadConfirmedCheck: true, at: lastChance)
        XCTAssertEqual(TripForegroundCadence.forTrip(empty, journal: journal, at: lastChance), .occasional)
        XCTAssertTrue(journal.reserveSlowCheck(for: empty, at: lastChance, lastSuccess: nil))
        let after = lastChance.addingTimeInterval(1)
        journal.observe(previous: empty, current: evidence, hadConfirmedCheck: true, at: after)
        XCTAssertNil(TripForegroundCadence.forTrip(evidence, journal: journal, at: after))
        XCTAssertNil(TripForegroundCadence.forTrip(empty, journal: journal, at: after))
    }

    func testCanceledArrivedUnrelatedRunsAndUnmatchedOrUndatedReportsCannotExtendPolling() throws {
        let observed = now.addingTimeInterval(-3 * 3_600)
        let moving = train(fix: observed)
        let cleared = train()
        var journal = TripChangeJournal()
        journal.observe(previous: moving, current: cleared, hadConfirmedCheck: true, at: now)
        XCTAssertEqual(TripForegroundCadence.forTrip(cleared, journal: journal, at: now), .occasional)
        XCTAssertNil(TripForegroundCadence.forTrip(train(serviceDayDelta: 86_400), journal: journal, at: now))
        XCTAssertNil(TripForegroundCadence.forTrip(train(runID: "other-run"), journal: journal, at: now))
        XCTAssertNil(TripForegroundCadence.forTrip(train(provider: "different-operator"), journal: journal, at: now))
        for closed in [train(terminalReport: now), train(canceled: true)] {
            var completed = journal
            completed.observe(previous: cleared, current: closed, hadConfirmedCheck: true, at: now)
            XCTAssertNil(TripForegroundCadence.forTrip(closed, journal: completed, at: now))
            completed.observe(previous: closed, current: cleared, hadConfirmedCheck: true, at: now)
            XCTAssertNil(TripForegroundCadence.forTrip(cleared, journal: completed, at: now))
            completed.observe(previous: cleared, current: moving, hadConfirmedCheck: true, at: now)
            XCTAssertNil(TripForegroundCadence.forTrip(moving, journal: completed, at: now))
        }
        let unmoved = train(fix: observed, coordinate: GeoCoordinate(latitude: 38.897, longitude: -77.007))
        let offRoute = train(fix: observed, coordinate: GeoCoordinate(latitude: 45, longitude: -100))
        for trip in [cleared, unmoved, offRoute] {
            XCTAssertNil(TripForegroundCadence.forTrip(trip, journal: TripChangeJournal(), at: now))
        }
        let dated = train(intermediateReport: observed)
        XCTAssertEqual(TripForegroundCadence.forTrip(dated, journal: TripChangeJournal(), at: now), .occasional)
    }

    private func train(fix: Date? = nil, coordinate: GeoCoordinate? = nil, intermediateReport: Date? = nil,
                       terminalReport: Date? = nil, canceled: Bool = false, serviceDayDelta: TimeInterval = 0,
                       runID: String? = nil, provider: String = "amtraker") -> TrainTrip {
        let source = TripUpdatesQA.amtrak.snapshot(.baseline, now: now)
        let stations = source.stopTimes.map(\.station)
        let calls = [
            StopTime(station: stations[0], sequence: 1, scheduledDeparture: now.addingTimeInterval(-8 * 3_600), isCancelled: canceled, isPassed: true),
            StopTime(station: stations[1], sequence: 2, scheduledArrival: now.addingTimeInterval(-6 * 3_600), isCancelled: canceled,
                     isPassed: true, passageObservedAt: intermediateReport),
            StopTime(station: stations[2], sequence: 3, scheduledArrival: now.addingTimeInterval(-4 * 3_600), isCancelled: canceled,
                     isPassed: true, arrivalObservedAt: terminalReport),
        ]
        let midpoint = GeoCoordinate(latitude: (stations[0].location.latitude + stations[1].location.latitude) / 2,
                                     longitude: (stations[0].location.longitude + stations[1].location.longitude) / 2)
        return TrainTrip(id: runID.map(RailIdentifier.init(rawValue:)) ?? source.id, source: provider,
                         serviceDate: source.serviceDate.addingTimeInterval(serviceDayDelta), operatorName: "Amtrak",
                         product: "Northeast Regional 171", headsign: "New York Penn", stopTimes: calls,
                         positions: fix.map { [VehiclePosition(coordinate: coordinate ?? midpoint, source: .real, confidence: 1, asOf: $0)] } ?? [],
                         capabilities: source.capabilities)
    }
}

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func set(_ value: Date) { lock.withLock { date = value } }
}

private actor RecoveryProvider: TripDataProviding {
    var requests = 0
    private var current: TrainTrip?
    init(_ current: TrainTrip) { self.current = current }
    func set(_ trip: TrainTrip?) { current = trip }
    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary] { [] }
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { try next() }
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip { try next() }
    private func next() throws -> TrainTrip {
        requests += 1
        guard let current else { throw URLError(.notConnectedToInternet) }
        return current
    }
}
