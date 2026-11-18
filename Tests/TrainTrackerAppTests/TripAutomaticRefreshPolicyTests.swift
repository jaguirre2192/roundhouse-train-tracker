import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TripAutomaticRefreshPolicyTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_784_574_000)

    @MainActor
    func testNearestFutureDepartureWinsForHighlightedTrainAndIPadDefault() {
        let later = makeTrip(id: "later", scheduledStart: referenceDate.addingTimeInterval(3_600), scheduledEnd: referenceDate.addingTimeInterval(7_200))
        let next = makeTrip(id: "next", scheduledStart: referenceDate.addingTimeInterval(600), scheduledEnd: referenceDate.addingTimeInterval(4_000))
        let adapter = AutomaticRefreshRailAdapter(trips: [later, next])
        let library = makeLibrary(trips: [later, next], adapter: adapter)

        XCTAssertEqual(library.activeTrip?.id, next.id)
        let presentation = JourneyPlanListPresentation(plans: [], trips: library.trips, activeTrip: library.activeTrip, at: referenceDate)
        XCTAssertEqual(presentation.activeTrip?.id, next.id)
        XCTAssertEqual(presentation.upcomingTrains(asOf: referenceDate).map(\.id), [later.id])
    }

    func testUnderwayTrainWinsOverEarlierSavedFutureTrain() {
        let future = makeTrip(id: "future", scheduledStart: referenceDate.addingTimeInterval(600), scheduledEnd: referenceDate.addingTimeInterval(4_000))
        let current = makeTrip(id: "current", scheduledStart: referenceDate.addingTimeInterval(-600), scheduledEnd: referenceDate.addingTimeInterval(3_600))

        XCTAssertEqual(TripAutomaticRefreshPolicy.preferredActiveTrip(in: [future, current], at: referenceDate)?.id, current.id)
    }

    func testEqualFutureDeparturesPreserveSaveOrder() {
        let first = makeTrip(id: "first", scheduledStart: referenceDate.addingTimeInterval(600), scheduledEnd: referenceDate.addingTimeInterval(4_000))
        let second = makeTrip(id: "second", scheduledStart: referenceDate.addingTimeInterval(600), scheduledEnd: referenceDate.addingTimeInterval(4_000))

        XCTAssertEqual(TripAutomaticRefreshPolicy.preferredActiveTrip(in: [first, second], at: referenceDate)?.id, first.id)
    }

    func testPassedFlagsDoNotEndTheTimetableRecoveryWindow() {
        let trip = makeTrip(scheduledEnd: referenceDate, passed: true)

        XCTAssertFalse(trip.isComplete, "Unstamped passage flags do not confirm arrival")
        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
            trip, at: referenceDate.addingTimeInterval(3_600)
        ))
        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
            trip, at: referenceDate.addingTimeInterval(7_200)
        ))
        XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
            trip, at: referenceDate.addingTimeInterval(7_201)
        ))
    }

    func testDelayedExpectedArrivalExtendsTheRecoveryWindow() {
        let trip = makeTrip(
            scheduledEnd: referenceDate.addingTimeInterval(-10_800),
            expectedEnd: referenceDate,
            passed: true
        )

        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: referenceDate))
    }

    func testEarlierEstimateDoesNotShortenTheScheduledRecoveryWindow() {
        let trip = makeTrip(
            scheduledEnd: referenceDate,
            expectedEnd: referenceDate.addingTimeInterval(-10_800)
        )

        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: referenceDate))
    }

    func testMissingTimetableUsesBoundedServiceDayFallbackEvenWithEmptyStops() {
        let emptyTrip = makeTrip(empty: true)
        let untimedTrip = makeTrip()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let expiration = calendar.startOfDay(for: referenceDate).addingTimeInterval(48 * 3_600)

        for trip in [emptyTrip, untimedTrip] {
            XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: referenceDate))
            XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
                trip, at: expiration.addingTimeInterval(1)
            ))
        }
    }

    @MainActor
    func testManualRefreshAllowsAllPassedHistoricalTrip() async throws {
        let trip = makeTrip(scheduledEnd: referenceDate.addingTimeInterval(-86_400), passed: true)
        let adapter = AutomaticRefreshRailAdapter(trips: [trip])
        let library = makeLibrary(trips: [trip], adapter: adapter)

        XCTAssertFalse(library.hasRefreshableTrips)
        await library.refreshTrackedTrip(id: trip.id)

        let requestedIDs = await adapter.requestedTripIDs()
        XCTAssertEqual(requestedIDs, [trip.id])
        XCTAssertEqual(library.lastSuccessfulCheck(for: trip.id), referenceDate)
    }

    @MainActor
    func testAutomaticBulkRefreshKeepsRecoveryTripAndSkipsOldUnpassedTrip() async {
        let recovering = makeTrip(id: "recovering", scheduledEnd: referenceDate.addingTimeInterval(-3_600), passed: true)
        let expired = makeTrip(id: "expired", scheduledEnd: referenceDate.addingTimeInterval(-10_800))
        let adapter = AutomaticRefreshRailAdapter(trips: [recovering, expired])
        let library = makeLibrary(trips: [recovering, expired], adapter: adapter)

        XCTAssertTrue(library.hasRefreshableTrips)
        await library.refreshTrackedTrips()

        let requestedIDs = await adapter.requestedTripIDs()
        XCTAssertEqual(requestedIDs, [recovering.id])
        XCTAssertNotNil(library.lastSuccessfulCheck(for: recovering.id))
        XCTAssertNil(library.lastSuccessfulCheck(for: expired.id))
        XCTAssertTrue(library.removeTrip(id: recovering.id))
        XCTAssertFalse(library.hasRefreshableTrips)
    }

    @MainActor
    func testRecoveryWindowKeepsPassedTripVisibleAndRestoresItsPushWatch() {
        let recovering = makeTrip(
            id: "recovering",
            scheduledEnd: referenceDate.addingTimeInterval(-3_600),
            passed: true
        )
        let expired = makeTrip(
            id: "expired",
            scheduledEnd: referenceDate.addingTimeInterval(-10_800),
            passed: true
        )
        let adapter = AutomaticRefreshRailAdapter(trips: [recovering, expired])
        let push = RecordingPushCoordinator()
        let now = referenceDate
        let library = TripLibrary(
            trips: [expired, recovering],
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: push,
            archive: nil,
            automaticRefreshEnabled: true,
            now: { now }
        )

        XCTAssertEqual(library.activeTrip?.id, recovering.id)
        library.resumePushWatches()
        XCTAssertEqual(push.watchedTripIDs, [recovering.id])
    }

    @MainActor
    func testTimetablePhaseDistinguishesPrematurePassageFromEndedConnection() {
        let trips = PreviewTrips.make(referenceDate: referenceDate)
        let prematurelyPassed = markingAllStopsPassed(in: trips[0])
        let adapter = AutomaticRefreshRailAdapter(trips: [prematurelyPassed, trips[1]])
        let underwayDate = referenceDate
        let endedDate = referenceDate.addingTimeInterval(4 * 3_600)
        let underwayLibrary = makeLibrary(
            trips: [prematurelyPassed, trips[1]],
            adapter: adapter,
            now: underwayDate
        )
        let endedLibrary = makeLibrary(
            trips: [prematurelyPassed, trips[1]],
            adapter: adapter,
            now: endedDate
        )

        XCTAssertFalse(prematurelyPassed.isComplete, "Unstamped passage flags do not confirm arrival")
        XCTAssertEqual(underwayLibrary.activeTrip?.id, prematurelyPassed.id)
        XCTAssertEqual(endedLibrary.activeTrip?.id, trips[1].id)
    }

    @MainActor
    func testDetailPollingDoesNotKeepRefreshingHistoricalTrip() async {
        let trip = makeTrip(scheduledEnd: referenceDate.addingTimeInterval(-86_400))
        let adapter = AutomaticRefreshRailAdapter(trips: [trip])
        let library = makeLibrary(trips: [trip], adapter: adapter)

        await library.refreshTrackedTrip(id: trip.id, allowEnded: false)

        let requestedIDs = await adapter.requestedTripIDs()
        XCTAssertTrue(requestedIDs.isEmpty)
        XCTAssertNil(library.lastSuccessfulCheck(for: trip.id))
    }

    @MainActor
    func testPreviewDisablementStillBlocksExplicitRefresh() async {
        let trip = makeTrip(scheduledEnd: referenceDate)
        let adapter = AutomaticRefreshRailAdapter(trips: [trip])
        let library = makeLibrary(trips: [trip], adapter: adapter, enabled: false)

        await library.refreshTrackedTrip(id: trip.id)

        let requestedIDs = await adapter.requestedTripIDs()
        XCTAssertTrue(requestedIDs.isEmpty)
    }

    @MainActor
    private func makeLibrary(
        trips: [TrainTrip],
        adapter: AutomaticRefreshRailAdapter,
        enabled: Bool = true,
        now: Date? = nil
    ) -> TripLibrary {
        let currentDate = now ?? referenceDate
        return TripLibrary(
            trips: trips,
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: enabled,
            now: { currentDate }
        )
    }

    private func makeTrip(
        id: String = "trip",
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        expectedEnd: Date? = nil,
        passed: Bool = false,
        empty: Bool = false
    ) -> TrainTrip {
        let stop = StopTime(
            station: Station(
                id: RailIdentifier(rawValue: "test:station"),
                names: [LocalizedStationName("Destination")],
                location: GeoCoordinate(latitude: 0, longitude: 0),
                countryCode: "US"
            ),
            sequence: 1,
            scheduledArrival: scheduledEnd,
            expectedArrival: expectedEnd,
            isPassed: passed
        )
        return TrainTrip(
            id: RailIdentifier(rawValue: "test:\(id)"),
            source: "test",
            serviceDate: referenceDate,
            operatorName: "Railway",
            product: "Train 1",
            headsign: "Destination",
            stopTimes: empty ? [] : (scheduledStart.map {
                [StopTime(station: stop.station, sequence: 0, scheduledDeparture: $0), stop]
            } ?? [stop]),
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true,
                hasAlerts: false, granularity: .perStop
            )
        )
    }

    private func markingAllStopsPassed(in trip: TrainTrip) -> TrainTrip {
        TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: trip.stopTimes.map { stop in
                StopTime(
                    station: stop.station,
                    sequence: stop.sequence,
                    scheduledArrival: stop.scheduledArrival,
                    scheduledDeparture: stop.scheduledDeparture,
                    expectedArrival: stop.expectedArrival,
                    expectedDeparture: stop.expectedDeparture,
                    plannedPlatform: stop.plannedPlatform,
                    expectedPlatform: stop.expectedPlatform,
                    isCancelled: stop.isCancelled,
                    isPassed: true
                )
            },
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }
}

private actor AutomaticRefreshRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities
    private let trips: [RailIdentifier: TrainTrip]
    private var requestedIDs: [RailIdentifier] = []

    init(trips: [TrainTrip]) {
        capabilities = trips[0].capabilities
        self.trips = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
    }

    func requestedTripIDs() -> [RailIdentifier] { requestedIDs }
    func searchStations(query: String) async throws -> [Station] { [] }
    func resolveStation(id: RailIdentifier) async throws -> Station { throw RailAdapterError.notFound }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        requestedIDs.append(id)
        guard let trip = trips[id] else { throw RailAdapterError.notFound }
        return trip
    }
}
